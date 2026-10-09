/// Android Media3 playback-cache controls and cache preloading.
///
/// Playback on Android goes through Media3's shared `SimpleCache`, which only ever stores what the
/// decoder happens to read. That makes the first open of any video a cold network start. The
/// preload API below drives Media3's own offline downloaders (`HlsDownloader` for the 91 HLS
/// source, `ProgressiveDownloader` for the Hanime1 progressive MP4 source) so that the bytes the
/// player will need are already on disk before the user taps — and they land in the *same* cache
/// the player reads through, so nothing is downloaded twice.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_logger.dart';

/// Progress report for a single preload task.
class Media3PreloadProgress {
  const Media3PreloadProgress({
    required this.taskId,
    required this.contentLength,
    required this.bytesDownloaded,
    required this.percent,
    required this.finished,
    this.error,
  });

  final String taskId;

  /// Total size in bytes, or `-1` when the server did not advertise one.
  final int contentLength;

  /// Bytes currently held in the cache for this resource.
  final int bytesDownloaded;

  /// 0..100, or `-1` when the total size is unknown.
  final double percent;

  /// True once the requested window is fully cached.
  final bool finished;

  /// Non-null when the preload failed.
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;

  @override
  String toString() =>
      'Media3PreloadProgress($taskId, $bytesDownloaded/$contentLength, '
      '${percent.toStringAsFixed(1)}%, finished=$finished, error=$error)';
}

class Media3CacheService {
  Media3CacheService._();

  static const MethodChannel _channel = MethodChannel(
    'video_browser/media3_cache',
  );

  static final StreamController<Media3PreloadProgress> _progressController =
      StreamController<Media3PreloadProgress>.broadcast();
  static final Map<String, Media3PreloadProgress> _latestProgressByTask = {};

  static bool _handlerInstalled = false;

  /// Preload progress for every task. Broadcast, so several listeners are fine.
  static Stream<Media3PreloadProgress> get progress =>
      _progressController.stream;

  /// Most recent cache state, retained so reopening a video does not reset its bar to zero.
  static Media3PreloadProgress? latestProgressFor(String taskId) =>
      _latestProgressByTask[taskId];

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'preloadProgress') return null;
      final args = call.arguments;
      if (args is! Map) return null;
      final taskId = args['taskId'];
      if (taskId is! String) return null;
      final update = Media3PreloadProgress(
        taskId: taskId,
        contentLength: _asInt(args['contentLength'], -1),
        bytesDownloaded: _asInt(args['bytesDownloaded'], 0),
        percent: _asDouble(args['percent'], -1),
        finished: args['finished'] == true,
        error: args['error'] is String ? args['error'] as String : null,
      );
      // Keep a small bounded snapshot for player routes reopened in the same app session.
      _latestProgressByTask.remove(taskId);
      _latestProgressByTask[taskId] = update;
      if (_latestProgressByTask.length > 64) {
        _latestProgressByTask.remove(_latestProgressByTask.keys.first);
      }
      _progressController.add(update);
      return null;
    });
  }

  static int _asInt(Object? value, int fallback) =>
      value is num ? value.toInt() : fallback;

  static double _asDouble(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  static Future<void> setMaxCacheSizeMB(int megabytes) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
        'setMaxCacheBytes',
        megabytes * 1024 * 1024,
      );
    } catch (error) {
      AppLogger.w('Media3Cache', '更新 Android 播放缓存上限失败: $error');
    }
  }

  /// Returns the occupied bytes in Media3's shared disk cache. Null means the
  /// platform cannot report the native cache size.
  static Future<int?> getCacheSizeBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      final bytes = await _channel.invokeMethod<int>('getCacheSizeBytes');
      return bytes == null || bytes < 0 ? null : bytes;
    } catch (error) {
      AppLogger.w('Media3Cache', '读取 Android 播放缓存占用失败: $error');
      return null;
    }
  }

  /// Enables Media3's decoder optimizations while a user continuously scrubs one player.
  /// The native plugin restores normal playback behavior when [enabled] is false.
  static Future<void> setScrubbingModeForPlayer(
    int playerId, {
    required bool enabled,
  }) async {
    if (!Platform.isAndroid || playerId < 0) return;
    try {
      await _channel.invokeMethod<void>('setScrubbingMode', <String, Object?>{
        'playerId': playerId,
        'enabled': enabled,
      });
    } catch (error) {
      AppLogger.w(
        'Media3Cache',
        '切换原生拖动解码模式失败 playerId=$playerId enabled=$enabled: $error',
      );
    }
  }

  static Future<void> clear() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (error) {
      AppLogger.w('Media3Cache', '清除 Android 播放缓存失败: $error');
    }
  }

  /// Queues a preload into the shared Media3 playback cache.
  ///
  /// [isHls] selects the downloader: `HlsDownloader` fetches the playlist and every segment (plus
  /// encryption keys), `ProgressiveDownloader` walks the byte range of a progressive MP4.
  ///
  /// A non-positive [durationUs] (HLS) or [lengthBytes] (MP4) means "to the end of the media".
  /// [variantIndex] only applies to HLS multivariant playlists; a media playlist has no variants
  /// to choose between and is cached whole regardless.
  ///
  /// Returns true when the request was accepted by the platform.
  static Future<bool> preload({
    required String taskId,
    required String url,
    required bool isHls,
    Map<String, String>? headers,
    String? userAgent,
    int variantIndex = 0,
    int positionBytes = 0,
    int lengthBytes = 0,
    int durationUs = 0,
  }) async {
    if (!Platform.isAndroid) return false;
    if (url.isEmpty) return false;
    _ensureHandler();
    try {
      await _channel.invokeMethod<void>('preload', <String, Object?>{
        'taskId': taskId,
        'url': url,
        'isHls': isHls,
        'headers': headers ?? const <String, String>{},
        'userAgent': userAgent,
        'variantIndex': variantIndex,
        'positionBytes': positionBytes,
        'lengthBytes': lengthBytes,
        'durationUs': durationUs,
      });
      return true;
    } catch (error) {
      AppLogger.w('Media3Cache', '提交预缓存任务失败 taskId=$taskId: $error');
      return false;
    }
  }

  /// Cancels one preload task. Already-cached bytes stay in the cache.
  static Future<void> cancelPreload(String taskId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancelPreload', taskId);
    } catch (error) {
      AppLogger.w('Media3Cache', '取消预缓存任务失败 taskId=$taskId: $error');
    }
  }

  /// Cancels every in-flight preload task. Already-cached bytes stay in the cache.
  static Future<void> cancelAllPreloads() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancelAllPreloads');
    } catch (error) {
      AppLogger.w('Media3Cache', '取消全部预缓存任务失败: $error');
    }
  }

  /// Number of preload tasks the platform is currently running.
  static Future<int> activePreloadCount() async {
    if (!Platform.isAndroid) return 0;
    try {
      final count = await _channel.invokeMethod<int>('getPreloadStatus');
      return count ?? 0;
    } catch (error) {
      AppLogger.w('Media3Cache', '读取预缓存任务数失败: $error');
      return 0;
    }
  }
}
