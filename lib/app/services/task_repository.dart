/// 下载任务的持久化。
///
/// 对应原 Kotlin 项目 `Models.kt` 里的 `VideoStore`：
///   - 原实现是 `object` + `mutableListOf`，纯内存，进程被杀则任务与进度全部丢失；
///   - 这里改为 JSON 文件落盘（`path_provider` 提供目录），启动时恢复。
///
/// 选文件而非 sqflite 的原因：本工程同时构建 Android 与 Windows，
/// sqflite 在 Windows 上需要额外引入 FFI 与 sqlite3 动态库；
/// JSON 文件零原生配置，两端行为一致。
/// 所有读写都收拢在 [TaskRepository] 内，将来要换成 sqflite / drift，
/// 只需替换本文件，上层无感知。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/media_utils.dart';
import '../data/models/video_item.dart';

/// 统一的路径解析。
class StoragePaths {
  const StoragePaths._();

  static Directory? _root;

  /// 清除缓存的根目录（当修改设置时调用）
  static void clearRootCache() {
    _root = null;
  }

  /// 获取或设置自定义下载目录
  static Future<String?> getCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('custom_download_path');
  }

  static Future<void> setCustomPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove('custom_download_path');
    } else {
      await prefs.setString('custom_download_path', path);
    }
    clearRootCache();
  }

  /// 迁移下载文件夹到新目录，并自动更新所有任务和视频的路径。
  static Future<int> migrateTo(
    String newPath, {
    void Function(String message)? onProgress,
  }) async {
    final oldRoot = await root();
    if (p.canonicalize(oldRoot.path) == p.canonicalize(newPath)) {
      return 0;
    }

    final newDir = Directory(newPath);
    if (!newDir.existsSync()) {
      await newDir.create(recursive: true);
    }

    onProgress?.call('正在迁移已有下载文件...');
    await _copyAndRemoveDirectory(oldRoot, newDir, onProgress: onProgress);

    // 清理旧目录下的 .tmp 临时残留
    try {
      final oldTmp = Directory(p.join(oldRoot.path, '.tmp'));
      if (oldTmp.existsSync()) {
        await oldTmp.delete(recursive: true);
      }
    } catch (_) {}

    onProgress?.call('正在更新下载管理任务路径...');
    var migratedTasksCount = 0;
    for (final task in TaskRepository.instance.all) {
      if (task.outputPath != null && task.outputPath!.isNotEmpty) {
        final oldFilePath = task.outputPath!;
        String? newFilePath;

        if (oldFilePath.startsWith(oldRoot.path)) {
          final rel = p.relative(oldFilePath, from: oldRoot.path);
          final targetCandidate = p.join(newDir.path, rel);
          final mp4Candidate = targetCandidate.replaceAll(
            RegExp(r'\.ts$', caseSensitive: false),
            '.mp4',
          );
          if (File(mp4Candidate).existsSync()) {
            newFilePath = mp4Candidate;
          } else if (File(targetCandidate).existsSync()) {
            newFilePath = targetCandidate;
          } else {
            newFilePath = mp4Candidate;
          }
        } else {
          final fileName = p.basename(oldFilePath);
          final authorName = VideoItem.sanitizeFileName(
            task.video.author.isEmpty ? 'unknown' : task.video.author,
          );
          final mp4Name = fileName.replaceAll(
            RegExp(r'\.ts$', caseSensitive: false),
            '.mp4',
          );
          final candidateMp4 = p.join(newDir.path, authorName, mp4Name);
          final candidateOriginal = p.join(newDir.path, authorName, fileName);

          if (File(candidateMp4).existsSync()) {
            newFilePath = candidateMp4;
          } else if (File(candidateOriginal).existsSync()) {
            newFilePath = candidateOriginal;
          }
        }

        if (newFilePath != null) {
          task.outputPath = newFilePath;
          task.touch();
          migratedTasksCount++;
          MediaUtils.scanFile(newFilePath).ignore();
        }
      }
    }

    // 更新自定义路径配置
    await setCustomPath(newPath);

    // 将新的任务数据写入新目录下的 download_tasks.json
    await TaskRepository.instance.flush();

    return migratedTasksCount;
  }

  static Future<void> _copyAndRemoveDirectory(
    Directory source,
    Directory destination, {
    void Function(String message)? onProgress,
  }) async {
    if (!source.existsSync()) return;

    await for (final entity in source.list(
      recursive: false,
      followLinks: false,
    )) {
      final name = p.basename(entity.path);

      // 彻底跳过 .tmp 及隐藏临时文件
      if (name.startsWith('.') || name == '.tmp') {
        continue;
      }

      // 清洗 Windows / FAT32 文件名非法字符（如冒号等）
      final safeName = VideoItem.sanitizeFileName(name);

      if (entity is Directory) {
        final subDest = Directory(p.join(destination.path, safeName));
        if (!subDest.existsSync()) {
          await subDest.create(recursive: true);
        }
        await _copyAndRemoveDirectory(entity, subDest, onProgress: onProgress);
        try {
          await entity.delete();
        } catch (_) {}
      } else if (entity is File) {
        onProgress?.call('正在迁移: $safeName');

        // 如果是 .ts 视频，迁移时自动转为标准 .mp4 封装
        final isTs = safeName.toLowerCase().endsWith('.ts');
        final targetFileName = isTs
            ? safeName.replaceAll(
                RegExp(r'\.ts$', caseSensitive: false),
                '.mp4',
              )
            : safeName;
        final destPath = p.join(destination.path, targetFileName);

        var converted = false;
        if (isTs) {
          try {
            final ok = await MediaUtils.remuxTsToMp4(
              inputPath: entity.path,
              outputPath: destPath,
            );
            if (ok &&
                File(destPath).existsSync() &&
                await File(destPath).length() > 0) {
              converted = true;
              try {
                await entity.delete();
              } catch (_) {}
            }
          } catch (_) {}
        }

        if (!converted) {
          // 普通文件或未转码成功的直接移动（先 rename，跨卷异常则 copy + delete）
          try {
            await entity.rename(destPath);
          } catch (_) {
            await entity.copy(destPath);
            try {
              await entity.delete();
            } catch (_) {}
          }
        }

        MediaUtils.scanFile(destPath).ignore();
      }
    }
  }

  /// 应用下载根目录。
  static Future<Directory> root() async {
    final cached = _root;
    if (cached != null && cached.existsSync()) return cached;

    String? customPath = await getCustomPath();
    Directory dir;
    if (customPath != null && customPath.isNotEmpty) {
      dir = Directory(customPath);
    } else {
      final docs = await getApplicationDocumentsDirectory();
      dir = Directory('${docs.path}${Platform.pathSeparator}video_browser');
    }

    if (!dir.existsSync()) dir.createSync(recursive: true);
    _root = dir;
    return dir;
  }

  /// 某个作者的归档目录。
  ///
  /// 沿用原项目的"每个作者一个文件夹"约定。
  static Future<Directory> authorDir(String author) async {
    final base = await root();
    final safe = VideoItem.sanitizeFileName(
      author.isEmpty ? 'unknown' : author,
    );
    final dir = Directory('${base.path}${Platform.pathSeparator}$safe');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 分片临时目录（保存在应用临时缓存目录中，不再污染正式下载根目录）。
  static Future<Directory> tempDir(String taskId) async {
    final temp = await getTemporaryDirectory();
    final safeId = VideoItem.sanitizeFileName(taskId);
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}video_parts${Platform.pathSeparator}$safeId',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 磁盘占用统计（字节）。
  static Future<int> usedBytes() async {
    final base = await root();
    var total = 0;
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // 文件可能刚被清理，忽略。
        }
      }
    }
    return total;
  }
}

