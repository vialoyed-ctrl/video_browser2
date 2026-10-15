import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';
import 'package:video_browser/app/modules/search/search_view.dart';

class HeaderFixtureSource implements VideoSource {
  @override
  String get id => 'hanime1';
  @override
  Future<List<String>> fetchHotKeywords() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final type in [SearchType.videoName, SearchType.authorId]) {
    testWidgets(
      'Hanime $type pinned filter preserves full width and 40px extent',
      (tester) async {
        Get.testMode = true;
        addTearDown(Get.reset);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = SearchController(HeaderFixtureSource());
        controller.searchType.value = type;
        controller.keyword.value = 'fixture';
        controller.hasSearched.value = true;
        controller.results.add(
          VideoItem(id: 'neutral', title: 'Fixture', author: '', hlsUrl: ''),
        );
        await tester.pumpWidget(
          GetMaterialApp(home: SearchView(searchController: controller)),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        final filterHeader = find.byWidgetPredicate(
          (widget) =>
              widget is SliverPersistentHeader &&
              widget.delegate.minExtent == 40,
        );
        final sliver = tester.renderObject<RenderSliverPersistentHeader>(
          filterHeader,
        );
        expect(sliver.geometry!.scrollExtent, 40);
        expect(sliver.geometry!.paintExtent, 40);
        expect(sliver.geometry!.layoutExtent, 40);
        expect(sliver.child!.size.height, 40);
        // Natural filter content remains 39px and starts at the same top edge.
        final align = find
            .descendant(of: filterHeader, matching: find.byType(Align))
            .first;
        final filter = tester.widget<Align>(align).child!;
        final filterFinder = find.byWidget(filter);
        expect(tester.getSize(filterFinder).height, 39);
        expect(tester.getSize(filterFinder).width, 400);
        expect(tester.getTopLeft(filterFinder).dx, 0);
        expect(tester.getTopLeft(filterFinder).dy, tester.getTopLeft(align).dy);
      },
    );
  }
}
