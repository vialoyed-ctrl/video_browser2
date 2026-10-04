/// 下载管理模块。
///
/// 视图状态直接绑定 [DownloadService.tasks]（RxList），
/// 控制器只负责筛选与转发操作，不持有第二份数据。
library;

import 'package:get/get.dart';

import '../../data/models/video_item.dart';
import '../../services/download_service.dart';

enum DownloadFilter {
  all('全部'),
  active('进行中'),
  completed('已完成'),
  failed('失败');

  const DownloadFilter(this.label);
  final String label;
}

class DownloadsController extends GetxController {
  final DownloadService service = Get.find<DownloadService>();

  final Rx<DownloadFilter> filter = DownloadFilter.all.obs;

  RxList<DownloadTask> get tasks => service.tasks;

  /// 当前筛选下的任务列表。
  List<DownloadTask> get visibleTasks {
    final all = service.tasks;
    switch (filter.value) {
      case DownloadFilter.all:
        return all.toList();
      case DownloadFilter.active:
        return all
            .where(
              (t) =>
                  t.status == DownloadStatus.pending ||
                  t.status == DownloadStatus.running,
            )
            .toList();
      case DownloadFilter.completed:
        return all.where((t) => t.status == DownloadStatus.completed).toList();
      case DownloadFilter.failed:
        return all
            .where(
              (t) =>
                  t.status == DownloadStatus.failed ||
                  t.status == DownloadStatus.canceled,
            )
            .toList();
    }
  }

  int countOf(DownloadFilter f) {
    final all = service.tasks;
    return switch (f) {
      DownloadFilter.all => all.length,
      DownloadFilter.active =>
        all
            .where(
              (t) =>
                  t.status == DownloadStatus.pending ||
                  t.status == DownloadStatus.running,
            )
            .length,
      DownloadFilter.completed =>
        all.where((t) => t.status == DownloadStatus.completed).length,
      DownloadFilter.failed =>
        all
            .where(
              (t) =>
                  t.status == DownloadStatus.failed ||
                  t.status == DownloadStatus.canceled,
            )
            .length,
    };
  }

  void setFilter(DownloadFilter value) => filter.value = value;

  void cancel(String taskId) => service.cancel(taskId);

  void retry(String taskId) => service.retry(taskId);

  void remove(String taskId) => service.remove(taskId);

  void clearCompleted() => service.clearCompleted();

  /// 当前筛选下是否存在可重试的任务。
  bool get hasRetryable =>
      visibleTasks.any((t) => t.status == DownloadStatus.failed);

  /// 当前筛选下是否存在已完成任务。
  bool get hasCompleted =>
      visibleTasks.any((t) => t.status == DownloadStatus.completed);

  void retryAllFailed() {
    for (final task in visibleTasks.where(
      (t) => t.status == DownloadStatus.failed,
    )) {
      service.retry(task.id);
    }
  }
}
