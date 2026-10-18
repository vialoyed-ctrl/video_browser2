# 91 源域名自动检测 —— 交接说明（2026-10-18）

## 1. 一句话结论

91porny 的内容域名不再依赖用户手输：打开「选择内容域名」对话框即自动扫描地址发布页、
提取直连清单、逐个探测，**命中第一个可用域名就停止检索**，然后自动加入列表、选中、
持久化并关闭对话框。换域名成功后自动清空页面缓存。

## 2. 改动文件

| 文件 | 类型 | 说明 |
|---|---|---|
| `lib/app/data/sources/site91_source.dart` | 修改 | 新增发布页发现链路 + 缓存清理（+485 行） |
| `lib/app/widgets/domain_picker.dart` | 修改 | 对话框打开即自动检测、自动采用（+137 行） |
| `test/site91_domain_discovery_test.dart` | 新增 | 4 个确定性用例（注入式适配器，不联网） |
| `test/fixtures/site91/publish_page.html` | 新增 | 真实 `dizhi360.com` 响应（1487 字节，JS 空壳） |
| `test/fixtures/site91/publish_script_head.js` | 新增 | 真实 `publish.js` 前 2600 字符（含 30 个明文直连） |

**未改动**：91麻豆（`site91md_source.dart` / `site91md_domain_picker.dart`）、播放器、
下载、预加载、搜索模块、任何其它 UI。

## 3. 对方站点的事实（实测，2026-10-18）

```
dizhi360.com                    HTTP 200，正文仅 <div id="main">，无任何链接
  └─ res.kingslord.com/dizhi/publish.js?20260521
       └─ 字符串表里明文 50 个 91tanhua301.sbs ~ 91tanhua350.sbs
            └─ https://www.<host> → 42/50 返回 200，title 均为「九色|91PORNY|…」
```

- 页面展示的「最新地址」10 条是按时段轮换的（周期 7595904 ms ≈ 2.11h，A/B 两组各取 5，
  `startOffset=1`，基准 `2021-11-12T16:00Z`）。
- **刻意没有复制这套轮换算法**：它依赖 `publish.js` 里被混淆过的字符串表下标，
  对方改一次混淆就失效。改用「50 条全量 + 倒序（编号越大越新）+ 并发探测」，
  效果等价且不依赖对方内部实现。
- 号段 `dizhi360~999` 存活率约 5%（本次实测存活：360、365、444、678、930-939、956、960、968）。

## 4. 代码结构

### 4.1 `site91_source.dart`

| 位置 | 符号 | 作用 |
|---|---|---|
| L35 | `DomainDiscoveryResult` | 检测结果值对象：`domain` / `publishHost` / `testedPublishHosts` / `testedDirectLinks` / `timedOut` |
| L200 | `clearHtmlCache()` | 清内存 HTML + 磁盘 `site91_html_cache_v1_*` + 详情缓存 |
| L602 | `_publishHostFirst/_Last` | 号段 360~999 |
| L616-627 | 四个常量 | 直连超时 4s / 发布页超时 2.5s / 直连并发 8 / 号段并发 16 |
| L630-636 | `_discoveryBudget` / `_publishScanBudget` | 总预算 25s，发布页阶段子预算 15s |
| L645 | `discoverWorkingDomain()` | **主入口**，供对话框与请求链共用 |
| L760 | `_firstMatch<T>()` | 有限并发 + 命中即停止派发 |
| L807 | `_publishHostCandidates()` | 上次成功 → 968/969 → 360~999 |
| L829 | `_fetchPublishPage()` | 拉发布页，判据宽松（有 `publish.js` 或 `id="main"` 即算成功） |
| L858 | `_extractDirectLinks()` | 正则 `91tanhua(\d+)\.sbs`，从 HTML + 脚本两处提取，倒序 |
| L930 | `_probeDirectLink()` | 200 + 长度 ≥2000 + 非质询页 + **是 91 站点** |
| L955 | `_looksLikeNinetyOneSite()` | `video-elem` / `colVideoList` / 标题含「九色」「91porny」/ `/video/view` |

另有两处行为修改（非新增）：

