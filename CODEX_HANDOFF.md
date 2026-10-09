# Codex 接手说明：video_browser2 功能保持型重构

> 交接日期：2026-10-09。请先阅读本文件和 `docs/refactor-audit-2026-10-09.md`，然后检查源码及测试；不要一上来重写项目。

## 0. 任务与不可变约束
- 项目：`E:\projects\video_browser2`（Flutter / Dart / GetX，版本 2.0.2+3）。
- 最终目标：统一模块架构、UI 组件与状态管理；改善 UI 和播放器流畅度；**保持当前全部功能、交互、解析结果及播放行为**。
- 不删除或替换 91、91麻豆、hanime1、PornHub 站点模块；不得未经测试修改网站解析规则、用户认证、路由、下载、收藏、历史、缓存、预取、视频嗅探、倍速、进度拖动、全屏、亮度/音量手势等功能。
- Android 已定制 `third_party/video_player_android`（Media3 / ExoPlayer）；Flutter 使用 `video_player`。Android 原生磁盘缓存与非 Android Dart HLS/MP4 回环代理是**两条不同路径**，严禁因“统一”而直接合并或替换。
- 只做行为可验证的渐进式重构。发现疑似重复代码时先确认业务差异，避免为了减少文件数量而删除契约实现。
- 不能把“单元测试通过”或“静态检查通过”视为完整功能等价；真机验证必须单独开展。

## 1. 当前已完成（不要重复做）
1. 已检查项目分层：`lib/app/core`, `data`, `modules`, `services`, `widgets`, `routes`；项目 `lib` 有 102 个 Dart 文件，原有 `test` 下 28 个测试文件。
2. 已创建**独立源码快照**：`E:\projects\_video_browser2_refactor_backup_20261009`，含 `lib`, `test`, `integration_test`, `third_party`, `android`, `pubspec.*`, `analysis_options.yaml`。
3. 修改前 `flutter test --no-pub --reporter expanded`：140 通过、1 跳过。
4. 修改后完整 `flutter test --no-pub --reporter compact`：141 通过、1 跳过；新增单测也已独立通过。
5. `flutter analyze lib test --no-pub`：修改前后均无 error / warning，仅 `test/hanime1_integration_test.dart` 中原有 7 条 `avoid_print` info（该命令可能因此返回非 0，**不要误判为新回归**）。
6. 已检查手机 `PMB110`，Android 16，设备 id `BUPR8HWKLZTCHAPN`。一次已安装旧版本 gfxinfo 样本：191 帧、29 卡顿帧（15.18%），P50 5ms / P90 73ms / P95 125ms / P99 200ms。**这不是新代码的性能结果**。

## 2. 唯一已实施的生产代码优化
- `lib/app/services/download_service.dart`：新增 `RxInt activeTaskCount = 0.obs`，在 `init` 和 `syncFromRepository()` 经过 `_publishTasks()` 更新，仅活跃任务数变化时通知该字段，原有 `tasks.assignAll(latest)` 行为保留。
- `lib/app/modules/home/home_view.dart`：首页下载角标从订阅整个 `tasks` 列表改为订阅 `activeTaskCount.value`，避免进度事件在角标数字不变时触发重建。
- `test/download_badge_count_test.dart`（新增）：验证任务从 pending 到下载进度更新再到 completed 的计数通知以及任务列表状态。
- 先编写测试并验证其因新属性缺失而失败，实施后单测/全测通过。
- 与源码快照目录做递归 `git diff --no-index --name-only` 校验：`lib/` **仅**上述两处生产文件不同；`test/` **仅**上述新增测试文件不同。
- 未修改任何站点数据源、播放器控制器、播放器服务、Media3 原生代码、下载任务调度、HLS/MP4 代理或缓存键。

## 3. 目前尚未完成（Codex 后续工作）
- 尚未建立 Git 仓库／分支历史：项目根目录当时 `git status` 返回 `not a git repository`。请先审阅 `.gitignore`、APK、日志、设备截屏、凭据、缓存与 `lib - 副本` 等目录，建立干净的版本控制/回滚基线；**不要盲目 `git add .`**，也不要覆盖原始快照。
- 尚未在修改后构建 Android APK 或安装至手机；不要称本次修改已在手机上验证。
- 尚未做 Flutter Profile 模式 UI 帧耗时、内存、播放器首帧/seek/缓冲对比；不要声称流畅度已量化提升。
- 尚未实施跨站点模块接口统一、公共 Widget 统一、播放器生命周期重构。

