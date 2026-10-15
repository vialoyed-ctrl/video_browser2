# 播放器预热初始化取消：阶段交付

日期：2026-10-09；项目 `E:\projects\video_browser2`；前一批提交 `6503b15`。

## 本批范围和结果

继续交接 P2 的生命周期契约，修复预热初始化尚未完成时，清空、替换或接管控制器后 `PlayerService.preOpen()` 仍等待初始化事件的问题。上一批暂停异常释放修复及下载角标优化保留。没有进行整项目重写；架构、UI 组件统一与四站点全面验收仍在后续阶段。

生产改动仅 `lib/app/services/player_service.dart`，新增 18 行、替换 1 行。新增私有归属结束通知；清空、替换和接管时结束服务等待；正常初始化仍等待真实 ready。接管只结束服务的等待，原控制器继续初始化，仍由播放页释放。原 generation 与实例 identity 检查保留。

请求头、Referer、Cookie、缓存键、站点解析、预取策略、路由、GetX、播放 UI 和手势未改动。Android Media3 原生缓存与其他平台 Dart 代理仍是原来的两条路径；依赖版本未改动。

## 先复现，再最小修复

锁定 `video_player 2.14.0` 的 `initialize()` 等待原生 initialized 事件。`dispose()` 取消事件订阅，但不会完成该初始化 Future。旧服务只 await initialize：取消后 ready 无法再送达，服务等待无法正常收尾。接管时原生初始化还能继续，但服务不再拥有实例，也无需继续等待。

在真实 `VideoPlayerController` 上，仅替换 `VideoPlayerPlatform` 原生边界。新增六项契约：

1. ready 前清空：服务等待结束，原生实例释放，监听取消。
2. ready 前替换：旧任务结束，新预热实例及新槽位保留。
3. ready 前接管：服务任务结束；清空服务不释放已接管实例，原生 ready 后仍正常初始化。
4. 重复触碰同一个待初始化条目：不重复创建、取消或释放。
5. 初始化异常：只清理仍由服务拥有的实例和槽位。
6. 原生 create 尚未返回时取消：服务等待先结束；迟到创建的实例随后按原清理顺序释放。

修改生产代码前，四项取消契约出现 `TimeoutException`，六项既有/正常契约通过；修改后十项全通过。延迟创建假平台按照现有 Android 后端行为，拒绝为已释放 ID 提供事件流。

采用 `Future.any<void>` 监听初始化与归属结束。归属结束先发生时，真实初始化的迟到错误仍有错误监听消费；没有篡改 video_player 内部 Future，也没有取消已接管的真实初始化。

## 测试、构建和审查

| 检查 | 结果 |
|---|---|
| 生命周期定向测试 | 10 项通过；修复前 4 项失败 |
| 完整测试 | 151 通过、1 跳过；exit 0 |
| lib/test 静态分析 | 0 error、0 warning，仍原有 7 条 avoid_print info；exit 1 |
| Android ARM64 Profile 前后探针 | 两次构建、保留数据安装均成功 |
| 独立 Superpowers 代码审查 | Critical / Important / Minor 均无阻断项 |
| 默认 main.dart 正式 Profile 包 | 构建成功；保留数据安装恢复；91 首页、快速进入退出及实际播放冒烟通过 |

没有升级依赖或迁移 Kotlin/Gradle。构建出现现有 JVM native-access、Kotlin Gradle Plugin 迁移和 SDK XML 版本提示；它们不是本批引入的分析问题，构建结果另行记录。

## Android 真机 Profile 前后对照

设备 PMB110 / Android16 / API36。前后均同一临时 Profile 入口、同一项目中性 `Butterfly-209.mp4`、同一原生后端、同一 1500ms 延迟服务。每次使用唯一 URL 避免已有素材缓存绕过延迟；对照包 build number 均 2003。只使用 install -r，未卸载或清空数据。

临时探针位于 `work/profile_pending_init_probe.dart`，素材服务为 `work/handoff-validation/pending-init/server.cjs`，仅绑定电脑 127.0.0.1:8787，通过 ADB reverse 访问。默认 main.dart 未改动。

