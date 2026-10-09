import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/hanime1_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/hanime1/hanime1_controller.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';
import 'package:video_browser/app/services/preload_service.dart';

VideoItem item(String id) =>
    VideoItem(id: id, title: id, author: '', hlsUrl: '');
VideoPage page(
  List<String> ids,
  int number, {
  bool more = true,
  String? error,
}) => VideoPage(
  items: ids.map(item).toList(),
  page: number,
  totalPages: 9,
  hasMore: more,
  summary: error,
);
Hanime1SubscriptionData sub(List<String> ids, int number, {bool more = true}) =>
    Hanime1SubscriptionData(
      creators: const [],
      filters: const [],
      items: ids.map(item).toList(),
      page: number,
      totalPages: 8,
      hasMore: more,
    );

class HanimeFixture extends Hanime1Source {
  final ranks = <Completer<VideoPage>>[];
  final rankArgs = <(String, int)>[];
  final subscriptions = <Completer<Hanime1SubscriptionData>>[];
  final subArgs = <Map<String, Object?>>[];
  @override
  Future<VideoPage> fetchRankingList(String sort, {int page = 1}) {
    rankArgs.add((sort, page));
    final pending = Completer<VideoPage>();
    ranks.add(pending);
    return pending.future;
  }

  @override
  Future<Hanime1SubscriptionData> fetchSubscriptionsData({
    int page = 1,
    String? query,
    String genre = '',
    String sort = '',
    String date = '',
    String duration = '',
    List<String> tags = const [],
    bool broad = false,
  }) {
    subArgs.add({
      'page': page,
      'query': query,
      'genre': genre,
      'sort': sort,
      'date': date,
      'duration': duration,
      'tags': List.of(tags),
      'broad': broad,
    });
    final pending = Completer<Hanime1SubscriptionData>();
    subscriptions.add(pending);
    return pending.future;
  }
}

class PornHubFixture extends PornHubSource {
  final requests = <Completer<VideoPage>>[];
  final arguments = <(String, int)>[];
  @override
  Future<VideoPage> fetchPathPage(String path, int page) {
    arguments.add((path, page));
    final pending = Completer<VideoPage>();
    requests.add(pending);
    return pending.future;
  }

