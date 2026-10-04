/// Hanime1 官方用户播放清单详情页。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../widgets/pull_to_next_page.dart';

import '../../../data/models/hanime1_models.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/hanime1_source.dart';
import '../../../data/sources/video_source.dart';
import '../../../routes/app_navigator.dart';
import '../widgets/hanime1_pagination.dart';

class Hanime1PlaylistView extends StatefulWidget {
  const Hanime1PlaylistView({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<Hanime1PlaylistView> createState() => _Hanime1PlaylistViewState();
}

class _Hanime1PlaylistViewState extends State<Hanime1PlaylistView> {
  static const List<(String, String)> _sorts = <(String, String)>[
    ('latest', '最新'),
    ('popular', '熱門'),
    ('oldest', '最早'),
  ];

  Hanime1PlaylistPage? _playlist;
  bool _loading = true;
  String? _error;
  String _sort = 'latest';
  int _page = 1, _request = 0;

  Hanime1Source? get _source {
    final source = SourceRegistry.byId('hanime1');
    return source is Hanime1Source ? source : null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load({String? sort, int? page, bool append = false}) async {
    if (!mounted) return;
    final request = ++_request;
    final source = _source;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = 'Hanime1 目前不可用';
      });
      return;
    }
    final targetSort = sort ?? _sort;
    final targetPage =
        page ?? (sort != null ? 1 : (_playlist == null ? 1 : _page));
    setState(() {
      _loading = true;
      _error = null;
    });
    Hanime1PlaylistPage? result;
    try {
      result = await source.fetchPlaylist(
        widget.playlistId,
        page: targetPage,
        sort: targetSort,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted || request != _request) return;
    setState(() {
      _loading = false;
      if (result == null) {
        _error = '播放清單載入失敗，請下拉重試';
      } else {
        _playlist = append && _playlist != null
            ? Hanime1PlaylistPage(
                id: result.id,
                title: result.title,
                creator: result.creator,
                creatorPath: result.creatorPath,
                coverUrl: result.coverUrl,
                videoCount: result.videoCount,
                viewsText: result.viewsText,
                items: [..._playlist!.items, ...result.items],
                page: result.page,
                hasMore: result.hasMore,
                sort: result.sort,
                totalPages: result.totalPages,
              )
            : result;
        _page = result.page;
        _sort = result.sort;
      }
    });
  }

  void _play(VideoItem item) {
    final url = Uri.parse(Hanime1Source.baseUrl).replace(
      path: '/watch',
      queryParameters: <String, String>{
        'v': item.id,
        'list': widget.playlistId,
        'sort': _sort,
      },
    );
    AppNavigator.toPlayer(item.copyWith(detailUrl: url.toString()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = _playlist;
    return Scaffold(
      appBar: AppBar(title: Text(playlist?.title ?? '播放清單')),
      body: RefreshIndicator(
        color: theme.colorScheme.primary,
        onRefresh: () => _load(),
        child: PullToNextPage(
          hasNext: (_playlist?.totalPages ?? 1) > _page,
          isLoading: _loading,
          onNext: () => _load(page: _page + 1, append: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: <Widget>[
              if (_loading && playlist != null)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (playlist != null) ...<Widget>[
                SliverToBoxAdapter(child: _buildHeader(context, playlist)),
                SliverToBoxAdapter(child: _buildSortBar(context)),
                if (playlist.items.isEmpty && !_loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('這個播放清單目前沒有影片')),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    sliver: SliverList.separated(
                      itemCount: playlist.items.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: .5,
                        ),
                      ),
                      itemBuilder: (context, index) => _PlaylistVideoTile(
                        video: playlist.items[index],
                        onTap: () => _play(playlist.items[index]),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Hanime1Pagination(
                    currentPage: _page,
                    onNext: () => _load(page: _page + 1, append: true),
                    hasNext: playlist.hasMore,
                    error: _error,
                    totalPages: playlist.totalPages,
                    isLoading: _loading,
                    onPageChanged: (page) => _load(page: page),
                  ),
                ),
              ] else if (_loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.playlist_remove_rounded, size: 44),
                        const SizedBox(height: 12),
                        Text(_error ?? '播放清單不存在或無法查看'),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () => _load(),
                          child: const Text('重試'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Hanime1PlaylistPage playlist) {
    final theme = Theme.of(context);
    final cover = playlist.coverUrl;
    final count = playlist.videoCount.isEmpty
        ? '${playlist.items.length} 部影片'
        : '${playlist.videoCount} 部影片';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: 204,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (cover.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: cover,
                  fit: BoxFit.cover,
                  httpHeaders: const {'Referer': 'https://hanime1.me/'},
                  errorWidget: (_, _, _) =>
                      ColoredBox(color: context.cImagePlaceholder),
                )
              else
                ColoredBox(color: context.cImagePlaceholder),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0x22000000), Color(0xEE000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      playlist.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      <String>[
                        if (playlist.creator.isNotEmpty)
                          '由 ${playlist.creator} 建立',
                        count,
                        if (playlist.viewsText.isNotEmpty)
                          '觀看次數：${playlist.viewsText}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: playlist.items.isEmpty
                          ? null
                          : () => _play(playlist.items.first),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('全部播放'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSortBar(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        children: <Widget>[
          for (final (value, label) in _sorts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: _sort == value,
                onSelected: (selected) {
                  if (selected && _sort != value) _load(sort: value);
                },
                selectedColor: theme.colorScheme.primaryContainer,
              ),
            ),
        ],
      ),
    );
  }
}

class _PlaylistVideoTile extends StatelessWidget {
  const _PlaylistVideoTile({required this.video, required this.onTap});

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final views = video.viewsStr ?? '';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: 104,
          child: Row(
            children: <Widget>[
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if ((video.thumbnailUrl ?? '').isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: video.thumbnailUrl!,
                          fit: BoxFit.cover,
                          httpHeaders: const {'Referer': 'https://hanime1.me/'},
                          errorWidget: (_, _, _) =>
                              ColoredBox(color: context.cImagePlaceholder),
                        )
                      else
                        ColoredBox(color: context.cImagePlaceholder),
                      if ((video.durationStr ?? '').isNotEmpty)
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                video.durationStr!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      video.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      <String>[
                        if (views.isNotEmpty) views,
                        if ((video.publishedAt ?? '').isNotEmpty)
                          video.publishedAt!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
