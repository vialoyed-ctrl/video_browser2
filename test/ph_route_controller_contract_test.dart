import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_creator_controller.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_playlist_controller.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';

import 'support/ph_route_fixture.dart';

void main() {
  test('creator retry retains cursor and strict dedup', () async {
    final s = PhRouteFixture();
    final c = PornHubCreatorController(s, path: '/model/fixture');
    addTearDown(c.dispose);
    final first = c.load(reset: true);
    final cards = routeCards('first');
    s.requests.last.complete(routePage(cards, 1));
    await first;
    expect(c.items, cards);
    expect(() => c.items.clear(), throwsUnsupportedError);
    final pending = c.load(reset: false);
    s.requests.last.completeError(StateError('offline'));
    await pending;
    expect(c.nextPage, 2);
    expect(c.error, PornHubSource.requestFailureMessage);
    final retry = c.load(reset: false);
    s.requests.last.complete(routePage([...cards, ...routeCards('second')], 2));
    await retry;
    expect(s.arguments.map((a) => a.page), [1, 2, 2]);
    expect(c.items.length, 8);
    expect(c.nextPage, 3);
    expect(c.error, isNull);
  });
  test(
    'creator clips cap and latest video request ownership stay intact',
    () async {
      final s = PhRouteFixture();
      final c = PornHubCreatorController(s, path: '/model/fixture');
      addTearDown(c.dispose);
      final stale = c.load(reset: true);
      c.selectClips(true);
      final clips = c.load(reset: true);
      s.requests.first.complete(routePage(routeCards('stale'), 1));
      await stale;
      expect(c.loading, isTrue);
      expect(c.items, isEmpty);
      s.requests.last.complete(routePage(routeCards('clips'), 1, total: 4));
      await clips;
      expect(s.arguments.last.kind, 'clips');
      expect(c.items.first.id, 'clips-0');
      expect(c.hasMore, isFalse);
      await c.load(reset: false);
      expect(s.requests.length, 2);
    },
  );
  test(
    'creator summary-empty is failure without discarding prior data',
    () async {
      final s = PhRouteFixture();
      final c = PornHubCreatorController(s, path: '/model/fixture');
      addTearDown(c.dispose);
      final first = c.load(reset: true);
      s.requests.last.complete(routePage(routeCards('first'), 1));
      await first;
      final reset = c.load(reset: true, targetPage: 2);
      s.requests.last.complete(routePage([], 2, summary: 'offline'));
      await reset;
      expect(c.items.length, 4);
      expect(c.nextPage, 2);
      expect(c.error, isNotNull);
    },
  );
  for (final failed in [false, true]) {
    test('creator close rejects videos and profile failed=$failed', () async {
      final s = PhRouteFixture();
      final c = PornHubCreatorController(s, path: '/model/fixture');
      var changes = 0;
      c.addListener(() => changes++);
      final videos = c.load(reset: true);
      final profile = c.loadProfile();
      final before = changes;
      c.dispose();
      if (failed) {
        s.requests.last.completeError(StateError('late'));
        s.profiles.last.completeError(StateError('late'));
      } else {
        s.requests.last.complete(routePage(routeCards('late'), 1));
        s.profiles.last.complete(routeProfile);
      }
      await Future.wait([videos, profile]);
      expect(changes, before);
      expect(c.items, isEmpty);
      expect(c.profile, isNull);
      await c.load(reset: true);
      await c.loadProfile();
      expect(s.requests.length, 1);
      expect(s.profiles.length, 1);
    });
  }
  test('playlist details precede videos and rejected reset does not interrupt load', () async {
    final s = PhRouteFixture();
    final c = PornHubPlaylistController(s, id: '123');
    addTearDown(c.dispose);
    final first = c.load(reset: true);
    expect(s.requests, isEmpty);
    expect(s.detailRefreshes, [true]);
    await c.load(reset: true, targetPage: 8);
    expect(s.details.length, 1);
    s.details.last.complete(routeDetails);
    await Future<void>.value();
    s.requests.last.complete(routePage(routeCards('first'), 1));
    await first;
    expect(c.detail, routeDetails);
    expect(c.nextPage, 2);
    expect(() => c.videos.clear(), throwsUnsupportedError);
    final next = c.load();
    s.requests.last.completeError(StateError('offline'));
    await next;
    expect(c.nextPage, 2);
    expect(c.error, isNotNull);
    final retry = c.load();
    s.requests.last.complete(routePage(routeCards('first'), 2));
    await retry;
    expect(c.videos.length, 4);
    expect(c.hasMore, isTrue);
    expect(s.arguments.map((a) => a.page), [1, 2, 2]);
  });
  for (final atDetails in [false, true]) {
    test(
      'playlist account reset rejects stale stage details=$atDetails',
      () async {
        final s = PhRouteFixture();
        final c = PornHubPlaylistController(s, id: '123');
        addTearDown(c.dispose);
        final old = c.load(reset: true);
        if (!atDetails) {
          s.details.last.complete(routeDetails);
          await Future<void>.value();
        }
        final revision = c.requestRevision;
        c.resetAccount();
        expect(c.requestRevision, greaterThan(revision));
        final fresh = c.load(reset: true);
        if (atDetails) {
          s.details.first.complete(routeDetails);
        } else {
          s.requests.first.complete(routePage(routeCards('stale'), 1));
        }
        await old;
        expect(c.videos, isEmpty);
        expect(c.loading, isTrue);
        s.details.last.complete(routeDetails);
        await Future<void>.value();
        s.requests.last.complete(routePage(routeCards('fresh'), 1));
        await fresh;
        expect(c.videos.first.id, 'fresh-0');
        expect(c.loading, isFalse);
      },
    );
  }
  test('playlist close prevents notifications and fresh requests', () async {
    final s = PhRouteFixture();
    final c = PornHubPlaylistController(s, id: '123');
    var changes = 0;
    c.addListener(() => changes++);
    final pending = c.load(reset: true);
    final before = changes;
    c.dispose();
    s.details.last.complete(routeDetails);
    await pending;
    expect(changes, before);
    expect(s.requests, isEmpty);
    await c.load(reset: true);
    expect(s.details.length, 1);
  });

  test(
    'creator only accepted success updates retained-page metadata',
    () async {
      final s = PhRouteFixture();
      final c = PornHubCreatorController(s, path: '/model/fixture');
      addTearDown(c.dispose);
      final first = c.load(reset: true);
      expect(c.replacementGeneration, 0);
      s.requests.last.complete(routePage(routeCards('first'), 1));
      await first;
      expect(c.replacementGeneration, 1);
      expect(c.lastLoadWasAppend, isFalse);
      final append = c.load(reset: false);
      s.requests.last.complete(routePage([], 2));
      await append;
      expect(c.lastLoadWasAppend, isTrue);
      expect(c.replacementGeneration, 1);
      final reset = c.load(reset: true, targetPage: 7);
      expect(c.lastLoadWasAppend, isTrue);
      s.requests.last.completeError(StateError('offline'));
      await reset;
      expect(c.replacementGeneration, 1);
      expect(c.lastLoadWasAppend, isTrue);
      final old = c.load(reset: true);
      final fresh = c.load(reset: true, targetPage: 3);
      s.requests[s.requests.length - 2].complete(
        routePage(routeCards('old'), 1),
      );
      await old;
      expect(c.replacementGeneration, 1);
      s.requests.last.complete(routePage(routeCards('fresh'), 3));
      await fresh;
      expect(c.replacementGeneration, 2);
      expect(c.lastLoadWasAppend, isFalse);
    },
  );
  test('playlist failed reset and stale account reply leave success metadata intact', () async {
    final s = PhRouteFixture();
    final c = PornHubPlaylistController(s, id: '123');
    addTearDown(c.dispose);
    final first = c.load(reset: true);
    s.details.last.complete(routeDetails);
    await Future<void>.value();
    s.requests.last.complete(routePage(routeCards('first'), 1));
    await first;
    expect(c.replacementGeneration, 1);
    expect(c.lastLoadWasAppend, isFalse);
    final append = c.load();
    s.requests.last.complete(routePage([], 2));
    await append;
    expect(c.replacementGeneration, 1);
    expect(c.lastLoadWasAppend, isTrue);
    final reset = c.load(reset: true);
    s.details.last.completeError(StateError('offline'));
    await reset;
    expect(c.replacementGeneration, 1);
    expect(c.lastLoadWasAppend, isTrue);
    final stale = c.load(reset: true);
    c.resetAccount();
    s.details.last.complete(routeDetails);
    await stale;
    expect(c.replacementGeneration, 1);
    expect(c.lastLoadWasAppend, isTrue);
    final fresh = c.load(reset: true, targetPage: 4);
    s.details.last.complete(routeDetails);
    await Future<void>.value();
    s.requests.last.complete(routePage(routeCards('fresh'), 4));
    await fresh;
    expect(c.replacementGeneration, 2);
    expect(c.lastLoadWasAppend, isFalse);
  });
}
