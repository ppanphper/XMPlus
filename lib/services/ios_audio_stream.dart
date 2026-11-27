import 'dart:async';
import 'dart:math';

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
  final _reads = <String, _CacheRead>{};
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
    cache.attachPlayback();
    return uri;
  }

  Future<void> unmount(Uri uri) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream.unmount',
    );
    final key = uri.toString();
    _mounts.remove(key)?.detachPlayback();
    _failures.remove(key);
    await Future.wait<void>([
      for (final read in _reads.values)
        if (read.uri == key) read.cancel(),
      _channel.invokeMethod<void>('unmount', {'uri': key}),
    ]);
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
      _generations.remove(id);
      await _reads[id]?.cancel();
      return null;
    }
    if (call.method != 'read') throw MissingPluginException();
    final uri = args['uri'] as String;
    final cache = _mounts[uri];
    final read = _CacheRead(uri);
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
      _reads[id] = read;
      return await _read(read, cache, id, offset, count);
    } catch (error, stack) {
      final cancelled =
          read.cancelled ||
          !_mounts.containsKey(uri) ||
          cache?.closed == true ||
          error is XmlyException && error.code == 'cache_closed';
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
      if (identical(_reads[id], read)) _reads.remove(id);
    }
  }

  Future<Object?> _read(
    _CacheRead read,
    AudioCache cache,
    String id,
    int offset,
    int count,
  ) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::IosAudioStream._read',
    );
    final generation = _generations[id];
    void checkActive() {
      AppLog.instance.trace(
        'lib/services/ios_audio_stream.dart::IosAudioStream._read.checkActive',
      );
      if (read.cancelled || cache.closed) {
        throw const XmlyException('cache_closed', '音频读取已取消');
      }
      if (generation != null && generation != cache.generation) {
        throw const XmlyException('cache_source_changed', '音频来源已变化');
      }
    }

    Stopwatch? waited;
    var attempts = 0, backoffMs = 500;
    while (true) {
      checkActive();
      final List<int> chunk;
      try {
        chunk = await read.nextChunk(cache, offset);
      } catch (error) {
        checkActive();
        if (!isAudioNetworkFailure(error) &&
            !(error is XmlyException && error.code == 'cache_paused')) {
          rethrow;
        }
        if (waited == null) {
          waited = Stopwatch()..start();
          AppLog.instance.write(
            AppLogLevel.warning,
            'audio_stream',
            'Audio cache read waiting',
            data: {
              'offset': offset,
              'code': error is XmlyException
                  ? error.code
                  : error.runtimeType.toString(),
            },
          );
        }
        attempts++;
        final delay = Duration(milliseconds: backoffMs);
        final retryAfter = error is XmlyException && error.code == 'rate_limited'
            ? error.retryAfter
            : null;
        await read.wait(
          retryAfter != null && retryAfter > delay ? retryAfter : delay,
        );
        backoffMs = min(15000, backoffMs * 2);
        continue;
      }
      checkActive();
      _generations[id] = cache.generation;
      if (waited != null) {
        AppLog.instance.write(
          AppLogLevel.info,
          'audio_stream',
          'Audio cache read resumed',
          data: {'waitedMs': waited.elapsedMilliseconds, 'attempts': attempts},
        );
      }
      final bytes = Uint8List.fromList(
        chunk.length > count ? chunk.sublist(0, count) : chunk,
      );
      return {'bytes': bytes, 'length': cache.length};
    }
  }
}

/// One decoder read retains its slot across retries, but not its subscription.
class _CacheRead {
  _CacheRead(this.uri) {
    AppLog.instance.trace('lib/services/ios_audio_stream.dart::_CacheRead.new');
  }
  final String uri;
  bool cancelled = false;
  StreamIterator<List<int>>? _reader;
  Completer<void>? _waiting;

  Future<List<int>> nextChunk(AudioCache cache, int offset) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::_CacheRead.nextChunk',
    );
    // A short read is sufficient; do not wait for a full decoder buffer.
    final reader = _reader = StreamIterator(cache.stream(offset));
    try {
      return await reader.moveNext() ? reader.current : const <int>[];
    } finally {
      await reader.cancel();
      _reader = null;
    }
  }

  Future<void> wait(Duration delay) async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::_CacheRead.wait',
    );
    if (cancelled) return;
    final ready = _waiting = Completer<void>();
    final timer = Timer(delay, ready.complete);
    try {
      await ready.future;
    } finally {
      timer.cancel();
      _waiting = null;
    }
  }

  Future<void> cancel() async {
    AppLog.instance.trace(
      'lib/services/ios_audio_stream.dart::_CacheRead.cancel',
    );
    cancelled = true;
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    await _reader?.cancel();
  }
}
