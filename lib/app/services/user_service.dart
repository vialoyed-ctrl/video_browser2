/// 用户个人数据管理与持久化服务。
/// 包含：自建收藏夹管理、观看记录、稍后再看、关注UP主等。
library;

import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';

import '../core/app_logger.dart';
import '../data/models/video_item.dart';
import 'task_repository.dart';

/// 观看历史条目
class WatchHistoryItem {
  final VideoItem video;
  final int positionMs;
  final int durationMs;
  final DateTime watchedAt;

  const WatchHistoryItem({
    required this.video,
    this.positionMs = 0,
    this.durationMs = 0,
    required this.watchedAt,
  });

  double get progressPercent {
    if (durationMs <= 0) return 0.0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'positionMs': positionMs,
    'durationMs': durationMs,
    'watchedAt': watchedAt.toIso8601String(),
  };

  factory WatchHistoryItem.fromJson(Map<String, dynamic> json) {
    return WatchHistoryItem(
      video: VideoItem.fromJson(json['video'] as Map<String, dynamic>),
      positionMs: json['positionMs'] as int? ?? 0,
      durationMs: json['durationMs'] as int? ?? 0,
      watchedAt:
          DateTime.tryParse(json['watchedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class UserService extends GetxService {
  static UserService get to => Get.find<UserService>();

  static const String defaultFolderName = '默认收藏夹';

  /// 收藏夹映射：文件夹名称 -> 视频列表
  final RxMap<String, List<VideoItem>> favorites =
      <String, List<VideoItem>>{}.obs;

  /// 观看历史记录（最新在最前）
  final RxList<WatchHistoryItem> history = <WatchHistoryItem>[].obs;

  /// 稍后再看视频列表
  final RxList<VideoItem> watchLater = <VideoItem>[].obs;

  /// 关注/订阅的 UP 主集合
  final RxSet<String> subscriptions = <String>{}.obs;

  File? _storageFile;

  Future<UserService> init() async {
    try {
      final rootDir = await StoragePaths.root();
      _storageFile = File(
        '${rootDir.path}${Platform.pathSeparator}user_profile.json',
      );
      await _load();
    } catch (e, stack) {
      AppLogger.e('UserService', '初始化用户数据失败: $e', e, stack);
    }
    return this;
  }

  // ------------------------------------------------------------- 收藏夹管理
  /// 获取所有收藏视频的总数（去重计数或累加）
  int get totalFavoriteCount {
    final allIds = <String>{};
    for (final list in favorites.values) {
      for (final v in list) {
        allIds.add(v.id);
      }
    }
    return allIds.length;
  }

  /// 创建新收藏夹
  bool createFolder(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || favorites.containsKey(trimmed)) {
      return false;
    }
    favorites[trimmed] = <VideoItem>[];
    _save();
    return true;
  }

  /// 删除收藏夹（默认收藏夹不可删除）
  bool deleteFolder(String name) {
    if (name == defaultFolderName) return false;
    if (favorites.remove(name) != null) {
      _save();
      return true;
    }
    return false;
  }

  /// 检查某视频是否在特定收藏夹
  bool isVideoInFolder(String folderName, String videoId) {
    final list = favorites[folderName];
    if (list == null) return false;
    return list.any((v) => v.id == videoId);
  }

  /// 检查某视频是否在任意收藏夹
  bool isVideoInAnyFolder(String videoId) {
    for (final list in favorites.values) {
      if (list.any((v) => v.id == videoId)) return true;
    }
    return false;
  }

  /// 将视频添加到某个收藏夹
  void addVideoToFolder(String folderName, VideoItem video) {
    final list = favorites[folderName] ?? <VideoItem>[];
    if (!list.any((v) => v.id == video.id)) {
      final updated = List<VideoItem>.from(list)..insert(0, video);
      favorites[folderName] = updated;
      _save();
    }
  }

  /// 从某个收藏夹移除视频
  void removeVideoFromFolder(String folderName, String videoId) {
    final list = favorites[folderName];
    if (list == null) return;
    final updated = list.where((v) => v.id != videoId).toList();
    favorites[folderName] = updated;
    _save();
  }

  // ------------------------------------------------------------- 观看记录
  /// 记录/更新观看历史
  void recordHistory(
    VideoItem video, {
    int positionMs = 0,
    int durationMs = 0,
  }) {
    // 移除已有的相同视频
    history.removeWhere((h) => h.video.id == video.id);
    // 插入到最前面
    history.insert(
      0,
      WatchHistoryItem(
        video: video,
        positionMs: positionMs,
        durationMs: durationMs,
        watchedAt: DateTime.now(),
      ),
    );
    // 最多保留 200 条
    if (history.length > 200) {
      history.removeRange(200, history.length);
    }
    _save();
  }

  void removeHistory(String videoId) {
    history.removeWhere((h) => h.video.id == videoId);
    _save();
  }

  void clearHistory() {
    history.clear();
    _save();
  }

  // ------------------------------------------------------------- 稍后再看
  bool isInWatchLater(String videoId) {
    return watchLater.any((v) => v.id == videoId);
  }

  void toggleWatchLater(VideoItem video) {
    if (isInWatchLater(video.id)) {
      watchLater.removeWhere((v) => v.id == video.id);
    } else {
      watchLater.insert(0, video);
    }
    _save();
  }

  void removeFromWatchLater(String videoId) {
    watchLater.removeWhere((v) => v.id == videoId);
    _save();
  }

  void clearWatchLater() {
    watchLater.clear();
    _save();
  }

  // ------------------------------------------------- 域名变更后的 URL 重定位
  /// 把已保存条目里的旧域名 URL 重定位到当前选中的域名。
  ///
  /// 收藏夹 / 观看记录 / 稍后再看存的都是**保存当时**的绝对 URL（host = 当时的域名）。
  /// 用户换域名后旧 host 已失效，直接拿它去请求必然失败 ——
  /// 对外表现为「历史里的视频点开播不了」。所以域名一变就调用本方法统一改写。
  ///
  /// [rebase] 由数据源提供（`Site91Source.rebaseUrl`）：只重写属于本站的地址，
  /// CDN 的 m3u8 / mp4 / 封面图会原样返回，不会被误改。
  ///
  /// **只改 [VideoItem.detailUrl]，刻意不动 [VideoItem.id]**：id 同时是下载任务标识
  /// 与缓存目录键（见 DownloadService / HlsCacheProxy / PreloadService），
  /// 改掉会让进行中的下载任务与已有缓存全部失联。而播放器真正拿去请求、
  /// 以及当 Referer 用的都是 detailUrl —— 改它就够了。
  void rebaseVideoUrls(String Function(String url) rebase) {
    var changed = false;

    VideoItem fix(VideoItem v) {
      final d = v.detailUrl;
      if (d == null || d.isEmpty) return v;
      final next = rebase(d);
      if (next == d) return v;
      changed = true;
      return v.copyWith(detailUrl: next);
    }

    // 先把三个列表都算出来（fix 的副作用因此一定会执行到），再决定是否落盘。
    final favNext = <String, List<VideoItem>>{};
    favorites.forEach((name, list) {
      favNext[name] = list.map(fix).toList();
    });
    final histNext = history
        .map(
          (h) => WatchHistoryItem(
            video: fix(h.video),
            positionMs: h.positionMs,
            durationMs: h.durationMs,
            watchedAt: h.watchedAt,
          ),
        )
        .toList();
    final laterNext = watchLater.map(fix).toList();

    if (!changed) return;

    favorites.assignAll(favNext);
    history.assignAll(histNext);
    watchLater.assignAll(laterNext);
    _save();
    AppLogger.i('UserService', '已把收藏 / 观看记录 / 稍后再看里的旧域名 URL 重定位到当前域名');
  }

  // ------------------------------------------------------------- 我的订阅
  bool isSubscribed(String author) {
    final clean = author.trim();
    return clean.isNotEmpty && subscriptions.contains(clean);
  }

  void toggleSubscription(String author) {
    final clean = author.trim();
    if (clean.isEmpty) return;
    if (subscriptions.contains(clean)) {
      subscriptions.remove(clean);
    } else {
      subscriptions.add(clean);
    }
    _save();
  }

  // ------------------------------------------------------------- 持久化读写
  Future<void> _load() async {
    final file = _storageFile;
    if (file == null || !file.existsSync()) {
      // 默认提供一个默认收藏夹
      favorites[defaultFolderName] = <VideoItem>[];
      return;
    }

    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) {
        favorites[defaultFolderName] = <VideoItem>[];
        return;
      }

      final json = jsonDecode(text) as Map<String, dynamic>;

      // 1. 收藏夹
      final favJson = json['favorites'] as Map<String, dynamic>? ?? {};
      final map = <String, List<VideoItem>>{};
      favJson.forEach((k, v) {
        if (v is List) {
          map[k] = v
              .whereType<Map<String, dynamic>>()
              .map(VideoItem.fromJson)
              .toList();
        }
      });
      if (!map.containsKey(defaultFolderName)) {
        map[defaultFolderName] = <VideoItem>[];
      }
      favorites.assignAll(map);

      // 2. 观看历史
      final histJson = json['history'] as List<dynamic>? ?? [];
      final histList = histJson
          .whereType<Map<String, dynamic>>()
          .map(WatchHistoryItem.fromJson)
          .toList();
      history.assignAll(histList);

      // 3. 稍后再看
      final wlJson = json['watchLater'] as List<dynamic>? ?? [];
      final wlList = wlJson
          .whereType<Map<String, dynamic>>()
          .map(VideoItem.fromJson)
          .toList();
      watchLater.assignAll(wlList);

      // 4. 订阅作者
      final subJson = json['subscriptions'] as List<dynamic>? ?? [];
      subscriptions.assignAll(subJson.whereType<String>());
    } catch (e, stack) {
      AppLogger.e('UserService', '读取用户配置数据异常: $e', e, stack);
      favorites[defaultFolderName] = <VideoItem>[];
    }
  }

  Future<void> _save() async {
    final file = _storageFile;
    if (file == null) return;

    try {
      final favMap = <String, dynamic>{};
      favorites.forEach((k, v) {
        favMap[k] = v.map((item) => item.toJson()).toList();
      });

      final json = {
        'favorites': favMap,
        'history': history.map((h) => h.toJson()).toList(),
        'watchLater': watchLater.map((w) => w.toJson()).toList(),
        'subscriptions': subscriptions.toList(),
      };

      await file.writeAsString(jsonEncode(json), flush: true);
    } catch (e, stack) {
      AppLogger.e('UserService', '保存用户配置数据异常: $e', e, stack);
    }
  }
}
