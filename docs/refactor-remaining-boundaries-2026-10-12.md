# 首页/通用搜索/PornHub搜索成功分页语义（2026-10-12）

基线a594fc5，实现6f01e5b；测试稳定性独立提交d3a00c6。六个生产文件仅新增20行，成功current响应后明确append/replacement；Home/Search复用已有PagedListState，PH路由局部控制器公开只读标记，view缓存加入replacementGeneration。保留原去重/顺序/请求/失败/重试/当前页导航no-op、Home空页自动继续请求策略，公共RetainedPageSliver与PagedListState未改。

新增六真实UI契约：Home空页后探下一页、同前缀替换；通用搜索空追加、刷新并保留同页导航no-op；PH空追加、同前缀数字目标回调。首次Search测试误把no-op当新请求，出现Future already completed，修正fixture而非改交互；修正后46项42过4败，新增Home空页单独RED（Home6过2败）。五个唯一边界失败，原Search刷新已正确。最终定向60、完整294通过/1原跳过，lib/test原7info、0error/0warning。原订阅计数实时时间190ms曾在完整并发下Actualnull，独立重跑通过；该测试改虚拟时钟pump160ms触发原160ms防抖并flush，保留总数停止/请求数/刷新断言，应用PH主控制器未改。独立审查无阻断，Minor无赋值pending/awaitnull删除；无关SearchView格式恢复，最终只必要差异。

PLK110/API37/ARM64 Profile中性真实页面，同一探针三mode×两scenario×三轮18对照：旧15轮页段错误，Search刷新3轮本来正确；新18轮全部正确、数据8项不变。空追加保留1/2页段，替换Home/PH只留2，Search刷新只留1；Home继续第4页后1/2/4。同页目标为页面实际footer callback，不声称点击禁用当前数字按钮。首次探针编译3错误已在有效基线前修正并preflight通过，未装失败包；after一次已连接app被重启造成DDS断连，排除该collector错误，重新attach再取得有效18轮数据。

正式main.dart2014：首页{'items': {'length': 41}, 'page': {'value': '1'}, 'loadingFirst': {'value': 'false'}, 'loadingPage': {'value': 'false'}, 'hasMore': {'value': 'true'}, 'pageError': {'value': 'null'}}→{'items': {'length': 129}, 'page': {'value': '5'}, 'loadingFirst': {'value': 'false'}, 'loadingPage': {'value': 'false'}, 'hasMore': {'value': 'true'}, 'pageError': {'value': 'null'}}，真实页段见JSON；PH搜索2026视频31→74，两页保留，nextPage3/loadingfalse/errornull；退出后disposedtrue并不证明GC。91实际搜索及一次重试均返回检索网络错误，作为待诊断失败，未宣称此项通过。正常重新启动后首页41/第1页、scroll0、Rootsite91。三APK一致SHA256：AA19C5F370FB97DC17DCEDDA1EDA2F3F9A99BCDF0935D18E059D5BFB0BA36FD5。自建4476/5180/13338/3006/11441转发移除，detach、forward/reverse列表为空。

当前首页翻页窗口14动作、2107帧，Build P95 1152us，Raster P95 4093us；窗口按VM时间过滤DDS旧帧。没有改动前同场景FPS对照，仅当前描述；Dart GC数字不代表native泄漏或内存提升。原golden布局/等待零结果重建契约继续通过。

可独立revert6f01e5b，稳定测试另revertd3a00c6；旧快照与全部之前阶段保留。继续创作者/片单等剩余路由与账号列表、活跃播放器/首帧/Seek/弱网/native长期内存，以及四站点综合回归；整个项目尚未完成。
