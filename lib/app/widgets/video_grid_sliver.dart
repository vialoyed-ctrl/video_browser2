import 'adaptive_sliver_layout.dart';

import 'package:flutter/material.dart';

import '../core/responsive_utils.dart';
import 'grid_layout_scope.dart';
import '../data/models/video_item.dart';

/// Shared geometry; each caller retains its card and business actions.
class VideoGridSliver extends StatelessWidget {
  const VideoGridSliver({
    super.key,
    required this.items,
    required this.availableWidth,
    required this.padding,
    required this.itemBuilder,
  });

  final List<VideoItem> items;
  final double availableWidth;
  final EdgeInsets padding;
  final Widget Function(BuildContext, VideoItem) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return adaptiveSliverLayout((context, constraints) {
      final actualWidth = constraints.crossAxisExtent;
      final columns = GridLayoutScope.columnsOf(context, actualWidth);
      final columnWidth =
          (actualWidth - padding.horizontal - (columns - 1) * 6) / columns;
      return SliverPadding(
        padding: padding,
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
            childAspectRatio: ResponsiveLayout.cardAspectRatio(
              columnWidth,
              textScale: MediaQuery.textScalerOf(context).scale(1),
            ),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => itemBuilder(context, items[index]),
            childCount: items.length,
          ),
        ),
      );
    });
  }
}
