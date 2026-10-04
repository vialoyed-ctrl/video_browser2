/// Hanime1「我的 Hanime1」Tab —— 逐值复刻官网 `/user/{uid}` 手机端。
///
/// 所有数值来自**无头 Chrome 实测的 computed style**（不是手抄 CSS），
/// 对应官网 `app.css` 的 `@media (max-width:767.9px)` 分支：
/// ```
/// #playlist-headings-wrapper        padding-top:50px; background:#000;
///                                   overflow:hidden; color:#fff; position:relative
/// #playlist-headings-wrapper:before 背景 = 头像自身，blur(50px) brightness(.5)
///                                   scale(1.1) + mask 上下各 5px 渐隐
/// .profile-main-container           display:flex; align-items:flex-start; padding:15px
/// .profile-avatar-wrapper img       width:70px; height:70px; border-radius:50%
/// .profile-content-right            display:flex; flex-wrap:wrap; margin-left:15px;
///                                   flex-grow:1; min-width:0
/// .profile-display-name             25px/27.5px w700; width:100%; padding-right:15px
/// .profile-sub-stats                12px/17.14px; color:#aaa; margin:10px 0 16px;
///                                   width:100%
/// .profile-sub-stats-id             display:block; margin-top:-4px; color:#fff
/// .profile-sub-stats-new-line       display:block; w400; margin-top:1px
/// .profile-action-buttons           display:flex; gap:8px; padding:0 15px
/// .pill-btn                         padding:8px 16px; radius:18px; 14px w600;
///                                   white-space:nowrap; text-align:center
/// .pill-btn.edit-btn                background:#fff; color:#000
/// .pill-btn.dark-btn                background:hsla(0,0%,100%,.15); color:#fff
/// .user-nav-bar                     margin-top:-5px; overflow:hidden;
///                                   border-bottom:1px solid hsla(0,0%,100%,.1)
/// .nav-tabs-scroll                  display:flex; gap:24px; padding:0 15px;
///                                   overflow-x:auto
/// .yt-tab                           padding:12px 0; 15px/21.43px w600; color:#aaa
/// .yt-tab.active                    color:#fff
/// .yt-tab.active:after              position:absolute; bottom:0; left:0; right:0;
///                                   height:3px; background:#fff      ← 覆盖，不撑高
/// .yt-divider                       width:1px; height:20px;
///                                   background:hsla(0,0%,100%,.2)
/// .tab-index-rows-wrapper           padding-top:5px
/// .horizontal-row-title h3          19px w700; padding:0 10px; margin:29px 0 15px
/// .horizontal-row-title div         padding:3px 8px; 11px; color:#696969;
///                                   border:1px solid #696969; border-radius:100px;
///                                   float:right; margin-top:1px
/// .home-row.horizontal-row          grid-template-columns:repeat(2,1fr);
///                                   gap:17px 7px; padding:0 7px; margin:0 0 10px
/// ```
///
/// **手机端只有两个动作按钮可见**（这条最容易做错）：
/// `個人中心` / `訂閱內容` / `上傳影片` 都带 `hidden-xs`（`display:none`），
/// 实测只剩 `帳戶設定`（白底黑字）和 `分享`（白 15% 透明底白字），各占 50% 宽。
///
/// 视频横排**直接复用** [Hanime1CardH] —— 官网这一页用的就是首页/搜索页同一个
/// `.horizontal-card`，实测 2 列、`gap:17px 7px`，与 [Hanime1VideoGridSliver] 一致。
library;

import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../widgets/pull_to_next_page.dart';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/hanime1_models.dart';
import '../../../data/models/video_item.dart';
import '../../../routes/app_navigator.dart';
import '../../../services/hanime1_auth_service.dart';
import '../../../widgets/app_toast.dart';
import '../hanime1_controller.dart';
import '../widgets/hanime1_card_h.dart';
import '../widgets/hanime1_pagination.dart';

class Hanime1ProfileTab extends StatefulWidget {
  const Hanime1ProfileTab({super.key, required this.onSwitchTo91});

  /// 「切回 91 影視版面」—— 放在「帳戶設定」弹层里，保持入口不丢。
  final VoidCallback onSwitchTo91;

  @override
  State<Hanime1ProfileTab> createState() => _Hanime1ProfileTabState();
}

