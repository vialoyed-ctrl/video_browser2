/// 搜索视图：100% 对齐 91PORNY 官方网页多维检索、用户提取与结果分页。
///
/// 特性：
/// 1. 单一搜索框，统一检索用户与视频；
/// 2. 官网 5 大筛选维度完整呈现（排序、选择分类[除论坛]、发布时间、播放量、视频长度），样式与交互严丝合缝；
/// 3. “搜索到用户”红底数字徽标卡片（如「小郎君 [4]」），点击直达作者作品与关注；
/// 4. 视频标题动态跟随选定分类（如「搜索到视频 蝌蚪」）；
/// 5. 官方标准紧凑分页控制器（« 1 2 3 ... 15 16 »）与跳页快捷框；
/// 6. 深度适配深色与浅色模式，保证全界面高对比度与清晰度。
library;

import '../../widgets/pull_to_next_page.dart';
import '../../widgets/append_pagination_footer.dart';

import 'package:flutter/material.dart' hide SearchController;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:get/get.dart';

import '../../core/app_logger.dart';
import '../../core/app_theme.dart';
import '../../core/responsive_utils.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_navigator.dart';
import '../../services/download_service.dart';
import '../../services/user_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/bili_video_card.dart';
import '../../widgets/common.dart';
import '../hanime1/widgets/hanime1_card.dart';
import '../hanime1/hanime1_controller.dart';
import 'hanime1_tag_picker.dart';
import 'hanime1_search_filter_sheet.dart';
import 'search_controller.dart';

class SearchView extends StatefulWidget {
  const SearchView({super.key, this.searchController});

  final SearchController? searchController;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _Hanime1PinnedHeader extends SliverPersistentHeaderDelegate {
  const _Hanime1PinnedHeader({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(covariant _Hanime1PinnedHeader oldDelegate) =>
      height != oldDelegate.height || child != oldDelegate.child;
}

class _Hanime1FilterChip extends StatelessWidget {
  const _Hanime1FilterChip({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
          border: Border.all(color: context.cBorder, width: 0.8),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: context.cTextMain,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.keyboard_arrow_down, size: 13, color: context.cTextMain),
          ],
        ),
      ),
    );
  }
}

class _Hanime1SearchChip extends StatelessWidget {
  const _Hanime1SearchChip({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
          border: Border.all(color: context.cBorder, width: 0.8),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: context.cTextMain,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.grid_view_rounded, size: 13, color: context.cTextMain),
          ],
        ),
      ),
    );
  }
}

class _Hanime1StudioGridSliver extends StatelessWidget {
  const _Hanime1StudioGridSliver({
    required this.items,
    required this.onTapItem,
  });

  final List<VideoItem> items;
  final ValueChanged<VideoItem> onTapItem;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 7,
          mainAxisSpacing: 10,
          childAspectRatio: 0.77,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = items[index];
          return InkWell(
            onTap: () => onTapItem(item),
            borderRadius: BorderRadius.circular(3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: ColoredBox(
                      color: context.cImagePlaceholder,
                      child: item.thumbnailUrl == null
                          ? Icon(
                              Icons.business,
                              color: context.cTextFaint,
                              size: 34,
                            )
                          : CachedNetworkImage(
                              imageUrl: item.thumbnailUrl!,
                              fit: BoxFit.contain,
                              placeholder: (_, _) =>
                                  ColoredBox(color: context.cImagePlaceholder),
                              errorWidget: (_, _, _) => Icon(
                                Icons.business,
                                color: context.cTextFaint,
                                size: 34,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.cTextMain,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.viewsStr ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.cTextSub,
                    fontSize: 9.5,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          );
        }, childCount: items.length),
      ),
    );
  }
}

class _SearchViewState extends State<SearchView> {
  late final SearchController controller;
  late final bool _isOwnedController;

