import 'dart:async';

import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';
import 'package:video_browser/app/modules/search/search_view.dart';
import 'package:video_browser/app/modules/hanime1/widgets/hanime1_card.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';
import 'package:video_browser/app/widgets/append_pagination_footer.dart';

class FixtureSource implements VideoSource {
  FixtureSource(this.id);
  @override
  final String id;
  final arguments = <(SearchQuery, int, int)>[];
  final requests = <Completer<VideoPage>>[];
  @override
  Future<List<String>> fetchHotKeywords() async => const [];
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) {
    arguments.add((query, page, pageSize));
    final request = Completer<VideoPage>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<VideoItem> cards(String prefix) => List.generate(
  4,
  (i) => VideoItem(
    id: '$prefix-$i',
    title: 'Fixture $prefix $i',
    author: '',
    hlsUrl: '',
  ),
);

void main() {
  late int oldPreload;
  setUp(() {
    Get.testMode = true;
    Get.put(UserService());
    oldPreload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    PreloadService.instance.preloadCount.value = oldPreload;
  });
  Future<(SearchController, FixtureSource)> mount(
    WidgetTester tester,
    String mode, {
    double width = 400,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = FixtureSource(mode == '91' ? 'site91' : 'hanime1');
    final controller = SearchController(source);
    controller.keyword.value = 'fixture';
    controller.input.text = 'fixture';
    controller.hasSearched.value = true;
    controller.results.assignAll(cards('first'));
    controller.totalPages.value = 20;
    controller.hasMore.value = true;
    if (mode == 'poster') controller.category.value = '裏番';
    if (mode == 'studio') controller.searchType.value = SearchType.authorId;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: RepaintBoundary(
          key: const ValueKey('search-pixels'),
          child: SearchView(searchController: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, source);
  }

  for (final mode in ['91', 'horizontal', 'poster', 'studio']) {
    testWidgets('original $mode search pixels', (tester) async {
      await mount(tester, mode);
      await expectLater(
        find.byKey(const ValueKey('search-pixels')),
        matchesGoldenFile('goldens/search-$mode.png'),
      );
    });
    testWidgets('$mode page loading retains cards without rebuilding results', (
      tester,
    ) async {
      final (controller, source) = await mount(tester, mode);
      var cardBuilds = 0, gridBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is BiliVideoCardV ||
            element.widget is Hanime1CardH ||
            element.widget.runtimeType.toString() == 'Hanime1PosterCard') {
          cardBuilds++;
        }
        if (element.widget is SliverGrid ||
            element.widget is Hanime1VideoGridSliver ||
            element.widget is Hanime1PosterGridSliver ||
            element.widget.runtimeType.toString() ==
                '_Hanime1StudioGridSliver') {
          gridBuilds++;
        }
      };
      final pending = controller.goToPage(2, append: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.arguments.single.$1.keyword, 'fixture');
      expect(source.arguments.single.$2, 2);
      expect(source.arguments.single.$3, 24);
      expect(controller.results.length, 4);
      expect(controller.currentPage.value, 1);
      final waitingFooter = tester.widget<AppendPaginationFooter>(
        find.byType(AppendPaginationFooter, skipOffstage: false),
      );
      expect(waitingFooter.loading, isTrue);
      expect(waitingFooter.error, isNull);
      expect(
        tester
            .widgetList<PageFooterScope>(
              find.byType(PageFooterScope, skipOffstage: false),
            )
            .map((scope) => scope.page),
        [1],
      );
      expect(
        cardBuilds,
        0,
        reason: 'loading should update pagination rather than old cards',
      );
      expect(
        gridBuilds,
        0,
        reason: 'an unchanged result list retains its grid',
      );
      source.requests.last.completeError(StateError('offline'));
      await pending;
      await tester.pumpAndSettle();
      expect(controller.error.value, isNotNull);
      expect(controller.results.length, 4);
      final failedFooter = tester.widget<AppendPaginationFooter>(
        find.byType(AppendPaginationFooter, skipOffstage: false),
      );
      expect(failedFooter.loading, isFalse);
      expect(failedFooter.error, controller.error.value);
      expect(cardBuilds, 0);
      expect(gridBuilds, 0);
    });
  }
  testWidgets('original wide 91 search pixels', (tester) async {
    await mount(tester, '91', width: 900);
    await expectLater(
      find.byKey(const ValueKey('search-pixels')),
      matchesGoldenFile('goldens/search-91-wide.png'),
    );
  });
  for (final scenario in ['empty append', 'same-prefix replacement']) {
    testWidgets('91 search accepted boundary contract $scenario', (
      tester,
    ) async {
      final (controller, source) = await mount(tester, '91');
      final next = controller.goToPage(2, append: true);
      source.requests.last.complete(
        VideoPage(
          items: cards('second'),
          page: 2,
          totalPages: 20,
          hasMore: true,
        ),
      );
      await next;
      await tester.pumpAndSettle();
      List<int> sections() => tester
          .widgetList<PageFooterScope>(
            find.byType(PageFooterScope, skipOffstage: false),
          )
          .map((w) => w.page)
          .toList();
      expect(sections(), [1, 2]);
      final before = List.of(controller.results);
      if (scenario != 'empty append') {
        final requests = source.requests.length;
        await controller.goToPage(2);
        expect(
          source.requests.length,
          requests,
          reason: 'Same-page navigation remains a no-op',
        );
        expect(sections(), [1, 2]);
      }
      final pending = scenario == 'empty append'
          ? controller.goToPage(3, append: true)
          : controller.runSearch();
      source.requests.last.complete(
        VideoPage(
          items: scenario == 'empty append' ? [] : before,
          page: scenario == 'empty append' ? 3 : 1,
          totalPages: 20,
          hasMore: true,
        ),
      );
      await pending;
      await tester.pumpAndSettle();
      expect(sections(), scenario == 'empty append' ? [1, 2] : [1]);
      expect(controller.results, before);
    });
  }

  testWidgets('91 failed append retries the same page and jump resets scroll', (
    tester,
  ) async {
    final (controller, source) = await mount(tester, '91');
    final pending = controller.goToPage(2, append: true);
    source.requests.last.completeError(StateError('offline'));
    await pending;
    await tester.pumpAndSettle();
    controller.nextPage();
    await tester.pump();
    expect(source.arguments.map((a) => a.$2), [2, 2]);
    source.requests.last.complete(
      VideoPage(items: cards('second'), page: 2, totalPages: 20, hasMore: true),
    );
    await tester.pumpAndSettle();
    expect(controller.results.length, 8);
    expect(
      tester
          .widgetList<PageFooterScope>(
            find.byType(PageFooterScope, skipOffstage: false),
          )
          .map((scope) => scope.page),
      [1, 2],
    );
    controller.scroll.jumpTo(150);
    await tester.pump();
    final jump = controller.goToPage(7);
    source.requests.last.complete(
      VideoPage(items: cards('jump'), page: 7, totalPages: 20, hasMore: true),
    );
    await jump;
    await tester.pumpAndSettle();
    expect(controller.results.map((v) => v.id), [
      'jump-0',
      'jump-1',
      'jump-2',
      'jump-3',
    ]);
    expect(controller.scroll.offset, 0);
    expect(
      tester
          .widgetList<PageFooterScope>(
            find.byType(PageFooterScope, skipOffstage: false),
          )
          .map((scope) => scope.page),
      [7],
    );
  });
  testWidgets('studio card opens artist video search using its title', (
    tester,
  ) async {
    final (controller, source) = await mount(tester, 'studio');
    await tester.tap(find.text('Fixture first 0'));
    await tester.pump();
    expect(controller.searchType.value, SearchType.videoName);
    expect(source.arguments.single.$1.keyword, 'Fixture first 0');
    expect(source.arguments.single.$1.searchType, SearchType.videoName);
    expect(source.arguments.single.$2, 1);
    source.requests.last.complete(const VideoPage.empty());
    await tester.pumpAndSettle();
  });
}
