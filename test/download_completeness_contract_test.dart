import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/download_service.dart';
import 'package:video_browser/app/services/task_repository.dart';

class CompletenessAdapter implements HttpClientAdapter {
  CompletenessAdapter(this.mode);
  final String mode;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? request,
    Future<void>? cancellation,
  ) async {
    final bytes = Uint8List.fromList([0, 0, 0, 8, 102, 116, 121, 112]);
    if (mode == 'partialError') {
      return ResponseBody(
        Stream<Uint8List>.multi((c) {
          c.add(bytes);
          c.addError(StateError('neutral partial stream error'));
          c.close();
        }),
        200,
        headers: {
          Headers.contentLengthHeader: ['16'],
        },
      );
    }
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: mode == 'unknownLength'
          ? {}
          : {
              Headers.contentLengthHeader: ['16'],
            },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['truncatedClean', 'partialError', 'unknownLength']) {
    test('MP4 completion boundary $mode', () async {
      final dir = await Directory.systemTemp.createTemp(
        'video-browser-completeness-',
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': dir.path,
      });
      StoragePaths.clearRootCache();
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (call) async => dir.path);
      final service = DownloadService(
        dio: Dio()..httpClientAdapter = CompletenessAdapter(mode),
      );
      final item = VideoItem(
        id: 'completeness-$mode',
        title: 'Neutral completeness fixture',
        author: 'fixture',
        hlsUrl: 'https://example.invalid/neutral.mp4',
      );
      try {
        final task = service.enqueue(item);
        await service
            .whenTaskSettled(task.id)
            .timeout(const Duration(seconds: 5));
        if (mode == 'unknownLength') {
          expect(task.status, DownloadStatus.completed);
          expect(await File(task.outputPath!).readAsBytes(), [
            0,
            0,
            0,
            8,
            102,
            116,
            121,
            112,
          ]);
        } else {
          expect(
            task.status,
            DownloadStatus.failed,
            reason: 'Incomplete content cannot be presented as a completed download',
          );
          expect(
            dir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.mp4')),
            isEmpty,
          );
        }
      } finally {
        service.onClose();
        await service.whenTaskSettled(item.id);
        TaskRepository.instance.remove(item.id);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await TaskRepository.instance.flush();
        messenger.setMockMethodCallHandler(paths, null);
        StoragePaths.clearRootCache();
        await dir.delete(recursive: true);
      }
    });
  }
}
