import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/task_repository.dart';

class HeldDownload implements HttpClientAdapter {
  int requests = 0;
  final started = Completer<void>();
  final secondStarted = Completer<void>();
  final response = Completer<ResponseBody>();
  static ResponseBody body() => ResponseBody.fromBytes(
    [0, 0, 0, 8, 102, 116, 121, 112],
    200,
    headers: {
      Headers.contentLengthHeader: ['8'],
    },
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests++;
    if (requests > 1) {
      if (!secondStarted.isCompleted) secondStarted.complete();
      return Future.value(body());
    }
    started.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

class HeldHlsDownload extends HeldDownload {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) {
    if (options.uri.path.endsWith('.m3u8')) {
      return Future.value(
        ResponseBody.fromString(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\npart.m4s\n#EXT-X-ENDLIST\n',
          200,
        ),
      );
    }
    return super.fetch(options, stream, cancellation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'cancel',
    'retry',
    'remove',
    'hlsCancel',
    'hlsSuccess',
    'lateFailure',
    'reenqueue',
    'parallelCancel',
  ]) {
    test('$mode isolates a late MP4 reply and settles file work', () async {
      final dir = await Directory.systemTemp.createTemp(
        'video-browser-cancel-contract-',
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': dir.path,
      });
      StoragePaths.clearRootCache();
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (call) async => dir.path);
      final adapter = mode.startsWith('hls')
          ? HeldHlsDownload()
          : HeldDownload();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = DownloadService(dio: dio);
      final video = VideoItem(
        id: '$mode-mp4-fixture',
        title: 'Neutral cancellation fixture',
        author: 'fixture',
        hlsUrl: mode.startsWith('hls')
            ? 'https://example.invalid/neutral.m3u8'
            : 'https://example.invalid/neutral.mp4',
      );
      try {
        final task = service.enqueue(video);
        await adapter.started.future.timeout(const Duration(seconds: 5));
        if (mode == 'remove' || mode == 'reenqueue') {
          service.remove(task.id);
          expect(TaskRepository.instance.byId(task.id), isNull);
          if (mode == 'reenqueue') {
            service.enqueue(video.copyWith(title: 'Replacement fixture'));
          }
        } else if (mode != 'hlsSuccess') {
          if (mode == 'parallelCancel') {
            service.enqueue(
              video.copyWith(
                id: '${video.id}-other',
                title: 'Parallel fixture',
              ),
            );
            await adapter.secondStarted.future.timeout(
              const Duration(seconds: 5),
            );
          }
          service.cancel(task.id);
          expect(
            TaskRepository.instance.byId(task.id)!.status,
            DownloadStatus.canceled,
          );
        }
        final retry = mode == 'retry' ? service.retry(task.id) : null;
        if (mode == 'lateFailure') {
          adapter.response.completeError(
            DioException(requestOptions: RequestOptions(path: video.hlsUrl)),
          );
        } else {
          adapter.response.complete(HeldDownload.body());
        }
        if (retry != null) await retry.timeout(const Duration(seconds: 5));
        if (mode == 'reenqueue') {
          await adapter.secondStarted.future.timeout(
            const Duration(seconds: 5),
          );
        }
        await service
            .whenTaskSettled(task.id)
            .timeout(const Duration(seconds: 5));
        if (mode == 'remove') {
          expect(TaskRepository.instance.byId(task.id), isNull);
        } else if ([
          'cancel',
          'hlsCancel',
          'lateFailure',
          'parallelCancel',
        ].contains(mode)) {
          expect(
            TaskRepository.instance.byId(task.id)!.status,
            DownloadStatus.canceled,
          );
          if (mode == 'parallelCancel') {
            await service
                .whenTaskSettled('${video.id}-other')
                .timeout(const Duration(seconds: 5));
            expect(
              TaskRepository.instance.byId('${video.id}-other')!.status,
              DownloadStatus.completed,
            );
          }
          if (mode == 'hlsCancel') {
            final canceledParts = Directory(
              '${dir.path}${Platform.pathSeparator}video_parts${Platform.pathSeparator}${task.id}',
            );
            expect(
              canceledParts.existsSync(),
              false,
              reason: 'Canceled HLS must finish part cleanup before settlement',
            );
          }
        } else {
          expect(adapter.requests, 2);
          final completed = TaskRepository.instance.byId(task.id)!;
          expect(completed.status, DownloadStatus.completed);
          const part = [0, 0, 0, 8, 102, 116, 121, 112];
          expect(
            await File(completed.outputPath!).readAsBytes(),
            mode == 'hlsSuccess' ? [...part, ...part] : part,
          );
        }
      } finally {
        if (!adapter.response.isCompleted) {
          adapter.response.complete(HeldDownload.body());
        }
        service.onClose();
        await service
            .whenTaskSettled(video.id)
            .timeout(const Duration(seconds: 5));
        TaskRepository.instance.remove(video.id);
        TaskRepository.instance.remove('${video.id}-other');
        // Allow the repository's 400ms persistence debounce to finish before
        // deleting the isolated fixture directory (not a behavior assertion).
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await TaskRepository.instance.flush();
        messenger.setMockMethodCallHandler(paths, null);
        StoragePaths.clearRootCache();
        await dir.delete(recursive: true);
      }
    });
  }
}
