# 播放仓库

Flutter Android 视频浏览、播放与下载应用，包含 91、Hanime1 和 PornHub 三个独立内容模块。

## 功能

- 视频浏览、搜索、筛选、刷新与分页。
- 视频播放、画质选择、倍速、进度及亮度/音量手势。
- 下载队列、缓存、断点续传与任务管理。
- 支持对应内容源的账号登录、订阅、收藏、历史与片单。
- PornHub 创作者个人页、切片、分类/标签，以及相关、推荐、评论和片单面板。
- Material 3 明暗主题与统一滚动交互。

各内容源的功能随官网可用接口和账号权限而变化。

## 开发与测试

安装与 `pubspec.yaml` 相容的 Flutter SDK、Android SDK 和 JDK，然后运行：

```sh
flutter pub get
flutter analyze lib
flutter test
```

项目使用 `third_party/video_player_android` 中的本地播放器插件，必须一起保留。第三方许可和作者署名位于对应依赖目录。

## Android 编译

Windows 使用项目根目录的 `build_apk.bat`。脚本优先查找 PATH 中的 Flutter；JDK 路径由脚本中的 `JAVA_HOME` 设置，首次使用请按本机环境调整。

64 位安装包位于 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，脚本同时复制为 `vb_base_64bit.apk`。

当前 release 构建使用 Android debug 签名配置；正式发行时应配置自己的签名，签名文件与密码不提交到仓库。

## 隐私处理

- 不包含真实账号密码、登录 Cookie、抓取的账号页面或本机配置。
- 不包含手机截图、调试日志、缓存、安装包与历史源码备份。
- 账号测试样例已匿名化。真实登录集成测试通过环境变量 `HANIME1_TEST_EMAIL` 和 `HANIME1_TEST_PASSWORD` 读取凭据，未设置时跳过。
- 登录日志不输出邮箱、用户名或用户编号。
