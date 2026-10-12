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

## 8. Codex 接手更新（2026-10-09）

原第 3 节为交接时状态。现已完成 P0 核对、Git 回滚基线与 Profile 真机安装。

- Git 基线：3649739a8c0e5990f0c65d40f7485f32f7629406；标签 handoff-2026-10-09。
- 分支：refactor/profile-ui-20261009；原源码快照保留。
- 接手基线：141 通过、1 跳过；analyze 仍原有 7 info。
- P0 详见 docs/refactor-phase0-2026-10-09.md；后续实测与局部修复详见 docs/refactor-progress-2026-10-09.md。

不得将当前阶段测试视为四站点完整功能等价验收。

## 9. Codex 继续执行更新（2026-10-09）

P2 新增一批经测试及真机 Profile 前后对照的局部修复：初始化完成前取消、替换或接管时，服务的 preOpen 等待正常收尾；接管后的原控制器继续初始化。上一批 6503b15 的暂停异常释放修复保留。

- 生命周期定向 10 项通过；完整测试 151 通过、1 跳过；分析仍原有 7 info。
- 同一慢响应 MP4 真机探针：修复前 7 次操作后的服务等待均超出 1 秒；修复后均小于计时器 1ms 精度。该结果不是可见首帧、Seek 第一帧、整体 UI 帧率或原生 dispose 完成时间。
- 正式 main.dart Profile 修复版已保留数据恢复，正常首页与播放页进度冒烟已记录；临时服务及端口已关闭。
- 本批完整改动、限制、后续生命周期边界与回滚：docs/refactor-player-cancellation-2026-10-09.md。

继续工作先读第 8、9 节及新增报告，不要重复第 3 节交接时已经完成的 P0 工作；完整架构/UI 统一和四站点全面回归仍未完成。

## 10. 首页与搜索架构重构更新（2026-10-09）

已实际迁移首页/搜索公共分页状态和91公共网格，首页内容状态、列表、热词与页脚分别订阅。保留全部源解析、专用Hanime布局、页大小/防抖/重试/预加载及此前播放器与下载角标修复。

- 状态迁移：b7d7664；网格与首页拆分：f92af1a；测试所需async导入恢复：fdac8c7。
- 最终完整测试177通过、1原有跳过；lib/test分析0error、0warning、原7info；独立审查及导入修复复审无阻断项。
- 同一真机Profile固定4卡片、10次加载切换：卡片重建40→0，网格10→0；该证据不等于整体FPS、搜索或长期内存提升。
- 正式真机首页追加到第3页90项、第1页页脚保留；点第2页替换24项并滚动归零；最后刷新恢复第1页42项。实际搜索前后均网络失败重试状态，不能宣称成功搜索结果已真机验收。
- 正式默认入口ARM64 Profile已保留数据恢复，APK及输出SHA256：952BD90DF1245DD31D6CF1A1F6CC4A82B47913B5D1BE98E1A96D81C34CCCC9EC。测量连接与8193–8198自建转发关闭。
- 全部测试/前后与交替帧样本、真实分页状态、限制、回滚顺序和下一批任务见 docs/refactor-home-search-2026-10-09.md；量化摘要 docs/home-search-profile-results-2026-10-09.json。

继续按该报告推进独立站点模块与播放器，不重复本批迁移；完整架构统一及四站点全面回归仍未完成。源码快照仍保留，不能整目录覆盖。

## 11. 独立站点列表架构更新（2026-10-10）

从252fbe9继续，已迁移Hanime1排行/订阅与PornHub推荐/最热的公共分页状态，并拆分PornHub内容/网格/页脚订阅。旧Rx接口、订阅初始hasMore=false、重复追加、各站点游标/请求策略、路径缓存/账号失效、原布局与播放器缓存均保留。

