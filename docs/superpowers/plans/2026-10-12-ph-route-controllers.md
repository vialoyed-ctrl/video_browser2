# PH 创作者/片单请求状态搬迁

Spec: docs/superpowers/specs/2026-10-12-ph-route-controllers.md
Base: 7101ef5。在现有refactor阶段分支内自行执行。

- [x] 读取两页请求、资料、账号和动作边界。
- [x] 提取PornHubCreatorController(source,path)，load/loadProfile/selectClips；view监听并dispose，保留滚动/订阅。
- [x] 提取PornHubPlaylistController(source,id)，load/resetAccount/toggleFavourite和requestRevision；view保留账号Worker/收藏写入。
- [x] 保存交接和独立回滚点。
- [ ] 测试、分析、构建、真机验收：按用户“不用验证，进行下一步”暂不执行，不宣称通过。

Ruling: 最新用户要求优先于技能默认TDD/验证门禁。本批仅机械搬迁已有逻辑，避免混入并发修正和缓存行为修改；状态为已实现、未验证。不使用此前导航319通过作为本批证据。
