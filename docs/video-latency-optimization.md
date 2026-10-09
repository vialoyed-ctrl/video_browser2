# 视频起播响应速度优化方案（hanime1 / 91）

> 结论先行：本项目 Android 端的起播延迟，主要不来自解码或播放器初始化，而来自**两处可修复的工程缺陷**——
> ① Media3 磁盘缓存被一次性签名 URL 打散，跨会话永不命中；② 播放器只在解码器实际读到字节时才写缓存，
> 而 Android 上唯一的主动预取分支（Stage 2）被显式关闭。本方案针对这两点做了实现，并给出验证口径。

---

## 一、现状：起播链路与瓶颈定位

### 1.1 平台分流（关键前提）

`lib/app/services/player_service.dart:25` 定义 `usesNativeMediaCache => Platform.isAndroid`。

| 平台 | 91（HLS） | hanime1（MP4 直链） |
|---|---|---|
| **Android** | ExoPlayer + Media3 `SimpleCache`，**直连远端 m3u8** | ExoPlayer + Media3 `SimpleCache`，**直连远端 MP4** |
| **Windows** | Dart 回环代理 `HlsCacheProxy`（4 并发分片管线） | Dart `HanimeMp4RangeProxy`（512KB 分块 + 6 路预取） |

即：**Dart 侧那套精密的代理与分片加速，在 Android 上完全没有参与播放**（`player_service.dart:129-147`）。
Android 的性能完全取决于 Media3 的原生配置。这是本方案的着力点。

### 1.2 一次起播要经过几步

```
用户点击
  └─(A) 取真实流地址：整页 HTML 抓取 + 解析，抽出带签名的直链
        91      → https://cdn/.../index.m3u8?t=1759300000
        hanime1 → https://vdownload.hembed.com/408437-1080p.mp4?secure=...
  └─(B) ExoPlayer.prepare()：拉清单/探 moov
  └─(C) 缓冲到 bufferForPlaybackMs 后才出画
```

`(A)` 在 `lib/app/services/preload_service.dart:520` `_resolveItemStreamUrl`，
`(C)` 由 `DefaultLoadControl` 决定。

### 1.3 三个已定位的瓶颈

**瓶颈 1（最严重）：磁盘缓存键不稳定 → 跨会话永不命中。**

两个源的直链都带**每次请求重新签发**的签名参数（91 的 `?t=`，hanime1 的 `?secure=`）。
而 Media3 默认缓存键是完整 URL：

```java
// androidx.media3.datasource.cache.CacheKeyFactory
CacheKeyFactory DEFAULT = (dataSpec) -> dataSpec.key != null ? dataSpec.key : dataSpec.uri.toString();
```

后果：同一个视频每次打开都产生一个**新的缓存条目**。500MB 上限的缓存被同一部片子的多份副本填满，
而「第二次打开同一个视频」依然走完整网络。**缓存存在、也在写，但从不被复用。**

证据：`third_party/.../Media3PlaybackCache.java:48-61` 的 `wrap()` 只设置了
`setCache` / `setUpstreamDataSourceFactory` / `setFlags`，**没有 `setCacheKeyFactory`**。

**瓶颈 2：Android 上没有任何主动预取。**

- `preload_service.dart:613` `preload()` 首行即 `if (Platform.isAndroid) return;`
- `preload_service.dart:572` `touchDown()` 的 91 分支同样 `if (Platform.isAndroid) return;`

于是 Android 只有「解码器读到哪、缓存到哪」的被动填充。第一次打开必然是冷启动。
`PreloadService` 里已有的两阶段预取，对 Android 而言只剩 Stage 1（解析 URL），Stage 2 整体缺失。

**瓶颈 3：出画阈值与 HTTP 超时未调优。**

- `TextureVideoPlayer.java` / `PlatformViewVideoPlayer.java` 原先**只在 `backBufferDurationMs > 0` 时才构造 LoadControl**，
  否则完全不设置 → 采用 Media3 默认 `bufferForPlaybackMs = 1000`（必须缓冲满 1 秒才出画）。
- `HttpVideoAsset.java` 未设置连接/读取超时 → 默认 8s/8s，弱网 CDN 下起播等待被拉长。

### 1.4 一个被排除的怀疑方向