| 初始化中操作 | 修复前调用后的服务 Future 等待 | 修复后调用后的服务 Future 等待 | 归属验证 |
|---|---|---|---|
| 清空，3 次 | 全部超出 1000ms 观察窗仍未完成 | 三次均记录 0ms，即小于计时器 1ms 精度 | 预热槽清空 |
| 替换，3 次 | 全部超出 1000ms 观察窗仍未完成 | 三次均记录 0ms | 三个新实例均 ready |
| 待初始化实例接管，1 次 | 超出 1000ms 观察窗仍未完成 | 记录 0ms | 接管时未初始化；随后 ready，原生位置增长 |

修复前后各操作都确认服务任务在操作前尚未完成。首轮取消可能早于原生创建返回，其余请求亦覆盖等待元数据阶段；不将它们全部声称为某个固定原生子阶段。接管样本明确检查 `value.isInitialized == false`，清空服务后确认真实 ready 与平台 position 正增长。

这证明**服务取消等待及时收尾**，不是可见首帧、Seek 第一帧、解码帧率或 dispose 完成时间的测量。没有在本批量化整体 UI 流畅度提升。单次内存结束快照 PSS：修复前 194792KiB、修复后 194415KiB；差异不足以证明内存优化或长时无泄漏。两个进程的 media.resource_manager 当前段均无编解码器客户端资源，历史 removeResource 保留；该服务不覆盖全部原生/GPU 内存。

原始结果 `baseline-result.json`、`fixed-result.json`，原始 UI、完整红绿/全测/分析/构建日志及资源快照均在 `work/handoff-validation/pending-init/`。修复前 logcat 文件为空，不作为证据；结果从保存的原始 UI content-desc 提取。

正常 main.dart 入口另行构建并恢复，正常构建输出与实际安装的保存包 SHA256 均为 `3D7E6CD1653C26155F20ABA737C0BB3331CE06E4D94DD12A527C9AD0AE2C5BAF`。正式版 91 首页加载，首次卡片快速进入即返回仍是首页；再次进入播放页，进度控件为00:02/02:49，随后能返回首页。第二份播放页 UI 控制条已自动隐藏，未以其宣称独立持续进度数值，也没有据此测量可见视频帧。终态 `HOME_RESTORED=True`、`PROBE_REMAINS=False`，临时服务端口和 ADB reverse 均已关闭。该冒烟不是四站点全验收，也没有鉴定此次实际站点媒体属于 HLS 或 MP4。

## 边界与审查后续事项

本批不声称完整播放器状态机完成：

- 原生 create 自身抛错：锁定依赖的 creating completer 可能不结束；需单独故障注入和决定依赖修复方式。
- pause 永久不返回：原有 pause→dispose 顺序仍可能阻塞实际释放；本批只结束服务等待。
- dispose 自身失败：仍为原 best-effort，不能保证平台回收。
- 控制器发布前，URL 获取或代理初始化永久等待：原有路径尚未加入取消契约。
- 接管方的错误展示、刷新地址等策略仍由原 PlayerController 处理；本批验证接管后的正常 ready，不等于所有错误 UI 全验收。
- 首个可见帧、冷/热 HLS、弱网、后台前台、长时内存、搜索/分页重建热点和四站点全面回归仍待测。

独立审查还建议将“接管后的迟到初始化错误及新槽保留”作为后续补充契约；源代码核对已确认 Future.any 的错误监听保留，未列为阻断项。

## 回滚与下一阶段

本批生产改动、六项测试和阶段记录单独提交，使用 `git log --oneline --grep="fix: settle canceled warm player initialization"` 定位，再 `git revert <该提交>`；保留 `6503b15` 和原下载角标优化。原始源码快照保持只读。

下一阶段先补上述真实平台失败及路由/后台生命周期边界，固定 HLS/MP4 可见帧与长时资源测量。搜索、分页和各站点 UI 的实测热点确认后，再逐个迁移公共组件与模块接口；不批量替换 GetX，不改变解析与缓存路径。
