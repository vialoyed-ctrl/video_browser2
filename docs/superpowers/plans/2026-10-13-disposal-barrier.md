# 并发释放屏障实施

Spec: docs/superpowers/specs/2026-10-13-disposal-barrier.md；Base755691a；既有隔离分支inline持续执行。

- [ ] 有效unit RED，核对旧释放置空与generation边界。
- [ ] Android真实旧6样本，gate在真实native.dispose调用之前，解除后完整清理。
- [ ] _disposeCurrentPlayer共享Future、原body迁到_releaseCurrentPlayer，仅待释放任务存在时复用；finally按身份清空。
- [ ] 原最后pause契约+新并发/退出契约GREEN，完整/分析/只读审查，新同设备对照。
- [ ] 正常构建恢复/hash/home/临时工具清理、证据和回滚；继续剩余播放器和四站点验收。

Ruling（审查后RED）：初版屏障调用release至赋值之间的Rx同步重入窗口已实际测试失败；先发布Completer.future再启动原同步清理，保留原Rx更新时机，并转接release成功/错误。另两个reload关闭/最新目标测试实际失败，reload须捕获自己的generation并在等待后核对，不让已失效重载重新打开。这些属于相同释放所有权边界，纳入本批，不把关闭保证限缩成只有switch。有效追加RED8通过3失败。
