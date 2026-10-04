/// HLS 视频切片预加载服务：在列表浏览时预先下载前 1~2 个分片并重写本地 m3u8，实现毫秒级秒开。
/// 支持用户自定义预加载数量与最大磁盘缓存容量（带 LRU 自动清理）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_logger.dart';
import '../data/models/video_item.dart';
import '../data/sources/video_source.dart';
import '../data/sources/watch_history.dart';
import 'hanime_mp4_range_proxy.dart';
import 'hls_cache_proxy.dart';
import 'hls_parser.dart';
import 'media3_cache_service.dart';
import 'video_cache_key.dart';

class PreloadService {
  PreloadService._();
  static final PreloadService instance = PreloadService._();

  static const String _prefPreloadCount = 'prefs_preload_count';
  static const String _prefMaxCacheSizeMB = 'prefs_preload_max_cache_mb';
  static const String _prefPreloadSegmentCount = 'prefs_preload_segment_count';

  /// 换行切分正则。提为常量，避免每次重写混合清单时重新编译。
  static final RegExp _newlineRe = RegExp(r'\r?\n');

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      validateStatus: (code) => code != null && code < 400,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ),
  );

  Directory? _cacheDir;
  final Set<String> _preloadedIds = <String>{};
  final Set<String> _inFlightIds = <String>{};
  final Queue<VideoItem> _queue = Queue<VideoItem>();
  bool _isProcessing = false;

  /// 内存中已解析就绪的真实 M3U8 流地址缓存映射（key: video.id -> hlsUrl）
  final Map<String, String> _resolvedHlsUrls = <String, String>{};
  final Map<String, DateTime> _resolvedHlsUrlTimes = <String, DateTime>{};
  static const Duration _site91StreamCacheMaxAge = Duration(minutes: 5);

  void _setResolvedUrl(String key, String url) {
    if (_resolvedHlsUrls.length >= 200) {
      final oldestKey = _resolvedHlsUrls.keys.first;
      _resolvedHlsUrls.remove(oldestKey);
      _resolvedHlsUrlTimes.remove(oldestKey);
    }
    _resolvedHlsUrls[key] = url;
    _resolvedHlsUrlTimes[key] = DateTime.now();
  }

  bool _isSite91Item(VideoItem item) {
    final url = (item.detailUrl ?? item.id).toLowerCase();
    if (url.contains('hanime1.me')) return false;
    if (Get.isRegistered<VideoSource>() &&
        Get.find<VideoSource>().id == 'site91') {
      return true;
    }
    return url.contains('91porn') ||
        url.contains('91p9.') ||
        url.contains('91tanhua') ||
        url.contains('hsex.icu');
  }

  bool _isFreshResolvedUrl(VideoItem item, String key, String url) {
    if (!_isSite91Item(item)) return true;
    final at = _resolvedHlsUrlTimes[key];
    return at != null &&
        _resolvedHlsUrls[key] == url &&
        DateTime.now().difference(at) <= _site91StreamCacheMaxAge &&
        _isSite91UrlUnexpired(url);
  }

  bool _isSite91UrlUnexpired(String url) {
    final expiresAt = int.tryParse(
      Uri.tryParse(url)?.queryParameters['t'] ?? '',
    );
    if (expiresAt == null) return true;
    final safeUntil = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
        .subtract(const Duration(seconds: 8));
    return DateTime.now().isBefore(safeUntil);
  }

  bool _hasFreshSite91DiskUrl(VideoItem item) {
    if (!_isSite91Item(item)) return true;
    if (_cacheDir == null) return false;
    final file = File(
      p.join(_cacheDir!.path, _safeCacheKey(item.id), 'source_url.txt'),
    );
    if (!file.existsSync()) return false;
    try {
      final url = file.readAsStringSync().trim();
      if (url.isEmpty || !_isSite91UrlUnexpired(url)) return false;
      return DateTime.now().difference(file.lastModifiedSync()) <=
          _site91StreamCacheMaxAge;
    } catch (_) {
      return false;
    }
  }

  /// Whether a URL carried by a history/detail item is still safe to open.
  /// Site91 signed streams need a current cache/source timestamp; other sources
  /// keep their previous direct-URL behavior.
  bool isFreshPlaybackUrl(VideoItem item, String url) {
    if (url.isEmpty) return false;
    // 先按 URL 自身带的过期时间判断。**这一步对 PornHub 尤其关键**：
    // 此前这里对「非 91 源」直接 `return true`（完全不看过期），
    // 于是预载缓存的 `hv-h` 地址过期后仍会被拿去播放，
    // ExoPlayer 拿到 410 Gone → 报 `Source error` → 界面「播放失败」。
    // 实测 PornHub 两套签名：`ev-h` 用 `validto=<unix秒>`，`hv-h` 用 `e=<unix秒>`。
    if (_isExpiredUrl(url)) return false;
    if (!_isSite91Item(item)) return true;
    return getCachedHlsUrl(item) == url;
  }

  /// URL 自带的过期时间是否已过。
  ///
  /// 只在参数值**看起来像 unix 时间戳**（>1e9）时才据此判定，
  /// 避免把同名的普通参数（例如 `?e=5`）误判成过期。
  /// 识别不出过期参数时返回 false（保守：宁可当它有效，也不要误杀可播地址）。
  static bool _isExpiredUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final key in const <String>['validto', 'e', 'expires', 'expire']) {
      final raw = uri.queryParameters[key];
      if (raw == null) continue;
      final parsed = int.tryParse(raw);
      if (parsed == null) continue;
      final seconds = parsed > 100000000000 ? parsed ~/ 1000 : parsed;
      if (seconds <= 1000000000) continue; // 不像时间戳，跳过
      // 留 5 秒余量，避免边界上刚好过期。
      return seconds <= nowSec + 5;
    }
    if (uri.host.endsWith('.phncdn.com')) {
      final expiry = RegExp(r'(?:^|~)exp=(\d+)')
          .firstMatch(uri.queryParameters['hdnea'] ?? '');
      final seconds = int.tryParse(expiry?.group(1) ?? '');
      if (seconds != null && seconds > 1000000000) {
        return seconds <= nowSec + 5;
      }
    }
    return false;
  }

  final Set<String> _resolvingIds = <String>{};
  final Queue<VideoItem> _resolveQueue = Queue<VideoItem>();
  int _activeResolvers = 0;
  static const int _maxConcurrentResolvers = 2;
  bool _playbackActive = false;
  String? _hanimePlayerWarmItemId;
  String? _site91PlayerWarmItemId;
  String? _site91PlaybackWarmupItemId;

  /// PlayerService installs this after the first frame. It opens one Hanime1
  /// stream silently while the user browses so a later tap can reuse the
  /// initialized native player instead of paying its startup latency.
  void Function(VideoItem item, String streamUrl)? onHanimeStreamResolved;

  /// During foreground 91 playback, pre-open only the first related video.
  /// This keeps related-video taps warm without running the full preload queue
  /// against the bandwidth used by the current stream.
  void Function(VideoItem item, String streamUrl)? onSite91StreamResolved;

  /// Give foreground playback the bandwidth previously used by list previews.
  void setPlaybackActive(bool active) {
    _playbackActive = active;
    if (!active) {
      _site91PlaybackWarmupItemId = null;
      _pumpResolvers();
      unawaited(_processQueue());
    }
  }

  /// 用户可配置：预加载数量（默认 8 条，覆盖首屏并限制后台流量）。
  final RxInt preloadCount = 8.obs;

  /// 用户可配置：最大缓存上限（MB，默认 500MB）
  final RxInt maxCacheSizeMB = 500.obs;

  /// 用户可配置：每个视频预加载的切片数量（1, 2, 3, 5, 10 等；默认 1 片，约 6~10 秒，极速秒开）
  final RxInt preloadSegmentCount = 1.obs;

  /// 预加载切片比例（备用）
  final RxDouble preloadPercent = 0.05.obs;

  /// 响应式当前缓存占用字节数
  final RxInt currentCacheSizeBytes = 0.obs;

  /// 是否启用了预加载
  bool get isPreloadEnabled => preloadCount.value != 0;

  /// 当前激活源是否认领该条目。
  ///
  /// 预加载队列与嗅探队列都是**全局单例**：切源后旧源排进去的任务不会自动消失，
  /// 而队列里的条目一旦被处理，就会用**当前激活源**去 `fetchDetail` 旧源的地址 ——
  /// 既浪费一次注定失败的请求，又白白占着主 isolate 做 HTML 解析。
  /// 所以每个入队/出队点都要过一遍这个判据。
  ///
  /// 源未注册时放行（无从判断，不误伤）。
  bool _ownedByActiveSource(VideoItem item) {
    if (!Get.isRegistered<VideoSource>()) return true;
    return Get.find<VideoSource>().ownsItem(item);
  }

  /// 生成文件系统安全的缓存目录键（避免 URL 中的非法字符）
  String _safeCacheKey(String id) => videoCacheKey(id);

  // --------------------------------------------------- Android 原生全量预缓存（Media3）
  //
  // Android 上播放走 Media3 的共享 SimpleCache，它只存解码器**实际读过**的字节，
  // 所以任何视频的第一次打开必然是冷启动。这里把 Stage 1 解析出的真实流地址交给
  // Media3 自带的离线下载器（HLS → HlsDownloader，MP4 → ProgressiveDownloader），
  // 写入**同一个** SimpleCache —— 预下载的字节就是播放器要读的字节，
  // 不存在「下了一份、播的却是另一份」的重复流量。

  /// Native Media3 has two download-driver threads; keep speculative list work at
  /// that same bound and drain the queue as tasks finish.
  static const int _maxConcurrentNativeHeadPreloads = 2;

  /// Approximate HLS segment duration used to translate the user's segment-count
  /// setting into a native Media3 preload window.
  static const int _nativeSecondsPerSegment = 8;

  static const String _nativePreloadUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 用户已明确点击、正在等待进入播放的条目。
  String? _nativeFullRequestedId;

  /// 已提交「头部窗口」预取的条目。
  final Set<String> _nativeHeadScheduled = <String>{};
  final Queue<_NativePreloadRequest> _nativeHeadQueue =
      Queue<_NativePreloadRequest>();
  final Map<String, _NativePreloadRequest> _nativeHeadActive =
      <String, _NativePreloadRequest>{};

  /// 已提交「全量」预取的条目。
  String? _nativeFullScheduledId;
  String? _nativeFullScheduledUrl;
  bool _nativeFullActive = false;
  int _nativeFullRequestGeneration = 0;
  StreamSubscription<Media3PreloadProgress>? _nativeProgressSubscription;
  Timer? _cacheStatsRefreshTimer;
  bool _cacheStatsRefreshInFlight = false;
  bool _cacheStatsRefreshPending = false;

  /// 记录用户已明确选定某条目 —— 之后它一旦解析出流地址，就走全量而非头部预取。
  void markNativeFullRequested(VideoItem item) {
    _nativeFullRequestedId = item.id;
  }

  /// Reset third-module cache jobs when entering another player route.
  Future<void> resetPornHubNativePreloads() async {
    _nativeFullRequestGeneration++;
    _nativeFullRequestedId = null;
    _nativeFullScheduledId = null;
    _nativeFullScheduledUrl = null;
    _nativeFullActive = false;
    _nativeHeadQueue.clear();
    _nativeHeadScheduled.clear();
    _nativeHeadActive.clear();
    await Media3CacheService.cancelAllPreloads();
  }

  Future<void> stopPornHubNativePreload(String? videoId) async {
    if (videoId == null || _nativeFullScheduledId != videoId) return;
    _nativeFullRequestGeneration++;
    _nativeFullRequestedId = null;
    _nativeFullScheduledId = null;
    _nativeFullScheduledUrl = null;
    _nativeFullActive = false;
    await Media3CacheService.cancelPreload(videoId);
  }

  /// 把已解析的真实流地址交给 Android 原生预缓存。
  ///
  /// [full] 为 true 或该条目已被用户点击（见 [markNativeFullRequested]）时预取整片，
  /// 否则只预取一个头部窗口 —— 浏览阶段的投机预取不该吃满带宽。
  ///
  /// 非 Android 平台、预加载被关闭、条目不属于当前源、或地址是本地文件时静默跳过。
  void scheduleNativePreload(
    VideoItem item,
    String url, {
    bool full = false,
    bool playbackStarted = false,
  }) {
    if (!Platform.isAndroid) return;
    final pageHost = Uri.tryParse(item.detailUrl ?? '')?.host ?? '';
    final mediaHost = Uri.tryParse(url)?.host ?? '';
    final isPornHub =
        pageHost.endsWith('.pornhub.com') || mediaHost.endsWith('.phncdn.com');
    if (isPornHub) {
      // Start only after the foreground player is initialized. List warming
      // resolves URLs without competing with the selected video's cache job.
      if (!full || !playbackStarted) return;
    }
    if (!_ownedByActiveSource(item)) return;
    if (url.isEmpty || url.startsWith('/') || url.startsWith('file://')) return;

    final turboEnabled = HlsCacheProxy.instance.isFullSpeedEnabled.value;
    if (full && !turboEnabled) return;
    final isFull = turboEnabled && (full || _nativeFullRequestedId == item.id);
    // Explicitly opened videos always get a full background cache job, even when
    // speculative list preloading is disabled in settings.
    if (!isPreloadEnabled && !isFull) return;
    _ensureNativeProgressListener();
    if (isFull) {
      if (_nativeFullScheduledId == item.id &&
          (!isPornHub || _nativeFullScheduledUrl == url)) {
        return;
      }
      _nativeFullScheduledId = item.id;
      _nativeFullScheduledUrl = url;
      _nativeFullActive = true;
      final generation = ++_nativeFullRequestGeneration;
      // 用户已选定视频：浏览阶段的投机下载此刻是最不值钱的带宽占用，全部让给这一条。
      _nativeHeadQueue.clear();
      _nativeHeadScheduled.clear();
      _nativeHeadActive.clear();
      unawaited(_startNativeFullPreload(item, url, generation));
      return;
    }

    if (_nativeFullScheduledId == item.id) return;
    if (_nativeFullActive || !_nativeHeadScheduled.add(item.id)) return;
    _nativeHeadQueue.addLast(_NativePreloadRequest(item, url));
    _pumpNativeHeadPreloads();
  }

  void _ensureNativeProgressListener() {
    _nativeProgressSubscription ??= Media3CacheService.progress.listen((
      update,
    ) {
      var shouldPump = false;
      if (update.taskId == _nativeFullScheduledId) {
        if (update.hasError) {
          // Permit a later open/tap to retry a failed whole-video download.
          _nativeFullScheduledId = null;
          _nativeFullActive = false;
          shouldPump = true;
        } else if (update.finished) {
          _nativeFullActive = false;
          shouldPump = true;
        }
      }

      final request = _nativeHeadActive[update.taskId];
      if (request != null && (update.finished || update.hasError)) {
        _nativeHeadActive.remove(update.taskId);
        if (update.hasError && request.retryCount == 0) {
          _nativeHeadQueue.addFirst(request.retry());
        } else if (update.hasError) {
          _nativeHeadScheduled.remove(update.taskId);
        }
        shouldPump = true;
      }

      if (update.bytesDownloaded > 0 || update.finished) {
        _scheduleCacheStatsRefresh();
      }
      if (shouldPump) _pumpNativeHeadPreloads();
    });
  }

  void _pumpNativeHeadPreloads() {
    if (_nativeFullActive) return;
    while (_nativeHeadActive.length < _maxConcurrentNativeHeadPreloads &&
        _nativeHeadQueue.isNotEmpty) {
      final request = _nativeHeadQueue.removeFirst();
      final id = request.item.id;
      if (!_nativeHeadScheduled.contains(id)) continue;
      _nativeHeadActive[id] = request;
      unawaited(_submitNativeHeadPreload(request));
    }
  }

  Future<void> _submitNativeHeadPreload(_NativePreloadRequest request) async {
    final id = request.item.id;
    var accepted = false;
    try {
      accepted = await _startNativePreload(
        request.item,
        request.url,
        full: false,
      );
    } catch (error) {
      AppLogger.w('Preload', '提交列表预缓存异常 id=$id: $error');
    }
    if (accepted || !identical(_nativeHeadActive[id], request)) return;
    _nativeHeadActive.remove(id);
    if (request.retryCount == 0) {
      _nativeHeadQueue.addFirst(request.retry());
    } else {
      _nativeHeadScheduled.remove(id);
    }
    _pumpNativeHeadPreloads();
  }

  Future<void> _startNativeFullPreload(
    VideoItem item,
    String url,
    int generation,
  ) async {
    await Media3CacheService.cancelAllPreloads();
    if (generation != _nativeFullRequestGeneration ||
        _nativeFullScheduledId != item.id) {
      return;
    }
    final accepted = await _startNativePreload(item, url, full: true);
    if (!accepted && generation == _nativeFullRequestGeneration) {
      _nativeFullScheduledId = null;
      _nativeFullActive = false;
      _pumpNativeHeadPreloads();
    }
  }

  Future<bool> _startNativePreload(
    VideoItem item,
    String url, {
    required bool full,
  }) async {
    // hanime1 的官网流是直连 MP4，其余（91）是 HLS 清单。
    final isMp4 =
        (_isHanime1Item(item) ||
            Uri.tryParse(url)?.host.endsWith('.phncdn.com') == true) &&
        HanimeMp4RangeProxy.isMp4Url(url);
    final referer =
        item.detailUrl ??
        (isMp4 ? 'https://hanime1.me/' : 'https://91porny.com/');

    final reqHeaders = <String, String>{'Referer': referer};
    final isPornHub =
        url.contains('phncdn') ||
        url.contains('pornhub') ||
        (item.detailUrl ?? '').contains('pornhub');
    if (isPornHub) {
      reqHeaders['Referer'] = 'https://cn.pornhub.com/';
      reqHeaders['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
      reqHeaders['Cookie'] = 'age_verified=1; platform=pc';
    }

    final segmentCount = preloadSegmentCount.value.clamp(1, 10).toInt();
    final accepted = await Media3CacheService.preload(
      taskId: item.id,
      url: url,
      isHls: !isMp4,
      headers: reqHeaders,
      userAgent: _nativePreloadUserAgent,
      durationUs: full ? 0 : segmentCount * _nativeSecondsPerSegment * 1000000,
      lengthBytes: full ? 0 : HanimeMp4RangeProxy.chunkSize * segmentCount,
    );
    AppLogger.i(
      'Preload',
      '原生预缓存${accepted ? '已提交' : '未提交'}（${full ? '全量' : '头部窗口'}）'
          'id=${item.id} mp4=$isMp4 url=$url',
    );
    return accepted;
  }

  void _scheduleCacheStatsRefresh() {
    if (_cacheStatsRefreshTimer?.isActive ?? false) return;
    _cacheStatsRefreshTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_refreshDisplayedCacheSize());
    });
  }

  /// 初始化缓存根目录与读取用户持久化配置
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      preloadCount.value = prefs.getInt(_prefPreloadCount) ?? 8;
      maxCacheSizeMB.value = prefs.getInt(_prefMaxCacheSizeMB) ?? 500;
      preloadSegmentCount.value = prefs.getInt(_prefPreloadSegmentCount) ?? 1;
    } catch (e) {
      AppLogger.w('Preload', '读取预加载配置异常，使用默认值: $e');
    }

    final base = await getApplicationCacheDirectory();
    _cacheDir = Directory(p.join(base.path, 'video_browser', 'hls_preload'));
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    HanimeMp4RangeProxy.instance.setCacheLimitMB(maxCacheSizeMB.value);
    await Media3CacheService.setMaxCacheSizeMB(maxCacheSizeMB.value);

    AppLogger.i(
      'Preload',
      '初始化完成: 预加载数量=${preloadCount.value == -1 ? "全页全部" : preloadCount.value}, 切片数=${preloadSegmentCount.value}片/视频, 缓存上限=${maxCacheSizeMB.value}MB',
    );

    // 缓存统计与 LRU 修剪**刻意不 await**。
    //
    // 缓存目录里可能有上万个分片文件，全量统计要遍历整棵树（虽然已挪到后台
    // isolate，但 `init()` 本身是在 `runApp` 之前被 await 的，卡在这里就是
    // 实打实的启动白屏）。统计结果只用于设置页显示与 LRU 判断，晚几百毫秒
    // 没有任何影响。
    unawaited(_refreshCacheStats());
  }

  /// 刷新缓存占用并在超限时做一次 LRU 修剪（后台执行，不阻塞调用方）。
  Future<void> _refreshCacheStats() async {
    try {
      await _trimCache(force: true);
      AppLogger.i(
        'Preload',
        '缓存统计: 已用=${(currentCacheSizeBytes.value / 1024 / 1024).toStringAsFixed(1)}MB'
            ' / 上限=${maxCacheSizeMB.value}MB',
      );
    } catch (e) {
      AppLogger.w('Preload', '缓存统计失败: $e');
    }
  }

  /// Refresh cache usage when the settings sheet is opened.
  Future<void> refreshCacheStats() => _refreshCacheStats();

  /// 修改预加载数量并持久化
  Future<void> setPreloadCount(int count) async {
    preloadCount.value = count;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefPreloadCount, count);
    } catch (e) {
      // 注意：下面那行 AppLogger.i 会照常打印「更新成功」，若此处持久化失败，
      // 那条日志是**失真的**。故在此明确记 W，避免被下一条误导。控制流不变。
      AppLogger.w('Preload', '预加载数量持久化失败（本次运行内仍生效）: $e');
    }
    AppLogger.i('Preload', '更新预加载数量为: ${count == -1 ? "全页全部" : count}');
  }

  /// Keep the full-video switch in sync with Android's native full-cache job.
  Future<void> setFullSpeedEnabled(bool enabled) async {
    await HlsCacheProxy.instance.setFullSpeedEnabled(enabled);
    if (enabled || !Platform.isAndroid) return;

    final fullTaskId = _nativeFullScheduledId;
    _nativeFullRequestGeneration++;
    _nativeFullRequestedId = null;
    _nativeFullScheduledId = null;
    _nativeFullActive = false;
    if (fullTaskId != null) {
      await Media3CacheService.cancelPreload(fullTaskId);
    }
    _pumpNativeHeadPreloads();
  }

  /// 修改单视频预加载切片数量并持久化
  Future<void> setPreloadSegmentCount(int count) async {
    final clamped = math.max(1, count);
    preloadSegmentCount.value = clamped;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefPreloadSegmentCount, clamped);
    } catch (e) {
      // 同上：紧随其后的 i 日志会失真，此处先记 W。控制流不变。
      AppLogger.w('Preload', '预加载分片数持久化失败（本次运行内仍生效）: $e');
    }
    AppLogger.i('Preload', '更新单视频预加载分片数量为: $clamped 片');
  }

  /// 修改最大缓存上限并持久化
  Future<void> setMaxCacheSizeMB(int mb) async {
    maxCacheSizeMB.value = mb;
    HanimeMp4RangeProxy.instance.setCacheLimitMB(mb);
    await Media3CacheService.setMaxCacheSizeMB(mb);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefMaxCacheSizeMB, mb);
    } catch (e) {
      // 同上：紧随其后的 i 日志会失真，此处先记 W。控制流不变。
      AppLogger.w('Preload', '缓存上限持久化失败（本次运行内仍生效）: $e');
    }
    // 用户刚改完上限，应当立即生效 —— 绕过节流。
    await _trimCache(force: true);
    AppLogger.i('Preload', '更新预加载缓存上限为: ${mb}MB');
  }

  /// 快速同步获取内存或缓存中已解析就绪的真实远端 HLS 地址（若已存在，直接返回，耗时 0ms）
  String? getCachedHlsUrl(VideoItem item) {
    final requiresFreshUrl = _isSite91Item(item);
    if (item.hlsUrl.isNotEmpty &&
        !item.hlsUrl.startsWith('/') &&
        !item.hlsUrl.startsWith('file://') &&
        (!requiresFreshUrl ||
            _isFreshResolvedUrl(item, item.id, item.hlsUrl))) {
      return item.hlsUrl;
    }
    final cachedById = _resolvedHlsUrls[item.id];
    if (cachedById != null) {
      if (_isFreshResolvedUrl(item, item.id, cachedById)) return cachedById;
      _resolvedHlsUrls.remove(item.id);
      _resolvedHlsUrlTimes.remove(item.id);
    }
    final targetUrl = item.detailUrl ?? item.id;
    final cachedByUrl = _resolvedHlsUrls[targetUrl];
    if (cachedByUrl != null) {
      if (_isFreshResolvedUrl(item, targetUrl, cachedByUrl)) return cachedByUrl;
      _resolvedHlsUrls.remove(targetUrl);
      _resolvedHlsUrlTimes.remove(targetUrl);
    }
    if (Get.isRegistered<VideoSource>()) {
      final source = Get.find<VideoSource>();
      final cached = source.getCachedHlsUrl(targetUrl);
      if (cached != null && cached.isNotEmpty) {
        _setResolvedUrl(item.id, cached);
        return cached;
      }
    }
    if (_cacheDir != null) {
      final key = _safeCacheKey(item.id);
      final urlFile = File(p.join(_cacheDir!.path, key, 'source_url.txt'));
      if (urlFile.existsSync() && _hasFreshSite91DiskUrl(item)) {
        try {
          final saved = urlFile.readAsStringSync().trim();
          if (saved.isNotEmpty) {
            _setResolvedUrl(item.id, saved);
            return saved;
          }
        } catch (e) {
          // 读缓存 URL 失败 → 本次回退到远端重新解析（多一次网络往返）。
          // 用户侧只感觉「这次进播放页慢」，无日志时无法归因。控制流不变。
          AppLogger.w(
            'Preload',
            '读取缓存 URL 失败，回退远端解析 id=${item.id} file=${urlFile.path}: $e',
          );
        }
      }
    }
    return null;
  }

  /// 检查某视频是否已存在本地预加载可播 m3u8
  bool hasPreload(VideoItem item) {
    if (_cacheDir == null) return false;
    if (!_hasFreshSite91DiskUrl(item)) return false;
    final key = _safeCacheKey(item.id);
    final localM3u8 = File(p.join(_cacheDir!.path, key, 'play.m3u8'));
    return localM3u8.existsSync();
  }

  /// 获取本地可播 m3u8 路径（若已预加载），否则返回空
  Future<String?> getPlayableUrl(VideoItem item) async {
    if (_cacheDir == null) await init();
    final key = _safeCacheKey(item.id);
    final localM3u8 = File(p.join(_cacheDir!.path, key, 'play.m3u8'));
    if (await localM3u8.exists() && _hasFreshSite91DiskUrl(item)) {
      AppLogger.i('Preload', '⚡ 命中预加载缓存秒开: ${localM3u8.path}');
      return localM3u8.path;
    }
    return getCachedHlsUrl(item);
  }

  /// Batch-preload the user's selected number of items, resolving their stream
  /// URLs through a bounded background pool before filling the platform cache.
  void preloadList(List<VideoItem> items, {bool isNewPage = true}) {
    final count = preloadCount.value;
    if (count == 0 || items.isEmpty) return;

    // ---- 归属闸门：只预加载属于「当前激活内容源」的条目 ----
    //
    // 预加载队列是全局单例，但一个页面上的条目只对当前源有意义。切源之后
    // 旧源的控制器依然存活并会继续往这里塞整页条目。
    //
    // 真机复现（用户在 hanime1 版面）：启动 20 秒内产生 44 次预加载 + 68 次
    // 流嗅探 + 40 次 LRU 清理，全部是 91 的视频 —— 主 isolate 被占满，最终
    // ANR（trace 里主线程卡在 `HlsParser.parse`）。根源是 91 的 HomeController
    // 被 `AppDrawer` 的 `Get.find` 顺带创建，其 `onInit` 拉整页后调到这里。
    final active = Get.isRegistered<VideoSource>()
        ? Get.find<VideoSource>()
        : null;
    final owned = active == null
        ? items
        : items.where(active.ownsItem).toList();
    if (owned.isEmpty) {
      AppLogger.i(
        'Preload',
        '跳过预加载：本批 ${items.length} 条均不属于当前内容源「${active?.displayName}」',
      );
      return;
    }
    if (owned.length != items.length) {
      AppLogger.i(
        'Preload',
        '预加载过滤：${items.length} 条中 ${items.length - owned.length} 条不属于'
            '当前内容源「${active?.displayName}」，已剔除',
      );
    }

    // 当 count < 0 时为全页全部视频；否则取前 count 个
    final targets = (count < 0 || count >= owned.length)
        ? owned
        : owned.take(count).toList();

    // Stage 1：立即并发嗅探流地址（轻量文本请求，极速填满内存缓存）
    preResolveStreamUrls(targets, isNewPage: isNewPage);

    // Android 的 Stage 2 由 Media3 的共享缓存队列承担；Dart 分片代理
    // 在 Android 不参与播放，不能把空任务塞进这个本地队列。
    if (Platform.isAndroid) return;

    // Stage 2：排队下载首分片。Hanime1 的官网流是直连 MP4，
    // fetchDetail 的 Stage 1 仍要执行（它同时缓存播放页详情和相关推荐 HTML），
    // 但不能把 MP4 当作 HLS 清单解析。
    final hlsTargets = targets.where((item) => !_isHanime1Item(item)).toList();
    if (isNewPage) {
      _queue.clear();
      for (final item in hlsTargets) {
        final key = _safeCacheKey(item.id);
        if (!_preloadedIds.contains(key) && !_inFlightIds.contains(key)) {
          _queue.add(item);
        }
      }
    } else {
      for (final item in hlsTargets) {
        final key = _safeCacheKey(item.id);
        if (!_preloadedIds.contains(key) && !_inFlightIds.contains(key)) {
          _queue.add(item);
        }
      }
    }
    final hanimeTargetCount = targets.where(_isHanime1Item).length;
    if (hanimeTargetCount > 0) {
      AppLogger.i(
        'Preload',
        'Hanime1 预取 $hanimeTargetCount 条详情和播放流；'
            '跳过 MP4 的 HLS 分片缓存',
      );
    }
    _processQueue();
  }

  /// Stage 1：受并发数限制的流地址预嗅探池。
  void preResolveStreamUrls(List<VideoItem> items, {bool isNewPage = true}) {
    if (!isPreloadEnabled) return;
    // The caller has already applied the user's page-preload limit. Resolve all
    // requested items through the bounded resolver pool so “全页全部” really
    // covers the full page rather than silently stopping after the first eight.
    final topItems = items;
    if (topItems.isEmpty) return;
    if (isNewPage) {
      _resolveQueue.clear();
      _hanimePlayerWarmItemId = null;
      _site91PlayerWarmItemId = null;
    }
    if (!_playbackActive && onHanimeStreamResolved != null) {
      for (final item in topItems) {
        if (_isHanime1Item(item)) {
          _hanimePlayerWarmItemId = item.id;
          break;
        }
      }
    }
    for (final item in topItems) {
      final cached = getCachedHlsUrl(item);
      if (cached != null && cached.isNotEmpty) {
        _warmFirstHanimePlayer(item, cached);
        _warmFirstSite91Player(item, cached);
        continue;
      }
      if (_resolvingIds.contains(item.id)) continue;
      _resolveQueue.add(item);
    }
    if (_playbackActive && onSite91StreamResolved != null) {
      VideoItem? firstRelated;
      for (final item in topItems) {
        if (_isSite91Item(item)) {
          firstRelated = item;
          break;
        }
      }
      if (firstRelated != null) {
        final warmItem = firstRelated;
        _site91PlayerWarmItemId = warmItem.id;
        final cached = getCachedHlsUrl(warmItem);
        if (cached != null && cached.isNotEmpty) {
          _warmFirstSite91Player(warmItem, cached);
        } else {
          _site91PlaybackWarmupItemId = warmItem.id;
          _resolveQueue.removeWhere((item) => item.id == warmItem.id);
          _resolveQueue.addFirst(warmItem);
        }
      }
    }
    _pumpResolvers();
  }

  void _pumpResolvers() {
    while (_activeResolvers < (_playbackActive ? 1 : _maxConcurrentResolvers) &&
        _resolveQueue.isNotEmpty) {
      if (_playbackActive) {
        final warmupId = _site91PlaybackWarmupItemId;
        if (warmupId == null || _resolveQueue.first.id != warmupId) return;
        _site91PlaybackWarmupItemId = null;
      }
      final item = _resolveQueue.removeFirst();
      final key = item.id;
      final cached = getCachedHlsUrl(item);
      if (cached != null && cached.isNotEmpty) continue;
      if (_resolvingIds.contains(key)) continue;

      _resolvingIds.add(key);
      _activeResolvers++;
      _resolveItemStreamUrl(item).whenComplete(() {
        _activeResolvers--;
        _resolvingIds.remove(key);
        _pumpResolvers();
      });
    }
  }

  Future<void> _resolveItemStreamUrl(VideoItem item) async {
    // 这里用的是**当前激活源**的 `fetchDetail`，所以旧源的条目一旦混进来，
    // 就等于拿 B 站的解析器去解析 A 站的地址：注定失败，却要白白付出一次
    // 整页抓取 + 主 isolate 上的 HTML 解析。
    if (!_ownedByActiveSource(item)) return;
    try {
      final targetUrl = item.detailUrl ?? item.id;
      if (Get.isRegistered<VideoSource>()) {
        final source = Get.find<VideoSource>();
        // 后台预取必须**匿名**拉详情：官网的觀看紀錄由服务端在收到 watch 页
        // 请求时写入，带登录态预取会给用户刷出从没点开过的观看记录。
        // 用户主动点开的那次记录由 PlayerController 走 markWatched 完成。
        final detail = await source.fetchDetailAnonymously(targetUrl);
        if (detail != null && detail.video.hlsUrl.isNotEmpty) {
          _setResolvedUrl(item.id, detail.video.hlsUrl);
          _setResolvedUrl(targetUrl, detail.video.hlsUrl);
          _warmFirstHanimePlayer(item, detail.video.hlsUrl);
          _warmFirstSite91Player(item, detail.video.hlsUrl);
          // Android 上顺手把这一段送进 Media3 共享缓存：浏览阶段只取头部窗口，
          // 若用户已经点过这一条（markNativeFullRequested）则取整片。
          scheduleNativePreload(item, detail.video.hlsUrl);
          AppLogger.i(
            'Preload',
            '⚡ [Stage 1 预嗅探] 成功提取视频 [${item.title}] 流地址: ${detail.video.hlsUrl}',
          );
        }
      }
    } catch (e) {
      AppLogger.w('Preload', '[Stage 1 预嗅探] 解析 [${item.title}] 异常: $e');
    }
  }

  /// 卡片触摸按下时即刻预热（将该视频插入嗅探与切片队列绝对最高优先级）
  void touchDown(VideoItem item) {
    if (!_ownedByActiveSource(item)) return;
    // 用户已经明确点开这一条：标记为「全量预取」，并在地址已知时立刻开工。
    // 地址未知的情况由 Stage 1 解析完成后的 scheduleNativePreload 接续。
    if (HlsCacheProxy.instance.isFullSpeedEnabled.value) {
      markNativeFullRequested(item);
      final knownUrl = getCachedHlsUrl(item);
      if (knownUrl != null && knownUrl.isNotEmpty) {
        scheduleNativePreload(item, knownUrl, full: true);
      }
    }
    if (_isHanime1Item(item)) {
      // Hanime1 uses progressive MP4. Its stream URL is resolved in Stage 1;
      // the native player is silently pre-opened for only the first visible
      // result. A touched card still takes priority if it is another item.
      _hanimePlayerWarmItemId = item.id;
      final cachedUrl = getCachedHlsUrl(item);
      if (cachedUrl != null && cachedUrl.isNotEmpty) return;
      if (!isPreloadEnabled) return;
      if (!_resolvingIds.contains(item.id)) {
        _resolveQueue.removeWhere((queued) => queued.id == item.id);
        _resolveQueue.addFirst(item);
        AppLogger.i('Preload', 'Hanime1 卡片触摸：优先预取详情和 MP4 首段');
        _pumpResolvers();
      }
      return;
    }
    if (!isPreloadEnabled) return;
    // Android's Media3 cache is filled by the actual pre-open/player request.
    // Downloading the same HLS segment into a separate Dart cache wastes
    // bandwidth and cannot help the native player's seek path.
    if (Platform.isAndroid) return;
    final key = _safeCacheKey(item.id);
    final targetDir = Directory(p.join(_cacheDir!.path, key));
    final localM3u8 = File(p.join(targetDir.path, 'play.m3u8'));
    if (localM3u8.existsSync() && _hasFreshSite91DiskUrl(item)) {
      _preloadedIds.add(key);
      return;
    }
    _preloadedIds.remove(key);

    // 优先插入嗅探队列最前端
    if (getCachedHlsUrl(item) == null && !_resolvingIds.contains(item.id)) {
      _resolveQueue.removeWhere((x) => x.id == item.id);
      _resolveQueue.addFirst(item);
      _pumpResolvers();
    }

    if (_inFlightIds.contains(key)) return;
    _queue.removeWhere((x) => x.id == item.id);
    _queue.addFirst(item);
    _processQueue();
  }

  void _warmFirstHanimePlayer(VideoItem item, String url) {
    if (_playbackActive || _hanimePlayerWarmItemId != item.id) return;
    final callback = onHanimeStreamResolved;
    if (callback == null) return;
    _hanimePlayerWarmItemId = null;
    callback(item.copyWith(hlsUrl: url), url);
  }

  void _warmFirstSite91Player(VideoItem item, String url) {
    if (_site91PlayerWarmItemId != item.id) return;
    final callback = onSite91StreamResolved;
    if (callback == null) return;
    _site91PlayerWarmItemId = null;
    callback(item.copyWith(hlsUrl: url), url);
  }

  /// 单个视频预加载核心逻辑
  Future<void> preload(VideoItem item) async {
    if (Platform.isAndroid) return;
    if (_isHanime1Item(item)) return;
    if (_cacheDir == null) await init();
    if (!isPreloadEnabled) return;
    // 队列是全局的，切源后里面可能还留着旧源的条目 —— 出队时再挡一道。
    if (!_ownedByActiveSource(item)) return;

    final key = _safeCacheKey(item.id);
    if (_inFlightIds.contains(key)) return;

    final targetDir = Directory(p.join(_cacheDir!.path, key));
    final localM3u8 = File(p.join(targetDir.path, 'play.m3u8'));
    if (await localM3u8.exists() && _hasFreshSite91DiskUrl(item)) {
      _preloadedIds.add(key);
      return;
    }
    _preloadedIds.remove(key);

    _inFlightIds.add(key);
    try {
      var hlsUrl = getCachedHlsUrl(item) ?? item.hlsUrl;

      // 1. 若没有 m3u8，调用数据源嗅探详情
      if (hlsUrl.isEmpty) {
        final targetUrl = item.detailUrl ?? item.id;
        if (Get.isRegistered<VideoSource>()) {
          final source = Get.find<VideoSource>();
          // 后台预取必须**匿名**拉详情：官网的觀看紀錄由服务端在收到 watch 页
          // 请求时写入，带登录态预取会给用户刷出从没点开过的观看记录。
          // 用户主动点开的那次记录由 PlayerController 走 markWatched 完成。
          final detail = await source.fetchDetailAnonymously(targetUrl);
          if (detail != null && detail.video.hlsUrl.isNotEmpty) {
            hlsUrl = detail.video.hlsUrl;
            _setResolvedUrl(item.id, hlsUrl);
            _setResolvedUrl(targetUrl, hlsUrl);
          }
        }
      }

      if (hlsUrl.isEmpty) {
        AppLogger.w('Preload', '视频 [${item.title}] 嗅探未得到 m3u8，跳过预加载');
        return;
      }

      await _doPreload(item.copyWith(hlsUrl: hlsUrl), targetDir, localM3u8);
      _preloadedIds.add(key);
      await _trimCache();
      AppLogger.i('Preload', '✓ 视频 [${item.title}] 预加载完成 (混合 M3U8 生成成功)');
    } catch (e) {
      AppLogger.w('Preload', '视频 [${item.title}] 预加载跳过/异常: $e');
    } finally {
      _inFlightIds.remove(key);
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    while (!_playbackActive && _queue.isNotEmpty && isPreloadEnabled) {
      final item = _queue.removeFirst();
      await preload(item);
      // 任务间稍作低延时，避免抢占正常 UI 网络
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _isProcessing = false;
  }

  bool _isHanime1Item(VideoItem item) =>
      (item.detailUrl ?? '').contains('hanime1.me/watch');

  Future<void> _doPreload(
    VideoItem item,
    Directory targetDir,
    File localM3u8,
  ) async {
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    Uri currentUri = Uri.parse(item.hlsUrl);
    final response = await _dio.get<String>(
      item.hlsUrl,
      options: Options(responseType: ResponseType.plain),
    );
    String content = response.data ?? '';

    // 若为 master playlist，提取最佳清晰度（通常 720p/Auto）变体
    //
    // 解析走**后台 isolate**：`HlsParser.parse` 是纯 CPU 的字符串 + 正则工作，
    // 放在主 isolate 上就是 UI 卡顿的直接来源（真机 ANR 主线程栈即
    // `HlsParser.parse → _StringBase.split → _RegExp._ExecuteMatch`）。
    var playlist = await HlsParser.parseInBackground(content, currentUri);
    if (playlist.isMaster) {
      final best = HlsParser.pickBestVariant(playlist.variants);
      if (best == null) return;
      currentUri = best.uri;
      final mediaRes = await _dio.get<String>(
        currentUri.toString(),
        options: Options(responseType: ResponseType.plain),
      );
      content = mediaRes.data ?? '';
      playlist = await HlsParser.parseInBackground(content, currentUri);
    }

    if (playlist.segments.isEmpty) return;

    // 持久化保存真实远端 HLS URL 与 M3U8 清单，供 HlsCacheProxy 瞬间 0ms 直读
    try {
      await File(p.join(targetDir.path, 'source_url.txt'))
          .writeAsString(item.hlsUrl);
      await File(p.join(targetDir.path, 'media_url.txt'))
          .writeAsString(currentUri.toString());
      await File(p.join(targetDir.path, 'source.m3u8')).writeAsString(content);
    } catch (e) {
      // 关键 IO：这三个文件是 HlsCacheProxy「0ms 直读」与预加载缓存命中判定的依据，
      // 写失败会让预加载白做（下次仍走远端）。可恢复，故记 W。控制流不变：不 rethrow。
      AppLogger.w(
        'Preload',
        '预加载缓存清单写入失败 id=${item.id} dir=${targetDir.path}: $e',
      );
    }

    // 获取用户自定义设置的预加载分片数（限制在 1 到该视频总切片数之间）
    final wantedSegs = math.max(1, preloadSegmentCount.value);
    final preloadCountSegs = math.min(playlist.segments.length, wantedSegs);
    final segmentsToFetch = playlist.segments.take(preloadCountSegs).toList();

    // 如果包含 initSegment (fMP4)，优先下载 init.mp4
    File? localInitFile;
    if (playlist.initSegment != null) {
      localInitFile = File(p.join(targetDir.path, 'init.mp4'));
      if (!await localInitFile.exists() || await localInitFile.length() < 512) {
        try {
          await _dio.download(
            playlist.initSegment.toString(),
            localInitFile.path,
          );
        } catch (e) {
          // 关键 IO：init 段缺失会让 fMP4 整段无法解码，且预加载不会自动重试 → 记 E。
          AppLogger.e(
            'Preload',
            'init 段下载失败 id=${item.id} url=${playlist.initSegment}: $e',
          );
        }
      }
    }

    // 并发下载前几个分片文件
    final Map<int, String> downloadedSegments = {};
    final futures = <Future<void>>[];
    for (int i = 0; i < segmentsToFetch.length; i++) {
      final segUri = segmentsToFetch[i];
      final ext = playlist.outputExtension;
      final segFile = File(p.join(targetDir.path, 'seg_$i$ext'));
      futures.add(() async {
        if (!await segFile.exists() || await segFile.length() < 1024) {
          try {
            await _dio.download(segUri.toString(), segFile.path);
            if (await segFile.length() >= 1024) {
              downloadedSegments[i] = segFile.path;
            } else {
              if (await segFile.exists()) await segFile.delete();
            }
          } catch (_) {
            if (await segFile.exists()) await segFile.delete();
          }
        } else {
          downloadedSegments[i] = segFile.path;
        }
      }());
    }
    await Future.wait(futures);

    // 构建混合式 m3u8：前几个分片指向本地磁盘文件，后续分片保持远端完整 HTTP 地址
    final lines = content.split(_newlineRe);
    final outputLines = <String>[];
    int segIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('#EXT-X-MAP')) {
        // 重写 fMP4 初始化分片路径为本地文件
        if (localInitFile != null) {
          final uriString = localInitFile.uri.toString();
          outputLines.add('#EXT-X-MAP:URI="$uriString"');
        } else {
          outputLines.add(line);
        }
      } else if (!trimmed.startsWith('#')) {
        // 分片 URI 节点
        if (segIndex < segmentsToFetch.length &&
            downloadedSegments.containsKey(segIndex)) {
          // 已下载：使用本地文件的 URI 协议，播放器可 0ms 瞬间秒开
          final localUri = File(downloadedSegments[segIndex]!).uri.toString();
          outputLines.add(localUri);
        } else {
          // 未下载的后续分片：转换为绝对远端网络 URL，由播放器在后台播放时持续拉取
          final remoteUri = currentUri.resolve(trimmed).toString();
          outputLines.add(remoteUri);
        }
        segIndex++;
      } else {
        outputLines.add(line);
      }
    }

    await localM3u8.writeAsString(outputLines.join('\n'));
  }

  /// 递归统计目录占用（**在后台 isolate 里跑**）。
  ///
  /// 目录遍历 + 逐文件 `length()` 是纯 IO 元数据操作，但执行它的线程会被全程
  /// 占用。缓存接近上限时目录里有上万个分片文件，一次全量统计放在主 isolate
  /// 上就是几百毫秒的卡顿 —— 真机实测 20 秒内被触发 40 次。
  ///
  /// 参数与返回值都只用 `String` / `int`，天然可跨 isolate。
  static Future<int> _dirSizeInBackground(String path) =>
      Isolate.run(() => _dirSizeSync(path));

  static int _dirSizeSync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    var total = 0;
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += e.lengthSync();
          } catch (_) {
            // 单个文件读长度失败 → 跳过它，统计值偏小（不会偏大）。
            // 偏小只会让 LRU 少清理，不会误删，静默是正确设计。
          }
        }
      }
    } catch (_) {
      // 目录枚举整体失败 → 返回 0，缓存大小显示为 0。
      // 这会让 LRU 暂时不触发（不误删），下次统计恢复正常，静默可接受。
    }
    return total;
  }

  /// Size of the legacy Dart preload directory. Android playback bytes live in
  /// Media3's separate shared cache and are added only to the displayed total.
  Future<int> _getLocalCacheSize() async {
    final dir = _cacheDir;
    if (dir == null) return 0;
    return _dirSizeInBackground(dir.path);
  }

  Future<void> _refreshDisplayedCacheSize({int? localBytes}) async {
    if (_cacheStatsRefreshInFlight) {
      _cacheStatsRefreshPending = true;
      return;
    }
    _cacheStatsRefreshInFlight = true;
    try {
      final local = localBytes ?? await _getLocalCacheSize();
      final native = await Media3CacheService.getCacheSizeBytes() ?? 0;
      currentCacheSizeBytes.value = local + native;
    } catch (error) {
      AppLogger.w('Preload', '刷新缓存占用失败: $error');
      currentCacheSizeBytes.value = localBytes ?? 0;
    } finally {
      _cacheStatsRefreshInFlight = false;
      if (_cacheStatsRefreshPending) {
        _cacheStatsRefreshPending = false;
        unawaited(_refreshDisplayedCacheSize());
      }
    }
  }

  Future<int> _getDirSize(Directory dir) => _dirSizeInBackground(dir.path);

  /// 上次执行 LRU 修剪的时间戳（用于节流）。
  DateTime? _lastTrimAt;

  /// 两次 LRU 修剪之间的最小间隔。
  ///
  /// [_trimCache] 每完成一个视频的预加载都会被调用一次，而它内部要递归遍历整个
  /// 缓存目录。缓存接近上限时（真机实测 97.4MB / 100MB）**每一次**都要全量遍历
  /// + 逐个目录算大小 + 删除，20 秒内触发了 40 次。缓存本来就允许短暂超限，
  /// 没必要每预加载一个视频就校验一遍。
  static const Duration _trimInterval = Duration(seconds: 20);

  /// LRU 缓存自动修剪：超出最大 MB 上限时按最后修改时间淘汰最久未访问目录
  Future<void> _trimCache({bool force = false}) async {
    final cacheDir = _cacheDir;
    if (cacheDir == null || !await cacheDir.exists()) {
      await _refreshDisplayedCacheSize(localBytes: 0);
      return;
    }

    final now = DateTime.now();
    final last = _lastTrimAt;
    if (!force && last != null && now.difference(last) < _trimInterval) return;
    _lastTrimAt = now;

    final maxBytes = maxCacheSizeMB.value * 1024 * 1024;
    var localCacheBytes = await _getLocalCacheSize();
    if (localCacheBytes <= maxBytes) {
      await _refreshDisplayedCacheSize(localBytes: localCacheBytes);
      return;
    }

    try {
      final subDirs = <Directory>[];
      await for (final entity in cacheDir.list(followLinks: false)) {
        if (entity is Directory) {
          subDirs.add(entity);
        }
      }

      // 按最后修改时间由旧到新排序（LRU）
      subDirs.sort((a, b) {
        final aTime = a.statSync().modified;
        final bTime = b.statSync().modified;
        return aTime.compareTo(bTime);
      });

      for (final dir in subDirs) {
        if (localCacheBytes <= maxBytes) break;
        final size = await _getDirSize(dir);
        try {
          await dir.delete(recursive: true);
          localCacheBytes = math.max(0, localCacheBytes - size).toInt();
          final key = p.basename(dir.path);
          _preloadedIds.remove(key);
          AppLogger.i('Preload', 'LRU 清理过期缓存目录: ${dir.path}');
        } catch (_) {
          // 单个目录删除失败（文件被占用/权限）→ 跳过它继续下一个。
          // 注意：内层吞掉后**外层 774 行的 W 收不到**，即「删不掉」这件事不可见；
          // 但因为循环会继续尝试后续目录，最终仍可能压到上限之下，故保持静默可接受。
        }
      }
    } catch (e) {
      AppLogger.w('Preload', 'LRU 缓存修剪异常: $e');
    } finally {
      await _refreshDisplayedCacheSize(localBytes: localCacheBytes);
    }
  }

  /// 一键清空所有预加载缓存
  Future<void> clearCache() async {
    _cacheStatsRefreshTimer?.cancel();
    _cacheStatsRefreshTimer = null;
    await Media3CacheService.cancelAllPreloads();
    await Media3CacheService.clear();
    if (_cacheDir != null && await _cacheDir!.exists()) {
      try {
        await _cacheDir!.delete(recursive: true);
        await _cacheDir!.create(recursive: true);
      } catch (e) {
        AppLogger.w('Preload', '清空预加载缓存失败: $e');
      }
    }
    _preloadedIds.clear();
    _nativeHeadQueue.clear();
    _nativeHeadScheduled.clear();
    _nativeHeadActive.clear();
    _nativeFullRequestedId = null;
    _nativeFullScheduledId = null;
    _nativeFullActive = false;
    _nativeFullRequestGeneration++;
    await _refreshDisplayedCacheSize(localBytes: 0);
    AppLogger.i('Preload', '预加载缓存已彻底清空');
  }
}

class _NativePreloadRequest {
  const _NativePreloadRequest(this.item, this.url, {this.retryCount = 0});

  final VideoItem item;
  final String url;
  final int retryCount;

  _NativePreloadRequest retry() =>
      _NativePreloadRequest(item, url, retryCount: retryCount + 1);
}
