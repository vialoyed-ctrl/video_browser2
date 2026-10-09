import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';

VideoItem video(String id) =>
    VideoItem(id: id, title: id, author: 'creator', hlsUrl: '');
VideoPage page(String id) =>
    VideoPage(items: [video(id)], page: 1, hasMore: true);

class FeedSource extends PornHubSource {
  final requests = <({String owner, int page, Completer<VideoPage> result})>[];
  final creators = Completer<List<PornHubSubscription>>();
  int creatorRequests = 0;
  List<PornHubPlaylist> playlists = const [];
  @override
  Future<List<PornHubPlaylist>> fetchUserPlaylists({int page = 1}) async =>
      playlists;
  @override
  Future<VideoPage> fetchPlaylistVideos(String id, {int page = 1}) =>
      request('playlist/$id', page);
  @override
  Future<VideoPage> fetchCreatorClips(String path, {int page = 1}) async =>
      const VideoPage.empty();
  final countRequests = <String>[];
  final counts = <String, int>{};
  Future<VideoPage> request(String owner, int page) {
    final result = Completer<VideoPage>();
    requests.add((owner: owner, page: page, result: result));
    return result.future;
  }

  @override
  Future<VideoPage> fetchSubscriptionsFeed({int page = 1}) =>
      request('ALL', page);
  @override
  Future<VideoPage> fetchCreatorVideos(String creatorPath, {int page = 1}) =>
      request(creatorPath, page);
  @override
  Future<List<PornHubSubscription>> fetchSubscribedCreators(String name) {
    creatorRequests++;
    return creators.future;
  }

  @override
  Future<int?> fetchCreatorTotalCount(String path) async {
    countRequests.add(path);
    return counts[path];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FeedSource source;
  late PornHubController controller;
  setUp(() {
    Get.testMode = true;
    final auth = PornHubAuthService();
    auth.isLoggedIn.value = true;
    auth.username.value = 'tester';
    Get.put(auth);
    source = FeedSource();
    controller = PornHubController(source)..currentTabIndex.value = 2;
  });
  tearDown(() async {
    controller.onClose();
    Get.reset();
  });

  Future<void> seed() async {
    final task = controller.loadFeed(reset: true);
    source.requests.last.result.complete(page('old'));
    await task;
  }

  test('selecting the current creator returns from clips to videos', () async {
    controller.selectedCreator.value = '/model/c';
    controller.selectedMediaType.value = PornHubMediaType.clips;
    controller.selectCreator('/model/c');
    expect(controller.selectedMediaType.value, PornHubMediaType.videos);
  });

  test('loading personal playlists opens the first valid playlist', () async {
    source.playlists = const [
      PornHubPlaylist(id: 'first', title: 'First', url: '/playlist/first'),
    ];
    controller.selectedPlaylistId.value = 'deleted';
    final task = controller.loadMyPlaylists();
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedPlaylistId.value, 'first');
    source.requests.last.result.complete(page('first-video'));
    await task;
    expect(controller.playlistVideos.single.id, 'first-video');
  });
  test('refresh retains content until successful replacement', () async {
    await seed();
    final task = controller.loadFeed(reset: true);
    expect(controller.feedVideos.single.id, 'old');
    expect(controller.isLoadingFeed.value, true);
    source.requests.last.result.complete(page('new'));
    await task;
    expect(controller.feedVideos.single.id, 'new');
  });

