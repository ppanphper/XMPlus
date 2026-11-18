import 'package:path/path.dart' as p;

import '../storage/app_storage.dart';
import 'ios_platform.dart';
import 'app_log.dart';

/// iOS may relocate the app container during an update. Only paths owned by this
/// installation or by an explicitly granted directory are rewritten by native.
Future<void> restoreIosStoragePaths(AppStorage storage) async {
  AppLog.instance.trace(
    'lib/services/ios_storage.dart::restoreIosStoragePaths',
  );
  const keys = {
    'rootDirectory',
    'finalPath',
    'root',
    'downloadRoot',
    'downloadDirectory',
    'coverPath',
  };
  final replacements = <String, String>{};
  final checked = <String>{};
  Future<void> collect(Object? value) async {
    AppLog.instance.trace(
      "lib/services/ios_storage.dart::restoreIosStoragePaths.collect",
    );

    if (value is Map) {
      for (final entry in value.entries) {
        final item = entry.value;
        if (keys.contains(entry.key) &&
            item is String &&
            p.isAbsolute(item) &&
            checked.add(item)) {
          final resolved = await IosPlatform.resolvePath(item);
          if (resolved != item) replacements[item] = resolved;
        } else if (item is Map || item is List) {
          await collect(item);
        }
      }
    } else if (value is List) {
      for (final item in value) {
        await collect(item);
      }
    }
  }

  await collect(storage.state);
  if (replacements.isEmpty) return;
  void apply(Object? value) {
    AppLog.instance.trace(
      "lib/services/ios_storage.dart::restoreIosStoragePaths.apply",
    );

    if (value is Map) {
      for (final key in value.keys.toList()) {
        final item = value[key];
        if (keys.contains(key) &&
            item is String &&
            replacements.containsKey(item)) {
          value[key] = replacements[item];
        } else {
          apply(item);
        }
      }
    } else if (value is List) {
      for (final item in value) {
        apply(item);
      }
    }
  }

  await storage.transaction((state) {
    AppLog.instance.trace(
      "lib/services/ios_storage.dart::restoreIosStoragePaths.closure#1",
    );
    apply(state);
  });
}
