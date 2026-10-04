import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';

class _DelayedSource extends Hanime1Source {
  final requests = <String, Completer<VideoPage>>{};

  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) {
    return (requests[query.keyword] = Completer<VideoPage>()).future;
  }
}

class _Delayed91Source extends Site91Source {
  _Delayed91Source() : super(baseUrl: 'https://91porny.com');

  final requests = <String, Completer<VideoPage>>{};

  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) {
    return (requests[query.keyword] = Completer<VideoPage>()).future;
  }
}

VideoPage _page(String id) => VideoPage(
  items: [VideoItem(id: id, title: id, author: '', hlsUrl: '')],
  page: 1,
  hasMore: false,
);

VideoPage _summaryPage(String summary) => VideoPage(
  items: const <VideoItem>[],
  page: 1,
  hasMore: false,
  summary: summary,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('append, jump and failed jump retry preserve the correct page', () async {
    final source = _DelayedSource();
    final controller = SearchController(source);
    addTearDown(controller.onClose);
    controller.keyword.value = 'paging';
    VideoPage response(int page) => VideoPage(
      items: [VideoItem(id: '$page', title: 'sample', author: '', hlsUrl: '')],
      page: page, totalPages: 20, hasMore: true,
    );
    final first = controller.runSearch();
    source.requests['paging']!.complete(response(1));
    await first;
    final append = controller.goToPage(2, append: true);
    source.requests['paging']!.complete(response(2));
    await append;
    expect(controller.results.map((v) => v.id), ['1', '2']);
    final jump = controller.goToPage(10);
    source.requests['paging']!.completeError(StateError('offline'));
    await jump;
    expect(controller.currentPage.value, 2);
    expect(controller.results.map((v) => v.id), ['1', '2']);
    controller.nextPage();
    source.requests['paging']!.complete(response(10));
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentPage.value, 10);
    expect(controller.results.single.id, '10');
    final following = controller.goToPage(11, append: true);
    source.requests['paging']!.complete(response(11));
    await following;
    expect(controller.results.map((v) => v.id), ['10', '11']);
  });

  test(
    'new Hanime filter runs immediately and stale results cannot replace it',
    () async {
      final source = _DelayedSource();
      final controller = SearchController(source);
      addTearDown(controller.onClose);
      controller.keyword.value = 'old';
      final old = controller.runSearch();
      controller.keyword.value = 'new';
      final current = controller.runSearch();
      expect(source.requests.keys, containsAll(['old', 'new']));
      source.requests['new']!.complete(_page('new'));
      await current;
      expect(controller.results.single.id, 'new');
      source.requests['old']!.complete(_page('old'));
      await old;
      expect(controller.results.single.id, 'new');
      expect(controller.loading.value, isFalse);
    },
  );

  test(
    'a new 91 keyword is not queued behind a slow previous request',
    () async {
      final source = _Delayed91Source();
      final controller = SearchController(source);
      addTearDown(controller.onClose);

      controller.keyword.value = 'old';
      final old = controller.runSearch();
      controller.keyword.value = 'new';
      final current = controller.runSearch();

      expect(source.requests.keys, containsAll(['old', 'new']));
      source.requests['new']!.complete(_summaryPage('new results'));
      await current;
      expect(controller.summaryText.value, 'new results');

      source.requests['old']!.complete(_summaryPage('old results'));
      await old;
      expect(controller.summaryText.value, 'new results');
      expect(controller.loading.value, isFalse);
    },
  );
}
