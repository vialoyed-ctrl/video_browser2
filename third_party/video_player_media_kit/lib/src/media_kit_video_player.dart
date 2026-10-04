/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2023 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as vpi;

// https://github.com/dart-lang/linter/issues/1381
// ignore_for_file: close_sinks

/// package:media_kit implementation of [VideoPlayerPlatform].
///
/// References:
/// * https://pub.dev/packages/media_kit
/// * https://github.com/media-kit/media-kit
///
class MediaKitVideoPlayer extends VideoPlayerPlatform {
  // The implementation uses [Player.hashCode] as texture ID.
  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();
  final _pendingSeeks = HashMap<int, _PendingSeek>();
  final _activeSeekDrains = <int>{};

  /// Registers this class as the default instance of [VideoPlayerPlatform].
  static void registerWith() {
    VideoPlayerPlatform.instance = MediaKitVideoPlayer();
  }

  /// Initializes the platform interface and disposes all existing players.
  ///
  /// This method is called when the plugin is first initialized and on every full restart.
  @override
  Future<void> init() async {
    for (final textureId in _players.keys) {
      await dispose(textureId);
    }

    _players.clear();
    _videoControllers.clear();
    _streamControllers.clear();
    _streamSubscriptions.clear();
  }

  /// Clears one video.
  @override
  Future<void> dispose(int textureId) async {
    final pendingSeek = _pendingSeeks.remove(textureId);
    if (pendingSeek != null) {
      for (final waiter in pendingSeek.waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('Video player was disposed'));
        }
      }
    }
    await _players[textureId]?.dispose();

    await _streamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );

    _players.remove(textureId);
    _videoControllers.remove(textureId);
    _streamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
    _activeSeekDrains.remove(textureId);
  }

  /// Creates an instance of a video player and returns its textureId.
  @override
  Future<int?> create(DataSource dataSource) async {
    final player = Player(
      // 32 MiB matches media_kit's default demuxer limit. Larger per-player
      // buffers made long 1080p streams read far ahead and compete with seeks.
      configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
    );
    final completer = Completer();
    final videoController = VideoController(player);
    // VideoController creates its native surface in a post-frame callback.
    // Pre-opening from a touch event also needs a frame when the UI is idle.
    WidgetsBinding.instance.scheduleFrame();
    // NOTE: [StreamController] without broadcast buffers events.
    final streamController = StreamController<VideoEvent>();
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _videoControllers[textureId] = videoController;
    _streamControllers[textureId] = streamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    // --------------------------------------------------
    _initialize(textureId);
    // --------------------------------------------------

    final String resource;
    final Map<String, String> httpHeaders = dataSource.httpHeaders;

    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        final String? asset;
        if (dataSource.package == null) {
          asset = dataSource.asset;
        } else {
          asset = 'packages/${dataSource.package}/${dataSource.asset}';
        }
        resource = 'asset:///$asset';
        break;

      case DataSourceType.network:
      case DataSourceType.file:
      case DataSourceType.contentUri:
        if (dataSource.uri == null) {
          throw ArgumentError('uri must not be null');
        }
        resource = dataSource.uri!;
        break;

      default:
        throw UnsupportedError('${dataSource.sourceType} is not supported');
    }

    final native = player.platform;
    if (native is NativePlayer) {
      // Keep useful forward/backward packets, but never wait for a large
      // startup buffer. Cached seeks stay inside the demuxer whenever possible.
      for (final option in const {
        'cache': 'yes',
        // Keep enough look-ahead to smooth playback without pulling minutes of
        // high-bitrate video ahead of the playhead on mobile networks.
        'cache-secs': '30',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '0.25',
        'demuxer-seekable-cache': 'yes',
        'demuxer-max-back-bytes': '33554432',
        'hr-seek': 'yes',
        'hr-seek-framedrop': 'yes',
      }.entries) {
        await native.setProperty(option.key, option.value);
      }
    }

    await player.open(
      Media(
        resource,
        httpHeaders: httpHeaders,
      ),
      play: false,
    );

    return textureId;
  }

  /// Returns a Stream of [VideoEventType]s.
  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    if (_streamControllers[textureId] == null) {
      throw StateError(
          'VideoPlayer for textureId $textureId is not found, Check if its disposed.');
    }
    return _streamControllers[textureId]!.stream;
  }

  /// Sets the looping attribute of the video.
  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final playlistMode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(playlistMode);
  }

  /// Starts the video playback.
  @override
  Future<void> play(int textureId) async {
    return _players[textureId]?.play();
  }

  /// Stops the video playback.
  @override
  Future<void> pause(int textureId) async {
    return _players[textureId]?.pause();
  }

  /// Sets the volume to a range between 0.0 and 1.0.
  @override
  Future<void> setVolume(int textureId, double volume) async {
    // NOTE: [volume] is in the range of 0.0 to 1.0 while [setVolume] expects 0.0 to 100.
    return _players[textureId]?.setVolume(volume * 100);
  }

  /// Sets the video position to a [Duration] from the start.
  @override
  Future<void> seekTo(int textureId, Duration position) async {
    final player = _players[textureId];
    if (player == null) return;

    final waiter = Completer<void>();
    final pending = _pendingSeeks.putIfAbsent(
      textureId,
      () => _PendingSeek(position),
    );
    pending.position = position;
    pending.waiters.add(waiter);
    if (_activeSeekDrains.add(textureId)) {
      unawaited(_drainSeekQueue(textureId, player));
    }
    return waiter.future;
  }

  /// Fold fast scrub updates into a single pending command so stale seeks do
  /// not queue ahead of the user's final target in libmpv's command lock.
  Future<void> _drainSeekQueue(int textureId, Player player) async {
    try {
      while (true) {
        final pending = _pendingSeeks.remove(textureId);
        if (pending == null) break;
        try {
          await player.seek(pending.position);
          for (final waiter in pending.waiters) {
            if (!waiter.isCompleted) waiter.complete();
          }
        } catch (error, stack) {
          for (final waiter in pending.waiters) {
            if (!waiter.isCompleted) waiter.completeError(error, stack);
          }
        }
      }
    } finally {
      _activeSeekDrains.remove(textureId);
      // A seek can arrive between the last empty check and clearing the drain
      // flag. Reclaim it here instead of leaving a waiter parked forever.
      if (_pendingSeeks.containsKey(textureId) &&
          _activeSeekDrains.add(textureId)) {
        unawaited(_drainSeekQueue(textureId, player));
      }
    }
  }

  /// Sets the playback speed to a [speed] value indicating the playback rate.
  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {
    return _players[textureId]?.setRate(speed);
  }

  /// Gets the video position as [Duration] from the start.
  @override
  Future<Duration> getPosition(int textureId) async {
    return _players[textureId]?.platform?.state.position ?? Duration.zero;
  }

  /// Returns a widget displaying the video with a given textureId.
  @override
  Widget buildView(int textureId) {
    if (_videoControllers[textureId] == null) {
      throw StateError(
          'VideoPlayer for textureId $textureId is not found, Check if its disposed.');
    }
    return Video(
      key: ValueKey(_videoControllers[textureId]!),
      controller: _videoControllers[textureId]!,
      wakelock: false,
      controls: NoVideoControls,
      fill: const Color(0x00000000),
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }

  /// Sets the audio mode to mix with other sources.
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future.value();

  /// Sets additional options on web.
  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) =>
      Future.value();

  @override
  bool isAudioTrackSupportAvailable() => true;

  @override
  Future<List<vpi.VideoAudioTrack>> getAudioTracks(int playerId) async {
    final player = _players[playerId];
    if (player == null) return const [];
    final selected = player.state.track.audio.id;
    return player.state.tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map((track) => vpi.VideoAudioTrack(
              id: track.id,
              label: track.title ?? track.language,
              language: track.language,
              isSelected: track.id == selected,
              bitrate: track.bitrate,
              sampleRate: track.samplerate,
              channelCount: track.channelscount,
              codec: track.codec,
            ))
        .toList(growable: false);
  }

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async {
    final player = _players[playerId];
    if (player == null) return;
    final track = player.state.tracks.audio.firstWhere(
      (candidate) => candidate.id == trackId,
      orElse: () => mk.AudioTrack(trackId, null, null),
    );
    await player.setAudioTrack(track);
  }

  @override
  bool isVideoTrackSupportAvailable() => true;

  @override
  Future<List<vpi.VideoTrack>> getVideoTracks(int playerId) async {
    final player = _players[playerId];
    if (player == null) return const [];
    final selected = player.state.track.video.id;
    return player.state.tracks.video
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map((track) => vpi.VideoTrack(
              id: track.id,
              label: track.title ??
                  (track.h == null ? null : track.h.toString() + 'p'),
              isSelected: track.id == selected,
              bitrate: track.bitrate,
              width: track.w,
              height: track.h,
              frameRate: track.fps,
              codec: track.codec,
            ))
        .toList(growable: false);
  }

  @override
  Future<void> selectVideoTrack(int playerId, vpi.VideoTrack? track) async {
    final player = _players[playerId];
    if (player == null) return;
    if (track == null) {
      await player.setVideoTrack(mk.VideoTrack.auto());
      return;
    }
    final selected = player.state.tracks.video.firstWhere(
      (candidate) => candidate.id == track.id,
      orElse: () => mk.VideoTrack(
        track.id,
        track.label,
        null,
        bitrate: track.bitrate,
        w: track.width,
        h: track.height,
        fps: track.frameRate,
        codec: track.codec,
      ),
    );
    await player.setVideoTrack(selected);
  }

  /// Initialize the [Stream]s for a given textureId.
  void _initialize(int textureId) {
    if (_streamSubscriptions[textureId]?.isNotEmpty ?? false) {
      return;
    }

    final player = _players[textureId];
    final completer = _completers[textureId];
    final streamController = _streamControllers[textureId];
    final streamSubscriptions = _streamSubscriptions[textureId];

    if (player != null &&
        completer != null &&
        streamController != null &&
        streamSubscriptions != null) {
      // VideoEventType.initialized

      int? width;
      int? height;
      Duration? duration;

      void notify() {
        if (!completer.isCompleted) {
          if (width != null && height != null && duration != null) {
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.initialized,
                size: Size(
                  (width ?? 0) * 1.0,
                  (height ?? 0) * 1.0,
                ),
                duration: player.state.duration,
              ),
            );
            completer.complete();
          }
        }
      }

      streamSubscriptions.add(
        player.stream.duration.listen(
          (event) {
            if (event > Duration.zero) {
              duration = event;
              notify();
            }
          },
        ),
      );
      streamSubscriptions.add(
        player.stream.videoParams.listen(
          (event) {
            width = event.dw;
            height = event.dh;
            if ((width ?? 0) > 0 && (height ?? 0) > 0) {
              notify();
            }
          },
        ),
      );
      streamSubscriptions.add(
        player.stream.tracks.listen(
          (event) {
            // No video track is available i.e. an audio file.
            if (event.video.length == 2 && event.audio.length > 2) {
              width = 0;
              height = 0;
              notify();
            }
          },
        ),
      );
      // VideoEventType.isPlayingStateUpdate
      streamSubscriptions.add(
        player.stream.playing.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.isPlayingStateUpdate,
                isPlaying: event,
              ),
            );
          },
        ),
      );
      // VideoEventType.completed
      streamSubscriptions.add(
        player.stream.completed.listen(
          (event) async {
            await completer.future;
            if (event) {
              streamController.add(
                VideoEvent(
                  eventType: VideoEventType.completed,
                ),
              );
            }
          },
        ),
      );
      // VideoEventType.bufferingStart
      streamSubscriptions.add(
        player.stream.buffering.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: event
                    ? VideoEventType.bufferingStart
                    : VideoEventType.bufferingEnd,
              ),
            );
          },
        ),
      );
      // VideoEventType.bufferingUpdate
      streamSubscriptions.add(
        player.stream.buffer.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.bufferingUpdate,
                buffered: [
                  DurationRange(
                    Duration.zero,
                    event,
                  ),
                ],
              ),
            );
          },
        ),
      );

      streamSubscriptions.add(
        player.stream.error.listen(
          (event) async {
            await completer.future;
            streamController.addError(
              PlatformException(
                code: '',
                message: event,
              ),
            );
          },
        ),
      );
    }
  }
}

class _PendingSeek {
  _PendingSeek(this.position);

  Duration position;
  final List<Completer<void>> waiters = <Completer<void>>[];
}