- 状态迁移f0ae7e7；UI局部订阅bd80de6；原有下载角标、播放器与Home/Search修复不改。
- 全测203通过、1原有跳过；lib/test分析0error、0warning、原7info；独立只读审查无本批新Critical/Important/Minor项。
- 同一真机Profile实际PornHub列表4个中性卡片、10次加载切换：卡片重建40→0，网格10→0。仅此局部证据，不等于整体FPS、起播/Seek或长期内存提升。
- 正式Profile真实界面：PornHub推荐21→42项第2页，最热31项与最多观看28项第1页分别缓存；Hanime排行第2页118项/总363页，订阅60→120项第2页/总19页。加载标志false、错误null。没有改登录或清除数据。
- 审查发现继承风险：PornHub网络回复前page++，RetainedPageSliver在页变/条目未增长时可清分段；原实现也会在loadingMore时重建。同步追加测试不覆盖此等待帧。本批保持原语义，下一批先延迟响应复现并单独修复，不能宣称真实异步页段保留已解决。
- 正式main.dart ARM64 Profile已恢复，手机回到91第1页42项、加载false、pageError=null、滚动0。正式输出/归档/手机已安装APK SHA256一致：45126F3DF6C86F319C9FD9677CEDDBE972E1EBE3FE5F50BB0DE90C1BBAEB3B8A。pubspec不改，临时构建号2004，自建8199–8201转发关闭。
- 本批报告：docs/refactor-list-modules-2026-10-10.md；摘要：docs/list-modules-profile-results-2026-10-10.json。回滚先bd80de6、再f0ae7e7；不能覆盖之前已完成工作。

剩余优先级：异步分页分段边界 → 其余站点/账号/搜索列表职责与局部UI → 播放器状态/生命周期、可见首帧/Seek/弱网/长期内存 → 四站点完整回归。完整项目尚未完成，原源码快照仍保留。

## 12. PornHub 异步翻页缺陷修复（2026-10-10）

从7046392继续，先延迟响应回归和真机旧版三轮测量，再独立修复上一节遗留的提前page++导致页脚丢失。实现2061b49：请求页与已确认页分开；成功空追加保留既有分段且继续原source.page进度；成功跳页/刷新用替换代次重置，包括同页同ID。

- 最终定向36通过，完整213通过、1原有跳过；lib/test分析0error、0warning、原7info。独立审查提出的同页替换问题已RED复现、修复并复审无剩余项。
- 真机ARM64 Profile真实列表控件、同4卡片/三轮1秒等待：每轮卡片4→0、网格1→0；等待保留1页，成功保留1/2页。异常重试仍请求2。仅局部重建/分页证据，不代表整体FPS/播放器/长期内存。
- 正式main.dart真实推荐21→105条/第5页，五页边界全部保留、loadingfalse/errornull。正常入口已保留数据恢复，最后91首页第1页41条、flagsfalse、pageErrornull、scroll0、Root=site91；网站返回条数不是固定42。
- 正式输出/归档/手机APK SHA256一致：0A257428E7605C7805C2537D1764A248DE8718575CA48782100EDCA54CE8CAE0；临时构建号2005，pubspec不改。自建8202–8204转发和测量连接已关闭。
- 报告docs/refactor-pornhub-append-2026-10-10.md；摘要docs/pornhub-append-profile-results-2026-10-10.json；执行/审查裁决docs/refactor-pornhub-append-execution-2026-10-10.md。回滚实现只revert2061b49；原快照及此前改动保留。

下一批仍为其余模块/搜索/账号职责与局部UI → 播放器状态与生命周期、首帧/Seek/弱网/长期原生内存 → 四站点完整回归；不得宣称整个项目已完成。

## 13. 通用搜索UI局部刷新更新（2026-10-10）

从c3e86ae继续，完成实际SearchView中91/Hanime横向/海报/制作方布局的结果区域与页脚订阅拆分；另独立修复Hanime筛选栏声明40px、内容39px的继承渲染契约错误，内部尺寸、全宽和位置保持原样。控制器、解析、请求、播放器及此前修复均保留。

- 高度/宽度契约bd2850d；局部订阅883821d。全测226通过、1原有跳过；分析0error/0warning/原7info；独立审查反馈已补测试，最终复审无剩余项。
- 真机ARM64 Profile旧/最终实际四布局、每布局三轮1秒等待：三视频布局旧卡片合计36→0，四布局渲染网格/列表12→0；四种布局应用区域逐像素一致。只证明局部重建减少，不代表整体FPS、起播/Seek或长期内存。
- 正式main.dart实际91搜索关键词2026，第1页24项→第3页68项/总3页，保留三页分段；点击第1页替换回24项并滚动归零。Hanime三布局使用实际控件固定样本，未宣称网站搜索/账号全面验收。
- 正常Profile已保留数据恢复；最后91首页第1页41项、flagsfalse、errornull、scroll0、Root=site91。构建/归档/手机APK SHA256一致：F7B750E77DAD08676583E631FBB025C9550E0A57E9900A2FD5C67A1F0C9D0CD8；临时构建号2006，pubspec不改。attach及8205–8207自建转发已关闭，最终forward列表为空。
- 报告docs/refactor-search-ui-2026-10-10.md；摘要docs/search-ui-profile-results-2026-10-10.json；执行与审查裁决docs/refactor-search-ui-execution-2026-10-10.md。回滚实现先883821d、再bd2850d；可只撤销订阅优化而保留尺寸修复。原快照、此前报告和实现保留。