1. `_findReachableDomain()`（原 L481）在 `defaultDomains` 全部失败后接上
   `discoverWorkingDomain()`。**这修的是一个真实缺陷**：`defaultDomains` 现在只剩
   `https://www.91porny.com` 一个，原先「自动切换备用域名」实际上永远返回 null。
2. `_notifyDomainChanged()`（原 L532）在 `previous.isNotEmpty` 时触发 `clearHtmlCache()`。
   启动时 `previous` 为空（首次恢复保存域名），**不清** —— 那时缓存还没载入，
   清它只是白丢冷启动预热。

### 4.2 `domain_picker.dart`

| 位置 | 符号 | 作用 |
|---|---|---|
| L97 | `_loadCustomDomains().then(_autoDetect)` | 先读完手动清单再检测，避免两个 setState 互相覆盖 |
| L108 | `_autoDetect()` | 检测 → 命中则加入列表 + 选中 + 保存 + `pop(true)` |
| L148 | `if (_userTouched) return` | 用户已手动干预则不抢方向盘 |
| L335 | `_autoStatusRow()` | 进度条：`正在查找地址发布页…（已试 N 个）` / `正在探测直连域名…（已试 N 个）` / 失败提示 |

`_userTouched` 在三个位置置 true：点选条目、点「测试」、输入框 `onChanged`。

## 5. 为什么必须清缓存（这是最容易踩的坑）

`_request()` 在自动切换域名后，把**新域名**取回的 HTML 存回**旧域名**的 key
（`_rememberHtml(url, html)`）。于是缓存里可能出现「key 是旧域名、内容是旧域名页面里的
旧 host 绝对链接」。这类条目不会再被复用（新请求 key 变了），但会：

- 占住 40 条磁盘配额；
- 更要紧的是，解析出的视频地址仍指向已失效 host，点开必然失败 ——
  用户看到的就是「换了域名还是打不开」。

## 6. 验证证据

- `dart analyze lib/app/data/sources/site91_source.dart lib/app/widgets/domain_picker.dart test/site91_domain_discovery_test.dart` → **No issues found**
- `flutter test test/site91_domain_discovery_test.dart` → **4/4 passed**
  - 发布页可达 → 命中第一个可用直连，`testedDirectLinks < 候选总数`（证明命中即停）
  - 候选全死 → `found == false`，且 30 个候选全部被否（不拿停靠页充数）
  - 发布页全不可达 → 不挂起，30 秒内返回
  - 记住上次发布页 → 下次第一个就试它

**本机跑测试的前置条件**（否则 flutter_tester 的 WebSocket 连不上）：

```bash
NO_PROXY="localhost,127.0.0.1,::1" HTTP_PROXY= HTTPS_PROXY= flutter test test/site91_domain_discovery_test.dart
```

## 7. 已知限制（交接必读）

1. **号段扫描在本机很慢**：640 个域名全扫要 374 秒（16 并发）。原因是本机 DNS 是
   fake-ip 代理（`198.18.x.x`），连不上的域名也要等 TLS 超时；手机端无此层，
   NXDOMAIN 是毫秒级。
2. 因此 25 秒预算在「种子 968/969 与 360 全挂」的极端情况下会扫不完号段，
   如实返回「未找到」并回退手动输入。这是**有意的降级**，不是 bug。
3. **真机可用性未验证**。本机所有探测都经过代理，`91tanhua*.sbs` 曾在数分钟内
   从 502 变为 200，说明结果对网络环境敏感。交付前需在目标手机上实测一次。
4. 没有做「取消已飞请求」。`_firstMatch` 命中后只是停止派发，已发出的请求会自然
   结束、结果被丢弃（约 8 个多余请求）。加 CancelToken 收益太小，未做。
5. 缓存清理是 `unawaited` 的：换域名后立刻发起的请求有可能与清理竞争。
   影响面很小（最坏情况是多发一次网络请求），未加锁。

## 8. 如果要继续改

