/// 首页模块：频道与分类切换 + 九色热搜 + 分页加载去重。
library;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/models/video_item.dart';
import '../../data/sources/site91_source.dart';
import '../../data/sources/site91md_source.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_routes.dart';
import '../../services/preload_service.dart';
import '../search/search_controller.dart' as search_module;

class HomeController extends GetxController {
  HomeController(VideoSource initialSource) : _source = initialSource.obs;

  final Rx<VideoSource> _source;
  VideoSource get source => _source.value;

  static const int pageSize = 12;

  final RxList<VideoItem> videos = <VideoItem>[].obs;
  final RxBool loadingFirst = true.obs;
  final RxBool loadingMore = false.obs;
  final RxBool hasMore = true.obs;
  final RxnString error = RxnString();
  final RxnString loadMoreError = RxnString();
  final RxList<VideoCategory> site91mdCategories = <VideoCategory>[].obs;
  final RxBool loadingSite91mdCategories = false.obs;
  final RxnString site91mdCategoriesError = RxnString();
  int _navigationGeneration = 0;

  Future<void> loadSite91mdCategories({bool refresh = false}) async {
    final source = _source.value;
    final generation = ++_navigationGeneration;
    if (source is! Site91MdSource) return;
    loadingSite91mdCategories.value = true;
    site91mdCategoriesError.value = null;
    try {
      await source.fetchCategories(refresh: refresh);
      if (generation != _navigationGeneration ||
          !identical(source, _source.value)) {
        return;
      }
      site91mdCategories.assignAll(
        source.categoriesForChannel(ChannelType.video),
      );
    } catch (e) {
      if (generation == _navigationGeneration) {
        site91mdCategoriesError.value = '栏目加载失败：$e';
      }
    } finally {
      if (generation == _navigationGeneration) {
        loadingSite91mdCategories.value = false;
      }
    }
  }

  final ScrollController scroll = ScrollController();

  /// 当前选中的大频道（首页、视频、蝌蚪、精品）
  final Rx<ChannelType> currentChannel = ChannelType.home.obs;

  /// 当前选中的子分类 / 专区
  final Rxn<VideoCategory> currentCategory = Rxn<VideoCategory>();

  /// 首页热搜词列表与折叠状态
  final RxList<String> hotKeywords = <String>[].obs;
  final RxBool hotKeywordsExpanded = false.obs;
  final RxBool loadingKeywords = false.obs;

  /// 严格去重集合，确保下拉触底加载绝无重复视频
  final Set<String> _seenVideoIds = <String>{};

  int _page = 0;
  bool _inFlight = false;
  int _firstPageGeneration = 0;
  int _keywordGeneration = 0;

  String get sourceName => _source.value.displayName;

  /// 当前频道的子分类集合
  List<VideoCategory> get currentCategories =>
      _source.value.categoriesForChannel(currentChannel.value);

  String get currentTitle {
    if (_source.value.id == 'hanime1') {
      switch (currentChannel.value) {
        case ChannelType.home:
          return 'Hanime1 动漫';
        case ChannelType.video:
          return '番剧 · ${currentCategory.value?.name ?? "精选"}';
        case ChannelType.kedou:
          return '榜单 · ${currentCategory.value?.name ?? "排行"}';
        case ChannelType.vod:
          return '我的 · ${currentCategory.value?.name ?? "专区"}';
      }
    }
    if (_source.value.id == 'site91md') {
      return currentCategory.value?.name ?? _source.value.displayName;
    }
    switch (currentChannel.value) {
      case ChannelType.home:
        // 91麻豆 的首页标题用它自己的展示名，避免串成 91 的「九色」。
        return _source.value.id == 'site91md'
            ? _source.value.displayName
            : '91PORNY 九色';
      case ChannelType.video:
        return '视频 · ${currentCategory.value?.name ?? "精选"}';
      case ChannelType.kedou:
        return '蝌蚪 · ${currentCategory.value?.name ?? "精选"}';
      case ChannelType.vod:
        return '精品 · ${currentCategory.value?.name ?? "全部"}';
    }
  }

  VideoCategory? defaultCategoryFor(ChannelType channel) {
    final list = _source.value.categoriesForChannel(channel);
    if (channel == ChannelType.home) return null;
    return list.isNotEmpty ? list.first : null;
  }

  /// 动态切换数据源
  void switchSource(VideoSource newSource) {
    if (_source.value.id == newSource.id) return;
    _source.value = newSource;
    SourceRegistry.setActiveSource(newSource);
    Get.replace<VideoSource>(newSource);
    currentChannel.value = ChannelType.home;
    currentCategory.value = null;
    hotKeywords.clear();
    site91mdCategories.clear();
    loadSite91mdCategories();
    loadFirstPage(supersede: true);
    loadHotKeywords();
  }

  @override
  void onInit() {
    super.onInit();
    scroll.addListener(_onScroll);
    loadSite91mdCategories();
    loadFirstPage();
    loadHotKeywords();
  }