  @override
  void initState() {
    super.initState();
    if (widget.searchController != null) {
      controller = widget.searchController!;
      _isOwnedController = true;
      controller.loadHotSearches();
    } else {
      if (!Get.isRegistered<SearchController>()) {
        Get.lazyPut<SearchController>(
          () => SearchController(SourceRegistry.defaultSource),
          fenix: true,
        );
      }
      controller = Get.find<SearchController>();
      _isOwnedController = false;
    }
    if (controller.isHanime1 &&
        !controller.hasSearched.value &&
        !controller.loading.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            controller.isHanime1 &&
            !controller.hasSearched.value &&
            !controller.loading.value) {
          controller.runSearch(allowEmptyHanime1: true);
        }
      });
    }
  }

  @override
  void dispose() {
    if (_isOwnedController) {
      controller.onClose();
    }
    super.dispose();
  }

  /// 跳页的**统一入口** —— 所有会改变页码的交互都必须走这里。
  ///
  void _goToPage(int page) {
    FocusManager.instance.primaryFocus?.unfocus();
    controller.goToPage(page);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: controller.isHanime1
          ? context.cBg
          : theme.scaffoldBackgroundColor,
      body: controller.isHanime1
          ? _buildHanime1Search(context)
          : Obx(() {
              final hasKeyword = controller.keyword.value.isNotEmpty;
              final hasSearched = controller.hasSearched.value;
              final isLoading = controller.loading.value;
              final error = controller.error.value;
              final results = controller.results;
              final users = controller.searchedUsers;
              final author = controller.selectedAuthor.value;

              return PullToNextPage(
                hasNext:
                    controller.currentPage.value < controller.totalPages.value,
                isLoading:
                    controller.loading.value || controller.pageLoading.value,
                onNext: () => controller.goToPage(
                  controller.currentPage.value + 1,
                  append: true,
                ),
                child: CustomScrollView(
                  controller: controller.scroll,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    // 1. 顶部统一搜索栏
                    SliverAppBar(
                      pinned: true,
                      floating: true,
                      snap: false,
                      titleSpacing: 8,
                      title: _buildSearchField(context),
                      actions: <Widget>[
                        Obx(() {
                          if (controller.hasAnyCondition) {
                            return IconButton(
                              tooltip: '清空条件',
                              onPressed: controller.resetAll,
                              icon: const Icon(Icons.refresh),
                            );
                          }
                          return const SizedBox.shrink();
                        }),
                      ],
                    ),

                    // 2. 官方 5 维筛选卡片（排序、选择分类、发布时间、播放量、视频长度）
                    SliverToBoxAdapter(
                      child: _buildOfficialFilterCard(context),
                    ),

                    // 3. 作者专栏激活提示栏（若点击了搜索到的用户）
                    if (author != null)
                      SliverToBoxAdapter(
                        child: _buildAuthorActiveBanner(context, author),
                      ),

                    // 4. 内容与状态分支展示
                    if (error != null && results.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: ErrorView(
                          message: error,
                          onRetry: controller.runSearch,
                        ),
                      )
                    else if (!hasKeyword && !hasSearched && author == null)
                      SliverToBoxAdapter(child: _buildInitialGuideView(context))
                    else if (isLoading)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: LoadingView(message: '正在检索官网内容…'),
                      )
                    else if (results.isEmpty && users.isEmpty && author == null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyView(
                          message: '没有匹配「${controller.keyword.value}」的结果',
                          icon: Icons.search_off_outlined,
                          actionLabel: '重置筛选',
                          onAction: controller.resetAll,
                        ),
                      )
                    else ...[
                      // 4.1 汇总信息条（如：“66” 的搜索结果共计380个视频，第1/16页）
                      if (controller.summaryText.value != null &&
                          controller.summaryText.value!.isNotEmpty &&
                          author == null)
                        SliverToBoxAdapter(
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 4,
                            ),
                            padding: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: context.cBorder,
                                  width: 0.8,
                                ),
                              ),
                            ),
                            child: Text(
                              controller.summaryText.value!,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),

                      // 4.2 搜索到用户模块（带有官方红底数量徽标）
                      if (users.isNotEmpty && author == null)
                        SliverToBoxAdapter(
                          child: _buildSearchedUsersSection(context, users),
                        ),

                      // 4.3 搜索到视频标题（动态携带分类名，如「搜索到视频 蝌蚪」）
                      if (results.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                            child: Row(
                              children: [
                                Text(
                                  author != null
                                      ? '作者全部作品'
                                      : (controller
                                                .currentCategoryLabel
                                                .isNotEmpty
                                            ? '搜索到视频 ${controller.currentCategoryLabel}'
                                            : '搜索到视频'),
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (controller.totalItems.value > 0)
                                  Text(
                                    '(${controller.totalItems.value})',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),

                      // 4.4 分页条 —— hanime1 官网手机端把它放在列表【上方】
                      //
                      // 官网实测的 DOM 顺序是：
                      //   `#home-rows-wrapper` → 顶部广告位 → `.search-pagination`
                      //   `.mobile-search-pagination.hidden-sm.hidden-md.hidden-lg`
                      //   → 59 张卡片 → 「跳页条」
                      // 也就是说**手机端分页条在列表上方**，列表下方那条是跳页条
                      // （见 [_buildHanime1SkipBar]）。桌面端（≥768px）才反过来。
                      // 91 保持原样：分页栏在列表下方，且不带跳页条。
                      if (controller.isHanime1 && results.isNotEmpty)
                        SliverToBoxAdapter(child: const SizedBox.shrink()),

                      // 4.5 视频流
                      //
                      // Hanime1 官网搜索结果用的是**同一个** `.horizontal-card` 组件
                      // （首页也是它），外层 `.horizontal-row` 在移动端断点是
                      // `grid-template-columns: repeat(2,1fr); gap: 17px 7px`，
                      // 所以走 Hanime1VideoGridSliver（2 列、行高自适应）。
                      // 91 那边是多列竖向网格，保持 BiliVideoCardV。
                      if (controller.isHanime1)
                        // 只有 里番 / 泡面番 / 新番预告 三类用 3 列竖版海报卡
                        // （封面 3:4 + 标题 + 作者，「新番預告」另带日期角标）；
                        // 其余类型保持原来的 2 列横版 `.horizontal-card`。
                        _hanime1UsesPosterGrid(controller)
                            ? Hanime1PosterGridSliver(
                                items: results.toList(growable: false),
                              )
                            : Hanime1VideoGridSliver(
                                items: results.toList(growable: false),
                              )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          sliver: Builder(
                            builder: (context) {
                              final screenWidth = MediaQuery.sizeOf(context)
                                  .width;
                              final columnCount =
                                  ResponsiveLayout.gridColumnCount(screenWidth);
                              final columnWidth =
                                  (screenWidth - 16 - (columnCount - 1) * 6) /
                                  columnCount;
                              final childAspectRatio =
                                  ResponsiveLayout.cardAspectRatio(columnWidth);

                              return SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columnCount,
                                      crossAxisSpacing: 6,
                                      mainAxisSpacing: 6,
                                      childAspectRatio: childAspectRatio,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final video = results[index];
                                  return BiliVideoCardV(
                                    video: video,
                                    onTap: () => AppNavigator.toPlayer(video),
                                    onDownload: () => _enqueue(video),
                                  );
                                }, childCount: results.length),
                              );
                            },
                          ),
                        ),

                      // 4.6 底部控件
                      //
                      // hanime1 是官网那条「跳页条」（上一頁 / 页码输入框 / 下一頁），
                      // 列表下方才有；91 保持原有卡片式分页栏不动。
                      if (results.isNotEmpty)
                        SliverToBoxAdapter(
                          child: controller.isHanime1
                              ? _buildPaginationBar(context)
                              : _buildPaginationBar(context),
                        )
                      else
                        const SliverToBoxAdapter(child: SizedBox(height: 32)),
                    ],
                  ],
                ),
              );
            }),
    );
  }

  /// Hanime1 的搜索页使用官网手机端结构；91 继续沿用下方原搜索视图。
  Widget _buildHanime1Search(BuildContext context) {
    return Obx(() {
      final results = controller.results;
      final isLoading = controller.loading.value;
      final error = controller.error.value;
      final hasKeyword = controller.keyword.value.trim().isNotEmpty;
      final hasSearched = controller.hasSearched.value;
      final artistDirectory =
          controller.searchType.value == SearchType.authorId;

      return PullToNextPage(
        hasNext: controller.currentPage.value < controller.totalPages.value,
        isLoading: controller.loading.value || controller.pageLoading.value,
        onNext: () =>
            controller.goToPage(controller.currentPage.value + 1, append: true),
        child: CustomScrollView(
          controller: controller.scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverAppBar(
              pinned: true,
              floating: false,
              automaticallyImplyLeading: false,
              toolbarHeight: 44,
              collapsedHeight: 44,
              titleSpacing: 0,
              backgroundColor: context.cBg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              title: _buildHanime1Header(context),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _Hanime1PinnedHeader(
                height: 40,
                child: _buildHanime1FilterBar(context),
              ),
            ),
            if (controller.pageLoading.value)
              SliverToBoxAdapter(
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: context.cAccent,
                  backgroundColor: context.cSurfaceAlt,
                ),
              ),
            if (error != null && results.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorView(
                  message: error,
                  onRetry: () => controller.runSearch(allowEmptyHanime1: true),
                ),
              )
            else if (isLoading || (!hasKeyword && !hasSearched))
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: CircularProgressIndicator(color: context.cAccent),
                ),
              )
            else if (results.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(
                  message: artistDirectory ? '沒有找到符合條件的制作方' : '沒有找到符合條件的影片',
                  icon: Icons.search_off_rounded,
                  actionLabel: '重設篩選',
                  onAction: controller.resetAll,
                ),
              )
            else ...[
              if (controller.totalPages.value > 1)
                SliverToBoxAdapter(child: const SizedBox.shrink()),
              if (artistDirectory)
                _Hanime1StudioGridSliver(
                  items: results.toList(growable: false),
                  onTapItem: (studio) =>
                      controller.searchVideosForArtist(studio.title),
                )
              // 只有 里番 / 泡面番 / 新番预告 三类用 3 列竖版海报卡
              // （封面 3:4 + 标题 + 作者，「新番預告」另带日期角标）；
              // 其余类型保持原来的 2 列横版 `.horizontal-card`。
              else if (_hanime1UsesPosterGrid(controller))
                Hanime1PosterGridSliver(items: results.toList(growable: false))
              else
                Hanime1VideoGridSliver(items: results.toList(growable: false)),
              if (controller.totalPages.value > 1)
                SliverToBoxAdapter(child: _buildPaginationBar(context)),
            ],
          ],
        ),
      );
    });
  }

  Widget _buildHanime1Header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 9, 0),
      child: Row(
        children: [
          Text(
            'H',
            style: TextStyle(
              color: context.cAccent,
              fontSize: 23,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 31,
              child: TextField(
                controller: controller.input,
                focusNode: controller.focusNode,
                onChanged: controller.onKeywordChanged,
                onSubmitted: (_) => controller.submit(),
                textInputAction: TextInputAction.search,
                style: TextStyle(fontSize: 12, color: context.cTextMain),
                cursorColor: context.cAccent,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: context.cSurfaceAlt,
                  hintText: '搜索 Hanime1.me',
                  hintStyle: TextStyle(fontSize: 12, color: context.cTextSub),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: context.cTextSub,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  suffixIcon: controller.keyword.value.isEmpty
                      ? null
                      : IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          icon: Icon(
                            Icons.close,
                            size: 15,
                            color: context.cTextFaint,
                          ),
                          onPressed: controller.clearKeyword,
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(3),
            onTap: _openHanime1Profile,
            child: SizedBox(
              width: 24,
              height: 28,
              child: Icon(
                Icons.account_box,
                color: context.cTextMain,
                size: 21,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openHanime1Profile() {
    if (!Get.isRegistered<Hanime1Controller>()) return;
    final hanime = Hanime1Controller.to;
    if (Get.key.currentState?.canPop() == true) Get.back<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => hanime.switchTab(3));
  }

  /// 官网对这三类**用 3 列竖版海报卡**展示搜索结果，其余类型保持原来的
  /// 2 列横版 `.horizontal-card`（用户明确要求）。
  ///
  /// 同时收录简繁两种写法：官网站内是繁体（裏番 / 泡麵番 / 新番預告），
  /// 而 App 的筛选面板里是简体（里番 / 泡面番 / 新番预告）。
  static const Set<String> _posterGenres = <String>{
    '里番',
    '泡面番',
    '新番预告',
    '裏番',
    '泡麵番',
    '新番預告',
  };

  bool _hanime1UsesPosterGrid(SearchController controller) {
    final g = controller.category.value.trim();
    final hit = _posterGenres.contains(g);
    // 临时诊断：确认实际取到的值到底是什么（简繁 / 空白 / 其它）。
    AppLogger.i('Search', '海报网格判定: category="$g" → $hit');
    return hit;
  }

  Widget _buildHanime1FilterBar(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.cBg,
        border: Border(bottom: BorderSide(color: context.cBorder)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          children: [
            _hanime1FilterChip('genre'),
            if (controller.searchType.value != SearchType.authorId) ...[
              const SizedBox(width: 6),
              _hanime1FilterChip('tags'),
            ],
            const SizedBox(width: 6),
            _hanime1FilterChip('sort'),
            if (controller.searchType.value != SearchType.authorId) ...[
              const SizedBox(width: 6),
              _hanime1FilterChip('date'),
            ],
            const SizedBox(width: 6),
            _hanime1FilterChip('duration'),
            const SizedBox(width: 6),
            _Hanime1SearchChip(
              label: controller.searchType.value == SearchType.authorId
                  ? '搜索影片'
                  : '搜索作者',
              onPressed: controller.toggleHanime1ArtistDirectory,
            ),
          ],
        ),
      ),
    );
  }

  Widget _hanime1FilterChip(String key) {
    final (caption, value, options, title) = switch (key) {
      'genre' => (
        '全部类型',
        controller.category.value,
        controller.activeCategoryOptions,
        '影片类型',
      ),
      'tags' => ('标签', '', const <(String, String)>[], '内容标签'),
      'sort' => (
        '排序方式',
        controller.sortFilter.value,
        controller.activeSortOptions,
        '排序方式',
      ),
      'date' => (
        '发布日期',
        _hanime1DateChipLabel(),
        controller.activeTimeOptions,
        '发布日期',
      ),
      _ => (
        '时长',
        controller.durationFilter.value,
        controller.activeDurationOptions,
        '时长',
      ),
    };
    var label = caption;
    if (key != 'tags' && value.isNotEmpty) {
      for (final option in options) {
        if (option.$2 == value) {
          label = _hanime1Simplified(option.$1);
          break;
        }
      }
      if (key == 'date' &&
          (controller.dateYear.value.isNotEmpty ||
              controller.dateMonth.value.isNotEmpty)) {
        label = value;
      }
    }
    return _Hanime1FilterChip(
      label: label,
      onPressed: () => _openHanime1Filter(key, title, options),
    );
  }

  String _hanime1DateChipLabel() {
    final year = controller.dateYear.value;
    final month = controller.dateMonth.value;
    if (year.isNotEmpty || month.isNotEmpty) {
      return '$year $month'.trim();
    }
    return controller.time.value;
  }

  Future<void> _openHanime1Filter(
    String key,
    String title,
    List<(String, String)> options,
  ) async {
    if (key == 'tags') {
      await showHanime1TagPicker(context, controller);
      return;
    }
    final selected = switch (key) {
      'genre' => controller.category.value,
      'sort' => controller.sortFilter.value,
      'date' => controller.time.value,
      _ => controller.durationFilter.value,
    };
    final selection = await showHanime1SearchFilterSheet(
      context: context,
      title: title,
      options: options
          .map((option) => (_hanime1Simplified(option.$1), option.$2))
          .toList(growable: false),
      selected: selected,
      selectedYear: controller.dateYear.value,
      selectedMonth: controller.dateMonth.value,
      showDateParts: key == 'date',
    );
    if (!mounted || selection == null) return;
    controller.applyHanime1Filters(
      sort: key == 'sort' ? selection.value : null,
      genre: key == 'genre' ? selection.value : null,
      date: key == 'date' ? selection.value : null,
      year: key == 'date' ? selection.year : null,
      month: key == 'date' ? selection.month : null,
      duration: key == 'duration' ? selection.value : null,
    );
  }

  String _hanime1Simplified(String text) =>
      const <String, String>{
        '裏番': '里番',
        '泡麵番': '泡面番',
        '2D動畫': '2D动画',
        '新番預告': '新番预告',
        'H漫畫': 'H漫画',
        '最新上傳': '最新上传',
        '本週排行': '本周排行',
        '本月排行': '本月排行',
        '觀看次數': '观看次数',
        '讚好比例': '点赞比例',
        '時長最長': '时长最长',
        '他們在看': '他们在看',
        '過去 24 小時': '过去 24 小时',
        '過去 2 天': '过去 2 天',
        '過去 1 週': '过去 1 周',
        '過去 1 個月': '过去 1 个月',
        '過去 3 個月': '过去 3 个月',
        '過去 1 年': '过去 1 年',
        '1 分鐘 +': '1 分钟 +',
        '5 分鐘 +': '5 分钟 +',
        '10 分鐘 +': '10 分钟 +',
        '20 分鐘 +': '20 分钟 +',
        '30 分鐘 +': '30 分钟 +',
        '60 分鐘 +': '60 分钟 +',
        '0 - 10 分鐘': '0 - 10 分钟',
        '0 - 20 分鐘': '0 - 20 分钟',
      }[text] ??
      text;

  /// 顶部搜索输入框
  Widget _buildSearchField(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 42,
      child: Obx(
        () => TextField(
          controller: controller.input,
          focusNode: controller.focusNode,
          onChanged: controller.onKeywordChanged,
          onSubmitted: (_) => controller.submit(),
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: '搜索视频名称、用户或关键词',
            hintStyle: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            prefixIcon: Icon(
              Icons.search,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 0),
            suffixIcon: controller.keyword.value.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: controller.clearKeyword,
                  ),
          ),
        ),
      ),
    );
  }

  /// 官方 5 维筛选面板（排序、选择分类[除论坛]、发布时间、播放量、视频长度）
  Widget _buildOfficialFilterCard(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.cSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.cBorder, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 排序方式
          _buildFilterRow(
            context,
            label: controller.isHanime1 ? '排序方式' : '排序',
            options: controller.activeSortOptions,
            currentValue: controller.sortFilter.value,
            onSelected: controller.setSortFilter,
          ),
          const SizedBox(height: 10),

          // 2. 全部類型 / 选择分类
          _buildFilterRow(
            context,
            label: controller.isHanime1 ? '全部類型' : '选择分类',
            options: controller.activeCategoryOptions,
            currentValue: controller.category.value,
            onSelected: controller.setCategory,
          ),
          const SizedBox(height: 10),

          // 3. 發佈日期 / 发布时间
          _buildFilterRow(
            context,
            label: controller.isHanime1 ? '發佈日期' : '发布时间',
            options: controller.activeTimeOptions,
            currentValue: controller.time.value,
            onSelected: controller.setTime,
          ),
          const SizedBox(height: 10),

          // 4. Hanime1 用「標籤」维度（官网 240 项 checkbox 多选，tags[] 参数），
          //    其余源用「播放量」
          if (controller.isHanime1)
            _buildTagFilterRow(context)
          else
            _buildFilterRow(
              context,
              label: '播放量',
              options: SearchController.viewsOptions,
              currentValue: controller.viewsFilter.value,
              onSelected: controller.setViewsFilter,
            ),
          const SizedBox(height: 10),

          // 5. 時長 / 视频长度
          _buildFilterRow(
            context,
            label: controller.isHanime1 ? '時長' : '视频长度',
            options: controller.activeDurationOptions,
            currentValue: controller.durationFilter.value,
            onSelected: controller.setDurationFilter,
          ),
        ],
      ),
    );
  }

  /// 单行筛选条件组（标签 + 选项按钮）
  Widget _buildFilterRow(
    BuildContext context, {
    required String label,
    required List<(String, String)> options,
    required String currentValue,
    required ValueChanged<String> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: context.cTextSub,
            ),
          ),
        ),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: options.map((opt) {
            final optLabel = opt.$1;
            final optVal = opt.$2;
            final isSelected = currentValue == optVal;
            return _buildFilterButton(
              context,
              label: optLabel,
              isSelected: isSelected,
              onTap: () => onSelected(optVal),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// 官方风格单项筛选按钮（对齐 Bootstrap btn-secondary 与 btn-outline-secondary）
  Widget _buildFilterButton(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    // 选中态背景与边框：主色高亮；未选中态：灰框线白底/暗黑底
    final activeBg = theme.colorScheme.primary;
    final activeBorder = theme.colorScheme.primary;
    final inactiveBg = context.cSurface;
    final inactiveBorder = context.cBorder;
    final inactiveTextColor = context.cTextSub;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
        decoration: BoxDecoration(
          color: isSelected ? activeBg : inactiveBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isSelected ? activeBorder : inactiveBorder,
            width: 0.9,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? context.scheme.onPrimary : inactiveTextColor,
          ),
        ),
      ),
    );
  }

  /// 「標籤」筛选行（Hanime1 专属）。
  ///
  /// 官网是 **240 项** checkbox 多选（收在 `#tags` 弹窗里，标题「內容標籤」）。
  /// 240 个胶囊平铺在搜索页会把页面撑爆，所以这里同样只放一个入口按钮，
  /// 外加已选标签的快捷预览（点一下就取消，不必再进弹窗）。
  Widget _buildTagFilterRow(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '標籤',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: context.cTextSub,
            ),
          ),
        ),
        Obx(() {
          final selected = controller.tagFilter.toList(growable: false);
          return Wrap(
            spacing: 7,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildFilterButton(
                context,
                label: selected.isEmpty ? '選擇標籤' : '選擇標籤（${selected.length}）',
                isSelected: selected.isNotEmpty,
                onTap: () => showHanime1TagPicker(context, controller),
              ),
              // 已选标签：最多预览 8 个，点一下即取消
              for (final t in selected.take(8)) _buildSelectedTagChip(t),
              if (selected.length > 8)
                Text(
                  '+${selected.length - 8}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (selected.isNotEmpty)
                TextButton(
                  onPressed: () {
                    controller.clearTagFilter();
                    controller.applyTagFilter();
                  },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('清除', style: TextStyle(fontSize: 12)),
                ),
            ],
          );
        }),
      ],
    );
  }

  /// 已选标签胶囊（官网 `.checkmark` 的选中态：底色 #dc143c）。
  Widget _buildSelectedTagChip(String tag) {
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: () {
        controller.toggleTag(tag);
        controller.applyTagFilter();
      },
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: context.cAccent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: TextStyle(fontSize: 11.5, color: context.scheme.onPrimary),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.close,
              size: 12,
              color: context.scheme.onPrimary.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  /// “搜索到用户”模块（带有官方红底数量徽标）
  Widget _buildSearchedUsersSection(
    BuildContext context,
    List<SearchedUser> users,
  ) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '搜索到用户',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(${users.length}) 点击查看作品',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: users.map((u) => _buildUserCard(context, u)).toList(),
          ),
        ],
      ),
    );
  }

  /// 搜索到的单个用户徽标（还原红底数量胶囊）
  Widget _buildUserCard(BuildContext context, SearchedUser user) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () => controller.selectAuthor(user),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
          border: Border.all(color: context.cBorder, width: 0.9),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              user.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cTextMain,
              ),
            ),
            if (user.count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary, // 官方主题色徽章
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${user.count}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 作者专属专栏激活提示条（包含作者关注与返回按钮）
  Widget _buildAuthorActiveBanner(BuildContext context, SearchedUser author) {
    final theme = Theme.of(context);
    final authorName = author.name;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.cWarningSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.cWarningBorder, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.account_circle, size: 20, color: context.cAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前查看作者专栏：$authorName',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: context.cOnWarningSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),

          // 快捷关注按钮
          Obx(() {
            final isSubscribed = UserService.to.isSubscribed(authorName);
            return OutlinedButton.icon(
              onPressed: () {
                UserService.to.toggleSubscription(authorName);
                final isNow = UserService.to.isSubscribed(authorName);
                AppToast.show(
                  isNow ? '已关注作者：$authorName' : '已取消关注：$authorName',
                );
              },
              icon: Icon(
                isSubscribed ? Icons.check : Icons.add,
                size: 14,
                color: isSubscribed
                    ? context.cAccent
                    : theme.colorScheme.primary,
              ),
              label: Text(
                isSubscribed ? '已关注' : '关注',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isSubscribed
                      ? context.cAccent
                      : theme.colorScheme.primary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: isSubscribed
                      ? context.cAccent
                      : theme.colorScheme.primary,
                  width: 0.8,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                visualDensity: VisualDensity.compact,
              ),
            );
          }),

          const SizedBox(width: 6),

          // 返回关键词搜索按钮
          IconButton(
            tooltip: '返回关键词搜索结果',
            icon: const Icon(Icons.close, size: 18),
            onPressed: controller.clearSelectedAuthor,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 初始状态引导（展示热门搜索词）
  Widget _buildInitialGuideView(BuildContext context) {
    final theme = Theme.of(context);
    final hotWords = controller.hotKeywords;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.local_fire_department,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '九色热搜',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (hotWords.isEmpty)
            Text(
              '输入搜索关键词开始检索，支持分类、时间、播放量与时长多重筛选',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: hotWords.map((word) {
                return ActionChip(
                  label: Text(word, style: const TextStyle(fontSize: 12)),
                  onPressed: () => controller.searchWithKeyword(word),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  /// hanime1 官网的分页窗口规则（逐值实测于 hanime1.me，总页数 360 时）：
  /// ```
  /// 第 1、2 页     → 1 2 3 4 … 359 360
  /// 第 3 … 358 页  → 1 2 … N-1 N N+1 … 359 360
  /// 第 359、360 页 → 1 2 … 356 357 358 359 360
  /// ```
  /// 这是 Laravel `UrlWindow` 的输出。两个反直觉的点：
  /// - 首部**固定两个**（`1 2`），不是常见的 `1 2 3`；只有贴近开头时才展开成 4 个；
  /// - 尾部固定是最后两页，只有贴近结尾时才展开成 5 个。
  /// 返回 `null` 表示省略号。
  Widget _buildPaginationBar(BuildContext context) => Obx(
    () => AppendPaginationFooter(
      page: controller.currentPage.value,
      hasMore: controller.hasMore.value,
      loading: controller.loading.value || controller.pageLoading.value,
      error: controller.error.value,
      onJump: _goToPage,
      onNext: controller.nextPage,
    ),
  );

  void _enqueue(VideoItem video) {
    final service = Get.find<DownloadService>();
    for (final task in service.tasks) {
      if (task.id == video.id && task.isActive) {
        _toast('「${video.title}」已在下载队列中');
        return;
      }
    }
    service.enqueue(video);
    _toast('已加入下载队列：${video.title}');
  }

  void _toast(String message) {
    AppToast.show(message);
  }
}
