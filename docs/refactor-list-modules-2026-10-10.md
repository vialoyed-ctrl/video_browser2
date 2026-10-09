# 独立站点列表架构重构阶段报告（2026-10-10）

本批从252fbe9继续，完成Hanime1排行/订阅与PornHub推荐/最热列表的公共分页状态迁移，以及PornHub列表与页脚的局部订阅拆分。旧源码快照、下载角标优化、播放器释放/取消修复及Home/Search上批迁移均保留。完整项目重构尚未结束。

## 改动与范围

- f0ae7e7：PagedListState新增initiallyHasMore（默认true）；Hanime1新增rankingPaging/subscriptionsPaging，旧公开Rx接口指向相同存储，订阅初始hasMore=false，排行/订阅各保留单一加载标志。请求失效使用共享代数；内部下一页游标、重复追加、过滤条件、预加载和错误处理不改。
- 同一提交：PornHubListState组合公共状态，旧items/isLoading/isLoadingMore/hasMore/error保持Rx接口，page保持可写int访问并代理到Rx存储；request继续保留原可写整数和控制器策略。路径缓存、页码回退/重试、账号重置与关闭失效逻辑不改。
- bd80de6：PornHub路径选择、空态、保留列表和页脚分别订阅，已有内容下的加载/错误仅更新页脚。排序、滚动控制器所有权、RetainedPageSliver/PageFooterScope、卡片/原网格几何、点击/下载动作均保留。
- 本批没有重写解析器、播放器、缓存、主题或账号聚合流；没有把Hanime专用布局强行替换成公共网格。

## 先测试与测量，再修改

1. 原完整基线177通过、1原有跳过；新增17项旧行为测试先在原实现上通过。
2. 共享状态消费者测试先失败（缺少rankingPaging），迁移后定向32项通过。验证真实结果、并发加载保护、旧响应/错误/cleanup、失败重试同页、重复追加、过滤参数、账号/关闭失效和独立路径。
3. 原实际PornHub视图生成400/900宽金图；原布局、空态、重试、排序、同步发布追加/替换、非活跃页脚共7项先通过。卡片重建约束先失败（四次加载/错误更新实际16次重建），拆分后8项全部通过，并与原金图一致。
4. 最终全项目测试203通过、1原有跳过；lib/test分析0error、0warning、原7条avoid_print info。分析仍报告7 issues，不能写成零问题。最后task-done全测再次203通过。
5. 新增两个多行if在格式化后产生的info已加括号消除；仅保留原有7info。临时筛选测试标签在完成RED记录后移除，没有新增标签警告。

原始日志位于work/handoff-validation/list-modules：characterization-before.log、state-red.log、state-green.log、ui-before-verified.log、ui-red.log、ui-green.log、full-tests-final.log、analyze-final.log。测试滚动探针改为指定实际滚动控制器，避免误触分页横向滚动区；生产手势不变。

## 真机Profile前后证据

同一PMB110（Android16/API36，ARM64），实际PornHubVideoListTab固定4个中性条目，无远程封面/流地址，10次底部加载标志切换，每次间隔350ms。前后均Profile、相同构建命令与入口。正式main.dart未改。

| 指标 | 修改前 | 修改后 |
|---|---:|---:|
| BiliVideoCardV重建 | 40 | 0 |
| SliverGrid重建 | 10 | 0 |
| Obx重建 | 10 | 10 |
| Timeline事件数 | 24934 | 15418 |

两份定向timeline均低于32k缓冲容量，10次RPC回执中条目数均保持4。证明该局部场景的已有卡片/网格重复重建消除；不证明整体FPS、起播、Seek或原生/GPU长期内存提升。

原始JSON：probe-before-builds.json、probe-after-builds.json；探针：work/profile_pornhub_list_probe.dart；采集工具在交付目录list-modules-profile-tools。量化摘要：docs/list-modules-profile-results-2026-10-10.json。

## 正式入口真机回归

已保留数据安装正式默认main.dart ARM64 Profile，然后通过真实界面执行91→PornHub→Hanime1→91切换、滚动及PornHub排序。

