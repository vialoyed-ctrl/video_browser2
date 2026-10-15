# PornHub独立搜索数据职责设计

目标：在原功能和交互不变的前提下，把PornHubSearchPage的请求、结果和失效代次交给路由自身拥有的控制器。原控件外部构造接口不变；不新增全局状态、不换依赖、不改解析或播放路径。

选用模块内ChangeNotifier控制器，与现有Site91MdSearchController的路由生命周期一致。沿用全站GetX控制器只适用于跨tab缓存；独立搜索是一次导航的数据，因此不用全局Get.put，避免共享或提前销毁。页面的输入框、ScrollController、筛选草稿、Focus和导航继续留在view。

控制器文件lib/app/modules/pornhub/pornhub_search_controller.dart：构造PornHubSearchController(PornHubSource source,{String initialKeyword='',String? initialPath})；拥有原videos/creators/playlists/filters/groups/suggestions/kind/creatorScope/keyword/path/loading/hasMore/started/error/nextPage/total。模型列表顺序与去重分别按视频id、创作者path、片单id保持。控制器公开只读结果与状态；过滤集合修改经明确方法。start只执行原初始路径/非空初始关键词的请求。load({required bool reset,bool clear=false,int? targetPage})保持原请求游标，成功才nextPage=请求+1；失败保留旧数据与页码。新请求与dispose使旧回复和异常失效。

页面保留_submit/_selectKind/_showFilters等交互入口，可通过控制器方法委托数据动作。稳定结果widget仍按kind/游标/模型身份失效；监听控制器替代原setState数据闭包；页脚用独立AnimatedBuilder监听同一控制器。输入和ScrollController仅view释放，控制器仅route释放。清空时仍丢弃结果widget和模型快照。历史PageFooterScope、所有golden、响应式宽度和回调保持。

原initialPath特殊语义必须保留：初始化解析filters删除search/page；应用筛选在原path上更新query，不强行变成搜索route。会员username/gender和明星search参数不变；片单路径不发keyword，keyword只筛已获得片单；空keyword提交条件不变。筛选取消不发请求，排除类别最多10个；suggestion导航按原路径执行。

本批不修正RetainedPageSliver的其他推断、不改身份/账号/订阅操作、不合并来源解析。控制器拆分是职责与生命周期改进；无测量前不声称FPS或native内存提升。

验收：原22控件契约和四golden继续通过；新增控制器级请求参数/迟到成功失败/销毁/去重/分页测试；完整测试及分析基线不退步；同中性真机探针等待时旧卡片仍0重建；正式入口四种搜索与可执行追加，正常首页恢复、三APKhash及测量清理；独立审查与可单独回滚提交。
