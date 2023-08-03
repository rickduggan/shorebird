import 'dart:io' hide Platform;

import 'package:checked_yaml/checked_yaml.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:scoped/scoped.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:yaml/yaml.dart';

/// A reference to a [ShorebirdEnv] instance.
final shorebirdEnvRef = create(ShorebirdEnv.new);

/// The [ShorebirdEnv] instance available in the current zone.
ShorebirdEnv get shorebirdEnv => read(shorebirdEnvRef);

/// {@template shorebird_env}
/// A class that provides access to shorebird environment metadata.
/// {@endtemplate}
class ShorebirdEnv {
  /// {@macro shorebird_env}
  const ShorebirdEnv();

  /// The root directory of the Shorebird install.
  ///
  /// Assumes we are running from $ROOT/bin/cache.
  Directory get shorebirdRoot {
    return File(platform.script.toFilePath()).parent.parent.parent;
  }

  String shorebirdEngineRevision({String? flutterRevision}) {
    return File(
      p.join(
        flutterDirectory(revision: flutterRevision).path,
        'bin',
        'internal',
        'engine.version',
      ),
    ).readAsStringSync().trim();
  }

  String get flutterRevision {
    return File(
      p.join(shorebirdRoot.path, 'bin', 'internal', 'flutter.version'),
    ).readAsStringSync().trim();
  }

  /// The root of the Shorebird-vended Flutter git checkout.
  Directory flutterDirectory({String? revision}) {
    return Directory(
      p.join(
        shorebirdRoot.path,
        'bin',
        'cache',
        'flutter',
        revision ?? flutterRevision,
      ),
    );
  }

  /// The Shorebird-vended Flutter binary.
  File flutterBinaryFile({String? revision}) {
    return File(
      p.join(
        flutterDirectory(revision: revision).path,
        'bin',
        'flutter',
      ),
    );
  }

  File genSnapshotFile({String? revision}) {
    return File(
      p.join(
        flutterDirectory(revision: revision).path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  /// The `shorebird.yaml` file for this project.
  File getShorebirdYamlFile() {
    return File(p.join(Directory.current.path, 'shorebird.yaml'));
  }

  /// The `pubspec.yaml` file for this project.
  File getPubspecYamlFile() {
    return File(p.join(Directory.current.path, 'pubspec.yaml'));
  }

  /// The `shorebird.yaml` file for this project, parsed into a [ShorebirdYaml]
  /// object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  ShorebirdYaml? getShorebirdYaml() {
    final file = getShorebirdYamlFile();
    if (!file.existsSync()) return null;
    final yaml = file.readAsStringSync();
    return checkedYamlDecode(yaml, (m) => ShorebirdYaml.fromJson(m!));
  }

  /// The `pubspec.yaml` file for this project, parsed into a [Pubspec] object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  Pubspec? getPubspecYaml() {
    final file = getPubspecYamlFile();
    if (!file.existsSync()) return null;
    final yaml = file.readAsStringSync();
    return Pubspec.parse(yaml);
  }

  /// Whether `shorebird init` has been run in the current project.
  bool get isShorebirdInitialized {
    return hasShorebirdYaml && pubspecContainsShorebirdYaml;
  }

  /// Whether the current project has a `shorebird.yaml` file.
  bool get hasShorebirdYaml => getShorebirdYamlFile().existsSync();

  /// Whether the current project has a `pubspec.yaml` file.
  bool get hasPubspecYaml => getPubspecYaml() != null;

  /// Whether the current project's `pubspec.yaml` file contains a reference to
  /// `shorebird.yaml` in its `assets` section.
  bool get pubspecContainsShorebirdYaml {
    final file = File(p.join(Directory.current.path, 'pubspec.yaml'));
    final pubspecContents = file.readAsStringSync();
    final yaml = loadYaml(pubspecContents, sourceUrl: file.uri) as Map;
    if (!yaml.containsKey('flutter')) return false;
    if (!(yaml['flutter'] as Map).containsKey('assets')) return false;
    final assets = (yaml['flutter'] as Map)['assets'] as List;
    return assets.contains('shorebird.yaml');
  }

  /// Returns the Android package name from the pubspec.yaml file of a Flutter
  /// module.
  String? get androidPackageName {
    final pubspec = getPubspecYaml();
    final module = pubspec?.flutter?['module'] as Map?;
    return module?['androidPackage'] as String?;
  }

  /// The base URL for the Shorebird code push server that overrides the default
  /// used by [CodePushClient]. If none is provided, [CodePushClient] will use
  /// its default.
  Uri? get hostedUri {
    try {
      final baseUrl = platform.environment['SHOREBIRD_HOSTED_URL'] ??
          getShorebirdYaml()?.baseUrl;
      return baseUrl == null ? null : Uri.tryParse(baseUrl);
    } catch (_) {
      return null;
    }
  }
}