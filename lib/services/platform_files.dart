import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'app_log.dart';
import 'ios_platform.dart';

Future<String?> pickApplicationDirectory({String? dialogTitle}) {
  AppLog.instance.trace(
    'lib/services/platform_files.dart::pickApplicationDirectory',
  );
  return Platform.isIOS
      ? IosPlatform.pickDirectory(dialogTitle: dialogTitle)
      : FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
}
