import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../../../widgets/app_toast.dart';
import '../pornhub_controller.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_video_grid.dart';

class PornHubCreatorPage extends StatefulWidget {
  const PornHubCreatorPage({super.key, required this.name, required this.path});
  final String name;
  final String path;
  @override
  State<PornHubCreatorPage> createState() => _PornHubCreatorPageState();
}

class _PornHubCreatorPageState extends State<PornHubCreatorPage> {
  final _scroll = ScrollController();
  final _items = <VideoItem>[];
  PornHubCreatorProfile? _profile;
  bool _clips = false, _loading = false, _hasMore = true, _subBusy = false;
  String? _error, _profileError;
  int _page = 1, _request = 0;
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
    _loadProfile();
    _load(reset: true);
  }

  @override
  void dispose() {
    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final result = await _source.fetchCreatorProfile(widget.path);
      if (mounted) {
        setState(() {
          _profile = result;
          _profileError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _profileError = '主页信息加载失败，点击重试');
    }
  }

  Future<void> _subscribe() async {
    final profile = _profile;
    if (profile == null || _subBusy) return;
    setState(() => _subBusy = true);
    final result = await _source.setCreatorSubscription(
      profile.isSubscribed ? profile.unsubscribeUrl : profile.subscribeUrl,
    );
    if (!mounted) return;
    AppToast.show(result.message);
    if (result.ok) {
      await _loadProfile();
      if (Get.isRegistered<PornHubController>()) {
        await PornHubController.to.loadSubscriptions();
      }
    }
    if (mounted) setState(() => _subBusy = false);
  }

  Future<void> _load({required bool reset, int? targetPage}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final request = ++_request;
    final page = reset ? (targetPage ?? 1) : _page;
    final clips = _clips;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = clips
          ? await _source.fetchCreatorClips(widget.path, page: page)
          : await _source.fetchCreatorVideos(widget.path, page: page);
      if (!mounted || request != _request) return;
      if (result.summary != null && result.items.isEmpty) {
        throw const PornHubRequestException();
      }
      setState(() {
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
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
          _error = PornHubSource.requestFailureMessage;
        });
      }
    }
  }

  void _select(bool clips) {
    if (_clips == clips) return;
    setState(() {
      _clips = clips;
      _items.clear();
      _hasMore = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          profile?.name.isNotEmpty == true ? profile!.name : widget.name,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: profile?.avatarUrl != null
                        ? CachedNetworkImage(
                            imageUrl: profile!.avatarUrl!,
                            fit: BoxFit.cover,
                            httpHeaders: const {
                              'Referer': 'https://cn.pornhub.com/',
                            },
                            errorWidget: (_, _, _) =>
                                const Icon(Icons.person, size: 40),
                          )
                        : const Icon(Icons.person, size: 40),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        profile?.videoCount == null
                            ? '创作者主页'
                            : '共 ${profile!.videoCount} 个视频',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: profile == null || _subBusy ? null : _subscribe,
                  child: Text(
                    _subBusy
                        ? '处理中'
                        : profile?.isSubscribed == true
                        ? '已订阅'
                        : '订阅',
                  ),
                ),
              ],
            ),
          ),
          if (_profileError != null)
            TextButton(onPressed: _loadProfile, child: Text(_profileError!)),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _select(false),
                  child: Text(
                    '视频',
                    style: TextStyle(
                      fontWeight: !_clips ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _select(true),
                  child: Text(
                    '切片',
                    style: TextStyle(
                      fontWeight: _clips ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([_loadProfile(), _load(reset: true)]);
              },
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  if (_loading && _items.isEmpty)
                    const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null && _items.isEmpty)
                    SliverFillRemaining(
                      child: PornHubErrorBlock(
                        message: _error!,
                        onRetry: () => _load(reset: true),
                      ),
                    )
                  else ...[
                    SliverPornHubGrid(
                      videos: _items,
                      onDownload: enqueuePornHubDownload,
                    ),
                    SliverToBoxAdapter(
                      child: PornHubListFooter(
                        currentPage: (_page - 1).clamp(1, 2147483647),
                        onJump: (page) => _load(reset: true, targetPage: page),
                        isLoadingMore: _loading,
                        hasMore: _hasMore,
                        errorText: _error,
                        isEmpty: _items.isEmpty,
                        emptyHint: _clips ? '暂无切片' : '暂无视频',
                        onLoadMore: () => _load(reset: false),
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
}
