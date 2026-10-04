import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/modules/player/widgets/seek_indicators.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fast seek indicators do not dim the video area', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [BackwardSeekIndicator(), ForwardSeekIndicator()],
          ),
        ),
      ),
    );

    final gradientContainers = find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final decoration = widget.decoration;
      return decoration is BoxDecoration && decoration.gradient != null;
    });
    expect(gradientContainers, findsNothing);
  });
}
