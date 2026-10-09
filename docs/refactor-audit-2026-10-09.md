# Flutter 视频浏览器：安全重构审计与第 1 阶段记录

日期：2026-10-09
项目：`E:\projects\video_browser2`
目标：业务功能与用户可观察行为不变；逐步统一架构、UI 状态订阅与播放器生命周期，改善流畅性。

## 一、项目现状（真实检查）
- Flutter / Dart / GetX；版本 `2.0.2+3`，Dio 网络层。
- `lib` 有 102 个 Dart 文件；变更前 `test` 有 28 个 Dart 测试文件。
- 已有 `core / data / modules / services / widgets / routes` 分层，并非需要重新设计整个目录。
- 播放器使用 `video_player`，Android 的 `third_party/video_player_android` 已做 Media3 / ExoPlayer 定制；Android 与非 Android 的 HLS、MP4 缓存/代理路径不同。不得盲目替换播放器或统一为单一代理。
- 较大的模块包括站点数据源、`player_controller.dart`、`player_view.dart` 与 `preload_service.dart`；仅凭文件长度不足以证明要拆分。
- 本目录**不是 Git 仓库**；为避免误伤，未擅自执行 `git init` 或提交项目文件。
- 独立快照：`E:\projects\_video_browser2_refactor_backup_20261009`；包含 `lib / test / integration_test / third_party / android / pubspec.* / analysis_options.yaml`。

## 二、重构前基线
- `flutter analyze lib test --no-pub`：0 error、0 warning，7 条测试代码的 `avoid_print` info。由于 info，分析命令报告 7 issues，不能写成零问题。
- `flutter test --no-pub --reporter expanded`：140 个通过，1 个跳过。
- Windows 远程会话缺少 `ProgramFiles(x86)` 环境变量。运行测试前需在当次 PowerShell 进程执行：
  `Set-Item -Path 'Env:ProgramFiles(x86)' -Value 'C:\Program Files (x86)'`。
  这只是进程环境修复，不写项目配置、不改系统永久环境变量。
- 连接手机：`PMB110`，Android 16 (API 36)。通过 adb 读取**设备已安装版本**的 gfxinfo：采样窗口总帧 191，janky 29（15.18%），P50 5ms、P90 73ms、P95 125ms、P99 200ms。这只是单次设备快照，未说明前台场景，不能当作新代码的性能提升对比。

## 三、本次实现：下载角标的细粒度状态订阅
发现：`home_view.dart` 首页下载角标使用 `Obx` 观察整个 `DownloadService.tasks`；进度同步会通过 `tasks.assignAll` 反复通知，哪怕活跃任务数未变，角标仍重复构建。

修改：
1. `lib/app/services/download_service.dart` 新增 `activeTaskCount`（RxInt），每次同步任务列表时计算活跃数量，**仅数量变化时通知**；原 `tasks.assignAll` 保留，下载管理页的进度更新方式不变。
2. `lib/app/modules/home/home_view.dart` 下载角标改为观察 `activeTaskCount.value`。
3. `test/download_badge_count_test.dart` 新增回归测试，验证 pending → 进度更新 → completed 期间角标只在数量变化时通知，并验证任务列表仍有正确的完成状态。

测试驱动过程：新增测试后预期失败（缺少 `activeTaskCount`），实现后单测通过。通过备份对比，生产逻辑改动仅涉及以上两处代码路径。

## 四、变更后验证
- 新增定向测试：通过。
- 完整测试：141 个通过，1 个跳过，未引入失败。
- `flutter analyze lib test --no-pub`：与基线一致，仍为 7 条 `avoid_print` info，0 error、0 warning。
- 未修改网站抓取与解析、下载并发调度、播放内核、预取协议或缓存键。
- **尚未**使用新代码重新构建并安装 Android APK、执行真机播放全链路回归或获取改动后的 Profile 帧数据；因此不宣称用户可感知的流畅度已经得到量化提升。

## 五、下一步按风险分层推进
1. **建立正式 Git 版本历史**：先核对 `.gitignore` 和敏感文件、调试产物、APK，不直接将当前项目所有内容提交。保留独立快照。
2. **UI 性能测量**：Profile 模式对首页、搜索、列表、抽屉、详情页分别记录 Build/Raster Frame、P90/P95、卡顿帧与内存。定位何种 Rx / 频繁复制列表造成刷新，再做局部改动。
3. **统一 UI 构件与模块接口**：优先检查公共卡片、加载/错误/空状态、分页、主题及可复用接口，按原视觉与交互契约逐一迁移；禁止同时改主题和业务数据源。
4. **播放器生命周期审计**：先建立控制器预热、接管、释放、切源、后台/前台、全屏切换、倍速与拖动的状态机测试。随后审视 Native Media3 / Dart 代理差异和异步竞态，先测试再更改。
5. **端到端真机回归**：分别验证每个内容源的搜索/列表/详情/播放/缓存/下载/登录（若适用），比较网络和播放器行为，记录 UI 帧、起播延迟、缓冲耗时及内存。不能只靠单元测试断言功能完全等价。

## 六、回滚方式
- **不要整目录覆盖**，先对照已修改的文件。
- 源代码回滚可将快照中的：
  - `lib/app/services/download_service.dart`
  - `lib/app/modules/home/home_view.dart`
  恢复到原路径，并移除本次新增的 `test/download_badge_count_test.dart`。
- 其他源码和原生播放实现应保持不动。
