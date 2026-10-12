import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/models/pornhub_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/pornhub_source.dart';

/// One search route owns its data and invalidates replies when it closes.
/// Input focus, scroll and navigation stay with the view.
class PornHubSearchController extends ChangeNotifier {
  PornHubSearchController(
    this._source, {
    this.initialKeyword = '',
    this.initialPath,
    String initialKind = 'videos',
  }) : _kind = initialKind;
  final PornHubSource _source;
  final String initialKeyword;
  final String? initialPath;
  final _videos = <VideoItem>[];
  final _creators = <PornHubSubscription>[];
  final _playlists = <PornHubPlaylist>[];
  final _filters = <String, String>{};
  List<PornHubFilterGroup> _groups = [];
  List<PornHubLinkItem> _suggestions = [];
  String _kind, _creatorScope = 'members', _keyword = '', _path = '';
  bool _loading = false, _hasMore = false, _started = false, _disposed = false;
  String? _error;
  int _nextPage = 1, _request = 0;
  int? _total;
  bool _lastLoadWasAppend = false;
  int _replacementGeneration = 0;
  late final List<VideoItem> videos = UnmodifiableListView(_videos);
  late final List<PornHubSubscription> creators = UnmodifiableListView(
    _creators,
  );
  late final List<PornHubPlaylist> playlists = UnmodifiableListView(_playlists);
  late final Map<String, String> filters = UnmodifiableMapView(_filters);
  List<PornHubFilterGroup> get groups => UnmodifiableListView(_groups);
  List<PornHubLinkItem> get suggestions => UnmodifiableListView(_suggestions);
  String get kind => _kind;
  String get creatorScope => _creatorScope;
  String get keyword => _keyword;
  String get path => _path;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get started => _started;
  String? get error => _error;
  int get nextPage => _nextPage;
  int? get total => _total;
  bool get lastLoadWasAppend => _lastLoadWasAppend;
  int get replacementGeneration => _replacementGeneration;

  Future<void> start() async {
    if (_disposed) return;
    if (initialPath != null || initialKeyword.isNotEmpty) {
      _keyword = initialKeyword;
      _path = initialPath ?? _makePath();
      _filters.addAll(Uri.tryParse(_path)?.queryParameters ?? {});
      _filters.remove('search');
      _filters.remove('page');
      await load(reset: true);
    }
  }

  Future<void> submit(String value) async {
    if (_disposed) return;
    _keyword = value.trim();
    if (_keyword.isEmpty && initialPath == null && _kind != 'playlists') return;
    _path = _makePath();
    await load(reset: true, clear: true);
  }

  void selectKind(String kind) {
    if (_disposed || kind == _kind) return;
    _change(() {
      _kind = kind;
      _filters.clear();
      _groups = [];
    });
  }

  void selectCreatorScope(String value) {
    if (_disposed) return;
    _creatorScope = value;
    _filters.clear();
  }

  void applyFilters(Map<String, String> draft) {
    if (_disposed) return;
    _filters
      ..clear()
      ..addAll(draft);
    final existing = Uri.tryParse(_path);
    _path = initialPath != null && _keyword.isEmpty && existing != null
        ? existing
              .replace(queryParameters: draft.isEmpty ? null : draft)
              .toString()
        : _makePath();
  }

  void selectSuggestion(PornHubLinkItem suggestion) {
    if (_disposed) return;
    _path = suggestion.path;
    _keyword = Uri.parse(_path).queryParameters['search'] ?? suggestion.name;
  }

  void _change(VoidCallback update) {
    update();
    notifyListeners();
  }

  String _makePath() {
    final parameters = Map<String, String>.from(_filters)..remove('page');
    String path;
    switch (_kind) {
      case 'clips':
        path = '/clips';
        parameters['search'] = _keyword;
      case 'creators':
        path = _creatorScope == 'members'
            ? '/user/search'
            : '/pornstars/search';
        parameters[_creatorScope == 'members' ? 'username' : 'search'] =
            _keyword;
        if (_creatorScope == 'members') parameters['gender'] = '0';
      case 'playlists':
        path = '/playlists';
        parameters.putIfAbsent('o', () => 'mr');
      default:
        path = '/video/search';
        parameters['search'] = _keyword;
    }
    parameters.removeWhere((_, value) => value.isEmpty);
    return Uri(
      path: path,
      queryParameters: parameters.isEmpty ? null : parameters,
    ).toString();
  }

  Future<void> load({
    required bool reset,
    bool clear = false,
    int? targetPage,
  }) async {
    if (_disposed) return;
    if (!reset && (_loading || !_hasMore)) return;
    final request = ++_request, page = reset ? (targetPage ?? 1) : _nextPage;
    final path = _path, kind = _kind;
    _change(() {
      _loading = true;
      _error = null;
      _started = true;
      if (clear) {
        _videos.clear();
        _creators.clear();
        _playlists.clear();
        _suggestions = [];
        _total = null;
      }
    });
    try {
      final result = await _source.fetchBrowse(path, page: page, kind: kind);
      if (_disposed || request != _request) return;
      _change(() {
        _lastLoadWasAppend = !reset;
        if (reset) _replacementGeneration++;
        if (reset) {
          _videos.clear();
          _creators.clear();
          _playlists.clear();
        }
        final ids = _videos.map((v) => v.id).toSet();
        _videos.addAll(result.videos.where((v) => ids.add(v.id)));
        final paths = _creators.map((c) => c.path).toSet();
        _creators.addAll(result.creators.where((c) => paths.add(c.path)));
        final playlistIds = _playlists.map((p) => p.id).toSet();
        _playlists.addAll(result.playlists.where((p) => playlistIds.add(p.id)));
        _groups = result.filters;
        _suggestions = result.suggestions;
        _total = result.total;
        _hasMore = result.hasMore;
        _nextPage = page + 1;
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
