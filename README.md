# 播放仓库

<img src="assets/branding/app-icon.png" width="120" alt="播放仓库图标" />

一款简洁的视频播放应用，支持清晰度选择、播放控制、缓存与下载。

## 功能

- 视频浏览与关键词搜索。
- 清晰度选择、倍速播放、进度拖动。
- 亮度与音量手势调节。
- 视频缓存、下载队列与断点续传。
- 收藏、片单及播放记录管理。
- 明暗主题、下拉刷新与分页。

## 下载

在本仓库的 Releases 页面下载 APK。普通 64 位 Android 手机选择 `playback-warehouse-arm64.apk`，旧款 32 位设备选择 `playback-warehouse-arm32.apk`。

## 开发

安装兼容 `pubspec.yaml` 的 Flutter SDK、Android SDK 和 JDK：

```sh
flutter pub get
flutter analyze lib
flutter test
```

项目使用本地播放器依赖，需保留 `third_party/video_player_android` 目录。第三方许可与作者署名保留在依赖目录中。

## 编译

Windows 运行根目录 `build_apk.bat`。首次使用时请按本机环境调整脚本中的 JDK 路径，并将 Flutter 添加到 PATH。

安装包输出到 `build/app/outputs/flutter-apk/`。

当前构建使用开发签名配置；配置自己的发行签名时，请勿将密钥或密码提交到仓库。

## 隐私

仓库不包含账号凭据、本机会话、手机截图、调试日志或缓存。需要账号的集成测试通过环境变量读取凭据，未配置时自动跳过。
