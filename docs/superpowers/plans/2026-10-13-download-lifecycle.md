# 第30阶段：下载取消与立即重试边界

基线92feda8，生产尚未修改。真实服务+注入Dio网络边界，独立systemTemp目录、mock preferences；不加载/清空真实任务库、不改账号。

有效RED：test/download_cancel_contract_test.dart两项均失败：取消后迟到MP4回复改写completed；旧运行任务存在时立即retry只产生1次请求而非替换2次。旧_running按ID去重，retry提前撤销_canceled并清临时文件，旧执行仍可写入和发表状态。

要求：每次执行拥有自己的取消/失效身份；取消与remove及时撤销发表权，旧网络回复不得写回新任务；同ID重试等待旧执行退出后清理旧分片再重新排队，不能被_running吞掉。独立ID并发/上限、正常MP4/HLS输出、原UI及重试语义保持。不能只增加MP4结束时检查_canceled，因为立即retry会清除该集合。

下一步：
1. 增加迟到失败、remove/re-enqueue同ID、HLS等待回复与任务槽排队契约；为现有取消边界取得失败证据。
2. 实现按执行身份隔离及可等待的同ID完成屏障，必要时Dio CancelToken只取消自身请求，绝不关闭共享Dio/全局清缓存。
3. 正常成功输出/重试与跨ID并发契约GREEN、全量分析、只读审查。
4. 已连接Android Profile中性fixture下载取消/重试测量，隔离探针存储路径，保留正常用户下载库。
5. 正常构建/hash/home、资源清理、独立实现/报告/交接/回滚。

本批不等价于完成Media3缓存/短HLS断网/可见首帧/Seek及四站点综合验收。测试现有500ms收尾轮询在GREEN前需改为明确服务完成/网络取消/替换完成证据，避免定时偶然通过。

补充RED：download-ownership-red.log三项全失败，remove后旧MP4回复重新upsert任务。统一方案：每ID `_DownloadRun`持有CancelToken、完成Completer与撤销标记；cancel/remove撤销旧run并取消自身Dio请求。schedule发布run后才await任务slot，finally按identity移除且完成done。所有执行progress/成功/失败发表经ownsRun门禁；源解析与IO await后检查身份。retry先pending预留防双击，再await旧done，核对库中仍是本pending任务，清临时片段后解除本IDcancel并排队；enqueue同ID新任务亦等待旧run结束。HLS网络取消不得继续重试/写片，片段/合并旧IO需在done之前结束。正常跨ID并发不增加串行屏障。实现前追加latefailure/HLS/remove-reenqueue契约；不能只改MP4最终status。所有生产文件仍HEAD未改。


执行结论：实现01154d4；11契约、380全量/1原跳过、原7info；3HLS及6MP4真机、解码/hash/正常2021/清理通过。审查Important queuedcleanup与timeoutdrain均有失败契约→修复。Deferred minors: clean truncated EOF及partial-stream-error覆盖（原有范围，未计验收）。资料交付独立提交；整体目标继续。
