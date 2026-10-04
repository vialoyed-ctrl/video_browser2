/// 播放模块控制器：基于 Google 官方 video_player (Android 原生 ExoPlayer / Media3)。
/// 仿哔哩哔哩移动端控制体系：
/// 1. 播放流解析与相关推荐加载；
/// 2. 手势系统：左屏垂直滑动调节亮度、右屏垂直滑动调节音量；
/// 3. 横向滑动 Seek 预览与精准拖动；
/// 4. 双击左屏快退 10s、双击右屏快进 10s（连击累加）、双击中屏暂停/播放；
/// 5. 长按 2.0X 极速倍速播放；
/// 6. Wakelock 屏幕常亮与全屏沉浸式切换。
library;

import 'dart:async';

import 'package:flutter/material.dart' show BoxFit, WidgetsBinding;
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/app_logger.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/pornhub_source.dart';
import '../../data/sources/site91_source.dart';
import '../../data/sources/video_source.dart';
import '../../data/sources/hanime1_source.dart';
import '../../data/sources/watch_history.dart';
import '../../services/hanime_mp4_range_proxy.dart';
import '../../services/hls_cache_proxy.dart';
import '../../services/media3_cache_service.dart';
import '../../services/player_service.dart';
import '../../services/preload_service.dart';
import '../../services/user_service.dart';

class PlayerController extends GetxController {
  // Match preview seeks to the encoded video cadence (at most display refresh rate).
  // Latest-wins coalescing prevents slow platform calls from building a seek backlog.
  Duration get _scrubSeekInterval {
    final fps = scrubFrameRate;
    if (fps == null) return const Duration(microseconds: 33333);
    final frameIntervalUs = (1000000 / fps).round().clamp(16667, 100000);
    return Duration(microseconds: frameIntervalUs);
  }

  PlayerController({this.initialVideo});

  final VideoItem? initialVideo;
  static final List<PlayerController> _activeControllers = <PlayerController>[];
  static bool get hasActivePlayback => _activeControllers.isNotEmpty;

  /// 观看历史写入失败只记一次日志。
  ///
  /// [_onPlayerValueChanged] 每 5 秒就会走一次 recordHistory 路径，若逐次记录失败，
  /// 会以每 5 秒一条的频率刷爆 application.log.jsonl（AppLogger 每条都会 print +
  /// debugPrint 并落盘）。这里用一次性闸门保留可见性、避免日志淹没。
  bool _historyWriteErrorLogged = false;

  VideoPlayerController? _videoPlayerController;
  VideoPlayerController? get videoPlayerController => _videoPlayerController;

  final Rxn<VideoItem> video = Rxn<VideoItem>();
  final RxList<VideoItem> relatedVideos = <VideoItem>[].obs;
  final RxList<VideoItem> playlistEpisodes = <VideoItem>[].obs;
  final RxList<VideoVariant> sourceVariants = <VideoVariant>[].obs;
  final RxList<VideoAudioTrack> audioTracks = <VideoAudioTrack>[].obs;
  final RxList<VideoTrack> videoTracks = <VideoTrack>[].obs;

  final RxBool buffering = false.obs;
  final RxBool playing = false.obs;
  final RxBool isInitialized = false.obs;
  final RxBool resolving = false.obs;
  final RxString resolveStatus = ''.obs;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;
  final Rx<Duration> buffered = Duration.zero.obs;

  /// Fraction of the active resource that the full-media downloader has cached.
  /// This is byte/segment progress from Media3, independent of the playhead.
  final RxnDouble cacheDownloadFraction = RxnDouble();
  String? _cacheProgressVideoId;
  final RxDouble speed = 1.0.obs;
  final RxnString error = RxnString();

  // 控制层显隐状态与定时器
  final RxBool showControls = true.obs;
  final RxBool controlsLocked = false.obs;
  final RxBool autoPlayNext = true.obs;
  final RxBool subtitlesEnabled = false.obs;
  final RxString currentCaption = ''.obs;
  final RxBool isFullscreen = false.obs;
  final Rx<BoxFit> videoFit = BoxFit.contain.obs;
  Timer? _hideTimer;

  // ----------------------------------------------------------- 手势与 HUD 状态
  // 亮度
  final RxDouble brightness = 0.5.obs;
  final RxBool showBrightnessHud = false.obs;
  Timer? _brightnessTimer;

  // 音量
  final RxDouble volume = 100.0.obs;
  final RxBool showVolumeHud = false.obs;
  Timer? _volumeTimer;
  Timer? _volumeWriteTimer;
  double? _gestureVolumeFraction, _pendingGestureVolume;
  DateTime _volumeEchoUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // 长按倍速
  final RxBool isSpeeding = false.obs;
  double _preSpeed = 1.0;

  // 横向滑动进度 Seek 预览
  final RxBool isSeeking = false.obs;
  final Rx<Duration> seekPreviewPosition = Duration.zero.obs;
  final RxInt seekDeltaSeconds = 0.obs;
  Duration _seekStartPosition = Duration.zero;
  Duration? _pendingVisualSeekTarget;
  DateTime? _pendingVisualSeekAt;
  DateTime? _playRequestAt;
  DateTime? _playerOpenAt;
  bool _firstPlaybackPositionLogged = false;

  // ------------------------------------------------------------ 进度条逐帧拖动 (Scrub)
  //
  // 进度条拖动与屏幕横滑共用同一个「实时跟随」引擎：两者都是「手指在哪，画面就在哪」，
  // 区别只在于位置从哪来（进度条几何 vs 屏幕位移）。因此 seek 泵、暂停/恢复的成对逻辑
  // 统一由下面的共享状态驱动，避免两套实现各自漂移。

  /// 是否正在拖动进度条。
  final RxBool isScrubbing = false.obs;

  /// 拖动过程中手指所指的位置。拖动期间 UI 应读它，而不是 [position]。
  final Rx<Duration> scrubPosition = Duration.zero.obs;

  /// 实时跟随 seek 会话是否活跃（进度条拖动或屏幕横滑）。
  ///
  /// seek 泵以此为准而不是 [isScrubbing]：横滑期间 [isScrubbing] 为 false，
  /// 但画面同样必须跟着手指走。
  bool _liveSeekActive = false;

  /// 拖动开始前是否正在播放，松手后据此恢复。
  bool _scrubWasPlaying = false;

  /// 是否因拖动而暂停。
  ///
  /// 只有手指**真正移动过**才暂停：单击进度条是一次「按下即抬起」，
  /// 若也走暂停/恢复，播放/暂停图标会在每次单击跳转时闪一下。
  bool _scrubPausedPlayback = false;

  /// 屏幕横滑专用的暂停/恢复状态。
  ///
  /// 刻意与进度条拖动的那套分开：两个手势不会同时发生，但共享字段会让
  /// 「横滑暂停后紧接着拖进度条」把 `_scrubWasPlaying` 读成 false，
  /// 于是松手后不再恢复播放 —— 表现为画面莫名停住。
  bool _seekWasPlaying = false;
  bool _seekPausedPlayback = false;

  /// 最新的 seek 目标。在飞期间只更新它，不叠加新请求（latest-wins）。
  Duration? _scrubLatestTarget;

  /// 正在飞的拖动 seek 任务；同一时刻最多一个。
  Future<void>? _scrubSeekTask;

  /// Final seek/resume is dispatched immediately on release; this tracks only cleanup.
  Future<void>? _scrubFinishTask;

  /// Native Media3 uses exact-frame seeks with decoder scrubbing optimizations during a gesture.
  int? _nativeScrubbingPlayerId;
  Future<void>? _nativeScrubbingEnableTask;
  VideoPlayerController? _activeScrubController;
  DateTime? _lastScrubSeekDispatchedAt;
  Future<void>? _scrubPauseTask;
  Future<void>? _seekPauseTask;
  StreamSubscription<Media3PreloadProgress>? _media3PreloadSubscription;

  // 双击左右快进/快退指示层与秒数
  final RxBool showBackwardSeek = false.obs;
  final RxBool showForwardSeek = false.obs;
  final RxInt backwardSeekSeconds = 0.obs;
  final RxInt forwardSeekSeconds = 0.obs;
  Timer? _seekFeedbackTimer;
  DateTime _lastDoubleTapTime = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _pendingSeekPosition = Duration.zero;
  DateTime? _lastHanimePositionUpdate;
  bool _hasAutoRetried = false;
  static const int _maxPornHubFallbackAttempts = 5;
  final Set<String> _attemptedPornHubStreams = <String>{};
  int _pornHubFallbackAttempts = 0;
  bool _pornHubFreshRefreshUsed = false;
  VideoPlayerController? _pornHubRecoveryController;
  bool _handledPlaybackEnd = false;
  int _videoSwitchGeneration = 0;

  bool get isReady => duration.value > Duration.zero;

  int get currentEpisodeIndex {
    final current = video.value;
    if (current == null) return -1;
    return playlistEpisodes.indexWhere(
      (episode) =>
          episode.id == current.id ||
          (episode.detailUrl != null && episode.detailUrl == current.detailUrl),
    );
  }

  bool get hasEpisodeNavigation =>
      playlistEpisodes.length > 1 && currentEpisodeIndex >= 0;
  bool get canSkipToPreviousEpisode =>
      hasEpisodeNavigation && currentEpisodeIndex > 0;
  bool get canSkipToNextEpisode =>
      hasEpisodeNavigation && currentEpisodeIndex < playlistEpisodes.length - 1;

  void _refreshPlaylistEpisodes(VideoItem item) {
    if (!(item.detailUrl ?? '').contains('hanime1.me')) {
      playlistEpisodes.clear();
      return;
    }
    final source = SourceRegistry.byId('hanime1');
    final extra = source is Hanime1Source ? source.getExtra(item.id) : null;
    playlistEpisodes.assignAll(extra?.playlistItems ?? const <VideoItem>[]);
  }

