// ignore_for_file: library_private_types_in_public_api, prefer_initializing_formals, unnecessary_getters_setters
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

import 'package:flutter/rendering.dart';

/// 移植自 PiliPlus 的高性能音频/视频自定义进度条 RenderObject。
/// 支持播放进度、缓冲进度、拖拽高亮与光晕特效。
class AudioVideoProgressBar extends LeafRenderObjectWidget {
  const AudioVideoProgressBar({
    super.key,
    required this.progress,
    required this.total,
    this.buffered = Duration.zero,
    this.onSeek,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.barHeight = 3.0,
    this.baseBarColor = const Color(0x3DFFFFFF),
    this.progressBarColor = AppTheme.playerAccent,
    this.bufferedBarColor = AppTheme.playerBuffer,
    this.thumbRadius = 6.0,
    this.thumbColor = AppTheme.playerAccent,
    this.thumbGlowColor = AppTheme.playerGlow,
    this.thumbGlowRadius = 14.0,
    this.thumbCanPaintOutsideBar = true,
  });

  final Duration progress;
  final Duration total;
  final Duration buffered;

  final ValueChanged<Duration>? onSeek;
  final ValueChanged<Duration>? onDragStart;
  final ValueChanged<Duration>? onDragUpdate;
  final VoidCallback? onDragEnd;

  final double barHeight;
  final Color baseBarColor;
  final Color progressBarColor;
  final Color bufferedBarColor;
  final double thumbRadius;
  final Color thumbColor;
  final Color thumbGlowColor;
  final double thumbGlowRadius;
  final bool thumbCanPaintOutsideBar;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderProgressBar(
      progress: progress.inMilliseconds,
      total: total.inMilliseconds,
      buffered: buffered.inMilliseconds,
      onSeek: onSeek != null
          ? (ms) => onSeek!(Duration(milliseconds: ms))
          : null,
      onDragStart: onDragStart != null
          ? (ms) => onDragStart!(Duration(milliseconds: ms))
          : null,
      onDragUpdate: onDragUpdate != null
          ? (ms) => onDragUpdate!(Duration(milliseconds: ms))
          : null,
      onDragEnd: onDragEnd,
      barHeight: barHeight,
      baseBarColor: baseBarColor,
      progressBarColor: progressBarColor,
      bufferedBarColor: bufferedBarColor,
      thumbRadius: thumbRadius,
      thumbColor: thumbColor,
      thumbGlowColor: thumbGlowColor,
      thumbGlowRadius: thumbGlowRadius,
      thumbCanPaintOutsideBar: thumbCanPaintOutsideBar,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderProgressBar renderObject,
  ) {
    renderObject
      ..total = total.inMilliseconds
      ..progress = progress.inMilliseconds
      ..buffered = buffered.inMilliseconds
      ..onSeek = onSeek != null
          ? (ms) => onSeek!(Duration(milliseconds: ms))
          : null
      ..onDragStart = onDragStart != null
          ? (ms) => onDragStart!(Duration(milliseconds: ms))
          : null
      ..onDragUpdate = onDragUpdate != null
          ? (ms) => onDragUpdate!(Duration(milliseconds: ms))
          : null
      ..onDragEnd = onDragEnd
      ..barHeight = barHeight
      ..baseBarColor = baseBarColor
      ..progressBarColor = progressBarColor
      ..bufferedBarColor = bufferedBarColor
      ..thumbRadius = thumbRadius
      ..thumbColor = thumbColor
      ..thumbGlowColor = thumbGlowColor
      ..thumbGlowRadius = thumbGlowRadius
      ..thumbCanPaintOutsideBar = thumbCanPaintOutsideBar;
  }
}

typedef _DurationMsCallback = void Function(int milliseconds);

class _EagerHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _RenderProgressBar extends RenderBox {
  _RenderProgressBar({
    required int progress,
    required int total,
    required int buffered,
    _DurationMsCallback? onSeek,
    _DurationMsCallback? onDragStart,
    _DurationMsCallback? onDragUpdate,
    VoidCallback? onDragEnd,
    required double barHeight,
    required Color baseBarColor,
    required Color progressBarColor,
    required Color bufferedBarColor,
    required double thumbRadius,
    required Color thumbColor,
    required Color thumbGlowColor,
    required double thumbGlowRadius,
    bool thumbCanPaintOutsideBar = true,
  }) : _progress = progress,
       _total = total,
       _buffered = buffered,
       _onSeek = onSeek,
       _onDragStart = onDragStart,
       _onDragUpdate = onDragUpdate,
       _onDragEnd = onDragEnd,
       _barHeight = barHeight,
       _baseBarColor = baseBarColor,
       _progressBarColor = progressBarColor,
       _bufferedBarColor = bufferedBarColor,
       _thumbRadius = thumbRadius,
       _thumbColor = thumbColor,
       _thumbGlowColor = thumbGlowColor,
       _thumbGlowRadius = thumbGlowRadius,
       _paintThumbGlow = thumbGlowRadius > thumbRadius,
       _thumbCanPaintOutsideBar = thumbCanPaintOutsideBar {
    _drag = _EagerHorizontalDragGestureRecognizer()
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel;
    _thumbValue = _proportionOfTotal(_progress);
  }