## 4. 建议的下一步执行顺序（每步单独提交与验证）
### P0：建立可回滚的仓库状态与验收基线
1. 先核对本交接文件所记载的修改与当前工作区（可能已有用户后来改动）。避免覆盖外部新修改。
2. 核对 `.gitignore`，确保不提交用户隐私/账号凭据、缓存、日志、截图、APK、大型产物和本地副本。按需创建安全的版本库或独立工作分支。
3. 再执行静态检查、完整测试及针对播放/缓存/站点的必要契约测试；保存命令输出。

### P1：测量 UI 卡顿，选择局部、可证的优化
1. 在 Android 真机 **Profile 模式**复现：首页网格滚动、搜索输入、分页、切换站点、抽屉、播放页进入和退出。
2. 使用 Flutter DevTools Frame chart / rebuild profiling / memory，以及 Android gfxinfo/Perfetto，区分 build/raster/UI isolate/原生视频帧问题。
3. 优先研究 GetX `Obx` 订阅粒度、图片解码尺寸、重复列表复制、分页 sliver、动画与耗时同步任务。对每处优化先加防回归测试，避免改变封面清晰度或界面行为。
4. 小批量迁移可证明等价的共用 UI 组件，不要一次性抽离所有列表或全局替换状态管理框架。

### P2：播放器状态机和原生流畅度
1. 建立播放器生命周期契约：preOpen、预热接管、取消与释放、快速切源、应用后台前台、横竖屏、倍速、Seek 拖动、亮度/音量手势。
2. 审计 `player_service.dart`、`player_controller.dart`、`player_view.dart`、`preload_service.dart` 及 Android Media3 原生实现，找出控制器/事件监听生命周期与异步竞态。
3. 按各站点类型分开测量：HLS、MP4、缓存冷/热起播、缓冲重试、并发预取。保持缓存键、请求头、Referer、Cookie 与解码器行为，不得因优化绕开已有缓存。
4. 如实记录每次修改前后 Profile 与真机播放验收数据，指标未改善或功能变更就回滚。

### P3：全面回归与交付
- 分别测试 91 / 91麻豆 / hanime1 / PornHub 的首页、搜索、分页、详情、播放、域名设置/登录（若适用）、收藏、历史、下载、缓存。
- 至少对一个 HLS 流和一个 MP4 流实测首帧、Seek、切视频、播放结束/退出、弱网缓冲；检查资源释放和内存。
- 每阶段输出：修改文件、变更原因、测试/构建结果、性能证据、风险与回滚方法。不得只写“优化完成”。

## 5. 本机工具链与命令
- Flutter：`D:\flutter\bin\flutter.bat`；Dart：`D:\flutter\bin\dart.bat`；Android SDK：`E:\AndroidSDK`。
- Windows 远程会话运行 Flutter 测试时可在**当前 PowerShell 进程**临时设置：
  `Set-Item -Path 'Env:ProgramFiles(x86)' -Value 'C:\Program Files (x86)'`。
- 进入项目：`Set-Location 'E:\projects\video_browser2'`。
- 执行全测：`& 'D:\flutter\bin\flutter.bat' test --no-pub --reporter compact`。
- 执行静态检查：`& 'D:\flutter\bin\flutter.bat' analyze lib test --no-pub`（注意原有 7 条 info）。
- Android 真机标识：`BUPR8HWKLZTCHAPN`，运行涉及手机安装/设备数据的命令前先确认不要破坏已安装数据，不清除 app data。

## 6. 现有其他文档及回滚
- 初步审计：`docs/refactor-audit-2026-10-09.md`。
- 过往优化报告：`代码优化报告_2026-09-30.md`（针对其他副本，属于历史材料，不能当作本目录已经完成的改动）。
- 相关播放器延迟评估：`docs/video-latency-optimization.md`（历史设计与测试记录，必须复核当前源码）。
- 单独恢复本轮优化：从快照还原 `lib/app/services/download_service.dart` 与 `lib/app/modules/home/home_view.dart`，删除新增 `test/download_badge_count_test.dart`；不要全目录覆盖。

## 7. 你收到本交接后立即执行的动作
1. 阅读本文件与审计文档。
2. 比对当前工作区与快照，保留全部用户后续改动；检查环境及 Git 状态。
3. 输出下一批**可量化、可单独回滚**的 UI/播放器优化清单和测试计划。
4. 从最高收益、最低风险的一处开始：写测试 → 修改 → 全测 → Profile 验证 → 记录 diff，重复迭代。
5. 全程遵守“**不改变现有功能**”；没有实测或证据时明确标注未知。
