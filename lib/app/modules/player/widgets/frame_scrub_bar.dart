/// 逐帧拖动进度条控件。
///
/// 在 [AudioVideoProgressBar] 之上补齐「拖动过程中画面实时跟随手指」所需的交互：
///
/// - 拖动时在滑块正上方浮出一个读数气泡，显示**毫秒级时间**与**当前帧号**，
///   慢拖时可以确认自己确实停在了相邻的下一帧上；
/// - 拖动期间由控件自己持有位置，不依赖宿主每帧回传 `progress`，因此宿主即便
///   来不及刷新也不会让滑块「粘住」；
/// - 手势被抢占（例如父级滚动抢走指针）时同样会回调 [onScrubEnd]，
///   避免宿主永远停在拖动态。
///
/// 控件本身不认识播放器：位置解算与 seek 节流由宿主（`PlayerController`）负责。
library;

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

import 'audio_video_progress_bar.dart';

class FrameScrubBar extends StatefulWidget {
  const FrameScrubBar({
    super.key,
    required this.progress,
    required this.total,
    this.buffered = Duration.zero,
    this.frameRate,
    this.onScrubStart,
    this.onScrubUpdate,
    this.onScrubEnd,
    this.barHeight = 3.0,
    this.baseBarColor = const Color(0x3DFFFFFF),
    this.progressBarColor = AppTheme.playerAccent,
    this.bufferedBarColor = AppTheme.playerBuffer,
    this.thumbRadius = 6.0,
    this.thumbColor = AppTheme.playerAccent,
    this.thumbGlowColor = AppTheme.playerGlow,
    this.thumbGlowRadius = 12.0,
    this.showBubble = true,
  });

  /// 静止时显示的播放进度。拖动期间控件改用手指位置，忽略它。
  final Duration progress;

  /// 视频总时长。
  final Duration total;

  /// 已缓冲时长。
  final Duration buffered;

  /// 当前视频轨帧率；为 null 时气泡只显示时间，不显示帧号。
  final double? frameRate;

  final ValueChanged<Duration>? onScrubStart;
  final ValueChanged<Duration>? onScrubUpdate;
  final ValueChanged<Duration>? onScrubEnd;

  final double barHeight;
  final Color baseBarColor;
  final Color progressBarColor;
  final Color bufferedBarColor;
  final double thumbRadius;
  final Color thumbColor;
  final Color thumbGlowColor;
  final double thumbGlowRadius;

  /// 是否显示拖动读数气泡。
  final bool showBubble;

  @override
  State<FrameScrubBar> createState() => _FrameScrubBarState();
}

class _FrameScrubBarState extends State<FrameScrubBar> {
  static const double _bubbleWidth = 132.0;

  /// 拖动期间由控件自己持有的位置。用 `null` 表示「未拖动」。
  Duration? _dragAt;

  bool get _dragging => _dragAt != null;

  Duration get _displayed => _dragAt ?? widget.progress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          // 气泡画在进度条自身高度之外，必须允许越界绘制。
          clipBehavior: Clip.none,
          children: [
            AudioVideoProgressBar(
              progress: _displayed,
              total: widget.total,
              buffered: widget.buffered,
              barHeight: widget.barHeight,
              baseBarColor: widget.baseBarColor,
              progressBarColor: widget.progressBarColor,
              bufferedBarColor: widget.bufferedBarColor,
              thumbColor: widget.thumbColor,
              thumbGlowColor: widget.thumbGlowColor,
              // 拖动中放大滑块与光晕，明确「现在由手指控制」。
              thumbRadius: _dragging
                  ? widget.thumbRadius * 1.25
                  : widget.thumbRadius,
              thumbGlowRadius: _dragging
                  ? widget.thumbGlowRadius + 4
                  : widget.thumbGlowRadius,
              onDragStart: _handleDragStart,
              onDragUpdate: _handleDragUpdate,
              onDragEnd: _handleDragEnd,
            ),
            if (widget.showBubble && _dragging) _buildBubble(width, _displayed),
          ],
        );
      },
    );
  }

  void _handleDragStart(Duration at) {
    setState(() => _dragAt = at);
    widget.onScrubStart?.call(at);
  }

  void _handleDragUpdate(Duration at) {
    setState(() => _dragAt = at);
    widget.onScrubUpdate?.call(at);
  }

  void _handleDragEnd() {
    final at = _dragAt ?? widget.progress;
    setState(() => _dragAt = null);
    widget.onScrubEnd?.call(at);
  }

  /// 把滑块中心对齐到气泡中心，并在两端做夹取，避免气泡被推出屏幕。
  Widget _buildBubble(double width, Duration at) {
    final totalMs = widget.total.inMilliseconds;
    final fraction = totalMs <= 0
        ? 0.0
        : (at.inMilliseconds / totalMs).clamp(0.0, 1.0);
    // 与 AudioVideoProgressBar 的绘制几何保持一致：两端各留半个条高的圆角。
    final capRadius = widget.barHeight / 2;
    final thumbDx = fraction * (width - widget.barHeight) + capRadius;
    final maxLeft = (width - _bubbleWidth).clamp(0.0, double.infinity);
    final left = (thumbDx - _bubbleWidth / 2).clamp(0.0, maxLeft);

    return Positioned(
      left: left,
      // 气泡底边略高于进度条顶部，靠 Clip.none 画到条外。
      bottom: 24,
      width: _bubbleWidth,
      child: IgnorePointer(child: _bubbleBody(at)),
    );
  }

  Widget _bubbleBody(Duration at) {
    final fps = widget.frameRate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE6000000),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatPreciseDuration(at),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              height: 1.1,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (fps != null && fps > 0) ...[
            const SizedBox(height: 2),
            Text(
              '第 ${(at.inMicroseconds * fps / 1000000.0).round()} 帧'
              ' / 共 ${(widget.total.inMicroseconds * fps / 1000000.0).round()} 帧',
              style: const TextStyle(
                color: AppTheme.playerAccent,
                fontSize: 10,
                height: 1.1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 毫秒级时长格式化：`mm:ss.SSS`（超过一小时则 `h:mm:ss.SSS`）。
///
/// 逐帧拖动时秒级精度不够用 —— 相邻两帧在 24fps 下只差 42ms，
/// 读数必须能看到毫秒，才能确认自己停在了哪一帧。
String formatPreciseDuration(Duration d) {
  final ms = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  if (d.inHours > 0) {
    return '${d.inHours}:$m:$s.$ms';
  }
  return '$m:$s.$ms';
}
