import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_search_page.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_video_grid.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_playlist_card.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

import 'support/ph_search_fixture.dart';

void main() {
  final source = PhSearchFixture();
  SourceRegistry.register(source);
  setUp(
    () => source
      ..arguments.clear()
      ..requests.clear(),
  );
  tearDown(() => debugOnRebuildDirtyWidget = null);
  Future<void> mount(WidgetTester tester, String kind) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: RepaintBoundary(
          key: const ValueKey('ph-search-pixels'),
          child: const PornHubSearchPage(initialKeyword: 'fixture'),
        ),
      ),
    );
    source.requests.last.complete(phSearchResponse('videos', 'first'));
    await tester.pumpAndSettle();
    if (kind != 'videos') {
      await tester.tap(
        find.text({'clips': '切片', 'creators': '创作者', 'playlists': '片单'}[kind]!),
      );
      await tester.pump();
      source.requests.last.complete(phSearchResponse(kind, 'first'));
      await tester.pumpAndSettle();
    }
  }

  PornHubListFooter footer(WidgetTester tester) =>
      tester.widgetList<PornHubListFooter>(find.byType(PornHubListFooter)).last;
  testWidgets(
    'ph ignored empty submit cannot reset scroll during pending refresh',
    (tester) async {
      await mount(tester, 'videos');
      footer(tester).onLoadMore!();
      source.requests.last.complete(
        PornHubBrowseData(
          videos: List.generate(
            20,
            (i) => VideoItem(
              id: 'long-$i',
              title: 'Fixture long $i',
              author: '',
              hlsUrl: '',
            ),
          ),
          hasMore: true,
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(150);
      await tester.pumpAndSettle();
      final before = scroll.position.pixels;
      expect(before, greaterThan(0));
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      final requests = source.requests.length;
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(source.requests.length, requests);
      expect(scroll.position.pixels, closeTo(before, .01));
      source.requests.last.complete(phSearchResponse('videos', 'refreshed'));
      await refresh;
      await tester.pumpAndSettle();
    },
  );
  testWidgets('ph nonempty source total renders the numeric count', (
    tester,
  ) async {
    await mount(tester, 'videos');
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    source.requests.last.complete(
      PornHubBrowseData(
        videos: phSearchResponse('videos', 'total').videos,
        hasMore: true,
        total: 123,
      ),
    );
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('官网共 123 条 · 已加载 4 条'), findsOneWidget);
  });
  for (final kind in ['videos', 'clips', 'creators', 'playlists']) {
    testWidgets('original ph $kind search geometry', (tester) async {
      await mount(tester, kind);
      await expectLater(
        find.byKey(const ValueKey('ph-search-pixels')),
        matchesGoldenFile('goldens/ph-search-$kind.png'),
      );
    });
    testWidgets('ph $kind wait and failure retain results without rebuilding', (
      tester,
    ) async {
      await mount(tester, kind);
      var cards = 0, lists = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is BiliVideoCardV ||
            e.widget is PornHubPlaylistCard ||
            e.widget is ListTile) {
          cards++;
        }
        if (e.widget is SliverGrid || e.widget is SliverList) lists++;
      };
      footer(tester).onLoadMore!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.arguments.last.$2, 2);
      expect(source.arguments.last.$3, kind);
      expect(footer(tester).currentPage, 1);
      expect(footer(tester).isLoadingMore, true);
      expect(footer(tester).errorText, isNull);
      expect(
        cards,
        0,
        reason: 'status changes must preserve old result widgets',
      );
      expect(lists, 0);
      source.requests.last.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(footer(tester).isLoadingMore, false);
      expect(footer(tester).errorText, isNotNull);
      expect(cards, 0);
      expect(lists, 0);
    });
    testWidgets('ph $kind retry appends and jump replaces displayed results', (
      tester,
    ) async {
      await mount(tester, kind);
      footer(tester).onLoadMore!();
      source.requests.last.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      footer(tester).onLoadMore!();
      expect(source.arguments.last.$2, 2);
      source.requests.last.complete(phSearchResponse(kind, 'second'));
      await tester.pumpAndSettle();
      expect(footer(tester).currentPage, 2);
      expect(find.text('Fixture first 0'), findsOneWidget);
      expect(find.text('Fixture second 0'), findsOneWidget);
      if (kind == 'videos' || kind == 'clips') {
        expect(
          tester
              .widgetList<PageFooterScope>(find.byType(PageFooterScope))
              .map((w) => (w.page, w.active)),
          [(1, false), (2, true)],
        );
      }
      footer(tester).onJump!(7);
      expect(source.arguments.last.$2, 7);
      source.requests.last.complete(
        phSearchResponse(kind, 'jump', more: false),
      );
      await tester.pumpAndSettle();
      expect(footer(tester).currentPage, 7);
      expect(footer(tester).hasMore, false);
      expect(find.text('Fixture first 0'), findsNothing);
      expect(find.text('Fixture jump 0'), findsOneWidget);
    });
  }
  testWidgets('ph kind and member scope preserve original emitted paths', (
    tester,
  ) async {
    await mount(tester, 'clips');
    expect(source.arguments.last, ('/clips?search=fixture', 1, 'clips'));
    await tester.tap(find.text('创作者'));
    await tester.pump();
    expect(source.arguments.last, (
      '/user/search?username=fixture&gender=0',
      1,
      'creators',
    ));
    source.requests.last.complete(phSearchResponse('creators', 'first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('明星'));
    await tester.pump();
    expect(source.arguments.last, (
      '/pornstars/search?search=fixture',
      1,
      'creators',
    ));
    source.requests.last.complete(phSearchResponse('creators', 'star'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片单'));
    await tester.pump();
    expect(source.arguments.last, ('/playlists?o=mr', 1, 'playlists'));
    source.requests.last.complete(phSearchResponse('playlists', 'first'));
    await tester.pumpAndSettle();
  });
  testWidgets(
    'ph new keyword suppresses older response and route dispose ignores late reply',
    (tester) async {
      await mount(tester, 'videos');
      footer(tester).onLoadMore!();
      final old = source.requests.last;
      await tester.enterText(find.byType(TextField), 'new');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(source.arguments.last, ('/video/search?search=new', 1, 'videos'));
      source.requests.last.complete(phSearchResponse('videos', 'new'));
      await tester.pumpAndSettle();
      old.complete(phSearchResponse('videos', 'old'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture old 0'), findsNothing);
      expect(find.text('Fixture new 0'), findsOneWidget);
      footer(tester).onLoadMore!();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      source.requests.last.complete(phSearchResponse('videos', 'late'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  for (final kind in ['videos', 'clips', 'creators', 'playlists']) {
    testWidgets(
      'ph $kind same identities with fresh metadata update on refresh',
      (tester) async {
        await mount(tester, kind);
        final pending = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        expect(source.arguments.last.$2, 1);
        source.requests.last.complete(
          PornHubBrowseData(
            videos: kind == 'videos' || kind == 'clips'
                ? List.generate(
                    4,
                    (i) => VideoItem(
                      id: 'first-$i',
                      title: 'Fixture updated $i',
                      author: '',
                      hlsUrl: '',
                    ),
                  )
                : const [],
            creators: kind == 'creators'
                ? List.generate(
                    4,
                    (i) => PornHubSubscription(
                      name: 'Fixture updated $i',
                      path: '/user/first-$i',
                    ),
                  )
                : const [],
            playlists: kind == 'playlists'
                ? List.generate(
                    4,
                    (i) => PornHubPlaylist(
                      id: 'first-$i',
                      title: 'Fixture updated $i',
                      url: '/playlist/first-$i',
                      videoCount: 11,
                    ),
                  )
                : const [],
            hasMore: true,
          ),
        );
        await pending;
        await tester.pumpAndSettle();
        expect(footer(tester).currentPage, 1);
        expect(find.text('Fixture updated 0'), findsOneWidget);
        expect(find.text('Fixture first 0'), findsNothing);
      },
    );
  }
  testWidgets('ph cached video results react to live width changes', (
    tester,
  ) async {
    await mount(tester, 'videos');
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
  Future<void> installFilters(WidgetTester tester) async {
    final pending = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    source.requests.last.complete(
      PornHubBrowseData(
        videos: phSearchResponse('videos', 'first').videos,
        hasMore: true,
        filters: const [
          PornHubFilterGroup(
            key: 'o',
            title: 'Fixture order',
            options: [PornHubLinkItem(name: 'Fixture ranked', path: 'tr')],
          ),
        ],
      ),
    );
    await pending;
    await tester.pumpAndSettle();
  }

  testWidgets('ph cancelling filter sheet does not emit another request', (
    tester,
  ) async {
    await mount(tester, 'videos');
    await installFilters(tester);
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture ranked'));
    await tester.pump();
    Navigator.of(tester.element(find.text('官网筛选'))).pop();
    await tester.pumpAndSettle();
    expect(source.arguments.length, 2);
    expect(footer(tester).isLoadingMore, false);
    expect(find.text('Fixture first 0'), findsOneWidget);
  });
  testWidgets(
    'ph applying filters keeps exact request parameters and clears old results',
    (tester) async {
      await mount(tester, 'videos');
      await installFilters(tester);
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture ranked'));
      await tester.pump();
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
        const RangeValues(10, 30),
      );
      await tester.pump();
      await tester.tap(find.text('显示结果'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(source.arguments.last, (
        '/video/search?o=tr&min_duration=10&max_duration=30&search=fixture',
        1,
        'videos',
      ));
      expect(find.byType(BiliVideoCardV), findsNothing);
      source.requests.last.complete(phSearchResponse('videos', 'filtered'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture filtered 0'), findsOneWidget);
      expect(find.text('Fixture first 0'), findsNothing);
    },
  );
  testWidgets(
    'ph initial browse path remains a browse path after filter apply',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        GetMaterialApp(
          home: const PornHubSearchPage(initialPath: '/video?o=mv'),
        ),
      );
      source.requests.last.complete(
        PornHubBrowseData(
          videos: phSearchResponse('videos', 'first').videos,
          hasMore: true,
          filters: const [
            PornHubFilterGroup(
              key: 'o',
              title: 'Fixture order',
              options: [PornHubLinkItem(name: 'Fixture ranked', path: 'tr')],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture ranked'));
      await tester.pump();
      await tester.tap(find.text('显示结果'));
      await tester.pump();
      expect(source.arguments.last, ('/video?o=tr', 1, 'videos'));
      source.requests.last.complete(phSearchResponse('videos', 'filtered'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture filtered 0'), findsOneWidget);
    },
  );
}