  test('selected creator count is immediate and stops at the total', () async {
    source.counts['/model/c'] = 2;
    controller.selectCreator('/model/c');
    await Future<void>.delayed(const Duration(milliseconds: 190));
    expect(source.countRequests, ['/model/c']);
    expect(controller.creatorCounts['/model/c'], 2);
    source.requests.last.result.complete(
      VideoPage(items: [video('1'), video('2')], page: 1, hasMore: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.feedHasMore, false);
    await controller.loadMoreFeed();
    expect(source.requests.length, 1);
    expect(controller.feedError.value, isNull);
    final refresh = controller.loadFeed(reset: true);
    source.requests.last.result.complete(
      VideoPage(items: [video('2'), video('1')], page: 1, hasMore: false),
    );
    await refresh;
    expect(controller.feedError.value, isNull);
    expect(controller.feedHasMore, false);
  });

  test('official last page prevents extra requests without a count', () async {
    final task = controller.loadFeed(reset: true);
    source.requests.last.result.complete(
      VideoPage(items: [video('last')], page: 1, hasMore: false),
    );
    await task;
    await controller.loadMoreFeed();
    expect(source.requests.length, 1);
    expect(controller.feedError.value, isNull);
  });

  test('all subscriptions retain website order across pages', () async {
    VideoItem dated(String id, String? date) => VideoItem(
      id: id,
      title: id,
      author: 'c',
      hlsUrl: '',
      publishedAt: date,
    );
    final first = controller.loadFeed(reset: true);
    source.requests.last.result.complete(
      VideoPage(
        items: [
          dated('old', '2026-10-01'),
          dated('new', '2026-10-04'),
          dated('same-day', '2026-10-04'),
          dated('unknown', null),
        ],
        page: 1,
        hasMore: true,
      ),
    );
    await first;
    expect(controller.feedVideos.map((v) => v.id), [
      'old',
      'new',
      'same-day',
      'unknown',
    ]);
    final more = controller.loadMoreFeed();
    source.requests.last.result.complete(
      VideoPage(
        items: [dated('new', '2026-10-04'), dated('middle', '2026-10-03')],
        page: 2,
        hasMore: true,
      ),
    );
    await more;
    expect(controller.feedVideos.map((v) => v.id), [
      'old',
      'new',
      'same-day',
      'unknown',
      'middle',
    ]);
  });

  test('a single creator uses the same newest-first ordering', () async {
    controller.selectedCreator.value = '/model/c';
    final task = controller.loadFeed(reset: true);
    source.requests.last.result.complete(
      VideoPage(
        items: [
          VideoItem(
            id: 'old',
            title: 'old',
            author: 'c',
            hlsUrl: '',
            publishedAt: '2026-09-01',
          ),
          VideoItem(
            id: 'new',
            title: 'new',
            author: 'c',
            hlsUrl: '',
            publishedAt: '2026-10-04',
          ),
        ],
        page: 1,
        hasMore: true,
      ),
    );
    await task;
    expect(controller.feedVideos.map((v) => v.id), ['new', 'old']);
  });

  test('failed refresh retains content and the next-page cursor', () async {
    await seed();
    final refresh = controller.loadFeed(reset: true);
    source.requests.last.result.complete(
      const VideoPage(
        items: [],
        page: 1,
        hasMore: true,
        summary: PornHubSource.requestFailureMessage,
      ),
    );
    await refresh;
    expect(controller.feedVideos.single.id, 'old');
    expect(controller.feedError.value, isNotNull);
    final more = controller.loadMoreFeed();
    expect(source.requests.last.page, 2);
    source.requests.last.result.complete(page('next'));
    await more;
    expect(controller.feedVideos.map((v) => v.id), ['old', 'next']);
  });

  test('unexpected empty refresh keeps the existing videos', () async {
    await seed();
    final task = controller.loadFeed(reset: true);
    source.requests.last.result.complete(const VideoPage.empty());
    await task;
    expect(controller.feedVideos.single.id, 'old');
    expect(controller.feedError.value, contains('保留'));
  });

  test('rapid creator taps resolve only the last selection', () async {
    controller.selectCreator('/model/a');
    controller.selectCreator('/model/b');
    controller.selectCreator('/model/c');
    expect(controller.isLoadingFeed.value, true);
    await Future<void>.delayed(const Duration(milliseconds: 190));
    expect(source.requests.length, 1);
    expect(source.requests.single.owner, '/model/c');
    source.requests.single.result.complete(page('c'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.feedVideos.single.id, 'c');
  });

  test('a stale request cannot replace a newly selected creator', () async {
    controller.selectedCreator.value = '/model/a';
    final old = controller.loadFeed(reset: true);
    controller.selectCreator('/model/b');
    await Future<void>.delayed(const Duration(milliseconds: 190));
    source.requests.last.result.complete(page('b'));
    await Future<void>.delayed(Duration.zero);
    source.requests.first.result.complete(page('a'));
    await old;
    expect(controller.feedVideos.single.id, 'b');
  });

  test('duplicate pagination notifications share one request', () async {
    await seed();
    final first = controller.loadMoreFeed();
    final second = controller.loadMoreFeed();
    expect(source.requests.length, 2);
    source.requests.last.result.complete(page('next'));
    await Future.wait([first, second]);
    expect(controller.feedVideos.length, 2);
  });

  test('subscription refresh waits for the video response too', () async {
    final refresh = controller.loadSubscriptions(refresh: true);
    var done = false;
    refresh.then((_) => done = true);
    source.creators.complete(const [
      PornHubSubscription(name: 'c', path: '/model/c'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    expect(source.requests.length, 1);
    source.requests.last.result.complete(page('fresh'));
    await refresh;
    expect(controller.feedVideos.single.id, 'fresh');
  });
}
