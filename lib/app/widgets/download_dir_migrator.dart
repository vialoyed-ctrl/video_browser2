import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';

import '../core/app_theme.dart';

import 'package:get/get.dart';

import '../services/download_service.dart';
import '../services/task_repository.dart';

import 'dart:io';

import '../core/media_utils.dart';
import 'app_toast.dart';

/// 下载目录选择与全量迁移辅助类。
class DownloadDirMigrator {
  const DownloadDirMigrator._();

  static Future<void> selectAndMigrate(
    BuildContext context, {
    VoidCallback? onDone,
  }) async {
    try {
      final oldRoot = await StoragePaths.root();
      final currentCustom = await StoragePaths.getCustomPath();

      final selectedPath = await file_picker.FilePicker.getDirectoryPath(
        dialogTitle: '选择新的下载文件夹',
      );

      if (selectedPath == null || selectedPath.isEmpty) {
        return;
      }

      // 如果选中的是外部公共存储空间，检查并请求“所有文件访问权限”
      if (Platform.isAndroid &&
          (selectedPath.startsWith('/storage/emulated/0') ||
              selectedPath.startsWith('/sdcard') ||
              selectedPath.startsWith('/storage/'))) {
        final granted = await MediaUtils.isManageStorageGranted();
        if (!granted) {
          final toSettings = await Get.dialog<bool>(
            AlertDialog(
              title: const Text('需要所有文件访问权限'),
              content: const Text(
                '移动到手机公共存储空间需要开启“所有文件访问权限”，否则 Android 系统将阻止写入。\n\n'
                '点击“去开启”后，请在系统设置中允许权限，再返回应用继续操作。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Get.back<bool>(result: false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Get.back<bool>(result: true),
                  child: const Text('去开启'),
                ),
              ],
            ),
          );
          if (toSettings == true) {
            await MediaUtils.requestManageStoragePermission();
          }
          return;
        }
      }

      if (selectedPath == oldRoot.path ||
          (currentCustom != null && selectedPath == currentCustom)) {
        AppToast.show('新目录与当前目录相同，无需迁移');
        return;
      }

      if (!context.mounted) return;
      // 弹出迁移确认弹窗
      final confirm = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('移动下载文件夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '确认要将下载目录迁移到新位置吗？',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                '原目录：\n${oldRoot.path}',
                style: TextStyle(fontSize: 12, color: context.cTextSub),
              ),
              const SizedBox(height: 8),
              Text(
                '新目录：\n$selectedPath',
                style: TextStyle(fontSize: 12, color: context.cAccent),
              ),
              const SizedBox(height: 12),
              const Text(
                '迁移后：\n1. 已下载的视频文件将自动移动到新目录。\n2. 下载管理信息与视频保存路径将同步更新。',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back<bool>(result: false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Get.back<bool>(result: true),
              child: const Text('确认移动'),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      // 弹出进度弹窗
      final progressMsg = '正在迁移文件，请稍候...'.obs;

      Get.dialog<void>(
        PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在移动下载文件夹'),
            content: Obx(
              () => Row(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      progressMsg.value,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        barrierDismissible: false,
      );

      final count = await StoragePaths.migrateTo(
        selectedPath,
        onProgress: (msg) {
          progressMsg.value = msg;
        },
      );

      // 关闭进度弹窗
      if (Get.isDialogOpen == true) {
        Get.back<void>();
      }

      // 同步 DownloadService 界面数据
      if (Get.isRegistered<DownloadService>()) {
        Get.find<DownloadService>().syncFromRepository();
      }

      AppToast.show('下载目录迁移成功！已同步更新 $count 个视频路径');
      onDone?.call();
    } catch (e) {
      if (Get.isDialogOpen == true) {
        Get.back<void>();
      }
      AppToast.show('迁移失败：$e');
    }
  }
}
