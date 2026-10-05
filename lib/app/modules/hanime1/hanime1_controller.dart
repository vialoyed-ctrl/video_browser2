/// Hanime1 独立业务控制器。
///
/// 独立管理 Hanime1 专版：
/// 1. 首页多板块数据与 Hero 焦点（HomeTab）；
/// 2. 多周期排行榜单（RankingTab）；
/// 3. 订阅创作者与筛选列表（SubscriptionsTab）；
/// 4. 账户状态与云端收藏/历史同步（ProfileTab）。
library;

import 'dart:async';

import 'package:get/get.dart';

import '../../core/app_logger.dart';
import '../../data/models/hanime1_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/hanime1_source.dart';
import '../../services/hanime1_auth_service.dart';
import '../../services/preload_service.dart';

class Hanime1Controller extends GetxController {
  static Hanime1Controller get to => Get.find<Hanime1Controller>();

  Hanime1Controller(this._source);

  final Hanime1Source _source;

  /// 当前底部导航选中索引 (0: 主页, 1: 本日排行, 2: 订阅内容, 3: 我的 Hanime1)
  final RxInt currentTabIndex = 0.obs;

  // --- 1. 首页 (Home Tab) 状态 ---
  final Rxn<Hanime1HomeData> homeData = Rxn<Hanime1HomeData>();
  final RxBool isLoadingHome = true.obs;
  final RxnString homeError = RxnString();

  // --- 2. 排行榜 (Ranking Tab) 状态 ---
  final List<String> rankingTabs = const [
    '本日排行',
    '本週排行',
    '本月排行',
    '最新上市',
    '最新上傳',
  ];
  final RxInt currentRankTabIndex = 0.obs;
  final RxList<VideoItem> rankingVideos = <VideoItem>[].obs;
  final RxBool isLoadingRanking = false.obs;
  final RxBool hasMoreRanking = true.obs;
  final RxInt rankingPage = 1.obs;
  final RxInt rankingTotalPages = 1.obs;
  final RxnString rankingError = RxnString();
  int _rankPage = 1;
  int _rankRequest = 0;

  // --- 3. 订阅内容 (Subscriptions Tab) 状态 ---
  final Rxn<Hanime1SubscriptionData> subData = Rxn<Hanime1SubscriptionData>();
  final RxBool isLoadingSub = false.obs;
  final RxnString selectedCreator = RxnString();
  final RxList<VideoItem> subVideos = <VideoItem>[].obs;
  final RxBool hasMoreSub = false.obs;
  final RxInt subscriptionsPage = 1.obs;
  final RxInt subscriptionsTotalPages = 1.obs;
  final RxString subscriptionGenre = ''.obs;
  final RxString subscriptionSort = ''.obs;
  final RxString subscriptionDate = ''.obs;
  final RxString subscriptionDuration = ''.obs;
  final RxList<String> subscriptionTags = <String>[].obs;
  final RxBool subscriptionBroad = false.obs;
  final RxnString subscriptionsError = RxnString();
  int _subPage = 1;
  int _subRequest = 0;

  // --- 4. 我的 Hanime1 (Profile Tab) 状态 ---
  //
  // 对齐官网 `/user/{uid}`：头部资料 + 4 个视频横排（觀看紀錄 / 稍後觀看 /
  // 讚好的影片 / 播放清單）。这些数据只能从服务端渲染的 HTML 里拿，
  // 所以由 [Hanime1Source.fetchUserProfile] 抓取并解析。
  final Rxn<Hanime1UserProfile> userProfile = Rxn<Hanime1UserProfile>();
  final RxBool isLoadingProfile = false.obs;
  final RxnString profileError = RxnString();

  // --- 4b. 「我的」页**单个 Tab 的独立分页**状态 ---
  //
  // 官网点 Tab 是跳独立分页（`/user/{uid}/saves` 等，每页 60 条 + 数字分页器），
  // 不是复用首屏那 12 条预览。所以这里按 tabKey 分别缓存与分页，
  // tabKey ∈ {histories, saves, likes, playlists}（由 URL 尾段得来，不受文案变化影响）。
  final RxMap<String, Hanime1UserTabPage> userTabPages =
      <String, Hanime1UserTabPage>{}.obs;

  /// 正在**首次加载**的 tabKey（空串 = 无）。用于显示整页 loading。
  final RxString loadingUserTab = ''.obs;

  /// 正在加载**下一页**的 tabKey（空串 = 无）。用于列表底部 loading。
  final RxString loadingMoreUserTab = ''.obs;

  int _homeRequest = 0, _profileRequest = 0, _userEpoch = 0;
  String _userId = '';

