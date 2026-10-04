import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/models/video_item.dart';
import '../../data/sources/video_source.dart';

/// Route-local search state: a newer query always invalidates older responses.
class Site91MdSearchController extends ChangeNotifier {
  Site91MdSearchController(this.source);
  final VideoSource source;
  final List<VideoItem> _items = [];
  late final List<VideoItem> items = UnmodifiableListView(_items);
  String keyword = '';
  int page = 1;
  int firstPage = 1;
  int lastAvailablePage = 1;
  bool hasMore = false;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  bool searched = false;
  int _generation = 0;
  bool _disposed = false;
  int? _failedPage;
  bool _failedAppend = false;

  Future<void> submit(String value) async {
    keyword = value.trim();
    _generation++;
    _items.clear();
    page = firstPage = lastAvailablePage = 1;
    hasMore = false;
    error = null;
    loadingMore = false;
    loading = false;
    searched = keyword.isNotEmpty;
    if (!searched) {
      notifyListeners();
      return;
    }
    await _load(1, append: false);
  }

  Future<void> goToPage(int target) async {
    if (_disposed ||
        loading ||
        loadingMore ||
        !searched ||
        target < 1 ||
        target > lastAvailablePage) {
      return;
    }
    await _load(target, append: false);
  }

  Future<void> loadMore() async {
    if (_disposed || loading || loadingMore || !hasMore) return;
    await _load(page + 1, append: true);
  }

  Future<void> retry() async {
    if (_disposed || loading || loadingMore || _failedPage == null) return;
    await _load(_failedPage!, append: _failedAppend);
  }

  Future<void> _load(int target, {required bool append}) async {
    final generation = ++_generation;
    final requestedKeyword = keyword;
    loading = !append;
    loadingMore = append;
    error = null;
    notifyListeners();
    try {
      final result = await source.search(
        query: SearchQuery(keyword: requestedKeyword),
        page: target,
      );
      if (_disposed || generation != _generation) return;
      // Keep the website's exact ordering, including repeated cards across pages.
      if (!append) {
        _items.clear();
        firstPage = target;
      }
      _items.addAll(result.items);
      page = target;
      lastAvailablePage = result.totalPages > target
          ? result.totalPages
          : target;
      hasMore = result.hasMore;
      _failedPage = null;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _failedPage = target;
      _failedAppend = append;
      error = '第 $target 页加载失败，请重试';
    } finally {
      if (!_disposed && generation == _generation) {
        loading = loadingMore = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