- 想更快：把 `_publishHostFirst` 的起点从 360 改成动态（例如从上次成功号 ±20 开始）。
- 想更稳：给 `_probeDirectLink` 加一次 `/index` 兜底探测（部分镜像根路径 302）。
- 想覆盖 91麻豆：`site91md_source.dart` 是另一套实现，`showSite91MdDomainPicker`
  与本文档的对话框完全独立，改动不要混在一起。


## 9. 稳定性补充重构（2026-10-18）

本轮保留交接时所有未提交改动与原固件，只改91发现流程和对话框，不改解析规则、缓存键或其它模块。原始文件已在本会话 `work/domain-stability-20261018` 单独备份；只含本轮变化的补丁为 `domain-stability-only.patch`，不提交或覆盖用户原有工作。

- 已复现并修复：首个发布页只有 `id="main"` 空壳、没有可提取地址时，原实现直接失败；现在验证取得候选清单后才选为发布页，否则继续尝试其它发布页。
- 发布页/脚本阶段和直连阶段都受15秒/25秒剩余预算约束，无响应传输也能返回；阶段结束、命中、调用方取消或关闭对话框后取消在飞请求并停止派发。
- 并发采用 `_firstMatch` 的唯一返回值，移除闭包反写最终domain/publishHost的竞争，迟到回复不再改变已选择结果。
- 自动发现只补充列表，用户已选中的域名不再被迟到结果改写；保存/删除也标记手动操作。异常回到可手动配置状态，关闭对话框取消自己的发现任务。
- 新增5项关键边界测试，连同原4项发现、6项域名配置和3项HTML缓存测试共 **18通过**；受影响4文件分析 **No issues found**。测试中的异步列表首帧、退出动画等待已修正，未把这些装置问题作为产品缺陷。
- 已连接 **PLK110** 真机Profile、真实网络，仅运行一次自动发现：**5626ms成功**，435个发布页候选、8个直连候选，未超预算。使用内存偏好，不读写真实登录/订阅；结束后覆盖恢复测试前原APK并核对SHA256 `919b00578f2bf42a0056b43ff1d9d3c82932f8e46113dc31367c54f26762285c`，未清用户数据。该单次结果不是旧新性能提升对照，也不保证换网络仍成功。

本节替代第7节“真机未验证”和“未取消在飞请求”的状态。**缓存异步清理竞态未在本轮修改**；仍保留号段无法在预算内扫完时回退手动输入的降级。未跑全项目测试、未构建新的正式APK、未推送GitHub。交付的是本地可审阅源码与回滚补丁，手机保留原正式应用。


## 10. 轻量发现与正式包安装（2026-10-18）

按用户“只添加一个可用源，优先流畅稳定”的要求，本节替代前文全号段扫描与高并发方案。

- 优先探测当前/最近成功的域名：命中即返回，不请求发布页。确定性测试确认此路径只有1次请求。
- 移除 `dizhi360~999` 穷举；只尝试上次发布页与3个固定入口，去重后最多4个。发布页与直连均串行，直连回退最多8个候选；找到第一个就停止，只采用一个，不添加整批地址。
- 总探测预算从25秒缩至15秒；保留关闭/取消中止请求及手动选择保护。有限入口全失败时回退手动配置，不再以数百次扫描换取覆盖率。
- 修改前最小复现确认旧实现忽略已保存的成功直连并扫描发布页。修改后相关测试20项通过；增强“第2个候选成功即停”的断言后，发现链路6项再次通过。静态分析无错误，保留1条null-aware集合写法的样式建议。
- ARM64 Release构建完成，源码版本 `2.0.4+2030`，安装版本码4030。APK 24238063字节，SHA256 `6e1ff452c60015857055ae97d85e7bcbc7191ffcef8a6cb07e7cb03525cd89e2`。已用 `adb install -r` 覆盖安装到PLK110，未清除用户数据；启动成功、5秒后进程仍存在，未观察到该进程的致命崩溃。
- 本轮是真实正式包安装与启动烟测，未重做Profile帧率或真实网络发现对比，不能声称帧率/耗时提升百分比。前一节5626ms实测属于旧扫描策略，不代表本轮结果。

本轮前的源码、APK备份与增量补丁位于本会话 `work/domain-lightweight-20261018`。未发布或推送GitHub；缓存清理竞态仍未修改。
