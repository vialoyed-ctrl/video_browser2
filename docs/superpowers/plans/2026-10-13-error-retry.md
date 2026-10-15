# 第29阶段：HLS弱网错误重试命中修复

基线26ccff3。原快照和第28阶段交付保持；生产仅PlayerView错误层级，站点规则/控制器/缓存/播放器实现不改。

- [x] 真机60秒中性HLS，独立run路径，1500ms分片延迟；503触发源错误，顶部刷新恢复，最终native3创建/3释放。
- [x] 实际UI重试中心无响应、截图确认底部控制栏覆盖；命中路径确认400宽度命中底部控制。576控件已点击，原异步分配条件假失败，改为同步SDK所有权撤销。
- [x] 有效RED1通过/1失败；错误背景保留在控制栏下方，错误内容上移至控制栏上方，非动作文字/图标IgnorePointer，正常布局不改。
- [x] GREEN6控件：400/576重试、顶部刷新、正常暂停。失败的装饰背景穿透尝试已撤回，不纳入最终实现。
- [x] 全量测试/分析。
- [x] 独立只读审查并处理具体问题。
- [x] 同机Profile503错误后中心重试3轮，恢复后实际页面/原生position推进与退出清理。
- [x] 正常main.dart构建/hash/home及所有临时资源清理。
- [x] 独立实现/报告/交接提交与反向可验补丁。

弱网源错误本身不作为缺陷；保持原自动尝试与手动重试语义。主要修复错误按钮原有操作可达性，不声称自动断网恢复/FPS/可见Seek优化。HLS短暂中断、缓存/下载和最终四站点仍需继续。

Final: implementation6a73ff6, full369/1, analyzer old7info, actual3 native retry rounds and normal2020 verified. Review no blocking findings. Deferred minors: hiddencontrols case; preexisting enlarged-text/long-error overflow. No arbitrary automatic retry behavior change.
