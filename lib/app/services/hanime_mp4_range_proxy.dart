/// Range-aware cache for Hanime1's progressive MP4 streams.
///
/// The 91 player accelerates HLS by downloading independent playlist segments.
/// Hanime1 supplies direct MP4 files instead, so this proxy caches HTTP byte
/// ranges and fetches a bounded six-range window ahead of the player's current
/// request. Player seeks remain ordinary HTTP Range requests.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import 'video_cache_key.dart';

class HanimeMp4RangeProxy {
  HanimeMp4RangeProxy._();
  static final HanimeMp4RangeProxy instance = HanimeMp4RangeProxy._();

  // Larger MP4 ranges reduce request/seek churn and give list preloads a more
  // useful head buffer. Android Media3 uses the same value for its progressive
  // preload window, so 1 configured block now means 2 MiB instead of 512 KiB.
  static const int chunkSize = 2 * 1024 * 1024;
  static const int prefetchConcurrency = 6;
  static const int _maxConcurrentDownloads = 6;
  static const int _maxConcurrentPrefetches = 4;
  int _maxCacheBytesPerVideo = 250 * 1024 * 1024;
  int _maxCacheBytesTotal = 500 * 1024 * 1024;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (status) => status != null && status < 500,
      headers: const <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept-Encoding': 'identity',
      },
    ),
  );

  HttpServer? _server;
  Directory? _cacheRoot;
  Future<void>? _initTask;
  bool _prefetchEnabled = true;
  final Map<String, _Mp4State> _states = <String, _Mp4State>{};
  final Queue<_QueuedRangeDownload> _downloadQueue =
      Queue<_QueuedRangeDownload>();
  int _activeDownloads = 0;
  int _activePrefetches = 0;
  bool _closing = false;
  Future<void>? _pruneTask;
  DateTime? _lastPrune;
  String? _foregroundKey;

  int get port => _server?.port ?? 0;

  static bool isMp4Url(String url) {
    final uri = Uri.tryParse(url);
    return (uri?.path ?? url).toLowerCase().endsWith('.mp4');
  }

  Future<void> init({Directory? cacheDirectory}) {
    if (_server != null) return Future<void>.value();
    return _initTask ??= _initInternal(cacheDirectory)
        .whenComplete(() => _initTask = null);
  }

  Future<void> _initInternal(Directory? cacheDirectory) async {
    _closing = false;
    try {
      if (cacheDirectory != null) {
        _cacheRoot = cacheDirectory;
      } else {
        final temp = await getApplicationCacheDirectory();
        _cacheRoot = Directory(
          p.join(temp.path, 'video_browser', 'hanime_mp4_ranges'),
        );
      }
      // ⚠️ 这里**不能**删目录。
      //
      // 旧实现是：
      //     if (await _cacheRoot!.exists()) {
      //       await _cacheRoot!.delete(recursive: true);
      //     }
      // 每次冷启动把已缓存的全部分块清空 —— 于是「第二次打开同一个视频」
      // 仍然要重新拉一遍，秒播完全失效。真机复现：看完一集退出 App 再进，
      // 同一集的首帧延迟和第一次一模一样。
      //
      // 正确做法是保留缓存、只清「过期/超量」的部分，交给下面的
      // [_pruneCache]（LRU，按访问计数淘汰）在启动后异步处理。
      await _cacheRoot!.create(recursive: true);
      _scheduleStartupPrune();
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error) {
          AppLogger.w('HanimeMp4Range', '本地 Range 代理错误: $error');
        },
      );
      AppLogger.i('HanimeMp4Range', 'MP4 Range 代理已启动，端口=$port');
    } catch (error, stack) {
      AppLogger.e('HanimeMp4Range', '初始化 Range 代理失败: $error', error, stack);
    }
  }

  Future<void> close() async {
    _closing = true;
    final pending = _states.values.expand((s) => s.inFlight.values).toList();
    for (final state in _states.values) {
      for (final transfer in state.transfers.values) {
        transfer.cancelToken.cancel('proxy closed');
      }
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
    for (final queued in _downloadQueue.toList()) {
      _downloadQueue.remove(queued);
      if (!queued.completer.isCompleted) queued.completer.complete(false);
    }
    await Future.wait(pending.map((task) => task.catchError((_) => false)));
    await _pruneTask;
    _cacheRoot = null;
    _states.clear();
    _lastPrune = null;
    _foregroundKey = null;
  }

  void setPrefetchEnabled(bool enabled) {
    _prefetchEnabled = enabled;
    if (!enabled) {
      _foregroundKey = null;
      for (final state in _states.values) {
        state.wholeCacheGeneration++;
        for (final transfer in state.transfers.values) {
          if (!transfer.foreground) {
            transfer.cancelToken.cancel('prefetch disabled');
          }
        }
      }
      for (final queued in _downloadQueue.toList()) {
        if (!queued.prefetch) continue;
        _downloadQueue.remove(queued);
        if (!queued.completer.isCompleted) queued.completer.complete(false);
      }
      _pumpDownloadQueue();
    }
  }

  /// Tie MP4 caching to the capacity selected in the app settings.
  /// One active video may use the full configured budget. The global LRU then
  /// evicts older MP4 ranges as needed, so a video that fits can be cached in
  /// full instead of stopping at an arbitrary half-budget threshold.
  void setCacheLimitMB(int megabytes) {
    final clamped = megabytes.clamp(50, 4096);
    _maxCacheBytesTotal = clamped * 1024 * 1024;
    _maxCacheBytesPerVideo = _maxCacheBytesTotal;
    if (_cacheRoot != null) unawaited(_pruneCacheOnDisk());
  }

  String getProxiedUrl({
    required String url,
    required String videoId,
    required String referer,
  }) {
    if (port == 0 || !isMp4Url(url)) return url;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/hanime.mp4',
      queryParameters: <String, String>{
        'id': videoId,
        'url': url,
        'ref': referer,
      },
    ).toString();
  }

  /// Warm the first byte range immediately, then keep a short playback window
  /// ahead and fill the rest of the file in the background when it fits the
  /// configured per-video cache budget.
  Future<void> prefetchInitial({
    required String videoId,
    required String url,
    required String referer,
    bool firstChunkOnly = false,
  }) async {
    if (!_prefetchEnabled || !isMp4Url(url)) return;
    await init();
    if (port == 0) return;
    try {
      final state = await _stateFor(videoId, url, referer);
      _prioritizeWindow(state, 0);
      final ready = await _ensureChunk(state, 0, prefetch: firstChunkOnly);
      if (!ready) return;
      if (!firstChunkOnly) {
        _scheduleAhead(state, 1);
        unawaited(_cacheRemainingChunks(state, 1));
      }
    } catch (error) {
      AppLogger.w('HanimeMp4Range', '首段预热失败: $error');
    }
  }

  static ByteRangeRequest? parseByteRange(String? value, {int? totalLength}) {
    if (value == null) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final first = match.group(1)!;
    final last = match.group(2)!;
    if (first.isEmpty && last.isEmpty) return null;

    if (first.isEmpty) {
      final suffixLength = int.tryParse(last);
      if (suffixLength == null || suffixLength <= 0 || totalLength == null) {
        return null;
      }
      return ByteRangeRequest(
        start: math.max(0, totalLength - suffixLength),
        end: totalLength - 1,
      );
    }

    final start = int.tryParse(first);
    final end = last.isEmpty ? null : int.tryParse(last);
    if (start == null || start < 0 || (last.isNotEmpty && end == null)) {
      return null;
    }
    if (end != null && end < start) return null;
    if (totalLength != null && start >= totalLength) return null;
    return ByteRangeRequest(start: start, end: end);
  }

  Future<_Mp4State> _stateFor(
    String videoId,
    String url,
    String referer,
  ) async {
    if (_cacheRoot == null) await init();
    final key = videoCacheKey('$videoId\n$url');
    final cached = _states[key];
    if (cached != null) return cached;
    final directory = Directory(p.join(_cacheRoot!.path, key));
    await directory.create(recursive: true);
    final state = _states.putIfAbsent(
      key,
      () =>
          _Mp4State(key: key, url: url, referer: referer, directory: directory),
    );
    state.lastAccessAt = DateTime.now();
    return state;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path != '/hanime.mp4') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final url = request.uri.queryParameters['url'];
      if (url == null || url.isEmpty || !isMp4Url(url)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final state = await _stateFor(
        request.uri.queryParameters['id'] ?? 'hanime-video',
        url,
        request.uri.queryParameters['ref'] ?? 'https://hanime1.me/',
      );

      if (request.method == 'HEAD') {
        await _forwardRequest(request, state);
        return;
      }
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader == null) {
        await _forwardRequest(request, state);
        return;
      }

      var range = parseByteRange(rangeHeader, totalLength: state.totalLength);
      // Suffix ranges need the file length; one cached block provides it via
      // Content-Range without pulling the full file.
      if (range == null && rangeHeader.startsWith('bytes=-')) {
        await _ensureChunk(state, 0);
        range = parseByteRange(rangeHeader, totalLength: state.totalLength);
      }
      if (range == null) {
        if (rangeHeader.startsWith('bytes=-')) {
          await _sendRangeNotSatisfiable(request, state.totalLength);
        } else {
          await _forwardRequest(request, state);
        }
        return;
      }

      final firstIndex = range.start ~/ chunkSize;
      _prioritizeWindow(state, firstIndex);
      final downloading = _ensureChunk(state, firstIndex);
      final transfer = state.transfers[firstIndex]!;
      // Headers are available before the complete block. Feed incoming bytes
      // to the decoder while the same request fills the disk cache.
      final streaming = await transfer.ready.future;
      if ((!streaming && !await downloading) || state.supportsRanges == false) {
        await _forwardRequest(request, state);
        return;
      }

      final total = state.totalLength;
      if (total == null || range.start >= total) {
        await _sendRangeNotSatisfiable(request, total);
        return;
      }
      final requestedEnd = range.end ?? (total - 1);
      final end = math.min(
        math.min(requestedEnd, total - 1),
        (firstIndex + 1) * chunkSize - 1,
      );
      final lastIndex = end ~/ chunkSize;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-$end/$total',
      );
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.contentLength = end - range.start + 1;
      request.response.bufferOutput = false;
      state.readingChunks.add(firstIndex);
      try {
        final offset = firstIndex * chunkSize;
        if (streaming) {
          await request.response.addStream(
            transfer.read(range.start - offset, end - offset + 1),
          );
        } else {
          final file = File(_chunkPath(state, firstIndex));
          await request.response.addStream(
            file.openRead(range.start - offset, end - offset + 1),
          );
        }
        state.markAccess(firstIndex);
      } finally {
        state.readingChunks.remove(firstIndex);
      }
      await request.response.close();
      unawaited(_pruneCache(state));
      if (_prefetchEnabled) _scheduleAhead(state, lastIndex + 1);
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
      AppLogger.w('HanimeMp4Range', '处理 MP4 Range 请求失败: $error');
    }
  }

  Future<bool> _ensureChunk(
    _Mp4State state,
    int index, {
    bool prefetch = false,
  }) {
    if (index < 0) return Future<bool>.value(false);
    final pending = state.inFlight[index];
    if (pending != null) {
      if (!prefetch) {
        state.transfers[index]?.foreground = true;
        _prioritizeQueuedChunk(state, index);
      }
      return pending;
    }

    // Register before the first filesystem await so simultaneous ExoPlayer
    // range requests share one upstream request per chunk.
    final completer = Completer<bool>();
    final task = completer.future;
    final transfer = _ChunkTransfer(foreground: !prefetch);
    state.transfers[index] = transfer;
    state.inFlight[index] = task;
    unawaited(() async {
      try {
        completer.complete(
          await _ensureChunkInternal(state, index, prefetch: prefetch),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        transfer.finish();
        if (identical(state.inFlight[index], task)) {
          state.inFlight.remove(index);
          state.transfers.remove(index);
        }
        if (prefetch) unawaited(_pruneCache(state));
      }
    }());
    return task;
  }

  void _prioritizeWindow(_Mp4State state, int firstIndex) {
    final previousKey = _foregroundKey;
    if (previousKey != state.key) {
      final previousState = previousKey == null ? null : _states[previousKey];
      if (previousState != null) {
        previousState.wholeCacheGeneration++;
      }
      for (final other in _states.values) {
        if (identical(other, state)) continue;
        for (final transfer in other.transfers.values) {
          if (!transfer.foreground) {
            transfer.cancelToken.cancel('active video changed');
          }
        }
      }
      for (final queued in _downloadQueue.toList()) {
        if (queued.videoKey == state.key || !queued.prefetch) continue;
        _downloadQueue.remove(queued);
        if (!queued.completer.isCompleted) queued.completer.complete(false);
      }
    }
    _foregroundKey = state.key;
    state.playbackIndex = firstIndex;
    // Keep same-video background cache fills running across seeks. Four slots
    // are capped for speculative work, leaving two of the six download slots
    // available to foreground range requests. Switching videos cancels old fills.
  }

  void _prioritizeQueuedChunk(_Mp4State state, int index) {
    for (var position = 0; position < _downloadQueue.length; position++) {
      final queued = _downloadQueue.elementAt(position);
      if (queued.videoKey == state.key && queued.index == index) {
        queued.prefetch = false;
        _downloadQueue.remove(queued);
        _downloadQueue.addFirst(queued);
        _pumpDownloadQueue();
        return;
      }
    }
  }

  Future<bool> _ensureChunkInternal(
    _Mp4State state,
    int index, {
    required bool prefetch,
  }) async {
    final file = File(_chunkPath(state, index));
    if (await file.exists() && await file.length() > 0) {
      state.markAccess(index);
      final now = DateTime.now();
      final lastTouched = state.diskTouchAt[index];
      if (lastTouched == null ||
          now.difference(lastTouched) >= const Duration(seconds: 30)) {
        state.diskTouchAt[index] = now;
        // Startup LRU uses the filesystem mtime; touch it asynchronously so
        // a range already used in this session is not evicted as stale later.
        unawaited(() async {
          try {
            await file.setLastModified(now);
          } catch (_) {
            // A failed LRU hint must never affect playback from the cache.
          }
        }());
      }
      return true;
    }

    final task = _enqueueDownload(
      () => _downloadChunk(state, index),
      videoKey: state.key,
      index: index,
      prefetch: prefetch,
    );
    final success = await task;
    if (success) state.markAccess(index);
    return success;
  }

  Future<void> _cacheRemainingChunks(_Mp4State state, int firstIndex) async {
    final existing = state.wholeCacheTask;
    if (existing != null) return existing;
    final generation = state.wholeCacheGeneration;
    final task = _fillRemainingChunks(state, firstIndex, generation);
    state.wholeCacheTask = task;
    try {
      await task;
    } catch (error) {
      AppLogger.w('HanimeMp4Range', '后台全片缓存异常: $error');
    } finally {
      if (identical(state.wholeCacheTask, task)) state.wholeCacheTask = null;
    }
  }

  Future<void> _fillRemainingChunks(
    _Mp4State state,
    int firstIndex,
    int generation,
  ) async {
    final totalLength = state.totalLength;
    if (!_prefetchEnabled ||
        _closing ||
        totalLength == null ||
        state.supportsRanges != true) {
      return;
    }
    if (totalLength > _maxCacheBytesPerVideo) {
      AppLogger.i(
        'HanimeMp4Range',
        '视频大小 ${(totalLength / 1024 / 1024).toStringAsFixed(1)}MB '
            '超过单视频缓存上限 '
            '${(_maxCacheBytesPerVideo / 1024 / 1024).toStringAsFixed(0)}MB，'
            '仅缓存已播放与前方分段',
      );
      return;
    }

    final chunkCount = (totalLength + chunkSize - 1) ~/ chunkSize;
    var cacheComplete = true;
    AppLogger.i(
      'HanimeMp4Range',
      '后台补全 MP4 缓存：$chunkCount 段，'
          '${(totalLength / 1024 / 1024).toStringAsFixed(1)}MB',
    );
    for (
      var batchStart = firstIndex;
      batchStart < chunkCount &&
          _prefetchEnabled &&
          !_closing &&
          generation == state.wholeCacheGeneration;
      batchStart += _maxConcurrentPrefetches
    ) {
      final batchEnd = math.min(
        batchStart + _maxConcurrentPrefetches,
        chunkCount,
      );
      final results = await Future.wait<bool>([
        for (var index = batchStart; index < batchEnd; index++)
          _ensureChunk(state, index, prefetch: true).catchError((_) => false),
      ]);
      if (results.any((success) => !success) &&
          generation == state.wholeCacheGeneration &&
          _prefetchEnabled) {
        // A seek or transient network failure may cancel a background range.
        // Retry only once to avoid a stuck or endlessly retrying cache worker.
        for (var offset = 0; offset < results.length; offset++) {
          if (results[offset]) continue;
          final index = batchStart + offset;
          if (generation != state.wholeCacheGeneration || !_prefetchEnabled) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final retried = await _ensureChunk(
            state,
            index,
            prefetch: true,
          ).catchError((_) => false);
          if (!retried) cacheComplete = false;
        }
      }
    }
    if (generation == state.wholeCacheGeneration && _prefetchEnabled) {
      if (cacheComplete) {
        AppLogger.i('HanimeMp4Range', 'MP4 后台全片缓存完成: ${state.key}');
      } else {
        AppLogger.w('HanimeMp4Range', 'MP4 后台缓存未完整填满: ${state.key}');
      }
    }
  }

  Future<bool> _enqueueDownload(
    Future<bool> Function() action, {
    required String videoKey,
    required int index,
    required bool prefetch,
  }) {
    final queued = _QueuedRangeDownload(
      action: action,
      videoKey: videoKey,
      index: index,
      prefetch: prefetch,
    );
    if (prefetch) {
      _downloadQueue.addLast(queued);
    } else {
      _downloadQueue.addFirst(queued);
    }
    _pumpDownloadQueue();
    return queued.completer.future;
  }

  void _pumpDownloadQueue() {
    while (_activeDownloads < _maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      _QueuedRangeDownload? next;
      for (final queued in _downloadQueue) {
        if (!queued.prefetch || _activePrefetches < _maxConcurrentPrefetches) {
          next = queued;
          break;
        }
      }
      if (next == null) return;
      _downloadQueue.remove(next);
      _activeDownloads++;
      if (next.prefetch) _activePrefetches++;
      unawaited(() async {
        try {
          next!.completer.complete(await next.action());
        } catch (error, stack) {
          next!.completer.completeError(error, stack);
        } finally {
          _activeDownloads--;
          if (next!.prefetch) _activePrefetches--;
          _pumpDownloadQueue();
        }
      }());
    }
  }

  Future<bool> _downloadChunk(_Mp4State state, int index) async {
    final transfer = state.transfers[index]!;
    final stopwatch = Stopwatch()..start();
    final start = index * chunkSize;
    final knownLength = state.totalLength;
    if (knownLength != null && start >= knownLength) return false;
    final end = knownLength == null
        ? start + chunkSize - 1
        : math.min(start + chunkSize - 1, knownLength - 1);
    final tempFile = File('${_chunkPath(state, index)}.tmp');
    try {
      final response = await _dio.get<ResponseBody>(
        state.url,
        cancelToken: transfer.cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, String>{
            HttpHeaders.rangeHeader: 'bytes=$start-$end',
            'Referer': state.referer,
          },
        ),
      );
      if (response.statusCode != HttpStatus.partialContent) {
        if (response.statusCode == HttpStatus.ok) {
          state.supportsRanges = false;
        }
        final stream = response.data?.stream;
        if (stream != null) await stream.listen((_) {}).cancel();
        return false;
      }

      // 同 _forwardRequest：用 headers[name] 而不是 value()，
      // 否则同名头出现多次时会抛异常，整块分片下载直接失败。
      final contentRange = _parseContentRange(
        response.headers[HttpHeaders.contentRangeHeader]?.first,
      );
      if (contentRange == null ||
          contentRange.start != start ||
          contentRange.end != math.min(end, contentRange.totalLength - 1)) {
        state.supportsRanges = false;
        final stream = response.data?.stream;
        if (stream != null) await stream.listen((_) {}).cancel();
        return false;
      }
      state.supportsRanges = true;
      state.totalLength = contentRange.totalLength;
      transfer.ready.complete(true);

      await tempFile.parent.create(recursive: true);
      final stream = response.data?.stream;
      if (stream == null) {
        if (await tempFile.exists()) await tempFile.delete();
        return false;
      }
      final sink = tempFile.openWrite();
      try {
        await for (final data in stream) {
          sink.add(data);
          transfer.add(data);
        }
      } finally {
        await sink.close();
      }

      final bytes = await tempFile.length();
      if (bytes <= 0 || bytes != contentRange.end - contentRange.start + 1) {
        await tempFile.delete().catchError((_) => tempFile);
        return false;
      }
      final finalFile = File(_chunkPath(state, index));
      if (await finalFile.exists()) await finalFile.delete();
      await tempFile.rename(finalFile.path);
      // A full-speed 1080p stream can complete thousands of these blocks.
      // Persisting one success log per block adds disk writes on the playback
      // path and floods logcat; retain only slow-range diagnostics.
      if (stopwatch.elapsed >= const Duration(seconds: 1)) {
        AppLogger.w(
          'HanimeMp4Range',
          'Range $start-$end 较慢：${bytes}B/${stopwatch.elapsedMilliseconds}ms',
        );
      }
      return true;
    } catch (error) {
      if (await tempFile.exists()) {
        await tempFile.delete().catchError((_) => tempFile);
      }
      if (!transfer.cancelToken.isCancelled) {
        AppLogger.w('HanimeMp4Range', 'MP4 分段下载失败 index=$index: $error');
      }
      return false;
    }
  }

  void _scheduleAhead(_Mp4State state, int firstIndex) {
    if (!_prefetchEnabled) return;
    if (_foregroundKey != null && _foregroundKey != state.key) return;
    final current = state.playbackIndex;
    if (current != null && firstIndex != current + 1) return;
    for (
      var index = firstIndex;
      index < firstIndex + prefetchConcurrency;
      index++
    ) {
      final start = index * chunkSize;
      if (state.totalLength != null && start >= state.totalLength!) break;
      if (!state.prefetchQueued.add(index)) continue;
      unawaited(
        _ensureChunk(state, index, prefetch: true)
            .then((success) {
              if (!success) state.prefetchQueued.remove(index);
              if (success) unawaited(_pruneCache(state));
            })
            .catchError((Object error) {
              state.prefetchQueued.remove(index);
              AppLogger.w('HanimeMp4Range', '并发预取失败 index=$index: $error');
            }),
      );
    }
  }

  Future<void> _pruneCache(_Mp4State state) {
    if (_closing) return Future<void>.value();
    final pending = _pruneTask;
    if (pending != null) return pending;
    final now = DateTime.now();
    if (_lastPrune != null &&
        now.difference(_lastPrune!) < const Duration(seconds: 2)) {
      return Future<void>.value();
    }
    _lastPrune = now;
    return _pruneTask = _pruneCacheInternal(state)
        .whenComplete(() => _pruneTask = null);
  }

  /// 启动后的磁盘缓存清理。
  ///
  /// 与 [_pruneGlobalCache] 的区别：后者只统计**本次进程已打开过**的视频
  /// （`_states` 里的），启动时列表为空、等于没清理。这里直接扫描缓存根目录，
  /// 按「文件最后修改时间」做 LRU，把全局占用裁到 [_maxCacheBytesTotal]。
  ///
  /// 之所以改成保留而非清空：见 [_initInternal] 的注释。
  void _scheduleStartupPrune() {
    _pruneTask = _pruneCacheOnDisk().whenComplete(() => _pruneTask = null);
  }

  Future<void> _pruneCacheOnDisk() async {
    final root = _cacheRoot;
    if (root == null) return;
    try {
      final files = <({File file, int bytes, DateTime modified})>[];
      var totalBytes = 0;
      await for (final videoEntry in root.list()) {
        if (videoEntry is! Directory) continue;
        await for (final entity in videoEntry.list()) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.bin')) continue;
          final stat = await entity.stat();
          totalBytes += stat.size;
          files.add((file: entity, bytes: stat.size, modified: stat.modified));
        }
      }
      if (totalBytes <= _maxCacheBytesTotal) {
        AppLogger.i(
          'HanimeMp4Range',
          '启动缓存保留 ${files.length} 个分块、'
              '${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB（未超上限）',
        );
        return;
      }

      files.sort((a, b) => a.modified.compareTo(b.modified));
      var removed = 0;
      for (final entry in files) {
        if (totalBytes <= _maxCacheBytesTotal) break;
        try {
          await entry.file.delete();
          totalBytes -= entry.bytes;
          removed++;
        } catch (_) {
          // 单个文件删不掉（被占用等）跳过即可。
        }
      }
      AppLogger.i(
        'HanimeMp4Range',
        '启动缓存清理：删除 $removed 个旧分块，'
            '剩余 ${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB',
      );
    } catch (error) {
      AppLogger.w('HanimeMp4Range', '启动缓存清理失败: $error');
    }
  }

  Future<void> _pruneCacheInternal(_Mp4State state) async {
    try {
      final files = <({int index, File file, int bytes, int access})>[];
      await for (final entity in state.directory.list()) {
        if (entity is! File) continue;
        final match = RegExp(r'^range_(\d+)\.bin$')
            .firstMatch(p.basename(entity.path));
        if (match == null) continue;
        final index = int.tryParse(match.group(1)!);
        if (index == null) continue;
        files.add((
          index: index,
          file: entity,
          bytes: await entity.length(),
          access: state.accessOrder[index] ?? 0,
        ));
      }
      var totalBytes = files.fold<int>(0, (sum, file) => sum + file.bytes);
      if (totalBytes > _maxCacheBytesPerVideo) {
        files.sort((a, b) => a.access.compareTo(b.access));
        for (final entry in files) {
          if (totalBytes <= _maxCacheBytesPerVideo) break;
          if (state.readingChunks.contains(entry.index) ||
              state.inFlight.containsKey(entry.index)) {
            continue;
          }
          await entry.file.delete();
          state.accessOrder.remove(entry.index);
          state.prefetchQueued.remove(entry.index);
          totalBytes -= entry.bytes;
        }
      }
      await _pruneGlobalCache(state);
    } catch (error) {
      AppLogger.w('HanimeMp4Range', '清理分段缓存失败: $error');
    }
  }

  Future<void> _pruneGlobalCache(_Mp4State keepState) async {
    final allFiles =
        <
          ({_Mp4State state, int index, File file, int bytes, DateTime access})
        >[];
    var totalBytes = 0;
    for (final state in _states.values.toList()) {
      await for (final entity in state.directory.list()) {
        if (entity is! File) continue;
        final match = RegExp(r'^range_(\d+)\.bin$')
            .firstMatch(p.basename(entity.path));
        if (match == null) continue;
        final index = int.tryParse(match.group(1)!);
        if (index == null) continue;
        final bytes = await entity.length();
        totalBytes += bytes;
        allFiles.add((
          state: state,
          index: index,
          file: entity,
          bytes: bytes,
          access: state.lastAccessAt,
        ));
      }
    }
    if (totalBytes <= _maxCacheBytesTotal) return;

    allFiles.sort((a, b) => a.access.compareTo(b.access));
    for (final entry in allFiles) {
      if (totalBytes <= _maxCacheBytesTotal) break;
      if (identical(entry.state, keepState) ||
          entry.state.readingChunks.contains(entry.index) ||
          entry.state.inFlight.containsKey(entry.index)) {
        continue;
      }
      await entry.file.delete();
      entry.state.accessOrder.remove(entry.index);
      entry.state.prefetchQueued.remove(entry.index);
      totalBytes -= entry.bytes;
    }

    for (final state in _states.values.toList()) {
      if (identical(state, keepState) ||
          state.inFlight.isNotEmpty ||
          state.readingChunks.isNotEmpty ||
          state.accessOrder.isNotEmpty) {
        continue;
      }
      await state.directory.delete(recursive: true);
      _states.remove(state.key);
    }
  }

  Future<void> _forwardRequest(HttpRequest request, _Mp4State state) async {
    final headers = <String, String>{'Referer': state.referer};
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) headers[HttpHeaders.rangeHeader] = range;
    final response = await _dio.request<ResponseBody>(
      state.url,
      options: Options(
        method: request.method,
        responseType: ResponseType.stream,
        headers: headers,
      ),
    );
    request.response.statusCode = response.statusCode ?? HttpStatus.badGateway;
    for (final name in <String>[
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ]) {
      // 必须用 headers[name]（返回 List<String>?），不能用 headers.value(name)。
      // Dio 的 value() 在**同名响应头出现多次**时会抛
      // `Exception: "xxx" header has more than one value, please use Headers[name]`。
      // 实测 CDN 会返回多个 accept-ranges，于是每次 Range 转发都在这里抛异常，
      // 代理返回空响应 → ExoPlayer 报 `ExoPlaybackException: Source error`，
      // 用户侧表现为「很多视频打不开」。
      final values = response.headers[name];
      if (values == null || values.isEmpty) continue;
      // 单值时与原行为完全一致；同名重复值按 HTTP 规范去重后逗号连接。
      request.response.headers.set(name, values.toSet().join(', '));
    }
    final stream = response.data?.stream;
    if (request.method != 'HEAD' && stream != null) {
      await request.response.addStream(stream);
    }
    await request.response.close();
  }

  Future<void> _sendRangeNotSatisfiable(
    HttpRequest request,
    int? totalLength,
  ) async {
    request.response.statusCode = 416;
    if (totalLength != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalLength',
      );
    }
    await request.response.close();
  }

  String _chunkPath(_Mp4State state, int index) =>
      p.join(state.directory.path, 'range_$index.bin');

  static _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null || end == null || total == null || end < start) {
      return null;
    }
    return _ContentRange(start: start, end: end, totalLength: total);
  }
}

