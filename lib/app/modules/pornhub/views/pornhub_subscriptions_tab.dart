/// PornHub 订阅页。
///
/// 版面（按用户最终要求）：
///   ┌ 上方订阅栏：**最左一格是「展开/收起」按钮**，其后是「全部订阅」+ 各创作者，
///   │  收起时是**一行横向滑动**（左右滑），展开时变成多行 Wrap。 ────────┐
///   ├ 视频区：当前选中项的视频流（全部订阅 = 官网 `/subscriptions`）， ───┤
///   │  **上滑到底自动追加下一页，上一页内容不消失**（累积式）。          │
///   └────────────────────────────────────────────────────────────────┘
///
/// 交互要点（用户明确）：
///   - 点某个订阅 → **原地加载出他的视频**，**不跳转页面**；
///   - 上方订阅栏保持原来的横向滑动样式，只是最左边多一个展开/收起按钮；
///   - 下拉刷新才清缓存重抓。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/pornhub_models.dart';
import '../pornhub_controller.dart';
import 'pornhub_creator_page.dart';
import '../widgets/pornhub_actions.dart';
import '../widgets/pornhub_login_form.dart';
import '../widgets/pornhub_video_grid.dart';

class PornHubSubscriptionsTab extends StatefulWidget {
  const PornHubSubscriptionsTab({super.key});

  @override
  State<PornHubSubscriptionsTab> createState() =>
      _PornHubSubscriptionsTabState();
}

class _PornHubSubscriptionsTabState extends State<PornHubSubscriptionsTab> {
  PornHubController get _ctrl => PornHubController.to;

  /// 上方订阅栏是否展开成多行。默认收起（一行横向滑动）。
  bool _expanded = false;
  final ScrollController _feedScroll = ScrollController();
  Worker? _creatorWorker, _feedWorker;

