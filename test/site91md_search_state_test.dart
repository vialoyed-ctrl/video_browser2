import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/search/site91md_search_controller.dart';

class PendingSource implements VideoSource {
  final requests = <String, List<Completer<VideoPage>>>{};
  @override
  String get id => 'site91md';
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) {
    final pending = Completer<VideoPage>();
    requests.putIfAbsent('${query.keyword}/$page', () => []).add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VideoPage response(List<String> ids, int page, {bool more = false}) =>
    VideoPage(
      items: ids
          .map((id) => VideoItem(id: id, title: id, author: '91麻豆', hlsUrl: ''))
          .toList(),
      page: page,
      totalPages: more ? page + 1 : page,
      hasMore: more,
    );
void main() {
  test('new keyword wins even if the previous request finishes last', () async {
    final source = PendingSource(),
        state = Site91MdSearchController(PendingSource());
    state.dispose();
    final controller = Site91MdSearchController(source);
    final old = controller.submit('old');
    final newest = controller.submit('new');
    source.requests['new/1']!.last.complete(response(['new'], 1));
    await newest;
    source.requests['old/1']!.last.complete(response(['old'], 1));
    await old;
    expect(controller.items.map((v) => v.id), ['new']);
    expect(controller.keyword, 'new');
    expect(controller.loading, isFalse);
    controller.dispose();
  });
  test('append preserves website repeats; failed next page retries without data loss', () async {
    final source = PendingSource();
    final controller = Site91MdSearchController(source);
    final first = controller.submit('sample');
    source.requests['sample/1']!.last.complete(
      response(['b', 'a'], 1, more: true),
    );
    await first;
    final fail = controller.loadMore();
    source.requests['sample/2']!.last.completeError(StateError('offline'));
    await fail;
    expect(controller.items.map((v) => v.id), ['b', 'a']);
    expect(controller.page, 1);
    expect(controller.hasMore, isTrue);
    final retry = controller.retry();
    source.requests['sample/2']!.last.complete(response(['a', 'c'], 2));
    await retry;
    expect(controller.items.map((v) => v.id), ['b', 'a', 'a', 'c']);
    expect(controller.page, 2);
    expect(controller.hasMore, isFalse);
    final back = controller.goToPage(1);
    source.requests['sample/1']!.last.complete(
      response(['b', 'a'], 1, more: true),
    );
    await back;
    expect(controller.items.map((v) => v.id), ['b', 'a']);
    expect(controller.firstPage, 1);
    controller.dispose();
  });
  test('clear and dispose invalidate pending page loads', () async {
    final source = PendingSource();
    final controller = Site91MdSearchController(source);
    final pending = controller.submit('sample');
    await controller.submit('');
    source.requests['sample/1']!.last.complete(response(['late'], 1));
    await pending;
    expect(controller.items, isEmpty);
    expect(controller.searched, isFalse);
    final closing = controller.submit('closing');
    controller.dispose();
    source.requests['closing/1']!.last.complete(response(['late'], 1));
    await closing;
    expect(controller.items, isEmpty);
  });
}