  bool _currentUser(String uid, int epoch) =>
      !isClosed &&
      epoch == _userEpoch &&
      Hanime1AuthService.to.isLoggedIn.value &&
      Hanime1AuthService.to.userId.value == uid;

  void _ensureUser(String uid) {
    if (_userId == uid) return;
    clearUserProfile();
    _userId = uid;
  }

  @override
  void onClose() {
    _homeRequest++;
    _profileRequest++;
    _rankRequest++;
    _subRequest++;
    _userEpoch++;
    super.onClose();
  }

  void switchTab(int index) {
    currentTabIndex.value = index;
    if (index == 1 && rankingVideos.isEmpty) {
      loadRanking(rankingTabs[currentRankTabIndex.value]);
    } else if (index == 2 && subData.value == null) {
      loadSubscriptions();
    } else if (index == 3) {
      // 「我的」页数据带用户态，切进来就刷一次（登录状态可能刚变过）。
      loadUserProfile();
    }
  }

  // ================= 首页逻辑 =================
  Future<void> loadHomeData() async {
    if (isClosed) return;
    final request = ++_homeRequest;
    isLoadingHome.value = true;
    homeError.value = null;
    try {
      final data = await _source.fetchHomeStructured();
      if (isClosed || request != _homeRequest) return;
      if (data != null && (data.sections.isNotEmpty || data.hero != null)) {
        homeData.value = data;
        final videos = <VideoItem>[
          if (data.hero != null) data.hero!.toVideoItem(),
          ...data.sections.expand((section) => section.items),
        ];
        PreloadService.instance.preloadList(videos, isNewPage: true);
      } else {
        homeError.value = '首页数据获取为空，请下拉重试';
      }
    } catch (e) {
      if (!isClosed && request == _homeRequest) {
        homeError.value = '获取首页数据失败: $e';
      }
    } finally {
      if (!isClosed && request == _homeRequest) isLoadingHome.value = false;
    }
  }

  // ================= 排行榜逻辑 =================
  Future<void> selectRankingTab(int index) async {
    if (currentRankTabIndex.value == index && rankingVideos.isNotEmpty) return;
    currentRankTabIndex.value = index;
    await loadRanking(rankingTabs[index]);
  }

  Future<void> loadRanking(
    String sortName, {
    bool isRefresh = true,
    int? page,
    bool append = false,
  }) async {
    if (isClosed) return;
    final requestedPage = page ?? (isRefresh ? 1 : _rankPage);
    final request = ++_rankRequest;
    rankingError.value = null;
    isLoadingRanking.value = true;
    try {
      final pageData = await _source.fetchRankingList(
        sortName,
        page: requestedPage,
      );
      if (isClosed || request != _rankRequest) return;
      if (append) {
        rankingVideos.addAll(pageData.items);
      } else {
        rankingVideos.assignAll(pageData.items);
      }
      _rankPage = pageData.page;
      PreloadService.instance.preloadList(
        pageData.items,
        isNewPage: requestedPage == 1,
      );
      rankingPage.value = pageData.page;
      rankingTotalPages.value = pageData.totalPages;
      hasMoreRanking.value = pageData.hasMore;
    } catch (_) {
      if (isClosed || request != _rankRequest) return;
      rankingError.value = '排行加载失败，请重试';
    } finally {
      if (!isClosed && request == _rankRequest) isLoadingRanking.value = false;
    }
  }

  Future<void> loadMoreRanking() async {
    if (isLoadingRanking.value || !hasMoreRanking.value) return;
    await loadRanking(
      rankingTabs[currentRankTabIndex.value],
      isRefresh: false,
      page: _rankPage + 1,
      append: true,
    );
  }

  // ================= 订阅页逻辑 =================
  Future<void> loadSubscriptions({
    String? creatorQuery,
    bool isRefresh = true,
    int? page,
    bool append = false,
  }) async {
    if (isClosed) return;
    final requestedPage = page ?? (isRefresh ? 1 : _subPage);
    final request = ++_subRequest;
    if (isRefresh) {
      selectedCreator.value = creatorQuery;
    }
    subscriptionsError.value = null;
    isLoadingSub.value = true;

    try {
      final data = await _source.fetchSubscriptionsData(
        page: requestedPage,
        query: selectedCreator.value,
        genre: subscriptionGenre.value,
        sort: subscriptionSort.value,
        date: subscriptionDate.value,
        duration: subscriptionDuration.value,
        tags: subscriptionTags.toList(growable: false),
        broad: subscriptionBroad.value,
      );
      if (isClosed || request != _subRequest) return;
      subData.value = data;
      if (append) {
        subVideos.addAll(data.items);
      } else {
        subVideos.assignAll(data.items);
      }
      _subPage = data.page;
      PreloadService.instance.preloadList(
        data.items,
        isNewPage: requestedPage == 1,
      );
      subscriptionsPage.value = data.page;
      subscriptionsTotalPages.value = data.totalPages;
      hasMoreSub.value = data.hasMore;
    } catch (_) {
      if (isClosed || request != _subRequest) return;
      subscriptionsError.value = '订阅加载失败，请重试';
    } finally {
      if (!isClosed && request == _subRequest) isLoadingSub.value = false;
    }
  }

