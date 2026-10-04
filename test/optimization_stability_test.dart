import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/hanime1_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/hanime1/hanime1_controller.dart';
import 'package:video_browser/app/modules/feed/feed_controller.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';
import 'package:video_browser/app/services/hanime1_auth_service.dart';
import 'package:video_browser/app/services/preload_service.dart';

class DelayedHanimeSource extends Hanime1Source {
  final tabs = <String, Completer<Hanime1UserTabPage>>{};
  final homes = <Completer<Hanime1HomeData?>>[];
  final searches = <String, Completer<VideoPage>>{};
  @override
  Future<Hanime1UserTabPage> fetchUserTabPage(
    String uid,
    String key, {
    int page = 1,
    String sort = 'latest',
  }) => (tabs['$uid:$key:$page'] = Completer<Hanime1UserTabPage>()).future;
  @override
  Future<Hanime1HomeData?> fetchHomeStructured() {
    final result = Completer<Hanime1HomeData?>();
    homes.add(result);
    return result.future;
  }

  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) => (searches[query.keyword] = Completer<VideoPage>()).future;
}

VideoItem item(String id) =>
    VideoItem(id: id, title: id, author: '', hlsUrl: '');
Hanime1UserTabPage page(String id, {int index = 1, bool more = false}) =>
    Hanime1UserTabPage(items: [item(id)], page: index, hasMore: more);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Hanime1AuthService auth;
  setUp(() {
    PreloadService.instance.preloadCount.value = 0;
    Get.testMode = true;
    auth = Get.put(
      Hanime1AuthService()
        ..isLoggedIn.value = true
        ..userId.value = 'old',
    );
  });
  tearDown(Get.reset);

  test('old account response cannot enter the new account cache', () async {
    final source = DelayedHanimeSource();
    final controller = Hanime1Controller(source);
    final old = controller.loadUserTab('likes');
    auth.userId.value = 'new';
    final current = controller.loadUserTab('likes');
    source.tabs['new:likes:1']!.complete(page('new'));
    await current;
    source.tabs['old:likes:1']!.complete(page('old'));
    await old;
    expect(controller.userTabPages['likes']!.items.single.id, 'new');
    expect(controller.loadingUserTab.value, '');
    controller.onClose();
  });

  test('refresh supersedes an in-flight append of the previous page', () async {
    final source = DelayedHanimeSource();
    final ctrl = Hanime1Controller(source);
    final first = ctrl.loadUserTab('likes');
    source.tabs['old:likes:1']!.complete(page('first', more: true));
    await first;
    final next = ctrl.loadMoreUserTab('likes');
    final refresh = ctrl.loadUserTab('likes', force: true);
    source.tabs['old:likes:1']!.complete(page('refreshed', more: true));
    await refresh;
    source.tabs['old:likes:2']!.complete(page('stale page', index: 2));
    await next;
    expect(ctrl.userTabPages['likes']!.items.map((v) => v.id), ['refreshed']);
    ctrl.onClose();
  });

  test('closing the controller prevents late home and search writes', () async {
    final source = DelayedHanimeSource();
    final home = Hanime1Controller(source);
    final pending = home.loadHomeData();
    home.onClose();
    source.homes.single.complete(
      const Hanime1HomeData(
        genreTabs: [],
        hero: null,
        sections: [Hanime1Section(title: 'stale', morePath: '', items: [])],
      ),
    );
    await pending;
    expect(home.homeData.value, isNull);
    final search = SearchController(source)..keyword.value = 'pending';
    final query = search.runSearch();
    search.onClose();
    source.searches['pending']!.complete(
      VideoPage(items: [item('late')], page: 1, hasMore: false),
    );
    await query;
    expect(search.results, isEmpty);
  });

  test('relative and absolute dates retain the same ordering basis', () {
    final now = DateTime(2026, 10, 4, 12);
    expect(
      FeedController.parsePublishedDate('1分钟前', reference: now),
      now.subtract(const Duration(minutes: 1)),
    );
    expect(
      FeedController.parsePublishedDate('2个星期前', reference: now),
      now.subtract(const Duration(days: 14)),
    );
    expect(
      FeedController.parsePublishedDate('2026/10/03', reference: now),
      DateTime(2026, 10, 3),
    );
    expect(
      FeedController.parsePublishedDate('未知', reference: now),
      DateTime.fromMillisecondsSinceEpoch(0),
    );
  });
}
