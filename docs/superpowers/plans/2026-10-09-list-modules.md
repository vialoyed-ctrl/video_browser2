# Independent list modules implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Reuse paging state in Hanime1/PornHub lists and isolate PornHub footer updates without changing behavior.
**Architecture:** Controllers retain source-specific policies. Existing Rx APIs alias shared state. Actual PornHub grid and retained page/footer components remain unchanged.
**Tech Stack:** Flutter, Dart, GetX, flutter_test, physical Android Profile, VM service.
**Spec:** docs/superpowers/specs/2026-10-09-list-modules-design.md

## Global Constraints
- Preserve all website parsing, player/cache behavior, account data, styles and pagination rules.
- Hanime1 append preserves duplicates and subscriptions start with hasMore=false.
- PornHub failed append retries its original page; path caches remain independent.
- Do not clear Android app data; restore normal main.dart Profile at the end.
- Existing Home/Search, download badge and player fixes must remain intact.

## Review Focus
- Older refresh cleanup must not clear newer request's loading flag.
- Account change or close must reject pending PornHub path replies.
- Empty success and refresh failure preserve each site's existing UI/paging behavior.
- Retained inactive page footers keep their own number and cannot auto-load.
- Hot sort switches must retain path cache independence and existing scroll behavior.

### Task 1: Shared paging state in independent site controllers
**Files:** lib/app/core/paging/paged_list_state.dart; lib/app/modules/hanime1/hanime1_controller.dart; lib/app/modules/pornhub/pornhub_controller.dart; test/list_modules_paging_contract_test.dart.
**Interfaces:** PagedListState<T>({bool initiallyLoading=false,bool initiallyHasMore=true}); Hanime1Controller.rankingPaging/subscriptionsPaging; PornHubListState.paging. Old public fields/accessors remain consumer compatible.
- [x] Add old behavior tests: initial append gating, duplicate append, actual server page/total, stale successes/failures/cleanup, retry same page, filter payloads, independent paths, account/close invalidation.
- [x] Run characterization tests against 252fbe9; Expected: all pass.
- [x] Add migration consumer test updating shared state and observing legacy outputs; run tagged test. Expected: missing shared state API failure.
- [x] Implement aliases, hasMore constructor default and Hanime request generations; retain PornHub request policy and public integer accessors.
- [x] Run full contract tests and existing Home/Search state tests. Expected: all pass.
- [x] Commit independently as refactor: share independent site paging state.

### Task 2: Isolate PornHub list/footer subscriptions
**Files:** lib/app/modules/pornhub/views/pornhub_video_list_tab.dart; test/pornhub_list_view_contract_test.dart; test/goldens/pornhub-list-400.png; test/goldens/pornhub-list-900.png.
**Interfaces:** Consume unchanged PornHubListState fields and shared page observable. Keep SliverPornHubGrid, RetainedPageSliver and footer behavior.
- [x] Add real-view golden/behavior tests (empty priority, retained append, replacement and sort); generate goldens from original UI. Expected: pass before production edits.
- [x] Add loading/footer/error-only card rebuild test. Expected: baseline cards rebuild and test fails expecting zero.
- [x] Build temporary ignored neutral actual-view Profile probe; collect 10 loading toggles before edits. Expected: four retained cards, nonzero baseline builds, save raw timeline.
- [x] Split path shell, empty/content selection, grid and footer observers; preserve scroll ownership and retry/sort callbacks.
- [x] Run view tests with original goldens. Expected: all pass, zero card rebuilds on loading/error-only changes.
- [x] Repeat matched Profile probe, restore formal main.dart ARM64 Profile, collect formal scroll smoke. Expected: probe card/grid counts fall, normal entry restored without data loss.
- [x] Run flutter test --no-pub and flutter analyze lib test --no-pub. Expected: full suite passes, 0 errors/warnings, original 7 info only.
- [x] Commit independently, request one fresh read-only whole-batch review, address important findings with RED/GREEN, report limits and rollback.
