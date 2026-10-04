import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/widgets/append_pagination_footer.dart';

void main() {
  testWidgets('page input validates zero, jumps and disposes safely', (
    tester,
  ) async {
    int? target;
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppendPaginationFooter(
            page: 2,
            hasMore: true,
            onNext: () => next++,
            onJump: (page) => target = page,
          ),
        ),
      ),
    );
    await tester.tap(find.text('续接下一页'));
    expect(next, 1);
    await tester.tap(find.text('第 2 页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('请输入大于 0 的页码'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '15');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(target, 15);
    expect(tester.takeException(), isNull);
  });
  testWidgets('busy footer disables duplicate requests', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppendPaginationFooter(
            page: 1,
            hasMore: true,
            loading: true,
            onNext: () => fail('duplicate'),
            onJump: (_) => fail('duplicate'),
          ),
        ),
      ),
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('加载中'), findsOneWidget);
  });
}
