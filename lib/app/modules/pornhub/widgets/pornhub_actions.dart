/// PornHub 模块的通用动作（下载入队等）。
///
/// 与 91 版面 `home_view._enqueue` 的行为保持一致：先查重，已在队列中则不重复入队。
library;

import 'package:get/get.dart';

import '../../../data/models/video_item.dart';
import '../../../services/download_service.dart';
import '../../../widgets/app_toast.dart';

/// 把视频加入下载队列（含去重）。
void enqueuePornHubDownload(VideoItem video) {
  final service = Get.find<DownloadService>();

  DownloadTask? existing;
  for (final task in service.tasks) {
    if (task.id == video.id) {
      existing = task;
      break;
    }
  }

  if (existing != null && existing.isActive) {
    AppToast.show('「${video.title}」已在下载队列中');
    return;
  }
  service.enqueue(video);
  AppToast.show('已加入下载队列：${video.title}');
}
