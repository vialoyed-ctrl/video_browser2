/// PornHub「我的」Tab：**收藏 / 片单 / 历史** 三个板块。
///
/// 版面（用户最终确认）：
///   ┌ 第一行：三个板块 chip（收藏 · N / 片单 · N / 历史 · N），**固定不随内容滚动**。
///   ├ 第二行（随板块变化）：
///   │   收藏 → 「我的视频」「我的片单」两个 chip，各占整行 50%、文字居中；
///   │   片单 → 「展开」按钮 + 片单 chip（左封面小方块 + 名称·数量），
///   │          展开后变两列封面卡片，原位切换「展开 / 收起」；
///   │   历史 → 无第二行。
///   └ 内容区：视频网格 / 片单列表 / 选中片单的视频。
///
/// 账号（头像 / 用户名 / 刷新 / 退出）按用户要求**移到抽屉**，本页不再显示。
/// 板块切换按需加载：已有数据不重复请求，下拉刷新才重抓。
library;

import '../../../widgets/retained_page_sliver.dart';

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../../../services/pornhub_auth_service.dart';
import '../widgets/pornhub_playlist_card.dart';
import '../../../data/models/video_item.dart';
import '../pornhub_controller.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_login_form.dart';
import '../widgets/pornhub_video_grid.dart';
import 'pornhub_browse_page.dart';

/// 「我的」页里的三个板块。
enum PornHubMineSection { favorites, playlists, history }

class PornHubMineTab extends StatefulWidget {
  const PornHubMineTab({super.key});

  @override
  State<PornHubMineTab> createState() => _PornHubMineTabState();
}

class _PornHubMineTabState extends State<PornHubMineTab> {
  PornHubMineSection _section = PornHubMineSection.favorites;

  /// 「片单」板块的第二行是否展开成两列封面卡片。默认收起（一行横向滑动）。
  bool _playlistsExpanded = false;
  Worker? _accountWorker;

