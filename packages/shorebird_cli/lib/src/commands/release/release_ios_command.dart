import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/auth_logger_mixin.dart';
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/shorebird_build_mixin.dart';
import 'package:shorebird_cli/src/shorebird_config_mixin.dart';
import 'package:shorebird_cli/src/shorebird_validation_mixin.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template release_ios_command}
/// `shorebird release ios`
/// Create new app releases for iOS.
/// {@endtemplate}
class ReleaseIosCommand extends ShorebirdCommand
    with
        AuthLoggerMixin,
        ShorebirdValidationMixin,
        ShorebirdConfigMixin,
        ShorebirdBuildMixin {
  /// {@macro release_ios_command}
  ReleaseIosCommand({
    required super.logger,
    super.auth,
    super.buildCodePushClient,
    super.cache,
    super.validators,
    HashFunction? hashFn,
  }) : _hashFn = hashFn ?? ((m) => sha256.convert(m).toString()) {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help: 'The main entrypoint file of the application.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Release without confirmation if there are no errors.',
        negatable: false,
      );
  }

  @override
  String get description => '''
Builds and submits your iOS app to Shorebird.
Shorebird saves the compiled Dart code from your application in order to
make smaller updates to your app.
''';

  @override
  String get name => 'ios';

  final HashFunction _hashFn;

  @override
  Future<int> run() async {
    if (!isShorebirdInitialized) {
      logger.err(
        'Shorebird is not initialized. Did you run "shorebird init"?',
      );
      return ExitCode.config.code;
    }

    if (!auth.isAuthenticated) {
      printNeedsAuthInstructions();
      return ExitCode.noUser.code;
    }

    final validationIssues = await runValidators();
    if (validationIssuesContainsError(validationIssues)) {
      logValidationFailure(issues: validationIssues);
      return ExitCode.config.code;
    }

    final flavor = results['flavor'] as String?;
    final target = results['target'] as String?;
    final buildProgress = logger.progress('Building release');
    try {
      await buildIpa(flavor: flavor, target: target);
      buildProgress.complete();
    } on ProcessException catch (error) {
      buildProgress.fail('Failed to build: ${error.message}');
      return ExitCode.software.code;
    }

    final shorebirdYaml = getShorebirdYaml()!;
    final codePushClient = buildCodePushClient(
      httpClient: auth.client,
      hostedUri: hostedUri,
    );

    const bundlePath = 'build/ios/ipa/ios_test.ipa';

    late final List<App> apps;
    final fetchAppsProgress = logger.progress('Fetching apps');
    try {
      apps = (await codePushClient.getApps())
          .map((a) => App(id: a.appId, displayName: a.displayName))
          .toList();
      fetchAppsProgress.complete();
    } catch (error) {
      fetchAppsProgress.fail('$error');
      return ExitCode.software.code;
    }

    final appId = shorebirdYaml.getAppId(flavor: flavor);
    final app = apps.firstWhereOrNull((a) => a.id == appId);
    if (app == null) {
      logger.err(
        '''
Could not find app with id: "$appId".
Did you forget to run "shorebird init"?''',
      );
      return ExitCode.software.code;
    }

    const releaseVersion = '1.0.0';
    // TODO(eseidel): Detect the release version from the Info.plist

    const platform = 'ios';
    final archNames = ['arm64'];
    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.id})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '''🕹️  Platform: ${lightCyan.wrap(platform)} ${lightCyan.wrap('(${archNames.join(', ')})')}''',
    ];

    logger.info('''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to create a new release!'))}

${summary.join('\n')}
''');

    final force = results['force'] == true;
    final needConfirmation = !force;
    if (needConfirmation) {
      final confirm = logger.confirm('Would you like to continue?');

      if (!confirm) {
        logger.info('Aborting.');
        return ExitCode.success.code;
      }
    }

    late final List<Release> releases;
    final fetchReleasesProgress = logger.progress('Fetching releases');
    try {
      releases = await codePushClient.getReleases(appId: app.id);
      fetchReleasesProgress.complete();
    } catch (error) {
      fetchReleasesProgress.fail('$error');
      return ExitCode.software.code;
    }

    var release = releases.firstWhereOrNull((r) => r.version == releaseVersion);
    if (release == null) {
      final flutterRevisionProgress = logger.progress(
        'Fetching Flutter revision',
      );
      final String shorebirdFlutterRevision;
      try {
        shorebirdFlutterRevision = await getShorebirdFlutterRevision();
        flutterRevisionProgress.complete();
      } catch (error) {
        flutterRevisionProgress.fail('$error');
        return ExitCode.software.code;
      }

      final createReleaseProgress = logger.progress('Creating release');
      try {
        release = await codePushClient.createRelease(
          appId: app.id,
          version: releaseVersion,
          flutterRevision: shorebirdFlutterRevision,
        );
        createReleaseProgress.complete();
      } catch (error) {
        createReleaseProgress.fail('$error');
        return ExitCode.software.code;
      }
    }

    final createArtifactProgress = logger.progress('Creating artifacts');
    for (final arch in archNames) {
      final artifactPath = p.join(
        Directory.current.path,
        bundlePath,
      );
      final artifact = File(artifactPath);
      final hash = _hashFn(await artifact.readAsBytes());
      logger.detail('Creating artifact for $artifactPath');

      try {
        await codePushClient.createReleaseArtifact(
          releaseId: release.id,
          artifactPath: artifact.path,
          arch: arch,
          platform: platform,
          hash: hash,
        );
      } on CodePushConflictException catch (_) {
        // Newlines are due to how logger.info interacts with logger.progress.
        logger.info(
          '''

$arch artifact already exists, continuing...''',
        );
      } catch (error) {
        createArtifactProgress.fail('Error uploading ${artifact.path}: $error');
        return ExitCode.software.code;
      }
    }

    createArtifactProgress.complete();

    logger
      ..success('\n✅ Published Release!')
      ..info('''

Your next step is to upload the app bundle to the App Store.
${lightCyan.wrap(bundlePath)}

See the following link for more information:    
${link(uri: Uri.parse('https://docs.flutter.dev/deployment/ios'))}
''');

    return ExitCode.success.code;
  }
}
