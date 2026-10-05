import 'package:get/get.dart';

import '../core/app_logger.dart';
import '../data/models/video_item.dart';
import '../data/sources/video_source.dart';
import '../modules/player/player_view.dart';
import '../modules/hanime1/views/hanime1_playlist_view.dart';
import '../modules/search/search_controller.dart' as app_search;
import '../modules/search/search_view.dart';
import '../modules/search/site91md_search_view.dart';
import '../services/player_service.dart';
import 'app_routes.dart';

/// 全局统一安全路由导航器
/// 彻底解决 GetX 命名路由在同名压栈时的单例污染、arguments 覆盖与回跳原视频 Bug。
abstract class AppNavigator {
  /// 打开官网用户播放清单详情页。
  static Future<T?>? toHanime1Playlist<T>(String playlistId) {
    if (playlistId.trim().isEmpty) return null;
    return Get.to<T>(
      () => Hanime1PlaylistView(playlistId: playlistId),
      preventDuplicates: false,
      transition: Transition.fadeIn,
      duration: const Duration(milliseconds: 180),
    );
  }

  /// 打开视频播放页：使用显式组件传参构造，完全独立于 GetX 的全局静态 arguments，支持无限多层安全压栈
  static Future<T?>? toPlayer<T>(VideoItem video) {
    AppLogger.i(
      'Navigator',
      '🚀 toPlayer 压栈导航: ${video.title} (id: ${video.id})',
    );
    PlayerService.instance.preOpen(video);
    return Get.to<T>(
      () => PlayerView(videoItem: video),
      preventDuplicates: false,
      transition: Transition.fadeIn,
      duration: const Duration(milliseconds: 180),
    );
  }

  /// 打开作者专栏作品列表：自动创建独立的 SearchController 实例，避免多层压栈时污染全局搜索状态
  static Future<T?>? toAuthor<T>(String author) {
    AppLogger.i('Navigator', '👤 toAuthor (直接搜索该 UP 主 ID) 压栈导航: $author');
    final controller = app_search.SearchController(Get.find<VideoSource>());
    controller.input.text = author;
    controller.searchType.value = SearchType.videoName;
    controller.keyword.value = author;
    controller.selectedAuthor.value = null;
    controller.currentPage.value = 1;
    controller.runSearch();

    return Get.to<T>(
      () => SearchView(searchController: controller),
      preventDuplicates: false,
      transition: Transition.fadeIn,
      duration: const Duration(milliseconds: 180),
    );
  }

  /// 打开搜索页（可传入预填关键词或 Hanime1 分类）
  static Future<T?>? toSearch<T>({String? keyword, String? category}) {
    final source = SourceRegistry.defaultSource;
    if (source.id == 'site91md') {
      return Get.to<T>(
        () => Site91MdSearchView(source: source, initialKeyword: keyword ?? ''),
        preventDuplicates: false,
      );
    }
    // Hanime1 与 91 共用搜索页面，但必须每次绑定当前数据源。
    // 默认命名路由中的 lazy SearchController 可能已在 91 模式下创建，
    // 切换版面后继续复用会让 Hanime1 的搜索仍发往 91。
    if (source.id == 'hanime1' ||
        (keyword != null && keyword.isNotEmpty) ||
        (category != null && category.isNotEmpty)) {
      final controller = app_search.SearchController(source);
      controller.input.text = keyword ?? '';
      controller.searchType.value = SearchType.videoName;
      controller.keyword.value = keyword ?? '';
      controller.category.value = category ?? '';
      controller.selectedAuthor.value = null;
      controller.currentPage.value = 1;
      controller.runSearch();

      return Get.to<T>(
        () => SearchView(searchController: controller),
        preventDuplicates: false,
        transition: Transition.fadeIn,
        duration: const Duration(milliseconds: 180),
      );
    }

    return Get.toNamed<T>(AppRoutes.search);
  }
}
