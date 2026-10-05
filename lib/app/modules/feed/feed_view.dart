/// “动态”板块视图：展示关注 UP 主视频、按时间最新排序、每页 24 条带分页控制。
library;

import 'package:flutter/material.dart';

import '../../widgets/pull_to_next_page.dart';

import '../../core/app_theme.dart';

import 'package:get/get.dart';

import '../../core/responsive_utils.dart';
import '../../data/models/video_item.dart';
import '../../routes/app_navigator.dart';
import '../../services/download_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/bili_video_card.dart';
import '../mine/mine_view.dart';
import '../root/root_controller.dart';
import 'feed_controller.dart';

class FeedView extends StatelessWidget {
  const FeedView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.isRegistered<FeedController>()
        ? Get.find<FeedController>()
        : Get.put(FeedController());
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '动态',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: '管理关注的 UP 主',
            icon: const Icon(Icons.people_alt_outlined),
            onPressed: () => Get.to<void>(() => const SubscriptionsListView()),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => controller.loadData(reset: true),
          ),
        ],
      ),
      body: Obx(() {
        final subs = controller.subscriptions;

        // 1. 未关注任何 UP 主的引导页面
        if (subs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.5,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.subscriptions_outlined,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '暂无关注的 UP 主',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '在浏览或播放页中点击「+ 关注」，UP 主的最新作品将按时间排序汇聚在这里。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: context.scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.explore_outlined, size: 18),
                    label: const Text(
                      '去浏览视频',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      if (Get.isRegistered<RootController>()) {
                        Get.find<RootController>().switchTab(0);
                      }
                    },
                  ),
                ],
              ),
            ),
          );
        }

        // 2. 有关注 UP 主时的动态流
        return Column(
          children: [
            // 顶部横向滚动 UP 主筛选栏
            _buildAuthorFilterBar(context, controller, isDark),

            // 主体视频展示区（支持下拉刷新与每页 24 项分页）
            Expanded(
              child: Obx(() {
                if (controller.isLoading.value &&
                    controller.displayVideos.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (controller.displayVideos.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library_outlined,
                          size: 48,
                          color: context.cTextFaint,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          controller.error.value ?? '暂未获取到动态视频',
                          style: TextStyle(color: context.cTextSub),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => controller.loadData(reset: true),
                          child: const Text('重试刷新'),
                        ),
                      ],
                    ),
                  );
                }

                final screenWidth = MediaQuery.sizeOf(context).width;
                final isWide = ResponsiveLayout.isWideScreen(context);
                final availableWidth = isWide ? screenWidth - 73 : screenWidth;
                final columnCount = ResponsiveLayout.gridColumnCount(
                  availableWidth,
                );
                final columnWidth =
                    (availableWidth - 12 - (columnCount - 1) * 6) / columnCount;
                final childAspectRatio = ResponsiveLayout.cardAspectRatio(
                  columnWidth,
                );

                return RefreshIndicator(
                  onRefresh: () => controller.loadData(reset: true),
                  child: PullToNextPage(
                    hasNext:
                        controller.currentPage.value <
                        controller.totalPages.value,
                    isLoading: controller.isLoading.value,
                    onNext: controller.nextPage,
                    child: CustomScrollView(
                      controller: controller.scrollController,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        // 动态视频智能自适应网格（2~5 列）
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          sliver: SliverGrid(
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
                              final video = controller.displayVideos[index];
                              return BiliVideoCardV(
                                video: video,
                                onTap: () => AppNavigator.toPlayer(video),
                                onDownload: () => _enqueue(video),
                              );
                            }, childCount: controller.displayVideos.length),
                          ),
                        ),

                        // 底部分页控制器栏（上一页 / 第 X / Y 页 / 下一页）
                        SliverToBoxAdapter(
                          child: _buildPaginationBar(context, controller),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      }),
    );
  }

  /// 顶部横向滚动作者筛选栏
  Widget _buildAuthorFilterBar(
    BuildContext context,
    FeedController controller,
    bool isDark,
  ) {
    final theme = Theme.of(context);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: context.cSurface,
        border: Border(bottom: BorderSide(color: context.cBorder, width: 0.8)),
      ),
      child: Obx(() {
        final subs = controller.subscriptions;
        final selected = controller.selectedAuthor.value;

        return ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          itemCount: subs.length + 1,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              final isAll = selected == 'ALL';
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => controller.selectAuthor('ALL'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isAll
                        ? theme.colorScheme.primary
                        : (context.cSurfaceAlt),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isAll
                          ? theme.colorScheme.primary
                          : (context.cBorder),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    '全部关注 (${subs.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isAll ? FontWeight.bold : FontWeight.normal,
                      color: isAll
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              );
            }

            final author = subs[index - 1];
            final isSelected = selected == author;

            return InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => controller.selectAuthor(author),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : (context.cSurfaceAlt),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : (context.cBorder),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 8,
                      backgroundColor: isSelected
                          ? context.cTextFaint
                          : theme.colorScheme.primaryContainer,
                      child: Text(
                        author.isNotEmpty ? author[0].toUpperCase() : 'U',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isSelected
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      author,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }

  /// 底部分页控制栏（每页 24 条）
  Widget _buildPaginationBar(BuildContext context, FeedController controller) {
    final theme = Theme.of(context);

    return Obx(() {
      final current = controller.currentPage.value;
      final total = controller.totalPages.value;
      final canPrev = current > 1 && !controller.isLoading.value;
      final canNext = current < total && !controller.isLoading.value;

      return Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: context.cSurface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: context.cBorder, width: 0.8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 上一页
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              onPressed: canPrev ? controller.previousPage : null,
              icon: const Icon(Icons.arrow_back_ios, size: 12),
              label: const Text('上一页', style: TextStyle(fontSize: 12)),
            ),

            // 页码与总数指示（点击可快速跳页）
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: total > 1
                  ? () => _showPageJumpDialog(context, controller)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '第 $current / $total 页',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    if (total > 1) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.unfold_more,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 下一页
            FilledButton.icon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                backgroundColor: canNext
                    ? theme.colorScheme.primary
                    : context.cTextFaint,
                foregroundColor: context.scheme.onPrimary,
              ),
              onPressed: canNext ? controller.nextPage : null,
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.arrow_forward_ios, size: 12),
              label: const Text('下一页', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    });
  }

  void _showPageJumpDialog(BuildContext context, FeedController controller) {
    final textCtrl = TextEditingController(
      text: '${controller.currentPage.value}',
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到指定页', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共有 ${controller.totalPages.value} 页（每页 24 条）'),
            const SizedBox(height: 12),
            TextField(
              controller: textCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '页码 (1 - ${controller.totalPages.value})',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final target = int.tryParse(textCtrl.text.trim());
              if (target != null &&
                  target >= 1 &&
                  target <= controller.totalPages.value) {
                Navigator.of(ctx).pop();
                controller.goToPage(target);
              } else {
                AppToast.show('请输入有效的页码');
              }
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }

  void _enqueue(VideoItem video) {
    final service = Get.find<DownloadService>();

    DownloadTask? existing;
    for (final task in service.tasks) {
      if (task.id == video.id) {
        existing = task;
        break;
      }
    }

    if (existing != null && existing.isActive) {
      AppToast.show('「${video.title}」已在下载队列中');
      return;
    }
    service.enqueue(video);
    AppToast.show('已加入下载队列：${video.title}');
  }
}
