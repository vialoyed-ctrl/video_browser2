/// 全局播放器服务：通过 Flutter video_player 管理播放（Android 默认使用 ExoPlayer）。
/// 负责视频流提前抢跑 (preOpen)、控制器生命周期管理、本地分片/网络 HLS 适配。
library;

import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:video_player/video_player.dart';

import '../core/app_logger.dart';
import '../data/models/video_item.dart';
import 'hanime_mp4_range_proxy.dart';
import 'hls_cache_proxy.dart';
import 'pornhub_auth_service.dart';
import 'preload_service.dart';

class PlayerService {
  PlayerService._();
  static final PlayerService instance = PlayerService._();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Android playback uses Media3's shared on-the-fly disk cache. The Dart
  /// loopback download proxies remain available on other platforms.
  bool get usesNativeMediaCache => Platform.isAndroid;

  VideoPlayerController? _preloadedController;
  String? _preloadedUrl;
  VideoItem? _preloadedItem;
  DateTime? _preOpenTime;
  int _preOpenGeneration = 0;

  String? get currentOpeningUrl => _preloadedUrl;
  VideoItem? get currentOpeningItem => _preloadedItem;

  Future<void> init() async {
    await HlsCacheProxy.instance.init();
    PreloadService.instance.onHanimeStreamResolved = (item, streamUrl) {
      unawaited(preOpen(item.copyWith(hlsUrl: streamUrl)));
    };
    PreloadService.instance.onSite91StreamResolved = (item, streamUrl) {
      unawaited(preOpen(item.copyWith(hlsUrl: streamUrl)));
    };
    AppLogger.i('PlayerService', '播放器服务就绪，Hanime1 MP4 代理按需初始化');
  }

  /// 检查某视频是否已经在提前起播池中
  bool isPreplaying(VideoItem item) {
    if (_preloadedItem?.id == item.id &&
        _preloadedUrl != null &&
        _preloadedController != null &&
        PreloadService.instance.isFreshPlaybackUrl(item, _preloadedUrl!)) {
      final elapsed = _preOpenTime != null
          ? DateTime.now().difference(_preOpenTime!).inMilliseconds
          : 0;
      // The first Hanime1 player is initialized while the user browses the
      // feed, so a 15-second window expires before many normal taps. Keep the
      // single warmed controller reusable for one minute; a new touch-down
      // still replaces it immediately when the user chooses another item.
      return elapsed < 60000;
    }
    return false;
  }

  /// 获取并接管已提前起播的控制器
  VideoPlayerController? takePreloadedController(VideoItem item) {
    if (isPreplaying(item)) {
      // Once ownership is transferred to PlayerController, any older async
      // preOpen call must not publish another hidden controller afterward.
      _preOpenGeneration++;
      final c = _preloadedController;
      _preloadedController = null;
      _preloadedUrl = null;
      _preloadedItem = null;
      _preOpenTime = null;
      return c;
    }
    return null;
  }

  void clearPreplay() {
    _preOpenGeneration++;
    _clearPreplayState();
  }

  void _clearPreplayState() {
    _disposePreloaded();
    _preloadedUrl = null;
    _preloadedItem = null;
    _preOpenTime = null;
  }

  void _disposePreloaded() {
    final old = _preloadedController;
    _preloadedController = null;
    if (old != null) {
      unawaited(() async {
        try {
          await old.pause();
          await old.dispose();
        } catch (_) {
          // best-effort 清理：预热实例可能已被接管或释放，
          // 失败无后果（引用已置空，GC 会回收）。静默是正确设计。
        }
      }());
    }
  }

