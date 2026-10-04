import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One bottom request per extent; loading and error state prevent retry loops.
class BottomLoadGate extends StatefulWidget {
  const BottomLoadGate({
    super.key,
    required this.enabled,
    required this.onNext,
    required this.child,
  });
  final bool enabled;
  final VoidCallback? onNext;
  final Widget child;
  @override
  State<BottomLoadGate> createState() => _BottomLoadGateState();
}

class _BottomLoadGateState extends State<BottomLoadGate> {
  ScrollPosition? _position;
  double? _triggeredExtent;
  bool _scheduled = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _position)) return;
    _position?.removeListener(_scroll);
    _position = position;
    _position?.addListener(_scroll);
  }

  void _scroll() {
    final p = _position;
    if (p == null || !p.hasContentDimensions) return;
    if (p.pixels < p.maxScrollExtent - 80) _triggeredExtent = null;
    if (!widget.enabled ||
        _scheduled ||
        widget.onNext == null ||
        p.userScrollDirection != ScrollDirection.reverse ||
        p.pixels < p.maxScrollExtent ||
        _triggeredExtent == p.maxScrollExtent) {
      return;
    }
    _triggeredExtent = p.maxScrollExtent;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && widget.enabled) widget.onNext?.call();
    });
  }

  @override
  void dispose() {
    _position?.removeListener(_scroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
