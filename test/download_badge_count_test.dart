import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/task_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('download badge count changes only when active task count changes', () {
    final repository = TaskRepository.instance;
    final service = DownloadService();
    const video = VideoItem(
      id: 'badge-count-regression',
      title: 'Badge regression fixture',
      author: '',
      hlsUrl: '',
    );
    final task = DownloadTask(video: video);
    final changes = <int>[];
    final worker = ever<int>(service.activeTaskCount, changes.add);
    addTearDown(() {
      worker.dispose();
      repository.remove(video.id);
      service.onClose();
    });

    repository.upsert(task);
    service.syncFromRepository();
    expect(service.activeTaskCount.value, 1);
    expect(changes, [1]);

    // Progress updates still refresh task-list consumers, but must not
    // trigger a rebuild of the download badge when its label is unchanged.
    task.progress = 0.65;
    repository.upsert(task);
    service.syncFromRepository();
    expect(service.activeTaskCount.value, 1);
    expect(changes, [1]);

    task.status = DownloadStatus.completed;
    repository.upsert(task);
    service.syncFromRepository();
    expect(service.activeTaskCount.value, 0);
    expect(changes, [1, 0]);
    expect(service.tasks.single.status, DownloadStatus.completed);
  });
}
