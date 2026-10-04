/// PornHub「更多」子页面：分类 / 片单 / 明星。
///
/// 主导航按需求固定为四个 Tab（推荐 / 最热 / 订阅 / 收藏），
/// 这三类作为**子页面**从 AppBar 溢出菜单进入，自包含、不占用主导航。
///
/// 刻意直接依赖 [PornHubSource] 而不是往控制器里堆状态：这些页面属于低频入口，
/// 单独持有自己的加载态更清晰，也不会让主 Tab 的状态机变复杂。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../pornhub_controller.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_video_grid.dart';

class PornHubMorePage extends StatefulWidget {
  const PornHubMorePage({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<PornHubMorePage> createState() => _PornHubMorePageState();
}

class _PornHubMorePageState extends State<PornHubMorePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialIndex,
  );

  PornHubSource get _source => PornHubController.to.source;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('更多'),
        bottom: TabBar(
          controller: _tab,
          tabs: const <Widget>[
            Tab(icon: Icon(Icons.category_outlined), text: '分类'),
            Tab(icon: Icon(Icons.queue_music_rounded), text: '片单'),
            Tab(icon: Icon(Icons.star_outline_rounded), text: '明星'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: <Widget>[
          const _CategoriesPane(),
          _PlaylistsPane(source: _source),
          _StarsPane(source: _source),
        ],
      ),
    );
  }
}

/// 分类面板（静态 96 个官方分类，点进去由详情页列表呈现）。
class _CategoriesPane extends StatelessWidget {
  const _CategoriesPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = PornHubCategories.categoryList;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 2.35,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => _CategoryVideosPage(category: category),
              ),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  category.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 某分类下的视频。
class _CategoryVideosPage extends StatefulWidget {
  const _CategoryVideosPage({required this.category});

  final dynamic category;

  @override
  State<_CategoryVideosPage> createState() => _CategoryVideosPageState();
}

class _CategoryVideosPageState extends State<_CategoryVideosPage> {
  final List<VideoItem> _items = <VideoItem>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await PornHubController.to.source.fetchPathPage(
        widget.category.path as String,
        1,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name as String)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _items.isEmpty
          ? PornHubErrorBlock(message: _error!, onRetry: _load)
          : CustomScrollView(
              slivers: <Widget>[
                SliverPornHubGrid(
                  videos: _items,
                  onDownload: enqueuePornHubDownload,
                ),
                SliverToBoxAdapter(
                  child: PornHubListFooter(
                    isLoadingMore: false,
                    hasMore: false,
                    isEmpty: _items.isEmpty,
                    emptyHint: '该分类暂无内容',
                  ),
                ),
              ],
            ),
    );
  }
}

/// 片单面板。
class _PlaylistsPane extends StatefulWidget {
  const _PlaylistsPane({required this.source});

  final PornHubSource source;

  @override
  State<_PlaylistsPane> createState() => _PlaylistsPaneState();
}

class _PlaylistsPaneState extends State<_PlaylistsPane> {
  final List<PornHubPlaylist> _items = <PornHubPlaylist>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.source.fetchPlaylists();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取片单失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return SingleChildScrollView(
        child: PornHubErrorBlock(message: _error!, onRetry: _load),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final playlist = _items[index];
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => _CollectionPage(
                  title: playlist.title,
                  fetcher: (page) => widget.source.fetchPlaylistVideos(
                    playlist.id,
                    page: page,
                  ),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.queue_music_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      playlist.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${playlist.videoCount} 个',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 明星面板。
class _StarsPane extends StatefulWidget {
  const _StarsPane({required this.source});

  final PornHubSource source;

  @override
  State<_StarsPane> createState() => _StarsPaneState();
}

class _StarsPaneState extends State<_StarsPane> {
  final List<PornHubStar> _items = <PornHubStar>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.source.fetchStars();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取明星失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return SingleChildScrollView(
        child: PornHubErrorBlock(message: _error!, onRetry: _load),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final star = _items[index];
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => _CollectionPage(
                  title: star.name,
                  fetcher: (page) =>
                      widget.source.fetchStarVideos(star.name, page: page),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: star.avatarUrl == null
                      ? Icon(
                          Icons.person_outline_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : CachedNetworkImage(
                          imageUrl: star.avatarUrl!,
                          httpHeaders: const <String, String>{
                            'Referer': 'https://cn.pornhub.com/',
                          },
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Icon(
                            Icons.person_outline_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Text(
                    star.name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 片单 / 明星 共用的集合详情。
class _CollectionPage extends StatefulWidget {
  const _CollectionPage({required this.title, required this.fetcher});

  final String title;
  final Future Function(int page) fetcher;

  @override
  State<_CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<_CollectionPage> {
  final List<VideoItem> _items = <VideoItem>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.fetcher(1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items as List<VideoItem>);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '获取失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _items.isEmpty
          ? PornHubErrorBlock(message: _error!, onRetry: _load)
          : CustomScrollView(
              slivers: <Widget>[
                SliverPornHubGrid(
                  videos: _items,
                  onDownload: enqueuePornHubDownload,
                ),
                SliverToBoxAdapter(
                  child: PornHubListFooter(
                    isLoadingMore: false,
                    hasMore: false,
                    isEmpty: _items.isEmpty,
                    emptyHint: '暂无视频',
                  ),
                ),
              ],
            ),
    );
  }
}
