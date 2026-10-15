import 'dart:async';

import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';

class PhRouteFixture extends PornHubSource {
  final actions = <Completer<({bool ok, String message})>>[];
  final actionArguments = <String>[];
  @override
  Future<({bool ok, String message})> setCreatorSubscription(String path) {
    actionArguments.add(path);
    final pending = Completer<({bool ok, String message})>();
    actions.add(pending);
    return pending.future;
  }

  @override
  Future<({bool ok, String message})> setPlaylistFavourite(
    String id, {
    bool remove = false,
  }) {
    actionArguments.add('$id:$remove');
    final pending = Completer<({bool ok, String message})>();
    actions.add(pending);
    return pending.future;
  }

  final requests = <Completer<VideoPage>>[];
  final arguments = <({String kind, String path, int page})>[];
  final profiles = <Completer<PornHubCreatorProfile>>[];
  final details = <Completer<PornHubPlaylistDetails>>[];
  final detailRefreshes = <bool>[];
  Future<VideoPage> request(String kind, String path, int page) {
    arguments.add((kind: kind, path: path, page: page));
    final pending = Completer<VideoPage>();
    requests.add(pending);
    return pending.future;
  }

  @override
  Future<VideoPage> fetchCreatorVideos(String path, {int page = 1}) =>
      request('videos', path, page);
  @override
  Future<VideoPage> fetchCreatorClips(String path, {int page = 1}) =>
      request('clips', path, page);
  @override
  Future<VideoPage> fetchPlaylistVideos(String id, {int page = 1}) =>
      request('playlist', id, page);
  @override
  Future<PornHubCreatorProfile> fetchCreatorProfile(String path) {
    final pending = Completer<PornHubCreatorProfile>();
    profiles.add(pending);
    return pending.future;
  }

  @override
  Future<PornHubPlaylistDetails> fetchPlaylistDetails(
    String id, {
    bool forceRefresh = false,
  }) {
    detailRefreshes.add(forceRefresh);
    final pending = Completer<PornHubPlaylistDetails>();
    details.add(pending);
    return pending.future;
  }
}

List<VideoItem> routeCards(String prefix) => List.generate(
  4,
  (i) => VideoItem(
    id: '$prefix-$i',
    title: 'Fixture $prefix $i',
    author: '',
    hlsUrl: '',
  ),
);
VideoPage routePage(
  List<VideoItem> items,
  int page, {
  bool more = true,
  int total = 0,
  String? summary,
}) => VideoPage(
  items: items,
  page: page,
  totalPages: 20,
  hasMore: more,
  totalItems: total,
  summary: summary,
);
const routeProfile = PornHubCreatorProfile(
  path: '/model/fixture',
  name: 'Fixture creator',
  videoCount: 80,
);
const routeDetails = PornHubPlaylistDetails(
  playlist: PornHubPlaylist(
    id: '123',
    title: 'Fixture playlist',
    url: '/playlist/123',
    videoCount: 80,
  ),
);
