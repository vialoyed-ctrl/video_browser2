/// Hanime1 专属移动端 Hero 焦点大卡片。
///
/// ## 布局：图上文下
///
/// 改造前是「竖版容器 + `BoxFit.cover` 叠加全部文字」。实测 hanime1 的封面
/// **统一是 16:9 横图**（1024×576 / 640×360），塞进 `1 / 1.08` 的竖版容器里
/// 会被横向裁掉约 **48%** —— 用户看到的就是「被截取」的画面。
///
/// 现在：
/// 1. 图片区**跟随封面真实宽高比**（运行时解析，兜底 16:9），完整显示不裁剪；
/// 2. 标题 / 作者 / 标签 / 按钮移到图片**下方**，不再压在画面上。
///    顺带解决了「白字压在浅色封面上看不清」的问题。
///
/// ## 配色
///
/// 全部走 [AppPalette] 语义色，不写字面量 —— 这样浅色模式与莫奈取色都能贯通。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/hanime1_models.dart';
import '../../../routes/app_navigator.dart';

class Hanime1HeroCard extends StatefulWidget {
  const Hanime1HeroCard({super.key, required this.hero});

  final Hanime1HeroItem hero;

  @override
  State<Hanime1HeroCard> createState() => _Hanime1HeroCardState();
}

class _Hanime1HeroCardState extends State<Hanime1HeroCard> {
  /// 实测 hanime1 封面统一 16:9；解析出真实比例前先用它占位，
  /// 避免图片加载完成后卡片高度跳变。
  static const double _fallbackAspect = 16 / 9;

  /// 极端长图的上限保护：比 1:1.6 更高就封顶。
  /// 封顶后改用 `BoxFit.contain` 留边 —— **仍然不裁剪**，只是不撑高卡片。
  static const double _minAspect = 1 / 1.6;

  static const Map<String, String> _imageHeaders = {
    'Referer': 'https://hanime1.me/',
  };

  /// 封面真实宽高比（w/h）。null = 尚未解析出来。
  double? _coverAspect;

  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolveCoverAspect();
  }

  @override
  void didUpdateWidget(covariant Hanime1HeroCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hero.coverUrl != widget.hero.coverUrl) {
      _coverAspect = null;
      _resolveCoverAspect();
    }
  }

  @override
  void dispose() {
    _detachListener();
    super.dispose();
  }

  /// 解析封面真实尺寸。
  ///
  /// 用 [CachedNetworkImageProvider] 而不是另起一个网络请求：它和展示用的
  /// [CachedNetworkImage] 共用同一份缓存，`maxWidth` 也保持一致，
  /// 不会多解一张图。
  void _resolveCoverAspect() {
    _detachListener();
    final url = widget.hero.coverUrl;
    if (url.isEmpty) return;

    final provider = CachedNetworkImageProvider(
      url,
      headers: _imageHeaders,
      maxWidth: 720,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final w = info.image.width;
      final h = info.image.height;
      if (w <= 0 || h <= 0) return;
      final ratio = w / h;
      if (_coverAspect == ratio) return;
      setState(() => _coverAspect = ratio);
    });
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detachListener() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) {
    final hero = widget.hero;

    final rawAspect = _coverAspect ?? _fallbackAspect;
    final aspect = rawAspect < _minAspect ? _minAspect : rawAspect;
    // 被上限保护截断时改用 contain 留边，保证「完整显示」这一条不被破坏。
    final letterboxed = aspect != rawAspect;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: context.cImageScrim.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---------------------------------------------------- 1. 封面
            AspectRatio(
              aspectRatio: aspect,
              child: _buildBackdrop(
                fit: letterboxed ? BoxFit.contain : BoxFit.cover,
              ),
            ),

            // ---------------------------------------------------- 2. 文字区
            Container(
              width: double.infinity,
              color: context.cSurface,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hero.title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: context.cTextMain,
                      letterSpacing: 0.2,
                    ),
                  ),
                  if (hero.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      hero.subtitle,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: context.cTextSub,
                      ),
                    ),
                  ],
                  if (hero.tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 52),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          alignment: WrapAlignment.center,
                          children: hero.tags.take(12).map((tag) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: context.cSurfaceAlt,
                                borderRadius: BorderRadius.circular(100),
                                border: Border.all(
                                  color: context.cBorder,
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                tag,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: context.cTextSub,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildActions(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 双操作按钮栏：【▶ 播放】与【ⓘ 更多资讯】。
  Widget _buildActions(BuildContext context) {
    return Row(
      children: [
        // 主操作：强调色实心按钮
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => AppNavigator.toPlayer(widget.hero.toVideoItem()),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: context.cAccent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.play_arrow_rounded,
                    color: context.scheme.onPrimary,
                    size: 22,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '播放',
                    style: TextStyle(
                      color: context.scheme.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 次操作：次级面 + 描边
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => AppNavigator.toPlayer(widget.hero.toVideoItem()),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: context.cSurfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: context.cBorder, width: 0.8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: context.cTextMain,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '更多资讯',
                    style: TextStyle(
                      color: context.cTextMain,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackdrop({required BoxFit fit}) {
    if (widget.hero.coverUrl.isEmpty) {
      return ColoredBox(color: context.cImagePlaceholder);
    }
    return CachedNetworkImage(
      imageUrl: widget.hero.coverUrl,
      // 容器比例已按封面真实比例设置，因此 cover 不会再裁掉任何内容；
      // 只有触发长图上限保护时才会传 contain 留边。
      fit: fit,
      // 限制解码尺寸：hero 全宽约 332dp，3x 屏约 996px，取 720 兼顾清晰度与内存。
      memCacheWidth: 720,
      httpHeaders: _imageHeaders,
      placeholder: (context, url) => ColoredBox(
        color: context.cImagePlaceholder,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.cTextFaint,
            ),
          ),
        ),
      ),
      errorWidget: (context, url, error) => ColoredBox(
        color: context.cImagePlaceholder,
        child: Icon(Icons.broken_image, color: context.cTextFaint, size: 40),
      ),
    );
  }
}
