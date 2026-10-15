import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/modules/mine/mine_view.dart';
import 'package:video_browser/app/modules/hanime1/widgets/hanime1_card_h.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_video_grid.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/widgets/video_grid_sliver.dart';

List<VideoItem> fixtures() => List.generate(
  8,
  (i) =>
      VideoItem(id: 'layout-$i', title: 'Neutral $i', author: '', hlsUrl: ''),
);

void main() {
  tearDown(Get.reset);
  testWidgets('91 newest subscription appears first, including resubscribe', (
    tester,
  ) async {
    final user = Get.put(UserService());
    user.toggleSubscription('Old fixture');
    user.toggleSubscription('New fixture');
    await tester.pumpWidget(
      const GetMaterialApp(home: SubscriptionsListView()),
    );
    expect(
      (tester.widgetList<ListTile>(find.byType(ListTile)).first.title! as Text)
          .data,
      'New fixture',
    );
    user.toggleSubscription('Old fixture');
    user.toggleSubscription('Old fixture');
    await tester.pump();
    expect(
      (tester.widgetList<ListTile>(find.byType(ListTile)).first.title! as Text)
          .data,
      'Old fixture',
    );
    expect(user.subscriptions.length, 2);
  });
  testWidgets('Hanime tablet uses four columns rather than fixed two', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Material(child: child!),
        home: CustomScrollView(
          slivers: [Hanime1VideoGridSliver(items: fixtures())],
        ),
      ),
    );
    final cards = find.byType(Hanime1CardH);
    expect(
      tester.getTopLeft(cards.at(3)).dy,
      tester.getTopLeft(cards.at(0)).dy,
    );
    expect(tester.takeException(), isNull);
  });
  for (final kind in ['shared', 'pornhub']) {
    testWidgets('$kind grid uses pane width, not full tablet width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => Material(child: child!),
          home: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 600,
              child: CustomScrollView(
                slivers: [
                  if (kind == 'shared')
                    VideoGridSliver(
                      items: fixtures(),
                      availableWidth: 1200,
                      padding: const EdgeInsets.all(6),
                      itemBuilder: (_, v) => Text(v.title),
                    )
                  else
                    SliverPornHubGrid(videos: fixtures()),
                ],
              ),
            ),
          ),
        ),
      );
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
