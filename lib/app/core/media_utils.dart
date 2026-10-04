import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 原生音视频工具与系统权限桥接。
class MediaUtils {
  const MediaUtils._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.video_browser/media_utils',
  );

  /// Force the activity orientation for fullscreen video playback.
  /// Flutter's allowed-orientation list does not rotate phones whose system
  /// auto-rotate setting is locked, so Android receives a fixed orientation.
  static Future<void> setPlayerOrientation(String orientation) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setPlayerOrientation', {
        'orientation': orientation,
      });
    } catch (e) {
      AppLogger.w('MediaUtils', '设置播放器方向失败: $e');
    }
  }

  /// 检查是否已拥有 Android 11+ 的“所有文件访问权限”（MANAGE_EXTERNAL_STORAGE）。
  static Future<bool> isManageStorageGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isManageStorageGranted');
      return res ?? true;
    } catch (e) {
      AppLogger.w('MediaUtils', '检查 MANAGE_EXTERNAL_STORAGE 失败: $e');
      return true;
    }
  }

  /// 请求/跳转系统“所有文件访问权限”授权设置页。
  static Future<bool> requestManageStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>(
        'requestManageStoragePermission',
      );
      return res ?? false;
    } catch (e) {
      AppLogger.e('MediaUtils', '请求 MANAGE_EXTERNAL_STORAGE 权限失败: $e');
      return false;
    }
  }

  /// 调用 Android 原生 MediaExtractor + MediaMuxer 将 TS 流极速无损重封装为 MP4 容器。
  /// 返回 true 表示封装成功；返回 false 表示封装失败。
  static Future<bool> remuxTsToMp4({
    required String inputPath,
    required String outputPath,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final res = await _channel.invokeMethod<bool>('remuxTsToMp4', {
        'inputPath': inputPath,
        'outputPath': outputPath,
      });
      return res ?? false;
    } catch (e) {
      AppLogger.e('MediaUtils', 'remuxTsToMp4 异常: $e');
      return false;
    }
  }

  /// 通知 Android 系统 MediaStore 扫描新生成的媒体文件，使其立即可在相册和外部播放器中检索。
  static Future<void> scanFile(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('scanFile', {'path': path});
    } catch (e) {
      AppLogger.w('MediaUtils', 'scanFile 异常: $e');
    }
  }
}
