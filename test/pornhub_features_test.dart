import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/data/models/video_item.dart';

class FixtureAdapter implements HttpClientAdapter {
  String html = '', writeResponse = '{"success":true}';
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final write =
        options.method == 'POST' || options.uri.path.contains('subscribe_');
    return ResponseBody.fromString(
      write ? writeResponse : html,
      200,
      headers: {
        'content-type': [write ? 'application/json' : 'text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FixtureAdapter adapter;
  late PornHubSource source;
  String padded(String html) => '$html<!--${'x' * 10001}-->';
  setUp(() {
    Get.testMode = true;
    final auth = PornHubAuthService();
    auth.isLoggedIn.value = true;
    auth.username.value = 'fixture';
    Get.put(auth);
    adapter = FixtureAdapter();
    source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
  });
  tearDown(Get.reset);

  test(
    'detail uses current action config, actual uploader and server states',
    () async {
      adapter.html = padded(r'''
      <a href="/pornstar/unrelated-header">Unrelated</a>
      <div class="videoUploaderBlock"><div class="usernameWrap"><a href="/channels/actual">Author</a></div></div>
      <button data-subscribe-url="/channel/subscribe_add_json?id=7&amp;token=t"
        data-unsubscribe-url="/channel/subscribe_remove_json?id=7&amp;token=t" data-subscribed="1"></button>
      <script>var WIDGET_RATINGS_LIKE_FAV = {"itemIdNum":123,"isFavourite":1,"token":"valid_token_with_a_dot.","favouriteUrl":"\/video\/favourite"};</script>
      <div class="tagsWrapper"><a class="item isTag" href="/video/search?search=fixture&amp;o=mr"><span>Fixture</span></a></div>
    ''');
      final extra = await source.fetchDetailExtra('fixture');
      expect(extra.videoId, '123');
      expect(extra.token, 'valid_token_with_a_dot.');
      expect(extra.favouriteUrl, '/video/favourite');
      expect(extra.isFavourite, true);
      expect(extra.creatorPath, '/channels/actual');
      expect(extra.isSubscribed, true);
      expect(extra.unsubscribeUrl, contains('&token=t'));
      expect(extra.tags.single.path, '/video/search?search=fixture&o=mr');
    },
  );

  test('favourite uses official id and toggle fields and rejects empty HTML success', () async {
    final result = await source.setFavourite(
      videoId: '123',
      token: 'token',
      remove: false,
    );
    expect(result.ok, true);
    final fields = adapter.requests.last.data;
    expect(fields, {'id': '123', 'token': 'token', 'toggle': '1'});
    adapter.writeResponse = '<html>login</html>';
    expect(
      (await source.setFavourite(
        videoId: '123',
        token: 'token',
        remove: true,
      )).ok,
      false,
    );
  });

  test('playlist write consumes JSON without the HTML transformer and requires confirmation', () async {
    final result = await source.addVideoToPlaylist(
      pid: '2',
      vid: '123',
      token: 't',
    );
    expect(result.ok, true);
    expect(jsonDecode(adapter.requests.last.data as String), {
      'pid': '2',
      'vid': '123',
      'token': 't',
    });
    adapter.writeResponse = '';
    expect(
      (await source.addVideoToPlaylist(pid: '2', vid: '123', token: 't')).ok,
      false,
    );
  });

  test(
    'subscription uses official channel URL and refuses foreign endpoints',
    () async {
      expect(
        (await source.setCreatorSubscription(
          '/channel/subscribe_add_json?id=7&token=t',
        )).ok,
        true,
      );
      expect(adapter.requests.last.method, 'GET');
      final before = adapter.requests.length;
      expect(
        (await source.setCreatorSubscription(
          'https://outside.example/user/subscribe_add_json',
        )).ok,
        false,
      );
      expect(adapter.requests.length, before);
    },
  );

  test(
    'browse retains tag parameters across pages and extracts official filters',
    () async {
      adapter.html = padded('''
      <ul><li data-video-vkey="fixture"><a href="/view_video.php?viewkey=fixture" title="Fixture"><img src="https://example.com/thumb.jpg"></a></li></ul>
      <ul data-filter="p"><li data-value="homemade"><a>自制</a></li></ul>
      <link rel="next" href="/video/search?search=fixture&amp;o=mr&amp;page=3">
    ''');
      final result = await source.fetchBrowse(
        'https://cn.pornhub.com/video/search?search=fixture&o=mr&c=241',
        page: 2,
      );
      expect(adapter.requests.last.uri.queryParameters, {
        'search': 'fixture',
        'o': 'mr',
        'c': '241',
        'page': '2',
      });
      expect(result.videos.single.id, 'fixture');
      expect(result.hasMore, true);
      expect(result.filters.single.options.single.path, 'homemade');
    },
  );

  test(
    'creator result opens its actual user path and not a header recommendation',
    () async {
      adapter.html = padded(
        '''<a href="/users/header">Header</a>
      <ul class="userWidgetWrapperGrid"><li><a class="usernameLink" href="/users/actual">Actual</a><img src="https://example.com/avatar.jpg"></li></ul>''',
      );
      final result = await source.fetchBrowse(
        '/user/search?username=actual',
        kind: 'creators',
      );
      expect(result.creators.single.path, '/users/actual');
    },
  );
  test(
    'history reads account page and excludes local records and recommendations',
    () async {
      final user = Get.put(UserService());
      final now = DateTime.now();
      user.history.assignAll([
        WatchHistoryItem(
          video: const VideoItem(
            id: 'viewed',
            title: 'Viewed',
            author: 'a',
            hlsUrl: '',
            detailUrl: 'https://cn.pornhub.com/view_video.php?viewkey=viewed',
          ),
          watchedAt: now,
        ),
        WatchHistoryItem(
          video: const VideoItem(
            id: 'other-site',
            title: 'Other',
            author: 'a',
            hlsUrl: '',
            detailUrl: 'https://hanime1.me/watch?v=other',
          ),
          watchedAt: now,
        ),
      ]);
      adapter.html = padded(
        '<div class="profileContentLeft"><div class="profileVids"><li class="pcVideoListItem" data-video-vkey="account"><a href="/view_video.php?viewkey=account" title="Account view">Account</a></li></div></div><aside><li class="pcVideoListItem" data-video-vkey="unseen"><a href="/view_video.php?viewkey=unseen">Unseen</a></li></aside>',
      );
      final history = await source.fetchHistory();
      expect(history.items.map((v) => v.id), ['account']);
      expect(history.totalItems, 1);
      expect(adapter.requests.single.uri.path, endsWith('/videos/recent'));
    },
  );
}