  /// 防盗链 Referer：按**媒体地址的 host** 决定，而不是只信调用方传入的 referer。
  ///
  /// PornHub 的 `.ts` 分片**强制**校验 Referer（实测：不带 → 404，带 → 200），
  /// 而它的 HLS 清单（master/variant）不校验。调用方传入的 referer 来自
  /// `item.detailUrl`；一旦该字段为空（条目来自历史/下载、域名被重写等），
  /// 就会落到 91 兜底值 —— 那会让 PH 分片全部 404、表现为「无法播放」。
  ///
  /// 这里按 host 兜住：媒体在 phncdn / pornhub 上一律发 PornHub Referer。
  /// **只影响 PornHub**，其余源逐位不变（91 的媒体在 cdn*.jiuse3.cloud，
  /// hanime1 在 hanime1.me，都不命中该分支）。
  static String _resolveReferer(String url, String? provided) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('phncdn') || host.contains('pornhub')) {
      return 'https://cn.pornhub.com/';
    }
    return provided ?? 'https://91porny.com/';
  }

  /// 创建通用的 VideoPlayerController（自动区分本地文件与网络 HLS，并接入极速全速缓存代理）
  VideoPlayerController createController(
    String playUrl, {
    String? referer,
    VideoItem? item,
  }) {
    var effectivePlayUrl = playUrl;
    final headers = <String, String>{
      'User-Agent': defaultUserAgent,
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': _resolveReferer(effectivePlayUrl, referer),
    };
    final host = Uri.tryParse(effectivePlayUrl)?.host.toLowerCase() ?? '';
    if (host.contains('phncdn') || host.contains('pornhub')) {
      var cookie = 'age_verified=1; platform=pc';
      try {
        if (Get.isRegistered<PornHubAuthService>()) {
          final userCookie = PornHubAuthService.to.cookieHeader;
          if (userCookie.isNotEmpty) {
            cookie = 'age_verified=1; platform=pc; $userCookie';
          }
        }
      } catch (_) {}
      headers['Cookie'] = cookie;
    }

    final options = VideoPlayerOptions(
      mixWithOthers: true,
      // Use the persistent disk cache for long backward seeks instead of
      // retaining an hour of media in ExoPlayer's mobile memory buffer.
      backBufferDurationMs: 30000,
    );

    final isFullSpeed = HlsCacheProxy.instance.isFullSpeedEnabled.value;
    if (usesNativeMediaCache &&
        item != null &&
        (effectivePlayUrl.startsWith('/') ||
            effectivePlayUrl.startsWith('file://'))) {
      // The native cache can only reuse the real network resource. Avoid
      // routing Android playback through the separate Dart segment cache.
      effectivePlayUrl =
          PreloadService.instance.getCachedHlsUrl(item) ?? effectivePlayUrl;
    }
    if (usesNativeMediaCache &&
        (effectivePlayUrl.startsWith('http://') ||
            effectivePlayUrl.startsWith('https://'))) {
      HanimeMp4RangeProxy.instance.setPrefetchEnabled(false);
      return VideoPlayerController.networkUrl(
        Uri.parse(effectivePlayUrl),
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
    }

    final isHanimeMp4 =
        item != null &&
        (item.detailUrl ?? '').contains('hanime1.me/watch') &&
        HanimeMp4RangeProxy.isMp4Url(effectivePlayUrl);

    if (!isHanimeMp4) {
      // Give bandwidth back to the active HLS player and stop any Hanime
      // look-ahead started for the previously selected item.
      HanimeMp4RangeProxy.instance.setPrefetchEnabled(false);
    }
    if (isHanimeMp4) {
      final rangeProxy = HanimeMp4RangeProxy.instance;
      rangeProxy.setPrefetchEnabled(isFullSpeed);
      if (isFullSpeed) {
        final rangeUrl = rangeProxy.getProxiedUrl(
          url: effectivePlayUrl,
          videoId: item.id,
          referer: referer ?? item.detailUrl ?? 'https://hanime1.me/',
        );
        AppLogger.i('PlayerService', 'Hanime1 MP4 使用 Range 代理并发预取');
        return VideoPlayerController.networkUrl(
          Uri.parse(rangeUrl),
          httpHeaders: headers,
          videoPlayerOptions: options,
        );
      }
    }

    // 当极速加载开启且有 item 时，无论是预加载视频还是新视频，均通过 HlsCacheProxy 本地回环代理：
    // 本地已预载的首切片 0ms 秒出，后续切片 6 线程并发全速冲刺拉满！
    if (isFullSpeed && item != null) {
      String remoteUrl = effectivePlayUrl;
      if (remoteUrl.startsWith('/') || remoteUrl.startsWith('file://')) {
        final cached = PreloadService.instance.getCachedHlsUrl(item);
        if (cached != null &&
            cached.isNotEmpty &&
            !cached.startsWith('/') &&
            !cached.startsWith('file://')) {
          remoteUrl = cached;
        }
      }
      final proxiedUrl = HlsCacheProxy.instance.getProxiedPlayUrl(
        remoteUrl,
        item: item,
        referer: referer,
      );
      return VideoPlayerController.networkUrl(
        Uri.parse(proxiedUrl),
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
    }

    if (effectivePlayUrl.startsWith('/') ||
        effectivePlayUrl.startsWith('file://')) {
      final filePath = effectivePlayUrl.replaceFirst('file://', '');
      return VideoPlayerController.file(
        File(filePath),
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
    } else {
      return VideoPlayerController.networkUrl(
        Uri.parse(effectivePlayUrl),
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
    }
  }

  /// 零延迟提前起播：在手指按下卡片 (onTapDown) 或跳转前立即调用
  Future<void> preOpen(VideoItem item) async {
    // Repeated pointer/tap notifications for the same still-valid warm player
    // should not invalidate the initialization Future currently building it.
    if (_preloadedItem?.id == item.id &&
        _preloadedController != null &&
        isPreplaying(item)) {
      return;
    }
    final generation = ++_preOpenGeneration;
    try {
      if (_preloadedItem?.id == item.id &&
          _preloadedUrl != null &&
          !PreloadService.instance.isFreshPlaybackUrl(item, _preloadedUrl!)) {
        _clearPreplayState();
      }

      final isFullSpeed = HlsCacheProxy.instance.isFullSpeedEnabled.value;
      String? playUrl;
      if (isFullSpeed) {
        playUrl = PreloadService.instance.getCachedHlsUrl(item);
        final itemUrl = item.hlsUrl.trim();
        if (playUrl == null &&
            PreloadService.instance.isFreshPlaybackUrl(item, itemUrl)) {
          playUrl = itemUrl;
        }
      } else {
        if (PreloadService.instance.hasPreload(item)) {
          playUrl = await PreloadService.instance.getPlayableUrl(item);
          if (generation != _preOpenGeneration) return;
        }
        playUrl ??= PreloadService.instance.getCachedHlsUrl(item);
        final itemUrl = item.hlsUrl.trim();
        if (playUrl == null &&
            PreloadService.instance.isFreshPlaybackUrl(item, itemUrl)) {
          playUrl = itemUrl;
        }
      }

      if (playUrl == null || playUrl.isEmpty) {
        if (generation != _preOpenGeneration) return;
        PreloadService.instance.touchDown(item);
        return;
      }
      if (generation != _preOpenGeneration) return;

      final isHanimeMp4 =
          (item.detailUrl ?? '').contains('hanime1.me/watch') &&
          HanimeMp4RangeProxy.isMp4Url(playUrl);
      HanimeMp4RangeProxy.instance.setPrefetchEnabled(
        isHanimeMp4 && isFullSpeed && !usesNativeMediaCache,
      );
      if (isHanimeMp4 && isFullSpeed && !usesNativeMediaCache) {
        await HanimeMp4RangeProxy.instance.init();
        if (generation != _preOpenGeneration) return;
        unawaited(
          HanimeMp4RangeProxy.instance.prefetchInitial(
            videoId: item.id,
            url: playUrl,
            referer: item.detailUrl ?? 'https://hanime1.me/',
          ),
        );
      }

      if (_preloadedUrl == playUrl && _preloadedController != null) {
        if (isPreplaying(item)) return;
        // Do not keep an expired native controller alive when the same card is
        // tapped again. Its initialization may contain an expired signed URL.
        _clearPreplayState();
      }

      _disposePreloaded();
      _preloadedUrl = playUrl;
      _preloadedItem = item;
      _preOpenTime = DateTime.now();

      AppLogger.i('PlayerService', '播放器提前初始化 (极速加速=$isFullSpeed): $playUrl');
      final controller = createController(
        playUrl,
        referer: item.detailUrl,
        item: item,
      );
      _preloadedController = controller;
      final timer = Stopwatch()..start();

      try {
        await controller.initialize();
        if (generation != _preOpenGeneration) {
          // The controller may already have been transferred to a player or
          // disposed by a newer preOpen request. Only clean it up while this
          // service still owns it.
          if (identical(_preloadedController, controller)) {
            _clearPreplayState();
          }
          return;
        }
        AppLogger.i(
          'PlayerService',
          '预打开播放器就绪 (${timer.elapsedMilliseconds}ms, id=${item.id})',
        );
        // 预热阶段仅完成流解析与缓冲队列准备，绝不在后台无渲染窗口时调用 play()，
        // 避免 ExoPlayer 向空 Surface 灌帧导致硬件管道脱钩与灰屏
      } catch (e) {
        AppLogger.w('PlayerService', 'preOpen 预初始化异常: $e');
        if (identical(_preloadedController, controller)) _clearPreplayState();
      }
    } catch (e, stack) {
      AppLogger.e('PlayerService', '准备预打开播放器失败 id=${item.id}: $e', e, stack);
    }
  }

  Future<void> reset() async {
    clearPreplay();
  }
}
