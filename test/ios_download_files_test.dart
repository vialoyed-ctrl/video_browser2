import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_browser/app/services/ios_download_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    're-signing restores nested downloads into the new Documents container',
    () {
      const current = '/var/mobile/Containers/Data/Application/NEW/Documents';
      expect(
        rebaseIosDocumentPath(
          '/var/mobile/Containers/Data/Application/OLD/Documents/video_browser/作者/video.mp4',
          current,
        ),
        p.posix.join(current, 'video_browser', '作者', 'video.mp4'),
      );
      expect(rebaseIosDocumentPath('/tmp/video.mp4', current), isNull);
      expect(
        rebaseIosDocumentPath('/old/Documents/../../outside.mp4', current),
        isNull,
      );
    },
  );

  test('valid MP4 is opened unchanged and disguised TS is remuxed without deleting the source', () async {
    final dir = await Directory.systemTemp.createTemp('ios-download-test');
    const channel = MethodChannel('com.example.video_browser/media_utils');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'remuxTsToMp4') {
            await File(call.arguments['outputPath'] as String)
                .writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
            return true;
          }
          return null;
        });
    try {
      final mp4 = File(p.join(dir.path, 'valid.mp4'));
      await mp4.writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
      expect(await IosDownloadFiles.prepareVideo(mp4.path), mp4.path);
      expect(calls, isEmpty);
      final ts = File(p.join(dir.path, 'old.mp4'));
      final bytes = List<int>.filled(377, 0);
      bytes[0] = bytes[188] = bytes[376] = 0x47;
      await ts.writeAsBytes(bytes);
      final repaired = await IosDownloadFiles.prepareVideo(ts.path);
      expect(await ts.readAsBytes(), bytes);
      expect(await File(repaired).exists(), isTrue);
      await IosDownloadFiles.open(repaired);
      await IosDownloadFiles.export(repaired);
      expect(calls.map((c) => c.method), [
        'remuxTsToMp4',
        'openDownloadedVideo',
        'exportDownloadedVideo',
      ]);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    }
  });
}
