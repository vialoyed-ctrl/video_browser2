/// Hanime1 官方卡片（`div.horizontal-card`）与官方 2 列网格（`.horizontal-row`）。
///
/// 官网首页、搜索页、订阅页用的是**同一个**卡片组件，抓到的真实 DOM：
/// ```
/// <div title="…" class="video-item-container">
///   <div class="horizontal-card">
///     <a href="https://hanime1.me/watch?v=408438" class="video-link">
///       <div class="thumb-container">
///         <img class="main-thumb" src="…" loading="lazy">
///         <div class="duration">04:56</div>
///         <div class="stats-container">
///           <div class="stat-item"><i class="material-icons">thumb_up</i> 100%</div>
///           <div class="stat-item">5萬次</div>
///         </div>
///       </div>
///       <div class="title">Alice : The Witch's Trial | Part – 2</div>
///     </a>
///     <div class="subtitle">
///       <a href="…/search?query=SingularityNSFW">SingularityNSFW</a>
///       <span class="subtitle-time">&nbsp;• 12小時前</span>
///     </div>
///   </div>
/// </div>
/// ```
///
/// 尺寸逐字取自官网 `app.css` 的**移动端媒体查询**（`@media (max-width:767.9px)`）：
/// ```
/// .content-padding-new               { padding: 0 7px }
/// .horizontal-row                    { grid-template-columns: repeat(2,1fr); gap: 17px 7px }
/// .horizontal-card .thumb-container  { aspect-ratio: 16/9; border-radius: 3px; background: #2a2a2a }
/// .horizontal-card .main-thumb       { object-fit: cover }
/// .horizontal-card .duration         { left: 6px; top: 3px; font-size: 10px;
///                                      color: #fff; text-shadow: #000 1px 0 10px }
/// .horizontal-card .stats-container  { right: 3px; bottom: 3px; gap: 3px }
/// .horizontal-card .stat-item        { font-size: 10px; color: hsla(0,0%,100%,.9);
///                                      background: rgba(0,0,0,.5); padding: 0 3px;
///                                      line-height: 15px; border-radius: 2px }
/// .horizontal-card .title            { padding: 0 3px; font-size: 12px; font-weight: 700;
///                                      color: #e5e5e5; margin-top: 8px;
///                                      white-space: nowrap; overflow: hidden; text-overflow: ellipsis }
/// .horizontal-card .subtitle         { padding: 0 3px; margin-top: 4px }
/// .horizontal-card .subtitle a       { max-width: 65%; color: #696969; font-size: 12px }
/// .horizontal-card .subtitle .subtitle-time { color: #696969; font-size: 12px; flex-shrink: 0 }
/// ```
///
/// 两个容易看错的地方，别"想当然"改回去：
/// 1. `.duration` 是 **left:6px / top:3px**，也就是**左上角**，不是常见的右下角；
/// 2. `.title` 是 `white-space: nowrap` —— **单行**截断。移动端媒体查询里只改了
///    字号与 margin，没有重置 `white-space`，所以仍然是单行。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/video_item.dart';
import '../../../routes/app_navigator.dart';
import '../../../services/player_service.dart';
import '../../../services/preload_service.dart';

/// 官网 `.horizontal-card` 卡片。
class Hanime1CardH extends StatelessWidget {
  const Hanime1CardH({super.key, required this.video, this.onTap});

  final VideoItem video;
  final VoidCallback? onTap;

  // ---------------- 官方尺寸常量（移动端断点） ----------------

  /// `.content-padding-new { padding: 0 7px }`
  static const double horizontalPadding = 7;

  /// `.horizontal-row { gap: 17px 7px }` —— 行间距。
  static const double rowGap = 17;

  /// `.horizontal-row { gap: 17px 7px }` —— 列间距。
  static const double columnGap = 7;

  // 颜色不再写死：改由 AppPalette 语义色提供（浅色模式 / 莫奈取色才能贯通）。
  // 原先这里是 _thumbBg / _titleColor / _subColor 三个 const 深色值 ——
  // 它们在浅色模式下会变成「深底深字」。

  /// 单行文本的行高估算值（官网 `line-height: normal`，12px 字号约 1.2 倍）。
  static const double _lineHeight = 15;

