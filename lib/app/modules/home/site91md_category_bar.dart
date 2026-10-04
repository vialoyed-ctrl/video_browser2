import 'package:flutter/material.dart';

import '../../data/sources/video_source.dart';

/// Website columns in the same compact expandable format as subscriptions.
class Site91MdCategoryBar extends StatefulWidget {
  const Site91MdCategoryBar({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    required this.loading,
    required this.error,
    required this.onRetry,
  });
  final List<VideoCategory> categories;
  final String? selectedId;
  final ValueChanged<VideoCategory?> onSelect;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  @override
  State<Site91MdCategoryBar> createState() => _Site91MdCategoryBarState();
}

class _Site91MdCategoryBarState extends State<Site91MdCategoryBar> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = <VideoCategory?>[null, ...widget.categories];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 54,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Material(
                  color: colors.primaryContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: colors.primary, width: .8),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Container(
                      height: 38,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 18,
                            color: colors.onPrimaryContainer,
                          ),
                          Text(
                            _expanded ? '收起' : '展开',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _expanded
                    ? Text(
                        '网站栏目 · ${widget.categories.length}',
                        style: Theme.of(context).textTheme.titleSmall,
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 2,
                        ),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) =>
                            _chip(context, entries[index]),
                      ),
              ),
              if (widget.loading)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        if (_expanded)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .28,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: entries
                      .map(
                        (c) => SizedBox(height: 38, child: _chip(context, c)),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        if (widget.error != null)
          TextButton.icon(
            onPressed: widget.onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('栏目加载失败，点击重试'),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, VideoCategory? category) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.selectedId == category?.id;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1 : .5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => widget.onSelect(category),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (category == null) ...[
                Icon(
                  Icons.home_rounded,
                  size: 16,
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                category?.name ?? '网站首页',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