  Future<void> loadMoreSubscriptions() async {
    if (isLoadingSub.value || !hasMoreSub.value) return;
    await loadSubscriptions(
      creatorQuery: selectedCreator.value,
      isRefresh: false,
      page: _subPage + 1,
      append: true,
    );
  }

  void selectCreator(String? creatorName) {
    if (selectedCreator.value == creatorName) return;
    loadSubscriptions(creatorQuery: creatorName);
  }

  void setSubscriptionFilter(String type, String value) {
    switch (type) {
      case 'genre':
        subscriptionGenre.value = value;
      case 'sort':
        subscriptionSort.value = value;
      case 'date':
        subscriptionDate.value = value;
      case 'duration':
        subscriptionDuration.value = value;
      default:
        return;
    }
    loadSubscriptions(creatorQuery: selectedCreator.value);
  }

  void setSubscriptionTags(List<String> tags, {required bool broad}) {
    subscriptionTags.assignAll(tags);
    subscriptionBroad.value = broad;
    loadSubscriptions(creatorQuery: selectedCreator.value);
  }

  // ================= 我的 Hanime1 逻辑 =================

  /// 拉取官网 `/user/{uid}`。
  ///
  /// 未登录时直接清空 —— 官网未登录访问底栏第 4 项会跳 `/login`，
  /// 这里对应「资料区显示未登录 + 不请求」。
  Future<void> loadUserProfile({bool force = false}) async {
    if (isClosed) return;
    final auth = Hanime1AuthService.to;

    if (!auth.isLoggedIn.value) {
      clearUserProfile();
      return;
    }

    final uid = auth.userId.value;
    if (uid.isEmpty) {
      profileError.value = '登录会话缺少 UID，请重新登录';
      return;
    }

    _ensureUser(uid);
    if (isLoadingProfile.value) return;
    if (!force && userProfile.value != null) return;

    final epoch = _userEpoch, request = ++_profileRequest;
    isLoadingProfile.value = true;
    profileError.value = null;
    try {
      final profile = await _source.fetchUserProfile(uid);
      if (!_currentUser(uid, epoch) || request != _profileRequest) return;
      if (profile == null || !profile.hasAnything) {
        profileError.value = '未能获取「我的」页数据，请稍后重试';
      } else {
        userProfile.value = profile;

        // 首屏某些行可能**整行为空** —— 官网对登录态返回的 HTML 不保证 4 行
        // 都有卡片（实测 `rows=4 (觀看紀錄:12, 稍后观看:12, 点赞的视频:12,
        // 播放清单:0)`，且曾观察到只解析出 1 行的情形）。
        // 空行用对应 Tab 的独立分页补一次，保证首頁 4 行都显示得出来。
        for (final r in profile.rows) {
          if (r.tabKey.isEmpty || r.items.isNotEmpty) continue;
          unawaited(loadUserTab(r.tabKey));
        }
      }
    } catch (e) {
      if (_currentUser(uid, epoch) && request == _profileRequest) {
        profileError.value = '获取「我的」页失败：$e';
      }
    } finally {
      if (_currentUser(uid, epoch) && request == _profileRequest) {
        isLoadingProfile.value = false;
      }
    }
  }

  /// 快捷登录后联动刷新
  Future<void> loginAndRefresh(String email, String password) async {
    final ok = await Hanime1AuthService.to.login(email, password);
    if (ok && !isClosed) {
      clearUserProfile();
      if (currentTabIndex.value == 2) {
        loadSubscriptions();
      }
      // 换了账号 → 用户页必须重新拉，不能用上一个人的缓存。
      loadUserProfile(force: true);
      loadHomeData();
    }
  }

  // ================= 我的 Hanime1：单个 Tab 分页 =================