  @override
  void onClose() {
    _navigationGeneration++;
    _firstPageGeneration++;
    _keywordGeneration++;
    scroll.dispose();
    super.onClose();
  }

  /// 切换大频道（可传入具体分类，若未传则使用默认分类）
  void switchChannel(ChannelType channel, [VideoCategory? category]) {
    currentChannel.value = channel;
    currentCategory.value = category ?? defaultCategoryFor(channel);
    loadFirstPage(supersede: true);
  }

  /// 切换当前频道内的分类
  void selectCategory(VideoCategory category) {
    if (currentCategory.value?.id == category.id) return;
    currentCategory.value = category;
    loadFirstPage(supersede: true);
  }

  /// 加载首屏数据（清空历史去重记录）
  Future<void> loadFirstPage({bool supersede = false}) async {
    if (_inFlight && !supersede) return;
    final generation = ++_firstPageGeneration;
    final source = _source.value;
    final channel = currentChannel.value;
    final categoryPath = currentCategory.value?.path;
    _inFlight = true;
    loadingMore.value = false;
    loadingFirst.value = true;
    error.value = null;
    loadMoreError.value = null;
    _seenVideoIds.clear();

    try {
      final result = await source.fetchChannelPage(
        channel: channel,
        categoryPath: categoryPath,
        page: 1,
        pageSize: pageSize,
      );

      if (generation != _firstPageGeneration) return;
      _seenVideoIds.clear();
      final newItems = result.items
          .where((v) => _seenVideoIds.add(v.id))
          .toList();
      videos.assignAll(newItems);
      PreloadService.instance.preloadList(newItems, isNewPage: true);
      _page = 1;
      hasMore.value = result.hasMore;

      if (scroll.hasClients) {
        scroll.jumpTo(0);
      }
    } catch (e) {
      if (generation == _firstPageGeneration) error.value = '内容加载失败：$e';
    } finally {
      if (generation == _firstPageGeneration) {
        loadingFirst.value = false;
        _inFlight = false;
      }
    }
  }

  /// 触底加载下一页（全量过滤重复条目，若全重叠则自动翻下一页）
  Future<void> loadMore() async {
    if (_inFlight || !hasMore.value || loadingFirst.value) return;
    _inFlight = true;
    final generation = _firstPageGeneration;
    final source = _source.value;
    final channel = currentChannel.value;
    final categoryPath = currentCategory.value?.path;
    loadingMore.value = true;
    loadMoreError.value = null;

    try {
      int targetPage = _page + 1;
      final result = await source.fetchChannelPage(
        channel: channel,
        categoryPath: categoryPath,
        page: targetPage,
        pageSize: pageSize,
      );

      if (generation != _firstPageGeneration) return;
      final newItems = result.items
          .where((v) => _seenVideoIds.add(v.id))
          .toList();
      if (newItems.isNotEmpty) {
        videos.addAll(newItems);
        _page = targetPage;
        hasMore.value = result.hasMore;
        PreloadService.instance.preloadList(newItems, isNewPage: false);
      } else {
        // 如果拉到了条目但全部已存在于界面中（如官网分类交集），尝试再探一页
        if (result.hasMore && targetPage < 50) {
          _page = targetPage;
          _inFlight = false;
          loadingMore.value = false;
          await loadMore();
          return;
        } else {
          hasMore.value = false;
        }
      }
    } catch (e) {
      if (generation == _firstPageGeneration) {
        if (source is Site91MdSource) {
          loadMoreError.value = '下一页加载失败，请重试';
        } else {
          hasMore.value = false;
        }
      }
    } finally {
      if (generation == _firstPageGeneration) {
        loadingMore.value = false;
        _inFlight = false;
      }
    }
  }

  /// 加载首页热搜词
  Future<void> loadHotKeywords() async {
    final generation = ++_keywordGeneration;
    final source = _source.value;
    loadingKeywords.value = true;
    try {
      final kws = await source.fetchHotKeywords();
      if (generation != _keywordGeneration) return;
      hotKeywords.assignAll(kws);
    } catch (_) {
      if (generation != _keywordGeneration) return;
      // 降级使用内置
      hotKeywords.assignAll(Site91Source.defaultHotKeywords);
    } finally {
      if (generation == _keywordGeneration) loadingKeywords.value = false;
    }
  }

  void toggleHotKeywordsExpand() {
    hotKeywordsExpanded.value = !hotKeywordsExpanded.value;
  }

  /// 点击热搜词直达搜索
  void searchKeyword(String kw) {
    final cleanKw = kw.trim();
    if (cleanKw.isEmpty) return;

    if (Get.isRegistered<search_module.SearchController>()) {
      final sCtrl = Get.find<search_module.SearchController>();
      sCtrl.searchWithKeyword(cleanKw);
    }

    Get.toNamed<dynamic>(AppRoutes.search, arguments: cleanKw);
  }

  void _onScroll() {
    if (!scroll.hasClients) return;
    final position = scroll.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      if (loadMoreError.value == null) loadMore();
    }
  }
}
