# Native资源测量实施

Spec docs/superpowers/specs/2026-10-13-native-resources.md；基线1d9b11a；持续目标inline执行。

- [x] 正常2018堆可取得，ART格式/稀疏deleted语义与6项工具RED/GREEN；正常首页基线0映射/0codec/2surface。
- [x] 实际PlayerView中性probe，idle/playing/close资源快照、截图和控制基础验收。
- [x] 60实际路由循环，闭合0/10/30/60内存/堆；如有异常先定位与TDD，不假定通过。
- [x] 工具/probe独立只读审查，证据限制及剩余项报告；无生产变化则不宣称优化收益。
- [x] 正常入口恢复/hash/home、自建连接/服务和原始堆清理。

执行补充：60轮closed0/10/30/60均0/0/2；追加900秒持续播放31状态样本及4快照1/2/3，最终0/0/2。全屏/窗口截图已检查，独立暂停700ms位置基本稳定（23ms差异）/恢复700ms推进。cycle控制错误字段在close后清空，不计Seek/倍速/scrub成功，审查已限定资源结论；下一控制验收保留缺口。正常2018保留数据复用恢复41/1/site91、同hash，转发/reverse/server/原始堆均已清理。

Ruling: 并行准备第28批test/scrub_release_contract_test.dart当前1过4败且未提交，生产lib未变；报告明确列出，不能称当前全套通过。第26批354/1只作为生产基线证据。详见docs/refactor-native-resources-2026-10-13.md及摘要。

交付：最终独立文档提交和回滚patch以Git核对；不能将以下后续任务计入本批已完成。
- [ ] HLS/弱网/缓存下载及四站点综合验收。
- [ ] scrub/Seek释放取消与迟到归属小修、可见画面计时、剩余列表审计。
