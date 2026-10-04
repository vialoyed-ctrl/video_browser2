import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:video_browser/app/core/app_scroll_behavior.dart';
import 'package:video_browser/app/core/app_theme.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/widgets/pull_to_next_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => PreloadService.instance.preloadCount.value = 0);
  test('theme keeps a shared accent and readable text in both modes', () {
    for (final brightness in Brightness.values) {
      final dynamic = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      );
      final theme = brightness == Brightness.dark
          ? AppTheme.dark(dynamicScheme: dynamic)
          : AppTheme.light(dynamicScheme: dynamic);
      final plain = brightness == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light();
      expect(theme.colorScheme.primary, plain.colorScheme.primary);
      expect(
        theme.colorScheme.surface,
        brightness == Brightness.light ? Colors.white : dynamic.surface,
      );
      final fg = theme.colorScheme.onSurface.computeLuminance(),
          bg = theme.colorScheme.surface.computeLuminance();
      expect(
        ((fg > bg ? fg : bg) + .05) / ((fg < bg ? fg : bg) + .05),
        greaterThan(4.5),
      );
    }
    expect(AppTheme.playerAccent.computeLuminance(), greaterThan(.3));
  });

  testWidgets(
    'a bottom pull appends without resetting position; top and final-page pulls do not load',
    (tester) async {
      final scroll = ScrollController();
      var calls = 0;
      var hasNext = true;
      Completer<void>? pending;
      Widget screen() => MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: PullToNextPage(
            hasNext: hasNext,
            isLoading: false,
            onNext: () {
              calls++;
              return (pending = Completer<void>()).future;
            },
            child: ListView(
              controller: scroll,
              children: List.generate(
                30,
                (i) => SizedBox(height: 70, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(screen());
      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(calls, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(calls, 1);
      pending!.complete();
      await tester.pumpAndSettle();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      hasNext = false;
      await tester.pumpWidget(screen());
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'volume uses cumulative movement rather than rounded platform echoes',
    (tester) async {
      const channel = MethodChannel(
        'com.yosemiteyss.flutter_volume_controller/method',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      final controller = PlayerController();
      controller.volume.value = 60;
      controller.beginVolumeGesture();
      for (var i = 0; i < 40; i++) {
        controller.onVerticalDragRight(1, 400);
        controller.syncSystemVolume(
          (controller.volume.value / 100 - .033).clamp(0, 1),
        );
      }
      expect(controller.volume.value, closeTo(50, .001));
      controller.endVolumeGesture();
      await tester.pump(const Duration(milliseconds: 1600));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );

  testWidgets(
    'gesture volume suppresses system UI and rejects invalid dimensions',
    (tester) async {
      const channel = MethodChannel(
        'com.yosemiteyss.flutter_volume_controller/method',
      );
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      final controller = PlayerController();
      controller.volume.value = 20;
      controller.onVerticalDragRight(-20, 0);
      expect(controller.volume.value, 20);
      controller.onVerticalDragRight(-20, 100);
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.volume.value, 40);
      expect(FlutterVolumeController.showSystemUI, isFalse);
      controller.endVolumeGesture();
      expect(calls.where((c) => c.method == 'setVolume').length, 1);
      await tester.pump(const Duration(milliseconds: 1600));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );
}
