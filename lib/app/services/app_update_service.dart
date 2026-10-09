import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.tagName,
    required this.assetName,
    required this.downloadUrl,
    required this.notes,
  });

  final String version;
  final String tagName;
  final String assetName;
  final String downloadUrl;
  final String notes;
}

/// Checks public GitHub Releases and installs only the APK matching this
/// device's primary Android ABI.
class AppUpdateService extends GetxService {
  static const _channel = MethodChannel(
    'com.example.video_browser/app_updates',
  );
  static const _releaseUrl =
      'https://api.github.com/repos/vialoyed-ctrl/video_browser2/releases/latest';
  static const _lastCheckKey = 'app_update_last_successful_check';
  static const _checkInterval = Duration(hours: 24);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'PlaybackWarehouseApp',
      },
    ),
  );

  final Rxn<AppUpdateInfo> availableUpdate = Rxn<AppUpdateInfo>();
  final RxBool checking = false.obs;
  final RxBool downloading = false.obs;
  final RxDouble downloadProgress = 0.0.obs;
  final RxString currentVersion = ''.obs;
  final RxString status = '启动后会自动检查更新'.obs;
  final RxString downloadedPath = ''.obs;
  final RxString downloadedVersion = ''.obs;
  final Rxn<DateTime> lastCheckedAt = Rxn<DateTime>();

  @override
  void onInit() {
    super.onInit();
    unawaited(_automaticCheck());
  }

  Future<void> _automaticCheck() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    try {
      final preferences = await SharedPreferences.getInstance();
      final previous = preferences.getInt(_lastCheckKey);
      if (previous != null &&
          DateTime.now().difference(
                DateTime.fromMillisecondsSinceEpoch(previous),
              ) <
              _checkInterval) {
        lastCheckedAt.value = DateTime.fromMillisecondsSinceEpoch(previous);
        return;
      }
      await checkForUpdate(manual: false);
    } catch (_) {
      // Automatic checks are best-effort and must not interrupt startup.
    }
  }

  Future<void> checkForUpdate({bool manual = true}) async {
    if (checking.value) return;
    if (!Platform.isAndroid) {
      status.value = '应用内安装更新目前仅支持 Android';
      return;
    }

    checking.value = true;
    status.value = '正在检查 GitHub 上的版本…';
    try {
      final package = await PackageInfo.fromPlatform();
      currentVersion.value = package.version;
      final response = await _dio.get<Object?>(_releaseUrl);
      final data = Map<String, dynamic>.from(response.data! as Map);
      final tagName = (data['tag_name'] as String? ?? '').trim();
      final releaseVersion = _versionFromTag(tagName);
      if (releaseVersion == null) {
        throw const FormatException(
          'GitHub Release tag is not a valid version',
        );
      }

      final isNewer = _compareVersions(releaseVersion, package.version) > 0;
      AppUpdateInfo? foundUpdate;
      if (isNewer) {
        final abis =
            await _channel.invokeListMethod<String>('supportedAbis') ??
            const <String>[];
        final primaryAbi = abis.isEmpty ? null : abis.first;
        final architecture = _architectureFor(primaryAbi);
        if (architecture == null) {
          status.value = '无法识别设备架构，未下载任何安装包';
          availableUpdate.value = null;
          return;
        }

        final assets = (data['assets'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((asset) => Map<String, dynamic>.from(asset))
            .toList(growable: false);
        Map<String, dynamic>? asset;
        for (final candidate in assets) {
          if (_assetMatchesArchitecture(
            candidate['name'] as String? ?? '',
            architecture,
          )) {
            asset = candidate;
            break;
          }
        }
        if (asset == null) {
          status.value =
              '发现版本 $releaseVersion，但 GitHub 暂无 $architecture 对应的 APK';
          availableUpdate.value = null;
          return;
        }

        final downloadUrl = asset['browser_download_url'] as String? ?? '';
        if (downloadUrl.isEmpty) {
          throw const FormatException('GitHub APK download URL is missing');
        }
        foundUpdate = AppUpdateInfo(
          version: releaseVersion,
          tagName: tagName,
          assetName: asset['name'] as String? ?? '',
          downloadUrl: downloadUrl,
          notes: (data['body'] as String? ?? '').trim(),
        );
      }

      availableUpdate.value = foundUpdate;
      final checkedAt = DateTime.now();
      lastCheckedAt.value = checkedAt;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_lastCheckKey, checkedAt.millisecondsSinceEpoch);
      if (foundUpdate == null) {
        status.value = '已是最新版本（v${package.version}）';
        downloadedPath.value = '';
        downloadedVersion.value = '';
      } else {
        if (downloadedVersion.value != foundUpdate.version) {
          downloadedPath.value = '';
          downloadedVersion.value = '';
        }
        status.value = '发现新版本 v${foundUpdate.version}';
      }
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      status.value = code == 403 ? 'GitHub 暂时限制了版本查询，请稍后重试' : '检查更新失败，请检查网络后重试';
      if (manual) rethrow;
    } catch (_) {
      status.value = '检查更新失败，请稍后重试';
      if (manual) rethrow;
    } finally {
      checking.value = false;
    }
  }

  Future<void> downloadAndInstall() async {
    final update = availableUpdate.value;
    if (update == null || downloading.value) return;

    try {
      var filePath = downloadedPath.value;
      if (downloadedVersion.value != update.version ||
          filePath.isEmpty ||
          !await File(filePath).exists()) {
        filePath = await _downloadUpdate(update);
      }
      final canInstall =
          await _channel.invokeMethod<bool>('canInstallUnknownApps') ?? false;
      if (!canInstall) {
        await _channel.invokeMethod<bool>('requestInstallPermission');
        status.value = '请在系统设置中允许安装此应用，返回后再次点击“立即更新”';
        return;
      }

      await _channel.invokeMethod<bool>('installApk', <String, Object>{
        'path': filePath,
      });
      status.value = '已打开系统安装程序，请确认安装';
    } catch (_) {
      status.value = '下载或启动安装失败，请重试';
    }
  }

  Future<String> _downloadUpdate(AppUpdateInfo update) async {
    downloading.value = true;
    downloadProgress.value = 0;
    status.value = '正在下载 ${update.assetName}';
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final updateDirectory = Directory(
        p.join(supportDirectory.path, 'updates'),
      );
      await updateDirectory.create(recursive: true);
      final safeVersion = update.version.replaceAll(
        RegExp(r'[^0-9A-Za-z._-]'),
        '_',
      );
      final targetPath = p.join(
        updateDirectory.path,
        'update-$safeVersion.apk',
      );
      final partialPath = '$targetPath.part';
      final partialFile = File(partialPath);
      if (await partialFile.exists()) await partialFile.delete();
      await _dio.download(
        update.downloadUrl,
        partialPath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total > 0) downloadProgress.value = received / total;
        },
      );

      final bytes = await partialFile
          .openRead(0, 4)
          .fold<List<int>>(
            <int>[],
            (previous, chunk) => previous..addAll(chunk),
          );
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4b ||
          bytes[2] != 0x03 ||
          bytes[3] != 0x04) {
        await partialFile.delete().catchError((_) => partialFile);
        throw const FormatException('Downloaded file is not a valid APK');
      }

      final targetFile = File(targetPath);
      if (await targetFile.exists()) await targetFile.delete();
      final installedFile = await partialFile.rename(targetPath);
      downloadedPath.value = installedFile.path;
      downloadedVersion.value = update.version;
      status.value = '下载完成，正在打开系统安装程序…';
      return installedFile.path;
    } finally {
      downloading.value = false;
    }
  }

  static String? _versionFromTag(String tag) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$',
      caseSensitive: false,
    ).firstMatch(tag);
    if (match == null) return null;
    return '${match[1]}.${match[2]}.${match[3]}';
  }

  static int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList();
    final rightParts = right.split('.').map(int.parse).toList();
    for (var index = 0; index < 3; index++) {
      final comparison = leftParts[index].compareTo(rightParts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static String? _architectureFor(String? abi) {
    if (abi == null) return null;
    return switch (abi.toLowerCase()) {
      'arm64-v8a' => 'arm64',
      'armeabi-v7a' || 'armeabi' => 'arm32',
      'x86_64' => 'x86_64',
      'x86' => 'x86',
      _ => null,
    };
  }

  static bool _assetMatchesArchitecture(String name, String architecture) {
    final normalized = name.toLowerCase();
    if (!normalized.endsWith('.apk')) return false;
    final patterns = switch (architecture) {
      'arm64' => <RegExp>[
        RegExp(r'(^|[^a-z0-9])arm64(?:-v8a)?([^a-z0-9]|$)'),
        RegExp(r'(^|[^a-z0-9])aarch64([^a-z0-9]|$)'),
        RegExp(r'(^|[^a-z0-9])64bit([^a-z0-9]|$)'),
      ],
      'arm32' => <RegExp>[
        RegExp(r'(^|[^a-z0-9])armeabi-v7a([^a-z0-9]|$)'),
        RegExp(r'(^|[^a-z0-9])arm32([^a-z0-9]|$)'),
        RegExp(r'(^|[^a-z0-9])armv7([^a-z0-9]|$)'),
        RegExp(r'(^|[^a-z0-9])32bit([^a-z0-9]|$)'),
      ],
      'x86_64' => <RegExp>[RegExp(r'(^|[^a-z0-9])x86_64([^a-z0-9]|$)')],
      'x86' => <RegExp>[RegExp(r'(^|[^a-z0-9])x86([^a-z0-9_]|$)')],
      _ => const <RegExp>[],
    };
    return patterns.any((pattern) => pattern.hasMatch(normalized));
  }
}
