# 第34阶段：Hanime订阅账号请求边界

基线72b639d。有效RED：账号A请求等待期间切换UID为B，A迟到回复写入B列表。扩展登录退出、已有内容清理、旧错误隔离新加载和匿名原行为契约；先记录RED再修。

注册控制器现有onInit监听auth.isLoggedIn/userId；账号变化先invalidate subscription paging request，再清账号私有创作者/订阅结果/页码与loading/error。保留站点筛选值；不自动发新网络请求，不修改解析/登录持久化。onClose释放Worker。全量既有UI与请求契约、只读审查及Profile仅mock账号探针，无真实logout/写账号；正常2023恢复后交付独立提交/补丁。
补充：无UID仍有登录邮箱/用户名时已有效4RED，worker扩展既有身份字段；无任何标识的原匿名结果UI-only登录提示变化行为保留。10新契约包括全部筛选不变/creator-error清理/Worker释放；目标26通过。
