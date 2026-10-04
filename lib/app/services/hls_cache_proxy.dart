/// 本地 HLS 极速缓存代理与全速并行预载引擎。
///
/// 核心能力：
/// 1. 本地回环代理 (127.0.0.1:port)：重写 M3U8 流媒体列表，将远端分片拦截映射至本地高速缓存；
/// 2. 4 并发全速后台切片加速管线 (Full-Speed Segment Pipeline)：
///    打开视频时立即触发全片极速并发下载，数秒至数十秒内迅速拉满整个视频切片缓存；
/// 3. 即时出画 + 0ms 瞬间 Seek：
///    已缓存分片以本地文件直出 (0 延迟)，未下载分片优先插队，实现"开屏即播，全片秒级加载完毕"；
/// 4. 实时向播放器同步进度与缓冲时长。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_logger.dart';
import '../data/models/video_item.dart';
import 'hls_parser.dart';
import 'video_cache_key.dart';

class HlsCacheProxy {
  HlsCacheProxy._();
  static final HlsCacheProxy instance = HlsCacheProxy._();

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (status) => status != null && status < 400,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ),
  );

  Directory? _cacheDir;

  // ------------------------------------------------------------- 开关与状态反馈
  static const String _prefFullSpeedEnabled =
      'prefs_full_speed_acceleration_enabled';

  /// 全片极速加载总开关（默认开启）
  final RxBool isFullSpeedEnabled = true.obs;

  /// 当前加速的视频 ID
  String? currentActiveVideoId;

  /// 加速进度 (0.0 ~ 1.0)
  final RxDouble accelerationProgress = 0.0.obs;

  /// 已加速切片数
  final RxInt cachedSegments = 0.obs;

  /// 总切片数
  final RxInt totalSegments = 0.obs;

  /// 是否正在全速加速中
  final RxBool isAccelerating = false.obs;

  /// 当前全速加速预估下载速率
  final RxString speedStr = ''.obs;

  /// 加速进度回调（传递给 PlayerController 同步播放器缓冲条）
  void Function(String videoId, double progress, Duration bufferedDuration)?
  onProgressUpdate;

  // 内部下载任务控制
  CancelToken? _cancelToken;
  final Set<int> _activeDownloadingIndices = <int>{};
  final Map<int, CancelToken> _workerTokens = {};
  final Set<int> _foregroundSegments = {};
  int _prioritySegment = 0;
  final Set<int> _completedIndices = <int>{};
  HlsPlaylist? _currentPlaylist;
  double _currentDurationSeconds = 0.0;
  Uri? _activeBaseUri;

  /// A cached playlist contains CDN segment URLs, which may be signed. Reuse it
  /// only briefly and only for the exact source URL that produced it.
  static const Duration _playlistCacheMaxAge = Duration(seconds: 30);

  /// 初始化本地代理服务器
  Future<void> init() async {
    if (_server != null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      isFullSpeedEnabled.value = prefs.getBool(_prefFullSpeedEnabled) ?? true;
    } catch (e) {
      // 读失败 → 回退默认值 true（全速开启）。用户侧表现为「设置被重置」，
      // 静默会让它看起来像设置没保存成功。控制流不变：仍用默认值继续 init。
      AppLogger.w('HlsProxy', '读取极速模式设置失败，本次使用默认值 true: $e');
    }

    final temp = await getApplicationCacheDirectory();
    _cacheDir = Directory(p.join(temp.path, 'video_browser', 'hls_preload'));
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(
        _handleRequest,
        onError: (e) {
          AppLogger.w('HlsProxy', '本地代理请求错误: $e');
        },
      );
      AppLogger.i(
        'HlsProxy',
        '⚡ [极速加载服务就绪] 本地代理服务运行在: http://127.0.0.1:$port (极速模式: ${isFullSpeedEnabled.value})',
      );
    } catch (e) {
      AppLogger.e('HlsProxy', '启动本地代理失败: $e');
    }
  }

  /// 切换极速全速加载开关并持久化
  Future<void> setFullSpeedEnabled(bool enabled) async {
    isFullSpeedEnabled.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefFullSpeedEnabled, enabled);
    } catch (e) {
      // 写失败 → 内存里的开关已生效，但重启后恢复旧值。用户侧表现为
      // 「设置改了但下次打开又变回去」，静默时完全无法归因。
      AppLogger.w('HlsProxy', '极速模式设置持久化失败（本次运行内仍生效）: $e');
    }
    if (!enabled) {
      stopCurrentAcceleration();
    }
    AppLogger.i('HlsProxy', '⚡ 极速全片加载总开关更新为: $enabled');
  }

  Future<void> toggleFullSpeedEnabled() async {
    await setFullSpeedEnabled(!isFullSpeedEnabled.value);
  }

  /// 转换网络 HLS 播放流为本地极速代理地址
  String getProxiedPlayUrl(
    String originalUrl, {
    required VideoItem item,
    String? referer,
  }) {
    if (!isFullSpeedEnabled.value || port == 0) {
      return originalUrl;
    }
    // MP4 直链不是 HLS 清单，走本代理必然在 HlsParser.parse 抛
    // 「不是合法的 m3u8：缺少 #EXTM3U 头」，进而返回 500、播放失败。
    // 站点存在这类直链（如 `/videos/view/` 模板的详情页），故原样放行交给播放器。
    final lower = originalUrl.toLowerCase();
    if (lower.contains('.mp4') && !lower.contains('.m3u8')) {
      return originalUrl;
    }
    final safeId = _safeCacheKey(item.id);
    final encUrl = Uri.encodeComponent(originalUrl);
    final encRef = Uri.encodeComponent(referer ?? 'https://91porny.com/');
    return 'http://127.0.0.1:$port/playlist.m3u8?url=$encUrl&id=$safeId&ref=$encRef';
  }

  String _safeCacheKey(String id) {
    return videoCacheKey(id);
  }

  /// 停止当前视频的全速加速下载管线
  void stopCurrentAcceleration() {
    _cancelToken?.cancel('new video loaded');
    for (final token in _workerTokens.values) {
      token.cancel('new video loaded');
    }
    _workerTokens.clear();
    _foregroundSegments.clear();
    _prioritySegment = 0;
    _cancelToken = null;
    isAccelerating.value = false;
    currentActiveVideoId = null;
    _activeDownloadingIndices.clear();
    _completedIndices.clear();
    _activeBaseUri = null;
    accelerationProgress.value = 0.0;
    cachedSegments.value = 0;
    totalSegments.value = 0;
    speedStr.value = '';
  }

  /// 核心分发路由：处理 ExoPlayer 发往本地 127.0.0.1 的请求
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    // 跨域与基础响应头支持
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Headers', '*');
    request.response.headers.set('Accept-Ranges', 'bytes');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    try {
      if (path == '/playlist.m3u8') {
        await _servePlaylist(request);
      } else if (path == '/segment') {
        await _serveSegment(request);
      } else if (path == '/init') {
        await _serveInitSegment(request);
      } else if (path == '/key') {
        await _serveKey(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('Internal Proxy Error: $e');
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 处理 M3U8 请求：拉取/解析远端 M3U8，重写分片为本地代理路由，并启动 4 个后台下载 worker。
  Future<void> _servePlaylist(HttpRequest request) async {
    final originalUrl = request.uri.queryParameters['url'];
    final id = request.uri.queryParameters['id'] ?? 'default';
    final ref = request.uri.queryParameters['ref'] ?? 'https://91porny.com/';

    if (originalUrl == null || originalUrl.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': ref,
    };

    final targetDir = Directory(p.join(_cacheDir!.path, id));
    final encodedReferer = Uri.encodeComponent(ref);
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final (playlist, content, currentUri) = await _loadPlaylist(
      url: originalUrl,
      initialUri: Uri.parse(originalUrl),
      headers: headers,
      sourceM3u8File: File(p.join(targetDir.path, 'source.m3u8')),
      mediaUrlFile: File(p.join(targetDir.path, 'media_url.txt')),
      sourceUrlFile: File(p.join(targetDir.path, 'source_url.txt')),
    );

    _currentPlaylist = playlist;
    _currentDurationSeconds = playlist.durationSeconds;

    // 重写 M3U8 列表分片行
    final lines = content.split(RegExp(r'\r?\n'));
    final outputLines = <String>[];
    int segIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('#EXT-X-MAP')) {
        // 重写 fMP4 初始化切片
        if (playlist.initSegment != null) {
          final initUrl = Uri.encodeComponent(playlist.initSegment.toString());
          outputLines.add(
            '#EXT-X-MAP:URI="http://127.0.0.1:$port/init?id=$id&url=$initUrl&ref=$encodedReferer"',
          );
        } else {
          outputLines.add(line);
        }
      } else if (trimmed.startsWith('#EXT-X-KEY')) {
        if (playlist.encryptionKeyUri != null) {
          final keyUrl = Uri.encodeComponent(
            playlist.encryptionKeyUri.toString(),
          );
          outputLines.add(
            '#EXT-X-KEY:METHOD=${playlist.encryptionMethod},URI="http://127.0.0.1:$port/key?id=$id&url=$keyUrl&ref=$encodedReferer"',
          );
        } else {
          outputLines.add(line);
        }
      } else if (!trimmed.startsWith('#')) {
        // 分片行
        final resolvedSegUri = currentUri.resolve(trimmed);
        final encSegUrl = Uri.encodeComponent(resolvedSegUri.toString());
        outputLines.add(
          'http://127.0.0.1:$port/segment?id=$id&idx=$segIndex&url=$encSegUrl&ref=$encodedReferer',
        );
        segIndex++;
      } else {
        outputLines.add(line);
      }
    }

    final rewrittenM3u8 = outputLines.join('\n');
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
    );
    request.response.write(rewrittenM3u8);
    await request.response.close();

    // 🚀 核心：若极速加载开启，播放器一拿走 M3U8，立刻全速火力全开加速整片视频！
    if (isFullSpeedEnabled.value) {
      _startFullSpeedPipeline(id, playlist, currentUri, targetDir, ref);
    }
  }

  /// 外部手动触发某视频的极速下载管线（例如用户中途打开极速开关）
  Future<void> triggerAccelerationForVideo(
    VideoItem item,
    String remoteHlsUrl, {
    String? referer,
  }) async {
    if (!isFullSpeedEnabled.value) return;
    try {
      final safeId = _safeCacheKey(item.id);
      final targetDir = Directory(p.join(_cacheDir!.path, safeId));
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      final ref = referer ?? 'https://91porny.com/';
      final (playlist, _, currentUri) = await _loadPlaylist(
        url: remoteHlsUrl,
        initialUri: Uri.parse(remoteHlsUrl),
        headers: {'Referer': ref},
        sourceM3u8File: File(p.join(targetDir.path, 'source.m3u8')),
        mediaUrlFile: File(p.join(targetDir.path, 'media_url.txt')),
        sourceUrlFile: File(p.join(targetDir.path, 'source_url.txt')),
      );

      _currentPlaylist = playlist;
      _currentDurationSeconds = playlist.durationSeconds;
      _startFullSpeedPipeline(safeId, playlist, currentUri, targetDir, ref);
    } catch (e) {
      AppLogger.w('HlsProxy', '手动触发极速管线异常: $e');
    }
  }

  /// 拉取并解析播放列表：优先复用本地缓存，否则请求远端并处理 master 变体。
  ///
  /// 返回 (最终 playlist, 原始内容, 解析基准 Uri)。
  /// [headers] 由调用方给定 —— 两条调用路径的请求头并不相同（代理路由带 UA，
  /// 手动加速仅带 Referer），不可在此统一。
  Future<(HlsPlaylist, String, Uri)> _loadPlaylist({
    required String url,
    required Uri initialUri,
    required Map<String, String> headers,
    required File sourceM3u8File,
    required File mediaUrlFile,
    required File sourceUrlFile,
  }) async {
    Uri currentUri = initialUri;
    String content;

    var canReuseCachedPlaylist = false;
    if (sourceM3u8File.existsSync() &&
        mediaUrlFile.existsSync() &&
        sourceUrlFile.existsSync()) {
      try {
        final cachedSourceUrl = (await sourceUrlFile.readAsString()).trim();
        final cachedAt = await sourceM3u8File.lastModified();
        canReuseCachedPlaylist =
            cachedSourceUrl == url &&
            DateTime.now().difference(cachedAt) < _playlistCacheMaxAge;
      } catch (_) {
        // A partial or unreadable cache is a miss; fetch a fresh manifest.
      }
    }

    if (canReuseCachedPlaylist) {
      content = await sourceM3u8File.readAsString();
      final savedUrl = (await mediaUrlFile.readAsString()).trim();
      if (savedUrl.isNotEmpty) {
        currentUri = Uri.parse(savedUrl);
      }
    } else {
      final res = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain, headers: headers),
      );
      content = res.data ?? '';
    }

    // 每次请求只解析最终播放清单一次。旧逻辑首次加载先解析 master，
    // 拉取变体后又从头解析媒体清单；缓存写入也串在响应前，增加了起播等待。
    var playlist = await HlsParser.parseInBackground(content, currentUri);
    if (playlist.isMaster) {
      final best = HlsParser.pickBestVariant(playlist.variants);
      if (best != null) {
        currentUri = best.uri;
        final subRes = await _dio.get<String>(
          currentUri.toString(),
          options: Options(responseType: ResponseType.plain, headers: headers),
        );
        content = subRes.data ?? '';
        playlist = await HlsParser.parseInBackground(content, currentUri);
      }
    }

    if (!canReuseCachedPlaylist) {
      unawaited(
        _persistPlaylistCache(
          url: url,
          content: content,
          mediaUri: currentUri,
          sourceM3u8File: sourceM3u8File,
          mediaUrlFile: mediaUrlFile,
          sourceUrlFile: sourceUrlFile,
        ),
      );
    }

    return (playlist, content, currentUri);
  }

  Future<void> _persistPlaylistCache({
    required String url,
    required String content,
    required Uri mediaUri,
    required File sourceM3u8File,
    required File mediaUrlFile,
    required File sourceUrlFile,
  }) async {
    try {
      await mediaUrlFile.writeAsString(mediaUri.toString());
      await sourceUrlFile.writeAsString(url);
      // Write the playlist last so its timestamp marks a complete cache entry.
      await sourceM3u8File.writeAsString(content);
    } catch (error) {
      // Persistence is only an optimization; playback has already received
      // the parsed playlist and will safely fetch it again on a cache miss.
      AppLogger.w('HlsProxy', '播放列表缓存写入失败 url=$url: $error');
    }
  }

  /// 启动 4 个全速并发 worker，在保证前台播放可用带宽的同时预载视频。
  void _startFullSpeedPipeline(
    String videoId,
    HlsPlaylist playlist,
    Uri baseUri,
    Directory targetDir,
    String referer,
  ) {
    if (currentActiveVideoId == videoId &&
        _activeBaseUri == baseUri &&
        _cancelToken != null &&
        !_cancelToken!.isCancelled) {
      AppLogger.d('HlsProxy', '相同视频的全速缓存任务已在运行，跳过重复启动: $videoId');
      return;
    }
    stopCurrentAcceleration();

    currentActiveVideoId = videoId;
    _activeBaseUri = baseUri;
    _cancelToken = CancelToken();
    isAccelerating.value = true;
    totalSegments.value = playlist.segments.length;
    _completedIndices.clear();

    AppLogger.i(
      'HlsProxy',
      '⚡ [全力加速开启] 视频 $videoId 共 ${playlist.segments.length} 个分片，正在扫描已有缓存...',
    );
    unawaited(
      _bootstrapFullSpeed(videoId, playlist, targetDir, referer, _cancelToken!),
    );
  }

  /// 全速管线的启动后半段：扫描已有分片 → 下 init.mp4 → 起 4 个 worker。
  ///
  /// 拆出来是因为扫描必须放到**后台 isolate**：原本的 `existsSync()` +
  /// `lengthSync()` 同步循环，对一部 2000 分片的片子就是 4000 次同步系统调用，
  /// 而它恰好发生在**播放起播的那一刻** —— 主 isolate 被占住，用户看到的就是
  /// 「点了播放要等半天才出画」。
  Future<void> _bootstrapFullSpeed(
    String videoId,
    HlsPlaylist playlist,
    Directory targetDir,
    String referer,
    CancelToken token,
  ) async {
    final done = await _scanCompletedSegmentsInBackground(
      targetDir.path,
      playlist.segments.length,
      playlist.outputExtension,
    );
    // 扫描期间可能已经换片或停止 —— 别把过期结果写进状态。
    if (token.isCancelled || currentActiveVideoId != videoId) return;

    _completedIndices.addAll(done);
    cachedSegments.value = _completedIndices.length;
    _notifyProgress(videoId);

    AppLogger.i(
      'HlsProxy',
      '⚡ [全力加速] 视频 $videoId 共 ${playlist.segments.length} 个分片，已有 ${_completedIndices.length} 片，4 并发全速拉取中...',
    );

    // 若有 init.mp4，优先下载
    if (playlist.initSegment != null) {
      unawaited(() async {
        final initFile = File(p.join(targetDir.path, 'init.mp4'));
        if (!await initFile.exists() || await initFile.length() < 1024) {
          try {
            await _dio.download(
              playlist.initSegment.toString(),
              initFile.path,
              cancelToken: token,
              options: Options(headers: {'Referer': referer}),
            );
          } catch (e) {
            // 关键 IO：init 段（fMP4 的 moov）缺失时整段无法解码，
            // 用户侧表现为「卡住/黑屏」而无任何报错。此前完全静默，无法定位。
            // 该次拉取是 one-shot，失败后本片不会自动重试 → 记 E。
            AppLogger.e(
              'HlsProxy',
              'init 段下载失败 videoId=$videoId url=${playlist.initSegment}: $e',
            );
          }
        }
      }());
    }

    // 4 个并发 Worker 协程循环消费。
    // 刻意不用更高并发：留出带宽给解码器请求与页面导航，移动网络下
    // 提高并发反而会因带宽竞争拖慢起播。历史注释写「6」与实现不符，已更正。
    const int workerCount = 4;
    for (int w = 0; w < workerCount; w++) {
      unawaited(_workerLoop(videoId, playlist, targetDir, referer, token));
    }
  }

  /// 扫描本地已存在的有效分片索引（**在后台 isolate 里跑**）。
  ///
  /// 参数与返回值只用 `String` / `int` / `List<int>`，天然可跨 isolate。
  static Future<List<int>> _scanCompletedSegmentsInBackground(
    String dirPath,
    int count,
    String ext,
  ) => Isolate.run(() => _scanCompletedSegmentsSync(dirPath, count, ext));

  static List<int> _scanCompletedSegmentsSync(
    String dirPath,
    int count,
    String ext,
  ) {
    final done = <int>[];
    for (var i = 0; i < count; i++) {
      try {
        final f = File(p.join(dirPath, 'seg_$i$ext'));
        if (f.existsSync() && f.lengthSync() > 1024) done.add(i);
      } catch (_) {
        // 探测失败按「该分片未完成」处理 → 后续会被重新下载。
        // 这是安全方向（宁可多下一次，也不会把坏分片当好的），静默是正确设计。
      }
    }
    return done;
  }

  Future<void> _workerLoop(
    String videoId,
    HlsPlaylist playlist,
    Directory targetDir,
    String referer,
    CancelToken token,
  ) async {
    final ext = playlist.outputExtension;

    while (!token.isCancelled && currentActiveVideoId == videoId) {
      int? nextIdx;

      // 寻找下一个未完成且未在下载中的切片索引
      for (int step = 0; step < playlist.segments.length; step++) {
        final i = (_prioritySegment + step) % playlist.segments.length;
        if (!_completedIndices.contains(i) &&
            !_activeDownloadingIndices.contains(i) &&
            !_foregroundSegments.contains(i)) {
          nextIdx = i;
          _activeDownloadingIndices.add(i);
          break;
        }
      }

      if (nextIdx == null) {
        // 所有切片均已完成或已被接管下载
        if (_completedIndices.length >= playlist.segments.length) {
          isAccelerating.value = false;
          speedStr.value = '全片极速缓存已完成';
          AppLogger.i(
            'HlsProxy',
            '🎉 [全片极速缓存已 100% 完成] 视频 $videoId 全部 ${playlist.segments.length} 切片已安全驻留本地磁盘！',
          );
        }
        break;
      }

      final segIndex = nextIdx;
      final segUri = playlist.segments[segIndex];
      final finalFile = File(p.join(targetDir.path, 'seg_$segIndex$ext'));
      final downloadToken = CancelToken();
      // A cancelled worker can still be unwinding while a replacement worker
      // starts for the same segment. Give each attempt its own temp file.
      final tempFile = File(
        p.join(
          targetDir.path,
          'seg_${segIndex}_${identityHashCode(downloadToken)}_worker.tmp',
        ),
      );
      _workerTokens[segIndex] = downloadToken;

      try {
        if (!await finalFile.exists() || await finalFile.length() < 1024) {
          await _dio.download(
            segUri.toString(),
            tempFile.path,
            cancelToken: downloadToken,
            options: Options(headers: {'Referer': referer}),
          );
          if (await tempFile.exists()) {
            if (await tempFile.length() > 1024) {
              if (!finalFile.existsSync() || finalFile.lengthSync() <= 1024) {
                try {
                  await tempFile.rename(finalFile.path);
                } catch (_) {
                  try {
                    await tempFile.delete();
                  } catch (_) {}
                }
              } else {
                try {
                  await tempFile.delete();
                } catch (_) {}
              }
            } else {
              try {
                await tempFile.delete();
              } catch (_) {}
              continue;
            }
          }
        }
        if (!await finalFile.exists() || await finalFile.length() <= 1024) {
          throw StateError('segment $segIndex was not written completely');
        }
        if (token.isCancelled || currentActiveVideoId != videoId) break;
        _completedIndices.add(segIndex);
        cachedSegments.value = _completedIndices.length;
        _notifyProgress(videoId);
      } catch (e) {
        if (token.isCancelled) break;
        if (downloadToken.isCancelled) continue;
        // 若单分片网络波动失败，重试
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {
          // Partial download cleanup is best-effort; a later cache scan ignores
          // temporary files and retries this segment.
        }
        if (identical(_workerTokens[segIndex], downloadToken)) {
          _workerTokens.remove(segIndex);
          _activeDownloadingIndices.remove(segIndex);
        }
      }
    }
  }

  void _notifyProgress(String videoId) {
    final total = totalSegments.value;
    if (total <= 0) return;
    final count = _completedIndices.length;
    final frac = (count / total).clamp(0.0, 1.0);
    accelerationProgress.value = frac;

    final durMs = (_currentDurationSeconds * 1000).toInt();
    var contiguous = 0;
    while (_completedIndices.contains(contiguous)) {
      contiguous++;
    }
    final bufferedMs = (contiguous / total * durMs).toInt();
    final bufferedDuration = Duration(milliseconds: bufferedMs);

    onProgressUpdate?.call(videoId, frac, bufferedDuration);
  }

  /// 处理分片请求：本地命中 0 延迟秒出；未命中即刻优先边下边播
  Future<void> _serveSegment(HttpRequest request) async {
    final id = request.uri.queryParameters['id'] ?? 'default';
    final idxStr = request.uri.queryParameters['idx'] ?? '0';
    final rawUrl = request.uri.queryParameters['url'] ?? '';
    final idx = int.tryParse(idxStr);
    if (idx == null || idx < 0 || rawUrl.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final generation = _cancelToken;
    if (id == currentActiveVideoId) {
      _prioritySegment = idx;
      // A seek changes which bytes matter. Cancel obsolete background work,
      // including a duplicate download of the foreground segment itself.
      for (final entry in _workerTokens.entries) {
        if (entry.key == idx || entry.key < idx || entry.key > idx + 6) {
          entry.value.cancel('foreground playback moved');
        }
      }
    }

    final targetDir = Directory(p.join(_cacheDir!.path, id));
    final ext = _currentPlaylist?.outputExtension ?? '.ts';
    final segFile = File(p.join(targetDir.path, 'seg_$idx$ext'));

    // 1. 本地磁盘已命中（全速预载已就绪或 Feed 预载命中且大于 1024 字节）：0ms 极速直出
    if (await segFile.exists() && await segFile.length() > 1024) {
      await _sendFile(
        request,
        segFile,
        ext == '.mp4' ? 'video/mp4' : 'video/mp2t',
      );
      return;
    }

    // 2. 正在或尚未下载：将该切片优先级提至最高，立刻直连拉取并同时落盘
    final tempFile = File(
      p.join(targetDir.path, 'seg_${idx}_${request.hashCode}_stream.tmp'),
    );
    if (id == currentActiveVideoId) _foregroundSegments.add(idx);
    IOSink? sink;
    try {
      final res = await _dio.get<ResponseBody>(
        rawUrl,
        options: Options(
          responseType: ResponseType.stream,
          // 必须用请求里带过来的 ref，不能写死 91porny。
          // 用户切换到镜像域名（hsex.icu 等）后，写死的 Referer 会让 CDN
          // 认为来源非法，分片 403 —— 表现为「换域名后视频一直缓冲」。
          headers: {
            'Referer':
                request.uri.queryParameters['ref'] ?? 'https://91porny.com/',
          },
        ),
      );

      final stream = res.data?.stream;
      if (stream == null) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType.parse(
        ext == '.mp4' ? 'video/mp4' : 'video/mp2t',
      );

      sink = tempFile.openWrite();
      await for (final chunk in stream) {
        request.response.add(chunk);
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      await request.response.close();

      if (await tempFile.exists()) {
        if (await tempFile.length() > 1024) {
          if (!segFile.existsSync() || segFile.lengthSync() <= 1024) {
            try {
              await tempFile.rename(segFile.path);
            } catch (_) {
              try {
                await tempFile.delete();
              } catch (_) {}
            }
          } else {
            try {
              await tempFile.delete();
            } catch (_) {}
          }
          if (id == currentActiveVideoId &&
              identical(generation, _cancelToken)) {
            _completedIndices.add(idx);
            cachedSegments.value = _completedIndices.length;
            _notifyProgress(id);
          }
        } else {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      AppLogger.w('HlsProxy', '前台分片请求失败 id=$id idx=$idx: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // best-effort：客户端可能已断开（response 写不进去），
        // 此处失败无补救手段，静默是正确设计。原始异常已在上面记录。
      }
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
        // A cancelled client may leave a partial temp file; do not let cleanup
        // failure interfere with playback or proxy response completion.
      }
      if (id == currentActiveVideoId && identical(generation, _cancelToken)) {
        _foregroundSegments.remove(idx);
      }
    }
  }

  /// 处理 fMP4 初始化分片
  Future<void> _serveInitSegment(HttpRequest request) async {
    final id = request.uri.queryParameters['id'] ?? 'default';
    final rawUrl = request.uri.queryParameters['url'] ?? '';

    final targetDir = Directory(p.join(_cacheDir!.path, id));
    final initFile = File(p.join(targetDir.path, 'init.mp4'));

    if (await initFile.exists() && await initFile.length() > 0) {
      await _sendFile(request, initFile, 'video/mp4');
      return;
    }

    try {
      await _dio.download(
        rawUrl,
        initFile.path,
        options: Options(
          headers: {
            'Referer':
                request.uri.queryParameters['ref'] ?? 'https://91porny.com/',
          },
        ),
      );
      await _sendFile(request, initFile, 'video/mp4');
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    }
  }

  /// 处理解密密钥
  Future<void> _serveKey(HttpRequest request) async {
    final id = request.uri.queryParameters['id'] ?? 'default';
    final rawUrl = request.uri.queryParameters['url'] ?? '';

    final targetDir = Directory(p.join(_cacheDir!.path, id));
    final keyFile = File(p.join(targetDir.path, 'key.bin'));

    if (await keyFile.exists() && await keyFile.length() > 0) {
      await _sendFile(request, keyFile, 'application/octet-stream');
      return;
    }

    try {
      await _dio.download(
        rawUrl,
        keyFile.path,
        options: Options(
          headers: {
            'Referer':
                request.uri.queryParameters['ref'] ?? 'https://91porny.com/',
          },
        ),
      );
      await _sendFile(request, keyFile, 'application/octet-stream');
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    }
  }

  /// 发送本地文件，支持 HTTP 200 与 HTTP 206 (Range)
  Future<void> _sendFile(
    HttpRequest request,
    File file,
    String mimeType,
  ) async {
    final fileLength = await file.length();
    request.response.headers.contentType = ContentType.parse(mimeType);

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      final parsed = parseByteRange(range, fileLength);
      if (parsed == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$fileLength',
        );
        request.response.contentLength = 0;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${parsed.start}-${parsed.end}/$fileLength',
      );
      request.response.contentLength = parsed.end - parsed.start + 1;
      await request.response.addStream(
        file.openRead(parsed.start, parsed.end + 1),
      );
    } else {
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = fileLength;
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
  }

  /// Parses a single HTTP byte range. Invalid or unsatisfiable ranges return
  /// null so the caller can answer with 416 instead of throwing during read.
  static ({int start, int end})? parseByteRange(String value, int totalLength) {
    if (totalLength <= 0 || !value.startsWith('bytes=')) return null;
    final spec = value.substring(6).trim();
    if (spec.contains(',')) return null; // Multi-range is not used by player.
    final separator = spec.indexOf('-');
    if (separator < 0 || spec.indexOf('-', separator + 1) >= 0) return null;

    final startText = spec.substring(0, separator).trim();
    final endText = spec.substring(separator + 1).trim();
    if (startText.isEmpty) {
      final suffixLength = int.tryParse(endText);
      if (suffixLength == null || suffixLength <= 0) return null;
      final start = suffixLength >= totalLength
          ? 0
          : totalLength - suffixLength;
      return (start: start, end: totalLength - 1);
    }

    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= totalLength) return null;
    final requestedEnd = endText.isEmpty
        ? totalLength - 1
        : int.tryParse(endText);
    if (requestedEnd == null || requestedEnd < start) return null;
    final end = requestedEnd >= totalLength ? totalLength - 1 : requestedEnd;
    return (start: start, end: end);
  }
}