/// 任务仓库：内存态 + 落盘。
class TaskRepository {
  TaskRepository._();

  static final TaskRepository instance = TaskRepository._();

  static const String _fileName = 'download_tasks.json';

  final List<DownloadTask> _tasks = <DownloadTask>[];

  Timer? _saveDebounce;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<DownloadTask> get all => List<DownloadTask>.unmodifiable(_tasks);

  DownloadTask? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<File> _file() async {
    final dir = await StoragePaths.root();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 从磁盘恢复。应在 `main()` 里 await 一次。
  Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        _loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(raw) as List<dynamic>;
      _tasks
        ..clear()
        ..addAll(
          decoded.map(
            (e) => DownloadTask.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );

      // 进程上次退出时正在运行的任务，恢复到"等待中"，避免出现永久卡住的假运行态。
      for (final t in _tasks) {
        if (t.status == DownloadStatus.running) {
          t.status = DownloadStatus.pending;
          t.touch();
        }
      }
      _loaded = true;
    } catch (_) {
      // 存档损坏时以空列表启动，不阻塞应用。
      _tasks.clear();
      _loaded = true;
    }
  }

  void upsert(DownloadTask task) {
    task.touch();
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      _tasks[idx] = task;
    } else {
      _tasks.insert(0, task);
    }
    _scheduleSave();
  }

  void remove(String id) {
    _tasks.removeWhere((t) => t.id == id);
    _scheduleSave();
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _scheduleSave();
  }

  /// 合并写盘，避免进度回调高频触发 IO。
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    try {
      final file = await _file();
      final payload = jsonEncode(_tasks.map((t) => t.toJson()).toList());
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // 落盘失败不应影响下载主流程。
    }
  }
}