`.perf/anr_new.txt:3194-3240` 中本应用 ANR 的 `main` 线程栈是
`Looper.pollOnce`（**空闲**），且 `VmSwapKb: 46204`、`RssShmemKb: 2172`。
主线程空闲而输入分发超时，指向**内存压力/换页**而非主线程被计算占满。
所以本轮优化不把「主 isolate 解析 HTML」当作 Android 起播延迟的主因
（该项目此前已把 `HlsParser.parse` 移入后台 isolate，见 `preload_service.dart:704`）。

---

## 二、开源方案检索与筛选

检索方向：Media3/ExoPlayer 官方预加载与缓存能力、第三方视频缓存库。筛选判据四条：
① 是否支持 **HLS 与渐进式 MP4 两种**（两个源分别使用）；② 是否写入**播放器自身读取的同一份缓存**（避免重复流量）；
③ 是否**持久化到磁盘**（而非仅内存）；④ 是否仍在维护、API 是否稳定。

| # | 方案 | 能力 | 结论 |
|---|---|---|---|
| 1 | **`CacheKeyFactory`**（androidx.media3） | 自定义缓存键 | ✅ **采用**。直接解决瓶颈 1，一处生效，覆盖清单与分片 |
| 2 | **`HlsDownloader`**（media3-exoplayer-hls） | 拉清单 + 全部分片 + 加密密钥，写入指定 Cache | ✅ **采用**（91） |
| 3 | **`ProgressiveDownloader`**（media3-exoplayer） | 按字节区间缓存 MP4 | ✅ **采用**（hanime1） |
| 4 | **`CacheWriter`**（media3-datasource） | 底层写缓存的工具类 | ✅ 已由 2/3 内部使用，不单独调用 |
| 5 | **`DefaultLoadControl`** 调参 | 控制出画阈值 | ✅ **采用**。改动最小、直接作用于出画时刻 |
| 6 | **`HlsMediaSource.allowChunklessPreparation`** | 免分片准备 | ⚪ **已默认开启**（源码默认 `true`），无需改动 |
| 7 | **`PreloadManager` / `DefaultPreloadManager`**（media3 1.8+） | 为动态列表预载媒体源 | ❌ **不采用**。官方 Part 2 明确：预载进入**内存** `PreloadCache`，「与磁盘缓存结合仍在开发中」。本方案要求持久化缓存，且该 API 标记实验性 |
| 8 | **`DownloadManager` / `DownloadService`**（media3-exoplayer） | 完整离线下载管理 | ❌ **不采用**。需要前台服务、通知、数据库与生命周期托管，对「预取头部窗口」过重 |
| 9 | **danikula/AndroidVideoCache** | 代理式边下边播 | ❌ **不采用**。README 自述「only with direct urls to media file，不支持 DASH/HLS」——**对 91 的 HLS 源不适用**；且本项目已有两套 Dart 回环代理，再叠一层代理会引入第三份缓存与重复流量 |
| 10 | **OkHttp / Cronet 作为 HTTP 栈** | 连接池、HTTP/2、QUIC | ⚪ **列为后续可选**。当前 `DefaultHttpDataSource` 已足够；Cronet 需引入额外原生库并改 `DataSource.Factory`，收益依赖服务端是否支持 HTTP/2/QUIC，未验证前不引入 |
| 11 | **`PriorityTaskManager`** | 让后台下载为播放让路 | ⚪ **列为后续可选**。需与播放器共享管理器，改动面扩大到 `HttpVideoAsset`，本轮未做 |

筛选后的组合即：**1 + 2 + 3 + 5**，全部为 Media3 官方组件、版本 1.9.2 已在本项目依赖中，无新增第三方依赖。

---

## 三、已实施的改动

### 3.1 稳定缓存键（新增 `Media3CacheKeyFactory.java`）

在 `CacheDataSource.Factory` 上注入自定义键工厂，剥离**易变签名参数**后再做键：

```
https://cdn/.../seg_0042.ts?t=1759300000   →  https://cdn/.../seg_0042.ts
https://vdownload.hembed.com/408437-1080p.mp4?secure=xxx
                                           →  https://vdownload.hembed.com/408437-1080p.mp4
```

要点：
- **路径不动** → 不同分片仍是不同键，满足 Media3「一个键对应一个完整资源」的约束（`CacheKeyFactory` 文档明示
  实现不得对同一资源的不同 Range 返回不同键，反之亦然）。
- **未剥离任何参数时返回原始字符串**（逐字节）→ 无签名的 URL 保持原有键，已有缓存不受影响。
- 参数名单保守（`t`、`secure` 为本项目实测所见，其余为常见 CDN 约定）。

