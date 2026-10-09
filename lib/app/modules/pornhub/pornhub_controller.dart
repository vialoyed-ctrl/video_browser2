/// PornHub 独立业务控制器。
///
/// 四个版面 Tab 与官网路径一一对应（均由实测确认）：
///
/// | Tab | 路径 |
/// |---|---|
/// | 推荐 | `/recommended?o=time` |
/// | 最热 | `/video?o=ht` |
/// | 订阅 | `/subscriptions` |
/// | 收藏 | `/users/<name>/videos/favorites` |
///
/// 推荐与最热都是「按路径取视频列表」，因此共用一套 [_PornHubListState]，
/// 以路径为键分别缓存与分页 —— 两者互不影响翻页位置。
library;

import 'dart:async';

import 'package:get/get.dart';

import '../../core/app_logger.dart';
import '../../data/models/pornhub_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/pornhub_source.dart';
import '../../data/sources/video_source.dart';
import '../../services/pornhub_auth_service.dart';
import '../../services/preload_service.dart';
import '../player/player_controller.dart';

class PornHubController extends GetxController {
  static PornHubController get to => Get.find<PornHubController>();

  PornHubController(this._source);

  final PornHubSource _source;

  PornHubSource get source => _source;

  /// 当前底部导航选中索引（0 推荐 / 1 最热 / 2 订阅 / 3 收藏）。
  final RxInt currentTabIndex = 0.obs;

  /// 官网排序参数（实测自页面真实链接）。
  static const List<VideoCategory> sortCategories = <VideoCategory>[
    VideoCategory(id: 'o=tr', name: '最高分', path: '/video?o=tr'),
    VideoCategory(id: 'o=mv', name: '最多观看', path: '/video?o=mv'),
    VideoCategory(id: 'o=cm', name: '最新', path: '/video?o=cm'),
    VideoCategory(id: 'o=ht', name: '最热', path: '/video?o=ht'),
  ];

  static String get recommendedPath => '/recommended?o=time';
  static String get hotPath => '/video?o=ht';

  void switchTab(int index) {
    currentTabIndex.value = index;
    if (index == 2) {
      unawaited(loadSubscriptions());
    } else if (index == 3) {
      unawaited(loadFavorites());
    }
  }

  Worker? _accountWorker;
  int _accountEpoch = 0;
  String _accountIdentity = '';

  @override
  void onInit() {
    super.onInit();
    if (!Get.isRegistered<PornHubAuthService>()) return;
    String identity() =>
        '${auth.sessionRevision.value}:${auth.isLoggedIn.value}:${auth.userName}';
    _accountIdentity = identity();
    _accountWorker = everAll(
      [auth.sessionRevision, auth.username, auth.isLoggedIn],
      (_) {
        final next = identity();
        if (next == _accountIdentity) return;
        _accountIdentity = next;
        _resetAccountData();
      },
    );
  }

  void _resetAccountData() {
    _accountEpoch++;
    _source.clearAccountCaches();
    _creatorSelectionTimer?.cancel();
    _searchRequest++;
    _subscriptionsRequest++;
    _feedRequest++;
    _favoritesRequest++;
    _historyRequest++;
    _myPlaylistsRequest++;
    _publicPlaylistsRequest++;
    _playlistVideosRequest++;
    _clipsRequest++;
    _subscriptionsTask = null;
    _feedTask = null;
    _creatorCountTasks.clear();
    _countingCreators = false;
    _creatorNextPage.clear();
    _feedPool.clear();
    _feedSeen.clear();
    _clipPool.clear();
    _clipSeen.clear();
    favorites.clear();
    subscriptions.clear();
    feedVideos.clear();
    clipVideos.clear();
    history.clear();
    myPlaylists.clear();
    publicPlaylists.clear();
    playlistVideos.clear();
    searchResults.clear();
    creatorCounts.clear();
    clipCounts.clear();
    historyTotal.value = null;
    playlistTotal.value = null;
    feedTotalCount.value = 0;
    selectedPlaylistId.value = null;
    selectedCreator.value = allSubs;
    _feedOwner = allSubs;
    selectedMediaType.value = PornHubMediaType.videos;
    selectedMineSub.value = PornHubMineSub.videos;
    _subsNextPage = 1;
    _clipsNextPage = 1;
    _playlistNextPage = 1;
    _feedHasMore = true;
    _clipsHasMore = true;
    playlistHasMore.value = false;
    for (final loading in [
      isSearching,
      isLoadingSubscriptions,
      isLoadingFeed,
      isLoadingFavorites,
      isLoadingHistory,
      isLoadingMyPlaylists,
      isLoadingPublicPlaylists,
      isLoadingPlaylistVideos,
      isLoadingClips,
    ]) {
      loading.value = false;
    }
    for (final error in [
      searchError,
      subscriptionsError,
      feedError,
      favoritesError,
      historyError,
      myPlaylistsError,
      publicPlaylistsError,
      playlistVideosError,
      clipsError,
    ]) {
      error.value = null;
    }
    for (final state in _listStates.values) {
      state.request++;
      state.items.clear();
      state.page = 1;
      state.isLoading.value = false;
      state.isLoadingMore.value = false;
      state.error.value = null;
      state.hasMore.value = true;
    }
  }

