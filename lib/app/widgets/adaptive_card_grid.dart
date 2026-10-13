import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/responsive_utils.dart';
import 'grid_layout_scope.dart';

/// Non-sliver grids use their real pane width, including player side panels.
class AdaptiveCardGrid extends StatelessWidget {
  const AdaptiveCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.all(6),
    this.shrinkWrap = false,
    this.physics,
    this.crossAxisSpacing = 6,
    this.mainAxisSpacing = 6,
    this.childAspectRatio,
    this.mainAxisExtent,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final double crossAxisSpacing, mainAxisSpacing;
  final double? childAspectRatio, mainAxisExtent;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = GridLayoutScope.columnsOf(context, constraints.maxWidth);
      final width = math.max(
        1.0,
        (constraints.maxWidth -
                padding.horizontal -
                (columns - 1) * crossAxisSpacing) /
            columns,
      );
      final ratio =
          childAspectRatio ??
          ResponsiveLayout.cardAspectRatio(
            width,
            textScale: MediaQuery.textScalerOf(context).scale(1),
          );
      return GridView.builder(
        padding: padding,
        shrinkWrap: shrinkWrap,
        physics: physics,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: crossAxisSpacing,
          mainAxisSpacing: mainAxisSpacing,
          childAspectRatio: ratio,
          mainAxisExtent:
              mainAxisExtent ??
              (childAspectRatio == null ? null : math.max(48.0, width / ratio)),
        ),
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    },
  );
}
