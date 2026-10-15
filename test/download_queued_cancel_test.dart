import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/task_repository.dart';

import 'download_cancel_contract_test.dart' show HeldDownload;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'queued canceled HLS clears preexisting parts before settlement',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'video-browser-queued-contract-',
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': dir.path,
      });
      StoragePaths.clearRootCache();
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => dir.path);
      final adapter = HeldDownload();
      final service = DownloadService(
        dio: Dio()..httpClientAdapter = adapter,
        maxConcurrentTasks: 1,
      );
      const first = VideoItem(
        id: 'queued-blocker',
        title: 'Neutral blocker',
        author: 'fixture',
        hlsUrl: 'https://example.invalid/blocker.mp4',
      );
      const queued = VideoItem(
        id: 'queued-hls',
        title: 'Neutral queued',
        author: 'fixture',
        hlsUrl: 'https://example.invalid/queued.m3u8',
      );
      try {
        service.enqueue(first);
        await adapter.started.future.timeout(const Duration(seconds: 5));
        final parts = await StoragePaths.tempDir(queued.id);
        await File('${parts.path}/part_000000.bin').writeAsBytes([1, 2, 3]);
        service.enqueue(queued);
        service.cancel(queued.id);
        adapter.response.complete(HeldDownload.body());
        await service
            .whenTaskSettled(first.id)
            .timeout(const Duration(seconds: 5));
        await service
            .whenTaskSettled(queued.id)
            .timeout(const Duration(seconds: 5));
        expect(
          adapter.requests,
          1,
          reason: 'Canceled queued task must not start network work',
        );
        expect(
          TaskRepository.instance.byId(queued.id)!.status,
          DownloadStatus.canceled,
        );
        expect(
          parts.existsSync(),
          false,
          reason: 'Old parts must be cleaned even before segment setup',
        );
      } finally {
        if (!adapter.response.isCompleted) {
          adapter.response.complete(HeldDownload.body());
        }
        service.onClose();
        await service.whenTaskSettled(first.id);
        await service.whenTaskSettled(queued.id);
        TaskRepository.instance.remove(first.id);
        TaskRepository.instance.remove(queued.id);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await TaskRepository.instance.flush();
        messenger.setMockMethodCallHandler(channel, null);
        StoragePaths.clearRootCache();
        await dir.delete(recursive: true);
      }
    },
  );
}
