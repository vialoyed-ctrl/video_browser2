# PornHub Search Controller Implementation Plan

> For agentic workers: use superpowers:executing-plans inline, task by task. Keep a ledger and request one independent review before completion.

**Goal:** 分离独立搜索数据职责，保留现有所有行为及已验证局部刷新。

**Architecture:** 路由局部ChangeNotifier接管请求与结果。view只拥有UI资源，控制器不持有BuildContext或ScrollController。

**Tech Stack:** 现有Flutter/Dart/GetX/PornHubSource，不新增依赖。

**Spec:** ../specs/2026-10-10-pornhub-search-controller.md

## Global Constraints

原外部page构造接口、四类型路径/去重/游标/错误、initialPath、筛选和布局保持。不得修改源解析、播放器、账号或此前阶段。先RED后实现；真机Profile保留应用数据；独立可回滚提交。

## Review Focus

关闭后旧成功/异常不能notify或更改数据；并发新查询阻止旧回复。
初始路径与筛选保留query顺序和原path语义。
空关键词/片单过滤保持原交互，不主动改变历史行为。
结果快照只在数据/模式/游标改变时失效；主题和尺寸依赖仍活跃。
controller/view监听各自恰好释放，历史页脚仍订阅正确PageFooterScope。

### Task 1: 路由控制器与原页面迁移

Files: create lib/app/modules/pornhub/pornhub_search_controller.dart; modify lib/app/modules/pornhub/views/pornhub_search_page.dart; create test/ph_search_controller_contract_test.dart; preserve test/ph_search_ui_contract_test.dart and its goldens.

Interfaces: consumes PornHubSource.fetchBrowse(String path,{int page=1,String kind='videos'}). Produces PornHubSearchController(source,{initialKeyword,initialPath}), start(), load({required bool reset,bool clear=false,int? targetPage}), submit(String), selectKind(String), selectCreatorScope(String), applyFilters(Map<String,String>), selectSuggestion(PornHubLinkItem), dispose(). start/load/submit return Future<void>; selectKind/selectCreatorScope/applyFilters/selectSuggestion only mutate selection/path and return void. State getters are read only. view remains responsible for unfocus and clear-scroll.

- [x] Write controller tests using existing PhSearchFixture and actual deferred external replies: videos/clips/member/star/playlist exact paths; result order and per-type dedup; reset/append/failed page retry; stale success and stale failure; dispose while pending. Assert no listener notifications after disposal and original state does not change.
- [x] Run the new controller tests before implementation; record missing controller RED. Re-run original22 UI/goldens as baseline before migrating.
- [x] Move original request/path/state code into controller with _disposed and generation guards. Keep immutable public result views, mutable filter changes through methods. Do not change parsing or add side effects.
- [x] Delegate page interactions to controller, keep UI-owned resources and stable result cache; listen to controller for view changes and independent footer AnimatedBuilder. Preserve clear-scroll timing and initialPath filter application.
- [x] Run new contracts + original22 UI/goldens; failures use systematic-debugging. Full suite and analyze must match or improve baseline.
- [x] Independent review entire diff. Resolve real issues with tests; record unjudged runtime limits.
- [x] Reuse real-control neutral probe adapted only for controller inspection, compare waiting rebuilds against previous0 baseline; normal main.dart Profile actual four types/search/append and restore homepage/hash/cleanup. No FPS/native claims without evidence.
- [x] Commit production+tests separately from report, add evidence and reverse-checked binary patch. Update handoff by append.

Self-review: every spec behavior pinned by existing22 UI contracts or new controller request/disposal contracts; no source/player/account scope expansion. Inline execution follows user's continuous-work instruction; independent reviewers remain read only.
