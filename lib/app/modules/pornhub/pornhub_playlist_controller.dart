import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/models/pornhub_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/pornhub_source.dart';

/// Owned by one playlist route; account observation and actions stay in the view.
class PornHubPlaylistController extends ChangeNotifier {
  PornHubPlaylistController(this._source, {required this.id});
  final PornHubSource _source;
  final String id;
  final _videos = <VideoItem>[];
  PornHubPlaylistDetails? _detail;
  bool _loading = false, _hasMore = true, _favourite = false, _disposed = false;
  int _page = 1, _request = 0;
  bool _lastLoadWasAppend = false;
  int _replacementGeneration = 0;
  String? _error;
  late final List<VideoItem> videos = UnmodifiableListView(_videos);
  PornHubPlaylistDetails? get detail => _detail;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get favourite => _favourite;
  int get nextPage => _page;
  bool get lastLoadWasAppend => _lastLoadWasAppend;
  int get replacementGeneration => _replacementGeneration;
  int get requestRevision => _request;
  String? get error => _error;

  void resetAccount() {
    if (_disposed) return;
    _request++;
    _change(() {
      _detail = null;
      _videos.clear();
      _favourite = false;
      _loading = false;
      _error = null;
      _page = 1;
      _hasMore = true;
    });
  }

  void toggleFavourite() => _change(() => _favourite = !_favourite);

  void _change(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  Future<void> load({bool reset = false, int? targetPage}) async {
    if (_disposed || _loading || (!reset && !_hasMore)) return;
    final request = ++_request;
    _change(() {
      _loading = true;
      _error = null;
    });
    try {
      if (reset) {
        final detail = await _source.fetchPlaylistDetails(
          id,
          forceRefresh: true,
        );
        if (_disposed || request != _request) return;
        _detail = detail;
        _favourite = detail.isFavourite;
      }
      final page = await _source.fetchPlaylistVideos(
        id,
        page: reset ? (targetPage ?? 1) : _page,
      );
      if (_disposed || request != _request) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        throw const PornHubRequestException();
      }
      _change(() {
        _lastLoadWasAppend = !reset;
        if (reset) _replacementGeneration++;
        if (reset) _videos.clear();
        final seen = _videos.map((v) => v.id).toSet();
        _videos.addAll(page.items.where((v) => seen.add(v.id)));
        _page = page.page + 1;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      if (!_disposed && request == _request) {
        _change(() => _error = '片单加载失败，点击重试');
      }
    } finally {
      if (!_disposed && request == _request) _change(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    super.dispose();
  }
}