  @override
  void onClose() {
    _accountWorker?.dispose();
    _accountEpoch++;
    _creatorSelectionTimer?.cancel();
    _searchRequest++;
    _subscriptionsRequest++;
    _feedRequest++;
    _favoritesRequest++;
    _historyRequest++;
    _myPlaylistsRequest++;
    _publicPlaylistsRequest++;
    _playlistVideosRequest++;
    _clipsRequest++;
    for (final state in _listStates.values) {
      state.request++;
    }
    super.onClose();
  }

  // ==================================================== 视频列表（推荐 / 最热）

  final Map<String, PornHubListState> _listStates =
      <String, PornHubListState>{};

  /// 取某路径的列表状态（按需创建）。
  PornHubListState stateOf(String path) =>
      _listStates.putIfAbsent(path, PornHubListState.new);

  /// 最热 Tab 当前选中的路径。
  final RxString hotPathSelected = '/video?o=ht'.obs;

  Future<void> loadList(
    String path, {
    bool isRefresh = true,
    int? targetPage,
  }) async {
    final st = stateOf(path);
    final requestedPage = targetPage ?? (isRefresh ? 1 : st.page);
    if (isRefresh) {
      st.hasMore.value = true;
    }
    final request = ++st.request;
    if (isRefresh) {
      st.isLoading.value = true;
    } else {
      st.isLoadingMore.value = true;
    }
    st.error.value = null;
    try {
      final page = await _source.fetchPathPage(path, requestedPage);
      if (request != st.request) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        st.error.value = page.summary;
        st.hasMore.value = true;
        if (!isRefresh) st.page = st.page > 1 ? st.page - 1 : 1;
        return;
      }
      if (isRefresh) {
        st.items.assignAll(page.items);
        if (page.items.isNotEmpty) {
          PreloadService.instance.preloadList(
            page.items.take(2).toList(),
            isNewPage: true,
          );
        }
      } else {
        st.items.addAll(page.items);
      }
      st.page = page.page;
      st.hasMore.value = page.hasMore;
      if (page.items.isEmpty && isRefresh) {
        st.error.value = '未获取到内容，请下拉重试';
      }
    } catch (e) {
      if (request != st.request) return;
      st.error.value = '获取失败，请重试';
      st.hasMore.value = true;
      if (!isRefresh) st.page = st.page > 1 ? st.page - 1 : 1;
    } finally {
      if (request == st.request) {
        st.isLoading.value = false;
        st.isLoadingMore.value = false;
      }
    }
  }

  Future<void> loadMore(String path) async {
    final st = stateOf(path);
    if (st.isLoading.value || st.isLoadingMore.value || !st.hasMore.value) {
      return;
    }
    st.page++;
    await loadList(path, isRefresh: false);
  }

  Future<void> jumpListPage(String path, int page) async {
    if (page < 1) return;
    await loadList(path, targetPage: page);
  }

  /// 切换排序（最热 Tab 用）。
  Future<void> selectHotSort(VideoCategory category) async {
    if (hotPathSelected.value == category.path) return;
    hotPathSelected.value = category.path;
    await loadList(category.path);
  }

  // ==================================================== 搜索

  final RxString searchKeyword = ''.obs;

  /// 当前搜索排序（官网参数：'' 最相关 / mr / mv / tr / lg）。
  final RxString searchSort = ''.obs;

  final RxList<VideoItem> searchResults = <VideoItem>[].obs;
  final RxBool isSearching = false.obs;
  final RxnString searchError = RxnString();
  final RxBool hasMoreSearch = true.obs;
  int _searchPage = 1;
  int _searchRequest = 0;

  Future<void> search(String keyword, {String? sort}) async {
    final trimmed = keyword.trim();
    searchKeyword.value = trimmed;
    if (sort != null) searchSort.value = sort;
    final request = ++_searchRequest;
    if (trimmed.isEmpty) {
      isSearching.value = false;
      hasMoreSearch.value = false;
      searchResults.clear();
      searchError.value = null;
      return;
    }
    _searchPage = 1;
    hasMoreSearch.value = true;
    isSearching.value = true;
    searchError.value = null;
    try {
      final page = await _source.search(
        query: SearchQuery(keyword: trimmed, sortParam: searchSort.value),
        page: 1,
      );
      if (request != _searchRequest) return;
      searchResults.assignAll(page.items);
      hasMoreSearch.value = page.hasMore;
      if (page.items.isEmpty) {
        searchError.value = page.summary ?? '未找到相关视频';
      } else {
        PreloadService.instance.preloadList(
          page.items.take(2).toList(),
          isNewPage: true,
        );
      }
    } catch (e) {
      if (request != _searchRequest) return;
      searchError.value = '搜索失败，请重试';
      hasMoreSearch.value = true;
    } finally {
      if (request == _searchRequest) isSearching.value = false;
    }
  }

  Future<void> loadMoreSearch() async {
    if (isSearching.value || !hasMoreSearch.value) return;
    _searchPage++;
    final request = _searchRequest;
    isSearching.value = true;
    try {
      final page = await _source.search(
        query: SearchQuery(
          keyword: searchKeyword.value,
          sortParam: searchSort.value,
        ),
        page: _searchPage,
      );
      if (request != _searchRequest) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        _searchPage = _searchPage > 1 ? _searchPage - 1 : 1;
        searchError.value = page.summary;
        hasMoreSearch.value = true;
        return;
      }
      searchResults.addAll(page.items);
      hasMoreSearch.value = page.hasMore;
    } catch (_) {
      _searchPage = _searchPage > 1 ? _searchPage - 1 : 1;
      searchError.value = '搜索失败，请重试';
      hasMoreSearch.value = true;
    } finally {
      if (request == _searchRequest) isSearching.value = false;
    }
  }

  // ==================================================== 登录

  final RxBool isLoggingIn = false.obs;
  final RxnString loginError = RxnString();

  PornHubAuthService get auth => PornHubAuthService.to;

  bool get isLoggedIn => auth.isLoggedIn.value;

  String get userName => auth.userName;

  /// 收藏路径（需要登录用户名）。
  String get favoritesPath => '/users/${auth.userName}/videos/favorites';

  Future<bool> login(String email, String password) async {
    isLoggingIn.value = true;
    loginError.value = null;
    try {
      final ok = await auth.login(email, password);
      if (!ok) loginError.value = auth.lastError.value;
      if (ok) unawaited(loadProfile());
      return ok;
    } catch (e) {
      loginError.value = '登录异常: $e';
      return false;
    } finally {
      isLoggingIn.value = false;
    }
  }

  Future<bool> importCookies(String cookie) async {
    isLoggingIn.value = true;
    loginError.value = null;
    try {
      final ok = await auth.importCookies(cookie);
      if (!ok) loginError.value = auth.lastError.value;
      if (ok) unawaited(loadProfile());
      return ok;
    } catch (e) {
      loginError.value = '导入异常: $e';
      return false;
    } finally {
      isLoggingIn.value = false;
    }
  }

  Future<void> logout() async {
    _resetAccountData();
    await auth.logout();
  }

  // ==================================================== 订阅（对标 91 动态页）
  //
  // 形态与 91 的「动态」页一致（用户指定参考）：
  //   顶部一条横向创作者筛选栏 → 视频网格 → 底部分页栏（每页 24 条）。
  //   第一项「全部关注」= 所有订阅创作者的最新视频聚合，按发布时间从新到旧；
  //   其余每一项 = 该创作者自己的视频。
  //
  // 数据来源：`/users/<name>/subscriptions`（实测匿名可访问，52 项）。
  // 取某创作者视频 = 用其站内路径走 [PornHubSource.fetchCreatorVideos]。

  /// 订阅的创作者（3 列网格里的那些）。
  final RxList<PornHubSubscription> subscriptions = <PornHubSubscription>[].obs;
  final RxBool isLoadingSubscriptions = false.obs;
  final RxnString subscriptionsError = RxnString();
  int _subscriptionsRequest = 0;
  Future<void>? _subscriptionsTask;

  /// 「全部订阅」视频流 —— 数据源是官网 `/subscriptions`（需登录）。
  final RxList<VideoItem> feedVideos = <VideoItem>[].obs;
  final RxBool isLoadingFeed = false.obs;
  final RxnString feedError = RxnString();
  final RxInt feedTotalCount = 0.obs;

  /// 累积池：翻页只 append，已有内容不消失（用户明确要求）。
  final List<VideoItem> _feedPool = <VideoItem>[];
  final Set<String> _feedSeen = <String>{};

  /// 当前选中项：`ALL` = 全部订阅（官网 `/subscriptions`），
  /// 否则是某个创作者的站内路径。**切换是原地加载，不跳页**（用户明确要求）。
  static const String allSubs = 'ALL';
  final RxString selectedCreator = allSubs.obs;

  /// 下一个要拉的官网页码（1 起）。
  int _subsNextPage = 1;
  bool _feedHasMore = true;

  /// 加载请求代号：切创作者 / 下拉刷新会自增，让在飞的旧请求作废，
  /// 防止「上一个源的结果」追加进新池子（表现为列表里混着别人家的视频）。
  int _feedRequest = 0;
  String _feedOwner = allSubs;
  Future<void>? _feedTask;
  Timer? _creatorSelectionTimer;

  /// 每个创作者已取到第几页。
  final Map<String, int> _creatorNextPage = <String, int>{};

  /// 每个创作者的**总视频数**（key = 站内路径）。数据来自各自主页上的
  /// 「显示 1-N 个，共有 M 个」标记，用于在 chip 上展示、供用户核对。
  final RxMap<String, int> creatorCounts = <String, int>{}.obs;
  bool _countingCreators = false;
  final Map<String, Future<void>> _creatorCountTasks = {};

  Future<void> fetchSelectedCreatorCount(String key) {
    if (key == allSubs) return Future<void>.value();
    final epoch = _accountEpoch;
    return _creatorCountTasks.putIfAbsent(key, () async {
      try {
        final n = await _source.fetchCreatorTotalCount(key);
        if (n != null && !isClosed && epoch == _accountEpoch) {
          if (selectedCreator.value == key && feedVideos.length >= n) {
            _feedHasMore = false;
          }
          creatorCounts[key] = n;
        }
      } catch (e) {
        AppLogger.w('PornHub', '取创作者计数失败: $e');
      } finally {
        if (epoch == _accountEpoch) _creatorCountTasks.remove(key);
      }
    });
  }

  /// 逐个取每个创作者的总视频数。
  ///
  /// **严格串行、每个之间间隔 1.2 秒** —— 用户明确要求「一个一个来，不要太快」，
  /// 并发抓 50 多个页面会触发 PornHub 限流（实测会返回空列表/403）。
  Future<void> fetchCreatorCounts() async {
    if (_countingCreators) return;
    final epoch = _accountEpoch;
    _countingCreators = true;
    try {
      for (final c in subscriptions.toList(growable: false)) {
        if (isClosed || epoch != _accountEpoch) return;
        if (creatorCounts.containsKey(c.path)) continue;
        // These megabyte-sized pages are optional chip counts. Give foreground
        // stream resolution and media loading the connection and bandwidth.
        while ((PlayerController.hasActivePlayback ||
                currentTabIndex.value != 2 ||
                isLoadingFeed.value ||
                isLoadingSubscriptions.value) &&
            !isClosed &&
            epoch == _accountEpoch) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (isClosed || epoch != _accountEpoch) return;
        if (!creatorCounts.containsKey(c.path)) {
          await fetchSelectedCreatorCount(c.path);
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    } catch (e) {
      AppLogger.w('PornHub', '取创作者计数失败: $e');
    } finally {
      if (epoch == _accountEpoch) _countingCreators = false;
    }
  }

  // ── 订阅页「视频 / 切片」二级选择 ──────────────────────────────────────────
  /// 默认「视频」：此时下方仍是原来的聚合流 / 单创作者视频，行为完全不变。
  final Rx<PornHubMediaType> selectedMediaType = PornHubMediaType.videos.obs;

  /// 当前选中创作者的切片列表（切片只按单个创作者拉取，不做聚合）。
  final RxList<VideoItem> clipVideos = <VideoItem>[].obs;
  final RxBool isLoadingClips = false.obs;
  final RxnString clipsError = RxnString();

  /// 每个创作者的**切片总数**（key = 站内路径）。来自切片页文案
  /// 「显示 1-N 个，共有 M 个」；取不到时该创作者不显示数字。
  final RxMap<String, int> clipCounts = <String, int>{}.obs;

  /// 切片累积池：翻页只 append，已有内容不消失。
  final List<VideoItem> _clipPool = <VideoItem>[];
  final Set<String> _clipSeen = <String>{};
  int _clipsRequest = 0;
  int _clipsNextPage = 1;
  bool _clipsHasMore = true;

  /// 是否还有下一页切片。
  bool get clipsHasMore => _clipsHasMore;

  /// 切换「视频 / 切片」。选切片时按需加载当前创作者的切片。
  void selectMediaType(PornHubMediaType type) {
    if (selectedMediaType.value == type) return;
    selectedMediaType.value = type;
    if (type == PornHubMediaType.clips) {
      unawaited(loadClips(reset: true));
    }
  }

  /// 加载当前创作者的切片（`/…/clips/by-community`）。
  ///
  /// 与 [loadFavorites] 同款：request-id 防竞态 + isClosed，避免切换创作者后
  /// 在飞的旧请求把别人的切片追加进池子。
  Future<void> loadClips({bool reset = false, int? targetPage}) async {
    final creator = selectedCreator.value;
    // 「全部订阅」没有对应的切片列表页：明确提示，不臆造聚合结果。
    if (creator == allSubs) {
      _clipsRequest++;
      _clipPool.clear();
      _clipSeen.clear();
      clipVideos.clear();
      isLoadingClips.value = false;
      _clipsHasMore = false;
      clipsError.value = '请选择一个创作者查看其切片';
      return;
    }
    if (!reset && !_clipsHasMore) return;
    final request = ++_clipsRequest;
    if (reset) {
      _clipsHasMore = true;
    }
    final page = reset ? (targetPage ?? 1) : _clipsNextPage;
    isLoadingClips.value = true;
    clipsError.value = null;
    try {
      final res = await _source.fetchCreatorClips(creator, page: page);
      if (request != _clipsRequest || isClosed) return;
      if (res.summary == PornHubSource.requestFailureMessage) {
        clipsError.value = res.summary;
        _clipsHasMore = true;
        return;
      }
      if (reset) {
        _clipPool.clear();
        _clipSeen.clear();
      }
      for (final item in res.items) {
        if (_clipSeen.add(item.id)) _clipPool.add(item);
      }
      clipVideos.assignAll(_clipPool);
      if (res.totalItems > 0) clipCounts[creator] = res.totalItems;
      _clipsHasMore = res.hasMore && res.items.isNotEmpty;
      _clipsNextPage = page + 1;
      if (clipVideos.isEmpty && res.summary != null) {
        clipsError.value = res.summary;
      }
    } catch (e) {
      if (request == _clipsRequest && !isClosed) {
        clipsError.value = '获取切片失败，请重试';
        _clipsHasMore = true;
        AppLogger.w('PornHub', '切片请求失败: $e');
      }
    } finally {
      if (request == _clipsRequest) isLoadingClips.value = false;
    }
  }

  /// 上滑到底时调用：追加下一页切片。
  Future<void> loadMoreClips() async {
    if (isLoadingClips.value || !_clipsHasMore) return;
    await loadClips();
  }

  int get feedPage =>
      ((selectedCreator.value == allSubs
                  ? _subsNextPage
                  : (_creatorNextPage[selectedCreator.value] ?? 1)) -
              1)
          .clamp(1, 2147483647);
  int get clipsPage => (_clipsNextPage - 1).clamp(1, 2147483647);
  int get playlistPage => (_playlistNextPage - 1).clamp(1, 2147483647);
  Future<void> jumpFeedPage(int page) async {
    if (page > 0) await loadFeed(reset: true, targetPage: page);
  }

  Future<void> jumpClipsPage(int page) async {
    if (page > 0) await loadClips(reset: true, targetPage: page);
  }

  Future<void> jumpPlaylistPage(int page) async {
    final id = selectedPlaylistId.value;
    if (page > 0 && id != null) await loadPlaylistVideos(id, targetPage: page);
  }

  final RxInt favoritesPage = 1.obs, historyPage = 1.obs;
  final RxBool favoritesHasMore = false.obs, historyHasMore = false.obs;

  /// 收藏（保持原样）。
  final RxList<VideoItem> favorites = <VideoItem>[].obs;
  final RxBool isLoadingFavorites = false.obs;
  final RxnString favoritesError = RxnString();
  int _favoritesRequest = 0;

  // ── 「我的」页面用：观看历史 + 我收藏的片单 ───────────────────────────────
  /// 观看历史 `/users/<name>/videos/recent`
  final RxList<VideoItem> history = <VideoItem>[].obs;
  final RxBool isLoadingHistory = false.obs;
  final RxnString historyError = RxnString();
  int _historyRequest = 0;

  /// 我收藏的片单 `/users/<name>/playlists/favorites`
  final RxList<PornHubPlaylist> myPlaylists = <PornHubPlaylist>[].obs;
  final RxBool isLoadingMyPlaylists = false.obs;
  final RxnString myPlaylistsError = RxnString();
  int _myPlaylistsRequest = 0;

  /// 「我的 · 片单」里当前选中的片单 id（null = 还没选，UI 会自动选第一个）。
  final RxnString selectedPlaylistId = RxnString();

  /// 选中片单里的视频。
  final RxList<VideoItem> playlistVideos = <VideoItem>[].obs;
  final RxBool isLoadingPlaylistVideos = false.obs;
  final RxnString playlistVideosError = RxnString();
  int _playlistVideosRequest = 0;

  /// 历史总数（来自 `VideoPage.totalItems`；官网没给这个文案时保持 null）。
  final RxnInt historyTotal = RxnInt();

  /// 我收藏的片单总数（= myPlaylists.length）。
  final RxnInt playlistTotal = RxnInt();

  /// 「收藏」板块下选的是「我的视频」还是「我的片单」。
  final Rx<PornHubMineSub> selectedMineSub = PornHubMineSub.videos.obs;

  /// 我的公开片单 `/users/<name>/playlists/public`（收藏 · 我的片单）。
  final RxList<PornHubPlaylist> publicPlaylists = <PornHubPlaylist>[].obs;
  final RxBool isLoadingPublicPlaylists = false.obs;
  final RxnString publicPlaylistsError = RxnString();
  int _publicPlaylistsRequest = 0;

  Future<void> loadProfile() async {
    if (!isLoggedIn) return;
    await Future.wait<void>(<Future<void>>[
      loadFavorites(),
      loadSubscriptions(),
    ]);
  }

  /// 拉取订阅创作者列表。
  ///
  /// 用户要求：**删掉本地数据缓存，订阅一律在线拉取**。
  /// 这里不再读写任何本地存储；下拉刷新只重置内存状态。
  Future<void> loadSubscriptions({bool refresh = false}) {
    final pending = _subscriptionsTask;
    if (pending != null) return pending;
    final task = _loadSubscriptions(refresh: refresh);
    _subscriptionsTask = task;
    return task.whenComplete(() {
      if (identical(_subscriptionsTask, task)) _subscriptionsTask = null;
    });
  }

  Future<void> _loadSubscriptions({required bool refresh}) async {
    final name = userName;
    if (name.isEmpty) {
      subscriptionsError.value = '请先登录 PornHub';
      return;
    }
    final request = ++_subscriptionsRequest;
    isLoadingSubscriptions.value = true;
    subscriptionsError.value = null;
    try {
      // 订阅创作者列表：**始终在线拉取**（用户要求删掉本地数据缓存）。
      final list = await _source.fetchSubscribedCreators(name);
      if (request != _subscriptionsRequest || isClosed) return;
      if (list.isNotEmpty) {
        subscriptions.assignAll(list);
        subscriptionsError.value = null;
        // 逐个（串行、限流）取每个创作者的总视频数，回填到 chip 上供核对。
        unawaited(fetchCreatorCounts());
      } else if (subscriptions.isEmpty) {
        subscriptionsError.value = '未获取到订阅';
      }
      // list 为空但已有旧数据时：保留旧列表，不清空、不报错。

      if (subscriptions.isNotEmpty && (refresh || feedVideos.isEmpty)) {
        await loadFeed(reset: true);
      }
    } on PornHubRequestException {
      if (request == _subscriptionsRequest) {
        subscriptionsError.value = PornHubSource.requestFailureMessage;
        if (refresh && feedVideos.isNotEmpty) {
          feedError.value = '订阅更新失败，已保留原内容，请重试';
        }
      }
    } catch (e) {
      if (request == _subscriptionsRequest) {
        subscriptionsError.value = '获取订阅失败，请重试';
        if (refresh && feedVideos.isNotEmpty) {
          feedError.value = '订阅更新失败，已保留原内容，请重试';
        }
      }
    } finally {
      if (request == _subscriptionsRequest) {
        isLoadingSubscriptions.value = false;
      }
    }
  }

  /// 当前选中的创作者名（供列表标题展示）。
  String get selectedCreatorName {
    final key = selectedCreator.value;
    if (key == allSubs) return '全部订阅';
    for (final c in subscriptions) {
      if (c.path == key) return c.name;
    }
    return '全部订阅';
  }

  /// 切换查看「全部订阅」或某个创作者 —— **原地加载，不跳页**。
  void selectCreator(String key) {
    if (selectedCreator.value == key) {
      selectMediaType(PornHubMediaType.videos);
      unawaited(fetchSelectedCreatorCount(key));
      return;
    }
    _creatorSelectionTimer?.cancel();
    _feedRequest++;
    selectedCreator.value = key;
    _activateFeedOwner(key);
    isLoadingFeed.value = true;
    // 用户要求：点开某个订阅默认看「视频」。所以切创作者时一律切回视频，
    // 并清掉上一个创作者的切片池 —— 切片是按创作者分页的独立列表，
    // 不清会短暂串到别人的切片上。
    selectedMediaType.value = PornHubMediaType.videos;
    _clipsRequest++;
    _clipPool.clear();
    _clipSeen.clear();
    clipVideos.clear();
    clipsError.value = null;
    _clipsNextPage = 1;
    _clipsHasMore = true;
    isLoadingClips.value = false;
    _creatorSelectionTimer = Timer(const Duration(milliseconds: 160), () {
      if (!isClosed) {
        unawaited(fetchSelectedCreatorCount(key));
        unawaited(loadFeed(reset: true));
        if (selectedMediaType.value == PornHubMediaType.clips) {
          unawaited(loadClips(reset: true));
        }
      }
    });
  }

  void _activateFeedOwner(String key) {
    if (_feedOwner == key) return;
    _feedOwner = key;
    _feedPool.clear();
    _feedSeen.clear();
    feedVideos.clear();
    feedTotalCount.value = 0;
    feedError.value = null;
    _subsNextPage = 1;
    _creatorNextPage[key] = 1;
    _feedHasMore = true;
  }

  /// 重新加载 / 首次加载（reset = 从头拉第 1 页）。
  Future<void> loadFeed({bool reset = false, int? targetPage}) {
    if (!reset && isLoadingFeed.value) return _feedTask ?? Future<void>.value();
    _creatorSelectionTimer?.cancel();
    final task = _loadFeed(reset: reset, targetPage: targetPage);
    _feedTask = task;
    return task.whenComplete(() {
      if (identical(_feedTask, task)) _feedTask = null;
    });
  }

  Future<void> _loadFeed({required bool reset, int? targetPage}) async {
    if (!_feedHasMore && !reset) return;
    final creator = selectedCreator.value;
    final req = ++_feedRequest;
    isLoadingFeed.value = true;
    _activateFeedOwner(creator);
    feedError.value = null;
    if (reset && creator != allSubs) {
      unawaited(fetchSelectedCreatorCount(creator));
    }
    final page = reset
        ? (targetPage ?? 1)
        : (creator == allSubs
              ? _subsNextPage
              : (_creatorNextPage[creator] ?? 1));
    try {
      final res = creator == allSubs
          ? await _source.fetchSubscriptionsFeed(page: page)
          : await _source.fetchCreatorVideos(creator, page: page);
      if (req != _feedRequest || isClosed) return;
      if (res.items.isEmpty && res.summary != null) {
        final total = creatorCounts[creator];
        if (!reset && total != null && _feedPool.length >= total) {
          _feedHasMore = false;
          return;
        }
        feedError.value = res.summary;
        return;
      }
      if (reset && res.items.isEmpty && feedVideos.isNotEmpty) {
        feedError.value = '刷新未获取到有效内容，已保留原视频，请重试';
        return;
      }
      // Commit data and pagination together only after a successful response.
      if (reset) {
        _feedPool.clear();
        _feedSeen.clear();
      }
      final appended = <VideoItem>[];
      for (final item in res.items) {
        if (_feedSeen.add(item.id)) {
          _feedPool.add(item);
          appended.add(item);
        }
      }
      if (creator != allSubs) {
        final ordered = _feedPool.indexed.toList()
          ..sort((a, b) {
            final left = DateTime.tryParse(a.$2.publishedAt ?? '');
            final right = DateTime.tryParse(b.$2.publishedAt ?? '');
            if (left == null && right != null) return 1;
            if (left != null && right == null) return -1;
            final byDate = left != null && right != null
                ? right.compareTo(left)
                : 0;
            return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
          });
        _feedPool
          ..clear()
          ..addAll(ordered.map((entry) => entry.$2));
      }
      final keepsVisibleOrder =
          feedVideos.length <= _feedPool.length &&
          feedVideos.indexed.every(
            (entry) => entry.$2.id == _feedPool[entry.$1].id,
          );
      if (reset || !keepsVisibleOrder) {
        feedVideos.assignAll(_feedPool);
      } else {
        feedVideos.addAll(_feedPool.skip(feedVideos.length));
      }
      feedTotalCount.value = _feedPool.length;
      final total = creator == allSubs ? null : creatorCounts[creator];
      _feedHasMore =
          res.hasMore &&
          res.items.isNotEmpty &&
          appended.isNotEmpty &&
          (total == null || _feedPool.length < total);
      if (creator == allSubs) {
        _subsNextPage = page + 1;
      } else {
        _creatorNextPage[creator] = page + 1;
      }
      if (currentTabIndex.value != 2 && res.items.isNotEmpty) {
        PreloadService.instance.preloadList(res.items.take(2).toList());
      }
    } catch (e) {
      if (req == _feedRequest && !isClosed) {
        feedError.value = '加载失败，请重试';
        AppLogger.w('PornHub', '订阅视频请求失败: $e');
      }
    } finally {
      if (req == _feedRequest) isLoadingFeed.value = false;
    }
  }

  /// 上滑到底时调用：**追加**下一页，已有内容不消失（用户明确要求）。
  Future<void> loadMoreFeed() async {
    if (isLoadingFeed.value || isLoadingSubscriptions.value) return;
    await loadFeed();
  }

  /// 是否还有下一页。
  bool get feedHasMore => _feedHasMore;

  Future<void> loadFavorites({int targetPage = 1, bool append = false}) async {
    if (isLoadingFavorites.value) return;
    if (!isLoggedIn) {
      favoritesError.value = '请先登录 PornHub';
      return;
    }
    final request = ++_favoritesRequest;
    isLoadingFavorites.value = true;
    favoritesError.value = null;
    try {
      final page = await _source.fetchFavorites(page: targetPage);
      if (request != _favoritesRequest || isClosed) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        favoritesError.value = page.summary;
        return;
      }
      if (append) {
        favorites.addAll(page.items);
      } else {
        favorites.assignAll(page.items);
      }
      favoritesPage.value = page.page;
      favoritesHasMore.value = page.hasMore;
      if (page.items.isEmpty && page.summary != null) {
        favoritesError.value = page.summary;
      }
    } catch (e) {
      if (request == _favoritesRequest) {
        favoritesError.value = '获取收藏失败，请重试';
      }
    } finally {
      if (request == _favoritesRequest) isLoadingFavorites.value = false;
    }
  }

  /// 观看历史 `/users/<name>/videos/recent`
  Future<void> loadHistory({int targetPage = 1, bool append = false}) async {
    if (isLoadingHistory.value) return;
    if (!isLoggedIn) {
      historyError.value = '请先登录 PornHub';
      return;
    }
    final request = ++_historyRequest;
    isLoadingHistory.value = true;
    historyError.value = null;
    try {
      final page = await _source.fetchHistory(page: targetPage);
      if (request != _historyRequest || isClosed) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        historyError.value = page.summary;
        return;
      }
      if (append) {
        history.addAll(page.items);
      } else {
        history.assignAll(page.items);
      }
      historyPage.value = page.page;
      historyHasMore.value = page.hasMore;
      // 展示官网实际返回的最近观看记录数；不会用本机历史覆盖账号记录。
      // 无记录时保持 null，
      // 让 chip 只显示「历史」而不显示一个臆造的条数。
      historyTotal.value = page.totalItems > 0 ? page.totalItems : null;
      if (page.items.isEmpty && page.summary != null) {
        historyError.value = page.summary;
      }
    } catch (e) {
      if (request == _historyRequest) historyError.value = '获取历史失败，请重试';
    } finally {
      if (request == _historyRequest) isLoadingHistory.value = false;
    }
  }

  /// 我收藏的片单 `/users/<name>/playlists/favorites`
  Future<void> loadMyPlaylists() async {
    if (isLoadingMyPlaylists.value) return;
    if (!isLoggedIn) {
      myPlaylistsError.value = '请先登录 PornHub';
      return;
    }
    final request = ++_myPlaylistsRequest;
    isLoadingMyPlaylists.value = true;
    myPlaylistsError.value = null;
    try {
      final list = await _source.fetchUserPlaylists();
      if (request != _myPlaylistsRequest || isClosed) return;
      myPlaylists.assignAll(list);
      playlistTotal.value = list.length;
      if (list.isEmpty) {
        _playlistVideosRequest++;
        selectedPlaylistId.value = null;
        playlistVideos.clear();
        playlistHasMore.value = false;
        isLoadingPlaylistVideos.value = false;
      }
      if (list.isNotEmpty &&
          !list.any((p) => p.id == selectedPlaylistId.value)) {
        await loadPlaylistVideos(list.first.id);
      }
      if (list.isEmpty) myPlaylistsError.value = '还没有收藏任何片单';
    } catch (e) {
      if (request == _myPlaylistsRequest) {
        myPlaylistsError.value = '获取片单失败，请重试';
      }
    } finally {
      if (request == _myPlaylistsRequest) isLoadingMyPlaylists.value = false;
    }
  }

  /// 我的公开片单 `/users/<name>/playlists/public`（收藏 · 我的片单）。
  ///
  /// 写法与 [loadMyPlaylists] 一致：request-id 防竞态 + isClosed 判断，
  /// 避免旧请求把已切换页面的结果盖回来。
  Future<void> loadPublicPlaylists() async {
    if (isLoadingPublicPlaylists.value) return;
    if (!isLoggedIn) {
      publicPlaylistsError.value = '请先登录 PornHub';
      return;
    }
    final request = ++_publicPlaylistsRequest;
    isLoadingPublicPlaylists.value = true;
    publicPlaylistsError.value = null;
    try {
      final list = await _source.fetchPublicPlaylists();
      if (request != _publicPlaylistsRequest || isClosed) return;
      publicPlaylists.assignAll(list);
      if (list.isEmpty) publicPlaylistsError.value = '还没有创建片单';
    } catch (e) {
      if (request == _publicPlaylistsRequest) {
        publicPlaylistsError.value = '获取片单失败，请重试';
      }
    } finally {
      if (request == _publicPlaylistsRequest) {
        isLoadingPublicPlaylists.value = false;
      }
    }
  }

  /// 选中某个片单并加载其视频（`/playlist/<id>`）。
  ///
  /// 先写入 [selectedPlaylistId]，让 UI 立即高亮选中项；同样带 request-id
  /// 防竞态，快速连点多个片单时只有最后一次的结果会被采用。
  int _playlistNextPage = 1;
  final RxBool playlistHasMore = false.obs;

  Future<void> loadMorePlaylistVideos() async {
    final id = selectedPlaylistId.value;
    if (id == null || isLoadingPlaylistVideos.value || !playlistHasMore.value) {
      return;
    }
    final request = _playlistVideosRequest;
    isLoadingPlaylistVideos.value = true;
    playlistVideosError.value = null;
    try {
      final page = await _source.fetchPlaylistVideos(
        id,
        page: _playlistNextPage,
      );
      if (isClosed ||
          request != _playlistVideosRequest ||
          selectedPlaylistId.value != id) {
        return;
      }
      if (page.summary == PornHubSource.requestFailureMessage) {
        throw const PornHubRequestException();
      }
      final seen = playlistVideos.map((v) => v.id).toSet();
      playlistVideos.addAll(page.items.where((v) => seen.add(v.id)));
      playlistHasMore.value = page.hasMore;
      _playlistNextPage++;
    } catch (_) {
      if (request == _playlistVideosRequest) {
        playlistVideosError.value = '加载更多失败，点击重试';
      }
    } finally {
      if (request == _playlistVideosRequest) {
        isLoadingPlaylistVideos.value = false;
      }
    }
  }

  Future<void> loadPlaylistVideos(
    String playlistId, {
    int targetPage = 1,
  }) async {
    if (selectedPlaylistId.value != playlistId) playlistVideos.clear();
    selectedPlaylistId.value = playlistId;
    final request = ++_playlistVideosRequest;
    isLoadingPlaylistVideos.value = true;
    playlistVideosError.value = null;
    try {
      final page = await _source.fetchPlaylistVideos(
        playlistId,
        page: targetPage,
      );
      if (request != _playlistVideosRequest || isClosed) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        playlistVideosError.value = page.summary;
        return;
      }
      playlistVideos.assignAll(page.items);
      _playlistNextPage = page.page + 1;
      playlistHasMore.value = page.hasMore;
      if (page.items.isEmpty && page.summary != null) {
        playlistVideosError.value = page.summary;
      }
    } catch (e) {
      if (request == _playlistVideosRequest) {
        playlistVideosError.value = '获取片单视频失败，请重试';
      }
    } finally {
      if (request == _playlistVideosRequest) {
        isLoadingPlaylistVideos.value = false;
      }
    }
  }
}

/// 某个路径下的列表分页状态。
class PornHubListState {
  final RxList<VideoItem> items = <VideoItem>[].obs;
  final RxBool isLoading = false.obs;
  final RxBool isLoadingMore = false.obs;
  final RxBool hasMore = true.obs;
  final RxnString error = RxnString();
  int page = 1;
  int request = 0;
}

/// 「我的 · 收藏」板块下的二级选择：我的视频 / 我的片单。
enum PornHubMineSub { videos, playlists }

/// 订阅页的二级选择：视频（原聚合流）/ 切片。
enum PornHubMediaType { videos, clips }
