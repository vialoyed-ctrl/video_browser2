import 'package:flutter/material.dart';

import '../data/models/video_item.dart';

/// Keeps each loaded page and its footer together in one scrolling stream.
class RetainedPageSliver extends StatefulWidget {
  const RetainedPageSliver({
    super.key,
    required this.items,
    required this.page,
    required this.gridBuilder,
    required this.footer,
  });
  final List<VideoItem> items;
  final int page;
  final Widget Function(List<VideoItem>) gridBuilder;
  final Widget footer;
  @override
  State<RetainedPageSliver> createState() => _RetainedPageSliverState();
}

class _RetainedPageSliverState extends State<RetainedPageSliver> {
  final _ends = <({int page, int end})>[];
  List<String> _ids = [];
  void _update() {
    final ids = widget.items.map((item) => item.id).toList(growable: false);
    final prefix =
        ids.length >= _ids.length &&
        Iterable<int>.generate(_ids.length).every((i) => ids[i] == _ids[i]);
    final previousPage = _ends.isEmpty ? widget.page : _ends.last.page;
    if (!prefix ||
        ids.length < _ids.length ||
        (widget.page != previousPage && ids.length <= _ids.length)) {
      _ends.clear();
    }
    if (_ends.isEmpty) {
      _ends.add((page: widget.page, end: ids.length));
    } else if (widget.page != _ends.last.page && ids.length > _ids.length) {
      _ends.add((page: widget.page, end: ids.length));
    } else {
      _ends[_ends.length - 1] = (page: widget.page, end: ids.length);
    }
    _ids = ids;
  }

  @override
  Widget build(BuildContext context) {
    _update();
    var start = 0;
    final slivers = <Widget>[];
    for (var i = 0; i < _ends.length; i++) {
      final section = _ends[i];
      final items = widget.items.sublist(start, section.end);
      slivers.add(
        KeyedSubtree(
          key: ValueKey('grid-${section.page}'),
          child: widget.gridBuilder(items),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          key: ValueKey('footer-${section.page}'),
          child: PageFooterScope(
            page: section.page,
            active: i == _ends.length - 1,
            child: widget.footer,
          ),
        ),
      );
      start = section.end;
    }
    return SliverMainAxisGroup(slivers: slivers);
  }
}

class PageFooterScope extends InheritedWidget {
  const PageFooterScope({
    super.key,
    required this.page,
    required this.active,
    required super.child,
  });
  final int page;
  final bool active;
  static PageFooterScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageFooterScope>();
  @override
  bool updateShouldNotify(PageFooterScope oldWidget) =>
      page != oldWidget.page || active != oldWidget.active;
}
