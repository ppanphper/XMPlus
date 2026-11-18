import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:ffmpeg_kit_flutter_new_audio/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/log.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../models/xmly_models.dart';
import 'app_log.dart';
import 'ios_platform.dart';

/// Runs the existing media pipeline inside the app, with per-session cancellation.
Future<String> runIosMedia({
  required bool probe,
  required List<String> arguments,
  required Duration timeout,
  Future<void> Function()? checkpoint,
}) async {
  AppLog.instance.trace('lib/services/ios_media_runner.dart::runIosMedia');
  await checkpoint?.call();
  final work = await IosPlatform.beginWork();
  final completed = Completer<AbstractSession>();
  final started = Completer<AbstractSession?>();
  Directory? captureDirectory;
  File? capturedOutput;
  final command = List<String>.of(arguments);
  Object? stopped;
  StackTrace? stoppedStack;
  var bytes = 0;
  const limit = 2 * 1024 * 1024;
  Future<void> cancel(Object error, StackTrace stack) async {
    AppLog.instance.trace(
      "lib/services/ios_media_runner.dart::runIosMedia.cancel",
    );

    stopped ??= error;
    stoppedStack ??= stack;
    final session = await started.future;
    final id = session?.getSessionId();
    if (id != null) await FFmpegKit.cancel(id);
  }

  void log(Log entry) {
    AppLog.instance.trace(
      "lib/services/ios_media_runner.dart::runIosMedia.log",
    );

    bytes += utf8.encode(entry.getMessage()).length;
    if (bytes > limit && stopped == null) {
      unawaited(
        cancel(
          const XmlyException('media_output_limit', '媒体工具输出异常，源文件已保留'),
          StackTrace.current,
        ),
      );
    }
  }

  final expiration = IosPlatform.expiredWork.listen((id) {
    AppLog.instance.trace(
      "lib/services/ios_media_runner.dart::runIosMedia.closure#1",
    );

    if (id == work)
      unawaited(
        cancel(
          const XmlyException(
            'media_background_expired',
            '系统后台处理时间已到，源缓存已保留，请返回应用继续',
          ),
          StackTrace.current,
        ),
      );
  });
  Timer? timer;
  try {
    // FFmpeg's muxer stdout is not a log stream in the in-process library.
    if (!probe &&
        command.length > 2 &&
        command.last == '-' &&
        command.contains('hash')) {
      captureDirectory = await (await getTemporaryDirectory()).createTemp(
        'xmplus-media-output-',
      );
      capturedOutput = File(p.join(captureDirectory.path, 'output'));
      command[command.length - 1] = capturedOutput.path;
    }
    final session = probe
        ? await FFprobeKit.executeWithArgumentsAsync(
            command,
            completed.complete,
            log,
          )
        : await FFmpegKit.executeWithArgumentsAsync(
            command,
            completed.complete,
            log,
          );
    started.complete(session);
    await IosPlatform.channel.invokeMethod<void>('bindMediaSession', {
      'id': work,
      'session': session.getSessionId(),
    });
    timer = Timer(timeout, () {
      AppLog.instance.trace(
        "lib/services/ios_media_runner.dart::runIosMedia.closure#2",
      );

      unawaited(
        cancel(
          const XmlyException('media_timeout', '媒体处理超时，源文件已保留'),
          StackTrace.current,
        ),
      );
    });
    while (!completed.isCompleted) {
      await Future.any([
        completed.future,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
      if (!completed.isCompleted && stopped == null) {
        try {
          await checkpoint?.call();
        } catch (error, stack) {
          await cancel(error, stack);
        }
      }
    }
    final result = await completed.future;
    if (stopped != null) Error.throwWithStackTrace(stopped!, stoppedStack!);
    if (!ReturnCode.isSuccess(await result.getReturnCode())) {
      throw const XmlyException('media_process', '媒体处理失败，源缓存已保留，请检查输出格式');
    }
    final output = capturedOutput != null
        ? await capturedOutput.readAsString()
        : await result.getOutput() ?? '';
    if (utf8.encode(output).length > limit)
      throw const XmlyException('media_output_limit', '媒体工具输出异常，源文件已保留');
    return output;
  } finally {
    if (!started.isCompleted) started.complete(null);
    if (captureDirectory != null)
      await captureDirectory.delete(recursive: true);
    timer?.cancel();
    await expiration.cancel();
    await IosPlatform.endWork(work);
  }
}
