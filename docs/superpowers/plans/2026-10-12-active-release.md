# 活跃播放器释放实施

Spec: docs/superpowers/specs/2026-10-12-active-release.md；Base ce6fe03。既有隔离分支inline执行；持续授权与测试/真机/审查目标。

- [x] 调查SDK pause/dispose与Android release实现；有效RED1通过2失败。
- [x] Android真实后端中性MP4旧六轮释放/切换对照。
- [x] 最小异步best-effort pause和await dispose，普通/失败/挂起/切换顺序契约。
- [x] 定向/全量/分析/独立代码审查及新六轮真机对照。
- [x] 正常入口构建/首页/hash/临时服务清理、报告/回滚，继续其它生命周期及四站点。

Ruling: 本批证据仅针对最后一次pause回复等待，scrub/Seek等待独立保留，不谎称解决所有慢操作。只有旧真机前态完成后才改生产。

Task complete260153c：19定向/349全量/1原跳过、原7info；Android旧六轮>1s、新六轮释放60–77ms、3切换命令172–200ms；正常2017恢复，传输和server关闭。独立审查Minor晚到异常已覆盖。旧probe switchCompleteMs blocked样本只作观测时间，原始保留，派生摘要正确标注未完成。完整项目仍继续。