- PornHub推荐首次21项，实际滚动追加到第2页42项；最热独立缓存第1页31项；点击“最多观看”加载第1页28项，旧推荐/最热缓存保留。快照中加载标志false、错误null。
- Hanime1结构化首页返回数据；本日排行实际滚动追加至第2页118项、总363页；订阅由第1页60项追加至第2页120项、总19页。快照中加载标志false、错误null。没有改登录状态或筛选偏好。
- 最后恢复91，第1页42项、加载标志false、pageError=null、滚动0。没有卸载或清除应用数据，没有修改用户预加载设置。
- 网络内容随时间变化，以上仅本次真实快照，不是网站完整功能或四站点端到端验收。

以下均是重构后的独立冒烟样本，**没有配套同场景本批前测，不能用作速度提升百分比**。build/raster P95单位ms：

| 场景 | 滑动次数 | 帧数 | build P95 | raster P95 |
|---|---:|---:|---:|---:|
| 91首页滚动 | 22 | 2598 | 1.596 | 8.267 |
| PornHub推荐滚动 | 17 | 2026 | 1.445 | 7.578 |
| Hanime1排行滚动 | 9 | 1460 | 1.890 | 9.100 |
| Hanime1订阅滚动 | 13 | 1948 | 1.745 | 9.830 |

更多帧/内存数据见原始formal-*.json；Dart GC后的堆快照不是Native Media3、GPU或长时间内存泄漏验证。空闲样本可能0帧，不把无动画的0帧当作卡顿。

## 审查与已知边界

一个全新上下文的只读独立审查检查252fbe9..bd80de6，没有本批引入的Critical/Important/Minor项。审查记录的继承风险是：PornHub在网络请求返回前st.page++，原RetainedPageSliver遇到页变/条目未增长会清分段；原大Obx也会在loadingMore变化时重建，因此此风险早于本批存在。新增同步追加测试不覆盖这个网络等待帧，不宣称实际异步页段保留已修复。

执行决定与代价：
- 沿用已获授权的干净refactor/profile-ui-20261009分支和本会话执行方式；不重复创建检出或审批。若选错工作区，需要在本地回滚并重放本批提交。
- 本批保持继承的PornHub页码预增/分段语义，把延迟响应复现与单独修复列为下一优先项；代价是原有等待帧丢失旧页脚的风险仍在。无延期Minor项。

## 构建与回滚

正式入口Profile构建成功，临时build-number2004，pubspec版本不改。正式输出APK、归档APK、从手机拉取的已安装APK SHA256完全一致：

45126F3DF6C86F319C9FD9677CEDDBE972E1EBE3FE5F50BB0DE90C1BBAEB3B8A

正式入口的VM扩展列表没有ext.refactor.setLoading；临时探针不在正式入口。测量会话已detach，8199/8200/8201自建端口转发均关闭。

可单独回滚：先revert bd80de6，再revert f0ae7e7；此前所有提交保留。a9ad24f为本批设计/计划记录，可保留作历史。交付补丁为252fbe9到最终文档提交的二进制净diff，反向应用检查后交付；不要整目录覆盖原源码快照。

## 剩余任务

1. 先用延迟响应复现PornHub页码预增与保留分段边界；明确请求页/已发布页责任，再单独修复并做真实追加/失败重试验收。
2. 继续迁移Hanime结构化首页/按用户Tab缓存、PornHub搜索/订阅聚合/账号列表和搜索局部订阅；按各站点差异拆批，不合并抓取算法或改过滤/排序语义。
3. 播放器状态与UI职责分离；背景/前台、快速切源、初始化/暂停/释放异常契约；HLS/MP4冷暖可见首帧、Seek第一帧、弱网和长时间Native/GPU内存验证。
4. 完成91/91麻豆/Hanime1/PornHub的搜索、详情、播放、登录、收藏/历史、下载/缓存、横竖屏与宽屏全流程回归。上批真实搜索网络失败仍是未完成项，本批不把列表成功当作搜索验收。
