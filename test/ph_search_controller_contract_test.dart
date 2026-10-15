import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_search_controller.dart';

import 'support/ph_search_fixture.dart';

void main() {
  for (final kind in ['videos', 'clips', 'creators', 'playlists']) {
    test(
      '$kind route controller keeps paths, dedup and retry cursor',
      () async {
        final source = PhSearchFixture();
        final controller = PornHubSearchController(source);
        addTearDown(controller.dispose);
        controller.selectKind(kind);
        final first = controller.submit(' fixture ');
        final paths = {
          'videos': '/video/search?search=fixture',
          'clips': '/clips?search=fixture',
          'creators': '/user/search?username=fixture&gender=0',
          'playlists': '/playlists?o=mr',
        };
        expect(source.arguments.single, (paths[kind], 1, kind));
        source.requests.last.complete(phSearchResponse(kind, 'first'));
        await first;
        expect(controller.nextPage, 2);
        final pending = controller.load(reset: false);
        expect(controller.loading, isTrue);
        expect(controller.nextPage, 2);
        source.requests.last.completeError(StateError('offline'));
        await pending;
        expect(controller.nextPage, 2);
        expect(controller.error, isNotNull);
        final retry = controller.load(reset: false);
        expect(source.arguments.map((a) => a.$2), [1, 2, 2]);
        source.requests.last.complete(phSearchResponse(kind, 'first'));
        await retry;
        expect(
          controller.videos.length +
              controller.creators.length +
              controller.playlists.length,
          4,
        );
        expect(controller.nextPage, 3);
        expect(controller.error, isNull);
      },
    );
  }
  for (final failure in [false, true]) {
    test('new query rejects older response failure=$failure', () async {
      final source = PhSearchFixture();
      final controller = PornHubSearchController(source);
      addTearDown(controller.dispose);
      final old = controller.submit('old');
      final fresh = controller.submit('fresh');
      if (failure) {
        source.requests.first.completeError(StateError('old'));
      } else {
        source.requests.first.complete(phSearchResponse('videos', 'old'));
      }
      await old;
      expect(controller.loading, isTrue);
      expect(controller.videos, isEmpty);
      source.requests.last.complete(phSearchResponse('videos', 'fresh'));
      await fresh;
      expect(controller.videos.first.id, 'fresh-0');
      expect(controller.loading, isFalse);
    });
    test(
      'disposed route ignores response failure=$failure without notifying',
      () async {
        final source = PhSearchFixture();
        final controller = PornHubSearchController(source);
        var notifications = 0;
        controller.addListener(() => notifications++);
        final pending = controller.submit('fixture');
        final before = notifications;
        controller.dispose();
        if (failure) {
          source.requests.last.completeError(StateError('late'));
        } else {
          source.requests.last.complete(phSearchResponse('videos', 'late'));
        }
        await pending;
        expect(notifications, before);
        expect(controller.videos, isEmpty);
      },
    );
  }
  test('initial browsing path and filters stay on original route', () async {
    final source = PhSearchFixture();
    final controller = PornHubSearchController(
      source,
      initialPath: '/video?o=mv&page=7',
    );
    addTearDown(controller.dispose);
    final first = controller.start();
    expect(source.arguments.single, ('/video?o=mv&page=7', 1, 'videos'));
    source.requests.last.complete(phSearchResponse('videos', 'first'));
    await first;
    expect(controller.filters, {'o': 'mv'});
    controller.applyFilters({'o': 'tr'});
    final filtered = controller.load(reset: true, clear: true);
    expect(source.arguments.last, ('/video?o=tr', 1, 'videos'));
    expect(controller.videos, isEmpty);
    source.requests.last.complete(phSearchResponse('videos', 'new'));
    await filtered;
    expect(controller.videos.first.id, 'new-0');
  });
  test(
    'empty input keeps original no-request rule and playlist exception',
    () async {
      final source = PhSearchFixture();
      final controller = PornHubSearchController(source);
      addTearDown(controller.dispose);
      await controller.start();
      await controller.submit(' ');
      expect(source.arguments, isEmpty);
      controller.selectKind('playlists');
      final request = controller.submit(' ');
      expect(source.arguments.single, ('/playlists?o=mr', 1, 'playlists'));
      source.requests.last.complete(phSearchResponse('playlists', 'first'));
      await request;
      expect(controller.playlists, hasLength(4));
    },
  );
}