### 3.2 原生全量预缓存（新增 `Media3Preloader.java`）

- 91 → `HlsDownloader.Factory(...).setExecutor(IO).setStartPositionUs(0).setDurationUs(...)`；
  hanime1 → `ProgressiveDownloader(item, factory, IO, positionBytes, lengthBytes)`。
- 两者都通过 `Media3PlaybackCache.createCacheDataSourceFactory(...)` 拿到
  **与播放器同一个 `SimpleCache` + 同一个键工厂**。因此预下载的字节就是播放器要读的字节，
  不存在「下了一份、播的是另一份」的重复流量。
- **两个线程池**：`DRIVER`（2 线程，运行 `download()` 并阻塞等待）与 `IO`（3 线程，跑下载器内部分片工作）。
  这是必需的——Media3 的下载器把内部工作提交给构造时传入的 executor 后**阻塞调用线程**，
  若共用同一个池，驱动器会占满线程导致工作线程拿不到线程而死锁。驱动池大小同时就是并发上限。
- HLS 传 `StreamKey(GROUP_INDEX_VARIANT, variantIndex)`：多变体清单只缓存选定变体，
  避免一次性拉全部码率；**媒体清单会忽略该键**（`HlsMediaPlaylist.copy` 直接返回 `this`），
  所以 91 常见的单清单场景仍然是整片缓存。
- 取消语义：同一 `taskId` 重复入队会先取消旧任务；已落盘的字节保留。

### 3.3 出画阈值与 HTTP 超时

`VideoPlayer.createLoadControl(...)`（`VideoPlayer.java`）统一供两个子类使用：

| 参数 | 原值 | 新值 | 说明 |
|---|---|---|---|
| `bufferForPlaybackMs` | 1000 | **500** | 直接决定冷启动出画时刻 |
| `bufferForPlaybackAfterRebufferMs` | 2000 | **1500** | 仍高于上者：缓冲耗尽说明网络正慢，过早恢复会再次卡顿 |
| `minBufferMs` / `maxBufferMs` | 50000 | **50000（不变）** | 刻意不动，避免影响抗抖动能力 |
| `backBuffer` | 由 `options` 传入 | 同前（30000） | 行为不变 |

同时把「仅在 `backBufferDurationMs > 0` 时才设置 LoadControl」改为**无条件设置**——
原先 `backBufferDurationMs == null` 的调用方会静默沿用默认策略。

`HttpVideoAsset.java`：`setConnectTimeoutMs(5000)`、`setReadTimeoutMs(15000)`。

### 3.4 Dart 侧接入

- `lib/app/services/media3_cache_service.dart`：新增 `preload` / `cancelPreload` / `cancelAllPreloads` /
  `activePreloadCount`，以及进度事件流（原生经 `preloadProgress` 回推）。
- `lib/app/services/preload_service.dart`：新增 `scheduleNativePreload(...)`，在两个位置调用——
  - `_resolveItemStreamUrl` 解析成功后 → **头部窗口**（HLS 90 秒 / MP4 8MB），
    浏览阶段最多 4 条，避免首屏多条同时抢带宽；
  - `touchDown`（用户点击）→ 标记为**全量**。
- `lib/app/modules/player/player_controller.dart`：两条起播路径（预热控制器接管 / 常规打开）都触发**全量**预取。
  全量预取前会 `cancelAllPreloads()`——用户已选定视频时，浏览阶段的投机下载是最不值钱的带宽占用。

---

## 四、验证口径（重要）

| 检查项 | 结论 | 方法 |
|---|---|---|
| Dart 侧可编译 | ✅ 通过（退出码 0，无输出） | `dartaotruntime + gen_kernel_aot.dart.snapshot --target=flutter`，对 `lib/main.dart` 做完整内核编译 |
| Android 侧可编译 | ✅ 通过（kotlinc 0 / javac 0） | 手工组装 classpath（Media3 1.9.2 AAR + android-35 + flutter.jar + guava）后直接调 `javac` / `K2JVMCompiler` |
| 校验器本身有效 | ✅ | 编译校验**捕获到 1 个真实错误**（`HlsDownloader` 包路径误写为 `...exoplayer.hls`，正确为 `...exoplayer.hls.offline`）并修正 |
| **运行时效果** | ❌ **未实测** | 本机 `flutter build apk` 因环境限制无法运行（见下），未做真机验证 |

