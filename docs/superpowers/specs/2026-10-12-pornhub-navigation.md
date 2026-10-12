# PornHub 导航归属修复设计

用户明确要求检查并修复PornHub模块全部跳转错误；优先作者名误进91搜索。保留所有其余网站、播放器、布局、导航栈和账号动作。基线99c66e1。

根因：共享视频卡片和详情作者fallback调用AppNavigator.toAuthor(author)，它使用Get.find<VideoSource>()；PornHub使用独立模块，global source仍为91。列表解析已有uploader anchor，却只保存名字，丢失href。

采用保留实际authorUrl的可选模型字段（copy/JSON兼容旧记录）；视频/切片/详情只保留已读取的链接，不改变原解析选择规则。模块显式作者导航：有效原站作者路径打开现有CreatorPage；旧记录或缺链接在PornHub创作者搜索内兜底，不猜作者slug。共享卡片允许作者回调；跨模块相关/历史卡片按video上下文识别PH。详情面板优先原extra creator/pornstar path，再用卡片链接，最后PH搜索。

逐项核对主界面搜索/更多、分类/明星/片单、搜索creator/playlist、订阅creator、个人playlist、详情标签/作者、全部共享PH视频网格。正确的目标及source保留，错误入口加契约；绝不通过切换global source解决，以免影响91及播放器。

先旧UI和真机复现；新契约覆盖global91下PH卡片、横卡、已知model/pornstar/channel链接、旧JSON、91未变，以及既有各路由行为。回归、分析、前后真机、独立审查、正常入口恢复和hash、单独提交/回滚。不进行真实订阅/收藏/登录写入。