  /// 拉取/刷新某个 Tab 的第一页。
  ///
  /// [tabKey] 取 URL 尾段：`histories` / `saves` / `likes` / `playlists`。
  /// 已有缓存且非 force 时直接返回，避免来回切 Tab 重复请求。
  Future<void> loadUserTab(
    String tabKey, {
    bool force = false,
    String sort = 'latest',
  }) async {
    final key = tabKey.trim();
    if (isClosed || key.isEmpty) return;

    final auth = Hanime1AuthService.to;
    if (!auth.isLoggedIn.value) return;
    final uid = auth.userId.value;
    if (uid.isEmpty) return;
    _ensureUser(uid);
    final epoch = _userEpoch;

    final cached = userTabPages[key];
    if (!force && cached != null && cached.items.isNotEmpty) return;
    if (loadingUserTab.value == key) return;

    loadingUserTab.value = key;
    try {
      final data = await _source.fetchUserTabPage(
        uid,
        key,
        page: 1,
        sort: sort,
      );
      if (_currentUser(uid, epoch)) userTabPages[key] = data;
    } catch (error) {
      if (_currentUser(uid, epoch)) {
        AppLogger.w('Hanime1', '用户列表加载失败: $error', error);
      }
    } finally {
      if (_currentUser(uid, epoch) && loadingUserTab.value == key) {
        loadingUserTab.value = '';
      }
    }
  }

  /// 拉取某个 Tab 的下一页（列表滚到底触发）。
  Future<void> loadMoreUserTab(String tabKey) async {
    final key = tabKey.trim();
    if (isClosed || key.isEmpty) return;
    final auth = Hanime1AuthService.to;
    if (!auth.isLoggedIn.value) return;
    final uid = auth.userId.value;
    if (uid.isEmpty) return;
    _ensureUser(uid);
    final epoch = _userEpoch;

    if (loadingMoreUserTab.value == key || loadingUserTab.value == key) return;

    final current = userTabPages[key];
    if (current == null || !current.hasMore) return;

    loadingMoreUserTab.value = key;
    try {
      final next = await _source.fetchUserTabPage(
        uid,
        key,
        page: current.page + 1,
        sort: current.sort,
      );

      if (!_currentUser(uid, epoch) || !identical(userTabPages[key], current)) {
        return;
      }
      if (next.items.isEmpty) {
        // 空页但分页器还在 → 认为到底，避免无限重试。
        userTabPages[key] = Hanime1UserTabPage(
          items: current.items,
          page: current.page,
          hasMore: false,
          sort: current.sort,
          totalPages: current.totalPages,
        );
        return;
      }

      // 分页边界可能重复上页最后一条，按 id 去重后追加。
      final seen = current.items.map((e) => e.id).toSet();
      userTabPages[key] = Hanime1UserTabPage(
        items: <VideoItem>[
          ...current.items,
          ...next.items.where((e) => seen.add(e.id)),
        ],
        page: next.page,
        hasMore: next.hasMore,
        sort: next.sort,
        totalPages: next.totalPages,
      );
    } catch (error) {
      if (_currentUser(uid, epoch)) {
        AppLogger.w('Hanime1', '用户列表加载失败: $error', error);
      }
    } finally {
      if (_currentUser(uid, epoch) && loadingMoreUserTab.value == key) {
        loadingMoreUserTab.value = '';
      }
    }
  }

  /// Replace the visible results with one site page, preserving the active sort.
  Future<void> goToUserTabPage(String tabKey, int page) async {
    final key = tabKey.trim();
    if (isClosed || key.isEmpty || page < 1) return;
    final auth = Hanime1AuthService.to;
    if (!auth.isLoggedIn.value || auth.userId.value.isEmpty) return;
    final uid = auth.userId.value;
    _ensureUser(uid);
    final epoch = _userEpoch;
    final current = userTabPages[key];
    if (current == null ||
        current.page == page ||
        loadingMoreUserTab.value == key) {
      return;
    }
    loadingMoreUserTab.value = key;
    try {
      final result = await _source.fetchUserTabPage(
        uid,
        key,
        page: page,
        sort: current.sort,
      );
      if (_currentUser(uid, epoch) && identical(userTabPages[key], current)) {
        userTabPages[key] = result;
      }
    } catch (error) {
      if (_currentUser(uid, epoch)) {
        AppLogger.w('Hanime1', '用户列表加载失败: $error', error);
      }
    } finally {
      if (_currentUser(uid, epoch) && loadingMoreUserTab.value == key) {
        loadingMoreUserTab.value = '';
      }
    }
  }

  /// 退出登录后清空用户页缓存。
  void clearUserProfile() {
    _userEpoch++;
    _profileRequest++;
    _userId = '';
    isLoadingProfile.value = false;
    userProfile.value = null;
    profileError.value = null;
    userTabPages.clear();
    loadingUserTab.value = '';
    loadingMoreUserTab.value = '';
  }
}