class ByteRangeRequest {
  const ByteRangeRequest({required this.start, this.end});

  final int start;
  final int? end;
}

class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.totalLength,
  });

  final int start;
  final int end;
  final int totalLength;
}

class _Mp4State {
  _Mp4State({
    required this.key,
    required this.url,
    required this.referer,
    required this.directory,
  });

  final String key;
  final String url;
  final String referer;
  final Directory directory;
  final Map<int, Future<bool>> inFlight = <int, Future<bool>>{};
  final Map<int, _ChunkTransfer> transfers = <int, _ChunkTransfer>{};
  final Set<int> prefetchQueued = <int>{};
  final Set<int> readingChunks = <int>{};
  final Map<int, int> accessOrder = <int, int>{};
  int _accessCounter = 0;
  DateTime lastAccessAt = DateTime.now();
  int? totalLength;
  int? playbackIndex;
  bool? supportsRanges;
  int wholeCacheGeneration = 0;
  Future<void>? wholeCacheTask;
  final Map<int, DateTime> diskTouchAt = <int, DateTime>{};

  void markAccess(int index) {
    accessOrder[index] = ++_accessCounter;
    lastAccessAt = DateTime.now();
  }
}

/// A bounded replay buffer (at most one range block) shared by simultaneous
/// readers. New readers see the existing prefix, then follow incoming bytes.
class _ChunkTransfer {
  _ChunkTransfer({required this.foreground});

