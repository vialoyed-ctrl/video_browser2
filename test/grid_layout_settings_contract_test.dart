import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/grid_layout_settings.dart';
import 'package:video_browser/app/widgets/grid_layout_scope.dart';
import 'package:video_browser/app/widgets/grid_layout_settings_tile.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';
import 'package:video_browser/app/widgets/video_grid_sliver.dart';
import 'package:video_browser/app/widgets/adaptive_site_navigation.dart';
import 'package:video_browser/app/modules/hanime1/widgets/hanime1_card_h.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_video_grid.dart';

void main() {
  test('column preference restores, rejects bad values and keeps last rapid choice', () async {
    SharedPreferences.setMockInitialValues({
      GridLayoutSettings.preferenceKey: 4,
    });
    final prefs = await SharedPreferences.getInstance();
    final model = GridLayoutSettings();
    await model.init(preferences: prefs);
    expect(model.resolveColumns(400), 4);
    await Future.wait([
      model.setColumns(2),
      model.setColumns(6),
      model.setColumns(3),
    ]);
    final restarted = GridLayoutSettings();
    await restarted.init(preferences: prefs);
    expect(restarted.columns, 3);
    await restarted.setColumns(0);
    expect(restarted.resolveColumns(400), 2);
    expect(restarted.resolveColumns(900), 4);
    expect(() => restarted.setColumns(7), throwsArgumentError);
    await prefs.setInt(GridLayoutSettings.preferenceKey, -2);
    await restarted.init(preferences: prefs);
    expect(restarted.columns, 0);
    model.dispose();
    restarted.dispose();
  });
  testWidgets('layout setting opens and applies without restarting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final model = GridLayoutSettings();
    await model.init();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GridLayoutSettingsTile(settings: model)),
      ),
    );
    await tester.tap(find.text('卡片布局'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3列'));
    await tester.pumpAndSettle();
    expect(model.columns, 3);
    expect(find.text('3列 · 所有页面'), findsOneWidget);
  });
  for (final width in [240.0, 400.0, 900.0, 1200.0]) {
    for (final kind in ['shared', 'hanime', 'poster', 'pornhub']) {
      testWidgets(
        '$kind $width manual columns update retained grids without overflow',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final model = GridLayoutSettings();
          await model.init();
          addTearDown(model.dispose);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1200);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final items = List.generate(
            12,
            (i) => VideoItem(
              id: 'neutral-$i',
              title: 'Neutral fixture $i',
              author: 'Neutral author',
              publishedAt: '12 hours',
              hlsUrl: '',
            ),
          );
          final grid = switch (kind) {
            'hanime' => Hanime1VideoGridSliver(items: items),
            'poster' => Hanime1PosterGridSliver(items: items),
            'pornhub' => SliverPornHubGrid(videos: items, onDownload: (_) {}),
            _ => VideoGridSliver(
              items: items,
              availableWidth: width,
              padding: const EdgeInsets.all(6),
              itemBuilder: (_, v) =>
                  BiliVideoCardV(video: v, onDownload: () {}),
            ),
          };
          await tester.pumpWidget(
            MaterialApp(
              home: GridLayoutScope(
                settings: model,
                child: Scaffold(body: CustomScrollView(slivers: [grid])),
              ),
            ),
          );
          for (final count in [1, 2, 3, 4, 6, 0]) {
            await model.setColumns(count);
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: '$kind width=$width count=$count',
            );
            final columns = model.resolveColumns(width);
            if (kind == 'shared' || kind == 'pornhub') {
              final sliver = tester.widget<SliverGrid>(find.byType(SliverGrid));
              expect(
                (sliver.gridDelegate
                        as SliverGridDelegateWithFixedCrossAxisCount)
                    .crossAxisCount,
                columns,
              );
            } else {
              final cards = find.byType(
                kind == 'hanime' ? Hanime1CardH : Hanime1PosterCard,
              );
              expect(
                tester.getTopLeft(cards.at(columns - 1)).dy,
                tester.getTopLeft(cards.at(0)).dy,
              );
              if (cards.evaluate().length > columns) {
                expect(
                  tester.getTopLeft(cards.at(columns)).dy,
                  greaterThan(tester.getTopLeft(cards.at(0)).dy),
                );
              }
            }
          }
        },
      );
    }
  }
  testWidgets('tablet rail switches tabs and phone keeps its child', (
    tester,
  ) async {
    var selected = 0;
    Widget app() => MaterialApp(
      home: Material(
        child: AdaptiveSiteNavigation(
          selectedIndex: selected,
          onSelected: (i) => selected = i,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'First'),
            NavigationDestination(icon: Icon(Icons.person), label: 'Second'),
          ],
          child: const Text('Content'),
        ),
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('Second'));
    expect(selected, 1);
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(app());
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Content'), findsOneWidget);
  });
}
