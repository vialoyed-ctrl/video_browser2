import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// iOS app-container IDs can change when the app is re-signed and updated.
/// Recover only paths within Documents; never import another absolute path.
String? rebaseIosDocumentPath(String savedPath, String documentsPath) {
  const marker = '/Documents/';
  final index = savedPath.indexOf(marker);
  if (index < 0) return null;
  final relative = savedPath.substring(index + marker.length);
  if (relative.isEmpty) return null;
  final result = p.posix.normalize(p.posix.join(documentsPath, relative));
  return p.posix.isWithin(documentsPath, result) ? result : null;
}

class IosDownloadFiles {
  const IosDownloadFiles._();
  static const _channel = MethodChannel(
    'com.example.video_browser/media_utils',
  );

  static Future<String?> resolve(String savedPath) async {
    if (await File(savedPath).exists()) return savedPath;
    final docs = await getApplicationDocumentsDirectory();
    final rebased = rebaseIosDocumentPath(savedPath, docs.path);
    if (rebased != null && await File(rebased).exists()) return rebased;
    return null;
  }

  /// Older versions could save a failed MPEG-TS remux under an MP4 suffix.
  /// Preserve that original and create a real MP4 beside it on first open.
  static Future<String> prepareVideo(String path) async {
    final source = File(path);
    final input = await source.open();
    late List<int> header;
    try {
      header = await input.read(377);
    } finally {
      await input.close();
    }
    final isTs =
        header.length >= 377 &&
        header[0] == 0x47 &&
        header[188] == 0x47 &&
        header[376] == 0x47;
    if (!isTs) return path;
    final output = '${p.withoutExtension(path)}.repaired.mp4';
    if (await _channel.invokeMethod<bool>('remuxTsToMp4', {
          'inputPath': path,
          'outputPath': output,
        }) !=
        true) {
      throw const FileSystemException('视频转封装失败，请重试下载');
    }
    return output;
  }

  static Future<void> open(String path) =>
      _channel.invokeMethod<void>('openDownloadedVideo', {'path': path});

  static Future<void> export(String path) =>
      _channel.invokeMethod<void>('exportDownloadedVideo', {'path': path});
}