  _EagerHorizontalDragGestureRecognizer? _drag;
  late double _thumbValue;
  bool _userIsDraggingThumb = false;

  int _progress;
  int get progress => _progress;
  set progress(int value) {
    final clamp = _clampDuration(value);
    if (_progress == clamp) return;
    if (!_userIsDraggingThumb) {
      _progress = clamp;
      _thumbValue = _proportionOfTotal(clamp);
    }
    markNeedsPaint();
  }

  int _total;
  int get total => _total;
  set total(int value) {
    final clamp = value < 0 ? 0 : value;
    if (_total == clamp) return;
    _total = clamp;
    if (!_userIsDraggingThumb) {
      _thumbValue = _proportionOfTotal(_progress);
    }
    markNeedsPaint();
  }

  int _buffered;
  int get buffered => _buffered;
  set buffered(int value) {
    final clamp = _clampDuration(value);
    if (_buffered == clamp) return;
    _buffered = clamp;
    markNeedsPaint();
  }

  _DurationMsCallback? _onSeek;
  _DurationMsCallback? get onSeek => _onSeek;
  set onSeek(_DurationMsCallback? value) => _onSeek = value;

  _DurationMsCallback? _onDragStart;
  _DurationMsCallback? get onDragStart => _onDragStart;
  set onDragStart(_DurationMsCallback? value) => _onDragStart = value;

  _DurationMsCallback? _onDragUpdate;
  _DurationMsCallback? get onDragUpdate => _onDragUpdate;
  set onDragUpdate(_DurationMsCallback? value) => _onDragUpdate = value;

  VoidCallback? _onDragEnd;
  VoidCallback? get onDragEnd => _onDragEnd;
  set onDragEnd(VoidCallback? value) => _onDragEnd = value;

  double _barHeight;
  double get barHeight => _barHeight;
  set barHeight(double value) {
    if (_barHeight == value) return;
    _barHeight = value;
    markNeedsPaint();
  }

  Color _baseBarColor;
  Color get baseBarColor => _baseBarColor;
  set baseBarColor(Color value) {
    if (_baseBarColor == value) return;
    _baseBarColor = value;
    markNeedsPaint();
  }

  Color _progressBarColor;
  Color get progressBarColor => _progressBarColor;
  set progressBarColor(Color value) {
    if (_progressBarColor == value) return;
    _progressBarColor = value;
    markNeedsPaint();
  }

  Color _bufferedBarColor;
  Color get bufferedBarColor => _bufferedBarColor;
  set bufferedBarColor(Color value) {
    if (_bufferedBarColor == value) return;
    _bufferedBarColor = value;
    markNeedsPaint();
  }

  double _thumbRadius;
  double get thumbRadius => _thumbRadius;
  set thumbRadius(double value) {
    if (_thumbRadius == value) return;
    _thumbRadius = value;
    markNeedsLayout();
  }

  Color _thumbColor;
  Color get thumbColor => _thumbColor;
  set thumbColor(Color value) {
    if (_thumbColor == value) return;
    _thumbColor = value;
    markNeedsPaint();
  }

  Color _thumbGlowColor;
  Color get thumbGlowColor => _thumbGlowColor;
  set thumbGlowColor(Color value) {
    if (_thumbGlowColor == value) return;
    _thumbGlowColor = value;
    if (_userIsDraggingThumb) markNeedsPaint();
  }

  bool _paintThumbGlow;
  double _thumbGlowRadius;
  double get thumbGlowRadius => _thumbGlowRadius;
  set thumbGlowRadius(double value) {
    if (_thumbGlowRadius == value) return;
    _thumbGlowRadius = value;
    _paintThumbGlow = value > _thumbRadius;
    markNeedsLayout();
  }

  bool _thumbCanPaintOutsideBar;
  bool get thumbCanPaintOutsideBar => _thumbCanPaintOutsideBar;
  set thumbCanPaintOutsideBar(bool value) {
    if (_thumbCanPaintOutsideBar == value) return;
    _thumbCanPaintOutsideBar = value;
    markNeedsPaint();
  }

