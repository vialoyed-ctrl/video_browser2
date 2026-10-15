# PornHub 内容源模块 · 整体结构与集成方案

> 本文所有结构性结论均来自**对 cn.pornhub.com 真实页面的实测**（2026-10-02），
> 不是基于经验推测。实测方法与原始数据见文末「附录 A：实测记录」。
>
> 标注口径：**已实测** = 已用真实页面验证；**待验证** = 设计上成立但尚未取得证据；
> **推测** = 尚未验证的假设。

---

## 一、结论先行

| 问题 | 结论 |
|---|---|
| 能否接入 | **能**。且播放链路与 91 完全同构（都是 HLS + 签名直链），**播放器、下载、预缓存、缓存策略全部可零改动复用**。 |
| 接入成本 | **源层（数据）成本低**：现有 `VideoSource` 抽象就是为此设计的，新增源 = 一个实现 + 注册一行，上层零改动。 |
| 主要成本在哪 | **模块 UI**（hanime1 级的多 Tab 模块约 10 个文件）与**登录后的写操作**（点赞/收藏/订阅/评论，需真实会话才能抓到端点）。 |
| 广告 | **结构性消除**，不是「过滤」。见第四节。 |
| 最大不确定性 | 登录后的写操作端点（待验证）+ HD 清晰度是否需要登录（待验证）。 |

---

## 二、模块整体结构

### 2.1 在现有工程中的位置

现有架构（读自 `lib/app/data/sources/video_source.dart:459-577`）已经是一个**内容源插件体系**：

```
上层模块（零改动）
  home / search / player / downloads
        │  只依赖 VideoSource 接口
        ▼
  SourceRegistry  ──register()──▶  Site91Source (id: site91)
                                  Hanime1Source (id: hanime1)
                                  PornHubSource (id: pornhub)   ← 本次新增
```

`VideoSource` 接口要求实现 11 个成员（`video_source.dart:460-510`）：
`id` / `displayName` / `categoriesForChannel` / `fetchTags` / `fetchPage` /
`fetchChannelPage` / `fetchHotKeywords` / `search` / `fetchDetail` / `getCachedHlsUrl`。

**新增源不需要改动任何上层代码**——这正是该抽象的设计意图（见其文件头注释）。

### 2.2 模块目录规划

参照 hanime1 模块（`lib/app/modules/hanime1/`，10 个文件）的结构：

```
lib/app/
├─ data/
│  ├─ models/
│  │  └─ pornhub_models.dart          # 分类定义、播放器配置模型
│  └─ sources/
│     └─ pornhub_source.dart          # ★ 核心：VideoSource 实现
├─ services/
│  └─ pornhub_auth_service.dart       # ★ 登录会话（Cookie 持久化）
└─ modules/
   └─ pornhub/
      ├─ pornhub_binding.dart
      ├─ pornhub_controller.dart
      └─ views/
         ├─ pornhub_main_view.dart      # 模块入口（底部 Tab 容器）
         ├─ pornhub_home_tab.dart       # 首页推荐
         ├─ pornhub_categories_tab.dart # 分类浏览
         ├─ pornhub_search_tab.dart     # 搜索 + 筛选
         └─ pornhub_profile_tab.dart    # 我的（登录态、收藏、稍后观看）
```

### 2.3 页面布局（对齐官网体验）

官网的版面结构（实测自首页 HTML）：

| 区域 | 官网形态 | 本项目实现 |
|---|---|---|
| 顶部 | Logo + 搜索框 + 登录/头像 | `AppBar`：源标识 + 搜索入口 + 登录态头像 |
| 主导航 | 首页 / 分类 / 频道 / 模特 | 底部 Tab（与 hanime1 模块一致） |
| 内容区 | 2 列视频卡片网格（`li.pcVideoListItem`） | 复用 `VideoItem` 卡片组件 |
| 卡片 | 缩略图 + 时长角标 + 标题 + 上传者 + 播放量 | 字段 1:1 映射，见 2.4 |
| 分页 | `/video?page=N` | 无限滚动 + `hasMore` |
| 详情页 | 播放器 + 标题 + 上传者 + 相关推荐 | 复用现有 `PlayerView`（已支持相关推荐/评论） |