  static Future<void> _pauseOtherControllers({PlayerController? except}) async {
    final pending = _activeControllers
        .where((controller) => controller != except)
        .map((controller) => controller.pause())
        .toList(growable: false);
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  @override
  void onInit() {
    super.onInit();

    // Stop other player routes before this one starts opening its stream.
    unawaited(_pauseOtherControllers(except: this));
    _activeControllers.add(this);
    if (_isPornHubPlayback) {
      unawaited(PreloadService.instance.resetPornHubNativePreloads());
    }
    PreloadService.instance.setPlaybackActive(true);

    // 初始化系统亮度与系统全局媒体音量
    _initBrightness();
    _initVolume();

    _media3PreloadSubscription = Media3CacheService.progress.listen(
      _onMedia3PreloadProgress,
    );

    // Dart HLS proxy reports the contiguous segment prefix, not just the playhead buffer.
    HlsCacheProxy.instance.onProgressUpdate = (id, progress, bufferedDuration) {
      if (id != HlsCacheProxy.instance.currentActiveVideoId) return;
      final totalMs = duration.value.inMilliseconds;
      if (totalMs > 0) {
        cacheDownloadFraction.value =
            (bufferedDuration.inMilliseconds / totalMs).clamp(0.0, 1.0);
      } else if (progress >= 0.999) {
        cacheDownloadFraction.value = 1.0;
      }
      _refreshBufferedIndicator();
    };

    final targetVideo =
        initialVideo ??
        (Get.arguments is VideoItem ? Get.arguments as VideoItem : null);
    AppLogger.i(
      'Player',
      '▶️ 激活 PlayerController (id: $hashCode), 视频: ${targetVideo?.title}',
    );
    if (targetVideo != null) {
      video.value = targetVideo;
      final cachedProgress = Media3CacheService.latestProgressFor(
        targetVideo.id,
      );
      if (cachedProgress != null) {
        _onMedia3PreloadProgress(cachedProgress);
      }
      _playRequestAt = DateTime.now();
      _prepareAndOpen(targetVideo);
      // GetX can construct this controller during a route build. Defer the RxList
      // mutation until the frame completes so history updates never trigger
      // markNeedsBuild from inside Flutter's build phase.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        try {
          Get.find<UserService>().recordHistory(targetVideo);
        } catch (e) {
          AppLogger.w('Player', '写入观看历史失败 id=${targetVideo.id}: $e');
        }
      });
    } else {
      error.value = '未收到视频参数';
    }

    _startHideControlsTimer();
  }

  void _onMedia3PreloadProgress(Media3PreloadProgress update) {
    if (update.taskId != video.value?.id) return;

    double? fraction;
    if (update.finished) {
      fraction = 1.0;
    } else if (update.percent >= 0) {
      fraction = update.percent / 100.0;
    } else if (update.contentLength > 0) {
      fraction = update.bytesDownloaded / update.contentLength;
    }
    if (fraction != null) {
      cacheDownloadFraction.value = fraction.clamp(0.0, 1.0);
    }
    if (update.hasError) {
      AppLogger.w(
        'Player',
        '整片缓存中断 id=${update.taskId}, 已缓存比例=${cacheDownloadFraction.value ?? 0}',
      );
    }
    _refreshBufferedIndicator();
  }

  /// Combines the real contiguous player buffer with full-resource cache progress.
  /// The downloader percentage is byte/segment based; mapping it to time is an estimate for
  /// variable-bitrate media, while [VideoPlayerValue.buffered] remains the exact seekable range.
  void _refreshBufferedIndicator([VideoPlayerValue? value]) {
    final current = value ?? _videoPlayerController?.value;
    final total = duration.value > Duration.zero
        ? duration.value
        : (current?.duration ?? Duration.zero);
    var end = Duration.zero;

    if (current != null && current.buffered.isNotEmpty) {
      final ranges = current.buffered.toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      const gapTolerance = Duration(milliseconds: 250);
      for (final range in ranges) {
        if (range.end <= end) continue;
        if (range.start > end + gapTolerance) break;
        end = range.end;
      }
    }

    final fraction = cacheDownloadFraction.value;
    if (fraction != null && total > Duration.zero) {
      final cachedPrefix = Duration(
        microseconds: (total.inMicroseconds * fraction).round(),
      );
      if (cachedPrefix > end) end = cachedPrefix;
    }
    if (end > total && total > Duration.zero) end = total;
    buffered.value = end;
  }

  void _onPlayerValueChanged() {
    final vtl = _videoPlayerController;
    if (vtl == null) return;
    final val = vtl.value;

    if (val.hasError) {
      if (_isPornHubPlayback) {
        // initialize() and the listener report the same native failure. Only
        // one may dispose this controller and advance the fallback route.
        if (identical(_pornHubRecoveryController, vtl)) return;
        _pornHubRecoveryController = vtl;
      }
      final err = val.errorDescription ?? 'ExoPlayer 播放异常';
      AppLogger.e('Player', 'ExoPlayer 报错: $err');
      if (_tryOpenNextPornHubVariant('player error') ||
          _tryRefreshPornHubStream('player error')) {
        return;
      }
      if (!_hasAutoRetried && video.value != null) {
        _hasAutoRetried = true;
        AppLogger.i('Player', '🔄 检测到播放流异常，正在自动强制刷新流地址重试...');
        _prepareAndOpen(video.value!, forceRefresh: true);
        return;
      }
      error.value = err;
      buffering.value = false;
      return;
    }

    if (isInitialized.value != val.isInitialized) {
      isInitialized.value = val.isInitialized;
    }

    final isHanimeVideo = (video.value?.detailUrl ?? '').contains('hanime1.me');
    final now = DateTime.now();
    final seekTarget = _pendingVisualSeekTarget;
    final seekStartedAt = _pendingVisualSeekAt;
    final isAwaitingSeek =
        seekTarget != null &&
        seekStartedAt != null &&
        now.difference(seekStartedAt) < const Duration(seconds: 5);
    final reachedSeekTarget =
        isAwaitingSeek &&
        (val.position.inMilliseconds - seekTarget.inMilliseconds).abs() <= 1000;
    if (reachedSeekTarget) {
      AppLogger.i(
        'Player',
        '⚡ ${_playerSourceLabel()} seek 目标已到达：'
            '${now.difference(seekStartedAt).inMilliseconds}ms',
      );
      _pendingVisualSeekTarget = null;
      _pendingVisualSeekAt = null;
    } else if (seekTarget != null && seekStartedAt != null && !isAwaitingSeek) {
      _pendingVisualSeekTarget = null;
      _pendingVisualSeekAt = null;
      AppLogger.w('Player', '${_playerSourceLabel()} seek 超过 5 秒仍未到达目标');
    }

    if (!_firstPlaybackPositionLogged &&
        val.position > Duration.zero &&
        !isAwaitingSeek) {
      _firstPlaybackPositionLogged = true;
      final playingItem = video.value;
      if (_isPornHubPlayback &&
          playingItem != null &&
          playingItem.hlsUrl.isNotEmpty) {
        PreloadService.instance.scheduleNativePreload(
          playingItem,
          playingItem.hlsUrl,
          full: true,
          playbackStarted: true,
        );
      }
      final openedAt = _playerOpenAt;
      if (openedAt != null) {
        AppLogger.i(
          'Player',
          '⚡ ${_playerSourceLabel()} 首个播放位置已推进：'
              '${now.difference(openedAt).inMilliseconds}ms',
        );
      }
      final requestAt = _playRequestAt;
      if (requestAt != null) {
        AppLogger.i(
          'Player',
          '⚡ ${_playerSourceLabel()} 用户打开到首个播放位置：'
              '${now.difference(requestAt).inMilliseconds}ms',
        );
        _playRequestAt = null;
      }
    }

    final shouldPublishHanimePosition =
        !isHanimeVideo ||
        !val.isPlaying ||
        val.position == Duration.zero ||
        val.position.inSeconds != position.value.inSeconds ||
        _lastHanimePositionUpdate == null ||
        now.difference(_lastHanimePositionUpdate!) >=
            const Duration(milliseconds: 250);
    // 拖动进度条或屏幕横滑期间，位置由手指决定：播放器的位置在这里会把滑块与读数拽回去，
    // 表现为「拖着拖着跳一下」。横滑同样实时跟随，所以两者都要挡。
    if (!isScrubbing.value && !isSeeking.value) {
      if (reachedSeekTarget) {
        position.value = val.position;
      } else if (!isAwaitingSeek && shouldPublishHanimePosition) {
        position.value = val.position;
        if (isHanimeVideo) _lastHanimePositionUpdate = now;
      }
    }
    duration.value = val.duration;
    _refreshBufferedIndicator(val);
    buffering.value = val.isBuffering;
    if (currentCaption.value != val.caption.text) {
      currentCaption.value = val.caption.text;
    }

    if (playing.value != val.isPlaying) {
      playing.value = val.isPlaying;
      if (val.isPlaying) {
        _startHideControlsTimer();
        WakelockPlus.enable().ignore();
      } else {
        WakelockPlus.disable().ignore();
      }
    }

    if (!_handledPlaybackEnd &&
        val.duration > Duration.zero &&
        val.position >= val.duration &&
        !val.isPlaying) {
      _handledPlaybackEnd = true;
      if (autoPlayNext.value && canSkipToNextEpisode) {
        unawaited(switchVideo(playlistEpisodes[currentEpisodeIndex + 1]));
      } else {
        showControls.value = true;
      }
    }

    // 记录历史（每 5 秒同步一次进度）
    final posSec = val.position.inSeconds;
    if (posSec > 0 && posSec % 5 == 0 && video.value != null) {
      try {
        Get.find<UserService>().recordHistory(
          video.value!,
          positionMs: val.position.inMilliseconds,
          durationMs: val.duration.inMilliseconds,
        );
      } catch (e) {
        // 高频路径（每 5 秒一次）：只在首次失败时记录，避免刷爆日志。
        if (!_historyWriteErrorLogged) {
          _historyWriteErrorLogged = true;
          AppLogger.w('Player', '定时写入观看进度失败（后续同类失败不再重复记录）: $e');
        }
      }
    }
  }

  bool get _isPornHubPlayback {
    final detailUrl = video.value?.detailUrl ?? initialVideo?.detailUrl ?? '';
    final host = Uri.tryParse(detailUrl)?.host.toLowerCase() ?? '';
    if (host == 'pornhub.com' || host.endsWith('.pornhub.com')) return true;
    if (!Get.isRegistered<VideoSource>()) return false;
    try {
      return Get.find<VideoSource>().id == 'pornhub';
    } catch (_) {
      return false;
    }
  }

  String _pornHubStreamKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return url.trim().toLowerCase();
    // Ignore signatures: a refreshed URL to the same host/path is still the
    // same playback route and should not be retried as a different fallback.
    return '${uri.host.toLowerCase()}${uri.path}';
  }

  bool _tryOpenNextPornHubVariant(String reason) {
    if (!_isPornHubPlayback ||
        _pornHubFallbackAttempts >= _maxPornHubFallbackAttempts) {
      return false;
    }
    final current = video.value;
    if (current == null) return false;
    _attemptedPornHubStreams.add(_pornHubStreamKey(current.hlsUrl));

    final targetUrl = current.detailUrl ?? current.id;
    final source = Get.isRegistered<VideoSource>()
        ? Get.find<VideoSource>()
        : null;
    final cachedFallbacks = source is PornHubSource
        ? source.fallbackVariantsFor(targetUrl)
        : const <VideoVariant>[];
    final candidates = <VideoVariant>[...cachedFallbacks, ...sourceVariants];
    for (final candidate in candidates) {
      final url = candidate.url.trim();
      if (url.isEmpty ||
          _attemptedPornHubStreams.contains(_pornHubStreamKey(url)) ||
          !PreloadService.instance.isFreshPlaybackUrl(current, url)) {
        continue;
      }

      _attemptedPornHubStreams.add(_pornHubStreamKey(url));
      _pornHubFallbackAttempts++;
      final updated = current.copyWith(hlsUrl: url);
      video.value = updated;
      error.value = null;
      resolving.value = false;
      resolveStatus.value = '';
      final uri = Uri.tryParse(url);
      AppLogger.w(
        'Player',
        'PornHub $reason，尝试备用流 ${candidate.label} '
            '(${uri?.host ?? 'unknown'}${uri?.path ?? ''}) '
            '($_pornHubFallbackAttempts/$_maxPornHubFallbackAttempts)',
      );
      unawaited(_open(updated, generation: _videoSwitchGeneration));
      return true;
    }
    return false;
  }

  bool _tryRefreshPornHubStream(String reason) {
    if (!_isPornHubPlayback || _pornHubFreshRefreshUsed) return false;
    final current = video.value;
    if (current == null) return false;
    _pornHubFreshRefreshUsed = true;
    _hasAutoRetried = true;
    AppLogger.w('Player', 'PornHub 备用线路用尽，强制重新解析流地址 ($reason)');
    unawaited(_prepareAndOpen(current, forceRefresh: true));
    return true;
  }

  void _resetPornHubRecovery() {
    _pornHubRecoveryController = null;
    _attemptedPornHubStreams.clear();
    _pornHubFallbackAttempts = 0;
    _pornHubFreshRefreshUsed = false;
  }

  Future<void> _initVolume() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
      if (isClosed) return;
      final vol = await FlutterVolumeController.getVolume();
      if (isClosed) return;
      if (vol != null) {
        volume.value = (vol * 100.0).clamp(0.0, 100.0);
      }
      FlutterVolumeController.addListener((vol) {
        syncSystemVolume(vol);
      });
    } catch (e) {
      AppLogger.w('Player', '获取或监听系统音量失败: $e');
    }
  }

  Future<void> _initBrightness() async {
    try {
      final current = await ScreenBrightness().application;
      if (isClosed) return;
      brightness.value = current.clamp(0.0, 1.0);
    } catch (_) {
      if (!isClosed) brightness.value = 0.5;
    }
  }

  void toggleControls() {
    if (controlsLocked.value) return;
    showControls.value = !showControls.value;
    if (showControls.value) {
      _startHideControlsTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _startHideControlsTimer() {
    _hideTimer?.cancel();
    if (controlsLocked.value) {
      showControls.value = true;
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (playing.value && !isSeeking.value && !isScrubbing.value) {
        showControls.value = false;
      }
    });
  }

  void pingControls() {
    if (controlsLocked.value) return;
    if (!showControls.value) {
      showControls.value = true;
    }
    _startHideControlsTimer();
  }

  void toggleControlsLock() {
    controlsLocked.value = !controlsLocked.value;
    showControls.value = true;
    if (controlsLocked.value) {
      _hideTimer?.cancel();
    } else {
      _startHideControlsTimer();
    }
  }

  void toggleVideoFit() {
    if (videoFit.value == BoxFit.contain) {
      videoFit.value = BoxFit.cover;
    } else {
      videoFit.value = BoxFit.contain;
    }
  }

  final RxInt videoRotation = 0.obs;

  Future<void> enterFullscreen() async {
    isFullscreen.value = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    final size = _videoPlayerController?.value.size;
    final width = size?.width ?? 0;
    final height = size?.height ?? 0;

    if (width > 0 && height > width) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void toggleRotation() {
    videoRotation.value = (videoRotation.value + 1) % 4;
    pingControls();
  }

  Future<void> exitFullscreen() async {
    isFullscreen.value = false;
    await SystemChrome.setPreferredOrientations([]);
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> toggleFullscreen() async {
    if (isFullscreen.value) {
      await exitFullscreen();
    } else {
      await enterFullscreen();
    }
  }

  Future<void> stop() async {
    try {
      await _videoPlayerController?.pause();
    } catch (_) {
      // 平台通道（播放器暂停）：此处正在停止/释放，暂停失败不影响最终状态，静默是正确设计。
    }
  }

  // ----------------------------------------------------------- 手势控制方法
  /// 屏幕左侧垂直拖动调节应用窗口亮度（向上拖动 dy < 0，亮度增加）
  void onVerticalDragLeft(double deltaY, double totalHeight) {
    if (isClosed || totalHeight <= 0) return;
    final change = -deltaY / totalHeight;
    final next = (brightness.value + change).clamp(0.0, 1.0);
    brightness.value = next;
    try {
      unawaited(
        ScreenBrightness()
            .setApplicationScreenBrightness(next)
            .catchError((Object _) {}),
      );
    } catch (_) {
      // 平台能力（屏幕亮度）：设备不支持或权限受限时不应打断播放。
      // 界面上的 brightness 值已更新，静默降级是正确设计。
    }

    showControls.value = false;
    _hideTimer?.cancel();
    showBrightnessHud.value = true;
    _brightnessTimer?.cancel();
    _brightnessTimer = Timer(const Duration(milliseconds: 1500), () {
      showBrightnessHud.value = false;
    });
  }

  void beginVolumeGesture() {
    _gestureVolumeFraction = (volume.value / 100).clamp(0.0, 1.0);
  }

  void syncSystemVolume(double fraction) {
    // Android reports integer volume steps. Do not feed those rounded echoes
    // back into the next gesture delta, which otherwise drains one step/frame.
    if (isClosed ||
        _gestureVolumeFraction != null ||
        DateTime.now().isBefore(_volumeEchoUntil)) {
      return;
    }
    volume.value = (fraction * 100).clamp(0.0, 100.0);
  }

  void endVolumeGesture() {
    _gestureVolumeFraction = null;
    _volumeWriteTimer?.cancel();
    _volumeWriteTimer = null;
    _flushGestureVolume();
  }

  void _flushGestureVolume() {
    final target = _pendingGestureVolume;
    _pendingGestureVolume = null;
    if (target == null || isClosed) return;
    _volumeEchoUntil = DateTime.now().add(const Duration(milliseconds: 300));
    unawaited(_setGestureVolume(target));
  }

  /// 屏幕右侧垂直拖动调节系统音量（向上拖动 dy < 0，音量增加）
  void onVerticalDragRight(double deltaY, double totalHeight) {
    if (isClosed || totalHeight <= 0) return;
    final change = (-deltaY / totalHeight);
    final currentFraction =
        _gestureVolumeFraction ?? (volume.value / 100.0).clamp(0.0, 1.0);
    final nextFraction = (currentFraction + change).clamp(0.0, 1.0);
    _gestureVolumeFraction = nextFraction;
    volume.value = nextFraction * 100.0;
    _pendingGestureVolume = nextFraction;
    _volumeWriteTimer ??= Timer(const Duration(milliseconds: 40), () {
      _volumeWriteTimer = null;
      _flushGestureVolume();
    });

    showControls.value = false;
    _hideTimer?.cancel();
    showVolumeHud.value = true;
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      showVolumeHud.value = false;
    });
  }

  Future<void> _setGestureVolume(double value) async {
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
      if (isClosed) return;
      await FlutterVolumeController.setVolume(value);
    } catch (_) {
      // An unavailable platform control must not interrupt playback.
    }
  }

  double _dragDx = 0.0;

  /// 横向滑动进度 Seek 开始。
  ///
  /// 与进度条拖动共用 [_liveSeekActive] 驱动的 seek 泵，因此画面**实时跟随手指**，
  /// 而不是只预览时间、松手才跳。
  void onHorizontalDragStart() {
    _dragDx = 0.0;
    _seekStartPosition = position.value;
    seekPreviewPosition.value = position.value;
    seekDeltaSeconds.value = 0;
    isSeeking.value = true;
    // 让泵的起点与手指起点一致，否则首次位移会相对上一次拖动的位置计算。
    scrubPosition.value = _seekStartPosition;
    _seekWasPlaying = playing.value;
    _seekPausedPlayback = false;
    _seekPauseTask = null;
    _liveSeekActive = true;
    _lastScrubSeekDispatchedAt = null;
    _startNativeScrubbing();
    _hideTimer?.cancel();
    showControls.value = false;
    AppLogger.i('Player', '👉 开始横向滑动 Seek (起点: $_seekStartPosition)');
  }

  /// 横向滑动进度 Seek 预览中（依据视频总时长自适应动态范围）。
  ///
  /// 位移换算到**毫秒**精度：秒级步进在 24fps 下一跳就是 24 帧，
  /// 那样「慢拖逐帧看」无从谈起。
  void onHorizontalDragUpdate(double frameDeltaX, double totalWidth) {
    if (totalWidth <= 0 || duration.value.inMilliseconds <= 0) return;
    _dragDx += frameDeltaX;

    final totalSec = duration.value.inSeconds;
    final double maxSeekRange;
    if (totalSec <= 120) {
      maxSeekRange = totalSec.toDouble();
    } else if (totalSec <= 600) {
      maxSeekRange = 150.0;
    } else if (totalSec <= 1800) {
      maxSeekRange = 300.0;
    } else {
      maxSeekRange = (totalSec / 5).clamp(300.0, 900.0);
    }
    final deltaMs = ((_dragDx / totalWidth) * maxSeekRange * 1000).round();

    final targetMs = _seekStartPosition.inMilliseconds + deltaMs;
    final clampedMs = targetMs.clamp(0, duration.value.inMilliseconds);
    final targetDuration = Duration(milliseconds: clampedMs);

    seekPreviewPosition.value = targetDuration;
    // 读数仍按秒显示，保持与既有 HUD 一致。
    seekDeltaSeconds.value =
        targetDuration.inSeconds - _seekStartPosition.inSeconds;

    // 真正移动时才暂停：否则播放器一边被 seek 拉回、一边自己向前推进，
    // 画面表现为抖动而不是跟随。
    if (!_seekPausedPlayback && _seekWasPlaying) {
      _seekPausedPlayback = true;
      _seekPauseTask = _videoPlayerController?.pause();
    }
    // 吸附到帧边界后发布，并交给共享的 latest-wins 泵去 seek。
    _applyScrubPosition(targetDuration);
  }

  /// 横向滑动进度 Seek 结束，提交最终落点。
  void onHorizontalDragEnd() {
    if (!isSeeking.value) return;
    final target = seekPreviewPosition.value;
    final shouldResume = _seekPausedPlayback && _seekWasPlaying;

    // 先退出跟随态，泵的循环才会结束。
    isSeeking.value = false;
    _liveSeekActive = false;
    _seekPausedPlayback = false;
    _seekWasPlaying = false;
    showControls.value = false;
    _hideTimer?.cancel();

    AppLogger.i(
      'Player',
      '👌 结束横向滑动 Seek -> 跳转至: $target'
          '${scrubFrameRate != null ? '（${scrubFrameRate!.toStringAsFixed(3)}fps）' : ''}',
    );
    _finishHorizontalSeek(target, shouldResume);
  }

  /// Dispatch the final seek and resume immediately; cleanup can wait in the background.
  void _finishHorizontalSeek(Duration target, bool shouldResume) {
    final controller = _activeScrubController;
    _activeScrubController = null;
    if (controller == null || !identical(_videoPlayerController, controller)) {
      unawaited(_stopNativeScrubbing());
      return;
    }
    _pendingVisualSeekTarget = target;
    _pendingVisualSeekAt = DateTime.now();
    _pendingSeekPosition = target;
    _lastDoubleTapTime = DateTime.now();
    position.value = target;
    // Dispatch immediately; the queued cleanup only waits for acknowledgements in background.
    final finalSeek = _dispatchReleaseSeek(controller, target);
    _queueScrubCleanup(controller, finalSeek, shouldResume, _seekPauseTask);
    _seekPauseTask = null;
  }

  // ============================================ 实时跟随 seek（进度条拖动 / 屏幕横滑）
  //
  // 目标：手指拖动时画面**实时跟随**，慢拖能逐帧看清每一帧。两条入口共用这一套引擎：
  //
  //   - 进度条拖动（[beginScrub] / [updateScrub] / [endScrub]）：位置来自进度条几何；
  //   - 屏幕横滑（[onHorizontalDragStart] / [onHorizontalDragUpdate] / [onHorizontalDragEnd]）：
  //     位置来自屏幕位移。
  //
  // 平台 seek Future 只确认命令已接收，不等视频帧解码/显示。拖动期间因此启用
  // Media3 scrubbing mode，并按视频帧率（最高 60Hz）合并指针样本，只保留最新 seek。
  // 预览落在精确目标帧；原生 scrubbing mode 尽量复用 GOP 内已解码数据。
  // 拖动中暂停播放，避免画面自行推进。
  //
  // 两条入口各自的暂停/恢复状态刻意分开（[_scrubWasPlaying] 与 [_seekWasPlaying]），
  // 只有 seek 泵本身（[_liveSeekActive]）共用。

  /// 当前选中视频轨的帧率（fps）。拿不到时返回 null。
  ///
  /// 帧率来自 `getVideoTracks()`（ExoPlayer 的 `Format.frameRate`）。
  /// 优先取「已选中」的那条轨——自适应码率下不同变体的帧率可能不同。
  double? get scrubFrameRate {
    double? fallback;
    for (final track in videoTracks) {
      final fps = track.frameRate;
      if (fps == null || fps <= 1 || fps >= 240) continue;
      if (track.isSelected) return fps;
      fallback ??= fps;
    }
    return fallback;
  }

  /// 把时间吸附到最近的帧边界；帧率未知时原样返回。
  ///
  /// 不做吸附也能 seek 到任意时刻（Media3 默认 `SeekParameters.EXACT`，
  /// 会从最近的关键帧解码到目标位置），但吸附后每次步进都恰好跨一帧，
  /// 「逐帧」才是确定的而不是随机的。
  Duration snapToFrame(Duration at) {
    final fps = scrubFrameRate;
    if (fps == null) return at;
    final frameIndex = (at.inMicroseconds * fps / 1000000.0).round();
    return Duration(microseconds: (frameIndex * 1000000.0 / fps).round());
  }

  Duration _clampToDuration(Duration at, Duration total) {
    if (at < Duration.zero) return Duration.zero;
    if (total > Duration.zero && at > total) return total;
    return at;
  }

  /// 拖动开始（手指刚按下进度条）。
  void beginScrub(Duration at) {
    if (duration.value <= Duration.zero) return;
    isScrubbing.value = true;
    _liveSeekActive = true;
    _scrubPausedPlayback = false;
    _scrubWasPlaying = playing.value;
    _scrubPauseTask = null;
    _scrubLatestTarget = null;
    _lastScrubSeekDispatchedAt = null;
    _startNativeScrubbing();
    _applyScrubPosition(at);
    pingControls();
  }

  /// 拖动中（手指移动）。
  void updateScrub(Duration at) {
    if (!isScrubbing.value) return;
    // 真正拖动时才暂停：单击跳转不应触发暂停/恢复，否则图标会闪。
    if (!_scrubPausedPlayback && _scrubWasPlaying) {
      _scrubPausedPlayback = true;
      _scrubPauseTask = _videoPlayerController?.pause();
    }
    _applyScrubPosition(at);
  }

  /// 拖动结束（手指抬起）：提交最终落点，并恢复此前的播放状态。
  Future<void> endScrub() {
    if (!isScrubbing.value) return Future<void>.value();
    final target = scrubPosition.value;
    final shouldResume = _scrubPausedPlayback && _scrubWasPlaying;

    // 先退出跟随态，seek 泵的循环才会结束。
    isScrubbing.value = false;
    _liveSeekActive = false;
    _scrubLatestTarget = null;

    final controller = _activeScrubController;
    _activeScrubController = null;
    if (controller != null && identical(_videoPlayerController, controller)) {
      _pendingVisualSeekTarget = target;
      _pendingVisualSeekAt = DateTime.now();
      position.value = target;
      // Enqueue both channel calls before cleanup awaits anything. The player channel
      // preserves seek -> play order, so playback resumes as soon as the target is ready.
      final finalSeek = _dispatchReleaseSeek(controller, target);
      _queueScrubCleanup(controller, finalSeek, shouldResume, _scrubPauseTask);
      _scrubPauseTask = null;
    } else {
      unawaited(_stopNativeScrubbing());
    }

    _scrubPausedPlayback = false;
    _scrubWasPlaying = false;
    AppLogger.i(
      'Player',
      '🎞️ 进度条拖动结束 -> 落点 $target'
          '${scrubFrameRate != null ? '（${scrubFrameRate!.toStringAsFixed(3)}fps）' : ''}',
    );
    pingControls();
    return Future<void>.value();
  }

  void _queueScrubCleanup(
    VideoPlayerController controller,
    Future<void> finalSeek,
    bool shouldResume,
    Future<void>? pauseTask,
  ) {
    final previousCleanup = _scrubFinishTask;
    final inFlightSeek = _scrubSeekTask;
    final releaseAt = DateTime.now();
    _scrubFinishTask = () async {
      if (previousCleanup != null) await previousCleanup;
      await _completeScrubCleanup(
        controller,
        inFlightSeek,
        finalSeek,
        shouldResume,
        pauseTask,
        releaseAt,
      );
    }();
  }

  Future<void> _dispatchReleaseSeek(
    VideoPlayerController controller,
    Duration target,
  ) {
    try {
      return controller
          .seekTo(target)
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              AppLogger.w('Player', '拖动结束 seek 失败: $error');
            },
          );
    } catch (error) {
      AppLogger.w('Player', '拖动结束 seek 派发失败: $error');
      return Future<void>.value();
    }
  }

  Future<void> _dispatchReleasePlayback(VideoPlayerController controller) {
    try {
      return controller.play().then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.w('Player', '拖动结束后恢复播放失败: $error');
        },
      );
    } catch (error) {
      AppLogger.w('Player', '拖动结束后恢复播放派发失败: $error');
      return Future<void>.value();
    }
  }

  Future<void> _completeScrubCleanup(
    VideoPlayerController controller,
    Future<void>? inFlightSeek,
    Future<void> finalSeek,
    bool shouldResume,
    Future<void>? pauseTask,
    DateTime releaseAt,
  ) async {
    // Pause and seek use separate Pigeon message channels. Waiting for both native
    // acknowledgements prevents a late pause from overriding the release-time play.
    // The seek acknowledgement only means ExoPlayer accepted the target; it does not
    // wait for network buffering or frame decode.
    await _awaitScrubPause(pauseTask);
    try {
      await finalSeek;
    } catch (error) {
      AppLogger.w('Player', '拖动结束 seek 失败: $error');
    }
    if (shouldResume && identical(_videoPlayerController, controller)) {
      AppLogger.i(
        'Player',
        '松手后恢复播放命令延迟 ${DateTime.now().difference(releaseAt).inMilliseconds}ms',
      );
      // Send play only after pause and the release seek have been acknowledged.
      // This avoids the independent platform channels racing and leaving ExoPlayer paused.
      await _dispatchReleasePlayback(controller);
    }
    if (inFlightSeek != null) {
      try {
        await inFlightSeek;
      } catch (_) {
        // The final seek supersedes a failed intermediate drag seek.
      }
      if (identical(_scrubSeekTask, inFlightSeek)) _scrubSeekTask = null;
    }
    if (!_liveSeekActive && identical(_videoPlayerController, controller)) {
      await _stopNativeScrubbing();
    }
    if (!_liveSeekActive) _lastScrubSeekDispatchedAt = null;
  }

  /// 手指位置 → 吸附到帧 → 夹到时长范围 → 发布并请求 seek。
  void _applyScrubPosition(Duration at) {
    final clamped = _clampToDuration(snapToFrame(at), duration.value);
    if (scrubPosition.value == clamped) return;
    scrubPosition.value = clamped;
    // 时间标签读的是 position，同步过去让读数跟着手指走。
    position.value = clamped;
    _scrubLatestTarget = clamped;
    _scheduleScrubSeekPump();
  }

  void _scheduleScrubSeekPump() {
    if (_scrubSeekTask != null) return;
    _scrubSeekTask = _pumpScrubSeek().whenComplete(() {
      _scrubSeekTask = null;
      // Close the small completion race where a new target arrives as the prior pump exits.
      if (_liveSeekActive && _scrubLatestTarget != null) {
        _scheduleScrubSeekPump();
      }
    });
  }

  void _startNativeScrubbing() {
    final controller = _videoPlayerController;
    _activeScrubController = controller;
    if (controller == null) return;
    // This public ID is exposed by video_player for plugin integration and testing.
    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    if (playerId < 0) return;
    _nativeScrubbingPlayerId = playerId;
    _nativeScrubbingEnableTask = Media3CacheService.setScrubbingModeForPlayer(
      playerId,
      enabled: true,
    );
  }

  Future<void> _stopNativeScrubbing() async {
    final playerId = _nativeScrubbingPlayerId;
    final enableTask = _nativeScrubbingEnableTask;
    _nativeScrubbingPlayerId = null;
    _nativeScrubbingEnableTask = null;
    if (playerId == null) return;
    await enableTask;
    await Media3CacheService.setScrubbingModeForPlayer(
      playerId,
      enabled: false,
    );
  }

  Future<void> _awaitScrubPause(Future<void>? pauseTask) async {
    if (pauseTask == null) return;
    try {
      await pauseTask;
    } catch (error) {
      AppLogger.w('Player', '拖动期间暂停播放失败: $error');
    }
  }

  /// 实时跟随 seek 泵：同一时刻最多一次在飞，始终收敛到最新目标。
  ///
  /// 循环条件用 [_liveSeekActive] 而非 [isScrubbing]：进度条拖动与屏幕横滑
  /// 共用这一个泵，两者都只关心「手指还在不在动」。
  Future<void> _pumpScrubSeek() async {
    final controller = _videoPlayerController;
    if (controller == null) return;
    // Do not let the first seek race the native mode transition.
    await _nativeScrubbingEnableTask;
    // Pause and seek travel on separate platform channels. Wait for the pause acknowledgement
    // before issuing the first preview seek, or playback can advance while the seek is applied.
    final pauseTask = _seekPauseTask ?? _scrubPauseTask;
    await _awaitScrubPause(pauseTask);
    while (_liveSeekActive) {
      if (_scrubLatestTarget == null) break;
      final lastSentAt = _lastScrubSeekDispatchedAt;
      if (lastSentAt != null) {
        final elapsed = DateTime.now().difference(lastSentAt);
        final remaining = _scrubSeekInterval - elapsed;
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      if (!_liveSeekActive) break;
      // Re-read after the throttle so intermediate pointer samples collapse to the newest one.
      final target = _scrubLatestTarget;
      if (target == null) break;
      _scrubLatestTarget = null;
      _lastScrubSeekDispatchedAt = DateTime.now();
      try {
        await controller.seekTo(target);
      } catch (e) {
        AppLogger.w('Player', '拖动 seek 失败: $e');
        break;
      }
      if (!identical(_videoPlayerController, controller)) break;
    }
  }

  /// 双击左屏：瞬间快退 5 秒
  void onDoubleTapLeft() {
    seekBy(-5, revealControls: false);
    HapticFeedback.lightImpact();

    final now = DateTime.now();
    final isConsecutive =
        now.difference(_lastDoubleTapTime).inMilliseconds < 800;
    _lastDoubleTapTime = now;

    backwardSeekSeconds.value =
        (isConsecutive ? backwardSeekSeconds.value : 0) + 5;
    showBackwardSeek.value = true;
    showForwardSeek.value = false;
    AppLogger.i(
      'Player',
      '⚡ 触发左屏双击：瞬间快退 -5s, 累计快退 -${backwardSeekSeconds.value}s',
    );

    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      showBackwardSeek.value = false;
      backwardSeekSeconds.value = 0;
    });
  }

  /// 双击右屏：瞬间快进 10 秒
  void onDoubleTapRight() {
    seekBy(10, revealControls: false);
    HapticFeedback.lightImpact();

    final now = DateTime.now();
    final isConsecutive =
        now.difference(_lastDoubleTapTime).inMilliseconds < 800;
    _lastDoubleTapTime = now;

    forwardSeekSeconds.value =
        (isConsecutive ? forwardSeekSeconds.value : 0) + 10;
    showForwardSeek.value = true;
    showBackwardSeek.value = false;
    AppLogger.i(
      'Player',
      '⚡ 触发右屏双击：瞬间快进 +10s, 累计快进 +${forwardSeekSeconds.value}s',
    );

    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      showForwardSeek.value = false;
      forwardSeekSeconds.value = 0;
    });
  }

  /// 双击中屏：播放 / 暂停切换
  void onDoubleTapCenter() {
    togglePlay(revealControls: false);
    HapticFeedback.lightImpact();
  }

  void commitBackwardSeek(Duration delta) {
    showBackwardSeek.value = false;
  }

  void commitForwardSeek(Duration delta) {
    showForwardSeek.value = false;
  }

  /// 长按进入 2.0X 倍速
  void startSpeeding() {
    if (!playing.value) return;
    HapticFeedback.lightImpact();
    _preSpeed = speed.value;
    isSpeeding.value = true;
    _videoPlayerController?.setPlaybackSpeed(2.0);
  }

  /// 松开恢复原倍速
  void stopSpeeding() {
    if (isSpeeding.value) {
      isSpeeding.value = false;
      _videoPlayerController?.setPlaybackSpeed(_preSpeed);
    }
  }

  Future<void> _disposeCurrentPlayer() async {
    _liveSeekActive = false;
    _scrubLatestTarget = null;
    isScrubbing.value = false;
    isSeeking.value = false;
    try {
      await _scrubFinishTask;
    } catch (_) {
      // Cleanup is best-effort; disposing the player must still proceed.
    }
    _scrubFinishTask = null;
    try {
      await _scrubSeekTask;
    } catch (_) {
      // A scrub may be canceled while its final platform request is being disposed.
    }
    _scrubSeekTask = null;
    await _awaitScrubPause(_scrubPauseTask);
    await _awaitScrubPause(_seekPauseTask);
    _scrubPauseTask = null;
    _seekPauseTask = null;
    await _stopNativeScrubbing();
    _activeScrubController = null;

    isInitialized.value = false;
    playing.value = false;
    buffering.value = false;
    HlsCacheProxy.instance.stopCurrentAcceleration();
    final old = _videoPlayerController;
    _videoPlayerController = null;
    if (old != null) {
      old.removeListener(_onPlayerValueChanged);
      try {
        // Pause first so a route or card switch cannot leave the previous audio audible.
        await old.pause();
      } catch (_) {
        // best-effort：旧实例可能已释放，pause 失败无后果，继续走 dispose。
      }
      try {
        await old.dispose();
      } catch (_) {
        // best-effort 清理：旧播放器实例释放失败不阻断新实例接管。
      }
    }
  }

  /// 手动激活当前视频的极速全片下载管线
  void startFullSpeedForCurrentVideo() {
    if (PlayerService.instance.usesNativeMediaCache) return;
    final cur = video.value;
    if (cur == null) return;
    final directUrl = cur.hlsUrl.trim();
    final remoteHls =
        PreloadService.instance.getCachedHlsUrl(cur) ??
        (PreloadService.instance.isFreshPlaybackUrl(cur, directUrl)
            ? directUrl
            : '');
    if (remoteHls.isNotEmpty &&
        !remoteHls.startsWith('/') &&
        !remoteHls.startsWith('file://')) {
      HlsCacheProxy.instance.triggerAccelerationForVideo(
        cur,
        remoteHls,
        referer: cur.detailUrl,
      );
    }
  }

  // ----------------------------------------------------------- 核心媒体与解析逻辑
  /// 上报官网观看记录（fire-and-forget，失败不影响播放）。
  ///
  /// 官网的觀看紀錄由服务端在收到 watch 页请求时写入。这里**必须**独立发一次，
  /// 不能依赖 [_prepareAndOpen] 里的详情拉取 —— 详情带 15 分钟缓存，用户点开时
  /// 常常直接命中缓存、一个请求都不发，于是官网记不到；而后台预取反倒会把
  /// watch 页拉一遍，造成「真正点开的不记录、预取过的反而记录了」。
  Future<void> _reportWatched(String targetUrl) async {
    try {
      if (!Get.isRegistered<VideoSource>()) return;
      await Get.find<VideoSource>().markWatched(targetUrl);
    } catch (e) {
      AppLogger.w('Player', '上报观看记录异常: $e');
    }
  }

  Future<void> _prepareAndOpen(
    VideoItem item, {
    bool forceRefresh = false,
  }) async {
    final generation = _videoSwitchGeneration;
    _playerOpenAt = null;
    _firstPlaybackPositionLogged = false;
    final targetUrl = item.detailUrl ?? item.id;
    _refreshPlaylistEpisodes(item);

    // 用户主动点开 → 上报官网观看记录。
    // 放在所有分支之前：下面的快路径（预加载命中 / 缓存命中）都不会请求 watch 页，
    // 若不在这里补一次，官网就永远记不到用户真正看过的片子。
    // unawaited：不阻塞起播。
    unawaited(_reportWatched(targetUrl));

    try {
      await _pauseOtherControllers(except: this);
      if (generation != _videoSwitchGeneration) return;
      await _disposeCurrentPlayer();
      if (generation != _videoSwitchGeneration) return;
      // 0. 极速提前起播命中：若卡片按下时已提前开启播放，直接复用，0 等待瞬间出画！
      if (!forceRefresh && PlayerService.instance.isPreplaying(item)) {
        final preloadedUrl = PlayerService.instance.currentOpeningUrl;
        final preloaded = PlayerService.instance.takePreloadedController(item);
        if (preloaded != null) {
          final source = Get.isRegistered<VideoSource>()
              ? Get.find<VideoSource>()
              : null;
          if (source is Site91Source) {
            var ready =
                preloaded.value.isInitialized && !preloaded.value.hasError;
            if (!ready && !preloaded.value.hasError) {
              ready = await _waitForPlayerInitialization(preloaded);
            }
            if (generation != _videoSwitchGeneration) {
              await preloaded.dispose();
              return;
            }
            if (!ready) {
              AppLogger.w('Player', '91 预打开播放器未能就绪，丢弃旧流并强制刷新播放地址');
              try {
                await preloaded.dispose();
              } catch (_) {}
              await _prepareAndOpen(item, forceRefresh: true);
              return;
            }
          }
          AppLogger.i(
            'Player',
            '⚡ 命中提前打开的原生控制器 '
                '(ready=${preloaded.value.isInitialized})，直接接管',
          );
          _videoPlayerController = preloaded;
          isInitialized.value = preloaded.value.isInitialized;
          preloaded.addListener(_onPlayerValueChanged);
          resolving.value = false;
          resolveStatus.value = '';
          final activeVideo = item.copyWith(
            hlsUrl: preloadedUrl ?? item.hlsUrl,
          );
          video.value = activeVideo;
          update();

          if (!preloaded.value.isPlaying) {
            preloaded.play();
          }
          // 起播即开始全量预缓存（Android）：整片落进 Media3 共享缓存，
          // 之后拖动、重播都走本地，不再碰网络。
          if (!_isPornHubPlayback) {
            PreloadService.instance.scheduleNativePreload(
              activeVideo,
              activeVideo.hlsUrl,
              full: true,
            );
          }
          _fetchDetailSilently(
            targetUrl,
            activeVideo,
            forceRefresh: forceRefresh,
          );
          return;
        }
      }

      // The tapped card may still be resolving a pre-open URL. Invalidate that
      // background attempt now so it cannot allocate an unowned player while
      // this route is resolving/opening the stream itself.
      PlayerService.instance.clearPreplay();

      final isFullSpeed = HlsCacheProxy.instance.isFullSpeedEnabled.value;
      final cachedHls = PreloadService.instance.getCachedHlsUrl(item);

      // 1. 极致共存秒开分支：预加载首切片瞬间开屏 + HLS 后台并行缓存
      if (!forceRefresh &&
          isFullSpeed &&
          cachedHls != null &&
          cachedHls.isNotEmpty) {
        AppLogger.i(
          'Player',
          '⚡ [预加载 + 极速加载双剑合璧] 命中缓存后起播并激活 HLS 后台预载: $cachedHls',
        );
        resolving.value = false;
        resolveStatus.value = '';
        final streamVideo = item.copyWith(hlsUrl: cachedHls);
        video.value = streamVideo;
        unawaited(_open(streamVideo, generation: generation));

        _fetchDetailSilently(
          targetUrl,
          streamVideo,
          forceRefresh: forceRefresh,
        );
        return;
      }

      // 若极速加载关闭，且命中本地预载切片混合流，走本地 file
      if (!forceRefresh &&
          !isFullSpeed &&
          PreloadService.instance.hasPreload(item)) {
        final preloadedUrl = await PreloadService.instance.getPlayableUrl(item);
        if (generation != _videoSwitchGeneration) return;
        if (preloadedUrl != null && preloadedUrl.isNotEmpty) {
          AppLogger.i('Player', '⚡ 命中本地分片秒开混合流，直接 0ms 瞬间起播: $preloadedUrl');
          resolving.value = false;
          resolveStatus.value = '';
          final preloadedVideo = item.copyWith(hlsUrl: preloadedUrl);
          video.value = preloadedVideo;
          unawaited(_open(preloadedVideo, generation: generation));

          _fetchDetailSilently(
            targetUrl,
            preloadedVideo,
            forceRefresh: forceRefresh,
          );
          return;
        }
      }

      // 2. 次级极速秒开分支：Stage 1 已预嗅探到真实流地址或缓存命中，无需等待网页抓取，直接 0ms 直连起播！
      if (!forceRefresh && cachedHls != null && cachedHls.isNotEmpty) {
        AppLogger.i('Player', '⚡ 命中内存已预嗅探流地址，跳过网页爬虫，直接 0ms 直连起播: $cachedHls');
        resolving.value = false;
        resolveStatus.value = '';
        final streamVideo = item.copyWith(hlsUrl: cachedHls);
        video.value = streamVideo;
        unawaited(_open(streamVideo, generation: generation));

        _fetchDetailSilently(
          targetUrl,
          streamVideo,
          forceRefresh: forceRefresh,
        );
        return;
      }

      // List/search entries can already carry a playable stream URL. Start it
      // at once and fetch the remaining page metadata without delaying playback.
      final directUrl = item.hlsUrl.trim();
      if (!forceRefresh &&
          PreloadService.instance.isFreshPlaybackUrl(item, directUrl)) {
        AppLogger.i('Player', '⚡ 使用列表已提供的直播放址立即起播: $directUrl');
        resolving.value = false;
        resolveStatus.value = '';
        final streamVideo = item.copyWith(hlsUrl: directUrl);
        video.value = streamVideo;
        unawaited(_open(streamVideo, generation: generation));
        _fetchDetailSilently(targetUrl, streamVideo);
        return;
      }

      // 3. 常规分支：未命中任何预热时，现场拉取详情并播放
      resolving.value = true;
      resolveStatus.value = '正在解析播放地址…';
      AppLogger.i(
        'Player',
        '开始现场解析视频详情 (forceRefresh=$forceRefresh): $targetUrl',
      );

      final source = Get.find<VideoSource>();
      // 诊断：确认现场解析用的是哪个源（PornHub 卡死排查用）。
      AppLogger.i(
        'Player',
        '🔎 现场解析使用的源: id=${source.id} type=${source.runtimeType}',
      );
      final detail = await source.fetchDetail(
        targetUrl,
        forceRefresh: forceRefresh,
      );
      AppLogger.i(
        'Player',
        '🔀 fetchDetail 返回: gen=$generation cur=$_videoSwitchGeneration '
            'detail=${detail != null} hls=${detail?.video.hlsUrl.length ?? 0}B',
      );
      if (generation != _videoSwitchGeneration) return;

      if (detail != null) {
        _refreshPlaylistEpisodes(item);
        sourceVariants.assignAll(detail.variants);
        final newHls = detail.video.hlsUrl.isNotEmpty
            ? detail.video.hlsUrl
            : item.hlsUrl;
        final updated = item.copyWith(
          title: detail.video.title.isNotEmpty
              ? detail.video.title
              : item.title,
          hlsUrl: newHls,
          publishedAt: detail.video.publishedAt ?? item.publishedAt,
          viewsStr: detail.video.viewsStr ?? item.viewsStr,
          author: detail.video.author.isNotEmpty
              ? detail.video.author
              : item.author,
        );
        AppLogger.i('Player', '📺 写入 video.value（准备触发界面重建）');
        video.value = updated;
        relatedVideos.assignAll(detail.relatedVideos);
        AppLogger.i(
          'Player',
          '📚 相关推荐已写入（${detail.relatedVideos.length} 条），开始预加载',
        );
        _preloadRelated(detail.relatedVideos, updated);
        AppLogger.i('Player', '✅ _preloadRelated 已返回，即将出画');
        if (source is Site91Source && detail.video.title.isEmpty) {
          unawaited(
            _applySite91DetailEnrichmentLater(
              source,
              targetUrl,
              updated,
              generation,
            ),
          );
        }

        if (newHls.isNotEmpty) {
          AppLogger.i('Player', '成功现场解析流，准备出画: $newHls');
          // Stream resolution is complete. Let the player show its own buffering
          // state while ExoPlayer initializes; recommendations must not cover it.
          resolving.value = false;
          resolveStatus.value = '';
          final opening = _open(updated, generation: generation);
          unawaited(_loadHanimeRelatedLater(targetUrl, updated, generation));
          await opening;
        } else {
          error.value = '未能嗅探到有效 M3U8 流地址';
        }
      } else {
        error.value = '解析详情失败，未获取到数据';
      }
    } catch (e, stack) {
      if (generation != _videoSwitchGeneration) return;
      error.value = '解析播放地址异常: $e';
      AppLogger.e('Player', '解析异常: $e', e, stack);
    } finally {
      if (generation == _videoSwitchGeneration) {
        resolving.value = false;
        resolveStatus.value = '';
      }
    }
  }

  Future<bool> _waitForPlayerInitialization(
    VideoPlayerController controller, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final timer = Stopwatch()..start();
    while (timer.elapsed < timeout) {
      final value = controller.value;
      if (value.hasError) return false;
      if (value.isInitialized) return true;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return controller.value.isInitialized && !controller.value.hasError;
  }

  /// 把相关推荐交给预加载服务 —— **hanime1 除外**。
  ///
  /// 为什么要按源区分：hanime1 播放页的「相關影片」实测一部片子会给到 **95 条**
  /// 上下，而 `preloadCount` 的默认值是 -1（= 全页全部），于是 `preloadList`
  /// 会把 95 个视频**全部**排进队列，逐个嗅探 m3u8 并下载首分片。队列虽然是串行
  /// 的，但总量太大，网络与磁盘被长时间占满，表现就是整机发卡。
  ///
  /// hanime1 只保留播放时的「极速加载」—— 那是 [HlsCacheProxy]，在 [_open] 里
  /// 独立触发后台 HLS 并发缓存，**不依赖**这里的预加载，所以关掉预加载不会
  /// 影响起播与播放体验。
  void _preloadRelated(List<VideoItem> related, VideoItem owner) {
    if (related.isEmpty) return;
    final url = owner.detailUrl ?? '';
    if (url.contains('hanime1.me') || url.contains('pornhub.com')) {
      AppLogger.i(
        'Player',
        '${url.contains('pornhub.com') ? 'pornhub' : 'hanime1'} 跳过预加载（相关推荐 ${related.length} 条，仅保留播放时的极速加载）',
      );
      return;
    }
    PreloadService.instance.preloadList(related, isNewPage: false);
  }

  /// 后台异步拉取详情（更新标题、作者、发布时间与相关推荐列表，不阻塞播放出画）
  void _fetchDetailSilently(
    String targetUrl,
    VideoItem currentVideo, {
    bool forceRefresh = false,
  }) {
    final generation = _videoSwitchGeneration;
    unawaited(() async {
      try {
        final source = Get.find<VideoSource>();
        final detail = await source.fetchDetail(
          targetUrl,
          forceRefresh: forceRefresh,
        );
        if (detail != null &&
            generation == _videoSwitchGeneration &&
            video.value?.id == currentVideo.id) {
          _refreshPlaylistEpisodes(currentVideo);
          video.value = currentVideo.copyWith(
            title: detail.video.title.isNotEmpty
                ? detail.video.title
                : currentVideo.title,
            publishedAt: detail.video.publishedAt ?? currentVideo.publishedAt,
            viewsStr: detail.video.viewsStr ?? currentVideo.viewsStr,
            author: detail.video.author.isNotEmpty
                ? detail.video.author
                : currentVideo.author,
          );
          sourceVariants.assignAll(detail.variants);
          relatedVideos.assignAll(detail.relatedVideos);
          _preloadRelated(detail.relatedVideos, currentVideo);
          // 91 deliberately returns the stream URL first and enriches page
          // metadata/recommendations asynchronously. The normal resolution
          // branch awaits that enrichment, but the pre-open/direct-URL branches
          // arrive here first and otherwise leave the related list empty for
          // the lifetime of the page.
          if (source is Site91Source && detail.video.title.isEmpty) {
            unawaited(
              _applySite91DetailEnrichmentLater(
                source,
                targetUrl,
                currentVideo,
                generation,
              ),
            );
          }
          if (detail.relatedVideos.isEmpty) {
            unawaited(
              _loadHanimeRelatedLater(targetUrl, currentVideo, generation),
            );
          }
        } else if (detail == null &&
            generation == _videoSwitchGeneration &&
            video.value?.id == currentVideo.id) {
          // 详情**拉取失败**（网络抖动 / 被拦）时，原来整块跳过、什么都不做。
          // 而 switchVideo 已经把 relatedVideos 清空了 —— 于是「相關影片」
          // 就停在「暂无相关推荐」并且**永不重试**。这就是用户反馈的
          // 「相关按钮有概率刷不出来」。
          // 这里补一次只拉相关推荐的兜底请求（它走独立入口，不依赖详情解析成功）。
          AppLogger.w('Player', '详情拉取失败，改用兜底请求加载相关推荐');
          unawaited(
            _loadHanimeRelatedLater(targetUrl, currentVideo, generation),
          );
        }
      } catch (e) {
        AppLogger.w('Player', '静默补充视频详情失败（不影响播放）: $e');
      }
    }());
  }

  Future<void> _applySite91DetailEnrichmentLater(
    Site91Source source,
    String targetUrl,
    VideoItem owner,
    int generation,
  ) async {
    try {
      final detail = await source.waitForDetailEnrichment(targetUrl);
      if (detail == null ||
          generation != _videoSwitchGeneration ||
          video.value?.id != owner.id) {
        return;
      }
      final current = video.value!;
      final enriched = current.copyWith(
        title: detail.video.title.isNotEmpty
            ? detail.video.title
            : current.title,
        author: detail.video.author.isNotEmpty
            ? detail.video.author
            : current.author,
        publishedAt: detail.video.publishedAt ?? current.publishedAt,
        viewsStr: detail.video.viewsStr ?? current.viewsStr,
      );
      video.value = enriched;
      sourceVariants.assignAll(detail.variants);
      relatedVideos.assignAll(detail.relatedVideos);
      _preloadRelated(detail.relatedVideos, enriched);
      AppLogger.i('Player', '91 播放详情已补齐：相关推荐 ${detail.relatedVideos.length} 条');
      update();
    } catch (e) {
      AppLogger.w('Player', '91 播放详情后台补齐失败（不影响播放）: $e');
    }
  }

  Future<void> _loadHanimeRelatedLater(
    String targetUrl,
    VideoItem owner,
    int generation,
  ) async {
    if (!(owner.detailUrl ?? targetUrl).contains('hanime1.me')) return;
    if (generation != _videoSwitchGeneration || video.value?.id != owner.id) {
      return;
    }
    try {
      final source = Get.find<VideoSource>();
      if (source is! Hanime1Source) return;
      final related = await source.fetchRelatedVideos(targetUrl);
      if (generation != _videoSwitchGeneration || video.value?.id != owner.id) {
        return;
      }
      relatedVideos.assignAll(related);
      AppLogger.i('Player', 'Hanime1 相关推荐已加载：${related.length} 条');
    } catch (e) {
      AppLogger.w('Player', '延后加载 Hanime1 相关推荐失败: $e');
    }
  }

  Future<void> _open(
    VideoItem item, {
    required int generation,
    Duration startPosition = Duration.zero,
    bool shouldPlay = true,
  }) async {
    final openTimer = Stopwatch()..start();
    _playerOpenAt = DateTime.now();
    _firstPlaybackPositionLogged = false;
    VideoPlayerController? openingController;
    try {
      if (generation != _videoSwitchGeneration) return;
      error.value = null;
      duration.value = Duration.zero;
      buffered.value = Duration.zero;
      position.value = Duration.zero;
      _pendingSeekPosition = Duration.zero;
      if (_cacheProgressVideoId != item.id) {
        _cacheProgressVideoId = item.id;
        cacheDownloadFraction.value = null;
      }
      final cachedProgress = Media3CacheService.latestProgressFor(item.id);
      if (cachedProgress != null) _onMedia3PreloadProgress(cachedProgress);

      final isFullSpeed = HlsCacheProxy.instance.isFullSpeedEnabled.value;
      String playUrl = item.hlsUrl;

      if (!isFullSpeed) {
        try {
          final preloaded = await PreloadService.instance.getPlayableUrl(item);
          if (preloaded != null && preloaded.isNotEmpty) {
            playUrl = preloaded;
          }
        } catch (e) {
          // 播放源被**静默替换**为远端直链：用户侧只感觉到「预加载没生效/更慢」，
          // 而日志里看不到任何异常。这条对排障很关键，必须留痕。控制流不变。
          AppLogger.w('Player', '预加载可播地址获取失败，本次回退远端直链 id=${item.id}: $e');
        }
      } else {
        if (playUrl.startsWith('/') || playUrl.startsWith('file://')) {
          final remote = PreloadService.instance.getCachedHlsUrl(item);
          if (remote != null && remote.isNotEmpty) {
            playUrl = remote;
          }
        }
      }

      // getPlayableUrl may perform asynchronous filesystem work. A rapid item
      // switch during that await must not let this stale open dispose the new
      // video's controller below.
      if (generation != _videoSwitchGeneration) return;

      AppLogger.i(
        'Player',
        '⚡ [ExoPlayer] 打开媒体流 (isFullSpeed=$isFullSpeed): $playUrl',
      );

      await _disposeCurrentPlayer();
      if (generation != _videoSwitchGeneration) return;

      final controller = PlayerService.instance.createController(
        playUrl,
        referer: item.detailUrl,
        item: item,
      );
      openingController = controller;
      _videoPlayerController = controller;
      controller.addListener(_onPlayerValueChanged);

      await controller.initialize();
      if (_videoPlayerController != controller ||
          generation != _videoSwitchGeneration) {
        await controller.dispose();
        return;
      }
      AppLogger.i(
        'Player',
        '⚡ ${_playerSourceLabel()} 播放器就绪：${openTimer.elapsedMilliseconds}ms',
      );
      isInitialized.value = true;
      update();
      if (startPosition > Duration.zero) {
        final target = startPosition > controller.value.duration
            ? controller.value.duration
            : startPosition;
        await controller.seekTo(target);
      }
      await controller.setPlaybackSpeed(speed.value);
      if (shouldPlay) {
        await controller.play();
        AppLogger.i(
          'Player',
          '⚡ ${_playerSourceLabel()} 播放命令已接收：${openTimer.elapsedMilliseconds}ms',
        );
      } else {
        await controller.pause();
      }
      // Give the player the first cold-start request before starting the full background
      // cache, so preloading cannot delay initialization or the initial play command.
      if (!_isPornHubPlayback) {
        PreloadService.instance.scheduleNativePreload(
          item,
          playUrl,
          full: true,
        );
      }
      unawaited(refreshMediaTracks());
      if (generation != _videoSwitchGeneration) await controller.pause();
    } catch (e) {
      AppLogger.e('Player', 'ExoPlayer 打开媒体流失败: $e');
      if (generation != _videoSwitchGeneration) return;
      final failedController = openingController;
      if (failedController != null &&
          !identical(_videoPlayerController, failedController)) {
        // A listener may already have switched to a PornHub fallback while
        // this controller's initialize() was completing with an error.
        try {
          await failedController.dispose();
        } catch (_) {}
        return;
      }
      if (_isPornHubPlayback && failedController != null) {
        if (identical(_pornHubRecoveryController, failedController)) return;
        _pornHubRecoveryController = failedController;
      }
      if (_tryOpenNextPornHubVariant('open error') ||
          _tryRefreshPornHubStream('open error')) {
        return;
      }
      await _disposeCurrentPlayer();
      if (!_hasAutoRetried && video.value != null) {
        _hasAutoRetried = true;
        AppLogger.i('Player', '🔄 打开媒体流异常，正在自动强制刷新流地址重试...');
        await _prepareAndOpen(video.value!, forceRefresh: true);
        return;
      }
      error.value = '播放失败：$e';
    }
  }

  /// 切换到新的相关推荐视频并播放
  Future<void> switchVideo(VideoItem newVideo) async {
    AppLogger.i('Player', '切换视频: ${newVideo.title}');
    _playRequestAt = DateTime.now();
    final generation = ++_videoSwitchGeneration;
    _hasAutoRetried = false;
    _resetPornHubRecovery();
    _handledPlaybackEnd = false;
    resolving.value = false;
    resolveStatus.value = '';
    error.value = null;
    await _disposeCurrentPlayer();
    if (generation != _videoSwitchGeneration) return;
    video.value = newVideo;
    _refreshPlaylistEpisodes(newVideo);
    sourceVariants.clear();
    audioTracks.clear();
    videoTracks.clear();
    subtitlesEnabled.value = false;
    relatedVideos.clear();
    _lastHanimePositionUpdate = null;
    buffered.value = Duration.zero;
    _pendingSeekPosition = Duration.zero;
    await _prepareAndOpen(newVideo);
  }

  void skipToPreviousEpisode() {
    if (hasEpisodeNavigation) {
      final index = currentEpisodeIndex;
      if (index > 0) {
        unawaited(switchVideo(playlistEpisodes[index - 1]));
      }
      return;
    }
    seekBy(-30);
  }

  void skipToNextEpisode() {
    if (hasEpisodeNavigation) {
      final index = currentEpisodeIndex;
      if (index >= 0 && index < playlistEpisodes.length - 1) {
        unawaited(switchVideo(playlistEpisodes[index + 1]));
      }
      return;
    }
    seekBy(30);
  }

  Future<void> reload() async {
    final item = video.value;
    if (item == null) return;
    _playRequestAt = DateTime.now();
    _videoSwitchGeneration++;
    _hasAutoRetried = false;
    _resetPornHubRecovery();
    resolving.value = false;
    resolveStatus.value = '';
    await _disposeCurrentPlayer();
    buffered.value = Duration.zero;
    _pendingSeekPosition = Duration.zero;
    await _prepareAndOpen(item, forceRefresh: true);
  }

  Future<void> pause() async {
    try {
      await _videoPlayerController?.pause();
    } catch (_) {
      // 平台通道：播放器未初始化或已释放时 pause 无意义，静默是正确设计。
    }
  }

  Future<void> play() async {
    try {
      await _videoPlayerController?.play();
    } catch (_) {
      // 平台通道：播放器未初始化或已释放时 play 无意义，静默是正确设计。
    }
  }

  void togglePlay({bool revealControls = true}) {
    final vtl = _videoPlayerController;
    if (vtl != null) {
      if (vtl.value.isPlaying) {
        vtl.pause();
      } else {
        vtl.play();
      }
    }
    if (revealControls) pingControls();
  }

  /// 静默跳转进度（手势滑动 Seek 专用：不唤出任何控制栏，画面保持绝对纯净）
  void silentSeek(Duration target) {
    final dur = duration.value;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _pendingSeekPosition = clamped;
    _lastDoubleTapTime = DateTime.now();
    _requestSeek(clamped);
    showControls.value = false;
    _hideTimer?.cancel();
  }

  void seek(Duration target) {
    final dur = duration.value;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _pendingSeekPosition = clamped;
    _lastDoubleTapTime = DateTime.now();
    _requestSeek(clamped);
    pingControls();
  }

  void seekBy(int seconds, {bool revealControls = true}) {
    final now = DateTime.now();
    final Duration base;
    if (now.difference(_lastDoubleTapTime).inMilliseconds < 800 &&
        _pendingSeekPosition > Duration.zero) {
      base = _pendingSeekPosition;
    } else {
      base = isSeeking.value ? seekPreviewPosition.value : position.value;
    }
    final target = base + Duration(seconds: seconds);
    final dur = duration.value;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _pendingSeekPosition = clamped;
    _lastDoubleTapTime = now;
    _requestSeek(clamped);
    if (revealControls) pingControls();
  }

  String _playerSourceLabel() => _isPornHubPlayback
      ? 'PornHub'
      : (video.value?.detailUrl ?? '').contains('hanime1.me')
      ? 'Hanime1'
      : '91';

  void _requestSeek(Duration target) {
    final controller = _videoPlayerController;
    if (controller == null) return;
    _pendingVisualSeekTarget = target;
    _pendingVisualSeekAt = DateTime.now();
    // Keep the thumb at the requested location while ExoPlayer moves the demuxer.
    position.value = target;
    unawaited(
      controller.seekTo(target).catchError((Object error) {
        if (_pendingVisualSeekTarget == target) {
          _pendingVisualSeekTarget = null;
          _pendingVisualSeekAt = null;
        }
        AppLogger.w('Player', '${_playerSourceLabel()} seek 命令失败: $error');
      }),
    );
  }

  Future<void> setSpeed(double value) async {
    speed.value = value;
    await _videoPlayerController?.setPlaybackSpeed(value);
    pingControls();
  }

  Future<void> refreshMediaTracks() async {
    final player = _videoPlayerController;
    if (player == null || !player.value.isInitialized) return;
    try {
      if (player.isAudioTrackSupportAvailable()) {
        final tracks = await player.getAudioTracks();
        if (!identical(_videoPlayerController, player)) return;
        audioTracks.assignAll(tracks);
      } else {
        if (!identical(_videoPlayerController, player)) return;
        audioTracks.clear();
      }
    } catch (e) {
      if (!identical(_videoPlayerController, player)) return;
      AppLogger.w('Player', '读取音轨列表失败: $e');
      audioTracks.clear();
    }
    try {
      if (player.isVideoTrackSupportAvailable()) {
        final tracks = await player.getVideoTracks();
        if (!identical(_videoPlayerController, player)) return;
        videoTracks.assignAll(tracks);
      } else {
        if (!identical(_videoPlayerController, player)) return;
        videoTracks.clear();
      }
    } catch (e) {
      if (!identical(_videoPlayerController, player)) return;
      AppLogger.w('Player', '读取画质列表失败: $e');
      videoTracks.clear();
    }
  }

  Future<void> selectAudioTrack(VideoAudioTrack track) async {
    try {
      await _videoPlayerController?.selectAudioTrack(track.id);
      await refreshMediaTracks();
    } catch (e) {
      AppLogger.w('Player', '切换音轨失败: $e');
    }
  }

  Future<void> selectVideoTrack(VideoTrack? track) async {
    try {
      await _videoPlayerController?.selectVideoTrack(track);
      await refreshMediaTracks();
    } catch (e) {
      AppLogger.w('Player', '切换画质失败: $e');
    }
  }

  Future<void> setClosedCaptionFile(ClosedCaptionFile? file) async {
    final player = _videoPlayerController;
    if (player == null) return;
    await player.setClosedCaptionFile(
      file == null ? null : Future<ClosedCaptionFile>.value(file),
    );
    subtitlesEnabled.value = file != null;
    if (file == null) currentCaption.value = '';
  }

  Future<void> selectSourceVariant(VideoVariant variant) async {
    final current = video.value;
    if (current == null || variant.url == current.hlsUrl) return;
    final savedPosition = position.value;
    final shouldResume = playing.value;
    final generation = ++_videoSwitchGeneration;
    _hasAutoRetried = false;
    _resetPornHubRecovery();
    _handledPlaybackEnd = false;
    final updated = current.copyWith(hlsUrl: variant.url);
    video.value = updated;
    await _open(
      updated,
      generation: generation,
      startPosition: savedPosition,
      shouldPlay: shouldResume,
    );
  }

  @override
  void onClose() {
    _videoSwitchGeneration++;
    AppLogger.i(
      'Player',
      '⏹️ 销毁 PlayerController (id: $hashCode), 视频: ${video.value?.title}',
    );
    _activeControllers.remove(this);
    if (_isPornHubPlayback) {
      unawaited(
        PreloadService.instance.stopPornHubNativePreload(video.value?.id),
      );
    }
    if (_activeControllers.isEmpty) {
      PreloadService.instance.setPlaybackActive(false);
      HlsCacheProxy.instance.stopCurrentAcceleration();
      HanimeMp4RangeProxy.instance.setPrefetchEnabled(false);
    }
    _hideTimer?.cancel();
    _brightnessTimer?.cancel();
    _volumeTimer?.cancel();
    _volumeWriteTimer?.cancel();
    _pendingGestureVolume = null;
    _seekFeedbackTimer?.cancel();
    unawaited(_media3PreloadSubscription?.cancel());
    _media3PreloadSubscription = null;
    try {
      FlutterVolumeController.removeListener();
    } catch (_) {
      // best-effort 反注册：onClose 阶段失败无后果（进程即将回收该控制器）。
    }
    if (_activeControllers.isEmpty) {
      unawaited(
        FlutterVolumeController.updateShowSystemUI(true)
            .catchError((Object _) {}),
      );
    }
    WakelockPlus.disable().ignore();
    try {
      unawaited(
        ScreenBrightness().resetApplicationScreenBrightness().catchError(
          (Object _) {},
        ),
      );
    } catch (_) {
      // 平台能力：恢复系统亮度失败不应阻断页面关闭。
    }
    unawaited(_disposeCurrentPlayer());
    PlayerService.instance.clearPreplay();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    super.onClose();
  }
}
