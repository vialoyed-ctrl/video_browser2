import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';

class AccountAuth extends PornHubAuthService {
  @override
  String get cookieHeader => 'session=account-session';
}

class ContractAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String page = '', chunk = '', action = '{"success":true}';
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final text = options.uri.host == 'mux.pornhub.com'
        ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nstream.m3u8'
        : options.uri.path == '/playlist/viewChunked'
        ? chunk
        : options.method == 'POST' || options.method == 'DELETE'
        ? action
        : page;
    return ResponseBody.fromString(
      text,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String padded(String text) => '$text<!--${'x' * 10001}-->';
String video(String id) =>
    '<li class="pcVideoListItem" data-video-vkey="$id"><a title="$id" href="/view_video.php?viewkey=$id">$id</a></li>';
String playlist(String id, String title, String count) =>
    '<li id="playlist_$id"><div><a class="viewPlaylistLink" href="/playlist/$id">查看片单</a><img data-thumb_url="https://ei.phncdn.com/$id.jpg"></div><div><a class="title" title="$title" href="/playlist/$id">$title</a><span class="number">$count 个视频</span></div></li>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PornHubSource source;
  late ContractAdapter adapter;
  setUp(() {
    Get.testMode = true;
    final auth = AccountAuth()..isLoggedIn.value = true;
    auth.username.value = 'fixture';
    Get.put<PornHubAuthService>(auth);
    adapter = ContractAdapter();
    source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
  });
  tearDown(Get.reset);

  test('clip URL keeps identity, accepts official mux, and speculative resolution has no account cookie', () async {
    adapter.page = padded(
      '<script>var flashvars_1 = {"mediaDefinitions":[{"format":"hls","quality":"1080","videoUrl":"https://mux.pornhub.com/clips/test/m.m3u8?ttl=9999999999"}]};</script>',
    );
    final detail = await source.fetchDetail(
      'https://cn.pornhub.com/view_clip.php?viewkey=test',
    );
    expect(detail?.video.id, 'clip:test');
    expect(detail?.variants.first.label, '1080p');
    final request = adapter.requests.first;
    expect(request.uri.path, '/view_clip.php');
    expect('${request.headers['Cookie']}', isNot(contains('account-session')));
    adapter.requests.clear();
    await source.markWatched('clip:test');
    expect(adapter.requests.single.uri.path, '/view_clip.php');
    expect(
      '${adapter.requests.single.headers['Cookie']}',
      contains('account-session'),
    );
  });

  test('account playlist scope excludes header and sidebar, preserves empty playlists and website order', () async {
    adapter.page = padded(
      '<div id="dropdownHeaderSubMenu"><ul>${playlist('999', 'Header', '1')}</ul></div><ul id="moreData">${playlist('2', 'Second', '1,200')}${playlist('1', 'Empty', '0')}</ul><aside>${playlist('888', 'Sidebar', '8')}</aside>',
    );
    final result = await source.fetchPlaylists(
      path: '/users/fixture/playlists/public',
    );
    expect(result.map((p) => p.id), ['2', '1']);
    expect(result.first.videoCount, 1200);
    expect(result.last.videoCount, 0);
  });

  test('under-player playlists parse title and cover from the whole card', () async {
    adapter.page = padded(
      '<div id="under-player-playlists"><ul>${playlist('12', 'Actual title', '227')}</ul></div>',
    );
    final detail = await source.fetchDetailExtra('video');
    expect(detail.playlists.single.title, 'Actual title');
    expect(detail.playlists.single.videoCount, 227);
    expect(detail.playlists.single.coverUrl, 'https://ei.phncdn.com/12.jpg');
  });

  test('clip listing preserves main website order and excludes recommendations', () async {
    String clip(String key) =>
        '<li class="verticalVideoBox"><a href="/view_clip.php?viewkey=$key" title="$key"><img class="thumb" data-image="https://ei.phncdn.com/$key.jpg"></a><div class="userNameInfo"><span class="usernameWrapper"><a href="/model/author">Author</a></span></div></li>';
    adapter.page = padded(
      '<ul id="videoCategory" class="clipsListing">${clip('new')}${clip('old')}</ul><ul class="clipsListing">${clip('recommendation')}</ul>',
    );
    final result = await source.fetchBrowse('/clips', kind: 'clips');
    expect(result.videos.map((v) => v.id), ['clip:new', 'clip:old']);
    expect(result.videos.first.author, 'Author');
    expect(result.videos.first.thumbnailUrl, 'https://ei.phncdn.com/new.jpg');
  });

  test('playlist uses actual chunk endpoint and favourite JSON and DELETE contracts', () async {
    adapter.page = padded(
      '''<script>PLAYLIST_VIEW = {"title":"Fixture","video_count":3}; var token="fixture-token"; var lazyloadUrl="/playlist/viewChunked?id=12&token=fixture-token"; var alreadyAddedToFav=0; var playlistFavouriteAddUrl="/api/v1/playlist/favourite_add"; var playlistFavouriteRemoveUrl="/api/v1/playlist/12/favourite_remove?token=fixture-token";</script><ul id="videoPlaylist">${video('first')}</ul>''',
    );
    adapter.chunk = video('second') + video('third');
    final first = await source.fetchPlaylistVideos('12');
    expect(first.items.single.id, 'first');
    expect(first.hasMore, true);
    final second = await source.fetchPlaylistVideos('12', page: 2);
    expect(second.items.map((v) => v.id), ['second', 'third']);
    expect(second.hasMore, false);
    expect(adapter.requests.last.uri.path, '/playlist/viewChunked');
    expect(adapter.requests.last.uri.queryParameters['page'], '2');
    expect((await source.setPlaylistFavourite('12', remove: false)).ok, true);
    expect(adapter.requests.last.data, {'pid': 12, 'token': 'fixture-token'});
    expect((await source.setPlaylistFavourite('12', remove: true)).ok, true);
    expect(adapter.requests.last.method, 'DELETE');
    adapter.action = '{"success":false,"message":"Denied"}';
    expect((await source.setPlaylistFavourite('12', remove: false)).ok, false);
  });
}