> **本机限制**：`flutter build` / `flutter analyze` 会拉起 stdio 被重定向的子进程，
> 本机 `CreateFile` 返回 `ERROR_PIPE_BUSY(231)` 必然失败。因此改用上述两条**不依赖子进程**的编译通道。
> 已能证明「能编译」，**不能证明「跑起来有效」**。

### 建议的验收指标（需真机实测）

同一视频、同一网络，对比改动前后：

1. **冷启动**（首次打开，缓存为空）：`PlayerService` 日志中
   `预打开播放器就绪 (Xms)` 与 `播放器就绪：Xms` 两个值。
   预期下降约 0.5s（`bufferForPlaybackMs` 1000→500）。
2. **二次启动**（同一视频再次打开）：应显著低于冷启动。
   改动前因缓存键不稳定，此值**与冷启动基本相同**——这是验证瓶颈 1 是否修复的最直接判据。
3. **浏览态预取命中**：在列表页停留数秒后点开首屏前几条，应接近 0 网络等待。
   可通过 `Media3PreloadProgress` 事件（`finished=true`）与 `Media3Preloader` 日志确认。
4. **缓存复用率**：`Media3PlaybackCache` 的 `getCacheSpace()` 增长速度应显著低于改动前
   （同一视频不再产生多份副本）。

---

## 五、已知局限与风险

1. **签名在路径中的 CDN 无法受益。** 本方案按查询参数剥离。若某镜像把 token 放在路径段
   （如 `/hls/<token>/seg.ts`），键仍会变化，缓存依旧不命中。参数名单是保守的可调项，
   位置在 `Media3CacheKeyFactory.VOLATILE_QUERY_PARAMS`。
2. **升级后首轮缓存全部失效。** 键算法改变，旧条目（按完整 URL 键）不再可达，需由 LRU 自然淘汰。
   这是预期行为，但用户侧表现为「升级后第一次打开没变快」。
3. **MP4 非 faststart 时头部预取无收益。** 若 moov 在文件尾，播放器首帧必须读尾部，
   缓存头部对首帧无帮助。hanime1 的直链由浏览器 `<video>` 播放，通常为 faststart，但**未逐条验证**。
4. **HLS 多变体清单只缓存一个变体。** 若播放器实际选中的不是 `variantIndex=0`，
   该次预取白做（不产生错误，只是浪费带宽）。当前 91 在应用内以单条 `原画 (Auto)` 呈现，故取 0。
5. **预取与播放共享带宽。** 本轮未引入 `PriorityTaskManager`。
   播放器的 `CacheDataSource` 未启用 `FLAG_BLOCK_ON_CACHE`，因此在预取正在写入的区段上会回退到上游读取，
   **不会阻塞播放**；但两者仍会竞争带宽。这是第 11 项「后续可选」的动机。
6. **未做真机验证**（见第四节）。任何性能数字在实测前都只是预期。

---

## 六、改动文件清单

**新增**

| 文件 | 作用 |
|---|---|
| `third_party/video_player_android/android/src/main/java/io/flutter/plugins/videoplayer/Media3CacheKeyFactory.java` | 稳定缓存键（剥离签名参数） |
| `third_party/video_player_android/android/src/main/java/io/flutter/plugins/videoplayer/Media3Preloader.java` | `HlsDownloader` / `ProgressiveDownloader` 全量预缓存 |

**修改**

| 文件 | 改动 |
|---|---|
| `.../Media3PlaybackCache.java` | `wrap()` 注入 `setCacheKeyFactory`；新增 `createCacheDataSourceFactory()` |
| `.../VideoPlayer.java` | 新增 `createLoadControl()`（统一缓冲策略） |
| `.../texture/TextureVideoPlayer.java` | 无条件应用 LoadControl |
| `.../platformview/PlatformViewVideoPlayer.java` | 同上 |
| `.../HttpVideoAsset.java` | 连接 5s / 读取 15s 超时 |
| `.../VideoPlayerPlugin.java` | channel 新增 `preload` / `cancelPreload` / `cancelAllPreloads` / `getPreloadStatus`，并回推 `preloadProgress` |
| `lib/app/services/media3_cache_service.dart` | 预缓存 API + 进度流 |
| `lib/app/services/preload_service.dart` | `scheduleNativePreload()` 及两处调用点 |
| `lib/app/modules/player/player_controller.dart` | 两条起播路径触发全量预取 |