下一批：其余独立站点搜索/列表及账号职责与UI → 播放器状态/生命周期及真实首帧、Seek、弱网、长期原生内存 → 四站点完整回归。整个项目尚未完成，不重复公共分页状态和本批搜索订阅拆分。

## 14. Hanime 排行与订阅UI局部刷新（2026-10-10）

从256a467继续，实现5433ee2：实际排行/订阅结果区与页脚分别订阅，保留原排名键、制作方参数、网格边距、登录提示、翻页和刷新。控制器/解析/播放器不改，原快照及此前阶段保留。

- 旧测试226/1；新增12项实际控件契约与3张原布局golden，最终238通过、1原有跳过；分析0error/0warning/原7info。审查的页脚total/hasMore覆盖缺口补齐，复审无剩余项。
- 真机ARM64 Profile，排行/订阅/未登录订阅各三轮固定4卡片等待：卡片36→0，实际SliverList9→0；外层与页脚Obx仍刷新。截图比较区域无差异，顶部裁剪含部分探针控件，不能称整屏等价。
- 正式实际排行59→118/第2页/总363页、订阅60→120/第2页/总19页，两个页段分别保留，加载false/errornull。恢复91首页第1页41项、scroll0、Root=site91，账号/数据保留。
- 构建号2007，pubspec不改；输出/归档/手机APK SHA256：9DBC01F26E3275258EA1691A9CD776B490D32C87AAC38859515C0E204E33CF6D。测量已detach，final forward为空。
- 发现DDS历史Flutter.Frame重放，原正式滑动帧统计不作FPS/p95证据；独立clearVMTimeline构建计数有效。新增时间窗采集器，旧RED/新GREEN契约及真机226帧时间窗校验通过。
- 报告docs/refactor-hanime-list-ui-2026-10-10.md；摘要docs/hanime-list-ui-profile-results-2026-10-10.json；审查裁决docs/refactor-hanime-list-ui-execution-2026-10-10.md。实现可单独revert5433ee2；交付binary patch已反向检查。

剩余：其余站点搜索/列表与账号职责/UI；Hanime空追加/相同前缀替换独立测试；播放器真实首帧/Seek/弱网/长期原生内存及四站点完整回归。不要重复本批拆分，整个项目尚未完成。

## 15. 91麻豆独立搜索UI局部刷新（2026-10-10）

从7c7e848继续，实现fead00d，仅Site91MdSearchView复用未变结果快照/widget并独立页脚AnimatedBuilder；原route-local控制器、默认pageSize12、解析/播放器/下载回调、响应式几何保持。清空丢弃widget和条目缓存。

- 修改前238/1，等待RED旧4卡片重建；新增8项实际控件契约和原400/800golden，最终246通过、1原有跳过，分析0error/0warning/原7info。审查cache-clear/同ID元数据两Minor处理、复审无剩余项。
- 同真机ARM64 Profile三轮4卡片等待：卡片12→0、网格3→0；失败保留第1页，成功追加8项且1/2页保留。截图裁剪区域无差异，只是局部重建证据，不是FPS/播放器/长期内存提升。
- 正式官网2026搜索成功1项、第1页/hasMorefalse；无下一页，真实追加未验收。实际清空后缓存list0/widgetnull，返回controllerdisposedtrue，不能称对象已GC或无原生泄漏。
- 已保留数据恢复正常main.dart、91首页41条/第1页、flagsfalse/errornull/scroll0、Root=site91。构建号2008，pubspec不改；输出/归档/手机APK一致：23DCEA867384FB7B42CE33DCCE3C31D2E90DA4FC6AD426156D55F81F0DB9CB2F。attach/自建转发全关闭、forward空。
- 报告docs/refactor-md-search-ui-2026-10-10.md；摘要docs/md-search-ui-profile-results-2026-10-10.json；执行/审查裁决docs/refactor-md-search-ui-execution-2026-10-10.md。只revertfead00d可撤销实现，binary patch已反向检查。原源码快照和前阶段保留。

剩余PornHub搜索/其他列表及账号职责/UI、各模块空追加/同前缀替换边界、播放器首帧/Seek/弱网/长期原生内存与四站点完整回归。整个项目尚未完成，不重复本批优化。


