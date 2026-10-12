import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_creator_page.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_playlist_page.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_video_grid.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';
import 'package:video_browser/app/services/preload_service.dart';

import 'support/ph_route_fixture.dart';

void main() {
  final source = PhRouteFixture();
  SourceRegistry.register(source);
  setUp(() {
    source.actions.clear();
    source.actionArguments.clear();
    source.requests.clear();
    source.arguments.clear();
    source.profiles.clear();
    source.details.clear();
    source.detailRefreshes.clear();
    PreloadService.instance.preloadCount.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('PonnamKarthik/fluttertoast'),
          (call) async => true,
        );
  });
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('PonnamKarthik/fluttertoast'),
          null,
        );
  });
  Future<void> mount(WidgetTester tester, String mode) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: mode == 'playlist'
            ? const PornHubPlaylistPage(id: '123')
            : const PornHubCreatorPage(
                name: 'Fixture creator',
                path: '/model/fixture',
              ),
      ),
    );
    if (mode == 'playlist') {
      source.details.last.complete(routeDetails);
      await tester.pump();
    } else {
      source.profiles.last.complete(routeProfile);
    }
    source.requests.last.complete(routePage(routeCards('first'), 1));
    await tester.pumpAndSettle();
    if (mode == 'clips') {
      await tester.tap(find.text('切片'));
      await tester.pump();
      source.requests.last.complete(routePage(routeCards('first'), 1));
      await tester.pumpAndSettle();
    }
  }

  PornHubListFooter footer(WidgetTester tester) =>
      tester.widgetList<PornHubListFooter>(find.byType(PornHubListFooter)).last;
  List<int> sections(WidgetTester tester) => tester
      .widgetList<PageFooterScope>(
        find.byType(PageFooterScope, skipOffstage: false),
      )
      .map((w) => w.page)
      .toList();
  for (final mode in ['videos', 'clips', 'playlist']) {
    testWidgets('$mode waiting and failure retain existing grid builds', (
      tester,
    ) async {
      await mount(tester, mode);
      var cards = 0, grids = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is BiliVideoCardV) cards++;
        if (e.widget is SliverPornHubGrid) grids++;
      };
      footer(tester).onLoadMore!();
      await tester.pump();
      expect(footer(tester).isLoadingMore, isTrue);
      source.requests.last.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(footer(tester).errorText, isNotNull);
      expect(cards, 0);
      expect(grids, 0);
      expect(find.byType(BiliVideoCardV), findsNWidgets(4));
    });
    for (final scenario in ['empty append', 'same-prefix replacement']) {
      testWidgets('$mode $scenario retains accepted page meaning', (
        tester,
      ) async {
        await mount(tester, mode);
        footer(tester).onLoadMore!();
        source.requests.last.complete(routePage(routeCards('second'), 2));
        await tester.pumpAndSettle();
        expect(sections(tester), [1, 2]);
        final retained = tester.widget<RetainedPageSliver>(
          find.byType(RetainedPageSliver),
        );
        if (scenario == 'empty append') {
          footer(tester).onLoadMore!();
        } else {
          footer(tester).onJump!(2);
          if (mode == 'playlist') {
            source.details.last.complete(routeDetails);
            await tester.pump();
          }
        }
        source.requests.last.complete(
          routePage(
            scenario == 'empty append' ? [] : retained.items,
            scenario == 'empty append' ? 3 : 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(sections(tester), scenario == 'empty append' ? [1, 2] : [2]);
        expect(find.byType(BiliVideoCardV), findsNWidgets(8));
      });
    }
  }
  testWidgets('creator profile refresh leaves card results untouched', (
    tester,
  ) async {
    await mount(tester, 'videos');
    var cards = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (e.widget is BiliVideoCardV) cards++;
    };
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    source.profiles.last.complete(routeProfile);
    await tester.pump();
    source.requests.last.completeError(StateError('offline'));
    await refresh;
    await tester.pumpAndSettle();
    expect(cards, 0);
    expect(find.text('共 80 个视频'), findsOneWidget);
  });

  for (final mode in ['videos', 'playlist']) {
    testWidgets('$mode account action busy leaves existing cards stable', (
      tester,
    ) async {
      await mount(tester, mode);
      var cards = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is BiliVideoCardV) cards++;
      };
      await tester.tap(find.text(mode == 'playlist' ? '收藏片单' : '订阅'));
      await tester.pump();
      expect(find.text(mode == 'playlist' ? '保存中…' : '处理中'), findsOneWidget);
      expect(source.actions.length, 1);
      source.actions.last.complete((
        ok: false,
        message: 'Fixture action rejected',
      ));
      await tester.pumpAndSettle();
      // Fluttertoast owns a one-second delayed flag reset even with a mocked channel.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(mode == 'playlist' ? '收藏片单' : '订阅'), findsOneWidget);
      expect(cards, 0);
      expect(
        source.actionArguments.single,
        mode == 'playlist' ? '123:false' : '',
      );
    });
  }
  testWidgets(
    'playlist account reset clears cached cards and rejects pending append',
    (tester) async {
      final auth = PornHubAuthService();
      Get.put<PornHubAuthService>(auth);
      await mount(tester, 'playlist');
      footer(tester).onLoadMore!();
      final stale = source.requests.last;
      await tester.pump();
      auth.sessionRevision.value++;
      await tester.pumpAndSettle();
      expect(find.byType(BiliVideoCardV), findsNothing);
      expect(find.text('0 个视频 · 已加载 0'), findsOneWidget);
      expect(
        tester
            .widget<RetainedPageSliver>(find.byType(RetainedPageSliver))
            .items,
        isEmpty,
      );
      stale.complete(routePage(routeCards('stale'), 2));
      await tester.pumpAndSettle();
      expect(find.byType(BiliVideoCardV), findsNothing);
      auth.isLoggedIn.value = true;
      await tester.pump();
      source.details.last.complete(routeDetails);
      await tester.pump();
      source.requests.last.complete(routePage(routeCards('fresh'), 1));
      await tester.pumpAndSettle();
      expect(find.text('Fixture fresh 0'), findsOneWidget);
      expect(find.text('Fixture first 0'), findsNothing);
    },
  );
}
