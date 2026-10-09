
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/site91md_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/home/home_controller.dart';
import 'package:video_browser/app/modules/home/home_view.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';

class _FixtureSource extends Site91Source {
  Completer<VideoPage>? pending;
  @override
  Future<List<String>> fetchHotKeywords() async => const ['Fixture'];
  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) => pending?.future ?? Future.value(fixturePage);
}

class _MdFixtureSource extends Site91MdSource {
  @override
  Future<void> fetchCategories({bool refresh = false}) async {}
  @override
  List<VideoCategory> categoriesForChannel(ChannelType channel) => const [];
  @override
  Future<List<String>> fetchHotKeywords() async => const [];
  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async => fixturePage;
}

final fixturePage = VideoPage(
  items: List.generate(
    4,
    (i) => VideoItem(
      id: 'neutral-$i',
      title: 'Fixture $i',
      author: '',
      hlsUrl: '',
    ),
  ),
  page: 1,
  hasMore: false,
);

void main() {
  late int previousPreloadCount;
  setUp(() {
    Get.testMode = true;
    previousPreloadCount = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
    Get.put(DownloadService());
    Get.put(UserService());
  });
  tearDown(() async {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    PreloadService.instance.preloadCount.value = previousPreloadCount;
  });

  Future<HomeController> mount(
    WidgetTester tester, {
    double width = 400,
    VideoSource? source,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = Get.put(HomeController(source ?? _FixtureSource()));
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const RepaintBoundary(
          key: ValueKey('home-pixels'),
          child: HomeView(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.videos, hasLength(4));
    return controller;
  }

  for (final width in [400.0, 900.0]) {
    testWidgets('home geometry matches original UI at width $width', (
      tester,
    ) async {
      await mount(tester, width: width);
      await expectLater(
        find.byKey(const ValueKey('home-pixels')),
        matchesGoldenFile('goldens/home-feed-${width.toInt()}.png'),
      );
    });
  }

  testWidgets(
    '91 loading flags preserve existing cards without rebuilding them',
    (tester) async {
      final controller = await mount(tester);
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is BiliVideoCardV) builds++;
      };
      controller.loadingFirst.value = true;
      await tester.pump();
      expect(find.byType(BiliVideoCardV), findsNWidgets(4));
      controller.loadingFirst.value = false;
      await tester.pump();
      expect(
        builds,
        0,
        reason: 'a loading-only change must update the footer without rebuilding existing cards',
      );
    },
  );

  testWidgets(
    '91 refresh errors preserve existing cards and show retry in footer',
    (tester) async {
      final controller = await mount(tester);
      controller.error.value = 'First-page error';
      controller.loadMoreError.value = '第 7 页加载失败，请重试';
      await tester.pumpAndSettle();
      expect(find.byType(BiliVideoCardV), findsNWidgets(4));
      expect(find.text('First-page error'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('第 7 页加载失败，请重试'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('第 7 页加载失败，请重试'), findsOneWidget);
    },
  );

  testWidgets('empty list keeps its loading, error and empty content states', (
    tester,
  ) async {
    final controller = await mount(tester);
    controller.videos.clear();
    controller.loadingFirst.value = true;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.loadingFirst.value = false;
    controller.error.value = 'Fixture error';
    await tester.pump();
    expect(find.text('Fixture error'), findsOneWidget);
    controller.error.value = null;
    await tester.pump();
    expect(find.text('当前分类下没有返回任何视频条目'), findsOneWidget);
  });

  testWidgets(
    '91md refresh replaces existing cards with loading and error content',
    (tester) async {
      final controller = await mount(tester, source: _MdFixtureSource());
      controller.loadingFirst.value = true;
      await tester.pump();
      expect(find.byType(BiliVideoCardV), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      controller.loadingFirst.value = false;
      controller.error.value = 'Md refresh error';
      await tester.pump();
      expect(find.byType(BiliVideoCardV), findsNothing);
      expect(find.text('Md refresh error'), findsOneWidget);
      controller.error.value = null;
      await tester.pump();
      expect(find.byType(BiliVideoCardV), findsNWidgets(4));
    },
  );
}
