import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/modules/hanime1/hanime1_controller.dart';
import 'package:video_browser/app/modules/hanime1/views/hanime1_ranking_tab.dart';
import 'package:video_browser/app/modules/hanime1/views/hanime1_subscriptions_tab.dart';
import 'package:video_browser/app/modules/hanime1/widgets/hanime1_card.dart';
import 'package:video_browser/app/services/hanime1_auth_service.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/widgets/append_pagination_footer.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

import 'support/hanime_list_fixture.dart';

void main() {
  late int oldPreload;
  setUp(() {
    Get.testMode = true;
    oldPreload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    PreloadService.instance.preloadCount.value = oldPreload;
  });
  Future<(Hanime1Controller, HanimeListFixture)> mount(
    WidgetTester tester,
    String mode, {
    bool loggedIn = true,
    double width = 400,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = Get.put(Hanime1AuthService());
    auth.isLoggedIn.value = loggedIn;
    final source = HanimeListFixture();
    final ctrl = Get.put(Hanime1Controller(source));
    final first = mode == 'ranking'
        ? ctrl.loadRanking('本日排行')
        : ctrl.loadSubscriptions();
    if (mode == 'ranking') {
      source.rankRequests.last.complete(fixtureRank('first', 1));
    } else {
      source.subRequests.last.complete(fixtureSubscriptions('first', 1));
    }
    await first;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: RepaintBoundary(
          key: const ValueKey('list-pixels'),
          child: Scaffold(
            body: mode == 'ranking'
                ? const Hanime1RankingTab()
                : const Hanime1SubscriptionsTab(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (ctrl, source);
  }

  for (final mode in ['ranking', 'subscriptions']) {
    testWidgets('original $mode list pixels', (tester) async {
      await mount(tester, mode);
      await expectLater(
        find.byKey(const ValueKey('list-pixels')),
        matchesGoldenFile('goldens/hanime-list-$mode.png'),
      );
    });
    testWidgets(
      '$mode pending and error update footer without rebuilding old cards',
      (tester) async {
        final (ctrl, source) = await mount(tester, mode);
        var cards = 0, grids = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget is Hanime1CardH) cards++;
          if (element.widget is Hanime1VideoGridSliver) grids++;
        };
        final pending = mode == 'ranking'
            ? ctrl.loadMoreRanking()
            : ctrl.loadMoreSubscriptions();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<AppendPaginationFooter>(
                find.byType(AppendPaginationFooter),
              )
              .loading,
          isTrue,
        );
        expect(
          tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
          1,
        );
        final pendingCards = cards, pendingGrids = grids;
        cards = grids = 0;
        if (mode == 'ranking') {
          source.rankRequests.last.completeError(StateError('offline'));
        } else {
          source.subRequests.last.completeError(StateError('offline'));
        }
        await pending;
        await tester.pumpAndSettle();
        final footer = tester.widget<AppendPaginationFooter>(
          find.byType(AppendPaginationFooter),
        );
        expect(footer.loading, isFalse);
        expect(footer.error, mode == 'ranking' ? '排行加载失败，请重试' : '订阅加载失败，请重试');
        expect(ctrl.rankingVideos.length + ctrl.subVideos.length, 4);
        expect(
          pendingCards,
          0,
          reason: 'Waiting must keep the existing video cards',
        );
        expect(pendingGrids, 0);
        expect(cards, 0, reason: 'Error feedback belongs to the footer');
        expect(grids, 0);
      },
    );
    testWidgets(
      '$mode retry appends the failed page and numeric jump replaces results',
      (tester) async {
        final (ctrl, source) = await mount(tester, mode);
        Future<void> more() => mode == 'ranking'
            ? ctrl.loadMoreRanking()
            : ctrl.loadMoreSubscriptions();
        final failed = more();
        if (mode == 'ranking') {
          source.rankRequests.last.completeError(StateError('offline'));
        } else {
          source.subRequests.last.completeError(StateError('offline'));
        }
        await failed;
        await tester.pumpAndSettle();
        // Call the actual footer retry handler rather than a fake controller callback.
        tester
            .widget<AppendPaginationFooter>(find.byType(AppendPaginationFooter))
            .onNext!();
        await tester.pump();
        if (mode == 'ranking') {
          expect(source.rankArguments.last, ('本日排行', 2));
          source.rankRequests.last.complete(fixtureRank('second', 2));
        } else {
          expect(source.subArguments.last['page'], 2);
          source.subRequests.last.complete(fixtureSubscriptions('second', 2));
        }
        await tester.pumpAndSettle();
        final footers = tester
            .widgetList<PageFooterScope>(find.byType(PageFooterScope))
            .toList();
        expect(footers.map((f) => f.page), [1, 2]);
        expect(footers.map((f) => f.active), [false, true]);
        expect(ctrl.rankingVideos.length + ctrl.subVideos.length, 8);
        tester
            .widgetList<AppendPaginationFooter>(
              find.byType(AppendPaginationFooter),
            )
            .last
            .onJump!(7);
        await tester.pump();
        if (mode == 'ranking') {
          expect(source.rankArguments.last, ('本日排行', 7));
          source.rankRequests.last.complete(fixtureRank('jump', 7));
        } else {
          expect(source.subArguments.last['page'], 7);
          source.subRequests.last.complete(fixtureSubscriptions('jump', 7));
        }
        await tester.pumpAndSettle();
        expect(
          tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
          7,
        );
        expect(ctrl.rankingVideos.length + ctrl.subVideos.length, 4);
      },
    );
  }

  for (final mode in ['ranking', 'subscriptions']) {
    testWidgets(
      '$mode total and exhaustion update footer without rebuilding results',
      (tester) async {
        final (ctrl, _) = await mount(tester, mode);
        var cardBuilds = 0, gridBuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget is Hanime1CardH) cardBuilds++;
          if (element.widget is Hanime1VideoGridSliver) gridBuilds++;
        };
        final state = mode == 'ranking'
            ? ctrl.rankingPaging
            : ctrl.subscriptionsPaging;
        state.totalPages.value = 1;
        state.hasMore.value = false;
        await tester.pumpAndSettle();
        var footer = tester.widget<AppendPaginationFooter>(
          find.byType(AppendPaginationFooter),
        );
        expect(footer.totalPages, 1);
        expect(footer.hasMore, isFalse);
        expect(find.text('已到最后一页'), findsOneWidget);
        state.totalPages.value = 7;
        state.hasMore.value = true;
        await tester.pumpAndSettle();
        footer = tester.widget<AppendPaginationFooter>(
          find.byType(AppendPaginationFooter),
        );
        expect(footer.totalPages, 7);
        expect(footer.hasMore, isTrue);
        expect(cardBuilds, 0);
        expect(gridBuilds, 0);
      },
    );
  }
  testWidgets('subscriptions logged-out prompt keeps original pixels', (
    tester,
  ) async {
    await mount(tester, 'subscriptions', loggedIn: false);
    await expectLater(
      find.byKey(const ValueKey('list-pixels')),
      matchesGoldenFile('goldens/hanime-list-logged-out.png'),
    );
  });
  testWidgets(
    'ranking cycle selection requests selected ordering and resets footer',
    (tester) async {
      final (ctrl, source) = await mount(tester, 'ranking');
      await tester.tap(find.text('本週排行'));
      await tester.pump();
      expect(source.rankArguments.last, ('本週排行', 1));
      source.rankRequests.last.complete(fixtureRank('weekly', 1));
      await tester.pumpAndSettle();
      expect(ctrl.currentRankTabIndex.value, 1);
      expect(ctrl.rankingVideos.first.id, 'weekly-0');
      expect(
        tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
        1,
      );
    },
  );
  testWidgets('creator selection carries filters and updates the result list', (
    tester,
  ) async {
    final (ctrl, source) = await mount(tester, 'subscriptions');
    ctrl.subscriptionGenre.value = 'fixture genre';
    ctrl.subscriptionTags.assignAll(['fixture tag']);
    ctrl.subscriptionBroad.value = true;
    await tester.tap(find.text('Fixture creator'));
    await tester.pump();
    expect(source.subArguments.last, {
      'page': 1,
      'query': 'Fixture creator',
      'genre': 'fixture genre',
      'sort': '',
      'date': '',
      'duration': '',
      'tags': ['fixture tag'],
      'broad': true,
    });
    source.subRequests.last.complete(fixtureSubscriptions('creator', 1));
    await tester.pumpAndSettle();
    expect(ctrl.selectedCreator.value, 'Fixture creator');
    expect(ctrl.subVideos.first.id, 'creator-0');
  });
  testWidgets(
    'subscription login prompt reacts while existing results stay visible',
    (tester) async {
      final (ctrl, _) = await mount(tester, 'subscriptions', loggedIn: false);
      expect(find.text('未登录 Hanime1 账号'), findsOneWidget);
      final ids = ctrl.subVideos.map((v) => v.id).toList();
      Hanime1AuthService.to.isLoggedIn.value = true;
      await tester.pumpAndSettle();
      expect(find.text('未登录 Hanime1 账号'), findsNothing);
      expect(ctrl.subVideos.map((v) => v.id), ids);
      expect(find.byType(Hanime1CardH), findsNWidgets(4));
      expect(
        tester.widget<PageFooterScope>(find.byType(PageFooterScope)).page,
        1,
      );
    },
  );
}
