import 'package:flutter/material.dart';

import '../core/responsive_utils.dart';

class AdaptiveSiteNavigation extends StatelessWidget {
  const AdaptiveSiteNavigation({
    super.key,
    required this.child,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });
  final Widget child;
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (!ResponsiveLayout.isWideScreen(context)) return child;
    return Row(
      children: [
        NavigationRail(
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          labelType: NavigationRailLabelType.all,
          minWidth: 72,
          destinations: [
            for (final item in destinations)
              NavigationRailDestination(
                icon: item.icon,
                selectedIcon: item.selectedIcon,
                label: Text(item.label),
              ),
          ],
        ),
        const VerticalDivider(width: 0.8, thickness: 0.8),
        Expanded(child: child),
      ],
    );
  }
}
