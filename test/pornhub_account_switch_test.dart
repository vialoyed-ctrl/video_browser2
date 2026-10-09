import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/services/pornhub_auth_service.dart';

class AccountLists extends PornHubSource {
  final saved = <Completer<List<PornHubPlaylist>>>[];
  final owned = <Completer<List<PornHubPlaylist>>>[];
  final recent = <Completer<VideoPage>>[];
  @override
  Future<List<PornHubPlaylist>> fetchUserPlaylists({int page = 1}) {
    final c = Completer<List<PornHubPlaylist>>();
    saved.add(c);
    return c.future;
  }

  @override
  Future<List<PornHubPlaylist>> fetchPublicPlaylists({int page = 1}) {
    final c = Completer<List<PornHubPlaylist>>();
    owned.add(c);
    return c.future;
  }

  @override
  Future<VideoPage> fetchHistory({int page = 1}) {
    final c = Completer<VideoPage>();
    recent.add(c);
    return c.future;
  }

  @override
  Future<VideoPage> fetchPlaylistVideos(String id, {int page = 1}) async =>
      const VideoPage.empty();
}

class DelayedAdapter implements HttpClientAdapter {
  final pending = <Completer<String>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    final result = Completer<String>();
    pending.add(result);
    return ResponseBody.fromString(
      await result.future,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const old = PornHubPlaylist(id: '1', title: 'Old', url: '/playlist/1');
const saved = PornHubPlaylist(id: '2', title: 'Saved', url: '/playlist/2');
const owned = PornHubPlaylist(id: '3', title: 'Created', url: '/playlist/3');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PornHubAuthService auth;
  setUp(() {
    Get.testMode = true;
    auth = PornHubAuthService()..username.value = 'first';
    auth.isLoggedIn.value = true;
    Get.put(auth);
  });
  tearDown(Get.reset);
  test('switching accounts clears personal data and rejects delayed old lists and history', () async {
    final source = AccountLists();
    final c = Get.put(PornHubController(source));
    c.myPlaylists.add(old);
    c.publicPlaylists.add(old);
    c.selectedPlaylistId.value = '1';
    c.playlistTotal.value = 24;
    c.historyTotal.value = 48;
    c.creatorCounts['old'] = 20;
    c.selectedCreator.value = '/model/old';
    final a = c.loadMyPlaylists(),
        b = c.loadPublicPlaylists(),
        h = c.loadHistory();
    auth.username.value = 'second';
    expect(c.myPlaylists, isEmpty);
    expect(c.publicPlaylists, isEmpty);
    expect(c.historyTotal.value, isNull);
    expect(c.playlistTotal.value, isNull);
    expect(c.selectedPlaylistId.value, isNull);
    expect(c.creatorCounts, isEmpty);
    expect(c.selectedCreator.value, PornHubController.allSubs);
    final n = c.loadMyPlaylists(), o = c.loadPublicPlaylists();
    source.saved[1].complete([saved]);
    source.owned[1].complete([owned]);
    await Future.wait([n, o]);
    source.saved[0].complete([old]);
    source.owned[0].complete([old]);
    source.recent[0].complete(
      VideoPage(
        items: [VideoItem(id: 'unseen', title: 'old', author: '', hlsUrl: '')],
        page: 1,
        hasMore: false,
        totalItems: 48,
      ),
    );
    await Future.wait([a, b, h]);
    expect(c.myPlaylists.single.id, '2'); // Top “片单” is favourites.
    expect(c.publicPlaylists.single.id, '3'); // “我的片单” is created.
    expect(c.history, isEmpty);
    expect(c.historyTotal.value, isNull);
    expect(c.selectedPlaylistId.value, '2');
    auth
        .sessionRevision
        .value++; // Replacing credentials for the same username also clears.
    expect(c.myPlaylists, isEmpty);
    expect(c.publicPlaylists, isEmpty);
  });

  test('old detail requests cannot repopulate account caches or remove a new in-flight request', () async {
    final adapter = DelayedAdapter();
    final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
    final first = source.fetchDetailExtra('test');
    final rejected = expectLater(
      first,
      throwsA(isA<PornHubRequestException>()),
    );
    while (adapter.pending.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    auth.username.value = 'second';
    final second = source.fetchDetailExtra('test');
    while (adapter.pending.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    adapter.pending[0].complete('<div>old</div>');
    await rejected;
    final duplicate = source.fetchDetailExtra('test');
    expect(identical(second, duplicate), true);
    adapter.pending[1].complete(
      '<script>"isFavourite":0</script><!--${'x' * 10001}-->',
    );
    final result = await second;
    expect(result.isFavourite, false);
    expect(adapter.pending.length, 2);
  });
}
