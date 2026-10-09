import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/home/home_controller.dart';
import 'package:video_browser/app/services/preload_service.dart';

class _HomeSource extends Site91Source {
  final requests = <Completer<VideoPage>>[];
  final requestedPages = <int>[];

  @override
  Future<List<String>> fetchHotKeywords() async => const ['Fixture'];

  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) {
    final request = Completer<VideoPage>();
    requests.add(request);
    requestedPages.add(page);
    return request.future;
  }
}

VideoPage _page(String id) => VideoPage(
  items: [VideoItem(id: id, title: id, author: '', hlsUrl: '')],
  page: 1,
  hasMore: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int previousPreloadCount;
  setUp(() {
    previousPreloadCount = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(
    () => PreloadService.instance.preloadCount.value = previousPreloadCount,
  );

  test(
    'a quick channel switch shows the latest page and ignores the old reply',
    () async {
      final source = _HomeSource();
      final controller = HomeController(source);
      controller.onInit();
      expect(source.requests, hasLength(1));
      controller.switchChannel(
        ChannelType.video,
        const VideoCategory(id: 'new', name: 'New', path: '/video/new'),
      );
      expect(source.requests, hasLength(2));

      source.requests[1].complete(_page('new-channel'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.videos.single.id, 'new-channel');
      expect(controller.loadingFirst.value, isFalse);

      source.requests[0].complete(_page('stale-home'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.videos.single.id, 'new-channel');
      controller.onClose();
    },
  );

  VideoPage response(List<String> ids, int page, {bool hasMore = true}) =>
      VideoPage(
        items: ids
            .map((id) => VideoItem(id: id, title: id, author: '', hlsUrl: ''))
            .toList(),
        page: page,
        hasMore: hasMore,
      );

  test('append deduplicates and skips a repeated page before publishing the next page', () async {
    final source = _HomeSource();
    final controller = HomeController(source);
    addTearDown(controller.onClose);
    final first = controller.loadFirstPage();
    source.requests.last.complete(response(['a', 'a', 'b'], 1));
    await first;
    expect(controller.videos.map((v) => v.id), ['a', 'b']);

    final append = controller.loadMore();
    source.requests.last.complete(response(['a', 'b'], 2));
    await Future<void>.delayed(Duration.zero);
    expect(source.requestedPages, [1, 2, 3]);
    source.requests.last.complete(response(['b', 'c'], 3, hasMore: false));
    await append;
    expect(controller.videos.map((v) => v.id), ['a', 'b', 'c']);
    expect(controller.currentPage.value, 3);
    expect(controller.hasMore.value, isFalse);
    expect(controller.loadingMore.value, isFalse);
  });

  test('failed jump preserves existing results and retries the same target before append', () async {
    final source = _HomeSource();
    final controller = HomeController(source);
    addTearDown(controller.onClose);
    final first = controller.loadFirstPage();
    source.requests.last.complete(response(['a'], 1));
    await first;
    final jump = controller.jumpToPage(7);
    source.requests.last.completeError(StateError('offline'));
    await jump;
    expect(controller.videos.single.id, 'a');
    expect(controller.currentPage.value, 1);
    expect(controller.error.value, isNull);
    expect(controller.loadMoreError.value, '第 7 页加载失败，请重试');

    final retry = controller.retryOrLoadMore();
    expect(source.requestedPages, [1, 7, 7]);
    source.requests.last.complete(response(['g'], 7));
    await retry;
    expect(controller.videos.single.id, 'g');
    expect(controller.currentPage.value, 7);
    final append = controller.loadMore();
    expect(source.requestedPages.last, 8);
    source.requests.last.complete(response(['h'], 8));
    await append;
    expect(controller.videos.map((v) => v.id), ['g', 'h']);
  });

  test('closing invalidates an outstanding first page without publishing its reply', () async {
    final source = _HomeSource();
    final controller = HomeController(source);
    final pending = controller.loadFirstPage();
    controller.onClose();
    source.requests.last.complete(response(['late'], 1));
    await pending;
    expect(controller.videos, isEmpty);
  });

  test(
    'closing invalidates an outstanding append and preserves existing results',
    () async {
      final source = _HomeSource();
      final controller = HomeController(source);
      final first = controller.loadFirstPage();
      source.requests.last.complete(response(['a'], 1));
      await first;
      final pending = controller.loadMore();
      controller.onClose();
      source.requests.last.complete(response(['late'], 2));
      await pending;
      expect(controller.videos.single.id, 'a');
      expect(controller.currentPage.value, 1);
    },
  );
}
