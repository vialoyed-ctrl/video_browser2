import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/task_repository.dart';

class HeldStreamCleanup implements HttpClientAdapter {
  int requests = 0;
  final cancelStarted = Completer<void>();
  final allowCancel = Completer<void>();
  late final StreamController<Uint8List> stream = StreamController<Uint8List>(
    onCancel: () {
      if (!cancelStarted.isCompleted) cancelStarted.complete();
      return allowCancel.future;
    },
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? input,
    Future<void>? cancellation,
  ) async {
    requests++;
    if (requests > 1) {
      return ResponseBody.fromBytes(
        [0, 0, 0, 8, 102, 116, 121, 112],
        200,
        headers: {
          Headers.contentLengthHeader: ['8'],
        },
      );
    }
    stream.add(Uint8List.fromList([0, 0, 0, 8, 102, 116, 121, 112]));
    return ResponseBody(
      stream.stream,
      200,
      headers: {
        Headers.contentLengthHeader: ['16'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('MP4 settlement waits for actual response stream cleanup', () async {
    final dir = await Directory.systemTemp.createTemp(
      'video-browser-stream-contract-',
    );
    SharedPreferences.setMockInitialValues({'custom_download_path': dir.path});
    StoragePaths.clearRootCache();
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async => dir.path);
    final adapter = HeldStreamCleanup();
    final service = DownloadService(dio: Dio()..httpClientAdapter = adapter);
    const video = VideoItem(
      id: 'stream-barrier',
      title: 'Neutral stream',
      author: 'fixture',
      hlsUrl: 'https://example.invalid/stream.mp4',
    );
    try {
      final task = service.enqueue(video);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (task.progress == 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Initial bytes not written');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      service.cancel(task.id);
      final settled = service.whenTaskSettled(task.id);
      await adapter.cancelStarted.future.timeout(const Duration(seconds: 5));
      final boundary = await Future.any([
        settled.then((_) => 'early'),
        Future<String>.delayed(const Duration(milliseconds: 150), () => 'held'),
      ]);
      expect(
        boundary,
        'held',
        reason: 'Completion must remain blocked while response cleanup is held',
      );
      adapter.allowCancel.complete();
      await settled.timeout(const Duration(seconds: 5));
      expect(
        TaskRepository.instance.byId(task.id)!.status,
        DownloadStatus.canceled,
      );
    } finally {
      if (!adapter.allowCancel.isCompleted) adapter.allowCancel.complete();
      service.onClose();
      await service.whenTaskSettled(video.id);
      await adapter.stream.close();
      TaskRepository.instance.remove(video.id);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await TaskRepository.instance.flush();
      messenger.setMockMethodCallHandler(paths, null);
      StoragePaths.clearRootCache();
      await dir.delete(recursive: true);
    }
  });
  test('MP4 timeout drains before failure and successful retry', () async {
    final dir = await Directory.systemTemp.createTemp(
      'video-browser-stream-contract-',
    );
    SharedPreferences.setMockInitialValues({'custom_download_path': dir.path});
    StoragePaths.clearRootCache();
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async => dir.path);
    final adapter = HeldStreamCleanup();
    final service = DownloadService(
      dio: Dio()..httpClientAdapter = adapter,
      mp4DownloadTimeout: const Duration(milliseconds: 200),
    );
    const video = VideoItem(
      id: 'timeout-barrier',
      title: 'Neutral stream',
      author: 'fixture',
      hlsUrl: 'https://example.invalid/stream.mp4',
    );
    try {
      final task = service.enqueue(video);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (task.progress == 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Initial bytes not written');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // The injected deadline cancels the request; no user cancellation.
      final settled = service.whenTaskSettled(task.id);
      await adapter.cancelStarted.future.timeout(const Duration(seconds: 5));
      final boundary = await Future.any([
        settled.then((_) => 'early'),
        Future<String>.delayed(const Duration(milliseconds: 150), () => 'held'),
      ]);
      expect(
        boundary,
        'held',
        reason: 'Completion must remain blocked while response cleanup is held',
      );
      adapter.allowCancel.complete();
      await settled.timeout(const Duration(seconds: 5));
      final failed = TaskRepository.instance.byId(task.id)!;
      expect(failed.status, DownloadStatus.failed);
      expect(failed.error, contains('MP4下载超时'));
      await service.retry(task.id);
      await service
          .whenTaskSettled(task.id)
          .timeout(const Duration(seconds: 5));
      final completed = TaskRepository.instance.byId(task.id)!;
      expect(completed.status, DownloadStatus.completed);
      expect(adapter.requests, 2);
      expect(await File(completed.outputPath!).readAsBytes(), [
        0,
        0,
        0,
        8,
        102,
        116,
        121,
        112,
      ]);
    } finally {
      if (!adapter.allowCancel.isCompleted) adapter.allowCancel.complete();
      service.onClose();
      await service.whenTaskSettled(video.id);
      await adapter.stream.close();
      TaskRepository.instance.remove(video.id);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await TaskRepository.instance.flush();
      messenger.setMockMethodCallHandler(paths, null);
      StoragePaths.clearRootCache();
      await dir.delete(recursive: true);
    }
  });
}
