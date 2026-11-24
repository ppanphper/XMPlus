import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';

/// Only the iOS adapter owns document permissions and background URL sessions.
class IosPlatform {
  static const channel = MethodChannel('teikengstudio.xmplus/ios');
  static List<String> _containerHomes = const [];
  static final _expired = StreamController<String>.broadcast();

  static Future<String> rewardUserAgent() {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.rewardUserAgent',
    );
    return InAppWebViewController.getDefaultUserAgent();
  }

  static Stream<String> get expiredWork {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosPlatform.expiredWork.get",
    );
    return _expired.stream;
  }

  static Future<void> initialize() async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.initialize',
    );
    channel.setMethodCallHandler((call) async {
      AppLog.instance.trace(
        "lib/services/ios_platform.dart::IosPlatform.initialize.closure#1",
      );

      if (call.method == 'backgroundWorkExpired') {
        _expired.add(call.arguments as String);
      }
    });
    final info = await channel.invokeMapMethod<String, dynamic>('initialize');
    _containerHomes =
        (info?['currentHomes'] as List?)?.cast<String>() ?? const [];
    if (_containerHomes.isEmpty) throw StateError('iOS 容器信息未初始化');
  }

  static String profileDirectoryIdentity(String directory) {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.profileDirectoryIdentity',
    );
    if (_containerHomes.isEmpty) throw StateError('iOS 容器信息未初始化');
    for (final home in _containerHomes) {
      if (directory == home || p.isWithin(home, directory)) {
        return 'ios-container/${p.relative(directory, from: home)}';
      }
    }
    return directory;
  }

  static Future<String?> pickDirectory({String? dialogTitle}) {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.pickDirectory',
    );
    return channel.invokeMethod<String>('pickDirectory');
  }

  static Future<void> commitFile(
    String source,
    String target, {
    required bool overwrite,
  }) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.commitFile',
    );
    await channel.invokeMethod<void>('commitFile', {
      'source': source,
      'target': target,
      'overwrite': overwrite,
    });
  }

  static Future<int> availableBytes(String path) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.availableBytes',
    );
    final value = await channel.invokeMethod<int>('availableBytes', {
      'path': path,
    });
    if (value == null || value < 0) throw const FileSystemException('无法查询可用空间');
    return value;
  }

  static Future<String> resolvePath(String path) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.resolvePath',
    );
    return await channel.invokeMethod<String>('resolvePath', {'path': path}) ??
        path;
  }

  static Future<void> openAudioFile(String path) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.openAudioFile',
    );
    await channel.invokeMethod<void>('shareFile', {'path': path});
  }

  static Future<Uri?> exportFile(String path) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.exportFile',
    );
    final result = await channel.invokeMethod<String>('exportFile', {
      'path': path,
    });
    return result == null ? null : Uri.file(result);
  }

  static Future<Uri?> exportLogSnapshot(
    LogSnapshot snapshot,
    String name,
  ) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.exportLogSnapshot',
    );
    final root = await getTemporaryDirectory();
    final directory = await Directory(p.join(root.path, 'log-export'))
        .createTemp();
    final file = File(p.join(directory.path, name));
    try {
      final sink = file.openWrite();
      try {
        await sink.addStream(snapshot.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      return await exportFile(file.path);
    } finally {
      await directory.delete(recursive: true);
    }
  }

  static Future<String> beginWork() async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.beginWork',
    );
    final id = const Uuid().v4();
    await channel.invokeMethod<void>('beginWork', {'id': id});
    return id;
  }

  static Future<void> endWork(String id) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.endWork',
    );
    await channel.invokeMethod<void>('endWork', {'id': id});
  }

  static Future<HttpClientResponse> download({
    required String id,
    required Uri uri,
    required Map<String, dynamic> headers,
    required Uri Function(Uri) validateFinalUri,
  }) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.download',
    );
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'download',
        {'id': id, 'url': uri.toString(), 'headers': headers},
      );
      if (result == null) throw const HttpException('下载未返回结果');
      try {
        validateFinalUri(Uri.parse(result['url'] as String));
      } catch (_) {
        await releaseDownload(id);
        rethrow;
      }
      return IosAudioResponse(id, result);
    } on PlatformException catch (error) {
      throw HttpException(
        'Connection closed: ${error.message ?? error.code}',
        uri: uri,
      );
    }
  }

  static Future<void> cancelDownload(String id) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.cancelDownload',
    );
    await channel.invokeMethod<void>('cancelDownload', {'id': id});
  }

  static Future<void> releaseDownload(String id) async {
    AppLog.instance.trace(
      'lib/services/ios_platform.dart::IosPlatform.releaseDownload',
    );
    await channel.invokeMethod<void>('releaseDownload', {'id': id});
  }
}

class _IosHeaders implements HttpHeaders {
  _IosHeaders(Map values)
    : _values = {
        for (final entry in values.entries)
          '${entry.key}'.toLowerCase(): '${entry.value}',
      } {
    AppLog.instance.trace("lib/services/ios_platform.dart::_IosHeaders.new");
  }
  final Map<String, String> _values;
  @override
  String? value(String name) {
    AppLog.instance.trace("lib/services/ios_platform.dart::_IosHeaders.value");
    return _values[name.toLowerCase()];
  }

  @override
  List<String>? operator [](String name) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::_IosHeaders.operator[]",
    );
    return value(name) == null ? null : [value(name)!];
  }

  @override
  void forEach(void Function(String, List<String>) action) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::_IosHeaders.forEach",
    );

    _values.forEach((key, value) {
      AppLog.instance.trace(
        "lib/services/ios_platform.dart::_IosHeaders.forEach.closure#1",
      );
      return action(key, [value]);
    });
  }

  @override
  ContentType? get contentType {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::_IosHeaders.contentType.get",
    );

    final raw = value(HttpHeaders.contentTypeHeader);
    if (raw == null) return null;
    try {
      return ContentType.parse(raw);
    } on FormatException {
      return null;
    }
  }

  @override
  int get contentLength {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::_IosHeaders.contentLength.get",
    );
    return int.tryParse(value(HttpHeaders.contentLengthHeader) ?? '') ?? -1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::_IosHeaders.noSuchMethod",
    );
    return super.noSuchMethod(invocation);
  }
}

class IosAudioResponse extends Stream<List<int>> implements HttpClientResponse {
  IosAudioResponse(this.id, Map<String, dynamic> result)
    : statusCode = result['status'] as int,
      headers = _IosHeaders(result['headers'] as Map),
      _file = File(result['path'] as String) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse.new",
    );
  }
  final String id;
  final File _file;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  int get contentLength {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse.contentLength.get",
    );
    return headers.contentLength;
  }

  @override
  HttpClientResponseCompressionState get compressionState {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse.compressionState.get",
    );
    return HttpClientResponseCompressionState.notCompressed;
  }

  Stream<List<int>> _bytes() async* {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse._bytes",
    );

    try {
      yield* _file.openRead();
    } finally {
      await IosPlatform.releaseDownload(id);
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse.listen",
    );

    return _bytes().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    AppLog.instance.trace(
      "lib/services/ios_platform.dart::IosAudioResponse.noSuchMethod",
    );
    return super.noSuchMethod(invocation);
  }
}
