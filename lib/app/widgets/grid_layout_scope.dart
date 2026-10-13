import 'package:flutter/material.dart';

import '../core/responsive_utils.dart';
import '../services/grid_layout_settings.dart';

class GridLayoutScope extends InheritedNotifier<GridLayoutSettings> {
  const GridLayoutScope({
    super.key,
    required GridLayoutSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static int columnsOf(BuildContext context, double width) {
    final scope = context.dependOnInheritedWidgetOfExactType<GridLayoutScope>();
    return scope?.notifier?.resolveColumns(width) ??
        ResponsiveLayout.gridColumnCount(width);
  }
}
