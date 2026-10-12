import '../../../widgets/retained_page_sliver.dart';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../services/pornhub_auth_service.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../../../widgets/app_toast.dart';
import '../pornhub_controller.dart';
import '../pornhub_playlist_controller.dart';
import '../widgets/pornhub_video_grid.dart';

/// 官网片单详情、真实收藏状态与 viewChunked 分页。
class PornHubPlaylistPage extends StatefulWidget {
  const PornHubPlaylistPage({super.key, required this.id, this.title = ''});
  final String id, title;
  @override
  State<PornHubPlaylistPage> createState() => _PornHubPlaylistPageState();
}

class _PornHubPlaylistPageState extends State<PornHubPlaylistPage> {
  late final PornHubPlaylistController _controller;
  bool _busy = false;
  List<VideoItem> get _videos => _controller.videos;
  PornHubPlaylistDetails? get _detail => _controller.detail;
  bool get _loading => _controller.loading;
  bool get _favourite => _controller.favourite;
  int get _page => _controller.nextPage;
  int get _request => _controller.requestRevision;
  String? get _error => _controller.error;
  void _onChanged() {
    if (mounted) setState(() {});
  }
  Worker? _accountWorker;
  PornHubSource get _source => SourceRegistry.byId('pornhub') as PornHubSource;

  @override
  void initState() {
    super.initState();
    _controller = PornHubPlaylistController(_source, id: widget.id)
      ..addListener(_onChanged);
    if (Get.isRegistered<PornHubAuthService>()) {
      final auth = PornHubAuthService.to;
      _accountWorker = everAll(
        [auth.sessionRevision, auth.username, auth.isLoggedIn],
        (_) {
          if (!mounted) return;
          _busy = false;
          _controller.resetAccount();
          if (auth.isLoggedIn.value) _load(reset: true);
        },
      );
    }
    _load(reset: true);
  }

  @override
  void dispose() {
    _accountWorker?.dispose();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false, int? targetPage}) =>
      _controller.load(reset: reset, targetPage: targetPage);

  Future<void> _toggleFavourite() async {
    if (_busy || _detail == null) return;
    final request = _request;
    setState(() => _busy = true);
    try {
      final result = await _source.setPlaylistFavourite(
        widget.id,
        remove: _favourite,
      );
      if (!mounted || request != _request) return;
      if (result.ok) {
        _controller.toggleFavourite();
        if (Get.isRegistered<PornHubController>()) {
          await PornHubController.to.loadMyPlaylists();
        }
      }
      AppToast.show(result.message);
    } catch (_) {
      if (mounted && request == _request) AppToast.show('收藏失败，请重试');
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _detail?.playlist.title.isNotEmpty == true
            ? _detail!.playlist.title
            : widget.title,
      ),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_detail?.playlist.videoCount ?? 0} 个视频 · 已加载 ${_videos.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy || _detail == null ? null : _toggleFavourite,
                icon: Icon(
                  _favourite ? Icons.favorite : Icons.favorite_border,
                  size: 18,
                ),
                label: Text(
                  _busy
                      ? '保存中…'
                      : _favourite
                      ? '已收藏'
                      : '收藏片单',
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification &&
                    n.dragDetails != null &&
                    n.metrics.extentAfter < 600) {
                  _load();
                }
                return false;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  RetainedPageSliver(
                    items: List.of(_videos),
                    page: (_page - 1).clamp(1, 2147483647),
                    footer: PornHubListFooter(
                      currentPage: (_page - 1).clamp(1, 2147483647),
                      onJump: (page) => _load(reset: true, targetPage: page),
                      isLoadingMore: _loading,
                      hasMore: _hasMore,
                      isEmpty: !_loading && _error == null && _videos.isEmpty,
                      emptyHint: '片单中暂时没有可用视频',
                      errorText: _error,
                      onLoadMore: () => _load(reset: _videos.isEmpty),
                    ),
                    gridBuilder: (pageItems) =>
                        SliverPornHubGrid(videos: pageItems),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
