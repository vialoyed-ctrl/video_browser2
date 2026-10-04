import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';

import 'package:get/get.dart';

import '../core/formatters.dart';
import '../data/models/video_item.dart';
import '../data/sources/video_source.dart';
import '../routes/app_navigator.dart';
import '../services/player_service.dart';
import '../services/preload_service.dart';
import '../services/user_service.dart';
import 'app_toast.dart';

/// 点击 UP 主名称：直接进入搜索页检索该作者的作品。
///
/// 匿名与聚合占位作者（`匿名` / `官方精选`）没有可检索的主页，直接忽略。
void _searchAuthor(String author) {
  if (author.isEmpty || author == '匿名' || author == '官方精选') return;
  AppNavigator.toAuthor(author);
}

/// 哔哩哔哩移动端风格 - 竖向视频卡片（用于双列网格瀑布流）
/// 严格学习并对齐 PiliPlus/lib/common/widgets/video_card/video_card_v.dart
/// 缩略图防盗链 Referer：按条目所属站点选择。
///
/// 三个源各自的图床都校验 Referer，用错会被 403，封面就变成占位色块。
/// 判断依据是 `detailUrl` 的 host（各源注册在 `_ownedUrlMarkers` 里的域名）。
String _thumbRefererFor(VideoItem video) {
  final host = Uri.tryParse(video.detailUrl ?? '')?.host ?? '';
  if (host.contains('hanime1.me')) return 'https://hanime1.me/';
  if (host.contains('pornhub')) return 'https://cn.pornhub.com/';
  // 91麻豆（MacCMS）的封面与页面同源，用条目自己的 host 作 Referer；
  // 命中不了（含用户自加镜像）时退回原 91 默认值，不改动既有行为。
  if (SourceRegistry.isSite91MdVideo(video)) {
    final uri = Uri.tryParse(video.detailUrl ?? video.id);
    if (uri != null && uri.hasAuthority) return '${uri.origin}/';
  }
  return 'https://91porny.com/';
}

class BiliVideoCardV extends StatelessWidget {
  const BiliVideoCardV({
    super.key,
    required this.video,
    this.onTap,
    this.onDownload,
  });

  final VideoItem video;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardBg = theme.colorScheme.surface;

    return Card(
      elevation: 0.5,
      color: cardBg,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onTapDown: (_) {
          PreloadService.instance.touchDown(video);
          PlayerService.instance.preOpen(video);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面区 (16:10 比例)
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCover(),
                  // 底部渐变暗色阴影蒙层
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 32,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xBB000000)],
                        ),
                      ),
                    ),
                  ),
                  // 封面左上角：HD 标识
                  if (video.tags.any(
                        (t) =>
                            t.toLowerCase() == 'hd' ||
                            t.toLowerCase().contains('hd'),
                      ) ||
                      video.title.toLowerCase().contains('hd') ||
                      video.title.contains('1080'))
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.playerAccent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'HD',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.black,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  // 封面左下角：播放量与好评率
                  Positioned(
                    left: 6,
                    bottom: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_circle_outline,
                          size: 13,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          video.viewsStr ??
                              (video.views > 0
                                  ? Formatters.count(video.views)
                                  : '1.2万'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (video.description != null &&
                            video.description!.contains('好评')) ...[
                          const SizedBox(width: 5),
                          Text(
                            '• ${video.description!.replaceAll('好评: ', '👍 ')}',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppTheme.playerAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // 封面右下角：视频时长角标
                  if (video.author != '91麻豆' ||
                      video.durationStr != null ||
                      video.duration != null)
                    Positioned(
                      right: 6,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: context.cImageScrim.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          video.durationStr ??
                              (video.duration != null
                                  ? Formatters.duration(video.duration)
                                  : '10:00'),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // 内容区
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // 2行标题：高度自适应
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    // 底栏：UP主 / 作者 ID + 发布时间 + 快捷下载（紧贴底部，无多余空行）
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => _searchAuthor(video.author),
                            onLongPress: () =>
                                _showAuthorSheet(context, video.author),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                    vertical: 0.5,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.7),
                                      width: 0.8,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    'UP',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    video.publishedAt != null &&
                                            video.publishedAt!.isNotEmpty
                                        ? '${video.author} · ${video.publishedAt}'
                                        : video.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (onDownload != null)
                          InkWell(
                            onTap: onDownload,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Icon(
                                Icons.download_for_offline_outlined,
                                size: 22,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover() {
    final url = video.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: 400,
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': _thumbRefererFor(video),
        },
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    final hue = (video.title.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.35, 0.45).toColor();
    return Container(
      color: base,
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 32, color: Colors.white70),
      ),
    );
  }

  static void _showAuthorSheet(BuildContext context, String author) {
    if (author.isEmpty || author == '匿名' || author == '官方精选') return;
    final theme = Theme.of(context);
    final userSvc = Get.find<UserService>();

    showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      author[0].toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          author,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'UP 主快捷操作',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cTextSub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Obx(() {
                    final isSub = userSvc.isSubscribed(author);
                    return FilledButton.icon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: isSub
                            ? context.cSurfaceAlt
                            : theme.colorScheme.primary,
                        foregroundColor: isSub
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimary,
                      ),
                      icon: Icon(isSub ? Icons.check : Icons.add, size: 15),
                      label: Text(
                        isSub ? '已关注' : '关注',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () {
                        userSvc.toggleSubscription(author);
                        AppToast.show(
                          userSvc.isSubscribed(author)
                              ? '已关注 UP 主「$author」'
                              : '已取消关注',
                        );
                      },
                    );
                  }),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: const Text('查看 TA 的全部作品'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () {
                  Navigator.of(ctx).pop();
                  AppNavigator.toAuthor(author);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 哔哩哔哩风格 - 横向推荐视频卡片（用于详情页下方的【相关推荐】）
class BiliVideoCardH extends StatelessWidget {
  const BiliVideoCardH({super.key, required this.video, this.onTap});

  final VideoItem video;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      onTapDown: (_) {
        PreloadService.instance.touchDown(video);
        PlayerService.instance.preOpen(video);
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧封面 (固定宽 124, 高 76)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 124,
                height: 76,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCover(context),
                    // 右下角时长
                    if (video.author != '91麻豆' ||
                        video.durationStr != null ||
                        video.duration != null)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: context.cImageScrim.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            video.durationStr ?? '10:00',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            // 右侧信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.person_outline,
                        size: 13,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => _searchAuthor(video.author),
                          child: Text(
                            video.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.play_circle_outline,
                        size: 12,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        video.viewsStr ?? '1.2万',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      if (video.publishedAt != null &&
                          video.publishedAt!.isNotEmpty) ...[
                        Text(
                          ' · ${video.publishedAt}',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    final url = video.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      final referer = _thumbRefererFor(video);
      return CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: 320,
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': referer,
        },
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder(context),
        errorWidget: (_, _, _) => _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final hue = (video.title.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.35, 0.45).toColor();
    return Container(
      color: base,
      child: Center(
        // 图标压在这块由标题哈希生成的彩色底上 —— 「图片叠加」色族。
        child: Icon(
          Icons.movie_outlined,
          size: 24,
          color: context.cOnImage.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
