/// 搜索模块：对齐 91PORNY 官网多维检索、用户聚合与结果分页。
///
/// 检索完全按照官网接口与规范执行：
/// 1. 单一输入框支持关键词检索，同时匹配用户与视频；
/// 2. 官网 5 大筛选维度（排序、选择分类[除论坛]、发布时间、播放量、视频长度）；
/// 3. 搜索到用户直达作者作品与关注；
/// 4. 动态分类视频标题与官网页码翻页控制器。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../core/app_logger.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/video_source.dart';
import '../../services/preload_service.dart';

class SearchController extends GetxController {
  SearchController([VideoSource? source]) : _injectedSource = source;

  final VideoSource? _injectedSource;
  VideoSource get _source =>
      _injectedSource ??
      (Get.isRegistered<VideoSource>()
          ? Get.find<VideoSource>()
          : SourceRegistry.defaultSource);

  static const int pageSize = 24;
  static const Duration _debounceDelay = Duration(milliseconds: 400);
  static const Duration _site91DebounceDelay = Duration(milliseconds: 100);

  final TextEditingController input = TextEditingController();
  final FocusNode focusNode = FocusNode();
  final ScrollController scroll = ScrollController();

  final RxString keyword = ''.obs;
  final Rx<SearchType> searchType = SearchType.videoName.obs;

  // 官网 5 大筛选维度
  final RxString sortFilter = ''.obs;
  final RxString category = ''.obs;
  final RxString time = ''.obs;
  final RxString dateYear = ''.obs;
  final RxString dateMonth = ''.obs;
  final RxString viewsFilter = ''.obs;
  final RxString durationFilter = ''.obs;

  // 搜索到的用户列表与当前选中的专栏作者
  final RxList<SearchedUser> searchedUsers = <SearchedUser>[].obs;
  final Rxn<SearchedUser> selectedAuthor = Rxn<SearchedUser>();

  final RxnString summaryText = RxnString();
  final RxBool showFilters = true.obs;

  // 分页状态（对齐官网标准页码）
  final RxInt currentPage = 1.obs;
  final RxInt totalPages = 1.obs;
  final RxInt totalItems = 0.obs;
  final RxBool pageLoading = false.obs;
  final TextEditingController jumpPageInput = TextEditingController();

  final RxList<VideoItem> results = <VideoItem>[].obs;
  final RxBool loading = false.obs;
  final RxBool hasMore = true.obs;
  final RxnString error = RxnString();

  /// 热门搜索词推荐
  final RxList<String> hotKeywords = <String>[].obs;

  /// 是否已执行过检索
  final RxBool hasSearched = false.obs;

  Timer? _debounce;
  bool _inFlight = false;
  bool _pendingSearch = false;
  int _searchRequestId = 0;

  // 选项常量（严格按照官网，分类排除论坛）
  static const List<(String, String)> sortOptions = [
    ('默认', ''),
    ('最新', 'new'),
    ('最热', 'hot'),
  ];

  static const List<(String, String)> categoryOptions = [
    ('全部', ''),
    ('91视频', '91'),
    ('蝌蚪', 'kedou'),
    ('精品', 'vod'),
  ];

  static const List<(String, String)> timeOptions = [
    ('全部', ''),
    ('1星期内', 'week1'),
    ('2星期内', 'week2'),
    ('1个月内', 'month1'),
    ('3个月内', 'month3'),
    ('半年内', 'halfyear'),
    ('1年内', 'year1'),
  ];

  static const List<(String, String)> viewsOptions = [
    ('全部', ''),
    ('>1000', '1000'),
    ('>5000', '5000'),
    ('>1万', '10000'),
    ('>5万', '50000'),
    ('>10万', '100000'),
  ];

  static const List<(String, String)> durationOptions = [
    ('全部', ''),
    ('>5分钟', '5'),
    ('>10分钟', '10'),
    ('>30分钟', '30'),
    ('>60分钟', '60'),
  ];

  // ==================================================================
  // Hanime1 专属筛选选项
  //
  // 全部取自官网 /search 页 `<div class="simple-dropdown-item ..."
  // data-value="X">` 的 data-value 原值 —— 提交时是隐藏 input
  // （input[name=sort|genre|date|duration]）的值，所以 value 必须与官网逐字一致，
  // 不能翻译成简体或改写措辞，否则站点收不到筛选条件。
  // ==================================================================

