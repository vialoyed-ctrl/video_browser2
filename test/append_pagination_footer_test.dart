import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/widgets/append_pagination_footer.dart';
import 'package:video_browser/app/widgets/retained_page_sliver.dart';

List<VideoItem> items(List<String> ids) => ids
    .map((id) => VideoItem(id: id, title: id, author: '', hlsUrl: ''))
    .toList();
void main() {
  testWidgets(
    'centered page row opens validated numeric jump without next button',
    (tester) async {
      int? target;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppendPaginationFooter(
              page: 2,
              totalPages: 20,
              hasMore: true,
              onNext: () {},
              onJump: (page) => target = page,
            ),
          ),
        ),
      );
      expect(find.text('续接下一页'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
      expect(find.text('请输入大于 0 的页码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '21');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
      expect(find.text('最大页码为 20'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '15');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();
      expect(target, 15);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('append retains page separator; jump replaces all old sections', (
    tester,
  ) async {
    Widget screen(List<String> ids, int page) => MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            RetainedPageSliver(
              items: items(ids),
              page: page,
              footer: AppendPaginationFooter(
                page: page,
                hasMore: true,
                onNext: () {},
                onJump: (_) {},
              ),
              gridBuilder: (videos) => SliverList.list(
                children: videos.map((v) => Text('video-${v.id}')).toList(),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(screen(['a', 'b'], 1));
    await tester.pumpWidget(screen(['a', 'b', 'c', 'd'], 2));
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('video-a'), findsOneWidget);
    expect(find.text('video-d'), findsOneWidget);
    await tester.pumpWidget(screen(['j', 'k'], 10));
    expect(find.text('第 1 页'), findsNothing);
    expect(find.text('第 2 页'), findsNothing);
    expect(find.text('第 10 页'), findsOneWidget);
    expect(find.text('video-a'), findsNothing);
  });
  testWidgets('upward bottom drag appends only once for the same extent', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 900)),
              SliverToBoxAdapter(
                child: AppendPaginationFooter(
                  page: 1,
                  hasMore: true,
                  onNext: () => requests++,
                  onJump: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });
}
