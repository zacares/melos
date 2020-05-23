import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:yamlicious/yamlicious.dart';

import '../pub/pub_deps_list.dart';
import '../pub/pub_file_flutter_plugins.dart';
import '../pub/pub_file_package_config.dart';
import '../pub/pub_file_packages.dart';
import '../pub/pub_file_pubspec_lock.dart';
import 'package.dart';
import 'utils.dart' as utils;
import 'workspace_config.dart';

MelosWorkspace currentWorkspace;

class MelosWorkspace {
  final String _name;

  String get name => _name;

  final String _path;

  String get path => _path;

  Map<String, Set<String>> _dependencyGraph;

  final MelosWorkspaceConfig _config;

  MelosWorkspaceConfig get config => _config;

  List<MelosPackage> _packages;

  List<MelosPackage> get packages => _packages;

  MelosWorkspace._(this._name, this._path, this._config);

  static Future<MelosWorkspace> fromDirectory(Directory directory,
      {@required ArgResults arguments}) async {
    final workspaceConfig = await MelosWorkspaceConfig.fromDirectory(directory);

    if (workspaceConfig == null) {
      return null;
    }

    return MelosWorkspace._(
        workspaceConfig.name, workspaceConfig.path, workspaceConfig);
  }

  Future<List<MelosPackage>> loadPackages(
      {List<String> scope, List<String> ignore}) async {
    if (_packages != null) return Future.value(_packages);

    _packages = await Directory(_path)
        .list(recursive: true, followLinks: false)
        .where((file) {
      return file.path.endsWith('pubspec.yaml');
    }).where((file) {
      // Filter matching 'packages' config from melos.yaml
      final packageGlobs = _config.packages;
      // No 'package' glob patterns in 'melos.yaml' so skip all packages.
      if (packageGlobs.isEmpty) return false;
      final matchedPattern = packageGlobs.firstWhere((pattern) {
        return pattern.matches(file.path);
      }, orElse: () => null);
      return matchedPattern != null;
    }).asyncMap((entity) async {
      // Convert into Package for further filtering
      return MelosPackage.fromPubspecPath(entity);
    }).where((package) {
      // Scoped packages filter.
      if (scope.isEmpty) return true;
      final matchedPattern = scope.firstWhere((pattern) {
        return Glob(pattern).matches(package.name);
      }, orElse: () => null);
      return matchedPattern != null;
    }).where((package) {
      // Ignore packages filter.
      if (ignore.isEmpty) return true;
      final matchedPattern = ignore.firstWhere((pattern) {
        return Glob(pattern).matches(package.name);
      }, orElse: () => null);
      return matchedPattern == null;
    }).toList();

    _packages.sort((a, b) {
      return a.name.compareTo(b.name);
    });

    return _packages;
  }

  Future<Map<String, Set<String>>> getDependencyGraph() async {
    if (_dependencyGraph != null) {
      return _dependencyGraph;
    }

    final pubListCommandOutput = await Process.run(
      'flutter',
      ['pub', 'deps', '--', '--style=list', '--dev'],
      runInShell: true,
      workingDirectory: _path,
    );

    final pubDepList = PubDepsList.parse(pubListCommandOutput.stdout as String);
    final allEntries = pubDepList.allEntries;
    final allEntriesMap = allEntries.map((entry, map) {
      return MapEntry(entry.name, map);
    });

    void addNestedEntries(Set entriesSet) {
      var countBefore = entriesSet.length;
      var entriesSetClone = Set.from(entriesSet);

      entriesSetClone.forEach((entryName) {
        var depsForEntry = allEntriesMap[entryName];
        if (depsForEntry != null && depsForEntry.isNotEmpty) {
          depsForEntry.forEach((dependentName, _) {
            entriesSet.add(dependentName);
          });
        }
      });

      if (countBefore != entriesSet.length) {
        addNestedEntries(entriesSet);
      }
    }

    Map<String, Set<String>> dependencyGraphFlat = {};

    allEntries.forEach((entry, dependencies) {
      var entriesSet = <String>{};
      if (dependencies.isNotEmpty) {
        dependencies.forEach((dependentName, _) {
          entriesSet.add(dependentName);
        });
      }
      addNestedEntries(entriesSet);
      dependencyGraphFlat[entry.name] = entriesSet;
    });

    _dependencyGraph = dependencyGraphFlat;
    return dependencyGraphFlat;
  }

  /// Execute a command in the root of this workspace.
  Future<int> exec(List<String> execArgs, {bool onlyOutputOnError = false}) {
    final environment = {
      'MELOS_ROOT_PATH': path,
    };

    return utils.startProcess(execArgs,
        environment: environment,
        workingDirectory: path,
        onlyOutputOnError: onlyOutputOnError);
  }

  Future<void> linkPackages() async {
    await getDependencyGraph();
    await Future.forEach(packages, (MelosPackage package) {
      return package.linkPackages(this);
    });
  }

  void clean({bool cleanPackages = true}) {
    // clean workspace
    PackagesPubFile.fromDirectory(path).delete();
    FlutterPluginsPubFile.fromDirectory(path).delete();
    PackageConfigPubFile.fromDirectory(path).delete();
    // TODO(salakar): .flutter-plugins-dependencies

    // Delete generated pubspec.yaml file, only if cli generated it.
    var pubspecFileRoot = File('$path${Platform.pathSeparator}pubspec.yaml');
    if (pubspecFileRoot.existsSync()) {
      var contents = pubspecFileRoot.readAsStringSync();
      if (contents.startsWith(
          '# Generated file - do not modify or commit this file.')) {
        pubspecFileRoot.deleteSync();
        PubspecLockPubFile.fromDirectory(path).delete();
      }
    } else {
      PubspecLockPubFile.fromDirectory(path).delete();
    }

    if (cleanPackages) {
      packages.forEach((MelosPackage package) {
        package.clean();
      });
    }
  }

  Future<void> generatePubspecFile() async {
    var workspacePubspec = {};
    var workspaceName = config.name ?? 'MelosWorkspace';

    workspacePubspec['name'] = workspaceName;
    workspacePubspec['version'] = config.version ?? '0.0.0';
    workspacePubspec['publish_to'] = 'none';
    workspacePubspec['dependencies'] = Map.from(config.dependencies);
    workspacePubspec['dev_dependencies'] = Map.from(config.devDependencies);
    workspacePubspec['dependency_overrides'] = {};
    workspacePubspec['environment'] = Map.from(config.environment);

    packages.forEach((MelosPackage plugin) {
      var pluginRelativePath = utils.relativePath(plugin.path, path);
      workspacePubspec['dependencies'][plugin.name] = {
        'path': pluginRelativePath,
      };
      workspacePubspec['dependency_overrides'][plugin.name] = {
        'path': pluginRelativePath,
      };

      // TODO(salakar): this is a hacky work around for dev deps - look at using
      //                pub cache add etc and manually generating file:// links
      var devDependencies = plugin.devDependencies;
      plugin.devDependenciesSet.forEach((name) {
        var linkedPackageExists = packages.firstWhere((package) {
          return package.name == name;
        }, orElse: () {
          return null;
        });
        if (linkedPackageExists == null) {
          workspacePubspec['dev_dependencies'][name] = devDependencies[name];
        }
      });
    });

    var header = '# Generated file - do not modify or commit this file.';
    var pubspecYaml = '$header\n${toYamlString(workspacePubspec)}';

    await File(utils.pubspecPathForDirectory(Directory(path)))
        .writeAsString(pubspecYaml);
  }
}