  int _clampDuration(int value) {
    if (value < 0) return 0;
    if (value > _total) return _total;
    return value;
  }

  double _proportionOfTotal(int duration) {
    if (_total <= 0) return 0.0;
    return (duration / _total).clamp(0.0, 1.0);
  }

  int _currentThumbDurationInMilliseconds() {
    return (_thumbValue * _total).round();
  }

  void _handleDragStart(DragStartDetails details) {
    _userIsDraggingThumb = true;
    _updateThumbPosition(details.localPosition);
    _onDragStart?.call(_currentThumbDurationInMilliseconds());
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _updateThumbPosition(details.localPosition);
    _onDragUpdate?.call(_currentThumbDurationInMilliseconds());
  }

  void _handleDragEnd(DragEndDetails details) {
    _onDragEnd?.call();
    _onSeek?.call(_currentThumbDurationInMilliseconds());
    _finishDrag();
  }

  /// 手势被抢占（例如父级滚动拿走指针）时的收尾。
  ///
  /// 必须和正常结束一样回调 [onDragEnd]：宿主据此退出「拖动中」状态。若只重置本
  /// RenderObject 的标志位，宿主会永远停在拖动态 —— 表现为拖动结束后画面不再跟随
  /// 播放、控制栏也不再自动隐藏。
  void _handleDragCancel() {
    if (_userIsDraggingThumb) {
      _onDragEnd?.call();
    }
    _finishDrag();
  }

  void _finishDrag() {
    _userIsDraggingThumb = false;
    markNeedsPaint();
  }

  void _updateThumbPosition(Offset localPosition) {
    final barCapRadius = _barHeight / 2;
    final barStart = barCapRadius;
    final barEnd = size.width - barCapRadius;
    final barWidth = barEnd - barStart;
    if (barWidth <= 0) return;
    final position = (localPosition.dx - barStart).clamp(0.0, barWidth);
    _thumbValue = position / barWidth;
    _progress = _currentThumbDurationInMilliseconds();
    markNeedsPaint();
  }

  @override
  void dispose() {
    _drag?.dispose();
    _drag = null;
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _drag?.addPointer(event);
    }
  }

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final desiredWidth = constraints.maxWidth;
    final desiredHeight = max(2 * _thumbRadius, _barHeight) + 16.0; // 提供足够的触控高度
    return constraints.constrainDimensions(desiredWidth, desiredHeight);
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);

    final localSize = size;
    final barWidth = localSize.width;
    final barHeight = localSize.height;

    // 1. 绘制底条
    _drawBar(
      canvas: canvas,
      availableSize: Size(barWidth, barHeight),
      widthProportion: 1.0,
      color: _baseBarColor,
    );

    // 2. 绘制缓冲条
    _drawBar(
      canvas: canvas,
      availableSize: Size(barWidth, barHeight),
      widthProportion: _proportionOfTotal(_buffered),
      color: _bufferedBarColor,
    );

    // 3. 绘制播放进度条
    _drawBar(
      canvas: canvas,
      availableSize: Size(barWidth, barHeight),
      widthProportion: _thumbValue,
      color: _progressBarColor,
    );

    // 4. 绘制拖拽圆点与光晕
    final thumbPaint = Paint()..color = _thumbColor;
    final barCapRadius = _barHeight / 2;
    final availableWidth = barWidth - _barHeight;
    var thumbDx = _thumbValue * availableWidth + barCapRadius;
    if (!_thumbCanPaintOutsideBar) {
      thumbDx = thumbDx.clamp(_thumbRadius, barWidth - _thumbRadius);
    }
    final center = Offset(thumbDx, barHeight / 2);

    if (_userIsDraggingThumb && _paintThumbGlow) {
      final glowPaint = Paint()..color = _thumbGlowColor;
      canvas.drawCircle(center, _thumbGlowRadius, glowPaint);
    }
    canvas.drawCircle(
      center,
      _userIsDraggingThumb ? _thumbRadius * 1.3 : _thumbRadius,
      thumbPaint,
    );

    canvas.restore();
  }

  void _drawBar({
    required Canvas canvas,
    required Size availableSize,
    required double widthProportion,
    required Color color,
  }) {
    if (widthProportion <= 0.0) return;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = _barHeight;
    final capRadius = _barHeight / 2;
    final adjustedWidth = availableSize.width - _barHeight;
    final dx = widthProportion * adjustedWidth + capRadius;
    final dy = availableSize.height / 2;
    final startPoint = Offset(capRadius, dy);
    final endPoint = Offset(dx, dy);
    canvas.drawLine(startPoint, endPoint, paint);
  }
}