  PornHubController get _ctrl => PornHubController.to;

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<PornHubAuthService>()) {
      final auth = PornHubAuthService.to;
      _accountWorker = everAll(
        [auth.sessionRevision, auth.username, auth.isLoggedIn],
        (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _playlistsExpanded = false);
            _ensureLoaded(_section);
          });
        },
      );
    }
    // 首帧后再触发，避免在 build 期间改 Rx 状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureLoaded(_section);
    });
  }

  @override
  void dispose() {
    _accountWorker?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 加载

  /// 切到某板块时按需加载；已有数据就不重复请求。
  void _ensureLoaded(PornHubMineSection s) {
    if (!_ctrl.isLoggedIn) return;
    switch (s) {
      case PornHubMineSection.favorites:
        // 「收藏」板块两个 chip 的计数分别来自收藏视频与公开片单，
        // 所以进入该板块要同时确保两者都拉过。
        if (_ctrl.favorites.isEmpty) unawaited(_ctrl.loadFavorites());
        if (_ctrl.publicPlaylists.isEmpty) {
          unawaited(_ctrl.loadPublicPlaylists());
        }
      case PornHubMineSection.playlists:
        unawaited(_ensurePlaylistSelection());
      case PornHubMineSection.history:
        unawaited(_ctrl.loadHistory());
    }
  }

  /// 进入「片单」板块：先确保片单列表已加载，再默认选中第一个并加载其视频。
  Future<void> _ensurePlaylistSelection() async {
    if (_ctrl.myPlaylists.isEmpty) await _ctrl.loadMyPlaylists();
    if (!mounted || _ctrl.myPlaylists.isEmpty) return;
    if (!_ctrl.myPlaylists.any((p) => p.id == _ctrl.selectedPlaylistId.value)) {
      await _ctrl.loadPlaylistVideos(_ctrl.myPlaylists.first.id);
    }
  }

  void _switchTo(PornHubMineSection s) {
    if (_section == s) return;
    setState(() => _section = s);
    _ensureLoaded(s);
  }

  void _selectSub(PornHubMineSub sub) {
    if (_ctrl.selectedMineSub.value == sub) return;
    _ctrl.selectedMineSub.value = sub;
    if (sub == PornHubMineSub.playlists && _ctrl.publicPlaylists.isEmpty) {
      unawaited(_ctrl.loadPublicPlaylists());
    }
    if (sub == PornHubMineSub.videos && _ctrl.favorites.isEmpty) {
      unawaited(_ctrl.loadFavorites());
    }
  }

  void _selectPlaylist(String id) {
    if (_ctrl.selectedPlaylistId.value == id &&
        _ctrl.playlistVideos.isNotEmpty) {
      return;
    }
    unawaited(_ctrl.loadPlaylistVideos(id));
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!_ctrl.isLoggedIn) return const PornHubLoginForm();
      final theme = Theme.of(context);
      return Column(
        children: <Widget>[
          _sectionBar(theme),
          _secondaryBar(theme),
          Expanded(child: _body()),
        ],
      );
    });
  }

  /// 计数文案：只在已知且大于 0 时拼上「 · N」，避免未加载时显示 0。
  String _countLabel(String base, int? count) =>
      (count != null && count > 0) ? '$base · $count' : base;

  /// 第一行：三个板块 chip，**等宽各占 1/3、文字居中**，固定不随内容滚动。
  ///
  /// 复用收藏板块「我的视频 / 我的片单」的 [_subChip]，让两行排版风格一致；
  /// 原先按内容自适应宽度会让「历史 · 1858」明显更宽，视觉不均衡。
  Widget _sectionBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _subChip(
              theme,
              label: _countLabel('收藏', _ctrl.favorites.length),
              selected: _section == PornHubMineSection.favorites,
              onTap: () => _switchTo(PornHubMineSection.favorites),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _subChip(
              theme,
              label: _countLabel('片单', _ctrl.myPlaylists.length),
              selected: _section == PornHubMineSection.playlists,
              onTap: () => _switchTo(PornHubMineSection.playlists),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _subChip(
              theme,
              label: _countLabel('历史', _ctrl.historyTotal.value),
              selected: _section == PornHubMineSection.history,
              onTap: () => _switchTo(PornHubMineSection.history),
            ),
          ),
        ],
      ),
    );
  }

  /// 第二行：随当前板块变化（历史板块没有第二行）。
  Widget _secondaryBar(ThemeData theme) {
    switch (_section) {
      case PornHubMineSection.favorites:
        return _favoritesSubBar(theme);
      case PornHubMineSection.playlists:
        return _playlistsBar(theme);
      case PornHubMineSection.history:
        return const SizedBox.shrink();
    }
  }

  /// 收藏板块的第二行：两个 chip 各占整行 50%，文字居中。
  Widget _favoritesSubBar(ThemeData theme) {
    final sub = _ctrl.selectedMineSub.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _subChip(
              theme,
              label: _countLabel('我的视频', _ctrl.favorites.length),
              selected: sub == PornHubMineSub.videos,
              onTap: () => _selectSub(PornHubMineSub.videos),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _subChip(
              theme,
              label: _countLabel('我的片单', _ctrl.publicPlaylists.length),
              selected: sub == PornHubMineSub.playlists,
              onTap: () => _selectSub(PornHubMineSub.playlists),
            ),
          ),
        ],
      ),
    );
  }

  /// 片单板块的第二行：收起时一行 chip，展开时两列封面卡片。
  Widget _playlistsBar(ThemeData theme) {
    final playlists = _ctrl.myPlaylists;
    return Column(
      children: [
        SizedBox(
          height: 50,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: _expandChip(theme),
              ),
              Expanded(
                child: _playlistsExpanded
                    ? Text(
                        '收藏的片单 · ${playlists.length}',
                        style: theme.textTheme.titleSmall,
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 2,
                        ),
                        itemCount: playlists.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) =>
                            _playlistChip(theme, playlists[i]),
                      ),
              ),
            ],
          ),
        ),
        if (_playlistsExpanded)
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.26,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.15,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: playlists.length,
              itemBuilder: (_, i) => _playlistTile(theme, playlists[i]),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ chip 组件

  /// 收藏板块里「各占 50%」的居中 chip。
  Widget _subChip(
    ThemeData theme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = theme.colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 1.2 : 0.6,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? colors.onPrimaryContainer : colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _expandChip(ThemeData theme) {
    final colors = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _playlistsExpanded = !_playlistsExpanded),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.primary, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _playlistsExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: colors.onPrimaryContainer,
            ),
            const SizedBox(width: 2),
            Text(
              _playlistsExpanded ? '收起' : '展开',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: colors.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 收起态：左侧封面小方块 + 右侧「名称 · 数量」。
  Widget _playlistChip(ThemeData theme, PornHubPlaylist p) {
    final colors = theme.colorScheme;
    final selected = _ctrl.selectedPlaylistId.value == p.id;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _selectPlaylist(p.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 26,
                height: 26,
                child: _playlistCover(p, colors, 26),
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                '${p.title} · ${p.videoCount}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态网格单元：封面 + 名称 + 数量。
  Widget _playlistTile(ThemeData theme, PornHubPlaylist p) =>
      PornHubPlaylistCard(
        playlist: p,
        selected: _ctrl.selectedPlaylistId.value == p.id,
        onTap: () => _selectPlaylist(p.id),
      );

  // ------------------------------------------------------------ 内容区

  Widget _body() {
    switch (_section) {
      case PornHubMineSection.favorites:
        if (_ctrl.selectedMineSub.value == PornHubMineSub.playlists) {
          return _PublicPlaylistsPane(
            items: _ctrl.publicPlaylists,
            loading: _ctrl.isLoadingPublicPlaylists.value,
            error: _ctrl.publicPlaylistsError.value,
            onRetry: () => _ctrl.loadPublicPlaylists(),
          );
        }
        return _VideoPane(
          currentPage: _ctrl.favoritesPage.value,
          onJump: (page) => _ctrl.loadFavorites(targetPage: page),
          hasMore: _ctrl.favoritesHasMore.value,
          onLoadMore: () => _ctrl.loadFavorites(
            targetPage: _ctrl.favoritesPage.value + 1,
            append: true,
          ),
          items: _ctrl.favorites,
          loading: _ctrl.isLoadingFavorites.value,
          error: _ctrl.favoritesError.value,
          emptyHint: '还没有收藏任何视频',
          onRetry: () => _ctrl.loadFavorites(),
        );
      case PornHubMineSection.playlists:
        return _VideoPane(
          currentPage: _ctrl.playlistPage,
          onJump: _ctrl.jumpPlaylistPage,
          items: _ctrl.playlistVideos,
          loading: _ctrl.isLoadingPlaylistVideos.value,
          error: _ctrl.playlistVideosError.value,
          emptyHint: '该片单还没有视频',
          hasMore: _ctrl.playlistHasMore.value,
          onLoadMore: _ctrl.loadMorePlaylistVideos,
          onRetry: () {
            final id = _ctrl.selectedPlaylistId.value;
            return id == null
                ? Future<void>.value()
                : _ctrl.loadPlaylistVideos(id);
          },
        );
      case PornHubMineSection.history:
        return _VideoPane(
          currentPage: _ctrl.historyPage.value,
          onJump: (page) => _ctrl.loadHistory(targetPage: page),
          hasMore: _ctrl.historyHasMore.value,
          onLoadMore: () => _ctrl.loadHistory(
            targetPage: _ctrl.historyPage.value + 1,
            append: true,
          ),
          items: _ctrl.history,
          loading: _ctrl.isLoadingHistory.value,
          error: _ctrl.historyError.value,
          emptyHint: '还没有观看记录',
          onRetry: () => _ctrl.loadHistory(),
        );
    }
  }
}

/// 片单封面：有图用图（带 PH Referer），无图用纯色方块 + 名称首字母兜底。
///
/// 不用「无封面」来过滤空片单 —— 实测封面数在两次抓取间会变，不可靠；
/// 空片单仍显示，并以名称首字母作为封面。
Widget _playlistCover(PornHubPlaylist p, ColorScheme colors, double size) {
  final fallback = ColoredBox(
    color: colors.primaryContainer,
    child: Center(
      child: Text(
        p.title.isEmpty ? 'P' : p.title[0].toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.bold,
          color: colors.onPrimaryContainer,
        ),
      ),
    ),
  );
  final url = p.coverUrl;
  if (url == null || url.isEmpty) return fallback;
  return CachedNetworkImage(
    imageUrl: url,
    httpHeaders: const <String, String>{'Referer': 'https://cn.pornhub.com/'},
    width: size,
    height: size,
    fit: BoxFit.cover,
    memCacheWidth: (size * 3).round(),
    memCacheHeight: (size * 3).round(),
    placeholder: (_, _) => fallback,
    errorWidget: (_, _, _) => fallback,
  );
}

/// 视频网格面板（收藏视频 / 片单视频 / 历史共用）。
class _VideoPane extends StatelessWidget {
  const _VideoPane({
    required this.items,
    this.currentPage = 1,
    this.onJump,
    required this.loading,
    required this.error,
    required this.emptyHint,
    required this.onRetry,
    this.hasMore = false,
    this.onLoadMore,
  });

  final bool hasMore;
  final VoidCallback? onLoadMore;
  final List<VideoItem> items;
  final int currentPage;
  final ValueChanged<int>? onJump;
  final bool loading;
  final String? error;
  final String emptyHint;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRetry,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification is ScrollUpdateNotification &&
              notification.dragDetails != null &&
              (notification.scrollDelta ?? 0) > 0 &&
              notification.metrics.extentAfter < 500 &&
              !loading &&
              hasMore &&
              error == null) {
            onLoadMore?.call();
          }
          return false;
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: <Widget>[
            if (loading && items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...<Widget>[
              RetainedPageSliver(
                items: List.of(items),
                page: currentPage,
                footer: PornHubListFooter(
                  isLoadingMore: loading,
                  currentPage: currentPage,
                  onJump: onJump,
                  hasMore: hasMore,
                  onLoadMore: onLoadMore,
                  errorText: items.isNotEmpty ? error : null,
                  isEmpty: items.isEmpty,
                  emptyHint: error ?? emptyHint,
                ),
                gridBuilder: (pageItems) => SliverPornHubGrid(
                  videos: pageItems,
                  onDownload: enqueuePornHubDownload,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 收藏 · 我的片单：`/playlists/public` 的片单列表，点某片单进入其视频。
class _PublicPlaylistsPane extends StatelessWidget {
  const _PublicPlaylistsPane({
    required this.items,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final List<PornHubPlaylist> items;
  final bool loading;
  final String? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRetry,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          children: <Widget>[
            const SizedBox(height: 60),
            PornHubErrorBlock(message: error ?? '还没有片单', onRetry: onRetry),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRetry,
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.15,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => PornHubPlaylistCard(
          playlist: items[index],
          onTap: () => Get.to<void>(
            () => PornHubBrowsePage(
              title: items[index].title,
              path: items[index].url,
            ),
          ),
        ),
      ),
    );
  }
}
