import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/core/paging/paged_list_state.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/modules/home/home_controller.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'each list owns independent items, flags, metadata and request epochs',
    () {
      final home = PagedListState<String>(initiallyLoading: true);
      final search = PagedListState<String>();
      expect(home.loadingFirst.value, isTrue);
      expect(search.loadingFirst.value, isFalse);
      expect(home.page.value, 1);
      expect(search.totalPages.value, 1);
      expect(search.totalItems.value, 0);
      expect(home.hasMore.value, isTrue);
      expect(home.loadingPage.value, isFalse);
      home.items.add('a');
      home.page.value = 3;
      home.pageError.value = 'retry';
      expect(search.items, isEmpty);
      expect(search.page.value, 1);
      expect(search.pageError.value, isNull);
      expect(search.error.value, isNull);
    },
  );

  test(
    'loading and request invalidation do not notify items or page subscribers',
    () async {
      final state = PagedListState<String>();
      var itemNotifications = 0;
      var pageNotifications = 0;
      final items = state.items.listen((_) => itemNotifications++);
      final page = state.page.listen((_) => pageNotifications++);
      addTearDown(items.cancel);
      addTearDown(page.cancel);
      state.loadingFirst.value = true;
      state.loadingPage.value = true;
      state.error.value = 'offline';
      state.beginRequest();
      state.invalidateRequests();
      await Future<void>.delayed(Duration.zero);
      expect(itemNotifications, 0);
      expect(pageNotifications, 0);
      state.items.add('a');
      state.page.value = 2;
      await Future<void>.delayed(Duration.zero);
      expect(itemNotifications, 1);
      expect(pageNotifications, 1);
    },
  );

  test('new requests and closing invalidate only older generations', () {
    final state = PagedListState<int>();
    final old = state.beginRequest();
    expect(state.isCurrent(old), isTrue);
    final current = state.beginRequest();
    expect(state.isCurrent(old), isFalse);
    expect(state.isCurrent(current), isTrue);
    expect(state.requestGeneration, current);
    state.invalidateRequests();
    expect(state.isCurrent(current), isFalse);
    expect(state.items, isEmpty);
    expect(state.loadingFirst.value, isFalse);
  });

  test('controller public Rx aliases use the shared state without duplicate stores', () {
    final source = Site91Source();
    final home = HomeController(source);
    final search = SearchController(source);
    addTearDown(home.onClose);
    addTearDown(search.onClose);
    expect(identical(home.videos, home.paging.items), isTrue);
    expect(identical(home.currentPage, home.paging.page), isTrue);
    expect(identical(home.loadingFirst, home.paging.loadingFirst), isTrue);
    expect(identical(home.loadingMore, home.paging.loadingPage), isTrue);
    expect(identical(home.loadMoreError, home.paging.pageError), isTrue);
    expect(identical(search.results, search.paging.items), isTrue);
    expect(identical(search.currentPage, search.paging.page), isTrue);
    expect(identical(search.loading, search.paging.loadingFirst), isTrue);
    expect(identical(search.pageLoading, search.paging.loadingPage), isTrue);
    expect(identical(search.totalPages, search.paging.totalPages), isTrue);
    expect(identical(search.totalItems, search.paging.totalItems), isTrue);
    expect(identical(home.paging, search.paging), isFalse);
  });
}