class _Hanime1ProfileTabState extends State<Hanime1ProfileTab> {
  // ---------------- 官网实测常量（移动端断点） ----------------

  /// `#playlist-headings-wrapper { padding-top: 50px }`
  static const double _headerTopPad = 50;

  /// `.profile-main-container { padding: 15px }`，底边收 5px 顶掉
  /// `.user-nav-bar { margin-top: -5px }`（Flutter 没有负 margin，用减 padding
  /// 达到同样的重叠效果，渲染结果一致）。
  static const EdgeInsets _profilePad = EdgeInsets.fromLTRB(15, 15, 15, 10);

  /// `.profile-avatar-wrapper img { width:70px; height:70px; border-radius:50% }`
  static const double _avatarSize = 70;

  /// `.profile-content-right { margin-left: 15px }`
  static const double _avatarGap = 15;

  /// `.pill-btn { border-radius: 18px }`
  static const double _pillRadius = 18;

  /// `.pill-btn.dark-btn { background: hsla(0,0%,100%,.15) }`

  /// `.yt-tab { color: #aaa }`（未激活）

  /// `.profile-sub-stats { color: #aaa }`

  /// `.horizontal-row-title div { color/border: #696969 }`

  /// `.yt-divider / .user-nav-bar { border-color: hsla(0,0%,100%,.1~.2) }`

  /// 官网 `/user/{uid}` 的 7 个 Tab（顺序照抄，`active` 由当前选中决定）。
  static const List<String> _tabs = <String>[
    '首頁',
    '觀看紀錄',
    '稍後觀看',
    '讚好的影片',
    '播放清單',
    '上傳的影片',
    '審核中的影片',
  ];

  /// 与 [_tabs] 一一对应的**官网路径尾段**，也是该 Tab 的唯一稳定标识。
  ///
  /// 为什么不能拿 [_tabs] 的文案去和官网返回的标题做等值比对：
  /// 官网对**登录用户**返回的 HTML 里标题是**简繁混排**的 —— 实测
  /// `觀看紀錄`（繁体）但 `稍后观看` / `点赞的视频` / `播放清单`（简体）。
  /// 早期实现用 `r.title == _tabs[i]` 匹配，于是 3 个 Tab 永远匹配不上、
  /// 一律显示「暫無內容」（真机日志 `rows=4 (觀看紀錄:12, 稍后观看:12,
  /// 点赞的视频:12, 播放清单:0)` 即为铁证）。
  ///
  /// 空串 = 该 Tab 在 App 内没有对应数据源（首頁是总览；最后两个是创作者后台）。
  static const List<String> _tabKeys = <String>[
    '',
    'histories',
    'saves',
    'likes',
    'playlists',
    '',
    '',
  ];

  /// 标题 → tabKey 的**别名表**，作为 [Hanime1UserRow.tabKey] 解析失败时的兜底。
  ///
  /// 覆盖官网繁体与简体两套文案（`讚好的影片` → `点赞的视频` 是**词级**替换，
  /// 不是逐字简繁转换，所以用词表而不是转换表）。
  static const Map<String, String> _rowAlias = <String, String>{
    '觀看紀錄': 'histories',
    '观看纪录': 'histories',
    '觀看記錄': 'histories',
    '稍後觀看': 'saves',
    '稍后观看': 'saves',
    '稍後觀賞': 'saves',
    '讚好的影片': 'likes',
    '点赞的视频': 'likes',
    '喜歡的影片': 'likes',
    '播放清單': 'playlists',
    '播放清单': 'playlists',
  };

  /// 分隔线在第几个 Tab 之后（官网 `.yt-divider` 位于「播放清單」之后）。
  static const int _dividerAfterIndex = 4;

  /// 0 = 首頁（4 个横排总览）；1..4 = 对应的单个横排；5/6 = 创作者分页。
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    // IndexedStack 会让本 Tab 只构建一次，所以不能只靠 switchTab 触发。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Hanime1Controller.to.loadUserProfile();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = Hanime1AuthService.to;
    final ctrl = Hanime1Controller.to;