  @override
  void clearAccountCaches() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int oldPreload;
  setUp(() {
    Get.testMode = true;
    oldPreload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(() {
    Get.reset();
    PreloadService.instance.preloadCount.value = oldPreload;
  });

  test(
    'Hanime subscriptions do not append before the first successful page',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      await controller.loadMoreSubscriptions();
      expect(source.subscriptions, isEmpty);
      expect(controller.hasMoreSub.value, false);
      expect(controller.hasMoreRanking.value, true);
      expect(controller.isLoadingSub.value, false);
    },
  );
  test(
    'Hanime ranking uses actual page metadata and preserves duplicate append',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      final first = controller.loadRanking('本日排行');
      source.ranks.last.complete(page(['a', 'a'], 3));
      await first;
      final next = controller.loadMoreRanking();
      expect(controller.isLoadingRanking.value, true);
      await controller.loadMoreRanking();
      expect(source.rankArgs, [('本日排行', 1), ('本日排行', 4)]);
      source.ranks.last.complete(page(['a', 'b'], 4, more: false));
      await next;
      expect(controller.rankingVideos.map((v) => v.id), ['a', 'a', 'a', 'b']);
      expect(controller.rankingPage.value, 4);
      expect(controller.rankingTotalPages.value, 9);
      await controller.loadMoreRanking();
      expect(source.ranks, hasLength(2));
    },
  );
  test(
    'Hanime older ranking cleanup cannot clear newer loading or results',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      final old = controller.loadRanking('本日排行');
      final fresh = controller.loadRanking('本週排行');
      source.ranks.first.completeError(StateError('old failure'));
      await old;
      expect(controller.isLoadingRanking.value, true);
      expect(controller.rankingError.value, null);
      source.ranks.last.complete(page(['new'], 1));
      await fresh;
      expect(controller.rankingVideos.single.id, 'new');
      expect(controller.isLoadingRanking.value, false);
    },
  );
  test(
    'Hanime failed ranking append retains items and retries same page',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      final first = controller.loadRanking('本日排行');
      source.ranks.last.complete(page(['a'], 1));
      await first;
      final failed = controller.loadMoreRanking();
      source.ranks.last.completeError(StateError('offline'));
      await failed;
      expect(controller.rankingVideos.single.id, 'a');
      expect(controller.rankingPage.value, 1);
      expect(controller.rankingError.value, isNotNull);
      final retry = controller.loadMoreRanking();
      expect(controller.rankingError.value, null);
      expect(source.rankArgs.map((a) => a.$2), [1, 2, 2]);
      source.ranks.last.complete(page([], 2, more: false));
      await retry;
      expect(controller.rankingVideos.single.id, 'a');
      expect(controller.hasMoreRanking.value, false);
    },
  );
  test(
    'Hanime subscriptions preserve creator filters and duplicate append',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      controller.subscriptionGenre.value = 'genre';
      controller.subscriptionSort.value = 'sort';
      controller.subscriptionDate.value = 'date';
      controller.subscriptionDuration.value = 'duration';
      controller.subscriptionTags.assignAll(['tag1', 'tag2']);
      controller.subscriptionBroad.value = true;
      final first = controller.loadSubscriptions(creatorQuery: 'creator');
      source.subscriptions.last.complete(sub(['a'], 3));
      await first;
      final next = controller.loadMoreSubscriptions();
      await controller.loadMoreSubscriptions();
      expect(source.subArgs.last, {
        'page': 4,
        'query': 'creator',
        'genre': 'genre',
        'sort': 'sort',
        'date': 'date',
        'duration': 'duration',
        'tags': ['tag1', 'tag2'],
        'broad': true,
      });
      expect(source.subscriptions, hasLength(2));
      source.subscriptions.last.complete(sub(['a', 'b'], 4, more: false));
      await next;
      expect(controller.subVideos.map((v) => v.id), ['a', 'a', 'b']);
      expect(controller.subscriptionsPage.value, 4);
      expect(controller.subscriptionsTotalPages.value, 8);
    },
  );
  test(
    'Hanime creator replacement rejects older replies and stale cleanup',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      final old = controller.loadSubscriptions(creatorQuery: 'old');
      final fresh = controller.loadSubscriptions(creatorQuery: 'new');
      source.subscriptions.first.complete(sub(['old'], 8));
      await old;
      expect(controller.isLoadingSub.value, true);
      expect(controller.subData.value, null);
      source.subscriptions.last.complete(sub(['new'], 1));
      await fresh;
      expect(controller.selectedCreator.value, 'new');
      expect(controller.subVideos.single.id, 'new');
    },
  );
  test(
    'Hanime subscriptions retry failed page without replacing existing data',
    () async {
      final source = HanimeFixture();
      final controller = Hanime1Controller(source);
      addTearDown(controller.onClose);
      final first = controller.loadSubscriptions(creatorQuery: 'author');
      source.subscriptions.last.complete(sub(['a'], 1));
      await first;
      final oldData = controller.subData.value;
      final failed = controller.loadMoreSubscriptions();
      source.subscriptions.last.completeError(StateError('offline'));
      await failed;
      expect(controller.subData.value, same(oldData));
      expect(controller.subVideos.single.id, 'a');
      final retry = controller.loadMoreSubscriptions();
      expect(source.subArgs.map((a) => a['page']), [1, 2, 2]);
      source.subscriptions.last.complete(sub([], 2, more: false));
      await retry;
      expect(controller.subVideos.single.id, 'a');
      expect(controller.hasMoreSub.value, false);
      expect(controller.subscriptionsError.value, null);
    },
  );
  test('Hanime close invalidates both independent lists', () async {
    final source = HanimeFixture();
    final controller = Hanime1Controller(source);
    final rank = controller.loadRanking('本日排行');
    final subscription = controller.loadSubscriptions();
    controller.onClose();
    source.ranks.last.complete(page(['late'], 7));
    source.subscriptions.last.complete(sub(['late'], 8));
    await Future.wait([rank, subscription]);
    expect(controller.rankingVideos, isEmpty);
    expect(controller.subVideos, isEmpty);
    expect(controller.rankingPage.value, 1);
    expect(controller.subscriptionsPage.value, 1);
  });

  test('PornHub path states and request families remain independent', () async {
    final source = PornHubFixture();
    final controller = PornHubController(source);
    addTearDown(controller.onClose);
    final a = controller.loadList('/a');
    final b = controller.loadList('/b');
    source.requests[1].complete(page(['b'], 5, more: false));
    await b;
    expect(controller.stateOf('/a').isLoading.value, true);
    source.requests[0].complete(page(['a'], 2));
    await a;
    expect(controller.stateOf('/a').items.single.id, 'a');
    expect(controller.stateOf('/a').page, 2);
    expect(controller.stateOf('/b').page, 5);
    expect(controller.stateOf('/b').hasMore.value, false);
    expect(controller.stateOf('/a'), same(controller.stateOf('/a')));
  });
  test(
    'PornHub append guards concurrent loads and preserves duplicate entries',
    () async {
      final source = PornHubFixture();
      final controller = PornHubController(source);
      addTearDown(controller.onClose);
      final first = controller.loadList('/a');
      await controller.loadMore('/a');
      source.requests.last.complete(page(['a', 'a'], 1));
      await first;
      final next = controller.loadMore('/a');
      await controller.loadMore('/a');
      expect(source.arguments, [('/a', 1), ('/a', 2)]);
      expect(controller.stateOf('/a').page, 1);
      expect(controller.stateOf('/a').isLoadingMore.value, true);
      source.requests.last.complete(page(['a', 'b'], 2, more: false));
      await next;
      expect(controller.stateOf('/a').items.map((v) => v.id), [
        'a',
        'a',
        'a',
        'b',
      ]);
      await controller.loadMore('/a');
      expect(source.requests, hasLength(2));
    },
  );
  for (final throws in [false, true]) {
    test(
      'PornHub append failure ($throws) rolls back page and retries same target',
      () async {
        final source = PornHubFixture();
        final controller = PornHubController(source);
        addTearDown(controller.onClose);
        final first = controller.loadList('/a');
        source.requests.last.complete(page(['a'], 4));
        await first;
        final failed = controller.loadMore('/a');
        if (throws) {
          source.requests.last.completeError(StateError('offline'));
        } else {
          source.requests.last.complete(
            page([], 5, error: PornHubSource.requestFailureMessage),
          );
        }
        await failed;
        final state = controller.stateOf('/a');
        expect(state.items.single.id, 'a');
        expect(state.page, 4);
        expect(state.hasMore.value, true);
        expect(state.isLoadingMore.value, false);
        expect(state.error.value, isNotNull);
        final retry = controller.loadMore('/a');
        expect(source.arguments.map((a) => a.$2), [1, 5, 5]);
        expect(state.error.value, null);
        source.requests.last.complete(page(['b'], 5, more: false));
        await retry;
        expect(state.items.map((v) => v.id), ['a', 'b']);
      },
    );
  }
  test(
    'PornHub older failure does not overwrite refresh or clear new loading',
    () async {
      final source = PornHubFixture();
      final controller = PornHubController(source);
      addTearDown(controller.onClose);
      final old = controller.loadList('/a');
      final fresh = controller.jumpListPage('/a', 7);
      source.requests.first.completeError(StateError('old'));
      await old;
      expect(controller.stateOf('/a').error.value, null);
      expect(controller.stateOf('/a').isLoading.value, true);
      source.requests.last.complete(page(['new'], 7));
      await fresh;
      expect(controller.stateOf('/a').items.single.id, 'new');
      expect(controller.stateOf('/a').page, 7);
      await controller.jumpListPage('/a', 0);
      expect(source.requests, hasLength(2));
    },
  );
  test('PornHub empty refresh replaces items and exposes retry without resetting server page', () async {
    final source = PornHubFixture();
    final controller = PornHubController(source);
    addTearDown(controller.onClose);
    controller.stateOf('/a').items.add(item('old'));
    final pending = controller.jumpListPage('/a', 8);
    source.requests.last.complete(page([], 8, more: false));
    await pending;
    final state = controller.stateOf('/a');
    expect(state.items, isEmpty);
    expect(state.page, 8);
    expect(state.hasMore.value, false);
    expect(state.error.value, isNotNull);
  });
  test('PornHub failed refresh keeps old items and page', () async {
    final source = PornHubFixture();
    final controller = PornHubController(source);
    addTearDown(controller.onClose);
    final state = controller.stateOf('/a');
    state.items.add(item('old'));
    state.page = 3;
    final pending = controller.jumpListPage('/a', 8);
    source.requests.last.complete(
      page([], 8, error: PornHubSource.requestFailureMessage),
    );
    await pending;
    expect(state.items.single.id, 'old');
    expect(state.page, 3);
    expect(state.isLoading.value, false);
  });
  test(
    'PornHub account reset clears caches and rejects pending path replies',
    () async {
      final auth = Get.put(PornHubAuthService());
      final source = PornHubFixture();
      final controller = Get.put(PornHubController(source));
      final state = controller.stateOf('/a');
      state.items.add(item('old'));
      state.page = 3;
      final pending = controller.loadList('/a');
      auth.sessionRevision.value++;
      await Future<void>.delayed(Duration.zero);
      expect(state.items, isEmpty);
      expect(state.page, 1);
      expect(state.isLoading.value, false);
      source.requests.last.complete(page(['old-account'], 6));
      await pending;
      expect(state.items, isEmpty);
      expect(state.page, 1);
    },
  );
  test('PornHub close rejects pending path reply', () async {
    final source = PornHubFixture();
    final controller = PornHubController(source);
    final pending = controller.loadList('/a');
    controller.onClose();
    source.requests.last.complete(page(['late'], 4));
    await pending;
    expect(controller.stateOf('/a').items, isEmpty);
    expect(controller.stateOf('/a').page, 1);
  });

  test(
    'shared state updates remain visible through legacy list consumers',
    () async {
      final hanime = Hanime1Controller(HanimeFixture());
      final porn = PornHubController(PornHubFixture());
      addTearDown(hanime.onClose);
      addTearDown(porn.onClose);
      final dynamic rankings = hanime;
      final dynamic path = porn.stateOf('/a');
      rankings.rankingPaging.items.add(item('rank'));
      rankings.rankingPaging.page.value = 4;
      rankings.subscriptionsPaging.items.add(item('sub'));
      rankings.subscriptionsPaging.hasMore.value = true;
      path.paging.items.add(item('porn'));
      path.paging.page.value = 7;
      path.paging.loadingPage.value = true;
      expect(hanime.rankingVideos.single.id, 'rank');
      expect(hanime.rankingPage.value, 4);
      expect(hanime.subVideos.single.id, 'sub');
      expect(hanime.hasMoreSub.value, true);
      expect(porn.stateOf('/a').items.single.id, 'porn');
      expect(porn.stateOf('/a').page, 7);
      expect(porn.stateOf('/a').isLoadingMore.value, true);
      porn.stateOf('/a').page = 8;
      expect(path.paging.page.value, 8);
      expect(porn.stateOf('/b').items, isEmpty);
      expect(hanime.isLoadingSub.value, false);
    },
  );
  test('PornHub pending append does not publish an unconfirmed page', () async {
    final source = PornHubFixture();
    final controller = PornHubController(source);
    addTearDown(controller.onClose);
    final state = controller.stateOf('/a');
    state.items.add(item('first'));
    state.page = 4;
    var notifications = 0;
    final pages = state.paging.page.listen((_) => notifications++);
    addTearDown(pages.cancel);
    final pending = controller.loadMore('/a');
    await Future<void>.delayed(Duration.zero);
    expect(source.arguments.single, ('/a', 5));
    expect(state.items.single.id, 'first');
    expect(state.isLoadingMore.value, true);
    expect(state.page, 4);
    expect(notifications, 0);
    source.requests.last.complete(page(['second'], 5));
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(state.page, 5);
    expect(notifications, 1);
    expect(state.items.map((v) => v.id), ['first', 'second']);
  });
  for (final fails in [false, true]) {
    test(
      'PornHub stale append ($fails) cannot replace newer jump or cleanup',
      () async {
        final source = PornHubFixture();
        final controller = PornHubController(source);
        addTearDown(controller.onClose);
        final state = controller.stateOf('/a');
        state.items.add(item('first'));
        final old = controller.loadMore('/a');
        final fresh = controller.jumpListPage('/a', 8);
        if (fails) {
          source.requests.first.completeError(StateError('stale'));
        } else {
          source.requests.first.complete(page(['stale'], 2));
        }
        await old;
        expect(state.isLoading.value, true);
        expect(state.error.value, null);
        expect(state.items.single.id, 'first');
        source.requests.last.complete(page(['jump'], 8));
        await fresh;
        expect(state.items.single.id, 'jump');
        expect(state.page, 8);
        expect(state.isLoading.value, false);
        expect(state.isLoadingMore.value, false);
      },
    );
  }
}
