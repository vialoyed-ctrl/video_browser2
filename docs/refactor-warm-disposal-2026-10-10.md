# 预热播放器释放等待边界（2026-10-10）

基线9915327，实现baa1c94。PlayerService的预热slot从不播放，take返回前清空所有权；清空/替换直接best-effort dispose，移除冗余pause等待。活跃PlayerController暂停、拖动、播放、销毁和网站解析保持。

先使用真实AndroidVideoPlayer及中性Butterfly MP4；只在真实native pause后挂起Dart回复，create/events/dispose仍委托真实平台。旧实现清空三轮和替换三轮均未在1000ms内释放旧实例；修复后清空92/81/86ms，替换248/397/360ms内收到旧实例dispose确认，替换仍保留新实例。替换窗口包括新初始化，不是纯dispose耗时。每轮解除故障后等待全部native确认，最终active为空。首次旧探针清理100ms不足的样本排除；改为最多3s清理后才形成有效对照。

新增两项挂起pause回复契约，RED10通过/2失败、GREEN12通过；完整286通过/1原跳过，分析0error/0warning/原7info。测试fake第一次无条件await空future导致异步调度伪失败，修正为仅等待实际gate；新item期望漏fixture前缀也已纠正。独立审查无Critical/Important；Minor整份LF转CRLF已恢复原LF，最终差异41新增5删除。

正常main.dart ARM64 Profile2012构建/安装，实际91视频控件一次观察00:29/03:39，返回首页41条、第1页、加载false、error null、scroll0，Root site91。第二快照控件隐藏，不声称第二进度或可见首帧。三份APK SHA256一致：6D5832069736F31D7A5F0547FAC4BA2E423C106D08F5C8A078A8E0670F6291E8。detach；关闭自建5129/3867/4802/14993转发、8787反向映射及本地服务。

不声称FPS、可见首帧、Seek或长期native内存改善；dispose确认和Dart活动集合并不证明Java/GPU资源GC。native create/dispose自身挂起或失败仍保留原best-effort边界。本批可单独revert baa1c94，旧备份与前阶段不改。剩余架构路由、分页、活跃播放器控制/可见画面与native内存、四站点综合回归继续执行。