  bool foreground;
  final CancelToken cancelToken = CancelToken();
  final Completer<bool> ready = Completer<bool>();
  final List<List<int>> _chunks = [];
  Completer<void> _changed = Completer<void>();
  bool _finished = false;

  void add(List<int> bytes) {
    _chunks.add(bytes);
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void finish() {
    _finished = true;
    if (!ready.isCompleted) ready.complete(false);
    if (!_changed.isCompleted) _changed.complete();
  }

  Stream<List<int>> read(int start, int end) async* {
    var index = 0;
    var offset = 0;
    while (offset < end) {
      if (index < _chunks.length) {
        final bytes = _chunks[index++];
        final nextOffset = offset + bytes.length;
        if (nextOffset > start) {
          yield bytes.sublist(
            math.max(0, start - offset),
            math.min(bytes.length, end - offset),
          );
        }
        offset = nextOffset;
      } else if (_finished) {
        throw const HttpException('Incomplete MP4 range');
      } else {
        await _changed.future;
      }
    }
  }
}

class _QueuedRangeDownload {
  _QueuedRangeDownload({
    required this.action,
    required this.videoKey,
    required this.index,
    required this.prefetch,
  });

  final Future<bool> Function() action;
  final String videoKey;
  final int index;
  bool prefetch;
  final Completer<bool> completer = Completer<bool>();
}
