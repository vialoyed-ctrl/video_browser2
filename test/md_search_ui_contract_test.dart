import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/search/site91md_search_controller.dart';
import 'package:video_browser/app/modules/search/site91md_search_view.dart';
import 'package:video_browser/app/widgets/append_pagination_footer.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

import 'support/md_search_fixture.dart';

void main() {
  tearDown(() => debugOnRebuildDirtyWidget = null);
  Future<(Site91MdSearchController, MdSearchFixture)> mount(
    WidgetTester tester, {
    double width = 400,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = MdSearchFixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: RepaintBoundary(
          key: const ValueKey('md-pixels'),
          child: Site91MdSearchView(source: source, initialKeyword: 'fixture'),
        ),
      ),
    );
    source.requests.single.complete(mdResponse('first', 1));
    await tester.pumpAndSettle();
    final controller = tester
        .widgetList<AnimatedBuilder>(find.byType(AnimatedBuilder))
        .map((w) => w.animation)
        .whereType<Site91MdSearchController>()
        .first;
    return (controller, source);
  }

  for (final scenario in ['empty append', 'same-prefix replacement']) {
    testWidgets('md $scenario preserves accepted page sections', (
      tester,
    ) async {
      final (controller, source) = await mount(tester);
      final next = controller.loadMore();
      source.requests.last.complete(mdResponse('second', 2));
      await next;
      await tester.pumpAndSettle();
      List<int> sections() => tester
          .widgetList<PageFooterScope>(find.byType(PageFooterScope))
          .map((s) => s.page)
          .toList();
      expect(sections(), [1, 2]);
      final before = List.of(controller.items);
      final operation = scenario == 'empty append'
          ? controller.loadMore()
          : controller.goToPage(2);
      await tester.pump();
      expect(sections(), [1, 2]);
      source.requests.last.complete(
        VideoPage(
          items: scenario == 'empty append' ? [] : before,
          page: scenario == 'empty append' ? 3 : 2,
          totalPages: 20,
          hasMore: true,
        ),
      );
      await operation;
      await tester.pumpAndSettle();
      expect(sections(), scenario == 'empty append' ? [1, 2] : [2]);
      expect(controller.items, before);
      final failed = controller.goToPage(7);
      source.requests.last.completeError(StateError('offline'));
      await failed;
      await tester.pumpAndSettle();
      expect(sections(), scenario == 'empty append' ? [1, 2] : [2]);
      expect(controller.items, before);
    });
  }

  for (final width in [400.0, 800.0]) {
    testWidgets('original md search geometry at $width', (tester) async {
      await mount(tester, width: width);
      await expectLater(
        find.byKey(const ValueKey('md-pixels')),
        matchesGoldenFile('goldens/md-search-${width.toInt()}.png'),
      );
    });
  }
  testWidgets(
    'md waiting and failure update footer without rebuilding old cards',
    (tester) async {
      final (controller, source) = await mount(tester);
      var cards = 0, grids = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is BiliVideoCardV) cards++;
        if (element.widget is SliverGrid) grids++;
      };
      final pending = controller.loadMore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.arguments.last, ('fixture', 2, 12));
      expect(controller.items.length, 4);
      expect(controller.page, 1);
      final footer = tester.widget<AppendPaginationFooter>(
        find.byType(AppendPaginationFooter),
      );
      expect(footer.loading, true);
      expect(footer.error, isNull);
      expect(cards, 0, reason: 'waiting only changes status');
      expect(grids, 0);
      source.requests.last.completeError(StateError('offline'));
      await pending;
      await tester.pumpAndSettle();
      final failed = tester.widget<AppendPaginationFooter>(
        find.byType(AppendPaginationFooter),
      );
      expect(failed.loading, false);
      expect(failed.error, isNotNull);
      expect(controller.items.length, 4);
      expect(cards, 0);
      expect(grids, 0);
    },
  );
  testWidgets(
    'md retry appends both sections and numeric jump replaces content',
    (tester) async {
      final (controller, source) = await mount(tester);
      final failed = controller.loadMore();
      source.requests.last.completeError(StateError('offline'));
      await failed;
      await tester.pumpAndSettle();
      tester
          .widget<AppendPaginationFooter>(find.byType(AppendPaginationFooter))
          .onNext!();
      expect(source.arguments.last, ('fixture', 2, 12));
      source.requests.last.complete(mdResponse('second', 2));
      await tester.pumpAndSettle();
      expect(controller.items.length, 8);
      expect(
        tester
            .widgetList<PageFooterScope>(find.byType(PageFooterScope))
            .map((w) => (w.page, w.active)),
        [(1, false), (2, true)],
      );
      tester
          .widgetList<AppendPaginationFooter>(
            find.byType(AppendPaginationFooter),
          )
          .last
          .onJump!(7);
      expect(source.arguments.last, ('fixture', 7, 12));
      source.requests.last.complete(mdResponse('jump', 7, more: false));
      await tester.pumpAndSettle();
      expect(controller.items.length, 4);
      expect(find.text('Fixture first 0'), findsNothing);
      expect(find.text('Fixture jump 0'), findsOneWidget);
      expect(
        tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
        7,
      );
      expect(
        tester
            .widget<AppendPaginationFooter>(find.byType(AppendPaginationFooter))
            .hasMore,
        false,
      );
      expect(find.text('已到最后一页'), findsOneWidget);
    },
  );
  testWidgets(
    'md clear invalidates pending response and new keyword replaces results',
    (tester) async {
      final (_, source) = await mount(tester);
      await tester.enterText(find.byType(TextField), 'new');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(source.arguments.last, ('new', 1, 12));
      source.requests.last.complete(mdResponse('new', 1));
      await tester.pumpAndSettle();
      expect(find.text('Fixture new 0'), findsOneWidget);
      expect(find.text('Fixture first 0'), findsNothing);
      await tester.enterText(find.byType(TextField), 'late');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      source.requests.last.complete(mdResponse('late', 1));
      await tester.pumpAndSettle();
      expect(find.text('输入关键词，搜索官网视频'), findsOneWidget);
      expect(find.byType(BiliVideoCardV), findsNothing);
    },
  );
  testWidgets('md removing route ignores pending append completion', (
    tester,
  ) async {
    final (controller, source) = await mount(tester);
    final pending = controller.loadMore();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    source.requests.last.complete(mdResponse('late', 2));
    await pending;
    await tester.pumpAndSettle();
    expect(controller.items.length, 4);
    expect(tester.takeException(), isNull);
  });
  testWidgets('md retained grid adapts when available width changes', (
    tester,
  ) async {
    await mount(tester);
    int columns() =>
        (tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    expect(columns(), 2);
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pumpAndSettle();
    expect(columns(), 3);
    expect(find.byType(BiliVideoCardV), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'md same page and ids with new card metadata invalidate retained snapshot',
    (tester) async {
      final (controller, source) = await mount(tester);
      final pending = controller.goToPage(1);
      source.requests.last.complete(
        VideoPage(
          items: List.generate(
            4,
            (i) => VideoItem(
              id: 'first-$i',
              title: 'Updated $i',
              author: '91麻豆',
              hlsUrl: '',
            ),
          ),
          page: 1,
          totalPages: 20,
          hasMore: true,
        ),
      );
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Updated 0'), findsOneWidget);
      expect(find.text('Fixture first 0'), findsNothing);
      expect(
        tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
        1,
      );
    },
  );
}
