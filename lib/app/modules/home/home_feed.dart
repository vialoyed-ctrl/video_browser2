import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/app_theme.dart';
import '../../core/responsive_utils.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/site91md_source.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_navigator.dart';
import '../../widgets/append_pagination_footer.dart';
import '../../widgets/bili_video_card.dart';
import '../../widgets/common.dart';
import '../../widgets/retained_page_sliver.dart';
import '../../widgets/video_grid_sliver.dart';
import 'home_controller.dart';

/// Content state and footer observe separately from the retained video grid.
class HomeFeed extends StatelessWidget {
  const HomeFeed({
    super.key,
    required this.controller,
    required this.onDownload,
  });
  final HomeController controller;
  final ValueChanged<VideoItem> onDownload;

  @override
  Widget build(BuildContext context) {
    final grid = _HomeVideoGrid(controller: controller, onDownload: onDownload);
    return Obx(() {
      final replacesContent =
          controller.source is Site91MdSource || controller.videos.isEmpty;
      if (replacesContent) {
        if (controller.loadingFirst.value) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = controller.error.value;
        if (error != null) {
          return ErrorView(message: error, onRetry: controller.loadFirstPage);
        }
      }
      if (controller.videos.isEmpty) {
        return const EmptyView(
          message: '当前分类下没有返回任何视频条目',
          icon: Icons.video_library_outlined,
        );
      }
      return grid;
    });
  }
}

class _HomeVideoGrid extends StatelessWidget {
  const _HomeVideoGrid({required this.controller, required this.onDownload});
  final HomeController controller;
  final ValueChanged<VideoItem> onDownload;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final availableWidth = ResponsiveLayout.isWideScreen(context)
        ? screenWidth - 73
        : screenWidth;
    final header = _HomeHeader(controller: controller);
    final footer = Obx(
      () => AppendPaginationFooter(
        page: controller.currentPage.value,
        hasMore: controller.hasMore.value,
        loading: controller.loadingMore.value || controller.loadingFirst.value,
        error: controller.loadMoreError.value,
        onJump: controller.jumpToPage,
        onNext: controller.retryOrLoadMore,
      ),
    );
    return Obx(
      () => RefreshIndicator(
        onRefresh: controller.loadFirstPage,
        child: CustomScrollView(
          controller: controller.scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            if (controller.source is! Site91MdSource)
              SliverToBoxAdapter(child: header),
            RetainedPageSliver(
              key: ValueKey(
                '${controller.source.id}:${controller.currentChannel.value}:${controller.currentCategory.value?.path}',
              ),
              items: List.of(controller.videos),
              page: controller.currentPage.value,
              preserveEmptyAppend: controller.paging.lastLoadWasAppend,
              replacementGeneration:
                  controller.paging.replacementGeneration.value,
              footer: footer,
              gridBuilder: (items) => VideoGridSliver(
                items: items,
                availableWidth: availableWidth,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                itemBuilder: (_, video) => BiliVideoCardV(
                  video: video,
                  onTap: () => AppNavigator.toPlayer(video),
                  onDownload: () => onDownload(video),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.controller});
  final HomeController controller;

  /// 顶部动态内容区：九色热搜词条（首页模式）或 子分类横向滚动切换条（频道模式）
  @override
  Widget build(BuildContext context) => Obx(() => _content(context));

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (controller.currentChannel.value == ChannelType.home) {
      // 首页：展示与官网完全一致的“九色热搜”词流
      final kws = controller.hotKeywords;
      if (kws.isEmpty) return const SizedBox.shrink();

      final expanded = controller.hotKeywordsExpanded.value;
      final displayKws = expanded ? kws : kws.take(16).toList();

      return Container(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.cSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.cBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  color: context.cAccent,
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(
                  controller.source.id == 'hanime1' ? 'Hanime1 热门标签' : '九色热搜',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: context.cTextMain,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: controller.toggleHotKeywordsExpand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        Text(
                          expanded ? '收起' : '+更多',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: displayKws.map((kw) {
                return InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => controller.searchKeyword(kw),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? theme.colorScheme.primary.withValues(alpha: 0.12)
                          : theme.colorScheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      kw,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );
    } else {
      // 频道模式：展示二级子分类横向滑动条
      final categories = controller.currentCategories;
      if (categories.isEmpty) return const SizedBox.shrink();

      final currentCat = controller.currentCategory.value;

      return Container(
        height: 44,
        margin: const EdgeInsets.only(top: 4, bottom: 4),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: categories.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final cat = categories[index];
            final isSelected = currentCat?.id == cat.id;

            return Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => controller.selectCategory(cat),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : (context.cSurfaceAlt),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : (context.cBorder),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? context.scheme.onPrimary
                          : context.cTextMain,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
  }
}
