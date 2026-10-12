import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/models/pornhub_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/pornhub_source.dart';

/// Owned by one creator route; the view owns scroll and subscription actions.
class PornHubCreatorController extends ChangeNotifier {
  PornHubCreatorController(this._source, {required this.path});
  final PornHubSource _source;
  final String path;
  final _items = <VideoItem>[];
  PornHubCreatorProfile? _profile;
  bool _clips = false, _loading = false, _hasMore = true, _disposed = false;
  String? _error, _profileError;
  int _page = 1, _request = 0;
  bool _lastLoadWasAppend = false;
  int _replacementGeneration = 0;
  late final List<VideoItem> items = UnmodifiableListView(_items);
  PornHubCreatorProfile? get profile => _profile;
  bool get clips => _clips;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  String? get error => _error;
  String? get profileError => _profileError;
  int get nextPage => _page;
  bool get lastLoadWasAppend => _lastLoadWasAppend;
  int get replacementGeneration => _replacementGeneration;

  void selectClips(bool value) {
    if (_disposed || _clips == value) return;
    _change(() {
      _clips = value;
      _items.clear();
      _hasMore = true;
    });
  }

  void _change(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  Future<void> loadProfile() async {
    if (_disposed) return;
    try {
      final result = await _source.fetchCreatorProfile(path);
      if (!_disposed) {
        _change(() {
          _profile = result;
          _profileError = null;
        });
      }
    } catch (_) {
      if (!_disposed) _change(() => _profileError = '主页信息加载失败，点击重试');
    }
  }

  Future<void> load({required bool reset, int? targetPage}) async {
    if (_disposed || (!reset && (_loading || !_hasMore))) return;
    final request = ++_request;
    final page = reset ? (targetPage ?? 1) : _page;
    final clips = _clips;
    _change(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = clips
          ? await _source.fetchCreatorClips(path, page: page)
          : await _source.fetchCreatorVideos(path, page: page);
      if (_disposed || request != _request) return;
      if (result.summary != null && result.items.isEmpty) {
        throw const PornHubRequestException();
      }
      _change(() {
        _lastLoadWasAppend = !reset;
        if (reset) _replacementGeneration++;
        if (reset) _items.clear();
        final seen = _items.map((v) => v.id).toSet();
        final newItems = result.items.where((v) => seen.add(v.id)).toList();
        _items.addAll(newItems);
        _hasMore = result.hasMore && newItems.isNotEmpty;
        if (clips &&
            result.totalItems > 0 &&
            _items.length >= result.totalItems) {
          _hasMore = false;
        }
        _page = page + 1;
        _loading = false;
      });
    } catch (_) {
      if (!_disposed && request == _request) {
        _change(() {
          _loading = false;
          _error = PornHubSource.requestFailureMessage;
        });
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    super.dispose();
  }
}