  /// 排序方式（官网 input[name=sort]）
  static const List<(String, String)> hanime1SortOptions = [
    ('最新上市', '最新上市'),
    ('最新上傳', '最新上傳'),
    ('本日排行', '本日排行'),
    ('本週排行', '本週排行'),
    ('本月排行', '本月排行'),
    ('觀看次數', '觀看次數'),
    ('讚好比例', '讚好比例'),
    ('時長最長', '時長最長'),
    ('他們在看', '他們在看'),
  ];

  /// 全部類型（官网 input[name=genre]）
  static const List<(String, String)> hanime1GenreOptions = [
    ('全部', ''),
    ('裏番', '裏番'),
    ('泡麵番', '泡麵番'),
    ('Motion Anime', 'Motion Anime'),
    ('3DCG', '3DCG'),
    ('2.5D', '2.5D'),
    ('2D動畫', '2D動畫'),
    ('AI生成', 'AI生成'),
    ('MMD', 'MMD'),
    ('Cosplay', 'Cosplay'),
    ('新番預告', '新番預告'),
    ('H漫畫', 'H漫畫'),
  ];

  /// 發佈日期（官网 input[name=date]）
  static const List<(String, String)> hanime1DateOptions = [
    ('全部', ''),
    ('過去 24 小時', '過去 24 小時'),
    ('過去 2 天', '過去 2 天'),
    ('過去 1 週', '過去 1 週'),
    ('過去 1 個月', '過去 1 個月'),
    ('過去 3 個月', '過去 3 個月'),
    ('過去 1 年', '過去 1 年'),
  ];

  /// 時長（官网 input[name=duration]）
  static const List<(String, String)> hanime1DurationOptions = [
    ('全部', ''),
    ('1 分鐘 +', '1 分鐘 +'),
    ('5 分鐘 +', '5 分鐘 +'),
    ('10 分鐘 +', '10 分鐘 +'),
    ('20 分鐘 +', '20 分鐘 +'),
    ('30 分鐘 +', '30 分鐘 +'),
    ('60 分鐘 +', '60 分鐘 +'),
    ('0 - 10 分鐘', '0 - 10 分鐘'),
    ('0 - 20 分鐘', '0 - 20 分鐘'),
  ];

  /// 標籤（官网是 240 项 checkbox 多选，走 `tags[]=` 参数）。
  ///
  /// 240 项分 7 组，逐字取自官网弹窗的 `input[name="tags[]"][value=X]`，
  /// 见 [hanime1TagGroups]。这里不再列成常量选项 —— 直接由弹窗消费分组数据。
  ///
  /// 多选值（写入 SearchQuery.tags，每项单独提交一次 `tags[]=`）。
  final RxList<String> tagFilter = <String>[].obs;

  /// 「廣泛配對」开关（官网 `input#broad`）。
  ///
  /// `false`（默认）= 必须同时包含全部所选标签（AND）；
  /// `true` = 命中任意一个即可（OR）。官网文案：
  /// 关闭时「搜索包含所有以下選擇的標籤的影片」，打开时「…任何一個…」。
  final RxBool tagBroad = false.obs;

  bool isTagSelected(String tag) => tagFilter.contains(tag);

  /// 勾选/取消单个标签。不立即检索 —— 240 项要连续勾好几个，
  /// 每勾一下都发请求既慢又容易被站点限流；由弹窗的「套用」按钮统一提交。
  void toggleTag(String tag) {
    if (tagFilter.contains(tag)) {
      tagFilter.remove(tag);
    } else {
      tagFilter.add(tag);
    }
  }

  void clearTagFilter() => tagFilter.clear();

  void setTagBroad(bool value) => tagBroad.value = value;

  /// 弹窗「套用」：应用标签条件并重新检索。
  void applyTagFilter() {
    selectedAuthor.value = null;
    runSearch();
  }

  /// 当前内容源是否为 Hanime1（决定用哪套筛选维度）。
  bool get isHanime1 => _source.id == 'hanime1';
  bool get isSite91Md => _source.id == 'site91md';

  bool get isSite91 => _source.id == 'site91';

  List<(String, String)> get activeSortOptions =>
      isHanime1 ? hanime1SortOptions : sortOptions;
  List<(String, String)> get activeCategoryOptions =>
      isHanime1 ? hanime1GenreOptions : categoryOptions;
  List<(String, String)> get activeTimeOptions =>
      isHanime1 ? hanime1DateOptions : timeOptions;
  List<(String, String)> get activeDurationOptions =>
      isHanime1 ? hanime1DurationOptions : durationOptions;

