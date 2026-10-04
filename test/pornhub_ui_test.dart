import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_playlist_card.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_subscriptions_tab.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_mine_tab.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_video_info_panel.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';

VideoItem item(String id) =>
    VideoItem(id: id, title: id, author: 'Author', hlsUrl: '');

class UiSource extends PornHubSource {
  final details = <String, Completer<PornHubDetailExtra>>{};
  final browsePaths = <String>[];
  @override
  Future<PornHubDetailExtra> fetchDetailExtra(
    String id, {
    bool forceRefresh = false,
  }) => details.putIfAbsent(id, Completer<PornHubDetailExtra>.new).future;
  @override
  Future<PornHubBrowseData> fetchBrowse(
    String path, {
    int page = 1,
    String kind = 'videos',
  }) async {
    browsePaths.add(path);
    return const PornHubBrowseData();
  }

  @override
  Future<int?> fetchCreatorTotalCount(String path) async => null;
}

class UiController extends PornHubController {
  UiController(super.source);
  int moreCalls = 0;
  @override
  Future<void> loadMoreFeed() async {
    moreCalls++;
    isLoadingFeed.value = true;
  }

  @override
  Future<void> loadSubscriptions({bool refresh = false}) async {}
  @override
  Future<void> fetchCreatorCounts() async {}
  @override
  Future<void> loadFavorites() async {}
  @override
  Future<void> loadPublicPlaylists() async {}
}

void main() {
  final source = UiSource();
  late PornHubController controller;
  setUpAll(() => SourceRegistry.register(source));
  setUp(() {
    Get.testMode = true;
    final auth = PornHubAuthService()..isLoggedIn.value = true;
    auth.username.value = 'fixture';
    Get.put(auth);
    controller = Get.put<PornHubController>(UiController(source));
    controller.currentTabIndex.value = 2;
    controller.subscriptions.assignAll(const [
      PornHubSubscription(name: 'Creator', path: '/model/c'),
      PornHubSubscription(name: 'Second', path: '/model/d'),
    ]);
    controller.feedVideos.assignAll([item('Video')]);
    source.details.clear();
    source.browsePaths.clear();
  });
  tearDown(Get.reset);

  testWidgets('playlist expand and collapse use one fixed button', (
    tester,
  ) async {
    controller.myPlaylists.assignAll(const [
      PornHubPlaylist(
        id: '1',
        title: 'Owned',
        url: '/playlist/1',
        videoCount: 2,
      ),
    ]);
    controller.selectedPlaylistId.value = '1';
    controller.playlistVideos.assignAll([item('v')]);
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PornHubMineTab())),
    );
    await tester.pump();
    await tester.tap(find.text('片单 · 1'));
    await tester.pump();
    final before = tester.getCenter(find.text('展开'));
    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(tester.getCenter(find.text('收起')), before);
    expect(find.text('Owned'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('created playlists use two-column cover cards', (tester) async {
    controller.publicPlaylists.assignAll(const [
      PornHubPlaylist(
        id: '101',
        title: 'Created one',
        url: '/playlist/101',
        videoCount: 4,
      ),
      PornHubPlaylist(
        id: '102',
        title: 'Created two',
        url: '/playlist/102',
        videoCount: 6,
      ),
    ]);
    controller.selectedMineSub.value = PornHubMineSub.playlists;
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PornHubMineTab())),
    );
    await tester.pump();
    final cards = find.byType(PornHubPlaylistCard);
    expect(cards, findsNWidgets(2));
    final first = tester.getRect(cards.at(0)),
        second = tester.getRect(cards.at(1));
    expect(first.top, second.top);
    expect(first.right, lessThan(second.left));
    expect(find.text('4 个视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'subscription momentum loads the next page without another swipe',
    (tester) async {
      controller.feedVideos.assignAll(
        List.generate(30, (i) => item('video $i')),
      );
      await tester.pumpWidget(
        const GetMaterialApp(home: Scaffold(body: PornHubSubscriptionsTab())),
      );
      await tester.pump();
      final scroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final state = tester.state<ScrollableState>(scroll);
      state.position.jumpTo(state.position.maxScrollExtent - 900);
      await tester.pump();
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -300),
        1500,
      );
      await tester.pump(const Duration(seconds: 1));
      expect((controller as UiController).moreCalls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('detail tabs switch with horizontal swipes', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PornHubVideoInfoPanel(
              video: item('tabs'),
              onDownload: () {},
              onPlayVideo: (_) {},
            ),
          ),
        ),
      ),
    );
    source.details['tabs']!.complete(const PornHubDetailExtra());
    await tester.pump();
    expect(find.text('暂无相关视频'), findsOneWidget);
    await tester.drag(find.text('暂无相关视频'), const Offset(-250, 0));
    await tester.pump();
    expect(find.text('暂无推荐视频'), findsOneWidget);
    expect(find.text('暂无相关视频'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('暂无相关视频'), findsNothing);
    await tester.drag(find.text('暂无推荐视频'), const Offset(-250, 0));
    await tester.pump();
    expect(find.text('暂无评论'), findsOneWidget);
  });

  testWidgets(
    'expand and collapse remain at the same position and all has no media chips',
    (tester) async {
      await tester.pumpWidget(
        const GetMaterialApp(home: Scaffold(body: PornHubSubscriptionsTab())),
      );
      await tester.pump();
      expect(find.text('视频'), findsNothing);
      expect(find.text('切片'), findsNothing);
      final position = tester.getTopLeft(find.text('展开'));
      await tester.tap(find.text('展开'));
      await tester.pump();
      expect(tester.getTopLeft(find.text('收起')), position);
      await tester.tap(find.text('收起'));
      await tester.pump();
      expect(tester.getTopLeft(find.text('展开')), position);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('clicking the selected creator switches clips back to video', (
    tester,
  ) async {
    controller.selectedCreator.value = '/model/c';
    controller.selectedMediaType.value = PornHubMediaType.clips;
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PornHubSubscriptionsTab())),
    );
    await tester.pump();
    await tester.tap(find.text('Creator').first);
    await tester.pump();
    expect(controller.selectedMediaType.value, PornHubMediaType.videos);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old detail completion cannot replace the newly opened video', (
    tester,
  ) async {
    Widget panel(String id) => GetMaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PornHubVideoInfoPanel(
            video: item(id),
            onDownload: () {},
            onPlayVideo: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(panel('a'));
    await tester.pumpWidget(panel('b'));
    source.details['b']!.complete(
      PornHubDetailExtra(related: [item('Current result')]),
    );
    await tester.pump();
    source.details['a']!.complete(
      PornHubDetailExtra(related: [item('Stale result')]),
    );
    await tester.pump();
    expect(find.text('Current result'), findsOneWidget);
    expect(find.text('Stale result'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('category opens the actual website path', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PornHubVideoInfoPanel(
              video: item('links'),
              onDownload: () {},
              onPlayVideo: (_) {},
            ),
          ),
        ),
      ),
    );
    source.details['links']!.complete(
      const PornHubDetailExtra(
        categories: [
          PornHubLinkItem(name: 'Website category', path: '/video?c=241'),
        ],
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Website category'));
    await tester.tap(find.text('Website category'));
    await tester.pumpAndSettle();
    expect(source.browsePaths, contains('/video?c=241'));
    await tester.pumpWidget(const SizedBox());
  });
}