**关键复用**：详情页与播放页**不需要新写**。`PlayerView` / `PlayerController` 已经是源无关的，
hanime1 与 91 共用同一套；PH 通过 `fetchDetail()` 返回 `VideoDetail` 即可接入。

### 2.4 字段映射（实测覆盖率 100%）

列表卡片 → `VideoItem`：

| `VideoItem` 字段 | PornHub 来源（实测选择器） | 实测样例 |
|---|---|---|
| `id` | `li[data-video-vkey]` | `6a9981b0128b1` |
| `title` | `a[href*="view_video.php"][title]` | `Stepbrother, why is your dick...` |
| `detailUrl` | 同上 `href` 补全域名 | `/view_video.php?viewkey=...` |
| `thumbnailUrl` | `img[data-image]`（回退 `img[src]`） | `pix-cdn77.phncdn.com/...` |
| `durationStr` | `var.duration` | `18:14` |
| `duration` | 同上解析为秒 | `1094` |
| `viewsStr` | `.views var` | `216K` |
| `views` | 同上换算为整数 | `216000` |
| `author` | `.usernameWrap a` | `RunaMave` |
| `publishedAt` | `var.added`（相对时间，需归一化） | `56年前` |

> 实测：首页 65 张卡片，上表 6 个关键字段**完整率均为 65/65**。

---

## 三、数据与内容来源

### 3.1 端点清单（实测）

| 用途 | 端点 | 实测 |
|---|---|---|
| 首页 | `https://cn.pornhub.com/` | ✅ 200，1.26 MB |
| 分页 | `/video?page=N` | ✅ 链接存在于首页 |
| 搜索 | `/video/search?search=<q>&page=N` | ✅ 链接存在于首页 |
| 分类 | `/categories/<slug>`（如 `hentai`、`teen`） | ✅ |
| 分类（数字） | `/video?c=<id>` | ✅ |
| 模特 | `/model/<name>` | ✅ |
| 频道 | `/channels/<slug>` | ✅ |
| 详情 | `/view_video.php?viewkey=<vkey>` | ✅ 200，4.34 MB |

### 3.2 取流方式（实测，最关键的一环）

详情页内嵌 `var flashvars_<数字ID> = {...}`，其中 `mediaDefinitions` 数组实测为 **5 条**：

| quality | format | URL |
|---|---|---|
| `1080` | hls | `https://ev-h.phncdn.com/hls/.../1080P_4000K_<id>.mp4/master.m3u8?validfrom=…&validto=…&ipa=1&hdl=-1&hash=…` |
| `720`（**默认**） | hls | `…/720P_4000K_….mp4/master.m3u8?…` |
| `480` | hls | `…/480P_2000K_….mp4/master.m3u8?…` |
| `240` | hls | `…/240P_1000K_….mp4/master.m3u8?…` |
| `[]` | mp4 | `https://cn.pornhub.com/video/get_media?s=<token>`（**选择器端点，非直链**） |

**设计含义（重要）**：

1. 主链路是**每档一条 HLS master playlist**，与 91 的形态一致 →
   `VideoVariant(label: '1080p', url: <m3u8>)`，播放/下载/预缓存全部复用现有代码。
2. 签名参数为 `validfrom` / `validto` / `ipa` / `hdl` / `hash`。**必须**把这几个词加进
   `Media3CacheKeyFactory.VOLATILE_QUERY_PARAMS`（`hash` 已在名单内），
   否则 Android 端每次重新签发都会产生新的缓存条目 —— 这正是此前 91 缓存的缺陷，
   不补的话 PH 会重蹈覆辙。
3. `format:"mp4"` 那条**不要用**：它是 `get_media` 选择器，需要额外跳转，
   而 HLS 档位已经覆盖全部清晰度。

---

## 四、广告屏蔽方案（四层，其中一层是结构性的）

### 4.1 关键前提：本项目不渲染官网 HTML

