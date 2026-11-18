import 'dart:io';

import 'package:path/path.dart' as p;

import "app_log.dart";
import "ios_platform.dart";

/// Preserve the Windows share prefix before package:path normalizes separators.
String absoluteFilePath(String value) {
  AppLog.instance.trace("lib/services/file_paths.dart::absoluteFilePath");
  return p.normalize(
    p.absolute(Platform.isWindows ? value.replaceAll('/', r'\') : value),
  );
}

/// Keep profile isolation while removing the replaceable iOS container prefix.
String profileDirectoryIdentity(String directory) {
  AppLog.instance.trace(
    'lib/services/file_paths.dart::profileDirectoryIdentity',
  );
  return Platform.isIOS
      ? IosPlatform.profileDirectoryIdentity(directory)
      : directory;
}
