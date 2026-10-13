# 第34阶段：Hanime订阅账号请求所有权

基线72b639d。旧行为：账号A的订阅请求未结束时切换/退出，迟到回复把A的数据写入当前列表；已有A内容也保留。先有效RED三种场景，再修。仅UID边界初版又证明4个空UID邮箱/用户名账号场景失败；扩展到已有auth.isLoggedIn/userId/userEmail/username。

控制器onInit注册可释放Worker，账号字段变化先使subscriptionsPaging请求世代失效，再清已知会话的订阅items、subData、creator、页码、hasMore、loading/error。保留类型/排序/日期/时长/tags/broad全部筛选，不自动发请求，不改解析、认证Cookie或持久化。onClose释放监听。所有标识为空时保留现有匿名结果UI-only登录提示变化契约，但仍使旧请求失效。

10新契约覆盖UID/邮箱/用户名切换及退出、已发布内容清理、旧错误不结束新加载、新账号成功、匿名加载、私有creator/error清理/筛选全保留和Worker释放；26定向通过。390全量通过/1原跳过。复审无Critical/Important/Minor。分析0error/0warning、7原有info；10新契约在风格修正后再次通过。PMB110/API36 Profile真实订阅Tab与纯内存auth/source共16步骤5请求全部通过，不代表网站真实登录或网络验收，也未宣称FPS/内存改善。正常2023已安装：首页41项、第1页、滚动0、site91、加载false/错误null，三APK一致SHA FB314C0BA68A9F0694439D0BFC774D9016B4E61A22BFB2E3823E1AC45AC4E44A。探针关闭、Controller/Worker已释放，自有attach及forward清理。

此前26定向包含原有retained/UI golden。第一次实现误清匿名结果，原有UI契约失败，修订后保留原样；不改变该测试期望。真实手机探针只使用内存auth和受控source，无真实login/logout/init/prefs保存，不影响用户账号。

余项仍包括其他生命周期、列表更多页面、91搜索诊断和四站点综合回归。第33阶段编码录屏计时精度限制继续保留。

实现b3ecf2a，可独立git revert回滚。摘要见hanime-account-profile-results-2026-10-13.json，原备份保留。匿名UI-only标志契约是所有身份字段都为空的原有行为；真实登录至少产生邮件/用户名，因此不能以UID为空忽略已知会话。
