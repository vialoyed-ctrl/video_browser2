# Flutter 功能保持型重构：Codex 首批交付

日期：2026-10-09；项目 `E:\projects\video_browser2`。

## 阶段状态

| 阶段 | 本轮状态 |
|---|---|
| P0 回滚与验收基线 | 已完成本机交接核对、Git历史、测试、Profile构建安装；未从全新检出目录构建 |
| P1 UI测量 | 已建立首页、抽屉和播放页基线；搜索/分页/全部站点及重建热点仍待测量，未做广泛UI重构 |
| P2 播放器生命周期 | 已完成一处经红绿测试证明的异常释放修复，以及正常MP4真机生命周期探针；完整状态机尚未完成 |
| P3 全面验收 | 未完成，不能将本轮测试当作四站点功能完全等价 |

P0 详细证据：`docs/refactor-phase0-2026-10-09.md`。P1 原始统计与限制：`docs/refactor-profile-2026-10-09.md`。

## 唯一新增生产修复

文件：`lib/app/services/player_service.dart`，`_disposePreloaded()`。

旧代码在同一个 try 块中依次 await `pause()` 和 `dispose()`。若平台暂停抛出异常，后续 dispose 被跳过；服务已经丢弃旧控制器引用，但平台播放器与 Flutter 事件订阅仍存在。

修复把暂停与释放拆为两个独立的 try/catch。正常调用顺序保持不变；暂停失败仍尝试释放。捕获的局部 `old` 保证异步清理不会释放新的预热实例；已接管的控制器不在预热槽中，仍由播放页拥有。

没有修改站点解析、请求头/Referer/Cookie、缓存键、预取行为、路由、播放器UI、手势或下载调度。Android Media3 与非Android Dart代理仍保留原有两条路径。上一阶段下载角标优化保留。

## 测试驱动与审查

新增 `test/player_preload_lifecycle_test.dart`，使用真实 PlayerService 和真实 Flutter VideoPlayerController，仅替换原生平台边界：

1. 暂停异常后清空：仍释放原生播放器、取消监听。
2. 暂停异常后替换：只释放旧实例，新预热实例保留。
3. 重复清空：正常实例只释放一次。
4. 接管后清空预热槽：不释放已移交给播放页的实例。

修改生产代码前，两项异常测试明确失败：清空后平台仍有旧实例；替换后旧实例仍存活。最小修复后四项全部通过。故障注入证明释放调用及订阅取消得到恢复；这不是在真机上自然复现暂停异常，也不是测量到某个固定MB的内存减少。

`pubspec.yaml` 新增测试依赖 `video_player_platform_interface: 6.9.0`，与现有锁定版本相同；`pubspec.lock` 只将该项从 transitive 改为 direct dev，没有升级依赖。

| 检查 | 结果 |
|---|---|
| 完整测试 | 145通过、1跳过，exit 0 |
| 静态分析 lib/test | 0 error、0 warning，仍原有7条avoid_print info，exit 1 |
| 修复版ARM64 Profile构建 | 成功；临时build number 2003 |
| Superpowers独立只读代码审查 | 无本轮Critical / Important / Minor阻断项 |

原始红绿日志、全测、分析、构建记录在 `work/handoff-validation/`。审查对初始化中取消、暂停永久挂起、dispose自身失败保留为独立后续问题，未将它们误写成已覆盖。

## 真机验证

设备 PMB110 / Android16 / API36。始终使用保留数据安装，没有卸载或清空应用数据。

实际91模块：验证首页进入播放页、持续播放，观察到进度00:48以及后续01:48（总长02:49）；执行快进操作，未出现播放错误；退出后能返回首页并打开站点抽屉。这个冒烟流程不构成精确Seek延迟或媒体格式的独立鉴定，更不代替完整HLS冷/热缓存验收。

Hanime1：实际切换版面并完成首页加载；未把其所有播放、账号或订阅功能写成已验收。

为隔离站点网络波动，额外使用项目已有的中性 `Butterfly-209.mp4`，通过本机回环服务和ADB reverse在临时Profile入口复用同一真实PlayerService、video_player及Android原生后端。该入口位于 `work/profile_player_probe.dart`，不参与默认main.dart构建。

| 中性MP4探针 | 修复版单次测量 |
|---|---:|
| 时长 | 7540ms |
| 预热初始化 | 595ms |
| play到首次正播放进度 | 214ms |
| Seek指令返回 | 1ms |
| 原生getPosition确认中点3770ms | 2ms |
| 倍速、暂停 | 1.5X、暂停成功 |
| 预热后清空 | 连续8次完成，槽为空 |

这些是初始化、指令返回和报告位置的指标，**不是可见首帧或Seek后第一帧时间，也没有修复前同素材对照，不能声称起播/Seek提升了多少**。避免使用 seekTo 后立即更新的 Dart 乐观位置作为原生响应证据，最终探针改用平台position getter。

Android media.resource_manager当前进程段未列出该PID的编解码器客户端资源，历史事件有对应removeResource。历史日志中大量PID记录不是活跃资源数；该服务也不覆盖所有原生/GPU内存。探针结束PSS快照194698KiB仅用于留档，不能与完整App首页相减算优化量。

测试后已保留数据恢复正式修复版及正常 `build/app/outputs/flutter-apk/app-profile.apk`，关闭临时素材服务器和ADB reverse。正式Profile包SHA-256：`F3BA5920AB50125A152B4B795ADF853972AB022DBC6D017E5ED15204698A7FF1`。

## 性能结论

首页重复样本的raster P95为8.131ms，修复后8.033ms。已有运行波动更大，**没有证据证明整体流畅度提升**。本轮可证明的改善是：暂停异常时，原先被跳过的释放与监听取消现在执行；八次正常原生清理也通过测试。

## 回滚

基线 `3649739`，标签 `handoff-2026-10-09`；分支 `refactor/profile-ui-20261009`。P0记录提交 `2caabe3`；P1证据提交 `b137046`。

生产修复与四项测试、测试依赖单独提交。用 `git log --oneline --grep="fix: dispose warm player after pause failure"` 找到修复提交，再 `git revert <该提交>`，可保留P0/P1资料与上一阶段角标优化。不要回填全目录快照。

原始快照仍为 `E:\projects\_video_browser2_refactor_backup_20261009`。`work/handoff-validation/` 另存原设备安装包、修复前Profile包、正式修复后Profile包；Android可能限制降级，遇到失败不应卸载来强行回退数据。

## 下一批工作

1. 先补播放器初始化中的取消、快速切源、预热接管、后台前台和退出的竞态契约；尤其检查初始化Future取消后的收尾、暂停挂起及dispose失败的边界。
2. 用固定HLS/MP4素材分别测冷/热缓存、首个可见帧、Seek后的呈现帧、弱网重试和长时原生内存；加入Perfetto/视频呈现时间，不能用Dart位置冒充呈现时间。
3. 继续测量搜索输入、分页、切站和各站点列表；定位确定的重建/绘制热点后，才迁移最小共用UI组件。保持分页位置、视觉及辅助功能行为。
4. 最后逐站验证91、91麻豆、hanime1、PornHub的搜索/分页/详情/播放/账号/收藏/历史/下载/缓存，再逐步统一接口和状态管理；不更换GetX，不改解析规则或合并缓存路径。

本轮是接手后的第一批渐进工作，全面架构统一与P3验收仍未完成。
