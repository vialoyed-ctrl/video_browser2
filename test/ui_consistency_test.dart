import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/core/app_scroll_behavior.dart';
import 'package:video_browser/app/core/app_theme.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/feed/feed_controller.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/widgets/pull_to_next_page.dart';

class DelayedSource implements VideoSource {
  final requests = <String, Completer<VideoPage>>{};
  @override
  String get id => 'test';
  @override
  String? getCachedHlsUrl(String id) => 'https://example.invalid/video.m3u8';
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    int page = 1,
    int pageSize = 24,
  }) {
    if (page > 1) return Future.value(const VideoPage.empty());
    return (requests[query.keyword] = Completer<VideoPage>()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VideoPage page(String author) => VideoPage(
  items: [VideoItem(id: author, title: author, author: author, hlsUrl: '')],
  page: 1,
  hasMore: false,
);

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
      expect(theme.colorScheme.surface, dynamic.surface);
      final fg = theme.colorScheme.onSurface.computeLuminance(),
          bg = theme.colorScheme.surface.computeLuminance();
      expect(
        ((fg > bg ? fg : bg) + .05) / ((fg < bg ? fg : bg) + .05),
        greaterThan(4.5),
      );
    }
    expect(AppTheme.playerAccent.computeLuminance(), greaterThan(.3));
  });

  test('changing authors cannot publish the previous request', () async {
    final source = DelayedSource(), users = UserService();
    users.subscriptions.assignAll(['old', 'new']);
    Get.put<VideoSource>(source);
    Get.put<UserService>(users);
    final controller = FeedController();
    controller.selectedAuthor.value = 'old';
    final old = controller.loadData(reset: true);
    controller.selectedAuthor.value = 'new';
    final newest = controller.loadData(reset: true);
    source.requests['new']!.complete(page('new'));
    await newest;
    source.requests['old']!.complete(page('old'));
    await old;
    expect(controller.displayVideos.map((v) => v.id), ['new']);
    expect(controller.isLoading.value, isFalse);
    expect(controller.error.value, isNull);
    controller.onClose();
    Get.reset();
  });

  test('clearing subscriptions invalidates an in-flight feed', () async {
    final source = DelayedSource(), users = UserService();
    users.subscriptions.add('old');
    Get.put<VideoSource>(source);
    Get.put<UserService>(users);
    final controller = FeedController();
    final pending = controller.loadData(reset: true);
    users.subscriptions.clear();
    await controller.loadData(reset: true);
    source.requests['old']!.complete(page('old'));
    await pending;
    expect(controller.displayVideos, isEmpty);
    expect(controller.isLoading.value, isFalse);
    expect(controller.error.value, isNull);
    controller.onClose();
    Get.reset();
  });

  testWidgets(
    'a bottom pull turns one page, top pulls and the final page do not',
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
      expect(scroll.offset, 0);
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