应用把页面**解析成数据**，再用自己的 Flutter 控件渲染。因此官网的广告位
（`adsbytrafficjunky` 脚本、iframe 广告）**在架构上就不存在** —— 不下载、不执行、不渲染。

实测确认广告相关标记：`adsbytrafficjunky` ×7、`trafficjunky` ×15、`advertisement` ×2、
`adblock` ×3。**但它们全部是 `<script>`/`<iframe>` 形态，不进入解析结果**。

**最强的一条**：官网播放器的**贴片广告（VAST/VMAP）由 PH 自己的播放器 JS 发起请求**。
本项目直接消费 `mediaDefinitions` 里的 m3u8，**根本不实例化官网播放器** →
贴片广告请求从不发出。这不是「拦截」，是「不存在」。

### 4.2 四层防线

| 层 | 位置 | 做什么 |
|---|---|---|
| **L1 解析层** | `pornhub_source.dart` | 遍历卡片时跳过广告容器（`adsbytrafficjunky` / `trafficjunky` / `advertisement` 等 class 命中即丢弃），并过滤 `data-entrycode` 为广告码的条目 |
| **L2 请求层** | Dio 拦截器 | 只请求第 3.1 节的端点；对已知广告域（`*.trafficjunky.*`、`*.exoclick.*`、`*.juicyads.*`、`go.bluetrafficstream.com`）直接拒绝 |
| **L3 WebView 层** | 登录 WebView | ① `shouldInterceptRequest` 拦截广告域；② 注入 CSS 隐藏广告容器；③ 注入 JS 移除广告节点与 `window.open` 弹窗 |
| **L4 播放层** | 现有播放器 | 只喂 m3u8；HLS 清单本身由 CDN 直出，实测为纯媒体清单 |

> **实测数据**：首页 65 张卡片经 L1 规则扫描，**广告卡片 0 条**（跳过 0）。
> 说明首页以自然推荐为主；但该层仍必须保留 —— 分类页与搜索结果页的广告密度不同，
> 且官网会随登录态变化插入推广位。

---

## 五、账号登录方案

### 5.1 登录端点：已实测取得（推翻了本方案初版的判断）

初版本文写的是「模拟 POST 不可靠、端点不可静态获取」。**该判断已被实测推翻**，
保留在此作为记录。

实测过程：

```
GET  /login
   └─ 表单 form.js-loginForm 确实没有 action 属性（JS 接管提交）
   └─ 但端点就写在页面**内联脚本**里：
        "loginUrl":"/front/authenticate"

POST /front/authenticate   (application/x-www-form-urlencoded)
   body: email / password / token / redirect / from
   └─ 响应：
      {"success":"1","username":"example-user",
       "avatar":"https://ei.phncdn.com/pics/users/default/..."}
```

**实测结论：原生账号密码登录可用。** 登录页虽然带 reCAPTCHA site key
（`g-recaptcha` ×3、`grecaptcha` ×20），但它是**风险触发式而非强制**，
本次实测未触发验证码。

初版之所以判断错误，是因为我只搜了外部 JS bundle，**没有检查页面内联脚本** ——
端点恰恰在内联脚本里。这个教训值得记下：判断「端点不可得」之前，
必须把内联脚本也搜一遍。

### 5.2 采用的方案：原生登录为主 + Cookie 导入兜底

| 路径 | 用途 | 状态 |
|---|---|---|
| `login(email, password)` → `/front/authenticate` | **主路径**，体验最好 | ✅ 已实测可用 |
| `importCookies(cookieHeader)` | 兜底：官网启用风控（验证码/二次验证）时使用 | ✅ 已实现 |
| `verifySession()` | 会话有效性判定 | ✅ 判据已用真实会话验证 |

**会话校验判据**：登录后首页**不再包含** `href="/login"`。
该判据已用真实登录会话验证（登录后实测 `href="/login"` 出现 0 次）。
用「有没有 PHPSESSID」是错的 —— 匿名访问同样会下发会话 Cookie。

### 5.3 用户区真实路径（全部来自已登录会话实测）

