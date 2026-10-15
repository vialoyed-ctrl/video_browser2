import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/hanime1_models.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/hanime1/hanime1_controller.dart';
import 'package:video_browser/app/modules/hanime1/views/hanime1_ranking_tab.dart';
import 'package:video_browser/app/modules/hanime1/views/hanime1_subscriptions_tab.dart';
import 'package:video_browser/app/services/hanime1_auth_service.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

import 'support/hanime_list_fixture.dart';

void main() {
  late int preload;
  setUp(() {
    Get.testMode = true;
    preload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(() {
    Get.reset();
    PreloadService.instance.preloadCount.value = preload;
  });
  for (final mode in ['ranking', 'subscriptions']) {
    for (final scenario in ['empty append', 'same-prefix replacement']) {
      testWidgets('$mode $scenario retains correct page sections', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 1600);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Get.put(Hanime1AuthService()).isLoggedIn.value = true;
        final source = HanimeListFixture();
        final ctrl = Get.put(Hanime1Controller(source));
        Future<void> load(int page, {bool append = false}) => mode == 'ranking'
            ? ctrl.loadRanking('本日排行', page: page, append: append)
            : ctrl.loadSubscriptions(page: page, append: append);
        void complete(int page, List<String> prefixes) {
          final items = prefixes.expand(fixtureCards).toList();
          if (mode == 'ranking') {
            source.rankRequests.last.complete(
              VideoPage(
                items: items,
                page: page,
                totalPages: 20,
                hasMore: true,
              ),
            );
          } else {
            source.subRequests.last.complete(
              Hanime1SubscriptionData(
                creators: const [],
                filters: const [],
                items: items,
                page: page,
                totalPages: 20,
                hasMore: true,
              ),
            );
          }
        }

        final first = load(1);
        complete(1, ['first']);
        await first;
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(
              body: mode == 'ranking'
                  ? const Hanime1RankingTab()
                  : const Hanime1SubscriptionsTab(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final second = load(2, append: true);
        complete(2, ['second']);
        await second;
        await tester.pumpAndSettle();
        List<int> sections() => tester
            .widgetList<PageFooterScope>(find.byType(PageFooterScope))
            .map((s) => s.page)
            .toList();
        expect(sections(), [1, 2]);
        final operation = scenario == 'empty append'
            ? load(3, append: true)
            : load(2);
        await tester.pump();
        expect(sections(), [
          1,
          2,
        ], reason: 'Pending requests cannot discard loaded sections');
        complete(
          scenario == 'empty append' ? 3 : 2,
          scenario == 'empty append' ? [] : ['first', 'second'],
        );
        await operation;
        await tester.pumpAndSettle();
        expect(sections(), scenario == 'empty append' ? [1, 2] : [2]);
        expect(
          (mode == 'ranking' ? ctrl.rankingPage : ctrl.subscriptionsPage).value,
          scenario == 'empty append' ? 3 : 2,
        );
        expect(
          (mode == 'ranking' ? ctrl.rankingVideos : ctrl.subVideos).length,
          8,
        );
        final state = mode == 'ranking'
            ? ctrl.rankingPaging
            : ctrl.subscriptionsPaging;
        final generation = state.replacementGeneration.value;
        if (scenario == 'empty append') {
          final next = load(4, append: true);
          complete(4, ['fourth']);
          await next;
          await tester.pumpAndSettle();
          expect(sections(), [1, 2, 4]);
          expect(state.replacementGeneration.value, generation);
          expect(state.items.length, 12);
        }
        final beforeFailure = sections();
        final appendBeforeFailure = state.lastLoadWasAppend;
        final failed = load(7);
        if (mode == 'ranking') {
          source.rankRequests.last.completeError(StateError('offline'));
        } else {
          source.subRequests.last.completeError(StateError('offline'));
        }
        await failed;
        await tester.pumpAndSettle();
        expect(
          sections(),
          beforeFailure,
          reason: 'Failed replacement cannot choose new section ownership',
        );
        expect(state.replacementGeneration.value, generation);
        expect(state.lastLoadWasAppend, appendBeforeFailure);
        final old = load(8);
        final fresh = load(9);
        complete(9, ['fresh']);
        await fresh;
        await tester.pumpAndSettle();
        final freshGeneration = state.replacementGeneration.value;
        if (mode == 'ranking') {
          source.rankRequests[source.rankRequests.length - 2].complete(
            fixtureRank('stale', 8),
          );
        } else {
          source.subRequests[source.subRequests.length - 2].complete(
            fixtureSubscriptions('stale', 8),
          );
        }
        await old;
        await tester.pumpAndSettle();
        expect(sections(), [9]);
        expect(state.replacementGeneration.value, freshGeneration);
        expect(state.items.first.id, 'fresh-0');
        expect(state.lastLoadWasAppend, isFalse);
        final closing = load(10, append: true);
        await tester.pumpWidget(const SizedBox.shrink());
        await Get.delete<Hanime1Controller>(force: true);
        complete(10, ['closed']);
        await closing;
        expect(state.replacementGeneration.value, freshGeneration);
        expect(state.lastLoadWasAppend, isFalse);
        expect(state.items.first.id, 'fresh-0');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
