import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';
import 'package:video_browser/app/widgets/video_grid_sliver.dart';

VideoItem item(int i) =>
    VideoItem(id: '$i', title: 'Fixture $i', author: '', hlsUrl: '');

void main() {
  for (final geometry in [(400.0, 2), (600.0, 3), (900.0, 4), (1200.0, 5)]) {
    for (final inset in [6.0, 8.0]) {
      testWidgets(
        '${geometry.$1} width with $inset padding preserves tile geometry',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(geometry.$1, 900);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              home: CustomScrollView(
                slivers: [
                  VideoGridSliver(
                    items: List.generate(geometry.$2 * 2, item),
                    availableWidth: geometry.$1,
                    padding: EdgeInsets.symmetric(
                      horizontal: inset,
                      vertical: 4,
                    ),
                    itemBuilder: (_, video) =>
                        SizedBox(key: ValueKey(video.id)),
                  ),
                ],
              ),
            ),
          );
          final tileWidth =
              (geometry.$1 - inset * 2 - (geometry.$2 - 1) * 6) / geometry.$2;
          final expectedHeight =
              (tileWidth /
              (tileWidth / (tileWidth * 0.625 + 74)).clamp(0.85, 1.25));
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('0'))),
            Offset(inset, 4),
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('0'))).width,
            closeTo(tileWidth, 0.001),
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('0'))).height,
            closeTo(expectedHeight, 0.001),
          );
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('1'))).dx,
            closeTo(inset + tileWidth + 6, 0.001),
          );
          expect(
            tester.getTopLeft(find.byKey(ValueKey('${geometry.$2}'))).dy,
            closeTo(4 + expectedHeight + 6, 0.001),
          );
        },
      );
    }
  }

  testWidgets('caller card actions receive the original video', (tester) async {
    final video = item(9);
    VideoItem? opened, downloaded;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            VideoGridSliver(
              items: [video],
              availableWidth: 400,
              padding: EdgeInsets.zero,
              itemBuilder: (_, value) => Column(
                children: [
                  TextButton(
                    onPressed: () => opened = value,
                    child: const Text('Open'),
                  ),
                  TextButton(
                    onPressed: () => downloaded = value,
                    child: const Text('Download'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.tap(find.text('Download'));
    expect(identical(opened, video), isTrue);
    expect(identical(downloaded, video), isTrue);
  });

  testWidgets(
    'retained append keeps scroll and page boundary; replacement removes old page',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var videos = List.generate(12, item);
      var page = 1;
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: CustomScrollView(
            controller: scroll,
            slivers: [
              RetainedPageSliver(
                items: videos,
                page: page,
                footer: const SizedBox(height: 60, child: Text('Footer')),
                gridBuilder: (values) => VideoGridSliver(
                  items: values,
                  availableWidth: 800,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  itemBuilder: (_, video) => Text(video.title),
                ),
              ),
            ],
          ),
        ),
      );
      await render();
      scroll.jumpTo(100);
      await tester.pump();
      videos = [...videos, ...List.generate(12, (i) => item(i + 12))];
      page = 2;
      await render();
      expect(scroll.offset, 100);
      expect(
        find.byKey(const ValueKey('grid-1'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('grid-2'), skipOffstage: false),
        findsOneWidget,
      );
      scroll.jumpTo(700);
      await tester.pump();
      expect(find.text('Fixture 12'), findsOneWidget);
      videos = List.generate(12, (i) => item(i + 100));
      page = 7;
      await render();
      expect(
        find.byKey(const ValueKey('grid-1'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('grid-2'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('grid-7'), skipOffstage: false),
        findsOneWidget,
      );
    },
  );
}
