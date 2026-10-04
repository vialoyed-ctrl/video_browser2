/// 下载管理视图：任务队列、进度、筛选与操作。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/formatters.dart';
import '../../services/ios_download_files.dart';
import '../../services/task_repository.dart';
import '../../data/models/video_item.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common.dart';
import '../../widgets/download_dir_migrator.dart';
import 'downloads_controller.dart';

class DownloadsView extends GetView<DownloadsController> {
  const DownloadsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == 'clear-completed') {
                controller.clearCompleted();
              } else if (value == 'retry-failed') {
                controller.retryAllFailed();
              } else if (value == 'move-dir') {
                DownloadDirMigrator.selectAndMigrate(context);
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'move-dir',
                child: Row(
                  children: [
                    Icon(Icons.drive_file_move_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('移动下载文件夹'),
                  ],
                ),
              ),
              if (controller.tasks.any(
                (t) => t.status == DownloadStatus.failed,
              ))
                const PopupMenuItem<String>(
                  value: 'retry-failed',
                  child: Row(
                    children: [
                      Icon(Icons.refresh, size: 20),
                      SizedBox(width: 8),
                      Text('重试全部失败任务'),
                    ],
                  ),
                ),
              if (controller.tasks.any(
                (t) => t.status == DownloadStatus.completed,
              ))
                const PopupMenuItem<String>(
                  value: 'clear-completed',
                  child: Row(
                    children: [
                      Icon(Icons.cleaning_services_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('清理已完成记录'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _filterBar(context),
          const Divider(height: 1),
          Expanded(child: _list(context)),
        ],
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    return Obx(
      () => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            for (final f in DownloadFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    '${f.label} (${controller.countOf(f)})',
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: controller.filter.value == f,
                  onSelected: (_) => controller.setFilter(f),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    return Obx(() {
      final tasks = controller.visibleTasks;
      if (tasks.isEmpty) {
        return EmptyView(
          message: controller.filter.value == DownloadFilter.all
              ? '还没有下载任务。\n在浏览或搜索页点击下载图标即可加入队列。'
              : '该分类下暂无任务',
          icon: Icons.download_outlined,
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: tasks.length,
        separatorBuilder: (_, _) => const Divider(indent: 16, endIndent: 16),
        itemBuilder: (context, index) => _taskTile(context, tasks[index]),
      );
    });
  }

  Widget _taskTile(BuildContext context, DownloadTask task) {
    final scheme = Theme.of(context).colorScheme;
    final isCompleted = task.status == DownloadStatus.completed;

    return InkWell(
      onTap: isCompleted ? () => _openDownloadedVideo(task) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Stack(
              alignment: Alignment.center,
              children: [
                VideoThumbnail(video: task.video, width: 104, height: 60),
                if (isCompleted)
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _statusLine(context, task),
                  const SizedBox(height: 8),
                  if (task.status == DownloadStatus.running) ...<Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  _actions(context, task),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(BuildContext context, DownloadTask task) {
    final scheme = Theme.of(context).colorScheme;
    final Color color = switch (task.status) {
      DownloadStatus.completed => scheme.primary,
      DownloadStatus.failed => scheme.error,
      DownloadStatus.canceled => scheme.onSurfaceVariant,
      _ => scheme.onSurfaceVariant,
    };

    final String detail = switch (task.status) {
      DownloadStatus.running =>
        '${task.status.label} · ${task.completedSegments}/${task.totalSegments} 分片 · ${Formatters.percent(task.progress)}',
      DownloadStatus.completed => '${task.status.label} · 点击直接播放',
      DownloadStatus.failed => '${task.status.label} · ${task.error ?? '未知错误'}',
      _ => task.status.label,
    };

    return Text(
      detail,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11.5, color: color, height: 1.4),
    );
  }

  Widget _actions(BuildContext context, DownloadTask task) {
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (task.status == DownloadStatus.completed)
          FilledButton.tonalIcon(
            onPressed: () => _openDownloadedVideo(task),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('打开', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        if (task.isActive)
          TextButton.icon(
            onPressed: () => controller.cancel(task.id),
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('取消', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        if (Platform.isIOS && task.status == DownloadStatus.completed)
          TextButton.icon(
            onPressed: () => _openDownloadedVideo(task, export: true),
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('导出', style: TextStyle(fontSize: 12)),
          ),
        if (task.status == DownloadStatus.failed ||
            task.status == DownloadStatus.canceled)
          TextButton.icon(
            onPressed: () => controller.retry(task.id),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        TextButton.icon(
          onPressed: () => _confirmRemove(task),
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('移除', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }

  Future<void> _openDownloadedVideo(
    DownloadTask task, {
    bool export = false,
  }) async {
    final savedPath = task.outputPath;
    if (savedPath == null || savedPath.isEmpty) {
      AppToast.show('视频文件路径为空');
      return;
    }
    try {
      if (Platform.isIOS) {
        final resolved = await IosDownloadFiles.resolve(savedPath);
        if (resolved == null) {
          AppToast.show('视频文件不存在，可能已被移动或删除');
          return;
        }
        final playable = await IosDownloadFiles.prepareVideo(resolved);
        if (task.outputPath != playable) {
          task.outputPath = playable;
          TaskRepository.instance.upsert(task);
          await TaskRepository.instance.flush();
        }
        if (export) {
          await IosDownloadFiles.export(playable);
        } else {
          await IosDownloadFiles.open(playable);
        }
        return;
      }
      if (!File(savedPath).existsSync()) {
        AppToast.show('视频文件不存在，可能已被移动或删除');
        return;
      }
      final result = await OpenFilex.open(savedPath, type: 'video/*');
      if (result.type != ResultType.done) {
        AppToast.show('打开失败：${result.message}');
      }
    } catch (e) {
      AppToast.show('视频打开失败：$e');
    }
  }

  void _confirmRemove(DownloadTask task) {
    final bool isCompleted = task.status == DownloadStatus.completed;
    Get.dialog<dynamic>(
      AlertDialog(
        title: const Text('移除任务'),
        content: Text(
          isCompleted
              ? '仅从列表移除记录，已下载的文件会保留在磁盘上。\n\n确定移除「${task.video.title}」？'
              : '确定移除「${task.video.title}」？未完成的分片会被清理。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Get.back<dynamic>(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Get.back<dynamic>();
              controller.remove(task.id);
            },
            child: const Text('移除'),
          ),
        ],
      ),
    );
  }
}
