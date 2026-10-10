# Hanime排行与订阅分页边界（2026-10-10）

基线590e7df，实现0a370ac。先四个实际控件RED：空追加3错误把页段[1,2]改成[3]；同页同ID前缀替换2错误保留[1,2]。旧真机ARM64 Profile同四场景均复现，之后才改生产代码。

PagedListState新增成功追加标志与可观察替换代次；仅当前且未关闭的成功Hanime排行/订阅回复记录。两页面向既有RetainedPageSliver传显式语义；没有修改通用组件默认推断、其他消费者、网站参数/重复追加/解析/播放器。等待、失败和旧响应不会选择新页段。

最终实际控件测试四项含空3后非空4保留[1,2,4]、失败替换保留页段及两元数据、新9挡旧8、真实Get.delete挡关闭后append10。41项定向通过；最终完整272通过/1原跳过，分析0error/0warning/7原info，原三golden及0旧卡片重建契约仍通过。日志work/handoff-validation/hanime-boundaries。

新版同真机四场景：空追加保留1/2页与8条、请求/确认3继续原语义；同前缀替换只保留2页。等待均保留1/2，错误null、加载false、条目8。此为正确性证据，不是FPS/原生内存改善。

正式main.dart Profile构建2010、pubspec不改，保留数据安装。实际排行59→118条/第2页/总363页，订阅60→120条/第2页/总19页，两页分段各保留；flagsfalse/errornull。正常入口恢复91首页41条/第1页、flagsfalse/pageErrornull、scroll0、Rootsite91。输出/归档/手机APK SHA256一致：C8B9732D46B536D04C11051203E99A754A800ED67F77D1CAD4B2B5A62238A94B。三attach已detach，13222/2806/14004自建转发关闭，最终forward空；没有改账号或清数据。

独立只读review_hanime_boundaries检查Get4.7.3同步通知与后帧build顺序、接受响应守卫、页段增长/刷新、原回调/参数；初次Minor元数据缺断言已补并复审，无Critical/Important。最后可选Minor是关闭items只看首ID，元数据断言已捕获本实现接受迟到append路径，因此保留现有测试、不作额外修复循环。未判断事项逐项：SDK/设备由主执行者272/1及4旧错/新正确补证；hasMorefalse空追加与多页尺寸不是本新测试直接覆盖，但旧exhaustion/布局契约仍通过；原key切换/卸载恢复不改；FPS/native长期内存没有证据，不宣称验收。

工具一次误用已不存在的attach会话ID，返回Unknown process，随后使用实际30368取VM地址；没有对该失败调用声称采样成功。正式帧使用时间窗采集器仅记录当前手势，没有旧对照，不作性能提升结论。

回滚只revert0a370ac；原快照和全部以前阶段保留。摘要hanime-boundaries-profile-results-2026-10-10.json。本批结束继续路由数据职责与其他分页边界、播放器和四站点综合回归，完整重构尚未完成。