  /// 这张卡片是不是**播放清单**（而不是单个视频）。
  ///
  /// 「我的」页第 4 行「播放清單」整行都是 `/playlist?list=…` 链接：它没有 m3u8、
  /// 也不是一个视频。若按普通视频丢给播放器，播放器会去解析一个清单页然后失败，
  /// 所以点击必须拦下来。
  bool get _isPlaylist => (video.detailUrl ?? '').contains('/playlist?list=');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;

        return InkWell(
          borderRadius: BorderRadius.circular(3),
          onTap:
              onTap ??
              () {
                // 播放清单不是视频：它没有 m3u8，丢给播放器只会解析失败。
                if (_isPlaylist) {
                  final playlistId =
                      Uri.tryParse(video.detailUrl ?? '')
                          ?.queryParameters['list'] ??
                      '';
                  AppNavigator.toHanime1Playlist(playlistId);
                  return;
                }
                AppNavigator.toPlayer(video);
              },
          onTapDown: (_) {
            // 播放清单没有可预加载的流，跳过预嗅探（否则会白发一次请求）。
            if (_isPlaylist) return;
            PreloadService.instance.touchDown(video);
            PlayerService.instance.preOpen(video);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ---------------- 封面 16:9 + 角标 ----------------
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: ColoredBox(
                    color: context.cImagePlaceholder,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildCover(context),

                        // 左上角时长（官网 left:6px top:3px）
                        if (video.durationStr != null &&
                            video.durationStr!.isNotEmpty)
                          Positioned(
                            left: 6,
                            top: 3,
                            child: Text(
                              video.durationStr!,
                              style: TextStyle(
                                fontSize: 10,
                                // 时长压在封面上 —— 「图片叠加」色族，不随明暗变。
                                color: context.cOnImage,
                                fontWeight: FontWeight.w400,
                                height: 1.2,
                                shadows: const [
                                  // text-shadow: #000 1px 0 10px
                                  Shadow(
                                    color: Colors.black,
                                    offset: Offset(1, 0),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                            ),
                          ),

                        // 右下角统计胶囊（官网 right:3px bottom:3px gap:3px）
                        if (_hasStats)
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_likeText.isNotEmpty)
                                  _StatPill(
                                    icon: Icons.thumb_up,
                                    text: _likeText,
                                  ),
                                if (_likeText.isNotEmpty &&
                                    _viewsText.isNotEmpty)
                                  const SizedBox(width: 3),
                                if (_viewsText.isNotEmpty)
                                  _StatPill(text: _viewsText),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

              // ---------------- 标题（单行，粗体） ----------------
              Padding(
                padding: const EdgeInsets.only(left: 3, right: 3, top: 8),
                child: Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    height: 1.25,
                    color: context.cTextMain,
                  ),
                ),
              ),

              // ---------------- 副标题：作者 + 相对时间 ----------------
              //
              // 官网 `.subtitle a { max-width: 65% }`，所以作者名最多占卡片宽度的 65%，
              // 时间永远紧跟在后面（`flex-shrink: 0`）。
              Padding(
                padding: const EdgeInsets.only(left: 3, right: 3, top: 4),
                child: SizedBox(
                  height: _lineHeight,
                  child: Row(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: cardWidth * 0.65),
                        child: Text(
                          video.author.isNotEmpty ? video.author : 'Hanime1',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: context.cTextSub,
                          ),
                        ),
                      ),
                      if (video.publishedAt != null &&
                          video.publishedAt!.isNotEmpty)
                        Text(
                          // 官网是 `&nbsp;• 12小時前`（时间前面有一个不换行空格）
                          '\u00A0• ${video.publishedAt!}',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: context.cTextSub,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 好评率（`thumb_up 100%`）。
  ///
  /// [VideoItem] 没有「好评率」这个字段（它是内容源无关的），
  /// [Hanime1Source._parseSingleCard] 把 `.stat-item` 里带 `%` 的那一项
  /// 存进了 [VideoItem.description]，这里按同样的约定读回来。
  String get _likeText {
    final d = video.description;
    if (d == null || d.isEmpty) return '';
    return d.contains('%') ? d : '';
  }

  String get _viewsText {
    final v = video.viewsStr;
    if (v == null || v.isEmpty) return '';
    return v;
  }

  bool get _hasStats => _likeText.isNotEmpty || _viewsText.isNotEmpty;

  Widget _buildCover(BuildContext context) {
    final thumb = video.thumbnailUrl;
    if (thumb == null || thumb.isEmpty) {
      return Center(
        child: Icon(Icons.movie_outlined, color: context.cTextFaint, size: 28),
      );
    }

    return CachedNetworkImage(
      imageUrl: thumb,
      fit: BoxFit.cover,
      // 必须限制解码尺寸。hanime1 缩略图原图 1024x576，按原尺寸解码每张 2.25MB；
      // 首页一次就有 144 张，全按原图解码约 324MB，而全局 imageCache 上限 40MB
      // （main.dart），结果缓存被反复驱逐 → 反复解码 → 滚动掉帧。
      // 2 列卡片实际显示宽度约 165dp，取 400 足够清晰。
      memCacheWidth: 400,
      httpHeaders: const {'Referer': 'https://hanime1.me/'},
      placeholder: (context, url) => const SizedBox.expand(),
      errorWidget: (context, url, error) => Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: context.cTextFaint,
          size: 24,
        ),
      ),
    );
  }
}

/// 右下角单个统计胶囊（官网 `.stat-item`）。
class _StatPill extends StatelessWidget {
  const _StatPill({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      // padding: 0 3px; line-height: 15px; border-radius: 2px
      padding: const EdgeInsets.symmetric(horizontal: 3),
      height: 15,
      decoration: BoxDecoration(
        // 统计胶囊压在封面上 —— 「图片叠加」色族，不随明暗变。
        color: context.cImageScrim.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              // .stat-item i { font-size: .95rem } —— 官网 html{font-size:10px}
              size: 9.5,
              color: context.cOnImage.withValues(alpha: 0.9),
            ),
            const SizedBox(width: 1),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              height: 1.5,
              color: context.cOnImage.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

/// 官网 2 列网格（`.horizontal-row`）的 sliver 版本。
///
/// 为什么不用 [SliverGrid]：CSS grid 的行高是**内容自适应**的
/// （`.horizontal-row { align-items: stretch }` + `.horizontal-row > div { height: 100% }`），
/// 而 [SliverGrid] 必须给一个固定的 `childAspectRatio`，一旦估算值偏小就会出现
/// 溢出条纹。这里改成「每行两个 `Expanded`」——行高由卡片自然决定，
/// 与官网行为完全一致，也不会溢出。
class Hanime1VideoGridSliver extends StatelessWidget {
  const Hanime1VideoGridSliver({
    super.key,
    required this.items,
    this.padding,
    this.onTapItem,
  });

  final List<VideoItem> items;

  /// 外层内边距，默认官方 `.content-padding-new` 的 `0 7px`。
  final EdgeInsetsGeometry? padding;

  final void Function(VideoItem video)? onTapItem;

  @override
  Widget build(BuildContext context) {
    final rowCount = (items.length + 1) ~/ 2;

    return SliverPadding(
      padding:
          padding ??
          const EdgeInsets.symmetric(
            horizontal: Hanime1CardH.horizontalPadding,
          ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((ctx, row) {
          final leftIndex = row * 2;
          final rightIndex = leftIndex + 1;
          return Padding(
            padding: EdgeInsets.only(
              bottom: row == rowCount - 1 ? 0 : Hanime1CardH.rowGap,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Hanime1CardH(
                    video: items[leftIndex],
                    onTap: onTapItem == null
                        ? null
                        : () => onTapItem!(items[leftIndex]),
                  ),
                ),
                const SizedBox(width: Hanime1CardH.columnGap),
                Expanded(
                  child: rightIndex < items.length
                      ? Hanime1CardH(
                          video: items[rightIndex],
                          onTap: onTapItem == null
                              ? null
                              : () => onTapItem!(items[rightIndex]),
                        )
                      // 奇数个时右侧留空，保持左对齐
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        }, childCount: rowCount),
      ),
    );
  }
}

/// 官网搜索页（按类型筛选后）的 **3 列竖版海报卡**。
///
/// 与 [Hanime1CardH] 是**两套不同组件**，别混用：
/// - [Hanime1CardH] = 官网 `.horizontal-card`，16:9 横版封面，首页 / 排行 / 订阅用，2 列；
/// - 本组件 = 三个海报分类的搜索结果，2:3 竖版封面，标题叠在底部，3 列。
///
/// 「新番預告」还会在封面左上角叠一个**日期角标**（形如 `11月27日`）。
/// 其余类型给的是「1個月前」这类相对时间，官网不叠角标 —— 所以这里也用
/// 「是否形如绝对日期」来判定，而不是按类型名硬编码。
class Hanime1PosterCard extends StatelessWidget {
  const Hanime1PosterCard({super.key, required this.video, this.onTap});

  final VideoItem video;
  final VoidCallback? onTap;

  /// 官网移动端海报宽约 100px、高约 150px。
  static const double coverAspect = 2 / 3;

  /// 日期角标文案；不是绝对日期时返回 null（不叠角标）。
  String? get _dateBadge {
    final t = video.publishedAt;
    if (t == null || t.isEmpty) return null;
    if (!t.contains('月') || !t.contains('日')) return null;
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final badge = _dateBadge;

    return InkWell(
      borderRadius: BorderRadius.circular(2),
      onTap: onTap ?? () => AppNavigator.toPlayer(video),
      onTapDown: onTap == null
          ? (_) {
              PreloadService.instance.touchDown(video);
              PlayerService.instance.preOpen(video);
            }
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AspectRatio(
          aspectRatio: coverAspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _cover(context),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(3, 14, 3, 2),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        context.cImageScrim.withValues(alpha: 0),
                        context.cImageScrim.withValues(alpha: 0.85),
                      ],
                    ),
                  ),
                  child: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: context.cOnImage,
                    ),
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  left: 2,
                  top: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    color: context.cImageScrim.withValues(alpha: 0.65),
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: 9.5,
                        height: 1.2,
                        color: context.cOnImage,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    final thumb = video.thumbnailUrl;
    if (thumb == null || thumb.isEmpty) {
      return ColoredBox(
        color: context.cImagePlaceholder,
        child: Icon(Icons.movie_outlined, color: context.cTextFaint, size: 24),
      );
    }
    return CachedNetworkImage(
      imageUrl: thumb,
      fit: BoxFit.cover,
      // 3 列卡片实际显示宽度约 110dp，3x 屏约 330px，取 360 足够。
      memCacheWidth: 360,
      httpHeaders: const {'Referer': 'https://hanime1.me/'},
      placeholder: (_, _) => ColoredBox(color: context.cImagePlaceholder),
      errorWidget: (_, _, _) => ColoredBox(
        color: context.cImagePlaceholder,
        child: Icon(
          Icons.broken_image_outlined,
          color: context.cTextFaint,
          size: 22,
        ),
      ),
    );
  }
}

/// 3 列竖版海报网格的 sliver 版本（搜索页按类型筛选后使用）。
///
/// 与 [Hanime1VideoGridSliver] 同样是「每行若干个 Expanded」而不是 [SliverGrid]：
/// 行高由卡片内容自然决定，避免固定 `childAspectRatio` 估偏导致溢出条纹。
class Hanime1PosterGridSliver extends StatelessWidget {
  const Hanime1PosterGridSliver({
    super.key,
    required this.items,
    this.padding,
    this.onTapItem,
  });

  final List<VideoItem> items;
  final EdgeInsetsGeometry? padding;
  final void Function(VideoItem video)? onTapItem;

  /// 列数。官网搜索结果实测 3 列。
  static const int columns = 3;

  /// 列间距 / 行间距。
  static const double columnGap = 7;
  static const double rowGap = 7;

  @override
  Widget build(BuildContext context) {
    final rowCount = (items.length + columns - 1) ~/ columns;

    return SliverPadding(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 7),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((ctx, row) {
          return Padding(
            padding: EdgeInsets.only(bottom: row == rowCount - 1 ? 0 : rowGap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: columnGap),
                  Expanded(
                    child: (row * columns + c) < items.length
                        ? Hanime1PosterCard(
                            video: items[row * columns + c],
                            onTap: onTapItem == null
                                ? null
                                : () => onTapItem!(items[row * columns + c]),
                          )
                        // 末行不足时右侧留空，保持左对齐
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
        }, childCount: rowCount),
      ),
    );
  }
}