未登录时这些路径是 404 或登录墙，**无法靠猜测得到**（初版猜的 9 个候选全部 404）。
以下是登录后实测值：

| 功能 | 真实路径 | 实测内容 |
|---|---|---|
| 收藏 / 最爱 | `/users/<name>/videos/favorites` | 15 条卡片 ✅ |
| 订阅 | `/subscriptions` | 39 条卡片 ✅ |
| 个人主页 | `/users/<name>` | 5 条卡片 ✅ |
| 个人视频 | `/users/<name>/videos` | 存在 ✅ |
| 个人片单 | `/users/<name>/playlists` | 片单用独立容器 |
| 设置 | `/user/edit` | — |
| 注销 | `/user/logout?token=…` | — |

> ⚠️ **没有「观看历史」页面。** 实测 7 个候选路径
> （`/users/<name>/videos/history`、`/users/<name>/history`、`/video/history`、
> `/user/history`、`/history`、`/users/<name>/videos/watched`、`/users/<name>/videos`）
> **全部 404**。结论是 **PornHub 网页版不提供观看历史功能**，不是「没找到」。
> 因此本模块**不应为观看历史写任何实现**。

### 5.3 登录解锁的能力

| 能力 | 是否需要登录 | 状态 |
|---|---|---|
| 浏览列表/分类/搜索 | 否 | ✅ 已实测 |
| 播放（≤720p） | 否 | ✅ 已实测（720 为默认档） |
| 播放 1080p | **待验证** | PH 通常对 1080p 有登录要求 |
| 点赞 / 收藏 / 稍后观看 | 是 | 待验证（端点需真实会话抓取） |
| 订阅频道 / 模特 | 是 | 待验证 |
| 评论 / 观看历史 | 是 | 待验证 |

> **诚实说明**：上表标注「待验证」的项目，我**尚未取得证据**。它们需要真实登录会话
> 才能抓到准确的 AJAX 端点与请求体。我不会凭经验写死端点 —— 那正是上面第 5.1 节
> 批评的做法。实施时需要一个已登录会话（用户提供或自行登录一次）来抓取。

---

## 六、与现有项目的对接方式

### 6.1 必须改动的既有文件（仅 3 处，均为增量）

| 文件 | 改动 | 风险 |
|---|---|---|
| `lib/main.dart:84,91` 附近 | 增加 `SourceRegistry.register(pornhubSource)` | 极低（纯新增一行） |
| `lib/app/data/sources/video_source.dart:518` | `_ownedUrlMarkers` 增加 `'pornhub': {'pornhub.com'}` | 极低（新增一个 map entry） |
| `third_party/.../Media3CacheKeyFactory.java` | `VOLATILE_QUERY_PARAMS` 增加 `validfrom` / `validto` / `ipa` / `hdl` | 低（新增常量） |

> `_ownedUrlMarkers` 这一行**不是可选项**：它决定 `PreloadService` 是否会把 PH 条目
> 误当成当前源去嗅探。缺了它，切源后会出现「A 站浏览、后台替 B 站下载」的错配 ——
> 该文件注释里明确记录了这种错配曾导致主 isolate 占满并 ANR。

### 6.2 源切换入口

现有切换逻辑在 `lib/app/modules/root/root_controller.dart:28-41`
（`SourceRegistry.setActiveSource`）与 `home_controller.dart:90`。
新增 PH 后需在这两处增加第三个入口（Tab 或菜单项）。

---

## 七、网页版一致体验的覆盖范围

### 7.1 覆盖（本期目标）

- ✅ 首页推荐流（含分页）
- ✅ 分类浏览（`/categories/<slug>`、`/video?c=<id>`）
- ✅ 搜索（关键词 + 分页）
- ✅ 模特 / 频道页
- ✅ 详情页：标题、上传者、时长、播放量、缩略图、**多清晰度切换**
- ✅ 播放：HLS 多档，复用现有播放器（含逐帧拖动、手势、字幕轨）
- ✅ 相关推荐
- ✅ 下载（复用现有 m3u8 下载管线）
- ✅ 全链路广告屏蔽（四层）
- ✅ 账号登录（WebView 方案）

