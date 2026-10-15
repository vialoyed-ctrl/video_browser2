import 'dart:async';

import 'package:video_browser/app/data/models/hanime1_models.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';

List<VideoItem> fixtureCards(String prefix) => List.generate(
  4,
  (i) => VideoItem(
    id: '$prefix-$i',
    title: 'Fixture $prefix $i',
    author: '',
    hlsUrl: '',
  ),
);

VideoPage fixtureRank(String prefix, int page) => VideoPage(
  items: fixtureCards(prefix),
  page: page,
  totalPages: 20,
  hasMore: true,
);

Hanime1SubscriptionData fixtureSubscriptions(String prefix, int page) =>
    Hanime1SubscriptionData(
      creators: const [
        Hanime1Creator(name: '全部', queryPath: ''),
        Hanime1Creator(name: 'Fixture creator', queryPath: 'fixture'),
      ],
      filters: const [],
      items: fixtureCards(prefix),
      page: page,
      totalPages: 20,
      hasMore: true,
    );

class HanimeListFixture extends Hanime1Source {
  final rankArguments = <(String, int)>[];
  final rankRequests = <Completer<VideoPage>>[];
  final subArguments = <Map<String, Object?>>[];
  final subRequests = <Completer<Hanime1SubscriptionData>>[];
  @override
  Future<VideoPage> fetchRankingList(String sortName, {int page = 1}) {
    rankArguments.add((sortName, page));
    final pending = Completer<VideoPage>();
    rankRequests.add(pending);
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
    subArguments.add({
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
    subRequests.add(pending);
    return pending.future;
  }
}