  /// 搜索页是否有任何生效条件
  bool get hasAnyCondition =>
      keyword.value.trim().isNotEmpty ||
      (isHanime1 && searchType.value == SearchType.authorId) ||
      selectedAuthor.value != null ||
      sortFilter.value.isNotEmpty ||
      category.value.isNotEmpty ||
      time.value.isNotEmpty ||
      dateYear.value.isNotEmpty ||
      dateMonth.value.isNotEmpty ||
      viewsFilter.value.isNotEmpty ||
      durationFilter.value.isNotEmpty ||
      tagFilter.isNotEmpty;

  /// 当前选中的分类中文名称
  String get currentCategoryLabel {
    for (final opt in categoryOptions) {
      if (opt.$2 == category.value) {
        return opt.$1 == '全部' ? '' : opt.$1;
      }
    }
    return '';
  }

  @override
  void onInit() {
    super.onInit();
    _loadHotKeywords();
    final args = Get.arguments;
    if (args is String && args.trim().isNotEmpty) {
      final kw = args.trim();
      keyword.value = kw;
      input.text = kw;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isClosed) runSearch();
      });
    }
  }

  void searchWithKeyword(String kw) {
    final cleanKw = kw.trim();
    if (isClosed || cleanKw.isEmpty) return;
    selectedAuthor.value = null;
    input.text = cleanKw;
    keyword.value = cleanKw;
    runSearch();
  }

  @override
  void onClose() {
    _searchRequestId++;
    _debounce?.cancel();
    input.dispose();
    jumpPageInput.dispose();
    focusNode.dispose();
    scroll.dispose();
    super.onClose();
  }

  Future<void> _loadHotKeywords() async {
    try {
      final hot = await _source.fetchHotKeywords();
      if (!isClosed) hotKeywords.assignAll(hot);
    } catch (e) {
      // 热词是**可选增强**：失败时保持空列表即可，不影响搜索主流程。
      // 但静默会让「搜索页没有热词」无从判断是站点变更还是网络问题，故留一条 W。
      AppLogger.w('Search', '热词加载失败，搜索页热词区保持为空: $e');
    }
  }

  /// Search pages created outside a GetX route binding still need the site's
  /// suggested searches. The caller owns and disposes this controller.
  void loadHotSearches() => _loadHotKeywords();

  // ---------------------------------------------------------------- 条件变更

  void onKeywordChanged(String value) {
    keyword.value = value;
    if (!isHanime1 || searchType.value != SearchType.authorId) {
      searchType.value = SearchType.videoName;
    }
    if (selectedAuthor.value != null) {
      selectedAuthor.value = null;
    }
    _debounce?.cancel();
    _debounce = Timer(
      isSite91 ? _site91DebounceDelay : _debounceDelay,
      () => runSearch(allowEmptyHanime1: isHanime1),
    );
  }

  void setSortFilter(String val) {
    if (sortFilter.value == val) return;
    sortFilter.value = val;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  void setCategory(String val) {
    if (category.value == val) return;
    category.value = val;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  void setTime(String val) {
    if (time.value == val) return;
    time.value = val;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  void setViewsFilter(String val) {
    if (viewsFilter.value == val) return;
    viewsFilter.value = val;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  void setDurationFilter(String val) {
    if (durationFilter.value == val) return;
    durationFilter.value = val;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  /// Hanime1 search sheet commits all selected dimensions with one request.
  void applyHanime1Filters({
    String? sort,
    String? genre,
    String? date,
    String? year,
    String? month,
    String? duration,
  }) {
    if (sort != null) sortFilter.value = sort;
    if (genre != null) category.value = genre;
    if (year != null) dateYear.value = year;
    if (month != null) dateMonth.value = month;
    if (date != null) {
      final selectedYear = dateYear.value;
      final selectedMonth = dateMonth.value;
      time.value = selectedYear.isNotEmpty || selectedMonth.isNotEmpty
          ? '$selectedYear $selectedMonth'
          : date;
    }
    if (duration != null) durationFilter.value = duration;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: true);
  }

  void applyTagSelection(List<String> tags, bool broad) {
    tagFilter.assignAll(tags);
    tagBroad.value = broad;
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: true);
  }

  void toggleShowFilters() {
    showFilters.value = !showFilters.value;
  }

  /// 点击选择搜索到的用户：进入其专属作品专栏
  void selectAuthor(SearchedUser user) {
    selectedAuthor.value = user;
    currentPage.value = 1;
    runSearch();
  }

  /// 退出作者专栏，返回关键词搜索结果
  void clearSelectedAuthor() {
    selectedAuthor.value = null;
    currentPage.value = 1;
    runSearch();
  }

  void clearKeyword() {
    input.clear();
    keyword.value = '';
    selectedAuthor.value = null;
    searchedUsers.clear();
    summaryText.value = null;
    currentPage.value = 1;
    totalPages.value = 1;
    totalItems.value = 0;
    jumpPageInput.clear();
    runSearch(allowEmptyHanime1: isHanime1);
  }

  void resetAll() {
    _debounce?.cancel();
    input.clear();
    keyword.value = '';
    searchType.value = SearchType.videoName;
    selectedAuthor.value = null;
    sortFilter.value = '';
    category.value = '';
    time.value = '';
    dateYear.value = '';
    dateMonth.value = '';
    viewsFilter.value = '';
    durationFilter.value = '';
    tagFilter.clear();
    tagBroad.value = false;
    searchedUsers.clear();
    summaryText.value = null;
    results.clear();
    hasSearched.value = false;
    error.value = null;
    hasMore.value = true;
    currentPage.value = 1;
    totalPages.value = 1;
    totalItems.value = 0;
    jumpPageInput.clear();
    if (isHanime1) runSearch(allowEmptyHanime1: true);
  }

  /// 官网的“搜索作者 / 搜索影片”切换到制作方目录或视频列表。
  void toggleHanime1ArtistDirectory() {
    if (!isHanime1) return;
    searchType.value = searchType.value == SearchType.authorId
        ? SearchType.videoName
        : SearchType.authorId;
    selectedAuthor.value = null;
    currentPage.value = 1;
    runSearch(allowEmptyHanime1: true);
  }

  /// 选择制作方卡片后，官网会按名称打开普通视频搜索。
  void searchVideosForArtist(String name) {
    _debounce?.cancel();
    searchType.value = SearchType.videoName;
    input.text = name;
    keyword.value = name;
    selectedAuthor.value = null;
    sortFilter.value = '';
    category.value = '';
    time.value = '';
    dateYear.value = '';
    dateMonth.value = '';
    viewsFilter.value = '';
    durationFilter.value = '';
    tagFilter.clear();
    tagBroad.value = false;
    currentPage.value = 1;
    runSearch(allowEmptyHanime1: true);
  }

  /// 立即提交（回车 / 点击搜索）
  void submit() {
    _debounce?.cancel();
    selectedAuthor.value = null;
    runSearch(allowEmptyHanime1: isHanime1);
  }

  // ---------------------------------------------------------------- 检索执行

  SearchQuery get _query {
    if (selectedAuthor.value != null) {
      final a = selectedAuthor.value!;
      final targetName = a.authorId.isNotEmpty ? a.authorId : a.name;
      return SearchQuery(
        keyword: targetName,
        searchType: SearchType.authorId,
        author: targetName,
      );
    }
    return SearchQuery(
      keyword: keyword.value,
      searchType: searchType.value,
      author: searchType.value == SearchType.authorId ? keyword.value : null,
      sortParam: sortFilter.value,
      category: category.value,
      time: time.value,
      views: viewsFilter.value,
      duration: durationFilter.value,
      // Hanime1 用 tags[] 做标签筛选（可多选，其余源暂无此维度）。
      tags: List<String>.unmodifiable(tagFilter),
      tagBroad: tagBroad.value,
    );
  }

  Future<void> runSearch({bool allowEmptyHanime1 = false}) async {
    if (isClosed) return;
    // A slow 91 request must not hold the next keyword/filter behind it. 91
    // queries are URL-keyed and coalesced by Site91Source; request ids below
    // already prevent an older response from replacing the latest results.
    if (_inFlight && !isHanime1 && !isSite91) {
      _pendingSearch = true;
      return;
    }
    // A newly selected filter must not wait for the previous page's timeout.
    // Only the latest request may update the visible results.
    final currentRequestId = ++_searchRequestId;
    pageLoading.value = false;

    if (!hasAnyCondition && !(isHanime1 && allowEmptyHanime1)) {
      results.clear();
      searchedUsers.clear();
      summaryText.value = null;
      hasSearched.value = false;
      error.value = null;
      hasMore.value = true;
      currentPage.value = 1;
      totalPages.value = 1;
      totalItems.value = 0;
      jumpPageInput.clear();
      _inFlight = false;
      loading.value = false;
      return;
    }

    _inFlight = true;
    loading.value = true;
    error.value = null;
    hasSearched.value = true;

    try {
      final result = await _source.search(
        query: _query,
        page: 1,
        pageSize: pageSize,
      );
      if (currentRequestId != _searchRequestId) return;
      results.assignAll(result.items);
      _preloadResults(result.items);
      // 如果当前是作者模式，不覆盖搜到的作者列表
      if (selectedAuthor.value == null) {
        searchedUsers.assignAll(result.users);
      }
      summaryText.value = result.summary;
      currentPage.value = 1;
      totalPages.value = result.totalPages > 0 ? result.totalPages : 1;
      totalItems.value = result.totalItems;
      jumpPageInput.text = '1';
      hasMore.value = result.hasMore;
      if (scroll.hasClients) {
        scroll.jumpTo(0);
      }
    } catch (e) {
      if (currentRequestId != _searchRequestId) return;
      // 区分「站点限流」与「网络故障」：前者等一会儿重试即可恢复，后者要查网络。
      // 数据源在质询未解除时会抛出带此标识的 DioException，不再静默返回空列表。
      final isChallenge =
          e is DioException &&
          e.error is String &&
          (e.error! as String).contains('访问验证');
      error.value = isChallenge
          ? '站点触发了访问验证（请求过于频繁），请稍等片刻后重试'
          : '检索网络请求失败，请检查网络或点击重试';
      results.clear();
      if (selectedAuthor.value == null) {
        searchedUsers.clear();
      }
      summaryText.value = null;
      hasMore.value = false;
    } finally {
      if (currentRequestId == _searchRequestId) {
        loading.value = false;
        _inFlight = false;
        if (_pendingSearch) {
          _pendingSearch = false;
          runSearch(allowEmptyHanime1: isHanime1);
        }
      }
    }
  }

  /// 把一页搜索结果交给预加载服务 —— **hanime1 除外**。
  ///
  /// hanime1 一页就是官网服务端给的 **59 条**（它的 `search()` 忽略 `pageSize`，
  /// 只用 `?page=N`），而 `preloadCount` 的默认值是 -1（= 全页全部），于是每搜
  /// 一次、每翻一页都会把这 59 个视频全部排进预加载队列，逐个嗅探 m3u8 并下载
  /// 首分片 —— 这正是「分页加载量过大」的来源。
  ///
  /// hanime1 只保留播放时的极速加载（`HlsCacheProxy`，在播放页 `_open` 里独立
  /// 触发），所以这里跳过不影响起播体验。
  void _preloadResults(List<VideoItem> items) {
    if (items.isEmpty) return;
    if (isHanime1) {
      PreloadService.instance.preResolveStreamUrls(items.take(4).toList());
      return;
    }
    PreloadService.instance.preloadList(items, isNewPage: true);
  }

  /// 跳转至指定页码（对齐官网点击页码或跳页）
  Future<void> goToPage(int page) async {
    if (isClosed || _inFlight) return;
    if (page < 1) return;
    if (totalPages.value > 0 && page > totalPages.value) return;
    if (page == currentPage.value && results.isNotEmpty) return;

    _inFlight = true;
    final currentRequestId = ++_searchRequestId;
    pageLoading.value = true;
    error.value = null;

    try {
      final result = await _source.search(
        query: _query,
        page: page,
        pageSize: pageSize,
      );
      if (currentRequestId != _searchRequestId) return;
      if (isSite91Md && page == currentPage.value + 1) {
        final existing = results.map((item) => item.id).toSet();
        results.addAll(result.items.where((item) => existing.add(item.id)));
      } else {
        results.assignAll(result.items);
      }
      _preloadResults(result.items);
      if (selectedAuthor.value == null && result.users.isNotEmpty) {
        searchedUsers.assignAll(result.users);
      }
      if (result.summary != null && result.summary!.isNotEmpty) {
        summaryText.value = result.summary;
      }
      currentPage.value = page;
      if (result.totalPages > 0) {
        totalPages.value = result.totalPages;
      }
      if (result.totalItems > 0) {
        totalItems.value = result.totalItems;
      }
      jumpPageInput.text = '$page';
      hasMore.value = page < totalPages.value;

      if (!isSite91Md && scroll.hasClients) {
        scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (currentRequestId != _searchRequestId) return;
      error.value = '加载第 $page 页失败：$e';
    } finally {
      if (currentRequestId == _searchRequestId) {
        pageLoading.value = false;
        _inFlight = false;
      }
    }
  }

  void nextPage() {
    if (currentPage.value < totalPages.value) {
      goToPage(currentPage.value + 1);
    }
  }

  void prevPage() {
    if (currentPage.value > 1) {
      goToPage(currentPage.value - 1);
    }
  }

  void jumpToPage([String? target]) {
    final t = target ?? jumpPageInput.text.trim();
    final p = int.tryParse(t);
    if (p != null) {
      goToPage(p);
    }
  }
}
