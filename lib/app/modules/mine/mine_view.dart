/// “我的”个人中心视图（对齐 PiliPlus 风格）。
/// 包含：离线缓存、观看记录、我的订阅、稍后再看、自建收藏夹管理与详情展示。
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

import '../../widgets/app_toast.dart';

import 'package:get/get.dart';

import '../../data/models/video_item.dart';
import '../../modules/downloads/downloads_view.dart';
import '../../routes/app_navigator.dart';
import '../../services/hls_cache_proxy.dart';
import '../../services/preload_service.dart';
import '../../services/task_repository.dart';
import '../../services/user_service.dart';
import '../../widgets/bili_video_card.dart';
import '../../widgets/download_dir_migrator.dart';

class MineView extends StatelessWidget {
  const MineView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userSvc = Get.find<UserService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: [
          IconButton(
            tooltip: '新建收藏夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _showCreateFolderDialog(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          // 1. 用户简要信息卡片（本地单机模式）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 36,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本地用户',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '所有收藏夹与记录均保存在本地存储',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 2. 顶部四格快捷入口（离线缓存、观看记录、我的订阅、稍后再看）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildTopShortcut(
                  context: context,
                  icon: Icons.download_for_offline_outlined,
                  label: '离线缓存',
                  onTap: () => Get.to<void>(() => const DownloadsView()),
                ),
                Obx(
                  () => _buildTopShortcut(
                    context: context,
                    icon: Icons.history,
                    label: '观看记录',
                    badgeCount: userSvc.history.length,
                    onTap: () => Get.to<void>(() => const HistoryListView()),
                  ),
                ),
                Obx(
                  () => _buildTopShortcut(
                    context: context,
                    icon: Icons.subscriptions_outlined,
                    label: '我的订阅',
                    badgeCount: userSvc.subscriptions.length,
                    onTap: () =>
                        Get.to<void>(() => const SubscriptionsListView()),
                  ),
                ),
                Obx(
                  () => _buildTopShortcut(
                    context: context,
                    icon: Icons.watch_later_outlined,
                    label: '稍后再看',
                    badgeCount: userSvc.watchLater.length,
                    onTap: () => Get.to<void>(() => const WatchLaterListView()),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 14),

          // 3. “我的收藏 25 >” 标题区
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Obx(
                  () => Text(
                    '我的收藏 ${userSvc.totalFavoriteCount}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '新建收藏夹',
                  icon: const Icon(Icons.add_circle_outline, size: 22),
                  onPressed: () => _showCreateFolderDialog(context),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // 4. 自建收藏夹横向滚动卡片列表（对齐参考截图）
          SizedBox(
            height: 175,
            child: Obx(() {
              final folders = userSvc.favorites.keys.toList();
              if (folders.isEmpty) {
                return const Center(child: Text('暂无收藏夹'));
              }

              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: folders.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final folderName = folders[index];
                  final list = userSvc.favorites[folderName] ?? <VideoItem>[];
                  final coverUrl = list.isNotEmpty
                      ? list.first.thumbnailUrl
                      : null;

                  return _buildFolderCard(
                    context: context,
                    folderName: folderName,
                    count: list.length,
                    coverUrl: coverUrl,
                    onTap: () => Get.to<void>(
                      () => FavoriteFolderDetailView(folderName: folderName),
                    ),
                    onLongPress: () =>
                        _showFolderActionDialog(context, folderName),
                  );
                },
              );
            }),
          ),

          const SizedBox(height: 20),
          const Divider(height: 1),

          // 5. 辅助快捷列表项
          ListTile(
            leading: const Icon(Icons.playlist_play_rounded),
            title: const Text('所有收藏夹管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showManageFoldersSheet(context),
          ),
          StatefulBuilder(
            builder: (ctx, setState) {
              return ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('移动下载文件夹'),
                subtitle: FutureBuilder<String?>(
                  future: StoragePaths.getCustomPath(),
                  builder: (context, snapshot) {
                    final path = snapshot.data;
                    return Text(
                      path != null && path.isNotEmpty ? path : '系统默认目录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    );
                  },
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await DownloadDirMigrator.selectAndMigrate(
                    context,
                    onDone: () => setState(() {}),
                  );
                },
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.bolt_rounded, color: theme.colorScheme.primary),
            title: const Text('视频预加载与极速加载设置'),
            subtitle: Obx(() {
              final preloadSvc = PreloadService.instance;
              final fullSpeed = HlsCacheProxy.instance.isFullSpeedEnabled.value;
              final segs = preloadSvc.preloadSegmentCount.value;
              final maxMb = preloadSvc.maxCacheSizeMB.value;
              final usedMb =
                  (preloadSvc.currentCacheSizeBytes.value / 1024 / 1024)
                      .toStringAsFixed(1);
              final fullSpeedText = fullSpeed ? '极速加载开启' : '极速加载关闭';
              return Text(
                '$fullSpeedText · 预载: $segs 片/视频 · 上限: $maxMb MB (已用 $usedMb MB)',
                style: const TextStyle(fontSize: 12),
              );
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPreloadSettingsSheet(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清空观看历史'),
            onTap: () {
              userSvc.clearHistory();
              AppToast.show('观看历史已清除');
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 顶部四格按钮
  Widget _buildTopShortcut({
    required BuildContext context,
    required IconData icon,
    required String label,
    int? badgeCount,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: badgeCount != null && badgeCount > 0,
              label: Text('$badgeCount'),
              backgroundColor: theme.colorScheme.primary,
              child: Icon(icon, size: 26, color: theme.colorScheme.onSurface),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 收藏夹横向卡片
  Widget _buildFolderCard({
    required BuildContext context,
    required String folderName,
    required int count,
    String? coverUrl,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 170,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面卡片 (16:10)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: coverUrl != null && coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        memCacheWidth: 400,
                        fit: BoxFit.cover,
                        httpHeaders: const {
                          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                          'Referer': 'https://91porny.com/',
                        },
                        errorWidget: (_, _, _) => _defaultCover(theme),
                      )
                    : _defaultCover(theme),
              ),
            ),
            const SizedBox(height: 6),
            // 收藏夹标题
            Text(
              folderName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            // 数量角标
            Text(
              '共$count条视频 · 公开',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _defaultCover(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.folder_special,
          size: 38,
          color: theme.colorScheme.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 对话框
  void _showCreateFolderDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建收藏夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入收藏夹名称（如：精选、剧情等）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final success = Get.find<UserService>().createFolder(name);
                if (success) {
                  Navigator.of(ctx).pop();
                  AppToast.show('已创建收藏夹：$name');
                } else {
                  AppToast.show('收藏夹已存在或名称无效');
                }
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showFolderActionDialog(BuildContext context, String folderName) {
    if (folderName == UserService.defaultFolderName) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(folderName),
        children: [
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(ctx).pop();
              Get.find<UserService>().deleteFolder(folderName);
              AppToast.show('操作成功');
            },
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: context.cError),
                SizedBox(width: 8),
                Text('删除此收藏夹', style: TextStyle(color: context.cError)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showManageFoldersSheet(BuildContext context) {
    final userSvc = Get.find<UserService>();
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Obx(() {
          final folders = userSvc.favorites.keys.toList();
          return ListView.builder(
            shrinkWrap: true,
            itemCount: folders.length,
            itemBuilder: (context, i) {
              final name = folders[i];
              final count = userSvc.favorites[name]?.length ?? 0;
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(name),
                subtitle: Text('共 $count 个视频'),
                trailing: name != UserService.defaultFolderName
                    ? IconButton(
                        icon: Icon(Icons.delete_outline, color: context.cError),
                        onPressed: () {
                          userSvc.deleteFolder(name);
                        },
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  Get.to<void>(
                    () => FavoriteFolderDetailView(folderName: name),
                  );
                },
              );
            },
          );
        }),
      ),
    );
  }

  void _showPreloadSettingsSheet(BuildContext context) {
    final theme = Theme.of(context);
    final preloadSvc = PreloadService.instance;
    unawaited(preloadSvc.refreshCacheStats());

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      Icons.bolt_rounded,
                      color: theme.colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '视频预加载与秒开设置',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '浏览列表时在后台静默预载首切片，打开视频瞬间 0 毫秒秒开，同时 6 并发全速拉满整片。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),

                // 0. 全片极速加载总开关
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.35,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Obx(() {
                    final isFullSpeed =
                        HlsCacheProxy.instance.isFullSpeedEnabled.value;
                    return SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isFullSpeed,
                      activeThumbColor: theme.colorScheme.primary,
                      title: const Row(
                        children: [
                          Icon(Icons.bolt, color: Colors.amber, size: 20),
                          SizedBox(width: 6),
                          Text(
                            '全片极速加载（推荐开启）',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '播放时在后台继续缓存整片，列表预加载与全片缓存共用磁盘空间；关闭后停止后台全片任务',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                      onChanged: (val) {
                        unawaited(preloadSvc.setFullSpeedEnabled(val));
                      },
                    );
                  }),
                ),
                const SizedBox(height: 20),

                // 1. 预加载数量
                const Text(
                  '列表预加载数量',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '进入页面或刷新时，自动在后台按从上到下优先级预下载视频',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Obx(() {
                  final current = preloadSvc.preloadCount.value;
                  const options = [
                    MapEntry(0, '关闭 (0)'),
                    MapEntry(5, '5 个'),
                    MapEntry(8, '8 个（推荐）'),
                    MapEntry(10, '10 个'),
                    MapEntry(20, '20 个'),
                    MapEntry(-1, '全页全部'),
                  ];
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: options.map((opt) {
                      final isSelected = current == opt.key;
                      return ChoiceChip(
                        label: Text(opt.value),
                        selected: isSelected,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 12,
                        ),
                        onSelected: (_) => preloadSvc.setPreloadCount(opt.key),
                      );
                    }).toList(),
                  );
                }),

                const SizedBox(height: 18),

                // 2. 单视频预载切片数量
                const Text(
                  '单视频预加载切片数',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Hanime1 每块预载 2 MB；91 按播放时长预载。块数越多，打开后可离线播放越久',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Obx(() {
                  final currentSegs = preloadSvc.preloadSegmentCount.value;
                  const segOptions = [
                    MapEntry(1, '1 块 (最快)'),
                    MapEntry(2, '2 块 (推荐)'),
                    MapEntry(3, '3 块'),
                    MapEntry(5, '5 块'),
                    MapEntry(10, '10 块'),
                  ];
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: segOptions.map((opt) {
                      final isSelected = currentSegs == opt.key;
                      return ChoiceChip(
                        label: Text(opt.value),
                        selected: isSelected,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 12,
                        ),
                        onSelected: (_) =>
                            preloadSvc.setPreloadSegmentCount(opt.key),
                      );
                    }).toList(),
                  );
                }),

                const SizedBox(height: 18),

                // 3. 缓存容量上限
                const Text(
                  '预加载缓存容量上限',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '超出上限时将自动按 LRU 算法优先淘汰最久未观看的切片',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Obx(() {
                  final current = preloadSvc.maxCacheSizeMB.value;
                  const mbOptions = [
                    MapEntry(100, '100 MB'),
                    MapEntry(200, '200 MB'),
                    MapEntry(500, '500 MB (推荐)'),
                    MapEntry(1024, '1 GB'),
                    MapEntry(2048, '2 GB'),
                  ];
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: mbOptions.map((opt) {
                      final isSelected = current == opt.key;
                      return ChoiceChip(
                        label: Text(opt.value),
                        selected: isSelected,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 12,
                        ),
                        onSelected: (_) =>
                            preloadSvc.setMaxCacheSizeMB(opt.key),
                      );
                    }).toList(),
                  );
                }),

                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // 3. 当前占用与一键清理
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Obx(() {
                      final used =
                          (preloadSvc.currentCacheSizeBytes.value / 1024 / 1024)
                              .toStringAsFixed(1);
                      final max = preloadSvc.maxCacheSizeMB.value;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '当前预加载占用',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$used MB / $max MB',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      );
                    }),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text(
                        '立即清空缓存',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () async {
                        await preloadSvc.clearCache();
                        AppToast.show('预加载缓存已彻底清空');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------- 收藏夹详情页
class FavoriteFolderDetailView extends StatelessWidget {
  const FavoriteFolderDetailView({super.key, required this.folderName});

  final String folderName;

  @override
  Widget build(BuildContext context) {
    final userSvc = Get.find<UserService>();

    return Scaffold(
      appBar: AppBar(title: Text(folderName)),
      body: Obx(() {
        final list = userSvc.favorites[folderName] ?? <VideoItem>[];
        if (list.isEmpty) {
          return const Center(child: Text('该收藏夹内暂无视频，请在播放时点击【收藏】添加'));
        }
        PreloadService.instance.preloadList(list, isNewPage: true);

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 14, endIndent: 14),
          itemBuilder: (context, index) {
            final video = list[index];
            return Dismissible(
              key: ValueKey('${folderName}_${video.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: context.cError,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) {
                userSvc.removeVideoFromFolder(folderName, video.id);
                AppToast.show('已从 $folderName 移出');
              },
              child: BiliVideoCardH(
                video: video,
                onTap: () => AppNavigator.toPlayer(video),
              ),
            );
          },
        );
      }),
    );
  }
}

// ------------------------------------------------------------- 观看记录页面
class HistoryListView extends StatelessWidget {
  const HistoryListView({super.key});

  @override
  Widget build(BuildContext context) {
    final userSvc = Get.find<UserService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('观看记录'),
        actions: [
          IconButton(
            tooltip: '清空历史',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              userSvc.clearHistory();
              AppToast.show('观看记录已清除');
            },
          ),
        ],
      ),
      body: Obx(() {
        final list = userSvc.history;
        if (list.isEmpty) {
          return const Center(child: Text('暂无观看历史'));
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 14, endIndent: 14),
          itemBuilder: (context, index) {
            final item = list[index];
            final percent = (item.progressPercent * 100).toInt();
            return Dismissible(
              key: ValueKey('hist_${item.video.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: context.cError,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) => userSvc.removeHistory(item.video.id),
              child: BiliVideoCardH(
                video: item.video.copyWith(
                  viewsStr: percent > 0 ? '看到 $percent%' : '刚开始观看',
                ),
                onTap: () => AppNavigator.toPlayer(item.video),
              ),
            );
          },
        );
      }),
    );
  }
}

// ------------------------------------------------------------- 稍后再看页面
class WatchLaterListView extends StatelessWidget {
  const WatchLaterListView({super.key});

  @override
  Widget build(BuildContext context) {
    final userSvc = Get.find<UserService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('稍后再看'),
        actions: [
          IconButton(
            tooltip: '清空列表',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              userSvc.clearWatchLater();
              AppToast.show('稍后再看列表已清空');
            },
          ),
        ],
      ),
      body: Obx(() {
        final list = userSvc.watchLater;
        if (list.isEmpty) {
          return const Center(child: Text('暂无稍后再看视频'));
        }
        PreloadService.instance.preloadList(list, isNewPage: true);

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 14, endIndent: 14),
          itemBuilder: (context, index) {
            final video = list[index];
            return Dismissible(
              key: ValueKey('wl_${video.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: context.cError,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) => userSvc.removeFromWatchLater(video.id),
              child: BiliVideoCardH(
                video: video,
                onTap: () => AppNavigator.toPlayer(video),
              ),
            );
          },
        );
      }),
    );
  }
}

// ------------------------------------------------------------- 我的订阅页面
class SubscriptionsListView extends StatelessWidget {
  const SubscriptionsListView({super.key});

  @override
  Widget build(BuildContext context) {
    final userSvc = Get.find<UserService>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('我的订阅')),
      body: Obx(() {
        final list = userSvc.subscriptions.toList();
        if (list.isEmpty) {
          return const Center(child: Text('暂无关注的 UP 主，在视频页点击【关注】即可订阅'));
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 14, endIndent: 14),
          itemBuilder: (context, index) {
            final author = list[index];
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  author.isNotEmpty ? author[0].toUpperCase() : 'U',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              title: Text(
                author,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('已关注 UP 主'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: () => AppNavigator.toAuthor(author),
                    child: const Text('TA的作品'),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: Icon(
                      Icons.remove_circle_outline,
                      color: context.cTextSub,
                    ),
                    tooltip: '取消关注',
                    onPressed: () => userSvc.toggleSubscription(author),
                  ),
                ],
              ),
            );
          },
        );
      }),
    );
  }
}
