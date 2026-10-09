# 首页与搜索分页架构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, task-by-task. Steps use checkbox syntax.

**Goal:** 实际迁移首页/搜索的分页状态和公共网格，缩小首页重建范围且保持行为。
**Architecture:** 两控制器分别组合 PagedListState，保持公开 Rx alias。共享 VideoGridSliver 只管布局，首页 feed 拆为局部观察者。
**Tech Stack:** Flutter / Dart / GetX，使用原依赖锁定版本。
**Spec:** docs/superpowers/specs/2026-10-09-paged-list-design.md

## Global Constraints

- 页面/解析/请求头/缓存/播放器行为不变，GetX 保留，不升级依赖。
- 首页12、搜索24；防抖91 100ms/其他400ms；原去重、50页上限、跳页/追加/重试和预加载保留。
- 原 grid spacing6，home padding6/4及宽屏减73、search padding8/4、原卡片/RetainedPageSliver/AppendPaginationFooter 保留。
- 91已有结果刷新保留列表，91麻豆首屏刷新替换加载/错误。
- 两个先前生命周期修复与原角标优化保留。

## Review Focus

- 慢请求在切频道、新搜索或 onClose 后返回，不覆盖新页/结束新加载标志：Task1 延迟完成契约。
- 首页重复页与失败跳页，游标必须正确，重试同目标：Task1 去重/重复页/失败重试契约。
- 搜索 append 失败或新关键词，旧结果/目标页/作者统计语义保留：Task1 既有及新增请求契约。
- 旋转/宽屏与页追加，网格边距尺寸、页隔断、滚动位置与回调不变：Task2 像素/布局/retained append 测试。
- 91与91麻豆刷新/错误的不同显示规则，以及页脚/头部响应必须保留：Task2 HomeView 状态/重建契约。

### Task 1: Shared paging state and controller migration

**Files:** Create lib/app/core/paging/paged_list_state.dart, test/paged_list_state_test.dart; modify home_controller.dart, search_controller.dart, home_response_test.dart, search_response_test.dart.
**Interfaces:** Produce `PagedListState<T>({bool initiallyLoading=false})`: items, page, totalPages, totalItems, loadingFirst, loadingPage, hasMore, error, pageError; `int beginRequest()`, `int get requestGeneration`, `bool isCurrent(int)`, `void invalidateRequests()`; each controller exposes `paging` and preserves original Rx getters.

- [ ] Characterize home append/duplicate skip/failed jump retry and after-close reply; search stale page reply after new keyword/close; run before production changes, expect pass.
- [ ] Write state tests: independent controller states and startup flags; loading/epoch changes emit no items/page notifications; new epoch and invalidate reject old requests. Alias integration assertions require controller.paging and fail before migration.
- [ ] Run new tests, expect missing state/API; save red log.
- [ ] Implement PagedListState and replace original Rx allocation with exact aliases; replace two private request counters with state epochs; keep async flow and all site policies.
- [ ] Run full `flutter test --no-pub --reporter expanded`, expect prior and new contracts pass; inspect `flutter analyze lib test --no-pub`, only original seven info.
- [ ] Commit named state/controller files and test evidence summary; ledger actual SHA/count.

### Task 2: Shared grid and localized Home feed

**Files:** Create lib/app/widgets/video_grid_sliver.dart, lib/app/modules/home/home_feed.dart, test/video_grid_sliver_test.dart, test/home_feed_contract_test.dart; modify home_view.dart, search_view.dart.
**Interfaces:** Consume controller.paging aliases. Produce `VideoGridSliver({required List<VideoItem> items, required double availableWidth, required EdgeInsets padding, required Widget Function(BuildContext,VideoItem) itemBuilder})` and `HomeFeed({required HomeController controller, required ValueChanged<VideoItem> onDownload})`.

- [ ] Before view migration, capture actual HomeView neutral golden pixels at phone/wide widths and 91/91md refresh/error behavior. Record device baseline Profile frame samples and isolated neutral loading-flag widget builds.
- [ ] Write zero-card-rebuild contract for 91 existing list loadingFirst true/false; expect fail with baseline card rebuilds. Write shared grid layout, callback and retained append scroll tests; expect missing component API.
- [ ] Extract original feed/header/footer into home_feed.dart, introduce cached grid widget plus local Obx, preserving 91md branch and exact widget appearance. HomeView keeps scaffold/actions/download/domain responsibilities.
- [ ] Migrate both home and search91 grid builders to VideoGridSliver; retain specialized Hanime grids and all navigation/download callbacks.
- [ ] Run whole tests/golden comparison and analyze; expect preserved pixels/layout/behaviors, zero redundant card rebuilds and original info only.
- [ ] Build and run fixed neutral Profile with identical loading toggles; compare before/after widget builds. Build normal main.dart Profile, preserve-data install; capture home/search/page frames and UI behavior, restore normal app and stop test helpers.
- [ ] Commit UI files/tests, then independent whole-range review against spec; fix Important/Critical by RED→GREEN. Record report/evidence/limits/remaining module migrations and safe revert commands.

## Execution notes

用户在本计划形成前已批准阶段范围并说“开始吧”；按现有授权执行，不重复批准流程。Spec 与 Task1/2 接口自审一致；Task2 消费 Task1 的原公开 Rx aliases，无新的业务请求接口。
