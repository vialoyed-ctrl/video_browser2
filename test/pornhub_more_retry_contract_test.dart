import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_more_page.dart';

class MoreFixture extends PornHubSource {
  final lists = <Completer<List<PornHubPlaylist>>>[];
  final stars = <Completer<List<PornHubStar>>>[];
  @override
  Future<List<PornHubPlaylist>> fetchPlaylists({
    int page = 1,
    String path = '/playlists?o=mr',
  }) {
    final c = Completer<List<PornHubPlaylist>>();
    lists.add(c);
    return c.future;
  }

  @override
  Future<List<PornHubStar>> fetchStars({int page = 1}) {
    final c = Completer<List<PornHubStar>>();
    stars.add(c);
    return c.future;
  }

  int count(int tab) => tab == 1 ? lists.length : stars.length;
  void fail(int tab, int index) {
    if (tab == 1) {
      lists[index].completeError(StateError('neutral fixture'));
    } else {
      stars[index].completeError(StateError('neutral fixture'));
    }
  }

  void finishAll() {
    for (final c in lists) {
      if (!c.isCompleted) c.complete([]);
    }
    for (final c in stars) {
      if (!c.isCompleted) c.complete([]);
    }
  }
}

void main() {
  for (final tab in [1, 2]) {
    testWidgets(
      'more tab $tab coalesces rapid retry before the loading frame',
      (tester) async {
        Get.testMode = true;
        final source = MoreFixture();
        Get.put(PornHubController(source));
        try {
          await tester.pumpWidget(
            GetMaterialApp(home: PornHubMorePage(initialIndex: tab)),
          );
          expect(source.count(tab), 1);
          source.fail(tab, 0);
          await tester.pump();
          final retry = find.text('重试');
          expect(retry, findsOneWidget);
          await tester.tap(retry);
          await tester.tap(retry);
          expect(
            source.count(tab),
            2,
            reason: 'Two taps before rebuild must share the pending retry',
          );
          source.finishAll();
          await tester.pump();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          source.finishAll();
          await tester.pump();
          Get.reset();
        }
      },
    );
    testWidgets('more tab $tab drops pending reply after route closes', (
      tester,
    ) async {
      Get.testMode = true;
      final source = MoreFixture();
      Get.put(PornHubController(source));
      try {
        await tester.pumpWidget(
          GetMaterialApp(home: PornHubMorePage(initialIndex: tab)),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        source.finishAll();
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        source.finishAll();
        Get.reset();
      }
    });
  }
}
