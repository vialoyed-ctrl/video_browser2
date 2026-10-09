# PornHub 异步翻页修复与真机验证

日期：2026-10-10；项目：`E:\projects\video_browser2`。

## 本批结果

修复请求下一页时提前发布页码、导致已加载页脚丢失的问题。原解析、请求路径、重复追加、预加载、账号、播放器及既有UI外观不改。旧源码快照仍保留于 `E:\projects\_video_browser2_refactor_backup_20261009`。

基线为 `7046392`；实现独立提交 `2061b498b04df770c573ace7e935c524c5ac5898`，继续原 `refactor/profile-ui-20261009` 分支。先复现和测量，再修改；没有重做前几批架构迁移。

## 改动

- `lib/app/modules/pornhub/pornhub_controller.dart`：loadMore 用已确认 page+1 作为请求目标，不提前更新显示页。失败保留已确认页，因此重试目标不变；只在成功且当前请求响应中更新追加模式与替换代次。
- `lib/app/modules/pornhub/views/pornhub_video_list_tab.dart`：向实际列表传递成功追加/替换标记；等待期间仍只更新页脚。
- `lib/app/widgets/retained_page_sliver.dart`：可选 preserveEmptyAppend 保留空追加前的分段；可选 replacementGeneration 明确重置成功跳页/刷新，包括页码与条目ID完全相同的响应。默认 false/null，其他消费者仍按原逻辑更新。
- 两个现有契约测试文件新增10项测试，覆盖真实等待帧、summary/异常失败、重试同页、过期追加与新跳页竞态、空页 hasMore 两种返回、后续页码进度和同ID/同页替换。现有400/900宽度图片基准继续通过。

成功空页仍推进 source.page，下一次请求仍请求其+1；界面只保留实际有内容的页段，不把旧卡片改标为空页。请求失败或过期响应不增加替换代次、不清新请求的loading状态。

## 测试与审查

| 验证 | 结果 |
|---|---|
| 修改前完整测试 | 203通过、1原有跳过 |
| 初始延迟响应回归 RED | 27通过、5失败：等待页码提前变化/旧页脚消失 |
| 最小修复后 | 针对性32通过 |
| 空追加边界 RED | 11通过、2失败：期望[1,2]，实际[3] |
| 同页替换边界 RED | 13通过、2失败：期望[2]/[4]，实际[1,2]/[1,2,4] |
| 最终针对性测试 | 36通过 |
| 最终完整测试 | 213通过、1原有跳过 |
| analyze lib test --no-pub | 0error、0warning、原有7条avoid_print info |
| Git diff检查 | 通过 |
| 默认入口ARM64 Profile构建 | 通过，正式版已恢复安装 |

Superpowers系统化调试、TDD及验证流程已执行；独立只读审查发现同页/同ID替换缺口，先新增两项失败测试，修复后复审无Critical/Important/Minor项。审查未独立运行会生成产物的测试、未审查其他站点/播放器、未判断尚未完成的真机结果，这三项由执行者分别验证或保留为后续范围。

额外的不限定目录分析产生269条诊断，涉及源码副本、未参与当前依赖的third_party实现和临时探针；不能据此写全仓零问题。正式应用检查范围遵循交接文件的lib/test范围，修改未涉及那些目录。

## 真机修复前后对照

PMB110，Android16/API36，120Hz。前后同一ARM64 Profile探针，使用真正的PornHubController和PornHubVideoListTab；仅网络源为可控制Completer，4张中性卡片，无封面/视频网络负载。Flutter引擎二进制SHA256一致。每轮先恢复4条第1页、保持下一页响应1秒，采集widget build事件，关闭采集后完成第2页响应。各轮事件约6.9k–8.1k，低于32k缓冲。

| 等待窗口 | 修复前，3轮每轮 | 修复后，3轮每轮 |
|---|---|---|
| 显示页/请求页 | 2/2 | 1/2 |
| 等待期间已加载页脚 | 仅2，原1丢失 | 1保留 |
| BiliVideoCardV重建 | 4 | 0 |
| SliverGrid重建 | 1 | 0 |
| Obx重建 | 3 | 1 |
| 回复后页脚 | 仅2 | 1与2，2为活动页脚 |

合计旧卡片重建12→0、网格3→0。另一次异常/重试链修复后一直保留第1页并两次请求第2页，成功后保留1/2页。该结果仅证明待响应期间无谓重建和页脚丢失已消除，不等于HTTP、整体FPS、起播、Seek或长期原生内存改善。

## 正常入口真实网站验证

恢复main.dart的正式ARM64 Profile并保留安装数据。真实PornHub推荐列表21→105条、第1→5页，loading=false、error=null。VM中实际RetainedPageSliver的边界为(1,21)、(2,42)、(3,63)、(4,84)、(5,105)，只有第5页活动；最热仍保留独立31条第1页缓存。

12秒连续滚动，11次手势，1699个Flutter Frame事件：build p95=1.666ms，raster p95=8.790ms；raster有3帧>16.667ms。仅为修复后真实环境冒烟样本，无匹配的修复前帧样本，不能宣称帧率提高。长timeline接近缓冲容量，未用于卡片重建对比；帧统计来自独立Extension事件流。一次Dart GC后heap约29.44MB亦不是原生释放或泄漏证明。

最后手机恢复到91首页：第1页41条（当前网站返回，上一批42条不作为固定断言），两种加载false、pageError=null、滚动0、Root=site91。未修改登录、域名、缓存策略、预加载设置或清除app data。尚未访问的Hanime主页状态不纳入本批验收。

正式输出、归档及手机已安装APK三者SHA256：`0A257428E7605C7805C2537D1764A248DE8718575CA48782100EDCA54CE8CAE0`。构建号临时2005，pubspec仍2.0.2+3。自建8202–8204转发已移除，测量连接已脱离。正式APK：`work/handoff-validation/pornhub-append/formal-after.apk`。

## 证据与回滚

- 量化摘要：`docs/pornhub-append-profile-results-2026-10-10.json`。
- 测试/构建原始记录、APK、hash：项目的 `work/handoff-validation/pornhub-append/`（本地保留，不进Git）。
- 前后完整timeline及正常入口状态：本聊天工作目录 `work/append-results/`；可复用探针及采集工具随交付放在 `outputs/pornhub-append-tools/`。
- 单独回滚实现：`git revert 2061b49`，不覆盖此前的迁移和快照。整批补丁交付后可用 `git apply --reverse --check <patch>` 先验证；实际回滚前检查后续改动。

## 剩余任务

1. 其余站点搜索、账号和Hanime结构列表的职责/UI订阅分批统一，先建立行为测试与真实Profile基线。
2. 播放器状态、切换/后台/接管/释放生命周期，实测可见首帧、Seek、弱网和长期原生内存；保留前两批生命周期修复。
3. 四站点完整功能回归，特别是成功搜索、账号、收藏/历史、下载/缓存、HLS与MP4播放。当前阶段不等于完整项目重构完成。