  @override
  void initState() {
    super.initState();
    _feedScroll.addListener(_maybeLoadMore);
    _feedWorker = everAll(
      [_ctrl.isLoadingFeed, _ctrl.isLoadingClips, _ctrl.selectedMediaType],
      (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeLoadMore();
        });
      },
    );
    _creatorWorker = ever<String>(_ctrl.selectedCreator, (_) {
      if (_feedScroll.hasClients) _feedScroll.jumpTo(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ctrl.loadSubscriptions();
    });
  }

  @override
  void dispose() {
    _creatorWorker?.dispose();
    _feedWorker?.dispose();
    _feedScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!_ctrl.isLoggedIn) return const PornHubLoginForm();

      if (_ctrl.isLoadingSubscriptions.value && _ctrl.subscriptions.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_ctrl.subscriptions.isEmpty) {
        return PornHubErrorBlock(
          message: _ctrl.subscriptionsError.value ?? '未获取到订阅',
          onRetry: () => _ctrl.loadSubscriptions(refresh: true),
        );
      }

      return Column(
        children: <Widget>[
          Obx(() => _buildCreatorBar(context)),
          const Divider(height: 1),
          Obx(
            () => _ctrl.selectedCreator.value == PornHubController.allSubs
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      _buildMediaTypeBar(context),
                      const Divider(height: 1),
                    ],
                  ),
          ),
          Expanded(child: _buildFeed(context)),
        ],
      );
    });
  }

  // -------------------------------------------------------------- 上方订阅栏

  Widget _buildCreatorBar(BuildContext context) {
    final subs = _ctrl.subscriptions;
    return Column(
      children: [
        SizedBox(
          height: 50,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: _buildExpandChip(context),
              ),
              Expanded(
                child: _expanded
                    ? Text(
                        '订阅创作者 · ${subs.length}',
                        style: Theme.of(context).textTheme.titleSmall,
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 2,
                        ),
                        itemCount: subs.length + 1,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) => index == 0
                            ? Obx(() => _buildAllChip(context))
                            : Obx(
                                () =>
                                    _buildCreatorChip(context, subs[index - 1]),
                              ),
                      ),
              ),
            ],
          ),
        ),
        if (_expanded)
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.26,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: 94,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: subs.length + 1,
              itemBuilder: (context, index) => Obx(
                () => _buildCreatorTile(
                  context,
                  index == 0 ? null : subs[index - 1],
                ),
              ),
            ),
          ),
      ],
    );
  }
  // ---------------------------------------------------- 视频 / 切片二级选择

  /// 创作者 chip 行下面的一行：`视频 · N` / `切片 · N`，各占整行 50%、文字居中。
  ///
  /// 默认「视频」，此时下方仍是原来的聚合流 / 单创作者视频，行为不变。
  /// 计数取不到时只显示文字，不臆造数字。
  Widget _buildMediaTypeBar(BuildContext context) {
    final key = _ctrl.selectedCreator.value;
    // 「全部订阅」时下面没有具体创作者，视频/切片这个二级维度不成立，
    // 整行隐藏（用户要求），否则等于给了一个切了也没意义的选择。
    if (key == PornHubController.allSubs) return const SizedBox.shrink();
    final videoCount = _ctrl.creatorCounts[key];
    final clipCount = _ctrl.clipCounts[key];
    final isClips = _ctrl.selectedMediaType.value == PornHubMediaType.clips;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _mediaChip(
              context,
              label: videoCount == null ? '视频' : '视频 · $videoCount',
              selected: !isClips,
              onTap: () => _ctrl.selectMediaType(PornHubMediaType.videos),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _mediaChip(
              context,
              label: clipCount == null ? '切片' : '切片 · $clipCount',
              selected: isClips,
              onTap: () => _ctrl.selectMediaType(PornHubMediaType.clips),
            ),
          ),
          IconButton(
            tooltip: '打开个人主页',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Get.to<void>(
              () => PornHubCreatorPage(
                name: _ctrl.selectedCreatorName,
                path: key,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「各占 50%」的居中 chip（颜色全走 colorScheme，与创作者 chip 同一套色）。
  Widget _mediaChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
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
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              color: selected ? colors.onPrimaryContainer : colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandChip(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.primary, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 2),
            Text(
              _expanded ? '收起' : '展开',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreatorTile(BuildContext context, PornHubSubscription? creator) {
    final colors = Theme.of(context).colorScheme;
    final key = creator?.path ?? PornHubController.allSubs;
    final selected = _ctrl.selectedCreator.value == key;
    final count = creator == null ? null : _ctrl.creatorCounts[key];
    final name = creator?.name ?? '全部订阅';
    final subtitle = creator == null
        ? '${_ctrl.subscriptions.length} 位创作者'
        : count == null
        ? '视频数待获取'
        : '$count 个视频';
    final avatar = creator?.avatarUrl;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _ctrl.selectCreator(key),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: avatar != null && avatar.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: avatar,
                              httpHeaders: const {
                                'Referer': 'https://cn.pornhub.com/',
                              },
                              width: 52,
                              height: 52,
                              memCacheWidth: 208,
                              memCacheHeight: 208,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Center(
                                child: Text(
                                  name.isEmpty ? 'U' : name[0].toUpperCase(),
                                ),
                              ),
                            )
                          : creator == null
                          ? Icon(
                              Icons.people_alt_rounded,
                              color: colors.primary,
                              size: 30,
                            )
                          : Center(
                              child: Text(
                                name.isEmpty ? 'U' : name[0].toUpperCase(),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllChip(BuildContext context) {
    return _chip(
      context: context,
      label: '全部订阅 (${_ctrl.subscriptions.length})',
      selected: _ctrl.selectedCreator.value == PornHubController.allSubs,
      onTap: () => _ctrl.selectCreator(PornHubController.allSubs),
    );
  }

  Widget _buildCreatorChip(BuildContext context, PornHubSubscription creator) {
    // 该创作者的总视频数（串行限流逐个取回，取到才显示，供用户核对）。
    final n = _ctrl.creatorCounts[creator.path];
    return _chip(
      context: context,
      label: n == null ? creator.name : '${creator.name} · $n',
      avatarUrl: creator.avatarUrl,
      selected: _ctrl.selectedCreator.value == creator.path,
      onTap: () => _ctrl.selectCreator(creator.path),
    );
  }

  Widget _chip({
    required BuildContext context,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? avatarUrl,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (avatarUrl != null && avatarUrl.isNotEmpty) ...<Widget>[
              ClipOval(
                child: CachedNetworkImage(
                  imageUrl: avatarUrl,
                  httpHeaders: const <String, String>{
                    'Referer': 'https://cn.pornhub.com/',
                  },
                  width: 18,
                  height: 18,
                  memCacheWidth: 72,
                  memCacheHeight: 72,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) =>
                      _letterAvatar(context, label, selected),
                ),
              ),
            ] else
              _letterAvatar(context, label, selected),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _letterAvatar(BuildContext context, String label, bool selected) {
    final theme = Theme.of(context);
    return CircleAvatar(
      radius: 9,
      backgroundColor: selected
          ? theme.colorScheme.onPrimary.withValues(alpha: 0.25)
          : theme.colorScheme.primaryContainer,
      child: Text(
        label.isNotEmpty ? label[0].toUpperCase() : 'U',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: selected
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.primary,
        ),
      ),
    );
  }

  void _maybeLoadMore() {
    if (!mounted ||
        !_feedScroll.hasClients ||
        _ctrl.isLoadingSubscriptions.value ||
        _feedScroll.position.extentAfter > 700) {
      return;
    }
    final clips = _ctrl.selectedMediaType.value == PornHubMediaType.clips;
    if (clips) {
      if (_ctrl.clipVideos.isNotEmpty &&
          _ctrl.clipsHasMore &&
          !_ctrl.isLoadingClips.value &&
          _ctrl.clipsError.value == null) {
        _ctrl.loadMoreClips();
      }
    } else if (_ctrl.feedVideos.isNotEmpty &&
        _ctrl.feedHasMore &&
        !_ctrl.isLoadingFeed.value &&
        _ctrl.feedError.value == null) {
      _ctrl.loadMoreFeed();
    }
  }

  // -------------------------------------------------------------- 视频区

  Widget _buildFeed(BuildContext context) {
    return Obx(() {
      // 「视频」沿用原有聚合流 / 单创作者视频；「切片」走独立的切片列表。
      final isClips = _ctrl.selectedMediaType.value == PornHubMediaType.clips;
      final videos = isClips ? _ctrl.clipVideos : _ctrl.feedVideos;
      final loading = isClips
          ? _ctrl.isLoadingClips.value
          : _ctrl.isLoadingFeed.value;
      final error = isClips ? _ctrl.clipsError.value : _ctrl.feedError.value;
      final hasMore = isClips ? _ctrl.clipsHasMore : _ctrl.feedHasMore;
      final onRetry = isClips
          ? () => _ctrl.loadClips(reset: true)
          : () => _ctrl.loadFeed(reset: true);
      _ctrl.selectedCreator.value;

      if (loading && videos.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (videos.isEmpty) {
        return RefreshIndicator(
          onRefresh: () => _ctrl.loadSubscriptions(refresh: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            children: <Widget>[
              const SizedBox(height: 60),
              PornHubErrorBlock(
                message: error ?? (isClips ? '暂未获取到切片' : '暂未获取到视频'),
                onRetry: onRetry,
              ),
            ],
          ),
        );
      }

      return RefreshIndicator(
        onRefresh: () => _ctrl.loadSubscriptions(refresh: true),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0 && n is ScrollUpdateNotification) _maybeLoadMore();
            return false;
          },
          child: CustomScrollView(
            controller: _feedScroll,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: <Widget>[
              if (error != null)
                SliverToBoxAdapter(
                  child: TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(error),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                  child: Obx(() {
                    final key = _ctrl.selectedCreator.value;
                    final total = isClips
                        ? _ctrl.clipCounts[key]
                        : _ctrl.creatorCounts[key];
                    final countLabel = key == PornHubController.allSubs
                        ? ''
                        : total == null
                        ? (isClips ? '' : ' · 总数获取中')
                        : ' · 共 $total 个${isClips ? '切片' : '视频'}';
                    final loaded = isClips
                        ? _ctrl.clipVideos.length
                        : _ctrl.feedTotalCount.value;
                    return Text(
                      '${_ctrl.selectedCreatorName}$countLabel · ${key == PornHubController.allSubs ? '网页顺序' : '最新优先'} · 已加载 $loaded 条',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    );
                  }),
                ),
              ),
              SliverPornHubGrid(
                videos: videos,
                onDownload: enqueuePornHubDownload,
              ),
              SliverToBoxAdapter(
                child: PornHubListFooter(
                  isLoadingMore: loading,
                  hasMore: hasMore,
                  onLoadMore: isClips
                      ? _ctrl.loadMoreClips
                      : _ctrl.loadMoreFeed,
                  errorText: error,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
