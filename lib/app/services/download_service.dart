/// HLS 下载服务：任务队列 + 分片并发下载 + 重试 + 断点续传 + 合并。
///
/// 相对原 Kotlin 版 `VideoDownloadManager` 的改进：
///   1. 原版用 `segments.forEachIndexed` 串行下载，且 `downloadSegment` 失败只打日志、
///      返回空数组仍继续，会静默产出损坏文件 —— 这里改为并发 + 逐分片重试，
///      任一必得分片最终失败则整任务失败；
///   2. 原版每次重试都从 0 重新下载全部分片 —— 这里按分片文件存在性续传；
///   3. 原版把 m3u8 当分片列表，遇到 master playlist 必然失败 —— 这里先解析变体；
///   4. 原版无并发上限控制、无取消能力 —— 这里都有。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../core/app_logger.dart';
import '../core/media_utils.dart';
import '../data/models/video_item.dart';
import '../data/sources/video_source.dart';
import 'hls_parser.dart';
import 'task_repository.dart';

/// 计数信号量。用于同时限制"并发任务数"与"单任务内并发分片数"。
class Semaphore {
  Semaphore(this.max) : assert(max > 0);

  final int max;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_active < max) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_active > 0) {
      _active--;
    }
  }
}

class DownloadService extends GetxService {
  DownloadService({
    Dio? dio,
    this.maxConcurrentTasks = 3,
    this.maxConcurrentSegments = 4,
    this.maxAttemptsPerSegment = 3,
  }) : _dio = dio ?? _defaultDio();

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final Dio _dio;

  /// 同时进行的任务数上限。
  final int maxConcurrentTasks;

  /// 单个任务内同时下载的分片数上限。
  final int maxConcurrentSegments;

  /// 单个分片的最大尝试次数。
  final int maxAttemptsPerSegment;

  /// UI 绑定用的响应式列表。
  final RxList<DownloadTask> tasks = <DownloadTask>[].obs;

  final Set<String> _canceled = <String>{};
  final Set<String> _running = <String>{};
  late final Semaphore _taskGate = Semaphore(maxConcurrentTasks);
  bool _disposed = false;

