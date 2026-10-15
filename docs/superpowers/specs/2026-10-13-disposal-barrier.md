# 同一路由并发切换共享释放屏障

基线755691a。旧释放流程在await native dispose之前已将当前controller置null；第二次switch可能将null当成无待释放资源并提前创建另一个native player。

同一PlayerController的释放调用共享进行中的Future；所有请求继续用原generation检查latest-wins。旧native dispose确认前不创建新实例；退出使所有待切换目标失效。最后pause不阻塞dispose的260153c行为、scrub/Seek等待、解析/UI均保留，不添加超时。任务完成后释放future引用，后续正常释放仍可重新开始。

先8项unit（原6+2新）RED及同设备Android中性MP4实际旧native dispose调用前挂起gate，3rapid switch/3switch+close观测旧native仍在是否额外分配；再最小屏障/GREEN/全量/分析/独立审查/新对照。普通用户操作及正常入口保留，原快照/提交可回滚。nativeRPC/瞬间active数量不是长期内存或first-frame证据。

Ruling（审查后RED）：初版屏障调用release至赋值之间的Rx同步重入窗口已实际测试失败；先发布Completer.future再启动原同步清理，保留原Rx更新时机，并转接release成功/错误。另两个reload关闭/最新目标测试实际失败，reload须捕获自己的generation并在等待后核对，不让已失效重载重新打开。这些属于相同释放所有权边界，纳入本批，不把关闭保证限缩成只有switch。有效追加RED8通过3失败。