### 7.2 明确不覆盖（并说明原因）

| 官网功能 | 不做的原因 |
|---|---|
| 官网播放器 UI | 本项目有自研播放器；且官网播放器正是广告载体，绕过它才能结构性去广告 |
| 付费会员 / Premium | 涉及支付，超出内容聚合范围 |
| 直播 | 需要完全不同的播放与信令链路 |
| 上传 / 创作者后台 | 与浏览型客户端定位不符 |
| 站内私信 | 同上 |
| 评论区发帖 | 待验证（登录后写操作，见 5.3） |

---

## 八、可执行实施步骤

| # | 步骤 | 产出 | 验收方式 |
|---|---|---|---|
| 1 | 解析器原型（**已完成**） | `ph_parser_proto.py` | 真实页面 65/65 字段完整率 ✅ |
| 2 | `pornhub_source.dart`：列表/分页/分类/搜索/详情/多档/相关推荐 + L1 广告过滤 | 源实现 | Dart 内核编译 + 与原型逐字段对照 |
| 3 | `pornhub_auth_service.dart`：Cookie 会话持久化 | 登录服务 | 编译 + 单元逻辑复核 |
| 4 | 注册源 + `_ownedUrlMarkers` + Media3 缓存键扩展 | 3 处增量改动 | 编译 + 缓存键行为复核 |
| 5 | 模块 UI（5 个文件，参照 hanime1） | 页面 | 编译 |
| 6 | 登录 WebView + L3 广告注入 | 登录页 | 需真机 |
| 7 | 登录后写操作端点抓取（点赞/收藏/订阅） | 端点清单 | **需真实会话** |
| 8 | 真机联调 | — | **需真机**（本机 `flutter build` 被管道拦截，无法构建） |

**步骤 7、8 存在外部依赖**：需要真实登录会话与可构建环境。我会把 1–6 做到可编译、
可静态验证的程度，并明确标注哪些结论止于「已编译」而非「已实测」。

---

## 九、实施进展（最终）

### 9.1 已完成并验证

| 交付物 | 状态 | 验证方式 |
|---|---|---|
| 解析器原型 | ✅ | 真实页面实测，见 9.3 的完整率表 |
| `pornhub_source.dart` | ✅ | Dart 内核编译 exit 0 |
| `pornhub_auth_service.dart`（原生登录 + Cookie 兜底 + 会话校验） | ✅ | 编译通过；登录流程已实测成功 |
| `pornhub_models.dart`（片单 / 明星模型） | ✅ | 编译通过 |
| **模块 UI**：主框架 + 5 个 Tab | ✅ | 编译通过 |
| 源注册 / `_ownedUrlMarkers` / Media3 缓存键 | ✅ | Dart + javac + kotlinc 全部 exit 0 |
| 缩略图防盗链 Referer（三源分派） | ✅ | 编译通过 |
| 96 个真实分类 / 排序参数 | ✅ | 实测导出 |

### 9.2 模块 UI 结构（与 91 / Hanime1 统一）

```
PornHubMainView            ← 与 Hanime1MainView 同构：AppBar 徽标 + IndexedStack + NavigationBar
├─ 主页   PornHubHomeTab      入口分类芯片 + 自适应网格 + 分页
├─ 分类   PornHubCategoriesTab 96 分类网格 → 原地切换为该分类视频列表
├─ 发现   PornHubDiscoverTab   片单 / 明星 双 Tab → 点进去复用视频网格
├─ 搜索   PornHubSearchTab     关键词搜索 + 分页
└─ 我的   PornHubProfileTab    登录表单 + 收藏 / 订阅 双 Tab
```

**风格统一的具体做法**：不新写卡片，直接复用既有组件 ——
视频网格用 `BiliVideoCardV`（91 版面同款），几何参数走 `ResponsiveLayout`，
导航栏用 Material 3 `NavigationBar`。因此三个版面观感天然一致。

