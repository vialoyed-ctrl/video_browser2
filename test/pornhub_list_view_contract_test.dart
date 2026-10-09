import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_video_list_tab.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

List<VideoItem> videos(String prefix, [int count = 4]) => List.generate(
  count,
  (i) => VideoItem(
    id: '$prefix-$i',
    title: 'Fixture $prefix $i',
    author: '',
    hlsUrl: '',
  ),
);

class FixtureSource extends PornHubSource {
  final requests = <Completer<VideoPage>>[];
  final arguments = <(String, int)>[];
  @override
  Future<VideoPage> fetchPathPage(String path, int page) {
    arguments.add((path, page));
    final request = Completer<VideoPage>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  late int oldPreload;
  late FixtureSource source;
  late PornHubController controller;
  setUp(() {
    Get.testMode = true;
    oldPreload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
    Get.put(UserService());
    source = FixtureSource();
    controller = Get.put(PornHubController(source));
  });
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    PreloadService.instance.preloadCount.value = oldPreload;
  });

  Future<PornHubListState> mount(
    WidgetTester tester, {
    double width = 400,
    bool sorted = false,
    bool empty = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final path = sorted ? '/video?o=ht' : '/fixture';
    final state = controller.stateOf(path);
    if (!empty) state.items.assignAll(videos('first'));
    state.hasMore.value = false;
    if (empty) state.isLoading.value = true;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: RepaintBoundary(
          key: const ValueKey('pornhub-pixels'),
          child: Scaffold(
            body: PornHubVideoListTab(path: path, showSortBar: sorted),
          ),
        ),
      ),
    );
    await tester.pump();
    if (!empty) await tester.pumpAndSettle();
    return state;
  }

  for (final width in [400.0, 900.0]) {
    testWidgets('original PornHub pixels and geometry at width $width', (
      tester,
    ) async {
      await mount(tester, width: width, sorted: true);
      await expectLater(
        find.byKey(const ValueKey('pornhub-pixels')),
        matchesGoldenFile('goldens/pornhub-list-${width.toInt()}.png'),
      );
    });
  }
  testWidgets(
    'loading has priority over empty-list error and retry loads same path',
    (tester) async {
      final state = await mount(tester, empty: true);
      state.error.value = 'offline';
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('offline'), findsNothing);
      state.isLoading.value = false;
      await tester.pumpAndSettle();
      expect(find.text('offline'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(source.arguments.single, ('/fixture', 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      source.requests.single.complete(
        const VideoPage(items: [], page: 1, hasMore: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('未获取到内容，请下拉重试'), findsOneWidget);
    },
  );
  testWidgets('empty list without error keeps original empty hint', (
    tester,
  ) async {
    final state = await mount(tester, empty: true);
    state.isLoading.value = false;
    await tester.pumpAndSettle();
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.byType(BiliVideoCardV), findsNothing);
  });
  testWidgets('append retains page footers and replacement removes old pages', (
    tester,
  ) async {
    final state = await mount(tester);
    state.page = 2;
    state.items.addAll(videos('second'));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('第 1 页'), findsOneWidget);
    state.page = 7;
    state.items.assignAll(videos('replacement', 2));
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('第 7 页'), findsOneWidget);
    expect(find.text('第 1 页'), findsNothing);
    expect(find.text('第 2 页'), findsNothing);
  });
  testWidgets(
    'sort change keeps scroll controller and uses selected path cache',
    (tester) async {
      await mount(tester, sorted: true);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller;
      controller.stateOf('/video?o=mv').items.assignAll(videos('cached'));
      controller.stateOf('/video?o=mv').hasMore.value = false;
      await tester.tap(find.text('最多观看'));
      await tester.pump();
      expect(source.arguments.single, ('/video?o=mv', 1));
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(scroll),
      );
      expect(find.text('Fixture cached 0'), findsOneWidget);
      source.requests.single.complete(
        VideoPage(items: videos('fresh'), page: 1, hasMore: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fixture fresh 0'), findsOneWidget);
      expect(controller.stateOf('/video?o=ht').items.first.id, 'first-0');
    },
  );
  testWidgets('inactive retained footer cannot load the next page', (
    tester,
  ) async {
    final state = await mount(tester);
    state.page = 2;
    state.items.addAll(videos('second', 30));
    state.hasMore.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('第 1 页'), findsOneWidget);
    expect(source.arguments, isEmpty);
    state.hasMore.value = false;
    await tester.pumpAndSettle();
  });
  testWidgets('loading and error-only changes do not rebuild retained cards', (
    tester,
  ) async {
    final state = await mount(tester);
    var builds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is BiliVideoCardV) builds++;
    };
    state.isLoadingMore.value = true;
    await tester.pump();
    expect(find.byType(BiliVideoCardV), findsNWidgets(4));
    state.isLoadingMore.value = false;
    await tester.pump();
    state.isLoading.value = true;
    await tester.pump();
    state.isLoading.value = false;
    state.error.value = 'retry';
    await tester.pump();
    expect(find.text('retry'), findsOneWidget);
    expect(builds, 0, reason: 'only the footer changes for a nonempty list');
  });
  testWidgets(
    'delayed append preserves old footer while waiting and adds a new page',
    (tester) async {
      final state = await mount(tester);
      state.hasMore.value = true;
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is BiliVideoCardV) builds++;
      };
      final pending = controller.loadMore('/fixture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.arguments.single, ('/fixture', 2));
      expect(find.text('第 1 页'), findsOneWidget);
      expect(find.text('第 2 页'), findsNothing);
      expect(find.byType(BiliVideoCardV), findsNWidgets(4));
      expect(
        builds,
        0,
        reason: 'waiting for a new page only updates the footer',
      );
      source.requests.last.complete(
        VideoPage(items: videos('second'), page: 2, hasMore: false),
      );
      await pending;
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('第 2 页'), findsOneWidget);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('第 1 页'), findsOneWidget);
    },
  );
  for (final throws in [false, true]) {
    testWidgets(
      'failed delayed append ($throws) preserves footer and retries same page',
      (tester) async {
        final state = await mount(tester);
        state.hasMore.value = true;
        final pending = controller.loadMore('/fixture');
        await tester.pump();
        expect(find.text('第 1 页'), findsOneWidget);
        if (throws) {
          source.requests.last.completeError(StateError('offline'));
        } else {
          source.requests.last.complete(
            const VideoPage(
              items: [],
              page: 2,
              hasMore: true,
              summary: PornHubSource.requestFailureMessage,
            ),
          );
        }
        await pending;
        await tester.pumpAndSettle();
        expect(find.text('第 1 页'), findsOneWidget);
        expect(find.text(state.error.value!), findsOneWidget);
        await tester.tap(find.text(state.error.value!));
        await tester.pump();
        expect(source.arguments, [('/fixture', 2), ('/fixture', 2)]);
        expect(find.text('第 1 页'), findsOneWidget);
        source.requests.last.complete(
          VideoPage(items: videos('retried'), page: 2, hasMore: false),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('第 2 页'), findsOneWidget);
      },
    );
  }
  for (final scenario in [(false, 7), (true, 7), (false, 2), (true, 4)]) {
    final (hasMore, targetPage) = scenario;
    testWidgets(
      'empty append ($hasMore) retains sections and jump to $targetPage resets them',
      (tester) async {
        final state = await mount(tester);
        state.hasMore.value = true;
        final append = controller.loadMore('/fixture');
        source.requests.last.complete(
          VideoPage(items: videos('second'), page: 2, hasMore: true),
        );
        await append;
        await tester.pumpAndSettle();
        List<int> footerPages() => tester
            .widgetList<PageFooterScope>(
              find.byType(PageFooterScope, skipOffstage: false),
            )
            .map((scope) => scope.page)
            .toList();
        expect(footerPages(), [1, 2]);
        final emptyAppend = controller.loadMore('/fixture');
        source.requests.last.complete(
          VideoPage(items: const [], page: 3, hasMore: hasMore),
        );
        await emptyAppend;
        await tester.pumpAndSettle();
        expect(
          state.page,
          3,
          reason: 'source progression still advances over empty pages',
        );
        expect(state.items.length, 8);
        expect(
          footerPages(),
          [1, 2],
          reason: 'an empty append must not relabel or remove loaded sections',
        );
        if (hasMore) {
          final next = controller.loadMore('/fixture');
          expect(source.arguments.last, ('/fixture', 4));
          source.requests.last.completeError(StateError('offline'));
          await next;
          await tester.pumpAndSettle();
          expect(state.page, 3);
          expect(footerPages(), [1, 2]);
          final retry = controller.loadMore('/fixture');
          expect(source.arguments.last, ('/fixture', 4));
          source.requests.last.complete(
            VideoPage(items: videos('third'), page: 4, hasMore: false),
          );
          await retry;
          await tester.pumpAndSettle();
          expect(footerPages(), [1, 2, 4]);
        } else {
          final count = source.arguments.length;
          await controller.loadMore('/fixture');
          expect(source.arguments.length, count);
        }
        final unchangedItems = List<VideoItem>.of(state.items);
        final jump = controller.jumpListPage('/fixture', targetPage);
        source.requests.last.complete(
          VideoPage(items: unchangedItems, page: targetPage, hasMore: false),
        );
        await jump;
        await tester.pumpAndSettle();
        expect(
          footerPages(),
          [targetPage],
          reason:
              'a jump replaces sections even if the response has identical IDs',
        );
      },
    );
  }
}