    return Container(
      // 原来写死纯黑（注释是「官网 body 底色」）—— 那会让本页在浅色模式下
      // 与抽屉/其它页割裂。改跟随主题。
      color: context.cBg,
      child: RefreshIndicator(
        color: context.cAccent,
        backgroundColor: context.cSurface,
        onRefresh: () async {
          // 官网每个 Tab 是独立分页、各自刷新，所以下拉时只刷当前那一个；
          // 首頁是总览，刷的是整页资料。
          final key = _tabKeyAt(_activeTab);
          if (key.isEmpty) {
            await ctrl.loadUserProfile(force: true);
          } else {
            await ctrl.loadUserTab(key, force: true);
          }
        },
        child: Obx(() {
          final loggedIn = auth.isLoggedIn.value;
          final profile = ctrl.userProfile.value;

          return PullToNextPage(
            hasNext: ctrl.userTabPages[_tabKeyAt(_activeTab)]?.hasMore ?? false,
            isLoading:
                ctrl.loadingUserTab.value.isNotEmpty ||
                ctrl.loadingMoreUserTab.value.isNotEmpty,
            resetPosition: false,
            onNext: () => ctrl.loadMoreUserTab(_tabKeyAt(_activeTab)),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: <Widget>[
                // 头部（头像模糊背景 + 资料区 + Tab 条）
                SliverToBoxAdapter(
                  child: _buildHeader(
                    context,
                    loggedIn: loggedIn,
                    profile: profile,
                  ),
                ),

                // 内容区
                ..._buildContentSlivers(
                  context,
                  ctrl: ctrl,
                  profile: profile,
                  loggedIn: loggedIn,
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 28)),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ================================================================ 头部

  Widget _buildHeader(
    BuildContext context, {
    required bool loggedIn,
    required Hanime1UserProfile? profile,
  }) {
    final auth = Hanime1AuthService.to;
    final avatarUrl = profile?.avatarUrl ?? '';
    final name = loggedIn
        ? (profile?.displayName.isNotEmpty == true
              ? profile!.displayName
              : (auth.username.value.isNotEmpty
                    ? auth.username.value
                    : 'Hanime1 用戶'))
        : '未登入 Hanime1';
    final subId = loggedIn
        ? (profile?.subStatsIdText.isNotEmpty == true
              ? profile!.subStatsIdText
              : (auth.userId.value.isNotEmpty ? '@ ${auth.userId.value}' : ''))
        : '';
    final subLine = loggedIn
        ? (profile?.subStatsLineText ?? '')
        : '登入後可同步訂閱與觀看紀錄';

    return ClipRect(
      child: Stack(
        children: <Widget>[
          // 官网 `#playlist-headings-wrapper:before`：头像自身 blur(50px)
          // brightness(.5) scale(1.1) + 上下 5px 渐隐遮罩。
          Positioned.fill(child: _BlurredAvatarBackdrop(url: avatarUrl)),

          Padding(
            padding: const EdgeInsets.only(top: _headerTopPad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // ---------------- .profile-main-container ----------------
                Padding(
                  padding: _profilePad,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _buildAvatar(avatarUrl, loggedIn),
                          const SizedBox(width: _avatarGap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                // h1.profile-display-name
                                Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 25,
                                    height: 27.5 / 25,
                                    fontWeight: FontWeight.w700,
                                    color: context.cOnImage,
                                  ),
                                ),
                                // .profile-sub-stats
                                const SizedBox(height: 10),
                                if (subId.isNotEmpty)
                                  Text(
                                    subId,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 17.1429 / 12,
                                      fontWeight: FontWeight.w700,
                                      color: context.cOnImage,
                                    ),
                                  ),
                                const SizedBox(height: 1),
                                Text(
                                  subLine,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 17.1429 / 12,
                                    fontWeight: FontWeight.w400,
                                    color: context.cOnImage.withValues(
                                      alpha: 0.8,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // ---------------- .profile-action-buttons ----------------
                      //
                      // 手机端只剩两个（其余带 `hidden-xs`），各占 50%。
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: loggedIn
                                ? _buildPill(
                                    label: '帳戶設定',
                                    filled: true,
                                    onTap: () => _showAccountSheet(context),
                                  )
                                : _buildPill(
                                    label: '登入',
                                    filled: true,
                                    onTap: () => _showLoginSheet(context),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildPill(
                              label: '分享',
                              filled: false,
                              onTap: () => _shareProfile(profile, auth),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ---------------- .user-nav-bar ----------------
                Container(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: context.cBorder)),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        for (int i = 0; i < _tabs.length; i++) ...<Widget>[
                          _buildTab(i),
                          const SizedBox(width: 24),
                          if (i == _dividerAfterIndex)
                            Container(
                              width: 1,
                              height: 20,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              color: context.cBorder,
                            ),
                          if (i == _dividerAfterIndex)
                            const SizedBox(width: 24),
                        ],
                        // 末尾的搜索图标（官网 `.yt-tab.search-icon-tab`，点进去是
                        // `/search?query={昵称}`）。
                        InkWell(
                          onTap: () {
                            final kw =
                                loggedIn &&
                                    name.isNotEmpty &&
                                    name != '未登入 Hanime1'
                                ? name
                                : '';
                            AppNavigator.toSearch(
                              keyword: kw.isEmpty ? null : kw,
                            );
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Icon(
                              Icons.search,
                              size: 18,
                              color: context.cTextSub,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头像：官网 70×70、圆角 50%、`object-fit: cover`。
  Widget _buildAvatar(String url, bool loggedIn) {
    return SizedBox(
      width: _avatarSize,
      height: _avatarSize,
      child: ClipOval(
        child: url.isEmpty
            ? Container(
                color: context.cSurfaceAlt,
                alignment: Alignment.center,
                child: Icon(
                  loggedIn
                      ? Icons.person_rounded
                      : Icons.person_outline_rounded,
                  size: 34,
                  color: context.cTextSub,
                ),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 210, // 70dp × 3
                httpHeaders: const {'Referer': 'https://hanime1.me/'},
                placeholder: (_, _) => ColoredBox(color: context.cSurfaceAlt),
                errorWidget: (_, _, _) => Container(
                  color: context.cSurfaceAlt,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.person_rounded,
                    size: 34,
                    color: context.cTextSub,
                  ),
                ),
              ),
      ),
    );
  }

  /// `.pill-btn`：`padding:8px 16px; border-radius:18px; font-size:14px; w600`。
  ///
  /// [filled] = true → `.edit-btn` 的白底黑字；false → `.dark-btn` 的白 15% 透明底白字。
  Widget _buildPill({
    required String label,
    required bool filled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(_pillRadius),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: filled ? context.cAccentContainer : context.cSurfaceAlt,
          borderRadius: BorderRadius.circular(_pillRadius),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: filled ? context.cOnAccentContainer : context.cTextMain,
          ),
        ),
      ),
    );
  }

  /// `.yt-tab`：`padding:12px 0; 15px w600`；激活态白字 + 底部 3px 白条。
  ///
  /// 白条用 [Positioned] **覆盖**在底部，不撑高 —— 官网用的是 `:after` 绝对定位，
  /// 实测激活与未激活的 Tab 高度都是 45px，没有差 3px。
  Widget _buildTab(int index) {
    final active = index == _activeTab;
    final label = _tabs[index];

    return InkWell(
      onTap: () => _onTapTab(index),
      child: Stack(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 15,
                height: 21.4286 / 15,
                fontWeight: FontWeight.w600,
                color: active ? context.cAccent : context.cTextSub,
              ),
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 3,
              child: ColoredBox(color: context.cAccent),
            ),
        ],
      ),
    );
  }

  /// 取某个 Tab 对应的官网路径尾段（空串 = App 内无数据源）。
  static String _tabKeyAt(int index) =>
      (index >= 0 && index < _tabKeys.length) ? _tabKeys[index] : '';

  /// 把一行的标题归一成 App 侧固定文案。
  ///
  /// 官网标题简繁混排（见 [_rowAlias] 注释），直接显示会和 Tab 条打架，
  /// 所以能定位到 Tab 的一律用 [_tabs] 的文案，定位不到才用官网原文。
  static String _displayTitleFor(Hanime1UserRow row) {
    final key = row.tabKey.isNotEmpty
        ? row.tabKey
        : (_rowAlias[row.title.trim()] ?? '');
    final idx = _tabKeys.indexOf(key);
    return idx > 0 ? _tabs[idx] : row.title;
  }

  void _onTapTab(int index) {
    // 「上傳的影片」/「審核中的影片」是创作者后台分页，App 内没有对应数据源。
    if (index == 5 || index == 6) {
      AppToast.show('「${_tabs[index]}」需在官網創作者後台查看');
      return;
    }
    setState(() => _activeTab = index);

    // 官网点 Tab 是跳独立分页（每页 60 条），首屏那 12 条只是预览 ——
    // 所以切进来要真的去抓这一页，否则用户永远只看到 12 条。
    final key = _tabKeyAt(index);
    if (key.isNotEmpty) {
      Hanime1Controller.to.loadUserTab(key);
    }
  }

  // ================================================================ 内容区

  List<Widget> _buildContentSlivers(
    BuildContext context, {
    required Hanime1Controller ctrl,
    required Hanime1UserProfile? profile,
    required bool loggedIn,
  }) {
    if (!loggedIn) {
      return <Widget>[
        SliverToBoxAdapter(child: _buildHint('登入後即可查看觀看紀錄、稍後觀看與讚好的影片')),
      ];
    }

    if (ctrl.isLoadingProfile.value && profile == null) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.cTextSub,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    final err = ctrl.profileError.value;
    if (err != null && err.isNotEmpty && profile == null) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Column(
            children: <Widget>[
              _buildHint(err),
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: _buildPill(
                  label: '重試',
                  filled: true,
                  onTap: () => ctrl.loadUserProfile(force: true),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    if (profile == null) {
      return <Widget>[SliverToBoxAdapter(child: _buildHint('暫無資料'))];
    }

    // 首頁：4 个横排总览。
    //
    // 官网首屏每行只给 12 个预览，某些行还可能整行为空（官网对登录态返回的
    // HTML 不保证 4 行都有卡片）。空行用对应 Tab 的独立分页补一次 ——
    // 补齐动作由 `Hanime1Controller.loadUserProfile` 触发，这里只负责读。
    if (_activeTab == 0) {
      final slivers = <Widget>[];
      for (final row in profile.rows) {
        final items = row.items.isNotEmpty
            ? row.items
            : (ctrl.userTabPages[row.tabKey]?.items ?? const <VideoItem>[]);
        if (items.isEmpty) continue;
        slivers.add(SliverToBoxAdapter(child: _buildRowTitle(row)));
        slivers.add(Hanime1VideoGridSliver(items: items));
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 10)));
      }
      if (slivers.isEmpty) {
        slivers.add(SliverToBoxAdapter(child: _buildHint('這個帳號還沒有觀看紀錄或收藏')));
      }
      return slivers;
    }

    // 单个 Tab：官网点 Tab 是跳**独立分页**（`/user/{uid}/histories` 等，
    // 每页 60 条 + 数字分页器），首屏那 12 条只是预览。所以优先用独立分页的数据，
    // 还没拉到之前先回退首屏那一行的预览，避免用户看到闪一下空态。
    final key = _tabKeyAt(_activeTab);
    final tabPage = key.isEmpty ? null : ctrl.userTabPages[key];
    final loading = key.isNotEmpty && ctrl.loadingUserTab.value == key;
    final fallback = _rowForTab(profile, _activeTab);

    var items = tabPage?.items ?? const <VideoItem>[];
    if (items.isEmpty && !loading) {
      items = fallback?.items ?? const <VideoItem>[];
    }

    if (items.isEmpty) {
      if (loading) {
        return <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.cTextSub,
                  ),
                ),
              ),
            ),
          ),
        ];
      }
      return <Widget>[
        SliverToBoxAdapter(child: _buildHint('「${_tabs[_activeTab]}」暫無內容')),
      ];
    }

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _buildRowTitle(fallback ?? _virtualRow(key), showMore: false),
      ),
      Hanime1VideoGridSliver(items: items),
    ];
    if (key.isNotEmpty && tabPage != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: Hanime1Pagination(
            currentPage: tabPage.page,
            onNext: () => ctrl.loadMoreUserTab(key),
            hasNext: tabPage.hasMore,
            totalPages: tabPage.totalPages,
            isLoading: ctrl.loadingMoreUserTab.value == key,
            onPageChanged: (page) => ctrl.goToUserTabPage(key, page),
          ),
        ),
      );
    }
    return slivers;
  }

  /// 定位某个 Tab 对应的首屏横排。
  ///
  /// 三级兜底，缺一不可（见 [_tabKeys] / [_rowAlias] 的注释）：
  ///   1. `tabKey`（URL 尾段）—— 唯一稳定，官网改文案不受影响；
  ///   2. 标题别名表 —— 覆盖官网繁体 / 简体两套文案；
  ///   3. **位置**兜底 —— 官网首屏 4 行的顺序固定，就是 Tab 1..4。
  ///
  /// 早期实现只有「`r.title == _tabs[i]`」一级，且官网返回的标题是简体，
  /// 于是 3 个 Tab 全部落空、显示「暫無內容」。
  Hanime1UserRow? _rowForTab(Hanime1UserProfile profile, int tabIndex) {
    final key = _tabKeyAt(tabIndex);
    if (key.isEmpty) return null;

    for (final r in profile.rows) {
      if (r.tabKey == key) return r;
    }
    for (final r in profile.rows) {
      if ((_rowAlias[r.title.trim()] ?? '') == key) return r;
    }
    final idx = tabIndex - 1;
    if (idx >= 0 && idx < profile.rows.length) return profile.rows[idx];
    return null;
  }

  /// 首屏没有对应行时，造一个只用于显示标题的空行（不参与数据）。
  Hanime1UserRow _virtualRow(String key) {
    final idx = _tabKeys.indexOf(key);
    return Hanime1UserRow(
      title: idx > 0 ? _tabs[idx] : key,
      path: '',
      tabKey: key,
      items: const <VideoItem>[],
    );
  }

  /// `.horizontal-row-title`：h3（19px w700，padding 0 10，margin 29 0 15）
  /// + 右侧「更多 ›」胶囊（float:right，右边距 10）。
  Widget _buildRowTitle(Hanime1UserRow row, {bool showMore = true}) {
    return Padding(
      padding: const EdgeInsets.only(top: 29, bottom: 15),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                _displayTitleFor(row),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: context.cTextMain,
                ),
              ),
            ),
          ),
          if (showMore && row.path.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _buildMorePill(row),
            ),
        ],
      ),
    );
  }

  Widget _buildMorePill(Hanime1UserRow row) {
    return InkWell(
      borderRadius: BorderRadius.circular(100),
      onTap: () {
        // 官网跳 `/user/{uid}/histories` 这类独立分页。App 内没有对应路由，
        // 这里退化为把该行全部内容切到前台展示（与点同名 Tab 等价）。
        // 用 tabKey（URL 尾段）定位，不用标题 —— 官网标题简繁混排，比对不可靠。
        final key = row.tabKey.isNotEmpty
            ? row.tabKey
            : (_rowAlias[row.title.trim()] ?? '');
        final idx = _tabKeys.indexOf(key);
        if (idx > 0) {
          _onTapTab(idx);
        } else {
          AppToast.show('「${_displayTitleFor(row)}」需在官網查看完整列表');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: context.cTextSub),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '更多',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: context.cTextSub,
              ),
            ),
            SizedBox(width: 1),
            Icon(Icons.arrow_forward_ios, size: 12, color: context.cTextSub),
          ],
        ),
      ),
    );
  }

  Widget _buildHint(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: context.cTextSub),
        ),
      ),
    );
  }

  // ================================================================ 交互

  void _shareProfile(Hanime1UserProfile? profile, Hanime1AuthService auth) {
    final uid = profile?.userId.isNotEmpty == true
        ? profile!.userId
        : auth.userId.value;
    final url = uid.isEmpty
        ? 'https://hanime1.me/'
        : 'https://hanime1.me/user/$uid';
    Clipboard.setData(ClipboardData(text: url));
    AppToast.show('已複製個人主頁連結：$url');
  }

  /// 「帳戶設定」。
  ///
  /// 官网是 `/user/{uid}/edit` 编辑页；App 内没有资料编辑能力，所以这里给一个
  /// 只读的帳戶資訊 + 登出 + 版面切换的弹层，保证按钮「有作用」。
  void _showAccountSheet(BuildContext context) {
    final auth = Hanime1AuthService.to;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.cSurfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 14),
            Text(
              '帳戶設定',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: context.cTextMain,
              ),
            ),
            const SizedBox(height: 12),
            _sheetRow('暱稱', auth.username.value),
            _sheetRow('UID', auth.userId.value),
            _sheetRow('電郵', auth.userEmail.value),
            Divider(height: 20, color: context.cBorder),
            ListTile(
              leading: Icon(Icons.swap_horiz_rounded, color: context.cTextSub),
              title: Text(
                '切回 91 影視版面',
                style: TextStyle(fontSize: 14, color: context.cTextMain),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onSwitchTo91();
              },
            ),
            ListTile(
              leading: Icon(Icons.logout_rounded, color: context.cAccent),
              title: Text(
                '登出',
                style: TextStyle(fontSize: 14, color: context.cAccent),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                await auth.logout();
                Hanime1Controller.to.clearUserProfile();
                AppToast.show('已登出 Hanime1');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _sheetRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 54,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: context.cTextSub),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: context.cTextMain),
            ),
          ),
        ],
      ),
    );
  }

  /// 未登入时的登入入口。
  void _showLoginSheet(BuildContext context) {
    final emailCtrl = TextEditingController(
      text: Hanime1AuthService.to.userEmail.value,
    );
    final pwdCtrl = TextEditingController();
    final busy = false.obs;
    final errMsg = ''.obs;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cSurfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 18,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Obx(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '登入 Hanime1',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: context.cTextMain,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '登入後可同步訂閱、觀看紀錄與收藏。',
                style: TextStyle(fontSize: 12, color: context.cTextSub),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(fontSize: 14, color: context.cTextMain),
                decoration: _inputDecoration('電郵地址'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pwdCtrl,
                obscureText: true,
                style: TextStyle(fontSize: 14, color: context.cTextMain),
                decoration: _inputDecoration('密碼'),
              ),
              if (errMsg.value.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  errMsg.value,
                  style: TextStyle(fontSize: 12, color: context.cAccent),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: _buildPill(
                  label: busy.value ? '登入中…' : '登入',
                  filled: true,
                  onTap: () async {
                    if (busy.value) return;
                    final email = emailCtrl.text.trim();
                    final pwd = pwdCtrl.text.trim();
                    if (email.isEmpty || pwd.isEmpty) {
                      errMsg.value = '請輸入電郵與密碼';
                      return;
                    }
                    busy.value = true;
                    errMsg.value = '';
                    final ok = await Hanime1AuthService.to.login(email, pwd);
                    busy.value = false;
                    if (ok) {
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      AppToast.show(
                        '登入成功：${Hanime1AuthService.to.username.value}',
                      );
                      Hanime1Controller.to
                        ..loadSubscriptions()
                        ..loadUserProfile(force: true)
                        ..loadHomeData();
                    } else {
                      errMsg.value = '登入失敗，請檢查帳號密碼或網路';
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: context.cTextSub),
      isDense: true,
      filled: true,
      fillColor: context.cSurfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    );
  }
}

/// 官网 `#playlist-headings-wrapper:before` 的头像模糊背景。
///
/// ```css
/// background-image: var(--avatar-url); background-size: cover;
/// filter: blur(50px) brightness(.5); transform: scale(1.1);
/// mask-image: linear-gradient(180deg,#000 0,#000 50%,transparent);
/// ```
/// CSS 的 `blur(50px)` 半径对应高斯 sigma ≈ 50/2 = 25，所以这里用 25。
/// `brightness(.5)` 用一层 50% 黑覆盖来等效。
class _BlurredAvatarBackdrop extends StatelessWidget {
  const _BlurredAvatarBackdrop({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return const ColoredBox(color: Color(0xFF000000));
    }

    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight.isFinite && c.maxHeight > 20
            ? c.maxHeight
            : 240.0;
        // mask: transparent 0 → black 5px → black (100%-5px) → transparent 100%
        final stops = <double>[
          0,
          (5 / h).clamp(0.0, 1.0),
          ((h - 5) / h).clamp(0.0, 1.0),
          1,
        ];

        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const <Color>[
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: stops,
          ).createShader(rect),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Transform.scale(
                scale: 1.1, // transform: scale(1.1)
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    memCacheWidth: 240,
                    httpHeaders: const {'Referer': 'https://hanime1.me/'},
                    placeholder: (_, _) =>
                        const ColoredBox(color: Color(0xFF000000)),
                    errorWidget: (_, _, _) =>
                        const ColoredBox(color: Color(0xFF000000)),
                  ),
                ),
              ),
              // 压暗层：原来是一层固定 50% 黑（对应官网 `brightness(.5)`）。
              // 但头像本身若是浅色（默认头像就是浅灰），50% 之后仍是中灰 ——
              // 白字压在中灰上对比度不足，实测就是「头部文字看不清」。
              // 改成上浅下深的渐变：文字所在的中下部压到 65%~80%。
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x73000000),
                      Color(0xA6000000),
                      Color(0xCC000000),
                    ],
                    stops: <double>[0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
