/// PornHub 模块内共用的视频网格与列表尾部。
///
/// 与 91 版面（`home_view.dart` 的 `_grid`）保持同一套几何参数：
/// 列数走 [ResponsiveLayout.gridColumnCount]，比例走 [ResponsiveLayout.cardAspectRatio]，
/// 卡片直接用 [BiliVideoCardV] —— 这样三个版面的观感完全一致。
library;

import '../../../widgets/append_pagination_footer.dart';

import 'package:flutter/material.dart';

import '../../../core/responsive_utils.dart';
import '../../../data/models/video_item.dart';
import '../../../routes/app_navigator.dart';
import '../../../widgets/bili_video_card.dart';

/// 视频网格 sliver。
class SliverPornHubGrid extends StatelessWidget {
  const SliverPornHubGrid({
    super.key,
    required this.videos,
    this.onDownload,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
  });

  final List<VideoItem> videos;
  final void Function(VideoItem video)? onDownload;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = ResponsiveLayout.isWideScreen(context);
    final availableWidth = isWide ? screenWidth - 73 : screenWidth;
    final columnCount = ResponsiveLayout.gridColumnCount(availableWidth);
    final columnWidth =
        (availableWidth - 12 - (columnCount - 1) * 6) / columnCount;
    final childAspectRatio = ResponsiveLayout.cardAspectRatio(columnWidth);

    return SliverPadding(
      padding: padding,
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columnCount,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: childAspectRatio,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final video = videos[index];
          return BiliVideoCardV(
            video: video,
            onTap: () => AppNavigator.toPlayer(video),
            onDownload: onDownload == null ? null : () => onDownload!(video),
          );
        }, childCount: videos.length),
      ),
    );
  }
}

/// 列表尾部：加载中 / 加载更多 / 没有更多。
class PornHubListFooter extends StatelessWidget {
  const PornHubListFooter({
    super.key,
    required this.isLoadingMore,
    required this.hasMore,
    this.onLoadMore,
    this.errorText,
    this.emptyHint,
    this.isEmpty = false,
    this.currentPage = 1,
    this.onJump,
  });

  final bool isLoadingMore;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final String? errorText;
  final String? emptyHint;
  final bool isEmpty;
  final int currentPage;
  final ValueChanged<int>? onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text(
            emptyHint ?? '暂无内容',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return AppendPaginationFooter(
      page: currentPage,
      hasMore: hasMore,
      loading: isLoadingMore,
      error: errorText,
      onJump: onJump,
      onNext: onLoadMore,
    );
  }
}

/// 错误 / 空态提示块。
class PornHubErrorBlock extends StatelessWidget {
  const PornHubErrorBlock({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_rounded,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
