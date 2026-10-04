import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../services/pornhub_auth_service.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../../../widgets/app_toast.dart';
import '../pornhub_controller.dart';
import '../widgets/pornhub_video_grid.dart';

/// 官网片单详情、真实收藏状态与 viewChunked 分页。
class PornHubPlaylistPage extends StatefulWidget {
  const PornHubPlaylistPage({super.key, required this.id, this.title = ''});
  final String id, title;
  @override
  State<PornHubPlaylistPage> createState() => _PornHubPlaylistPageState();
}

class _PornHubPlaylistPageState extends State<PornHubPlaylistPage> {
  final _videos = <VideoItem>[];
  PornHubPlaylistDetails? _detail;
  bool _loading = false, _busy = false, _hasMore = true, _favourite = false;
  int _page = 1, _request = 0;
  String? _error;
  Worker? _accountWorker;
  PornHubSource get _source => SourceRegistry.byId('pornhub') as PornHubSource;

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<PornHubAuthService>()) {
      final auth = PornHubAuthService.to;
      _accountWorker = everAll(
        [auth.sessionRevision, auth.username, auth.isLoggedIn],
        (_) {
          if (!mounted) return;
          _request++;
          setState(() {
            _detail = null;
            _videos.clear();
            _favourite = false;
            _loading = false;
            _busy = false;
            _error = null;
            _page = 1;
            _hasMore = true;
          });
          if (auth.isLoggedIn.value) _load(reset: true);
        },
      );
    }
    _load(reset: true);
  }

  @override
  void dispose() {
    _request++;
    _accountWorker?.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!reset && !_hasMore)) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (reset) {
        final detail = await _source.fetchPlaylistDetails(
          widget.id,
          forceRefresh: true,
        );
        if (!mounted || request != _request) return;
        _detail = detail;
        _favourite = detail.isFavourite;
      }
      final page = await _source.fetchPlaylistVideos(
        widget.id,
        page: reset ? 1 : _page,
      );
      if (!mounted || request != _request) return;
      if (page.summary == PornHubSource.requestFailureMessage) {
        throw const PornHubRequestException();
      }
      setState(() {
        if (reset) _videos.clear();
        final seen = _videos.map((v) => v.id).toSet();
        _videos.addAll(page.items.where((v) => seen.add(v.id)));
        _page = page.page + 1;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '片单加载失败，点击重试');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

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
        setState(() => _favourite = !_favourite);
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
                  SliverPornHubGrid(videos: _videos),
                  SliverToBoxAdapter(
                    child: PornHubListFooter(
                      isLoadingMore: _loading,
                      hasMore: _hasMore,
                      isEmpty: !_loading && _error == null && _videos.isEmpty,
                      emptyHint: '片单中暂时没有可用视频',
                      errorText: _error,
                      onLoadMore: () => _load(reset: _videos.isEmpty),
                    ),
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
