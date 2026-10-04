/// 通用展示组件：缩略图、视频卡片、加载 / 空 / 错误态。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../data/models/video_item.dart';

/// 缩略图。
///
/// [VideoItem.thumbnailUrl] 为空时（演示目录即是此情况）渲染本地占位块：
/// 由标题哈希推导色相，保证同一条目颜色稳定，且不依赖任何外部图片服务。
class VideoThumbnail extends StatelessWidget {
  const VideoThumbnail({
    super.key,
    required this.video,
    this.width = 148,
    this.height = 84,
    this.borderRadius = 10,
  });

  final VideoItem video;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = video.thumbnailUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (url != null && url.isNotEmpty)
              CachedNetworkImage(
                imageUrl: url,
                memCacheWidth: (width * 2).toInt(),
                fit: BoxFit.cover,
                placeholder: (_, _) => _placeholder(context),
                errorWidget: (_, _, _) => _placeholder(context),
              )
            else
              _placeholder(context),
            if (video.duration != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // 时长角标压在缩略图上 —— 用「图片叠加」色族，
                    // 不跟随明暗（跟随的话浅色模式下会变成浅底浅字）。
                    color: context.cImageScrim.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    child: Text(
                      Formatters.duration(video.duration),
                      style: TextStyle(
                        color: context.cOnImage,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final hue = (video.title.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.32, 0.42).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[base, base.withValues(alpha: 0.62)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.play_circle_outline,
          size: height * 0.38,
          // 图标压在这块由标题哈希生成的彩色占位块上，属于「图片叠加」色族。
          color: context.cOnImage.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// 列表项卡片。
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    this.onTap,
    this.onDownload,
    this.trailing,
    this.highlightKeyword,
  });

  final VideoItem video;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;
  final Widget? trailing;

  /// 搜索场景下高亮命中的关键词。
  final String? highlightKeyword;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            VideoThumbnail(video: video),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _title(context),
                  const SizedBox(height: 6),
                  Text(
                    video.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _metaLine(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                  if (video.tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    _tags(context),
                  ],
                ],
              ),
            ),
            if (trailing != null || onDownload != null) ...<Widget>[
              const SizedBox(width: 4),
              trailing ??
                  IconButton(
                    tooltip: '加入下载队列',
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined, size: 22),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _title(BuildContext context) {
    final keyword = highlightKeyword?.trim() ?? '';
    final style = const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );

    if (keyword.isEmpty) {
      return Text(
        video.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final lowerTitle = video.title.toLowerCase();
    final lowerKeyword = keyword.toLowerCase();
    final index = lowerTitle.indexOf(lowerKeyword);

    if (index < 0) {
      return Text(
        video.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        style: style,
        children: <InlineSpan>[
          TextSpan(text: video.title.substring(0, index)),
          TextSpan(
            text: video.title.substring(index, index + keyword.length),
            style: TextStyle(
              color: scheme.primary,
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.6),
            ),
          ),
          TextSpan(text: video.title.substring(index + keyword.length)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _metaLine() {
    final parts = <String>[
      '${Formatters.count(video.views)}次播放',
      if (video.publishedAt != null) Formatters.relativeDate(video.publishedAt),
    ];
    return parts.join(' · ');
  }

  Widget _tags(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: video.tags
          .take(3)
          .map(
            (tag) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

/// 全屏加载态。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              message!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 空态。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: scheme.outline),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 18),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态。
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 44, color: scheme.error),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 18),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表骨架屏，用于首屏加载。
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.itemCount = 6});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: itemCount,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 148,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _bar(scheme, widthFactor: 0.92),
                  const SizedBox(height: 10),
                  _bar(scheme, widthFactor: 0.5),
                  const SizedBox(height: 10),
                  _bar(scheme, widthFactor: 0.34),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(ColorScheme scheme, {required double widthFactor}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
