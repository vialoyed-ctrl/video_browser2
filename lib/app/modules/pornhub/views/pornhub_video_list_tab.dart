/// PornHub 通用视频列表 Tab（推荐 / 最热 共用）。
///
/// 两者都是「按官网路径取视频列表」，区别只在于是否带排序切换条，
/// 因此合并成一个组件，由 [showSortBar] 控制。
library;

import '../../../widgets/retained_page_sliver.dart';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../pornhub_controller.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_video_grid.dart';

class PornHubVideoListTab extends StatefulWidget {
  const PornHubVideoListTab({
    super.key,
    required this.path,
    this.showSortBar = false,
  });

  /// 官网路径，例如 `/recommended?o=time`、`/video?o=ht`。
  final String path;

  /// 是否显示排序切换条（最热 Tab 用）。
  final bool showSortBar;

  @override
  State<PornHubVideoListTab> createState() => _PornHubVideoListTabState();
}

class _PornHubVideoListTabState extends State<PornHubVideoListTab> {
  final ScrollController _scroll = ScrollController();

  PornHubController get _ctrl => PornHubController.to;

  /// 最热 Tab 的实际路径会随排序变化。
  String get _effectivePath =>
      widget.showSortBar ? _ctrl.hotPathSelected.value : widget.path;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final st = _ctrl.stateOf(_effectivePath);
      if (st.items.isEmpty && !st.isLoading.value) {
        _ctrl.loadList(_effectivePath);
      }
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) _ctrl.loadMore(_effectivePath);
  }

  @override
  Widget build(BuildContext context) => widget.showSortBar
      ? Obx(() => _buildPath(context, _ctrl.hotPathSelected.value))
      : _buildPath(context, widget.path);

  Widget _buildPath(BuildContext context, String path) {
    final state = _ctrl.stateOf(path);
    // Reuse this widget while only the empty/loading/error branch changes.
    final grid = _PornHubRetainedGrid(
      controller: _ctrl,
      state: state,
      path: path,
    );
    return RefreshIndicator(
      onRefresh: () => _ctrl.loadList(path),
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
          if (widget.showSortBar)
            SliverToBoxAdapter(child: _buildSortBar(context)),
          Obx(() {
            if (state.items.isEmpty) {
              if (state.isLoading.value) {
                return const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final error = state.error.value;
              if (error != null) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: PornHubErrorBlock(
                    message: error,
                    onRetry: () => _ctrl.loadList(path),
                  ),
                );
              }
            }
            return grid;
          }),
        ],
      ),
    );
  }

  /// 排序切换条（最热 / 最高分 / 最多观看 / 最新）。
  Widget _buildSortBar(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Obx(() {
        final current = _ctrl.hotPathSelected.value;
        return ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          itemCount: PornHubController.sortCategories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final category = PornHubController.sortCategories[index];
            final selected = category.path == current;
            return ChoiceChip(
              label: Text(category.name),
              selected: selected,
              onSelected: (_) => _ctrl.selectHotSort(category),
              labelStyle: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              visualDensity: VisualDensity.compact,
            );
          },
        );
      }),
    );
  }
}

/// List/page changes rebuild the retained slivers; flags only rebuild footers.
class _PornHubRetainedGrid extends StatelessWidget {
  const _PornHubRetainedGrid({
    required this.controller,
    required this.state,
    required this.path,
  });
  final PornHubController controller;
  final PornHubListState state;
  final String path;

  @override
  Widget build(BuildContext context) {
    final footer = Obx(
      () => PornHubListFooter(
        isLoadingMore: state.isLoadingMore.value,
        currentPage: state.page,
        onJump: (page) => controller.jumpListPage(path, page),
        hasMore: state.hasMore.value,
        onLoadMore: () => controller.loadMore(path),
        errorText: state.error.value,
        isEmpty: state.items.isEmpty,
        emptyHint: '暂无内容',
      ),
    );
    return Obx(
      () => RetainedPageSliver(
        key: ValueKey(path),
        items: List.of(state.items),
        page: state.page,
        preserveEmptyAppend: state.lastLoadWasAppend,
        replacementGeneration: state.replacementGeneration,
        footer: footer,
        gridBuilder: (items) => SliverPornHubGrid(
          videos: items,
          onDownload: enqueuePornHubDownload,
        ),
      ),
    );
  }
}
