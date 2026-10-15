import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;

import 'grid_layout_scope.dart';

/// Scroll/footer geometry can invoke a layout builder again without a width
/// change. Reuse its grid so retained cards aren't rebuilt on every such pass.
Widget adaptiveSliverLayout(
  Widget Function(BuildContext, SliverConstraints) builder,
) {
  Widget? cached;
  double? width;
  int? columns;
  TextScaler? scaler;
  return SliverLayoutBuilder(
    builder: (context, constraints) {
      final nextWidth = constraints.crossAxisExtent;
      final nextColumns = GridLayoutScope.columnsOf(context, nextWidth);
      final nextScaler = MediaQuery.textScalerOf(context);
      if (cached != null &&
          width == nextWidth &&
          columns == nextColumns &&
          scaler == nextScaler) {
        return cached!;
      }
      width = nextWidth;
      columns = nextColumns;
      scaler = nextScaler;
      return cached = builder(context, constraints);
    },
  );
}
