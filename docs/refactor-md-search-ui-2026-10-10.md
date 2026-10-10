# 91麻豆独立搜索UI局部刷新（2026-10-10）

从7c7e848继续，实现fead00d。本批只改Site91MdSearchView，保留原ChangeNotifier控制器、请求页、搜索默认页大小12、解析、账号、播放器与下载回调。不是全项目架构统一完成。

## 改动

原AnimatedBuilder每次通知都重新创建RetainedPageSliver、结果网格和旧卡片。现在视图保留一份不可变条目快照与结果widget，以关键词、确认页、VideoItem对象列表比较判定失效。相同ID但新对象/元数据会更新；成功追加和跳页仍走原分页分段。页脚独立AnimatedBuilder读取当前loading/loadingMore/error/hasMore，原重试/下一页/跳页回调不改。

外层标题、进度和空状态仍正常刷新；每个页脚仍有通知订阅，成本随保留页数增加，没有声称整个页面零更新。清空搜索时丢弃缓存widget和条目引用，避免空界面保留旧查询内容。仅保存当前快照，不累计多个查询。通知时listEquals仍有O(n)比较成本；测量只证明减少结果重建，不推算总CPU或内存收益。

原SliverLayoutBuilder、响应式列数/卡片比例、horizontal8、spacing8/6、跳页成功滚动归零、输入/清空/返回、播放器和下载操作保持原样。生产文件CRLF保留。原源码快照、前14节交接和此前优化没有覆盖。

## 先测试、测量，再改动

- 修改前全测238通过、1原有跳过。新增等待测试旧版RED：预期旧卡片0次，实际4次；其他追加/跳页/清空/退出行为原版通过。先从原控件生成400/800dp两张golden，未用新版重生成。
- 最终新增8项实际控件契约：两宽度原golden、等待/失败零卡片/网格重建、失败重试追加及跳7页替换、清空与新查询/过期回复、卸载后延迟回复、同一挂载400→800动态宽度2→3列、同页同ID新标题更新。
- 最终完整246通过、1原有跳过；lib/test分析0error/0warning/原7条avoid_print info。独立审查两个Minor（清空保留缓存、同ID元数据测试缺口）均处理，最终无Critical/Important/Minor。

## 真机证据

PMB110 Android16、ARM64 Profile、1440×3200、120Hz；新旧探针同Flutter引擎。探针使用实际Site91MdSearchView和原控制器，仅外部source.search由固定中性样本及Completer延迟替代；没有登录、下载、播放或持久配置写入。

三轮各4卡片、下一页等待1秒，每轮clearVMTimeline后统计B/X构建事件：

| 三轮合计 | 原版 | 本批 |
|---|---:|---:|
| BiliVideoCardV重建 | 12 | 0 |
| SliverGrid重建 | 3 | 0 |

等待和失败均保留4条、第1页/页脚，实际请求2；成功追加8条、第2页，第1/2页页脚分别非活动/活动。时间线原7814左右、后6866左右事件，没有使用DDS扩展流历史Flutter.Frame帧数。此前发现的Frame重放问题不影响本批clearVMTimeline构建统计；本批不提供FPS或p95提升。

同样本设备截图区域[0,160,1440,3088]逐像素无差异；该裁剪不包含全部上边应用栏，不能称整屏像素等价。完整测试golden使用Ahem字体，两个宽度加动态约束验证不等于所有主题、字体和文字缩放验收。

## 正式入口与内存边界

默认main.dart正式Profile真实91麻豆首页30条；搜索2026返回1条、第1页、hasMore=false、加载false/errornull，结果页段(1,1)。这次查询没有下一页，所以真实网站追加没有在本批验收；受控实际控件探针覆盖追加，不混为后端全面验证。

点实际清空按钮：控制器items0、searchedfalse；视图_resultItems0、_retainedResults=null。返回后控制器_disposed=true，延迟响应卸载测试通过。VM检查仍可见已dispose对象实例（服务检查引用等因素可能保留对象）；没有宣称已GC收集、无泄漏或长期原生内存改善。

随后恢复91首页41条/第1页、加载false/errornull、scroll0、Root=site91。保持账号和应用数据；没有卸载/清空数据。构建号2008、pubspec2.0.2+3不改，正式输出/归档/手机APK SHA256一致：`23DCEA867384FB7B42CE33DCCE3C31D2E90DA4FC6AD426156D55F81F0DB9CB2F`。正式应用无探针扩展，attach已detach，自建3738/10606/12314转发全部移除、最终forward为空。

## 回滚、资料与下一步

实现单独回滚：`git revert fead00d`。报告提交独立，可保留。交付binary patch覆盖7c7e848→本批报告提交，最终树反向check通过；先check再反向应用，不能整目录覆盖原备份或其他阶段。

量化摘要md-search-ui-profile-results-2026-10-10.json；执行与审查裁决refactor-md-search-ui-execution-2026-10-10.md。日志、APK、中性探针截图及原始timeline保留work/handoff-validation/md-search-ui，交付tools提供复现。正式UI XML含站点内容不纳入Git/交付。

下一批：其余PornHub搜索/独立列表与账号职责/UI、各模块空追加及相同前缀替换边界；再播放器生命周期、首帧/Seek/弱网/长期原生内存；四站点完整回归。保留本批route-local普通通知器，不为形式统一强行更换状态框架。
