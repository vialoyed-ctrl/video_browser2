# PornHub独立搜索控制器职责重构（2026-10-10）

从f8d2aed继续，实现f86ed8d。新增路由局部PornHubSearchController拥有四类型请求/数据/过滤路径/错误/下一请求游标及失效代次，不注册Get.put。页面继续拥有输入/滚动/筛选弹窗/Focus/导航/布局和当前结果widget缓存；原页脚改独立AnimatedBuilder监听同一控制器，路由退出释放监听和控制器。源码解析、播放器、账号与其他模块不改。

按Superpowers架构设计、writing-plans、inline executing-plans、TDD、只读审查和完成前验证执行；设计/计划/ledger在docs/superpowers/specs和plans。原22UI/四golden基线实际通过；新10控制器RED缺类后实现通过，测试仅替换fetchBrowse外部边界。另新增空提交滚动和非空total两个UI回归：最终24UI+10controller，完整284通过/1原跳过，分析0error/0warning/原7info。旧22功能/布局契约继续通过。日志work/handoff-validation/ph-search-controller。

自审发现_submit以已有loading决定滚动，刷新pending空输入误150→0；实际UI RED后恢复按原是否接受提交决定滚动。独立审查发现属性插值展示控制器对象而非total，真实total123 UI RED后修复显式属性插值，复审关闭Important，无剩余阻断项。中间APK在该修复前已构建，明确归档not-evidence且没有安装；最终探针53.6秒重新构建。

同PMB110真机ARM64 Profile、四模式各三轮4条等待，视频/片单卡片、创作者行、实际网格/列表全部0重建，保持上一阶段0基线。失败页1/请求2/条目4保留，视频成功8项及1/2页保留。片单header原无数字计数，itemsnull不伪造。相比上一批实际已验证新版控件，四模式裁剪[0,160,1440,3088]像素无差异。此为架构迁移没有损失既有优化证据，不宣称新的FPS或原生内存提升。

正常main.dart Profile2011（pubspec不改），真实关键词2026视频31→74→117条三页分段保留，下一请求4/加载false/errornull；切片8、创作者48、片单接口36/原关键词过滤1匹配。网站条数随时间变化，不能与先前116/21/0差异当性能或行为变化。返回后controller_disposedtrue、view_elementnull，不能称已GC。最后正常91首页41条/第1页、flagsfalse/errornull/scroll0、Rootsite91。输出/归档/手机APK SHA256一致：2F8019EE51189B92C5A228C1A867135D1339220633EE6489FA581FF9BBD767E0。两个attach已detach，自建6189/11614转发关闭、final forward空，原账号数据保留。

审查review_ph_search_controller实际确认source构造注入兼容（同id register不替换、主入口runApp前注册）、exactquery/初始路径/去重/游标/迟到回复与缓存/页脚/继承布局保持。Declined裁决：排除的来源解析/播放/账号实现未改，整体仍待综合回归；原分页推断留后续独立测试；SDK/设备由最终284/1/7、0重建/四类型/三页/hash/恢复清理补证；没有FPS/native长期内存证据，不作提升结论。

回滚只revertf86ed8d；保留全部以前阶段与快照。摘要ph-search-controller-profile-results-2026-10-10.json，计划ledger记录执行与问题裁决。继续剩余控制器/分页边界及播放器，整个重构尚未完成。
