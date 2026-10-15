import 'dart:async';

import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';

class PhSearchFixture extends PornHubSource {
  final arguments = <(String, int, String)>[];
  final requests = <Completer<PornHubBrowseData>>[];
  @override
  Future<PornHubBrowseData> fetchBrowse(
    String path, {
    int page = 1,
    String kind = 'videos',
  }) {
    arguments.add((path, page, kind));
    final pending = Completer<PornHubBrowseData>();
    requests.add(pending);
    return pending.future;
  }
}

PornHubBrowseData phSearchResponse(
  String kind,
  String prefix, {
  bool more = true,
}) => PornHubBrowseData(
  videos: kind == 'videos' || kind == 'clips'
      ? List.generate(
          4,
          (i) => VideoItem(
            id: '$prefix-$i',
            title: 'Fixture $prefix $i',
            author: '',
            hlsUrl: '',
          ),
        )
      : const [],
  creators: kind == 'creators'
      ? List.generate(
          4,
          (i) => PornHubSubscription(
            name: 'Fixture $prefix $i',
            path: '/user/$prefix-$i',
          ),
        )
      : const [],
  playlists: kind == 'playlists'
      ? List.generate(
          4,
          (i) => PornHubPlaylist(
            id: '$prefix-$i',
            title: 'Fixture $prefix $i',
            url: '/playlist/$prefix-$i',
            videoCount: 10,
          ),
        )
      : const [],
  hasMore: more,
);
