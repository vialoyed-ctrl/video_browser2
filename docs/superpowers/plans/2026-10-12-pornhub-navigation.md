# PornHub 导航修复实施计划

> 使用superpowers:executing-plans在当前既有阶段分支逐项执行，独立代码审查。用户已授权持续完成及修复模块跳转。

**Goal:** PH作者和模块入口保持PH数据源，不串到91。
**Architecture:** 可选authorUrl保存实际metadata，模块路由明确target；缺链接采用已有PH搜索（creators初始模式）。其他站点接口和UI默认值不变。
**Spec:** docs/superpowers/specs/2026-10-12-pornhub-navigation.md

- [ ] 导航入口矩阵及旧7项契约RED、真机作者点击前态。
- [ ] 最小实现模型链接保留/作者回调/PH目标和搜索初始模式；保持原页面其他默认值。
- [ ] 解析及其他入口契约、失败/旧记录/源错误归属边界，GREEN/全量/分析。
- [ ] 新真机作者点击及模块代表入口；只读独立审查，修正阻断项。
- [ ] 正式入口/手机hash/首页/临时连接清理，独立提交、证据、回滚；继续原剩余重构。
