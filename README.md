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

在 [Releases](https://github.com/vialoyed-ctrl/video_browser2/releases) 下载最新 APK。当前版本提供 `playback-warehouse-arm64.apk`，适用于 ARM64 Android 手机和平板；旧款32位设备请查看此前提供 ARM32 包的历史版本。

## v2.0.4 更新

- 更新查询支持公开版本文件备用路径，解决GitHub API限流或连接失败时无法发现新版本。
- [v2.0.4发布说明](docs/releases/v2.0.4.md)。

## v2.0.3 更新

- 公共抽屉和“我的”新增卡片布局：自动适配或1–6列，各页面共用，立即生效并保存。
- 新订阅作者置顶，统一平板和分栏网格宽度、宽屏侧栏导航。
- 公共分页和UI局部订阅整理；修复站点导航、播放器异步释放/拖动边界、预加载和下载取消重试。
- 完整说明与已知验收限制见 [发布说明](docs/releases/v2.0.3.md)；测试证据和回滚记录保留在 `docs/`。

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
