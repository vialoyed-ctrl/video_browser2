/// PornHub 视频详情信息面板（播放器下方那一整块）。
///
/// 自上而下：标题 → 播放量/时间 → UP主行（订阅 / 作品）→ 动作行
/// （下载 / 最爱 / 添加 / 分享）→ 分类 → 标签 → 相关/推荐/评论/片单 四个 Tab。
///
/// 数据来源是 [PornHubSource.fetchDetailExtra]：四个 Tab、分类、标签、色情明星、
/// 写操作 token 全在**同一份详情页 HTML** 里，所以只抓一次；切 Tab 只是切本地数据，
/// 不会再发请求。
///
/// 本组件刻意独立于 `player_view.dart`：91 / Hanime1 的版式一行不改，
/// PornHub 的改动全部收敛在这里与 [PornHubCreatorPage]。
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../core/responsive_utils.dart';
import '../../../data/models/pornhub_models.dart';
import '../../../services/pornhub_auth_service.dart';
import '../widgets/pornhub_playlist_card.dart';
import '../../../data/models/video_item.dart';
import '../../../data/sources/pornhub_source.dart';
import '../../../data/sources/video_source.dart';
import '../../../routes/app_navigator.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/bili_video_card.dart';
import '../widgets/pornhub_actions.dart';
import 'pornhub_creator_page.dart';
import 'pornhub_browse_page.dart';
import '../pornhub_controller.dart';

class PornHubVideoInfoPanel extends StatefulWidget {
  const PornHubVideoInfoPanel({
    super.key,
    required this.video,
    required this.onDownload,
    required this.onPlayVideo,
  });

  final VideoItem video;

  /// 下载当前视频（沿用播放页原有行为）。
  final VoidCallback onDownload;

  /// 点相关/推荐卡片时原地换片。
  final void Function(VideoItem video) onPlayVideo;

  @override
  State<PornHubVideoInfoPanel> createState() => _PornHubVideoInfoPanelState();
}

class _PornHubVideoInfoPanelState extends State<PornHubVideoInfoPanel> {
  static const List<String> _tabLabels = <String>['相关', '推荐', '评论', '片单'];

  int _tab = 0;
  double _tabDrag = 0;
  bool _tabForward = true;
  bool _sortingPlaylists = false;
  String? _sortedPlaylistVideo;

  PornHubDetailExtra? _extra;
  bool _loading = true;
  String? _error;

  /// 最爱态（本地）：详情页没有直出「当前是否已最爱」的可靠标记，
  /// 先按未最爱渲染，操作成功后按返回值更新，供「再点一次取消」。
  bool _favActive = false;
  bool _favBusy = false;
  bool _addBusy = false;
  bool _subBusy = false;
  bool _subscribed = false;
  int _extraRequest = 0;
  Worker? _accountWorker;

  PornHubSource? get _source {
    final s = SourceRegistry.byId('pornhub');
    return s is PornHubSource ? s : null;
  }

  @override
  void initState() {
    super.initState();
    // 初始 _loading 已是 true，直接发请求，避免在 initState 里 setState。
    _fetchExtra();
    if (Get.isRegistered<PornHubAuthService>()) {
      final auth = PornHubAuthService.to;
      _accountWorker = everAll(
        [auth.sessionRevision, auth.username, auth.isLoggedIn],
        (_) {
          if (!mounted) return;
          _extraRequest++;
          setState(() {
            _extra = null;
            _favActive = false;
            _subscribed = false;
            _favBusy = false;
            _subBusy = false;
            _addBusy = false;
            _loading = false;
            _sortingPlaylists = false;
            _sortedPlaylistVideo = null;
            // Only an explicit retry opens this watch page with the new account.
            _error = '账号已切换，点击重新加载详情';
          });
        },
      );
    }
  }

  @override
  void dispose() {
    _extraRequest++;
    _accountWorker?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PornHubVideoInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 原地换片：复位 Tab 与最爱态，并重新拉取新片子的扩展内容。
    //
    // 这里**直接改字段而不 setState**：didUpdateWidget 处于构建阶段，
    // 同步 setState 会触发「setState during build」断言；而本帧本来就要用新值重建。
    if (oldWidget.video.id != widget.video.id) {
      _tab = 0;
      _favActive = false;
      _subscribed = false;
      _subBusy = false;
      _favBusy = false;
      _addBusy = false;
      _sortingPlaylists = false;
      _sortedPlaylistVideo = null;
      _extra = null;
      _loading = true;
      _error = null;
      _fetchExtra();
    }
  }

