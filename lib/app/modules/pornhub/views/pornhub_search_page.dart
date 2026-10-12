import '../../../widgets/retained_page_sliver.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../pornhub_search_controller.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_video_grid.dart';
import '../widgets/pornhub_playlist_card.dart';
import 'pornhub_creator_page.dart';
import 'pornhub_browse_page.dart';

class PornHubSearchPage extends StatefulWidget {
  const PornHubSearchPage({
    super.key,
    this.initialKeyword = '',
    this.initialKind = 'videos',
    this.initialPath,
    this.title,
  });
  final String initialKeyword;
  final String initialKind;
  final String? initialPath, title;
  @override
  State<PornHubSearchPage> createState() => _PornHubSearchPageState();
}

class _PornHubSearchPageState extends State<PornHubSearchPage> {
  late final _input = TextEditingController(text: widget.initialKeyword);
  final _scroll = ScrollController();
  late final _controller = PornHubSearchController(
    SourceRegistry.byId('pornhub') as PornHubSource,
    initialKeyword: widget.initialKeyword,
    initialPath: widget.initialPath,
    initialKind: widget.initialKind,
  );
  List<Object> _resultSnapshot = const [];
  String? _resultKind;
  int? _resultPage;
  int? _resultReplacementGeneration;
  Widget? _cachedResults;
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onDataChanged);
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.userScrollDirection == ScrollDirection.idle) {
        return;
      }
      if (_scroll.hasClients &&
          _scroll.position.extentAfter < 500 &&
          !_controller.loading &&
          _controller.hasMore &&
          _controller.error == null) {
        _load(reset: false);
      }
    });
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onDataChanged);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    final willLoad =
        _input.text.trim().isNotEmpty ||
        widget.initialPath != null ||
        _controller.kind == 'playlists';
    final request = _controller.submit(_input.text);
    if (willLoad && _scroll.hasClients) _scroll.jumpTo(0);
    // The controller handles network errors and request invalidation.
    request.ignore();
  }

  void _selectKind(String kind) {
    if (kind == _controller.kind) return;
    _controller.selectKind(kind);
    _submit();
  }

  Future<void> _load({
    required bool reset,
    bool clear = false,
    int? targetPage,
  }) {
    final request = _controller.load(
      reset: reset,
      clear: clear,
      targetPage: targetPage,
    );
    if (clear && _scroll.hasClients) _scroll.jumpTo(0);
    return request;
  }

  Future<void> _showFilters() async {
    final draft = Map<String, String>.from(_controller.filters);
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
    final groups = _controller.groups
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
                      if (_controller.kind == 'videos' ||
                          _controller.kind == 'clips') ...[
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
    _controller.applyFilters(draft);
    _load(reset: true, clear: true);
  }

  @override
  Widget build(BuildContext context) {
    final visiblePlaylists = _controller.keyword.isEmpty
        ? _controller.playlists
        : _controller.playlists
              .where(
                (p) => p.title.toLowerCase().contains(
                  _controller.keyword.toLowerCase(),
                ),
              )
              .toList();
    final count =
        _controller.videos.length +
        _controller.creators.length +
        visiblePlaylists.length;
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
                            fontWeight: _controller.kind == entry.key
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (_controller.kind == 'creators')
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'members', label: Text('会员 / 用户')),
                ButtonSegment(value: 'pornstars', label: Text('明星')),
              ],
              selected: {_controller.creatorScope},
              onSelectionChanged: (value) {
                _controller.selectCreatorScope(value.first);
                _submit();
              },
            ),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    _controller.kind == 'playlists'
                        ? '官网片单 · 筛选已获取片单'
                        : _controller.total == null
                        ? '已加载 $count 条'
                        : '官网共 ${_controller.total} 条 · 已加载 $count 条',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _controller.started ? _showFilters : null,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('筛选'),
              ),
            ],
          ),
          if (_controller.suggestions.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: _controller.suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final suggestion = _controller.suggestions[index];
                  return ActionChip(
                    label: Text(suggestion.name),
                    onPressed: () {
                      _controller.selectSuggestion(suggestion);
                      _input.text = _controller.keyword;
                      _load(reset: true, clear: true);
                    },
                  );
                },
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: !_controller.started
                ? const Center(child: Text('输入关键词开始搜索'))
                : RefreshIndicator(
                    onRefresh: () => _load(reset: true),
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        if (_controller.loading && count == 0)
                          const SliverFillRemaining(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_controller.error != null && count == 0)
                          SliverFillRemaining(
                            child: PornHubErrorBlock(
                              message: _controller.error!,
                              onRetry: () => _load(reset: true),
                            ),
                          )
                        else ...[
                          _buildResults(visiblePlaylists),
                          if (_controller.kind != 'videos' &&
                              _controller.kind != 'clips')
                            SliverToBoxAdapter(child: _footer),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _onDataChanged() {
    setState(() {
      if (_controller.videos.isEmpty &&
          _controller.creators.isEmpty &&
          _controller.playlists.isEmpty) {
        _cachedResults = null;
        _resultSnapshot = const [];
      }
    });
  }

  int get _resultCount =>
      _controller.videos.length +
      _controller.creators.length +
      (_controller.keyword.isEmpty
          ? _controller.playlists.length
          : _controller.playlists
                .where(
                  (p) => p.title.toLowerCase().contains(
                    _controller.keyword.toLowerCase(),
                  ),
                )
                .length);

  late final Widget _footer = AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => PornHubListFooter(
      currentPage: (_controller.nextPage - 1).clamp(1, 2147483647),
      onJump: (page) => _load(reset: true, targetPage: page),
      isLoadingMore: _controller.loading,
      hasMore: _controller.hasMore,
      errorText: _controller.error,
      isEmpty: _resultCount == 0,
      emptyHint: _controller.kind == 'playlists'
          ? '已获取片单没有匹配项，可继续加载下一页'
          : '没有找到匹配结果',
      onLoadMore: () => _load(reset: false),
    ),
  );

  Widget _buildResults(List<PornHubPlaylist> visiblePlaylists) {
    final currentItems = _controller.kind == 'creators'
        ? _controller.creators
        : _controller.kind == 'playlists'
        ? visiblePlaylists
        : _controller.videos;
    if (_cachedResults != null &&
        _resultKind == _controller.kind &&
        _resultPage == _controller.nextPage &&
        _resultReplacementGeneration == _controller.replacementGeneration &&
        listEquals(_resultSnapshot, currentItems)) {
      return _cachedResults!;
    }
    _resultKind = _controller.kind;
    _resultPage = _controller.nextPage;
    _resultReplacementGeneration = _controller.replacementGeneration;
    _resultSnapshot = List<Object>.of(currentItems);
    if (_controller.kind == 'videos' || _controller.kind == 'clips') {
      return _cachedResults = RetainedPageSliver(
        items: _resultSnapshot.cast<VideoItem>(),
        page: (_controller.nextPage - 1).clamp(1, 2147483647),
        preserveEmptyAppend: _controller.lastLoadWasAppend,
        replacementGeneration: _controller.replacementGeneration,
        footer: _footer,
        gridBuilder: (pageItems) => SliverPornHubGrid(
          videos: pageItems,
          onDownload: enqueuePornHubDownload,
        ),
      );
    }
    if (_controller.kind == 'creators') {
      final creators = _resultSnapshot.cast<PornHubSubscription>();
      return _cachedResults = SliverList.builder(
        itemCount: _resultSnapshot.length,
        itemBuilder: (_, index) {
          final creator = creators[index];
          return ListTile(
            leading: _cover(creator.avatarUrl),
            title: Text(creator.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Get.to<void>(
              () => PornHubCreatorPage(name: creator.name, path: creator.path),
            ),
          );
        },
      );
    }
    final playlists = _resultSnapshot.cast<PornHubPlaylist>();
    return _cachedResults = SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.15,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _resultSnapshot.length,
        itemBuilder: (_, index) {
          final playlist = playlists[index];
          return PornHubPlaylistCard(
            playlist: playlist,
            onTap: () => Get.to<void>(
              () =>
                  PornHubBrowsePage(title: playlist.title, path: playlist.url),
            ),
          );
        },
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
