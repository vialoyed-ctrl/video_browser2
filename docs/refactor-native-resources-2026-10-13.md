# 实际PlayerView原生资源测量（2026-10-13）

生产基线1d9b11a，生产源码未改；本批补充验收证据，不宣称新增性能优化。真实PMB110/API36，PlayerView/GetX路由、PlayerController、继承完整AndroidVideoPlayer能力的观察子类。仓库中性Butterfly MP4经本地Range服务；预热数0，只读UserService不init且recordHistory覆写为空操作，Site91观看扩展no-op，原账号/数据/快照保留。

实际ART堆计数：idle→playing→closed插件播放器映射0→1→0，MediaCodec非零native context 0→2→0，Surface非零native object 2→3→2。真实视频截图已检查。60轮进出，第0/10/30/60轮退出后均0/0/2；夹带倍速、Seek、暂停和scrub调用，但cycle错误字段在close后为空，不能认定每个控制行为已验收。独立审查指出该缺口，报告限定资源结论。

持续循环播放900秒，每30秒31次状态采集均initialized/playing true、error null、单一播放器；0/300/600/900秒实际堆均1/2/3，最终退出0/0/2。原生位置不是可见首帧/Seek到帧计时。另单独实测暂停700ms平台位置基本稳定（7029→7052ms，差23ms）、恢复700ms跨7540ms循环边界推进到503ms；全屏/窗口截图已检查，控制段最终退出RPC映射为空，未另采ART快照。这不涵盖后台、HLS、弱网、缓存下载或四站点真实播放。

堆解析6项工具契约通过：4/8字节ID、继承字段、缺字段不可用、损坏/未知记录拒绝、LongSparseArray DELETED删除占位。原始堆仅私有临时文件，聚合确认后删除；不提交或交付。Java heap dump强制GC，内存前后分别记录；Graphics摘要为private dirty/RSS，不冒称PSS。JNI wrapper句柄恢复基线不能证明所有native/GPU分配无泄漏，也不能据几次PSS波动声称长期无增长或优化收益。

格式依据：[ART HPROF writer](https://android.googlesource.com/platform/art/%2B/46af48acf4221a7f819d58dfffb576d0523ae285/runtime/hprof/hprof.cc)、[LongSparseArray实现](https://android.googlesource.com/platform/frameworks/base/%2B/master/core/java/android/util/LongSparseArray.java)、[Android堆快照文档](https://developer.android.com/studio/profile/capture-heap-dump)。实际字段存在由每份堆验证，缺失输出null，不能填零。

独立只读审查：资源限定结论无Critical/Important；control-state缺口保留在下一控制验收，不假装已修。cleanup Minor补验证header，真实清理结果单独记录。第26批354通过/1原跳过、0error/0warning/原7info属于未变生产基线，本批工具6测试为新跑。并行启动第28批故障测试，当前1过4败且未提交，明确保留RED，不宣称当前整个测试目录全绿。

正常2018保留数据恢复，归档及手机APK SHA256 9016E568F5C1AD3380EA1D9575866D9FAE0BABF7C9EB4A54A652488859E5C6AC；正常首页、布局状态及本批连接/服务/堆清理详见JSON。复用已验证的未变正常APK，未宣称本批新构建正常入口。手机最终正常入口。

剩余：scrub/Seek悬挂回复释放及迟到任务归属、可见首帧/Seek、背景/全屏复杂切换、HLS/弱网/缓存下载、剩余列表审计和四站点综合回归。第28批已取得正常恢复等待确认对照GREEN与四释放RED，旧Android故障probe已构建未安装，下一批先旧真机故障测量再实现；整个项目尚未完成。

审查Minor已闭合：计划把正常恢复/清理与后续未完成领域分开；摘要新增31有效/0无效状态计数；暂停23ms误差如实列出。videoRectPx只是内部VideoPlayer几何，不作可见画面裁剪或时延证据。独立文档提交及回滚patch按最终Git记录交付。
