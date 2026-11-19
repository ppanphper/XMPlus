import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import 'app_log.dart';
import 'audio_cache.dart';

/// iOS libmpv reads the same cache as downloads without a listening socket.
/// Native decoder threads wait for these asynchronous, cancellable reads.
class IosAudioStream {
  static final instance = IosAudioStream();
  static const scheme = 'xmpluscache';
  static const _channel = MethodChannel('teikengstudio.xmplus/audio-stream');
  final _mounts = <String, AudioCache>{};
  final _reads = <String, StreamIterator<List<int>>>{};
  final _generations = <String, int>{};
  final _failures = <String, Object>{};
  bool _registered = false;

  void _register() {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream._register',
    );
    if (_registered) return;
    _channel.setMethodCallHandler(_handle);
    _registered = true;
  }

  bool contains(Uri uri) {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.contains',
    );
    return _mounts.containsKey(uri.toString());
  }

  Future<Uri> mount(AudioCache cache) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.mount',
    );
    _register();
    final uri = Uri(scheme: scheme, host: const Uuid().v4());
    final key = uri.toString();
    _mounts[key] = cache;
    try {
      await _channel.invokeMethod<void>('mount', {'uri': key});
    } catch (_) {
      _mounts.remove(key);
      rethrow;
    }
    return uri;
  }

  Future<void> unmount(Uri uri) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.unmount',
    );
    final key = uri.toString();
    _mounts.remove(key);
    _failures.remove(key);
    // Native cancellation releases pending decoder reads before cache disposal.
    await _channel.invokeMethod<void>('unmount', {'uri': key});
  }

  Future<void> attach(int handle) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.attach',
    );
    _register();
    try {
      await _channel.invokeMethod<void>('attach', {'handle': handle});
    } on PlatformException catch (error, stack) {
      final failure = XmlyException('audio_stream_unavailable', '音频读取初始化失败');
      AppLog.instance.linkError(failure, error);
      Error.throwWithStackTrace(failure, stack);
    }
  }

  Future<void> detach(int handle) {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.detach',
    );
    // Only after player.dispose: registrations belong to the mpv core lifetime.
    return _channel.invokeMethod<void>('detach', {'handle': handle});
  }

  Object? failure(Uri? uri) {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.failure',
    );
    return _failures[uri?.toString()];
  }

  void clearFailure(Uri uri) {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.clearFailure',
    );
    _failures.remove(uri.toString());
  }

  Future<Object?> _handle(MethodCall call) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream._handle',
    );
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final id = args['id'] as String;
    if (call.method == 'cancel' || call.method == 'closed') {
      await _reads.remove(id)?.cancel();
      _generations.remove(id);
      return null;
    }
    if (call.method != 'read') throw MissingPluginException();
    final uri = args['uri'] as String;
    final cache = _mounts[uri];
    StreamIterator<List<int>>? reader;
    try {
      if (cache == null) throw const XmlyException('cache_closed', '音频已关闭');
      final offset = args['offset'] as int;
      final count = args['count'] as int;
      if (offset < 0 ||
          count <= 0 ||
          count > 256 * 1024 ||
          _reads.containsKey(id)) {
        throw const XmlyException('cache_range', '音频读取范围无效');
      }
      final generation = _generations[id];
      if (generation != null && generation != cache.generation) {
        throw const XmlyException('cache_source_changed', '音频来源已变化');
      }
      // Short reads are intentional. Do not wait for a full decoder buffer, or
      // request beyond an unknown EOF. AudioCache already yields <= 64 KiB.
      reader = StreamIterator(cache.stream(offset));
      _reads[id] = reader;
      final available = await reader.moveNext();
      if (!identical(_reads[id], reader) || !identical(_mounts[uri], cache)) {
        throw const XmlyException('cache_closed', '音频读取已取消');
      }
      if (generation != null && generation != cache.generation) {
        throw const XmlyException('cache_source_changed', '音频来源已变化');
      }
      _generations[id] = cache.generation;
      final chunk = available ? reader.current : const <int>[];
      final bytes = Uint8List.fromList(
        chunk.length > count ? chunk.sublist(0, count) : chunk,
      );
      return {'bytes': bytes, 'length': cache.length};
    } catch (error, stack) {
      final cancelled =
          !_mounts.containsKey(uri) ||
          (error is XmlyException &&
              const {'cache_closed', 'cache_paused'}.contains(error.code));
      if (!cancelled) {
        _failures[uri] = error;
        AppLog.instance.write(
          AppLogLevel.error,
          'audio_stream',
          'Audio cache read failed',
          data: {
            'stage': 'cache_read',
            'offset': args['offset'],
            'count': args['count'],
          },
          error: error,
          stackTrace: stack,
        );
      }
      throw PlatformException(
        code: cancelled ? 'cancelled' : 'audio_read',
        message: '音频读取未完成',
      );
    } finally {
      if (identical(_reads[id], reader)) _reads.remove(id);
      await reader?.cancel();
    }
  }
}
