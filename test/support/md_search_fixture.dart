import 'dart:async';

import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';

class MdSearchFixture implements VideoSource {
  @override
  String get id => 'site91md';
  final arguments = <(String, int, int)>[];
  final requests = <Completer<VideoPage>>[];
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) {
    arguments.add((query.keyword, page, pageSize));
    final request = Completer<VideoPage>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VideoPage mdResponse(String prefix, int page, {bool more = true}) => VideoPage(
  items: List.generate(
    4,
    (i) => VideoItem(
      id: '$prefix-$i',
      title: 'Fixture $prefix $i',
      author: '91麻豆',
      hlsUrl: '',
    ),
  ),
  page: page,
  totalPages: more ? 20 : page,
  hasMore: more,
);