  Future<void> _loadExtra() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetchExtra();
  }

  /// 真正发请求并回填。完成时统一 setState（已带 mounted 保护）。
  Future<void> _fetchExtra() async {
    final request = ++_extraRequest;
    final videoId = widget.video.id;
    final source = _source;
    if (source == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '当前不是 PornHub 源';
      });
      return;
    }
    try {
      final extra = await source.fetchDetailExtra(videoId);
      if (!mounted || request != _extraRequest) return;
      setState(() {
        _extra = extra;
        _favActive = extra.isFavourite;
        _subscribed = extra.isSubscribed;
        _loading = false;
      });
      if (_tab == 3) unawaited(_sortPlaylists());
    } catch (e) {
      if (!mounted || request != _extraRequest) return;
      setState(() {
        _error = '详情加载失败';
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------ 动作：最爱 / 添加

  Future<void> _toggleFavourite() async {
    if (_favBusy) return;
    final request = _extraRequest;
    final currentVideoId = widget.video.id;
    final source = _source;
    final extra = _extra;
    if (source == null || extra == null) {
      AppToast.show('详情尚未加载完成，请稍候');
      return;
    }
    if (!source.isLoggedIn) {
      AppToast.show('请先登录 PornHub');
      return;
    }
    if (extra.videoId.isEmpty || extra.token.isEmpty) {
      AppToast.show('缺少操作参数，请重进详情页');
      return;
    }
    setState(() => _favBusy = true);
    try {
      final res = await source.setFavourite(
        videoId: extra.videoId,
        token: extra.token,
        favouriteUrl: extra.favouriteUrl,
        remove: _favActive,
      );
      if (!mounted ||
          widget.video.id != currentVideoId ||
          request != _extraRequest) {
        return;
      }
      if (res.ok) {
        setState(() => _favActive = res.active);
        if (Get.isRegistered<PornHubController>()) {
          PornHubController.to.loadFavorites();
        }
        AppToast.show(res.message);
      } else {
        AppToast.show(res.message);
      }
    } catch (e) {
      // 写操作必须把异常反馈到 UI，不能静默吞掉。
      if (mounted) AppToast.show('操作失败：$e');
    } finally {
      if (mounted &&
          widget.video.id == currentVideoId &&
          request == _extraRequest) {
        setState(() => _favBusy = false);
      }
    }
  }

  Future<void> _addToPlaylist() async {
    if (_addBusy) return;
    final request = _extraRequest;
    final currentVideoId = widget.video.id;
    final source = _source;
    final extra = _extra;
    if (source == null || extra == null) {
      AppToast.show('详情尚未加载完成，请稍候');
      return;
    }
    if (!source.isLoggedIn) {
      AppToast.show('请先登录 PornHub');
      return;
    }
    if (extra.videoId.isEmpty || extra.token.isEmpty) {
      AppToast.show('缺少片单参数，请重进详情页');
      return;
    }

    setState(() => _addBusy = true);
    List<PornHubPlaylist> playlists;
    try {
      // 只能添加到自己创建的片单，收藏别人的片单不代表有编辑权限。
      playlists = await source.fetchPublicPlaylists();
    } catch (e) {
      if (mounted && request == _extraRequest) {
        setState(() => _addBusy = false);
        AppToast.show('片单加载失败：$e');
      }
      return;
    }
    if (!mounted || request != _extraRequest) return;
    setState(() => _addBusy = false);

    if (playlists.isEmpty) {
      AppToast.show('你还没有可用的片单');
      return;
    }

    final selected = await showModalBottomSheet<PornHubPlaylist>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => _PlaylistPickerSheet(playlists: playlists),
    );
    if (selected == null ||
        widget.video.id != currentVideoId ||
        request != _extraRequest) {
      return;
    }
    if (!mounted || request != _extraRequest) return;

    setState(() => _addBusy = true);
    try {
      final res = await source.addVideoToPlaylist(
        pid: selected.id,
        vid: extra.videoId,
        token: extra.token,
      );
      if (!mounted || request != _extraRequest) return;
      AppToast.show(res.ok ? '已添加到「${selected.title}」' : res.message);
    } catch (e) {
      if (mounted) AppToast.show('添加失败：$e');
    } finally {
      if (mounted &&
          widget.video.id == currentVideoId &&
          request == _extraRequest) {
        setState(() => _addBusy = false);
      }
    }
  }

  void _share() {
    final url = widget.video.detailUrl ?? widget.video.id;
    Clipboard.setData(ClipboardData(text: url));
    AppToast.show('已复制链接: $url');
  }

  void _openCreator() {
    final extra = _extra;
    final path = (extra?.creatorPath.isNotEmpty ?? false)
        ? extra!.creatorPath
        : (extra != null && extra.pornstars.isNotEmpty
              ? extra.pornstars.first.path
              : '');
    if (path.isNotEmpty) {
      Get.to<void>(
        () => PornHubCreatorPage(name: widget.video.author, path: path),
      );
      return;
    }
    // 兜底：详情未解析出 UP主路径时，按作者名走原有搜索页。
    AppNavigator.toAuthor(widget.video.author);
  }

  Future<void> _toggleSubscription() async {
    final request = _extraRequest;
    final source = _source;
    final extra = _extra;
    if (_subBusy || source == null || extra == null) return;
    final id = widget.video.id;
    final action = _subscribed ? extra.unsubscribeUrl : extra.subscribeUrl;
    setState(() => _subBusy = true);
    final result = await source.setCreatorSubscription(action);
    if (!mounted || widget.video.id != id || request != _extraRequest) return;
    setState(() {
      _subBusy = false;
      if (result.ok) _subscribed = !_subscribed;
    });
    AppToast.show(result.message);
    if (result.ok && Get.isRegistered<PornHubController>()) {
      await PornHubController.to.loadSubscriptions();
    }
  }

  void _openLink(PornHubLinkItem item) {
    Get.to<void>(() => PornHubBrowsePage(title: item.name, path: item.path));
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.video;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            v.title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          _buildMetaRow(theme, v),
          const SizedBox(height: 12),
          _buildUploaderRow(theme, v),
          const SizedBox(height: 12),
          _buildActionRow(theme),
          if (_extra != null && _extra!.categories.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _buildLinkRow(theme, '分类', _extra!.categories),
          ],
          if (_extra != null && _extra!.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _buildLinkRow(theme, '标签', _extra!.tags),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1, thickness: 0.5),
          _buildTabBar(theme),
          const Divider(height: 1, thickness: 0.5),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _tabDrag = 0,
            onHorizontalDragUpdate: (d) => _tabDrag += d.primaryDelta ?? 0,
            onHorizontalDragEnd: (d) {
              final velocity = d.primaryVelocity ?? 0;
              if (_tabDrag.abs() < 40 && velocity.abs() < 250) return;
              final next =
                  (_tab + ((_tabDrag != 0 ? _tabDrag : velocity) < 0 ? 1 : -1))
                      .clamp(0, 3);
              if (next != _tab) _selectTab(next);
            },
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (final child in previous)
                      Positioned.fill(child: IgnorePointer(child: child)),
                    ?current,
                  ],
                ),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey(_tab);
                  final direction =
                      (_tabForward ? 1.0 : -1.0) * (incoming ? 1 : -1);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(direction * 0.16, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey(_tab),
                  child: _buildTabContent(theme),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(ThemeData theme, VideoItem v) {
    final color = theme.colorScheme.outline;
    return Row(
      children: <Widget>[
        Icon(Icons.play_circle_outline, size: 14, color: color),
        const SizedBox(width: 4),
        Text(v.viewsStr ?? '—', style: TextStyle(fontSize: 12, color: color)),
        const SizedBox(width: 14),
        Icon(Icons.access_time, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          v.publishedAt != null && v.publishedAt!.isNotEmpty
              ? '发布于 ${v.publishedAt}'
              : '发布时间未知',
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }

  Widget _buildUploaderRow(ThemeData theme, VideoItem v) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _openCreator,
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      v.author.isNotEmpty ? v.author[0].toUpperCase() : 'U',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          v.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '作品UP主',
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _subBusy || _extra == null
                    ? null
                    : _toggleSubscription,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: Icon(_subscribed ? Icons.check : Icons.add, size: 15),
                label: Text(
                  _subBusy
                      ? '处理中'
                      : _subscribed
                      ? '已订阅'
                      : '订阅',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.person_search_outlined, size: 15),
                label: const Text('作品', style: TextStyle(fontSize: 12)),
                onPressed: _openCreator,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: <Widget>[
        _actionButton(
          theme,
          icon: Icons.download_for_offline_outlined,
          label: '下载',
          onTap: widget.onDownload,
        ),
        _actionButton(
          theme,
          icon: _favActive ? Icons.star_rounded : Icons.star_outline_rounded,
          label: _favActive ? '已最爱' : '最爱',
          iconColor: _favActive ? theme.colorScheme.primary : null,
          busy: _favBusy,
          onTap: _toggleFavourite,
        ),
        _actionButton(
          theme,
          icon: Icons.playlist_add_outlined,
          label: '添加',
          busy: _addBusy,
          onTap: _addToPlaylist,
        ),
        _actionButton(
          theme,
          icon: Icons.copy_outlined,
          label: '分享',
          onTap: _share,
        ),
      ],
    );
  }

  Widget _actionButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    bool busy = false,
  }) {
    final color = iconColor ?? theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    ),
                  )
                : Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类 / 标签胶囊行。
  ///
  /// TODO(跳转)：官网分类是 `/categories/<slug>`、标签是搜索，但跳转需要额外页面 /
  /// 请求；按需求「跳转成本高时先只展示」，这里暂时只渲染、点击不响应。
  Widget _buildLinkRow(
    ThemeData theme,
    String title,
    List<PornHubLinkItem> items,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.outline,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: items
                .map(
                  (item) => InkWell(
                    onTap: () => _openLink(item),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        item.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    );
  }

  void _selectTab(int index) {
    setState(() {
      _tabForward = index > _tab;
      _tab = index;
    });
    if (index == 3) unawaited(_sortPlaylists());
  }

  Future<void> _sortPlaylists() async {
    final request = _extraRequest;
    final id = widget.video.id, extra = _extra, source = _source;
    if (extra == null ||
        source == null ||
        extra.playlists.isEmpty ||
        _sortingPlaylists ||
        _sortedPlaylistVideo == id) {
      return;
    }
    setState(() => _sortingPlaylists = true);
    try {
      final sorted = await source.sortPlaylistsByTime(extra.playlists);
      if (!mounted || widget.video.id != id || request != _extraRequest) return;
      setState(() {
        _extra = _extra!.withPlaylists(sorted);
        _sortedPlaylistVideo = id;
      });
    } finally {
      if (mounted && widget.video.id == id && request == _extraRequest) {
        setState(() => _sortingPlaylists = false);
      }
    }
  }

  Widget _buildTabBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _tabLabels.length; i++)
            Expanded(
              child: _tabButton(theme, index: i, label: _tabLabels[i]),
            ),
        ],
      ),
    );
  }

  Widget _tabButton(
    ThemeData theme, {
    required int index,
    required String label,
  }) {
    final selected = _tab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        if (_tab == index) return;
        _selectTab(index);
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              FilledButton.tonal(
                onPressed: _loadExtra,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final extra = _extra;
    if (extra == null) return const SizedBox.shrink();

    switch (_tab) {
      case 0:
        return _buildVideoGrid(extra.related, '暂无相关视频');
      case 1:
        return _buildVideoGrid(extra.recommended, '暂无推荐视频');
      case 2:
        return _buildComments(theme, extra.comments);
      case 3:
        return Column(
          children: [
            if (_sortingPlaylists)
              const Padding(padding: EdgeInsets.all(8), child: Text('按时间排序…')),
            _buildPlaylists(theme, extra.playlists),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _emptyHint(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 相关 / 推荐用的非滚动视频网格（外层已是 ListView，不能再嵌套滚动）。
  Widget _buildVideoGrid(List<VideoItem> videos, String emptyHint) {
    final theme = Theme.of(context);
    if (videos.isEmpty) return _emptyHint(theme, emptyHint);

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = ResponsiveLayout.isWideScreen(context);
    final availableWidth = isWide ? screenWidth - 73 : screenWidth;
    final columnCount = ResponsiveLayout.gridColumnCount(availableWidth);
    final columnWidth =
        (availableWidth - 12 - (columnCount - 1) * 6) / columnCount;
    final childAspectRatio = ResponsiveLayout.cardAspectRatio(columnWidth);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnCount,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: childAspectRatio,
      ),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final video = videos[index];
        return BiliVideoCardV(
          video: video,
          onTap: () => widget.onPlayVideo(video),
          onDownload: () => enqueuePornHubDownload(video),
        );
      },
    );
  }

  Widget _buildComments(ThemeData theme, List<PornHubComment> comments) {
    if (comments.isEmpty) return _emptyHint(theme, '暂无评论');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final c in comments) ...<Widget>[
          _commentTile(theme, c),
          const Divider(height: 1, thickness: 0.4),
        ],
      ],
    );
  }

  Widget _commentTile(ThemeData theme, PornHubComment c) {
    final hasAvatar = c.avatarUrl != null && c.avatarUrl!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            backgroundImage: hasAvatar
                ? CachedNetworkImageProvider(c.avatarUrl!)
                : null,
            child: hasAvatar
                ? null
                : Text(
                    c.user.isNotEmpty ? c.user[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.user,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  c.message,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${c.upvotes}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Icon(
                      Icons.thumb_down_outlined,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${c.downvotes}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylists(ThemeData theme, List<PornHubPlaylist> playlists) {
    if (playlists.isEmpty) return _emptyHint(theme, '暂无片单');
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.15,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: playlists.length,
      itemBuilder: (_, i) => PornHubPlaylistCard(
        playlist: playlists[i],
        onTap: () => _openLink(
          PornHubLinkItem(name: playlists[i].title, path: playlists[i].url),
        ),
      ),
    );
  }
}

/// 「我的片单」选择弹窗。选中后返回该片单。
class _PlaylistPickerSheet extends StatelessWidget {
  const _PlaylistPickerSheet({required this.playlists});

  final List<PornHubPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: <Widget>[
                const Text(
                  '添加到片单',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  '${playlists.length} 个',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final p = playlists[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.playlist_play_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  title: Text(
                    p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${p.videoCount} 个视频'),
                  onTap: () => Navigator.of(context).pop(p),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
