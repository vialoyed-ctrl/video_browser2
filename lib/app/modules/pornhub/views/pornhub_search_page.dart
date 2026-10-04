import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_video_grid.dart';
import '../widgets/pornhub_playlist_card.dart';
import 'pornhub_creator_page.dart';
import 'pornhub_browse_page.dart';

class PornHubSearchPage extends StatefulWidget {
  const PornHubSearchPage({
    super.key,
    this.initialKeyword = '',
    this.initialPath,
    this.title,
  });
  final String initialKeyword;
  final String? initialPath, title;
  @override
  State<PornHubSearchPage> createState() => _PornHubSearchPageState();
}

class _PornHubSearchPageState extends State<PornHubSearchPage> {
  late final _input = TextEditingController(text: widget.initialKeyword);
  final _scroll = ScrollController();
  final _videos = <VideoItem>[];
  final _creators = <PornHubSubscription>[];
  final _playlists = <PornHubPlaylist>[];
  final _filters = <String, String>{};
  List<PornHubFilterGroup> _groups = [];
  List<PornHubLinkItem> _suggestions = [];
  String _kind = 'videos', _creatorScope = 'members', _keyword = '', _path = '';
  bool _loading = false, _hasMore = false, _started = false;
  String? _error;
  int _page = 1, _request = 0;
  int? _total;
  PornHubSource get _source => SourceRegistry.byId('pornhub') as PornHubSource;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.userScrollDirection == ScrollDirection.idle) {
        return;
      }
      if (_scroll.hasClients &&
          _scroll.position.extentAfter < 500 &&
          !_loading &&
          _hasMore &&
          _error == null) {
        _load(reset: false);
      }
    });
    if (widget.initialPath != null || widget.initialKeyword.isNotEmpty) {
      _keyword = widget.initialKeyword;
      _path = widget.initialPath ?? _makePath();
      _filters.addAll(Uri.tryParse(_path)?.queryParameters ?? {});
      _filters.remove('search');
      _filters.remove('page');
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    _request++;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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

  void _submit() {
    FocusScope.of(context).unfocus();
    _keyword = _input.text.trim();
    if (_keyword.isEmpty &&
        widget.initialPath == null &&
        _kind != 'playlists') {
      return;
    }
    _path = _makePath();
    _load(reset: true, clear: true);
  }

  void _selectKind(String kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _filters.clear();
      _groups = [];
    });
    _submit();
  }

  Future<void> _load({required bool reset, bool clear = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final request = ++_request, page = reset ? 1 : _page;
    final path = _path, kind = _kind;
    setState(() {
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
    if (clear && _scroll.hasClients) _scroll.jumpTo(0);
    try {
      final result = await _source.fetchBrowse(path, page: page, kind: kind);
      if (!mounted || request != _request) return;
      setState(() {
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
        _page = page + 1;
        _loading = false;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
          _error = PornHubSource.requestFailureMessage;
        });
      }
    }
  }

  Future<void> _showFilters() async {
    final draft = Map<String, String>.from(_filters);
    RangeValues range = RangeValues(
      double.tryParse(draft['min_duration'] ?? '') ?? 0,
      double.tryParse(draft['max_duration'] ?? '') ?? 40,
    );
    final categories = PornHubCategories.categoryList
        .map(
          (c) => PornHubLinkItem(
            name: c.name,
            path: Uri.parse(c.path).queryParameters['c'] ?? '',
          ),
        )
        .where((c) => c.path.isNotEmpty)
        .toList();
    final groups = _groups
        .where(
          (g) => !['c', 'filter_category', 'exclude_category'].contains(g.key),
        )
        .toList();
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .82,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '官网筛选',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => update(() {
                          draft.clear();
                          range = const RangeValues(0, 40);
                        }),
                        child: const Text('重置'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final group in groups) ...[
                        Text(
                          group.title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final option in group.options)
                              ChoiceChip(
                                label: Text(option.name),
                                selected:
                                    (draft[group.key] ?? '') == option.path,
                                onSelected: (_) => update(
                                  () => draft[group.key] = option.path,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_kind == 'videos' || _kind == 'clips') ...[
                        Text(
                          '时长：${range.start.round()}–${range.end == 40 ? '40+' : range.end.round()} 分钟',
                        ),
                        RangeSlider(
                          min: 0,
                          max: 40,
                          divisions: 4,
                          values: range,
                          onChanged: (value) => update(() => range = value),
                        ),
                        const Text(
                          '包含分类',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            ChoiceChip(
                              label: const Text('全部'),
                              selected: (draft['c'] ?? '').isEmpty,
                              onSelected: (_) =>
                                  update(() => draft.remove('c')),
                            ),
                            for (final category in categories)
                              ChoiceChip(
                                label: Text(category.name),
                                selected: draft['c'] == category.path,
                                onSelected: (_) =>
                                    update(() => draft['c'] = category.path),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '排除分类（最多 10 个）',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final category in categories)
                              FilterChip(
                                label: Text(category.name),
                                selected: (draft['exclude_category'] ?? '')
                                    .split('-')
                                    .contains(category.path),
                                onSelected: (selected) => update(() {
                                  final ids = (draft['exclude_category'] ?? '')
                                      .split('-')
                                      .where((id) => id.isNotEmpty)
                                      .toSet();
                                  if (selected && ids.length < 10) {
                                    ids.add(category.path);
                                  } else if (!selected) {
                                    ids.remove(category.path);
                                  }
                                  draft['exclude_category'] = ids.join('-');
                                }),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('显示结果'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied != true || !mounted) return;
    if (range.start > 0) {
      draft['min_duration'] = range.start.round().toString();
    } else {
      draft.remove('min_duration');
    }
    if (range.end < 40) {
      draft['max_duration'] = range.end.round().toString();
    } else {
      draft.remove('max_duration');
    }
    _filters
      ..clear()
      ..addAll(draft);
    final existing = Uri.tryParse(_path);
    _path = widget.initialPath != null && _keyword.isEmpty && existing != null
        ? existing
              .replace(queryParameters: draft.isEmpty ? null : draft)
              .toString()
        : _makePath();
    _load(reset: true, clear: true);
  }

  @override
  Widget build(BuildContext context) {
    final visiblePlaylists = _keyword.isEmpty
        ? _playlists
        : _playlists
              .where(
                (p) => p.title.toLowerCase().contains(_keyword.toLowerCase()),
              )
              .toList();
    final count = _videos.length + _creators.length + visiblePlaylists.length;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: widget.title ?? '搜索 PornHub',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _submit,
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.initialPath == null)
            SizedBox(
              height: 46,
              child: Row(
                children: [
                  for (final entry in const {
                    'videos': '视频',
                    'clips': '切片',
                    'creators': '创作者',
                    'playlists': '片单',
                  }.entries)
                    Expanded(
                      child: TextButton(
                        onPressed: () => _selectKind(entry.key),
                        child: Text(
                          entry.value,
                          style: TextStyle(
                            fontWeight: _kind == entry.key
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (_kind == 'creators')
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'members', label: Text('会员 / 用户')),
                ButtonSegment(value: 'pornstars', label: Text('明星')),
              ],
              selected: {_creatorScope},
              onSelectionChanged: (value) {
                _creatorScope = value.first;
                _filters.clear();
                _submit();
              },
            ),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    _kind == 'playlists'
                        ? '官网片单 · 筛选已获取片单'
                        : _total == null
                        ? '已加载 $count 条'
                        : '官网共 $_total 条 · 已加载 $count 条',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _started ? _showFilters : null,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('筛选'),
              ),
            ],
          ),
          if (_suggestions.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return ActionChip(
                    label: Text(suggestion.name),
                    onPressed: () {
                      _path = suggestion.path;
                      _keyword =
                          Uri.parse(_path).queryParameters['search'] ??
                          suggestion.name;
                      _input.text = _keyword;
                      _load(reset: true, clear: true);
                    },
                  );
                },
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: !_started
                ? const Center(child: Text('输入关键词开始搜索'))
                : RefreshIndicator(
                    onRefresh: () => _load(reset: true),
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        if (_loading && count == 0)
                          const SliverFillRemaining(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_error != null && count == 0)
                          SliverFillRemaining(
                            child: PornHubErrorBlock(
                              message: _error!,
                              onRetry: () => _load(reset: true),
                            ),
                          )
                        else ...[
                          if (_kind == 'videos' || _kind == 'clips')
                            SliverPornHubGrid(
                              videos: _videos,
                              onDownload: enqueuePornHubDownload,
                            ),
                          if (_kind == 'creators')
                            SliverList.builder(
                              itemCount: _creators.length,
                              itemBuilder: (_, index) {
                                final creator = _creators[index];
                                return ListTile(
                                  leading: _cover(creator.avatarUrl),
                                  title: Text(creator.name),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Get.to<void>(
                                    () => PornHubCreatorPage(
                                      name: creator.name,
                                      path: creator.path,
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (_kind == 'playlists')
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              sliver: SliverGrid.builder(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      childAspectRatio: 1.15,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                    ),
                                itemCount: visiblePlaylists.length,
                                itemBuilder: (_, index) {
                                  final playlist = visiblePlaylists[index];
                                  return PornHubPlaylistCard(
                                    playlist: playlist,
                                    onTap: () => Get.to<void>(
                                      () => PornHubBrowsePage(
                                        title: playlist.title,
                                        path: playlist.url,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: PornHubListFooter(
                              isLoadingMore: _loading,
                              hasMore: _hasMore,
                              errorText: _error,
                              isEmpty: count == 0,
                              emptyHint: _kind == 'playlists'
                                  ? '已获取片单没有匹配项，可继续加载下一页'
                                  : '没有找到匹配结果',
                              onLoadMore: () => _load(reset: false),
                            ),
                          ),
                          if (count == 0 && _hasMore)
                            SliverToBoxAdapter(
                              child: TextButton(
                                onPressed: _loading
                                    ? null
                                    : () => _load(reset: false),
                                child: const Text('加载下一页'),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cover(String? url) => SizedBox(
    width: 56,
    height: 56,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url == null || url.isEmpty
          ? const Icon(Icons.person_outline)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              httpHeaders: const {'Referer': 'https://cn.pornhub.com/'},
              errorWidget: (_, _, _) =>
                  const Icon(Icons.image_not_supported_outlined),
            ),
    ),
  );
}
