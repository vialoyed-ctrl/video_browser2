/// 数据模型层。
///
/// 与原 Kotlin 项目 `Models.kt` 的对应关系：
///   - `Video`            -> [VideoItem]（列表/详情共用的只读模型）
///   - `DownloadStatus`   -> [DownloadStatus]
///   - `VideoStore`       -> 已移除。原实现是纯内存 object，进程被杀即丢失；
///                           这里改由 `services/task_repository.dart` 负责持久化。
library;

// 刻意不依赖 Flutter：数据模型应当与 UI 框架解耦，
// 这样它也能在纯 Dart VM 下被脚本或服务端复用。
import 'package:meta/meta.dart';

/// 下载任务的生命周期状态。
enum DownloadStatus {
  /// 已入队，尚未开始。
  pending,

  /// 正在解析 m3u8 或下载分片。
  running,

  /// 全部分片已下载并合并完成。
  completed,

  /// 重试次数耗尽后仍失败。
  failed,

  /// 被用户主动取消。
  canceled;

  String get label => switch (this) {
    DownloadStatus.pending => '等待中',
    DownloadStatus.running => '下载中',
    DownloadStatus.completed => '已完成',
    DownloadStatus.failed => '失败',
    DownloadStatus.canceled => '已取消',
  };

  static DownloadStatus fromName(String value) => DownloadStatus.values
      .firstWhere((e) => e.name == value, orElse: () => DownloadStatus.pending);
}

/// 视频条目。
///
/// 字段刻意做成"内容源无关"：任何 [VideoSource] 实现只要能填满这些字段，
/// 上层列表 / 搜索 / 播放 / 下载逻辑都不需要改动。
@immutable
class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    required this.author,
    required this.hlsUrl,
    this.detailUrl,
    this.thumbnailUrl,
    this.duration,
    this.durationStr,
    this.publishedAt,
    this.tags = const <String>[],
    this.views = 0,
    this.viewsStr,
    this.description,
  });

  /// 在所属数据源内唯一。
  final String id;

  final String title;

  /// 作者 / 频道名。下载时用于归档目录。
  final String author;

  /// HLS 播放列表地址（.m3u8）。
  final String hlsUrl;

  /// 详情页网页地址（当列表页未直接拿到 m3u8 时使用）。
  final String? detailUrl;

  final String? thumbnailUrl;
  final Duration? duration;

  /// 字符串格式时长（如 10:24），供卡片角标直观展示
  final String? durationStr;

  /// ISO-8601 日期字符串，例如 `2026-03-14`。允许为空。
  final String? publishedAt;

  final List<String> tags;
  final int views;

  /// 字符串格式播放次数（如 12.5万、8.9k）
  final String? viewsStr;

  final String? description;

  /// 供搜索与排序使用的合并文本。
  String get searchBlob =>
      '$title $author ${tags.join(' ')} ${description ?? ''}'.toLowerCase();

  /// 下载文件名主干：`日期_标题`（不含扩展名）。
  ///
  /// 沿用原 Kotlin 版 `VideoDownloadManager` 的命名规则，
  /// 只是把文件系统禁用字符的清洗逻辑收拢到这里统一处理。
  ///
  /// 扩展名由下载服务按实际容器决定（MPEG-TS -> `.ts`，fMP4 -> `.mp4`），
  /// 原实现无条件写 `.mp4`，对 TS 分片流而言扩展名是错的。
  String get downloadBaseName {
    final safeDate = (publishedAt == null || publishedAt!.isEmpty)
        ? 'unknown'
        : publishedAt!.replaceAll('/', '-');
    final safeTitle = sanitizeFileName(title);
    return '${safeDate}_$safeTitle';
  }

  /// 清洗 Windows / Android 文件系统的保留字符。
  static String sanitizeFileName(String raw) => raw
      .replaceAll(RegExp(r'[/:*?"<>|\\]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  VideoItem copyWith({
    String? id,
    String? title,
    String? author,
    String? hlsUrl,
    String? detailUrl,
    String? thumbnailUrl,
    Duration? duration,
    String? durationStr,
    String? publishedAt,
    List<String>? tags,
    int? views,
    String? viewsStr,
    String? description,
  }) {
    return VideoItem(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      hlsUrl: hlsUrl ?? this.hlsUrl,
      detailUrl: detailUrl ?? this.detailUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      durationStr: durationStr ?? this.durationStr,
      publishedAt: publishedAt ?? this.publishedAt,
      tags: tags ?? this.tags,
      views: views ?? this.views,
      viewsStr: viewsStr ?? this.viewsStr,
      description: description ?? this.description,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'author': author,
    'hlsUrl': hlsUrl,
    'detailUrl': detailUrl,
    'thumbnailUrl': thumbnailUrl,
    'durationMs': duration?.inMilliseconds,
    'durationStr': durationStr,
    'publishedAt': publishedAt,
    'tags': tags,
    'views': views,
    'viewsStr': viewsStr,
    'description': description,
  };

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    final ms = json['durationMs'] as int?;
    return VideoItem(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String? ?? 'unknown',
      hlsUrl: json['hlsUrl'] as String? ?? '',
      detailUrl: json['detailUrl'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      duration: ms == null ? null : Duration(milliseconds: ms),
      durationStr: json['durationStr'] as String?,
      publishedAt: json['publishedAt'] as String?,
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList(growable: false),
      views: json['views'] as int? ?? 0,
      viewsStr: json['viewsStr'] as String?,
      description: json['description'] as String?,
    );
  }
}

/// 一条下载任务。可变的——队列会持续更新其进度。
class DownloadTask {
  DownloadTask({
    required this.video,
    this.status = DownloadStatus.pending,
    this.progress = 0,
    this.totalSegments = 0,
    this.completedSegments = 0,
    this.outputPath,
    this.error,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final VideoItem video;

  DownloadStatus status;

  /// 0.0 ~ 1.0。
  double progress;

  int totalSegments;
  int completedSegments;

  /// 合并完成后 mp4 的绝对路径。
  String? outputPath;

  String? error;

  final DateTime createdAt;
  DateTime updatedAt;

  String get id => video.id;

  int get progressPercent => (progress * 100).round().clamp(0, 100);

  bool get isActive =>
      status == DownloadStatus.pending || status == DownloadStatus.running;

  void touch() => updatedAt = DateTime.now();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'video': video.toJson(),
    'status': status.name,
    'progress': progress,
    'totalSegments': totalSegments,
    'completedSegments': completedSegments,
    'outputPath': outputPath,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      video: VideoItem.fromJson(
        Map<String, dynamic>.from(json['video'] as Map<dynamic, dynamic>),
      ),
      status: DownloadStatus.fromName(json['status'] as String? ?? 'pending'),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      totalSegments: json['totalSegments'] as int? ?? 0,
      completedSegments: json['completedSegments'] as int? ?? 0,
      outputPath: json['outputPath'] as String?,
      error: json['error'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }
}
