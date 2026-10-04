import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/core/responsive_utils.dart';

void main() {
  group('ResponsiveLayout unit tests', () {
    test('gridColumnCount maps widths correctly according to Android breakpoints', () {
      // Phone portrait
      expect(ResponsiveLayout.gridColumnCount(360), 2);
      expect(ResponsiveLayout.gridColumnCount(411), 2);
      expect(ResponsiveLayout.gridColumnCount(599), 2);

      // Phone landscape / Small tablet portrait
      expect(ResponsiveLayout.gridColumnCount(600), 3);
      expect(ResponsiveLayout.gridColumnCount(720), 3);
      expect(ResponsiveLayout.gridColumnCount(899), 3);

      // Tablet landscape / Large tablet portrait
      expect(ResponsiveLayout.gridColumnCount(900), 4);
      expect(ResponsiveLayout.gridColumnCount(1080), 4);
      expect(ResponsiveLayout.gridColumnCount(1199), 4);

      // Extra wide tablet landscape
      expect(ResponsiveLayout.gridColumnCount(1200), 5);
      expect(ResponsiveLayout.gridColumnCount(1600), 5);
    });

    test('cardAspectRatio calculates stable aspect ratio within bounds', () {
      final ratioNarrow = ResponsiveLayout.cardAspectRatio(180);
      expect(ratioNarrow, greaterThanOrEqualTo(0.85));
      expect(ratioNarrow, lessThanOrEqualTo(1.25));

      final ratioWide = ResponsiveLayout.cardAspectRatio(300);
      expect(ratioWide, greaterThanOrEqualTo(0.85));
      expect(ratioWide, lessThanOrEqualTo(1.25));
    });
  });
}