  static Dio _defaultDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 20),
        // 4xx/5xx 不抛异常，交由调用方按状态码处理。
        validateStatus: (code) => code != null && code < 400,
      ),
    );
  }

  /// 从磁盘恢复任务列表。在 `main()` 中 await。
  Future<DownloadService> init() async {
    await TaskRepository.instance.load();
    tasks.assignAll(TaskRepository.instance.all);
    // 恢复后自动接续未完成的任务。
    for (final t in tasks.where((t) => t.status == DownloadStatus.pending)) {
      unawaited(_schedule(t));
    }
    return this;
  }

  // ---------------------------------------------------------------- 对外操作

  /// 入队。同一视频重复入队时，若已在队列中则不重复添加。
  DownloadTask enqueue(VideoItem video) {
    final existing = TaskRepository.instance.byId(video.id);
    if (existing != null && existing.isActive) return existing;

    final task = DownloadTask(video: video);
    TaskRepository.instance.upsert(task);
    _syncFromRepository();
    unawaited(_schedule(task));
    return task;
  }

  void cancel(String taskId) {
    _canceled.add(taskId);
    final task = TaskRepository.instance.byId(taskId);
    if (task != null && task.status != DownloadStatus.completed) {
      task.status = DownloadStatus.canceled;
      task.error = null;
      TaskRepository.instance.upsert(task);
      _syncFromRepository();
    }
  }

  /// 重新入队一个已失败/已取消的任务。
  Future<void> retry(String taskId) async {
    final task = TaskRepository.instance.byId(taskId);
    if (task == null || task.isActive) return;
    _canceled.remove(taskId);

    // 立即更新状态为 pending 防止重复点击触发多次 retry
    _update(task, () {
      task.status = DownloadStatus.pending;
      task.progress = 0;
      task.completedSegments = 0;
      task.error = null;
    });

    // 重试时清理之前的分片，避免坏块导致继续失败，必须 await！否则会导致执行一半时目录被删！
    try {
      final dir = await StoragePaths.tempDir(taskId);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (e) {
      // 关键 IO：残留坏分片没被清掉，本次重试会从坏块继续 → 大概率**再次失败**。
      // 用户侧表现为「点了重试还是失败，重复几次都一样」且无任何日志。控制流不变。
      AppLogger.w('Downloader', '重试前清理残留分片失败 taskId=$taskId，本次重试可能因坏块再次失败: $e');
    }

    unawaited(_schedule(task));
  }

  void remove(String taskId) {
    cancel(taskId);
    TaskRepository.instance.remove(taskId);
    _syncFromRepository();
  }

  void clearCompleted() {
    TaskRepository.instance.clearCompleted();
    _syncFromRepository();
  }

  // ---------------------------------------------------------------- 队列调度

  Future<void> _schedule(DownloadTask task) async {
    if (_disposed || _running.contains(task.id)) return;
    if (task.status == DownloadStatus.completed) return;

    _running.add(task.id);
    await _taskGate.acquire();
    try {
      if (_canceled.contains(task.id)) {
        _markCanceled(task);
        return;
      }
      await _execute(task);
    } finally {
      _taskGate.release();
      _running.remove(task.id);
      if (!_disposed) unawaited(TaskRepository.instance.flush());
    }
  }

  // ---------------------------------------------------------------- 核心流程

  Future<void> _execute(DownloadTask task) async {
    var video = task.video;
    try {
      _update(task, () {
        task.status = DownloadStatus.running;
        task.progress = 0;
        task.completedSegments = 0;
        task.error = null;
      });

      // 始终动态获取最新详情以防 HLS 链接过期或缺失
      if (video.detailUrl != null || video.id.startsWith('http')) {
        AppLogger.i('Downloader', '任务 [${video.title}] 获取最新视频详情...');
        final targetUrl = video.detailUrl ?? video.id;
        if (targetUrl.isNotEmpty && targetUrl.startsWith('http')) {
          final source = SourceRegistry.forVideo(
            video,
            fallback: Get.find<VideoSource>(),
          );
          final detail = await source.fetchDetail(
            targetUrl,
            forceRefresh: true,
          );
          if (detail != null && detail.video.hlsUrl.isNotEmpty) {
            video = video.copyWith(
              hlsUrl: detail.video.hlsUrl,
              title: detail.video.title.isNotEmpty
                  ? detail.video.title
                  : video.title,
              publishedAt: detail.video.publishedAt ?? video.publishedAt,
            );
            task = DownloadTask(
              video: video,
              status: task.status,
              createdAt: task.createdAt,
            );
            TaskRepository.instance.upsert(task);
            _syncFromRepository();
            AppLogger.i('Downloader', '已解析出 HLS 地址: ${video.hlsUrl}');
          } else {
            throw Exception('未能从视频页面解析出有效 M3U8 播放地址');
          }
        } else {
          throw Exception('无效的视频页面链接: $targetUrl');
        }
      }

      AppLogger.i('Downloader', '开始下载任务: ${video.title} -> ${video.hlsUrl}');
      final String downloadReferer = video.detailUrl ?? 'https://91porny.com/';

      if (video.hlsUrl.contains('.mp4') && !video.hlsUrl.contains('.m3u8')) {
        AppLogger.i('Downloader', '检测到 MP4 直链，开始直接下载...');
        final authorDir = await StoragePaths.authorDir(video.author);
        final output = File(
          '${authorDir.path}${Platform.pathSeparator}${video.downloadBaseName}.mp4',
        );

        // Single file download directly to output
        await _dio
            .download(
              video.hlsUrl,
              output.path,
              options: Options(
                headers: <String, dynamic>{
                  'User-Agent': _ua,
                  'Accept': '*/*',
                  'Referer': downloadReferer,
                },
              ),
              onReceiveProgress: (count, total) {
                if (total > 0 && total != -1) {
                  _update(task, () {
                    task.progress = count / total;
                  });
                }
              },
            )
            .timeout(
              const Duration(minutes: 60),
              onTimeout: () => throw TimeoutException('MP4下载超时'),
            );

        _update(task, () {
          task.status = DownloadStatus.completed;
          task.progress = 1.0;
          task.completedSegments = 1;
          task.outputPath = output.path;
          task.error = null;
        });
        return;
      }

      // 第 1 步：解析播放列表。master -> 选最高码率 -> 再取 media playlist。
      AppLogger.i('Downloader', '正在请求 M3U8 播放列表...');
      var playlist = await _fetchPlaylist(
        Uri.parse(video.hlsUrl),
        downloadReferer,
      );
      AppLogger.i('Downloader', 'M3U8 播放列表请求完成，isMaster: ${playlist.isMaster}');
      if (playlist.isMaster) {
        final best = HlsParser.pickBest(playlist.variants);
        playlist = await _fetchPlaylist(best.uri, downloadReferer);
        AppLogger.i('Downloader', 'Media 播放列表请求完成');
      }

      if (playlist.isEncrypted) {
        throw Exception(
          '该流使用 ${playlist.encryptionMethod} 加密，'
          '当前版本未实现密钥获取与解密',
        );
      }

      // 第 2 步：拼出待下载分片序列（fMP4 的 init segment 必须排在最前）。
      final parts = <Uri>[
        if (playlist.initSegment != null) playlist.initSegment!,
        ...playlist.segments,
      ];
      if (parts.isEmpty) {
        throw Exception('播放列表中没有可用分片');
      }

      AppLogger.i('Downloader', '准备获取临时文件夹路径...');
      final tempDir = await StoragePaths.tempDir(task.id);
      AppLogger.i('Downloader', '获取临时文件夹路径成功: ${tempDir.path}');
      final alreadyDone = await _countExisting(tempDir, parts.length);

      _update(task, () {
        task.totalSegments = parts.length;
        task.completedSegments = alreadyDone;
        task.progress = alreadyDone / parts.length;
      });

      AppLogger.i('Downloader', '准备开始并发下载分片...');
      // 第 3 步：并发下载缺失分片，带续传。
      var done = alreadyDone;
      final gate = Semaphore(maxConcurrentSegments);
      final jobs = <Future<void>>[];

      for (var i = 0; i < parts.length; i++) {
        final index = i;
        jobs.add(() async {
          await gate.acquire();
          try {
            if (_canceled.contains(task.id)) return;

            final target = File(_partPath(tempDir, index));
            // 续传：已存在且非空的分片直接跳过。
            if (target.existsSync() && await target.length() > 0) return;

            final bytes = await _downloadPart(parts[index], downloadReferer);
            await target.writeAsBytes(bytes, flush: false);

            done++;
            _update(task, () {
              task.completedSegments = done;
              task.progress = done / parts.length;
            });
          } finally {
            gate.release();
          }
        }());
      }

      await Future.wait(jobs);

      if (_canceled.contains(task.id)) {
        _markCanceled(task);
        return;
      }

      // 第 4 步：按序号合并为单文件，并统一封装为 .mp4 格式。
      final authorDir = await StoragePaths.authorDir(video.author);
      final finalMp4File = File(
        '${authorDir.path}${Platform.pathSeparator}'
        '${video.downloadBaseName}.mp4',
      );

      if (playlist.isFragmentedMp4) {
        // fMP4 流直接按序拼接即为合法规范 MP4
        await _merge(tempDir, finalMp4File, parts.length);
      } else {
        // MPEG-TS 流先拼接为临时 ts 文件，再通过 Android 原生 MediaExtractor + MediaMuxer 无损封装为标准 MP4
        final tempTsFile = File(
          '${tempDir.path}${Platform.pathSeparator}merged.ts',
        );
        await _merge(tempDir, tempTsFile, parts.length);

        AppLogger.i('Downloader', '正在将 TS 流封装为 MP4: ${finalMp4File.path}');
        final remuxOk = await MediaUtils.remuxTsToMp4(
          inputPath: tempTsFile.path,
          outputPath: finalMp4File.path,
        );

        if (remuxOk &&
            finalMp4File.existsSync() &&
            await finalMp4File.length() > 0) {
          AppLogger.i('Downloader', 'TS 流转封装 MP4 成功');
          try {
            await tempTsFile.delete();
          } catch (_) {}
        } else {
          AppLogger.w('Downloader', '原生 Remux 失败或不受支持，优雅降级为直接以 .mp4 保存');
          if (finalMp4File.existsSync()) {
            try {
              await finalMp4File.delete();
            } catch (_) {}
          }
          await tempTsFile.rename(finalMp4File.path);
        }
      }

      // 通知系统媒体库立即扫描刷新该视频
      await MediaUtils.scanFile(finalMp4File.path);

      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}

      _update(task, () {
        task.status = DownloadStatus.completed;
        task.progress = 1;
        task.completedSegments = parts.length;
        task.outputPath = finalMp4File.path;
        task.error = null;
      });
    } catch (e, stackTrace) {
      final message = e is HlsParseException ? e.message : e.toString();
      AppLogger.e('Downloader', '任务执行失败: $message\n$stackTrace');

      _update(task, () {
        task.status = DownloadStatus.failed;
        task.error = message;
      });
    }
  }

  Future<void> _markCanceled(DownloadTask task) async {
    _update(task, () {
      task.status = DownloadStatus.canceled;
      task.error = null;
    });
    final tempDir = await StoragePaths.tempDir(task.id);
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // 忽略：文件可能被占用。
      }
    }
  }

  // ---------------------------------------------------------------- 网络

  Future<HlsPlaylist> _fetchPlaylist(Uri uri, String referer) async {
    final response = await _dio
        .get<String>(
          uri.toString(),
          options: Options(
            responseType: ResponseType.plain,
            headers: <String, dynamic>{
              'User-Agent': _ua,
              'Accept': '*/*',
              'Referer': referer,
            },
          ),
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('请求播放列表超时'),
        );

    final body = response.data;
    if (body == null || body.trim().isEmpty) {
      throw HlsParseException('播放列表响应为空：$uri');
    }
    return HlsParser.parse(body, uri);
  }

  Future<List<int>> _downloadPart(Uri uri, String referer) async {
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttemptsPerSegment; attempt++) {
      try {
        final response = await _dio
            .get<List<int>>(
              uri.toString(),
              options: Options(
                responseType: ResponseType.bytes,
                headers: <String, dynamic>{
                  'User-Agent': _ua,
                  'Accept': '*/*',
                  'Referer': referer,
                },
              ),
            )
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () => throw TimeoutException('请求分片超时'),
            );

        final data = response.data;
        if (data == null || data.isEmpty) {
          throw Exception('分片响应为空');
        }
        return data;
      } catch (e) {
        lastError = e;
        if (attempt < maxAttemptsPerSegment) {
          // 线性退避，给源站恢复时间。
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
      }
    }

    throw Exception('分片下载失败（已重试 $maxAttemptsPerSegment 次）：$uri\n$lastError');
  }

  // ---------------------------------------------------------------- 本地 IO

  static String _partPath(Directory dir, int index) =>
      '${dir.path}${Platform.pathSeparator}part_${index.toString().padLeft(6, '0')}.bin';

  Future<int> _countExisting(Directory dir, int total) async {
    var count = 0;
    for (var i = 0; i < total; i++) {
      final f = File(_partPath(dir, i));
      if (f.existsSync() && await f.length() > 0) count++;
    }
    return count;
  }

  /// 按分片序号顺序拼接。用流式写入避免把整个视频读进内存。
  Future<void> _merge(Directory tempDir, File output, int total) async {
    final sink = output.openWrite();
    try {
      for (var i = 0; i < total; i++) {
        final part = File(_partPath(tempDir, i));
        if (!part.existsSync()) {
          throw Exception('分片缺失：${part.path}');
        }
        await sink.addStream(part.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (!output.existsSync() || await output.length() == 0) {
      throw Exception('合并结果为空：${output.path}');
    }
  }

  // ---------------------------------------------------------------- 状态同步

  void _update(DownloadTask task, void Function() mutate) {
    mutate();
    task.touch();
    TaskRepository.instance.upsert(task);
    _syncFromRepository();
  }

  void syncFromRepository() {
    if (_disposed) return;
    final latest = TaskRepository.instance.all;
    // 逐项替换以触发 GetX 的细粒度更新。
    tasks.assignAll(latest);
  }

  void _syncFromRepository() => syncFromRepository();

  @override
  void onClose() {
    _disposed = true;
    unawaited(TaskRepository.instance.flush());
    super.onClose();
  }
}
