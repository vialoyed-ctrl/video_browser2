# 独立站点分页状态与 PornHub 列表订阅设计

起点：252fbe9，完整基线177通过、1原有跳过。用户要求继续分阶段重构，保持全部功能与解析/播放/UI行为，先测试、测量再修改。本批沿用已有隔离重构分支和原源码快照，不重复上一批工作。

统一公共状态容器，保留控制器的业务策略，风险低于统一所有抓取算法或更换状态管理框架。范围是 Hanime1 排行/订阅，以及 PornHub 推荐/最热按路径缓存的列表。Hanime1 结构化首页、按用户缓存、PornHub账号聚合流和播放器留待后续独立阶段。

Hanime1 新增 rankingPaging、subscriptionsPaging，旧公开Rx字段作为同一个状态的别名。两类请求继续共用各自单个加载标志，追加不去重；订阅初始hasMore=false。PagedListState新增initiallyHasMore，默认true保持Home/Search契约。内部下一页游标不改。

PornHubListState组合PagedListState，旧items/isLoading/isLoadingMore/hasMore/error/page接口保留；request仍为原整数业务代数，保留公开可写语义。page以int访问代理到共享Rx页码，避免两个页码存储失步。按路径实例、刷新失败保留内容、追加失败页码回退、账号重置与关闭失效逻辑均不改。

PornHub列表将路径、空态、网格和页脚分别订阅。已有内容下的加载和错误只更新页脚；空列表保持原loading优先、错误次之、空提示兜底。RetainedPageSliver保留页边界和PageFooterScope，排序变化保留原滚动控制器，卡片和原SliverPornHubGrid几何不改。不在本批顺带修改自定义padding规则。

验收：控制器旧行为特征测试；更新共享状态能经旧接口驱动消费者；手机/宽屏原像素金图；加载/错误更新不重建已有卡片；追加保留页脚、跳页替换、排序与空态；真机Profile四个中性卡片十次加载切换前后计数，最后恢复正式main.dart Profile且保留数据。不得把固定场景重建减少写成整体帧率、长期内存或成功网络结果提升。

回滚：状态迁移和UI订阅各独立提交，逆序revert本批提交，保留此前所有修复与报告。阶段结束更新CODEX_HANDOFF并输出报告、数据摘要和反向检查通过的补丁。
