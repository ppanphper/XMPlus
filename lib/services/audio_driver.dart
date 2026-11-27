import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

import '../models/xmly_models.dart';
import 'app_log.dart';
import 'ios_audio_stream.dart';
import 'close_sequence.dart';

/// Device observations, not requested commands. Epoch rejects old-source events.
class AudioSnapshot {
  const AudioSnapshot({
    required this.epoch,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = 0,
    this.duration = 0,
    this.error,
    this.failure,
    this.stackTrace,
    this.failureRecorded = false,
  });
  final int epoch;
  final bool playing, buffering, completed;
  final double position, duration;
  final String? error;
  final Object? failure;
  final StackTrace? stackTrace;
  final bool failureRecorded;
}

/// The only sound-device boundary. Tests implement this with recorded commands.
abstract class AudioDriver {
  Stream<AudioSnapshot> get snapshots;
  Future<void> open(
    Uri localUri, {
    required int epoch,
    double startPosition = 0,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(double seconds);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  void beginTransition() {}
  Future<void> endTransition() async {}
  Future<void> close();
}

void requireLocalAudio(Uri uri) {
  AppLog.instance.trace("lib/services/audio_driver.dart::requireLocalAudio");

  if (uri.scheme == 'file' &&
      (uri.host.isEmpty || Platform.isWindows) &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      uri.hasAbsolutePath &&
      !uri.hasQuery &&
      !uri.hasFragment) {
    try {
      // Windows file hosts are UNC shares already supported by downloads.
      uri.toFilePath(windows: Platform.isWindows);
      return;
    } on UnsupportedError {
      // Malformed file URIs must not become a different native media resource.
    }
  }
  if (uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.hasPort &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment)
    return;
  if (Platform.isIOS && IosAudioStream.instance.contains(uri)) return;
  throw ArgumentError('播放器仅接受本机缓存或已下载文件');
}

/// Constructing this adapter never initializes media_kit or a sound device.
class MediaKitAudioDriver implements AudioDriver {
  Player? _player;
  int? _nativeHandle;
  Uri? _sourceUri;
  Object? _streamFailure;
  StackTrace? _streamFailureStack;
  bool _failureEmitted = false;
  final _events = StreamController<AudioSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _epoch = 0;
  bool _opening = false;
  bool _closed = false;
  AudioSession? _session;
  Future<void> _commands = Future<void>.value();
  late final _closeSteps = CloseSequence([
    () async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._closeSteps.closure#1",
      );

      _closed = true;
      _cancelResume();
      await _commands;
    },
    () async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._closeSteps.closure#2",
      );

      while (_subscriptions.isNotEmpty) {
        await _subscriptions.last.cancel();
        _subscriptions.removeLast();
      }
    },
    _releaseFocus,
    () async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._closeSteps.closure#3",
      );

      await _player?.dispose();
      _player = null;
      final handle = _nativeHandle;
      if (handle != null) {
        await IosAudioStream.instance.detach(handle);
        _nativeHandle = null;
      }
    },
    () async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._closeSteps.closure#4",
      );

      await _events.close();
    },
  ]);
  int _intent = 0;
  int? _resumeIntent;
  // Native state can still be playing while a pause/open command is queued.
  // Focus callbacks must respect the requested state from command admission.
  bool _playRequested = false;
  int _transitionDepth = 0;

  @override
  void beginTransition() {
    _transitionDepth++;
  }

  @override
  Future<void> endTransition() async {
    if (_transitionDepth == 0) return;
    _transitionDepth--;
    if (_transitionDepth == 0 && !_playRequested) await _releaseFocus();
  }
  @override
  Stream<AudioSnapshot> get snapshots {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.snapshots.get",
    );
    return _events.stream;
  }

  void _emit({
    String? error,
    Object? failure,
    StackTrace? stackTrace,
    bool failureRecorded = false,
  }) {
    AppLog.instance.trace(
      'lib/services/audio_driver.dart::MediaKitAudioDriver._emit',
    );
    final player = _player;
    if (player == null || _opening || _closed || _failureEmitted) return;
    final state = player.state;
    final failed = _streamFailure != null;
    // eof-reached may arrive before mpv's error log when output initialization
    // fails. A known-duration source has not completed while still at its start.
    final reachedEnd = state.duration > Duration.zero
        ? state.position >= state.duration - const Duration(seconds: 1)
        : state.position > Duration.zero;
    // mpv can report end-of-file after a fatal output/read error. Deliver the
    // fault once, then suppress source events until open creates a new epoch.
    // In particular pause's own snapshot must not recursively report the error.
    _failureEmitted = failed;
    _events.add(
      AudioSnapshot(
        epoch: _epoch,
        playing: !failed && state.playing,
        buffering: !failed && state.buffering,
        completed: !failed && state.completed && reachedEnd,
        position: state.position.inMicroseconds / 1000000,
        duration: state.duration.inMicroseconds / 1000000,
        error: error ?? (failed ? '音频播放失败，请重试' : null),
        failure: failure ?? _streamFailure,
        stackTrace: stackTrace ?? _streamFailureStack,
        failureRecorded: failureRecorded || failed,
      ),
    );
  }

  Player _create() {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._create",
    );

    if (_closed) throw StateError('播放器已关闭');
    MediaKit.ensureInitialized();
    // Independent pitch remains 1.0 while scaletempo changes playback rate.
    final player = Player(
      configuration: const PlayerConfiguration(pitch: true, title: 'XMPlus'),
    );
    _player = player;
    _subscriptions.addAll([
      player.stream.playing.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._create.closure#1",
        );
        _emit();
      }),
      player.stream.buffering.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._create.closure#2",
        );
        _emit();
      }),
      player.stream.position.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._create.closure#3",
        );
        _emit();
      }),
      player.stream.duration.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._create.closure#4",
        );
        _emit();
      }),
      player.stream.completed.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._create.closure#5",
        );
        _emit();
      }),
      player.stream.error.listen(_streamError, onError: _streamError),
    ]);
    return player;
  }

  void _streamError(Object error, [StackTrace? stack]) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._streamError",
    );

    if (_closed || error.toString().trim().isEmpty || _streamFailure != null)
      return;
    _cancelResume();
    final outputFailure = error.toString().contains(
      'open/initialize audio device',
    );
    _streamFailure =
        IosAudioStream.instance.failure(_sourceUri) ??
        (outputFailure
            ? const XmlyException('audio_output_failed', '无法启用音频输出')
            : const XmlyException('audio_decode_failed', '音频暂时无法播放'));
    _streamFailureStack = stack;
    AppLog.instance.write(
      AppLogLevel.error,
      'audio',
      'Audio stream failed',
      data: {
        'epoch': _epoch,
        'source': _sourceUri?.scheme,
        'stage': outputFailure ? 'audio_output' : 'decoder',
      },
      error: error,
      stackTrace: stack,
      promptUser: false,
    );
    _emit();
  }

  Future<void> _perform(
    String operation,
    Future<void> Function() action, [
    Map<String, Object?>? arguments,
  ]) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._perform",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._perform.closure#1",
      );

      if (AppLog.instance.level == AppLogLevel.debug) {
        AppLog.instance.write(
          AppLogLevel.debug,
          'audio',
          'Audio operation',
          data: {
            'operation': operation,
            'epoch': _epoch,
            'arguments': arguments,
          },
        );
      }
      try {
        await action();
        if (AppLog.instance.level == AppLogLevel.debug) {
          AppLog.instance.write(
            AppLogLevel.debug,
            'audio',
            'Audio operation result',
            data: {'operation': operation, 'epoch': _epoch, 'result': null},
          );
        }
      } catch (error, stack) {
        AppLog.instance.requestUploadPrompt();
        if (AppLog.instance.errorWasRecorded(error)) rethrow;
        AppLog.instance.write(
          AppLogLevel.error,
          'audio',
          'Audio operation failed',
          data: {
            'operation': operation,
            'epoch': _epoch,
            'arguments': arguments,
          },
          error: error,
          stackTrace: stack,
          promptUser: true,
        );
        rethrow;
      }
    });
  }

  // Serialize Android device/session operations, including disposal. The returned
  // future still reports command failures; only the queue tail handles its copy.
  Future<void> _run(
    Future<void> Function() action, {
    required String operation,
    Map<String, Object?>? arguments,
  }) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._run",
    );

    if (!Platform.isAndroid && !Platform.isIOS)
      return _perform(operation, action, arguments);
    final result = _commands.then((_) async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver._run.closure#1",
      );

      if (!_closed) await _perform(operation, action, arguments);
    });
    _commands = result.then<void>(
      (_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._run.closure#2",
        );
      },
      onError: (Object _, StackTrace __) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._run.closure#3",
        );
      },
    );
    return result;
  }

  int _cancelResume({bool playRequested = false}) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._cancelResume",
    );

    _playRequested = playRequested;
    _resumeIntent = null;
    return ++_intent;
  }

  bool _canPlay(int intent) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._canPlay",
    );
    return !_closed && _playRequested && intent == _intent;
  }

  void _event(String operation, Future<void> Function() action) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._event",
    );

    if (_closed) return;
    unawaited(
      _run(action, operation: operation).catchError((
        Object error,
        StackTrace stack,
      ) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._event.closure#1",
        );

        // _perform recorded the original failure before this friendly callback.
        _emit(
          error: '音频播放失败，请重试',
          failure: error,
          stackTrace: stack,
          failureRecorded: true,
        );
      }),
    );
  }

  Future<AudioSession> _audioSession() async {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._audioSession",
    );

    if (_session case final session?) return session;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    if (_closed) return session;
    _session = session;
    _subscriptions.addAll([
      session.interruptionEventStream.listen(_interrupt, onError: _streamError),
      session.becomingNoisyEventStream.listen((_) {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._audioSession.closure#1",
        );

        final intent = _cancelResume();
        _event('pause', () async {
          AppLog.instance.trace(
            "lib/services/audio_driver.dart::MediaKitAudioDriver._audioSession.closure#1.closure#1",
          );

          if (intent == _intent) await _pause();
        });
      }, onError: _streamError),
    ]);
    return session;
  }

  void _interrupt(AudioInterruptionEvent event) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._interrupt",
    );

    if (_closed) return;
    if (event.type == AudioInterruptionType.unknown) _playRequested = false;
    if (event.begin) {
      final resume =
          _playRequested &&
          event.type != AudioInterruptionType.unknown &&
          (_player?.state.playing == true || _resumeIntent != null);
      final intent = ++_intent;
      _resumeIntent = resume ? intent : null;
      _event('pause', () async {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver._interrupt.closure#1",
        );

        if (intent != _intent) return;
        await _player?.pause();
        _emit();
        // Keep transient focus requests registered so Android can send gain.
        if (event.type == AudioInterruptionType.unknown) await _releaseFocus();
      });
    } else {
      final intent = _resumeIntent;
      _resumeIntent = null;
      if (event.type != AudioInterruptionType.unknown && intent != null) {
        _event('play', () {
          AppLog.instance.trace(
            "lib/services/audio_driver.dart::MediaKitAudioDriver._interrupt.closure#2",
          );
          return _play(intent);
        });
      }
    }
  }

  Future<void> _releaseFocus() async {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._releaseFocus",
    );

    if (_transitionDepth == 0) await _session?.setActive(false);
  }

  Future<void> _play(int intent) async {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._play",
    );

    final player = _player;
    if (player == null || !_canPlay(intent)) return;
    final failure = _streamFailure;
    if (failure != null)
      Error.throwWithStackTrace(
        failure,
        _streamFailureStack ?? StackTrace.current,
      );
    if (Platform.isAndroid || Platform.isIOS) {
      final session = await _audioSession();
      if (!_canPlay(intent)) return;
      final granted = await session.setActive(true);
      if (!granted) {
        await player.pause();
        throw StateError('无法获取音频焦点，请稍后重试');
      }
      if (!_canPlay(intent)) return;
    }
    await player.play();
    if ((Platform.isAndroid || Platform.isIOS) && !_canPlay(intent)) {
      await player.pause();
    }
  }

  Future<void> _pause() async {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver._pause",
    );

    try {
      await _player?.pause();
      _emit();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> open(
    Uri localUri, {
    required int epoch,
    double startPosition = 0,
  }) async {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.open",
    );

    requireLocalAudio(localUri);
    // media_kit's file URI sanitizer can turn a named UNC host into a local
    // directory. Give it the native file path to preserve the share and escapes.
    final resource = localUri.scheme == 'file'
        ? localUri.toFilePath(windows: Platform.isWindows)
        : localUri.toString();
    _cancelResume();
    await _run(
      () async {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver.open.closure#1",
        );

        _opening = true;
        try {
          if (Platform.isIOS) await _audioSession();
          final player = _player ?? _create();
          await player.stop();
          await _releaseFocus();
          _epoch = epoch;
          _streamFailure = null;
          _streamFailureStack = null;
          _failureEmitted = false;
          _sourceUri = localUri;
          if (localUri.scheme == IosAudioStream.scheme) {
            IosAudioStream.instance.clearFailure(localUri);
            final handle = await player.handle;
            await IosAudioStream.instance.attach(handle);
            _nativeHandle = handle;
          }
          if (localUri.scheme == 'http') {
            // The local cache owns upstream timeouts/retries. mpv's default
            // five-second timeout must not abort buffering before it finishes.
            await (player.platform as NativePlayer).setProperty(
              'network-timeout',
              '0',
            );
          }
          // open completes before mpv finishes loading. Media.start is applied
          // by its load hook; an immediate standalone seek can be lost.
          final media = Media(
            resource,
            start: Duration(microseconds: (startPosition * 1000000).round()),
          );
          if (localUri.scheme == IosAudioStream.scheme) {
            // media_kit.open loads a temporary playlist; mpv deliberately rejects
            // custom protocols from playlists. add uses direct loadfile and
            // retains Media.start hooks, without enabling unsafe playlists.
            await player.open(Playlist(const []), play: false);
            await player.add(media);
            await (player.platform as NativePlayer).setProperty(
              'playlist-pos',
              '0',
            );
          } else {
            await player.open(media, play: false);
          }
          await player.setPitch(1.0);
        } finally {
          _opening = false;
        }
        _emit();
      },
      operation: 'open',
      arguments: AppLog.instance.level == AppLogLevel.debug
          ? {
              'uri': localUri.toString(),
              'epoch': epoch,
              'startPosition': startPosition,
            }
          : null,
    );
  }

  @override
  Future<void> play() {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.play",
    );

    final intent = _cancelResume(playRequested: true);
    return _run(() {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver.play.closure#1",
      );
      return _play(intent);
    }, operation: 'play');
  }

  @override
  Future<void> pause() {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.pause",
    );

    _cancelResume();
    return _run(_pause, operation: 'pause');
  }

  @override
  Future<void> stop() {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.stop",
    );

    _cancelResume();
    return _run(() async {
      AppLog.instance.trace(
        "lib/services/audio_driver.dart::MediaKitAudioDriver.stop.closure#1",
      );

      try {
        await _player?.stop();
        _emit();
      } finally {
        await _releaseFocus();
      }
    }, operation: 'stop');
  }

  @override
  Future<void> seek(double seconds) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.seek",
    );
    return _run(
      () async {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver.seek.closure#1",
        );

        await _player?.seek(
          Duration(microseconds: (seconds * 1000000).round()),
        );
      },
      operation: 'seek',
      arguments: AppLog.instance.level == AppLogLevel.debug
          ? {'seconds': seconds}
          : null,
    );
  }

  @override
  Future<void> setRate(double rate) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.setRate",
    );
    return _run(
      () async {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver.setRate.closure#1",
        );

        await _player?.setRate(rate);
      },
      operation: 'setRate',
      arguments: AppLog.instance.level == AppLogLevel.debug
          ? {'rate': rate}
          : null,
    );
  }

  @override
  Future<void> setVolume(double volume) {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.setVolume",
    );
    return _run(
      () async {
        AppLog.instance.trace(
          "lib/services/audio_driver.dart::MediaKitAudioDriver.setVolume.closure#1",
        );

        await _player?.setVolume(volume);
      },
      operation: 'setVolume',
      arguments: AppLog.instance.level == AppLogLevel.debug
          ? {'volume': volume}
          : null,
    );
  }

  @override
  Future<void> close() {
    AppLog.instance.trace(
      "lib/services/audio_driver.dart::MediaKitAudioDriver.close",
    );
    return _perform('close', _closeSteps.run);
  }
}
