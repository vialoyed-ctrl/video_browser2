import 'package:flutter/material.dart';

import '../core/app_logger.dart';

/// Keep page links, and allow one deliberate pull past the bottom to turn a page.
class PullToNextPage extends StatefulWidget {
  const PullToNextPage({
    super.key,
    required this.child,
    required this.hasNext,
    required this.isLoading,
    required this.onNext,
    this.resetPosition = false,
  });
  final Widget child;
  final bool hasNext, isLoading, resetPosition;
  final Future<void> Function() onNext;
  @override
  State<PullToNextPage> createState() => _PullToNextPageState();
}

class _PullToNextPageState extends State<PullToNextPage> {
  bool _armed = false, _busy = false;
  ScrollPosition? _position;

  Future<void> _next() async {
    if (_busy || widget.isLoading || !widget.hasNext) return;
    _busy = true;
    final position = _position;
    try {
      await widget.onNext();
      if (!mounted || !widget.resetPosition) return;
      // The same scrollable remains mounted when its page data is replaced.
      if (position != null &&
          position.hasPixels &&
          position.context.notificationContext?.mounted == true) {
        position.jumpTo(position.minScrollExtent);
      }
    } catch (error, stack) {
      AppLogger.e('PullToNextPage', '加载下一页失败', error, stack);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
          if (n is ScrollStartNotification) _armed = false;
          if (!widget.hasNext || widget.isLoading || _busy) {
            _armed = false;
            return false;
          }
          if (n is ScrollUpdateNotification &&
              n.dragDetails != null &&
              n.metrics.pixels - n.metrics.maxScrollExtent >= 48) {
            _armed = true;
            _position = n.context
                ?.findAncestorStateOfType<ScrollableState>()
                ?.position;
          }
          if (n is ScrollEndNotification && _armed) {
            _armed = false;
            _next();
          }
          return false;
        },
        child: widget.child,
      );
}
