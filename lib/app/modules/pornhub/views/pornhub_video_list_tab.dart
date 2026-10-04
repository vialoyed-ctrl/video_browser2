/// PornHub 通用视频列表 Tab（推荐 / 最热 共用）。
///
/// 两者都是「按官网路径取视频列表」，区别只在于是否带排序切换条，
/// 因此合并成一个组件，由 [showSortBar] 控制。
library;

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
  Widget build(BuildContext context) {
    return Obx(() {
      final st = _ctrl.stateOf(_effectivePath);
      final videos = st.items;
      final isLoading = st.isLoading.value;
      final error = st.error.value;

      return RefreshIndicator(
        onRefresh: () => _ctrl.loadList(_effectivePath),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: <Widget>[
            if (widget.showSortBar)
              SliverToBoxAdapter(child: _buildSortBar(context)),
            if (isLoading && videos.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null && videos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: PornHubErrorBlock(
                  message: error,
                  onRetry: () => _ctrl.loadList(_effectivePath),
                ),
              )
            else ...<Widget>[
              SliverPornHubGrid(
                videos: videos,
                onDownload: enqueuePornHubDownload,
              ),
              SliverToBoxAdapter(
                child: PornHubListFooter(
                  isLoadingMore: st.isLoadingMore.value,
                  hasMore: st.hasMore.value,
                  onLoadMore: () => _ctrl.loadMore(_effectivePath),
                  errorText: error,
                  isEmpty: videos.isEmpty,
                  emptyHint: '暂无内容',
                ),
              ),
            ],
          ],
        ),
      );
    });
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
