# 实际原生资源与重复播放验收

基线1d9b11a，本阶段先测量验收，不为取得计数修改生产插件。真实PlayerView/GetX生命周期、真实PlayerController和AndroidVideoPlayer；观察子类继承全部Android功能，只观察create/dispose成功RPC。中性仓库Butterfly MP4通过本地Range服务，假91详情只返回fixture，观看扩展no-op；UserService覆盖recordHistory且不init，不写真实用户数据或账号。

使用ART Java HPROF解码实际VideoPlayerPlugin.videoPlayers映射（mValues跳过DELETED占位项）、MediaCodec.mNativeContext非零及Surface.mNativeObject非零。解析工具先6项合成二进制契约，4/8字节ID、继承字段、缺字段不可用、损坏/未知记录拒绝及tombstone；原始堆不输出/提交/交付，仅聚合结果。官方ART/LongSparseArray格式为依据，堆GC会影响内存数值，记录前后区别。

同PMB110验证idle/playing/close，至少60次实际路由开/播放/关闭，夹带暂停恢复、倍速、Seek、scrub；按0/10/30/60闭合节点收集native/Java/graphics/PSS/RSS及堆句柄。另记录实际中性视频画面及全屏返回。native position只是平台位置，不当可见Seek首帧；资源计数也不当完全无任何泄漏证明。测试失败先诊断，再单独TDD小修，不修改解析/交互。

恢复正常main与原数据，移除自建连接/server/手机临时堆，报告资源可用性、过程、剩余外部限制；原始本地堆在聚合确认后删除。

实际执行追加900秒中性循环播放、0/300/600/900快照和30秒状态采样；基于审查，60路由循环只计资源释放，不计其控制行为通过。独立暂停/恢复及全屏返回完成，Seek/拖动画面仍后续验收。