## 16. PornHub独立搜索UI局部刷新（2026-10-10）

实现8f61602；四种结果快照及页脚独立刷新，路径/过滤/请求/播放器保留。新增22契约和四原golden；最终268通过/1原跳过，分析0error/0warning/原7info；独立复审无剩余项。真机四模式各三轮：视频/片单卡片36→0、创作者行12→0、网格/列表12→0，裁剪像素无差异，只是局部构建证据。

正式2026视频31→73→116条、三页保留；切片21、创作者48、片单接口36但原过滤0匹配。正常2009保留数据恢复91首页41/第1页、flagsfalse/errornull/scroll0、Rootsite91。三APK SHA256：22E61769DFDF8B21FDF0FC8D920E9BE28E2B09E5CC62B412AFD61C71EB1917EB。attach与三自建转发关闭。

报告docs/refactor-ph-search-ui-2026-10-10.md，摘要及执行同名阶段文档。可单独revert8f61602。原快照与以前批次保留；后续分页边界、独立路由职责、播放器首帧/Seek/弱网/长期原生内存和四站点综合回归继续执行，完整项目尚未完成。


## 17. Hanime成功追加/替换页段边界（2026-10-10）

实现0a370ac；先四UI RED及旧真机四错，再给排行/订阅成功响应显式追加标志和替换代次。空追加保留1/2、相同前缀替换只留2；等待/失败/迟到/关闭不改成功元数据。定向41、最终完整272通过/1原跳过，分析原7info/0error/0warning；独立审查无阻断项。

正式2010排行59→118、订阅60→120均第2页，两页保留、flagsfalse/errornull。保留数据恢复91首页41/第1页/scroll0/Rootsite91；三APK一致C8B9732D46B536D04C11051203E99A754A800ED67F77D1CAD4B2B5A62238A94B；三自建转发已关闭。详情docs/refactor-hanime-boundaries-2026-10-10.md及摘要。可独立revert0a370ac；其他消费者默认推断仍待各自验证。

继续独立路由控制器职责、其余分页/账号UI、播放器首帧/Seek/弱网/native长期内存和四站点综合回归。整个项目未完成，不重复旧批。


## 18. PornHub独立搜索路由控制器（2026-10-10）

实现f86ed8d，route-local ChangeNotifier接管四类请求/结果/错误/失效，UI资源仍view负责；原22契约和局部刷新保留。新增10controller+2UI回归，最终284通过/1原跳过、原7info/0error/0warning；审查total插值Important已RED修复并关闭。

真机四模式十二窗口仍0卡片/行/网格重建，四裁剪像素无差异。正常2011实际视频31/74/117三页、切片8/创作者48/片单36-filter1；退出disposedtrue不代表GC。恢复91首页41/第1页/scroll0/Rootsite91，三APK一致2F8019EE51189B92C5A228C1A867135D1339220633EE6489FA581FF9BBD767E0；detach与6189/11614关闭。报告docs/refactor-ph-search-controller-2026-10-10.md、摘要及docs/superpowers计划ledger。可单独revertf86ed8d；原快照和以前阶段保留。

继续播放器释放/切换等待边界、剩余路由与分页、首帧/Seek/弱网/native长期内存及四站点完整回归；完整项目尚未完成。


## 19. 预热释放等待边界（2026-10-10）

实现baa1c94；移除仅预热slot的冗余pause等待。真实Android故障对照旧六轮超1s，新清空81–92ms、替换248–397ms，终态active为空。12生命周期、完整286通过/1原跳过、原7info；审查无阻断，LF修正。正式2012恢复91首页41/第1页/scroll0，三APK一致；临时服务/映射关闭。详见docs/refactor-warm-disposal-2026-10-10.md及warm-disposal-profile-results-2026-10-10.json。不声称FPS/首帧/长期native泄漏改善，完整项目仍继续。


## 20. 91MD 搜索成功分页语义（2026-10-12）

成功请求追加标志/替换代次及view缓存共新增9行；RED原8过新2败，GREEN10、全量288/1原跳过、lib/test原7info；独立审查无问题。10月10日真机前后六轮对照保留8项数据：空追加保留1/2，相同替换只留2。正常2013已构建/安装，但正式搜索/返回首页和手机hash未验收；10月12日无连接设备，仍待补充，不计整个项目完成。报告docs/refactor-md-boundaries-2026-10-12.md及摘要。继续其他模块核对，保留原快照和旧阶段。