**版面切换**：`RootController` 由「91 ↔ hanime1 二元」改为
`AppPlatform` 枚举驱动的三态循环，抽屉里的切换按钮同步改为通用文案。

### 9.3 解析器实测完整率

| 页面 | 条数 | 字段完整率 |
|---|---|---|
| 首页 `/video` | 35 | 六字段 100% |
| 分类 `/video?c=27` | 34 | 六字段 100% |
| 排序 `/video?o=tr` | 35 | 六字段 100% |
| 搜索 `/video/search` | 38 | 六字段 100% |
| `/categories/hentai` | 34 | 六字段 100% |
| 模特页 `/model/` | 31 | 六字段 100% |
| 频道页 `/channels/` | 40 | 六字段 100% |
| 用户页 `/users/` | 15 | 六字段 100% |
| HD 页 `/hd` | 34 | 六字段 100% |
| **片单 `/playlists`** | 38 | title 38/38 · count 38/38 · cover 38/38 |
| **明星 `/pornstars`** | 45 | name 45/45 · avatar 45/45 · rank 45/45 |
| 片单详情 `/playlist/<id>` | 19 | 复用视频解析器 |
| 明星详情 `/pornstar/<name>` | 20 | 复用视频解析器 |

### 9.4 按需求不做

| 项目 | 原因 |
|---|---|
| 相册 `/albums`、`/album/<id>` | 用户明确排除。内容为图片，需独立图片浏览器 |
| GIF `/gifs`、`/gif/<id>` | 用户明确排除。内容为动图，需独立 GIF 播放器 |
| 剪辑 `/clips` | 用户明确排除 |
| 会员搜索 `/user/search` | 用户明确排除 |
| 观看历史 | **官网不存在该页面**（7 个候选路径实测全部 404） |

### 9.5 一处自我纠错（记录在案）

初版源码把「20分钟以上」写成 `/video?min_duration=20` —— **凭直觉臆造的参数**，
官网无此链接。核实后替换为实测存在的 `o=ht` 与 `p=homemade&o=tr`。

另一处：明星页初版只认 `a[alt]` 一种结构，导致 rank 只有 5/44 命中。
实测该页有**两种卡片结构**（精选卡用 `a[alt]`/`.rankNumber`，普通卡用
`img[alt]`/`.rank_number`），补上回退后达到 45/45。

---

## 附录 A：实测记录

### A.1 采集

```
UA: Chrome/120  ·  代理: 127.0.0.1:14613
GET https://cn.pornhub.com/                      → 200, 1,264,734 bytes, 无 CF 质询
GET https://cn.pornhub.com/view_video.php?viewkey=67fc0c63e407b
                                                 → 200, 4,339,408 bytes
```

### A.2 解析原型输出（节选）

```
=== 列表页：解析 65 条，按广告规则跳过 0 条 ===
  6a9981b0128b1 |  18:14 |    216K | RunaMave        | Stepbrother, why is your dick hanging over my bed !?
  6aa4c168f0e2c |  15:20 |   97.3K | Mom Lover       | "I'm Not Your Mommy" Stepmom Veronica Weston Needs S
  67fc0c63e407b |  20:13 |    581K | Aunt Judys XXX  | Aunt Judy's XXX - Busty红发老师Mrs JoJo下课后乱搞她的学生

=== 列表页字段完整率 ===
  title: 65/65   detailUrl: 65/65   thumbnailUrl: 65/65
  durationStr: 65/65   viewsStr: 65/65   author: 65/65

=== 详情页 ===
  title: Aunt Judy's XXX - Busty红发老师Mrs JoJo下课后乱搞她的学生
  defaultQuality: 720
  variants: 1080p / 240p / 480p / 720p
  related: 77
```

### A.3 排除的一个误判

首次运行时 stdout 出现一段 hanime1 页面的 DOM 转储。经 `grep -c hanime1` 核对，
两个输入文件均为**纯 PornHub 内容（hanime1 出现 0 次）**，确认该转储为共享
`PYTHONPATH` 目录的残留污染；改用隔离 venv 后消失。**原始证据未被污染**，
但记录在此以免后续误读。
