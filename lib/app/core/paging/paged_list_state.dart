import 'package:get/get.dart';

/// Independent reactive state for one paged list.
///
/// Controllers retain their source-specific fetch, merge, retry and scroll
/// policies. Flags and request epochs never implicitly notify the item list.
class PagedListState<T> {
  PagedListState({bool initiallyLoading = false})
    : loadingFirst = initiallyLoading.obs;

  final RxList<T> items = <T>[].obs;
  final RxInt page = 1.obs;
  final RxInt totalPages = 1.obs;
  final RxInt totalItems = 0.obs;
  final RxBool loadingFirst;
  final RxBool loadingPage = false.obs;
  final RxBool hasMore = true.obs;
  final RxnString error = RxnString();
  final RxnString pageError = RxnString();

  int _generation = 0;
  int get requestGeneration => _generation;

  /// Starts a new request family, invalidating earlier replies and cleanup.
  int beginRequest() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  /// Invalidates pending replies when the owning controller is closed.
  void invalidateRequests() => ++_generation;
}
