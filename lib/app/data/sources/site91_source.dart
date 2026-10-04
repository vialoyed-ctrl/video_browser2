/// 91DL 官方网页数据源实现。
///
/// 完整迁移与升级 Android WebScraper / WebScraperV2 逻辑：
/// 1. 多域名动态测活与自定义切换（自定义域名会持久化，App 重启后仍生效）；
/// 2. 作者主页视频分页提取；
/// 3. 视频名称/关键词官网格式搜索；
/// 4. 详情页 M3U8 提取、防时间戳真实标题清洗、发布日期多级容错提取；
/// 5. 全链路 AppLogger 日志记录，方便手机端定位问题。
///
/// 关于「多域名」的设计取向：实测多个镜像域名跑的是**同一套 CMS**，
/// 因此这里刻意只维护**一套提取规则**，靠选择器/正则的宽容度覆盖域名差异。
/// 永久固定域名见 [defaultDomains]；临时镜像由用户在「网站域名设置」中添加和删除，
/// 不需要复制一份解析逻辑。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_logger.dart';
import '../../services/background_decode_transformer.dart';
import '../models/video_item.dart';
import 'video_source.dart';

class Site91Source implements VideoSource {
  /// [baseUrl] 留空表示「尚未选择域名」——由用户在选择对话框里显式指定
  /// （见 [setBaseUrl] / [restoreSelectedDomain]）。刻意不预设候选域名：
  /// 「谁先探测通过就用谁」的结果取决于当时的网络环境，在用户手机上并不可靠。
  Site91Source({String? baseUrl, Dio? dio})
    : _baseUrl = _cleanBaseUrl(baseUrl ?? ''),
      _dio = dio ?? _createDio();

  /// 永久保留的域名。
  ///
  /// 实测结论：下列域名运行的是**同一套 CMS** —— `div.video-elem`、`a.title`、
  /// `small.layer`、`div.img[style*=background-image]`、`ul.pagination li.page-item`、
  /// `video#video-play[data-src]` 全部一致。因此它们共用同一套提取规则，
  /// 不需要为每个域名各写一个解析器。
  ///
  /// 域名之间只剩少量差异，已由 [_videoLinkPattern] 与 [_parseVideoCards] 的选择器兜住：
  ///   1. 作者链接存在 `/author/xxx`（视频频道）与 `/dashen/xxx`（精品频道）两种形式；
  ///   2. 日期存在 `N月前` / `N年前` 形式（旧规则只认到 `小时/天/分钟/秒前`）；
  ///   3. 详情页存在三种模板 `/video/view/`、`/vod/view/`、`/videos/view/`，
  ///      前两者给 m3u8，第三者给 mp4。
  static const List<String> defaultDomains = <String>[
    'https://www.91porny.com',
  ];

  /// Former built-in mirror now remains available as a removable user domain.
  static const String _promotedDefaultDomain = 'https://www.91tanhua189.sbs';

  /// Previous built-in mirrors are deliberately not migrated as user-added domains.
  static const Set<String> _retiredDefaultDomains = <String>{
    'https://hsex.icu',
    'https://91p9.space',
    'https://www.91tanhua103.sbs',
  };

  /// Keep the old primary hostname working by migrating it to the requested www host.
  static const Map<String, String> _legacyDomainAliases = <String, String>{
    'https://91porny.com': 'https://www.91porny.com',
  };

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  String _baseUrl;
  final Dio _dio;
  bool _hasTestedDomain = false;

  /// 域名变更回调：(原域名, 新域名, 是否由程序自动切换触发)。
  ///
  /// 两类用途，缺一不可：
  ///
  /// 1. **重写已保存条目**（观看记录 / 稍后再看 / 收藏）。它们存的是保存当时的
  ///    绝对 URL，域名一变旧 host 就失效 —— 不重写就会「点开播不了」。
  ///    由 [rebaseUrl] 完成。
  /// 2. **告知用户**。自动切换若不提示，用户会以为自己选的域名仍在生效。
  ///
  /// 参数里带 [automatic] 正是为了区分这两类：只有自动切换才需要提示用户。
  void Function(String from, String to, bool automatic)? onDomainChanged;

  final Map<String, String> _cookies = <String, String>{};

  void _saveCookies(Headers headers) {
    final setCookies = headers['set-cookie'] ?? [];
    for (final sc in setCookies) {
      final pair = sc.split(';').first.split('=');
      if (pair.length >= 2) {
        _cookies[pair[0].trim()] = pair.sublist(1).join('=').trim();
      }
    }
  }

  String _cookieHeader() =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 视频详情本地缓存，避免重复请求解析（含 5 分钟有效期，防止 m3u8 token 过期）
  final Map<String, VideoDetail> _detailCache = <String, VideoDetail>{};
  final Map<String, DateTime> _detailCacheTime = <String, DateTime>{};
  final Map<String, Future<VideoDetail?>> _detailRequests =
      <String, Future<VideoDetail?>>{};
  final Map<String, Future<VideoDetail>> _detailEnrichmentJobs =
      <String, Future<VideoDetail>>{};

  // ---------------------------------------------------------------------------
  // HTML 响应缓存（内存 + 磁盘），以及并发请求去重
  //
  // 为什么必须做：实测 91 服务端本身响应就要 0.7~2.3 秒（`/index` 668ms、
  // `/video/category/latest/2` 2312ms），且响应头是
  // `Cache-Control: no-cache, no-store, must-revalidate` —— 服务端**明确禁止**
  // HTTP 缓存，所以 Dio/系统级缓存都救不了，只能靠本地兜。
  //
  // 策略是 stale-while-revalidate：
  //   命中缓存 → 立即返回旧内容（0 延迟渲染）→ 后台悄悄刷新，下次进入即最新。
  // 这样「第二次进入任何已看过的页面」都是秒开。
  // ---------------------------------------------------------------------------

  /// 内存 HTML 缓存：url -> (html, 写入时间)。用 LinkedHashMap 的插入序做 FIFO
  /// 淘汰（条目都是整页 HTML，访问频率差异不大，FIFO 已足够且实现最简）。
  final Map<String, ({String html, DateTime at})> _htmlCache =
      <String, ({String html, DateTime at})>{};
  static const int _maxHtmlCacheEntries = 60;

  /// 磁盘缓存最多保留多少条（gzip 压缩后存 SharedPreferences）。
  static const int _maxDiskCacheEntries = 40;

  /// 磁盘缓存键前缀。带版本号，将来格式变了直接换前缀即可整体失效。
  static const String _diskCacheKeyPrefix = 'site91_html_cache_v1_';

  /// 并发去重：同一个 URL 同时被请求多次时，只发一次真实网络请求。
  ///
  /// 真实现场：`HomeController.onInit` 会**同时**调 `loadFirstPage()` 与
  /// `loadHotKeywords()`，两者都请求 `/index` —— 没有这张表就是两次完整
  /// 网络往返（约 1.3 秒的重复等待）。
  final Map<String, Future<String>> _inFlightRequests =
      <String, Future<String>>{};
  final Set<String> _backgroundRevalidations = <String>{};

  /// 列表类页面的新鲜度。超过它才认为「需要刷新」，但**仍会先用旧值渲染**。
  static const Duration _htmlCacheStaleAfter = Duration(minutes: 5);

  /// 磁盘写入去抖：连续请求时不必每条都落盘。
  Timer? _diskFlushTimer;
  final Map<String, String> _pendingDiskWrites = <String, String>{};

  bool _diskCacheLoaded = false;

  /// 在应用退出前调用，把待写入的缓存落盘。非 [VideoSource] 接口成员，
  /// 由持有方按需调用；不调用也只是丢掉最多几秒内的写入，无副作用。
  Future<void> flushCacheNow() async {
    _diskFlushTimer?.cancel();
    await _flushDiskCache();
  }

  String _diskKeyFor(String url) =>
      '$_diskCacheKeyPrefix${base64Url.encode(utf8.encode(url))}';

  /// Detail HTML embeds time-limited HLS addresses. Keep it in memory briefly,
  /// but never restore an old detail page from disk after an app restart.
  bool _isVideoDetailUrl(String url) => _videoLinkPattern.hasMatch(url);

  bool _isStreamUrlFresh(String url) {
    final expiresAt = int.tryParse(
      Uri.tryParse(url)?.queryParameters['t'] ?? '',
    );
    if (expiresAt == null) return true;
    final safeUntil = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
        .subtract(const Duration(seconds: 8));
    return DateTime.now().isBefore(safeUntil);
  }

  /// 读取磁盘缓存并填充内存缓存。只执行一次。
  Future<void> _ensureDiskCacheLoaded() async {
    if (_diskCacheLoaded) return;
    _diskCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((k) => k.startsWith(_diskCacheKeyPrefix))
          .toList();
      for (final key in keys) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final inflated = utf8.decode(
            gzip.decode(base64Decode(raw)),
            allowMalformed: true,
          );
          final url = utf8.decode(
            base64Url.decode(key.substring(_diskCacheKeyPrefix.length)),
          );
          if (_isVideoDetailUrl(url)) {
            // Older app versions persisted detail pages with signed stream
            // URLs. Remove those entries so playback resolves a fresh URL.
            await prefs.remove(key);
            continue;
          }
          _htmlCache[url] = (html: inflated, at: DateTime.now());
        } catch (_) {
          // 单条损坏只丢这一条，不影响其它。
          unawaited(prefs.remove(key));
        }
      }
      if (keys.isNotEmpty) {
        AppLogger.i('Site91', '磁盘缓存已载入 ${_htmlCache.length} 条页面');
      }
    } catch (e) {
      AppLogger.w('Site91', '载入磁盘缓存失败: $e');
    }
  }

  void _scheduleDiskFlush() {
    _diskFlushTimer?.cancel();
    _diskFlushTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_flushDiskCache());
    });
  }

  Future<void> _flushDiskCache() async {
    if (_pendingDiskWrites.isEmpty) return;
    final batch = Map<String, String>.of(_pendingDiskWrites);
    _pendingDiskWrites.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in batch.entries) {
        final compressed = base64Encode(gzip.encode(utf8.encode(entry.value)));
        await prefs.setString(entry.key, compressed);
      }
      // 控制磁盘条目总量：超出就按插入序丢掉最早的。
      final allKeys = prefs
          .getKeys()
          .where((k) => k.startsWith(_diskCacheKeyPrefix))
          .toList();
      if (allKeys.length > _maxDiskCacheEntries) {
        final excess = allKeys.length - _maxDiskCacheEntries;
        for (var i = 0; i < excess; i++) {
          await prefs.remove(allKeys[i]);
        }
      }
    } catch (e) {
      AppLogger.w('Site91', '写入磁盘缓存失败: $e');
    }
  }

  void _rememberHtml(String url, String html) {
    _htmlCache[url] = (html: html, at: DateTime.now());
    while (_htmlCache.length > _maxHtmlCacheEntries) {
      _htmlCache.remove(_htmlCache.keys.first);
    }
    if (!_isVideoDetailUrl(url)) {
      _pendingDiskWrites[_diskKeyFor(url)] = html;
      _scheduleDiskFlush();
    }
  }

  /// 取缓存的 HTML。[allowStale] 为 true 时无视新鲜度直接返回旧内容
  /// （用于「先渲染、后刷新」）。
  String? _cachedHtml(String url, {bool allowStale = true}) {
    final entry = _htmlCache[url];
    if (entry == null) return null;
    if (!allowStale &&
        DateTime.now().difference(entry.at) > _htmlCacheStaleAfter) {
      return null;
    }
    return entry.html;
  }

  /// 后台静默刷新指定 URL（不等待、不抛错）。
  ///
  /// 关键：必须走 `forceRefresh: true`，否则会先命中刚写入的缓存、再次触发
  /// 本方法 → 自我循环。这里同时把域名重试链的起点传成空集合即可，
  /// 由 [_request] 的 isTopLevel 分支判定「不读缓存，只走网络」。
  void _revalidateInBackground(String url) {
    if (_inFlightRequests.containsKey(url) ||
        !_backgroundRevalidations.add(url)) {
      return;
    }
    unawaited(() async {
      try {
        final fresh = await _requestOverNetwork(url, <String>{}, true);
        if (fresh.isNotEmpty) _rememberHtml(url, fresh);
      } catch (e) {
        AppLogger.d('Site91', '后台刷新 $url 失败（忽略）: $e');
      } finally {
        _backgroundRevalidations.remove(url);
      }
    }());
  }

  String get currentBaseUrl => _baseUrl;

  static String _cleanBaseUrl(String url) {
    var cleaned = url.trim();
    if (cleaned.isEmpty) return cleaned;
    // 允许用户只输入裸域名（如 `www.example.com` 或 `91porny.com`），自动补全协议。
    // 否则 Dio 会因缺少 scheme 直接抛异常，用户看到的只是「无法连通」。
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned)) {
      cleaned = 'https://$cleaned';
    }
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  /// 规范化用户输入的站点根域名（补协议、统一 host 大小写）。
  ///
  /// 对外暴露是为了让 UI 与数据层共用**同一套**清洗规则 —— 否则对话框里显示的值
  /// 和最终生效的值可能不一致（例如用户输入 `www.x.com/`，界面显示带斜杠、实际不带）。
  static String normalizeDomain(String url) {
    final cleaned = _cleanBaseUrl(url);
    if (cleaned.isEmpty) return '';
    final uri = Uri.tryParse(cleaned);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return '';
    }
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: '',
        )
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  /// 从 URL 里取出 host（不含端口以外的部分）。
  static final RegExp _hostPattern = RegExp(
    r'^https?://([^/]+)',
    caseSensitive: false,
  );

  static String _hostOf(String url) =>
      _hostPattern.firstMatch(url)?.group(1)?.toLowerCase() ?? '';

  /// 把「保存下来的旧域名 URL」重定位到当前选中的域名。
  ///
  /// 观看记录 / 稍后再看 / 收藏里存的是**保存当时**的绝对 URL（host = 当时的域名）。
  /// 用户换域名后旧 host 已失效，直接拿它去请求必然失败 ——
  /// 对外表现为「历史里的视频点开播不了」。所以在域名变更时统一重写。
  ///
  /// 只替换 scheme + host，**完整保留 path 与 query**（`viewkey` 之类的参数不能丢）；
  /// 不属于本站地址的（CDN 的 m3u8 / mp4 / 封面图）原样返回。
  String rebaseUrl(String url) {
    if (url.isEmpty) return url;
    final normalizedUrl = _normalizeVideoPageUrl(url);
    if (_baseUrl.isEmpty) return normalizedUrl;
    final m = _hostPattern.firstMatch(normalizedUrl);
    if (m == null) return normalizedUrl; // 相对路径，交给 [_resolveUrl] 处理
    if (m.group(1)!.toLowerCase() == _hostOf(_baseUrl)) {
      return normalizedUrl; // 已是当前域名
    }
    if (!_isSiteAddress(normalizedUrl)) return normalizedUrl;
    return _normalizeVideoPageUrl('$_baseUrl${normalizedUrl.substring(m.end)}');
  }

  /// 91 将部分首页卡片生成为 `/video/viewhd/{id}`，但该详情路由在 App
  /// 当前使用的播放解析流程中无法正常播放。统一改用同 ID 的 `/video/view/{id}`。
  /// `Uri.replace` 会保留 host、query 与 fragment，其他详情类型和资源 URL 不变。
  static String _normalizeVideoPageUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final normalizedPath = uri.path.replaceFirst(
      RegExp(r'^/video/viewhd(?=/)'),
      '/video/view',
    );
    if (normalizedPath == uri.path) return url;
    return uri.replace(path: normalizedPath).toString();
  }

  /// 判断是否为「本站地址」。
  ///
  /// **刻意用路径形态判断，而不是比对 host** —— 因为用户之前可能用过某个自定义域名，
  /// 它早已不在 [defaultDomains] 里，靠 host 白名单会漏掉，那些记录就永远重定位不了。
  /// 反过来，CDN 的 `/hls/xxx/index.m3u8`、`/get_file/.../x.mp4`、封面图路径
  /// 都不会命中 [_videoLinkPattern]，所以不会被误改。
  bool _isSiteAddress(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final pathAndQuery = uri.query.isEmpty
        ? uri.path
        : '${uri.path}?${uri.query}';
    if (_videoLinkPattern.hasMatch(pathAndQuery)) return true;
    // 作者页地址。VideoItem 目前不存这类字段，但统一处理，
    // 免得以后新增字段时再踩一次同样的坑。
    return uri.path.startsWith('/author/') || uri.path.startsWith('/dashen/');
  }

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 25),
        sendTimeout: const Duration(seconds: 20),
        headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    // ⚠️ 本文件里**唯一**一处非功能性改动，如果不需要可以整段删掉回滚：
    // 把响应体的 UTF-8 解码从主 isolate 挪到后台 isolate。
    //
    // dio 默认是**主 isolate 同步** `utf8.decode`（连它那个名字很唬人的子类
    // `BackgroundTransformer` 也只对 JSON 走后台）。而 91 的首页与详情页 HTML
    // 是全局最大的，启动阶段的整页预加载会把 UI 线程顶到 ANR ——
    // 真机 ANR 主线程栈顶逐帧取证见 `background_decode_transformer.dart`。
    //
    // 输出与 dio 默认实现逐字节一致，不改动任何请求头、超时、解析或界面逻辑。
    dio.transformer = BackgroundDecodeTransformer();
    return dio;
  }

  @override
  String get id => 'site91';

  @override
  String get displayName => '91DL 在线内容源';

  /// 纯探测：只回报该域名当前是否可用，**不改变任何内部状态**。
  ///
  /// 与旧实现的关键区别：旧版「测试连通性」会顺手把 `_baseUrl` 改掉并持久化，
  /// 于是「测一下」等于「切过去」。现在测试与采用彻底分离 —— 采用只走 [setBaseUrl]。
  Future<bool> probeDomain(String url) async {
    final target = _cleanBaseUrl(url);
    if (target.isEmpty) return false;
    AppLogger.i('Site91', '正在探测域名: $target');
    try {
      final res = await _dio.get<String>(
        target,
        options: Options(responseType: ResponseType.plain),
      );
      if (res.statusCode != 200) {
        AppLogger.w('Site91', '域名不可用 (HTTP ${res.statusCode}): $target');
        return false;
      }
      // 质询页也可能以 200 返回，不能只看状态码，否则会把验证页当成"可用域名"。
      if (_looksLikeChallenge(res.data ?? '')) {
        AppLogger.w('Site91', '域名返回访问验证页，判定为不可用: $target');
        return false;
      }
      AppLogger.i('Site91', '✓ 域名可用: $target');
      return true;
    } catch (e) {
      AppLogger.w('Site91', '域名无法访问: $target ($e)');
      return false;
    }
  }

  /// 在候选域名里找一个可达的，跳过 [exclude] 里的全部域名。
  /// 只返回结果，不修改任何状态。
  ///
  /// [exclude] 是「本次请求已经试过」的域名集合，由 [_request] 沿递归链透传。
  /// 这一层过滤是**终止性保证**：没有它，A 失败切到 B、B 又失败切回 A，
  /// 两个域名会来回乒乓，递归永不收敛。
  Future<String?> _findReachableDomain(Set<String> exclude) async {
    for (final domain in defaultDomains) {
      if (exclude.contains(domain)) continue;
      if (await probeDomain(domain)) return domain;
    }
    return null;
  }

  /// Cloudflare 质询 / 访问验证页的特征判定。
  ///
  /// 关键：这类页面并不总带 4xx/5xx，也可能以 **200** 返回，故必须同时做内容特征判定。
  /// 早期只判状态码，导致 200 的验证页被当成正常内容返回，上层解析出 0 条，
  /// 界面显示「没有匹配的内容」—— 把「站点限流」伪装成「真的没结果」。
  static bool _looksLikeChallenge(String data) =>
      data.contains('cdn-cgi/content?id=') ||
      data.contains('Just a moment...') ||
      data.contains('__cf_chl_') ||
      data.contains('Checking your browser');

  /// Some successful 91 pages include Cloudflare's bot-management script along
  /// with real results. Trust a recognizable video page in that case instead
  /// of paying for an unnecessary challenge retry before parsing it.
  static bool _looksLikeSiteContent(String data) =>
      (_videoLinkPattern.hasMatch(data) &&
          RegExp(r'''class=["'][^"']*(?:video-elem|colVideoList)[^"']*["']''')
              .hasMatch(data)) ||
      RegExp(r'''<video\b[^>]*\b(?:src|data-src)\s*=''').hasMatch(data);

  /// 自定义域名持久化键（用户手输的域名，App 重启后仍然生效）。
  static const String _prefsKeyDomain = 'site91_custom_base_url';
  static const String _prefsKeyUserDomains = 'site91_user_domains';
  static const String _prefsKeyDomainListMigration =
      'site91_domain_list_migration_version';

  /// 采用用户显式选择的域名（立即生效 + 持久化）。
  ///
  /// 置 `_hasTestedDomain = true` 是必须的：否则下一次 [_request] 会认为域名尚未确定，
  /// 重新走恢复流程，用户刚选好的域名就被丢弃了。
  void setBaseUrl(String newUrl) {
    final previous = _baseUrl;
    _baseUrl = _cleanBaseUrl(newUrl);
    _hasTestedDomain = true;
    AppLogger.i('Site91', '域名已更新为: $_baseUrl');
    unawaited(_persistDomain(_baseUrl));
    _notifyDomainChanged(previous, automatic: false);
  }

  /// 通知外部「域名变了」。
  ///
  /// 外部据此做两件事：重写已保存条目的旧域名 URL（[rebaseUrl]）、
  /// 以及在**自动**切换时提示用户。回调异常不能影响请求链路，故整体兜住。
  void _notifyDomainChanged(String previous, {required bool automatic}) {
    if (_baseUrl.isEmpty || _baseUrl == previous) return;
    try {
      onDomainChanged?.call(previous, _baseUrl, automatic);
    } catch (e) {
      AppLogger.w('Site91', '域名变更回调异常: $e');
    }
  }

  Future<void> _persistDomain(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyDomain, url);
    } catch (e) {
      AppLogger.w('Site91', '保存域名失败: $e');
    }
  }

  /// 读取并规范化用户添加的域名。
  ///
  /// 旧版本把 tanhua189 作为不可删除的内置域名；现在将它迁移成可删除的用户域名。
  /// 迁移版本号保证用户删除后不会在下次打开时重新出现。
  Future<List<String>> loadCustomDomains() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_prefsKeyUserDomains) ?? <String>[];
      final needsMigration =
          (prefs.getInt(_prefsKeyDomainListMigration) ?? 0) < 1;
      final domains = <String>[];

      void addCustom(String value) {
        final domain = normalizeDomain(value);
        if (domain.isEmpty || _isReservedDomain(domain)) return;
        if (!domains.contains(domain)) domains.add(domain);
      }

      for (final value in stored) {
        addCustom(value);
      }
      if (needsMigration) addCustom(_promotedDefaultDomain);
      addCustom(prefs.getString(_prefsKeyDomain) ?? '');
      addCustom(_baseUrl);

      if (stored.length != domains.length ||
          !List<String>.generate(
            stored.length,
            (i) => normalizeDomain(stored[i]),
          ).every((domain) => domains.contains(domain))) {
        await prefs.setStringList(_prefsKeyUserDomains, domains);
      }
      if (needsMigration) {
        await prefs.setInt(_prefsKeyDomainListMigration, 1);
      }
      return domains;
    } catch (e) {
      AppLogger.w('Site91', '读取自定义域名失败: $e');
      return <String>[];
    }
  }

  /// 保存当前选择与用户域名清单，保证删除当前选中的自定义域名时不会留下失效配置。
  Future<void> saveDomainConfiguration(
    String selectedUrl, {
    required Iterable<String> customDomains,
  }) async {
    final normalizedSelection = normalizeDomain(selectedUrl);
    final selected = _retiredDefaultDomains.contains(normalizedSelection)
        ? defaultDomains.first
        : (_legacyDomainAliases[normalizedSelection] ?? normalizedSelection);
    final cleanedDomains = <String>[];
    for (final value in customDomains) {
      final domain = normalizeDomain(value);
      if (domain.isEmpty || _isReservedDomain(domain)) continue;
      if (!cleanedDomains.contains(domain)) cleanedDomains.add(domain);
    }
    if (selected.isNotEmpty &&
        !_isReservedDomain(selected) &&
        !cleanedDomains.contains(selected)) {
      cleanedDomains.add(selected);
    }

    final nextBaseUrl = selected.isNotEmpty ? selected : defaultDomains.first;
    final previous = _baseUrl;
    _baseUrl = nextBaseUrl;
    _hasTestedDomain = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKeyUserDomains, cleanedDomains);
      await prefs.setString(_prefsKeyDomain, nextBaseUrl);
      await prefs.setInt(_prefsKeyDomainListMigration, 1);
    } catch (e) {
      AppLogger.w('Site91', '保存域名设置失败: $e');
    }
    AppLogger.i(
      'Site91',
      '域名设置已保存: $nextBaseUrl，自定义域名 ${cleanedDomains.length} 个',
    );
    _notifyDomainChanged(previous, automatic: false);
  }

  static bool _isReservedDomain(String domain) =>
      defaultDomains.contains(domain) ||
      _retiredDefaultDomains.contains(domain) ||
      _legacyDomainAliases.containsKey(domain);

  /// 恢复用户上次选择的域名。返回是否恢复成功。
  ///
  /// **刻意不做候选域名轮询**：域名由用户显式选择 ——「谁先探测通过就用谁」
  /// 的结果取决于当时的网络环境，并不可靠。没有保存值就如实返回 false，
  /// 由 UI 引导用户去选。
  Future<bool> restoreSelectedDomain() async {
    if (_hasTestedDomain) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKeyDomain);
      if (saved != null && saved.trim().isNotEmpty) {
        final normalized = normalizeDomain(saved);
        final migrated = _legacyDomainAliases[normalized] ?? normalized;
        final customDomains = await loadCustomDomains();
        final selected = _retiredDefaultDomains.contains(normalized)
            ? defaultDomains.first
            : migrated;
        if (!defaultDomains.contains(selected) &&
            !customDomains.contains(selected)) {
          AppLogger.w('Site91', '保存的域名不在可用列表中，回退至 ${defaultDomains.first}');
          return false;
        }
        final previous = _baseUrl;
        _baseUrl = selected;
        _hasTestedDomain = true;
        AppLogger.i('Site91', '已恢复用户选择的域名: $_baseUrl');
        if (_baseUrl != normalized) await _persistDomain(_baseUrl);
        // 恢复出来的域名可能与已保存条目所用的域名不同（例如上次自动切换过），
        // 所以这里同样要触发一次重定位。
        _notifyDomainChanged(previous, automatic: false);
        return true;
      }
    } catch (e) {
      AppLogger.w('Site91', '读取已保存域名失败: $e');
    }
    AppLogger.i('Site91', '尚无用户选定的域名，等待用户选择');
    return false;
  }

  /// 发起 GET 请求（带本地缓存与并发去重）。
  ///
  /// 命中缓存时**立即返回旧内容**，同时在后台静默刷新 —— 即 stale-while-revalidate。
  /// 这样「第二次进入任何看过的页面」都是 0 延迟，彻底绕开 91 服务端
  /// 0.7~2.3 秒的固有响应延迟（服务端 `no-store`，HTTP 缓存无效）。
  ///
  /// [forceRefresh] 为 true 时跳过缓存读取，但结果仍会写入缓存。
  /// [triedDomains] 是本次逻辑请求**已经试过**的域名集合，沿自动切换的递归链透传，
  /// 用于保证切换一定会终止（详见 [_findReachableDomain]）。
  Future<String> _request(
    String url, [
    Set<String>? triedDomains,
    bool forceRefresh = false,
  ]) async {
    if (!_hasTestedDomain) {
      await restoreSelectedDomain();
    }
    if (_baseUrl.isEmpty) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.badResponse,
        error: '尚未选择内容域名，请先点击右上角的「选择内容域名」',
      );
    }

    // ---- 缓存读取（仅对「已确定域名」的站点页面生效）----
    // 域名自动切换的重试链会带 triedDomains 递归进来，那一层不再读缓存，
    // 避免旧域名缓存盖住切换后的新内容。
    final isTopLevel = triedDomains == null;
    if (isTopLevel) {
      await _ensureDiskCacheLoaded();
      if (!forceRefresh) {
        // A stale detail page can contain an expired CDN signature. Listing
        // pages are safe to serve stale-while-revalidate; video details are
        // served stale only while they are still inside the normal cache TTL.
        final cached = _cachedHtml(url, allowStale: !_isVideoDetailUrl(url));
        if (cached != null) {
          AppLogger.i('Site91', '缓存命中（${cached.length} 字节），立即可用并在后台刷新: $url');
          _revalidateInBackground(url);
          return cached;
        }
      }
      // 并发去重：同一 URL 正在请求中，直接复用那个 Future。
      final inFlight = _inFlightRequests[url];
      if (inFlight != null) {
        AppLogger.i('Site91', '复用在途请求（避免重复网络往返）: $url');
        return inFlight;
      }
      final future = _requestOverNetwork(url, triedDomains, forceRefresh);
      _inFlightRequests[url] = future;
      try {
        final html = await future;
        // Store the final successful response here, not only in
        // _requestOverNetwork's normal-success branch. A Cloudflare retry can
        // return early, and an automatic mirror retry can complete in a nested
        // request; both paths must be cached too or every repeat search pays
        // the full network round trip again.
        if (html.isNotEmpty) _rememberHtml(url, html);
        return html;
      } finally {
        _inFlightRequests.remove(url);
      }
    }
    return _requestOverNetwork(url, triedDomains, forceRefresh);
  }

  /// 实际的网络请求实现（含域名切换 / Cloudflare 质询处理）。
  Future<String> _requestOverNetwork(
    String url,
    Set<String>? triedDomains,
    bool forceRefresh,
  ) async {
    final tried = triedDomains ?? <String>{};
    tried.add(_baseUrl);
    AppLogger.d('Site91', '发起 GET 请求: $url');
    final headers = <String, String>{'User-Agent': _ua, 'Referer': _baseUrl};
    if (_cookies.isNotEmpty) {
      headers['Cookie'] = _cookieHeader();
    }

    Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain, headers: headers),
      );
    } catch (e) {
      // 自动切换到其它候选域名（用户已同意「自动切并告知」，见 [onDomainChanged]）。
      //
      // ⚠️ 必须先存下旧域名再替换。旧实现写成：
      //      final newDomain = await testAndFindAvailableDomain();
      //      final newUrl = url.replaceFirst(_baseUrl, newDomain);
      //    而 testAndFindAvailableDomain 内部已经把 _baseUrl 改成了 newDomain，
      //    于是 replaceFirst 变成「新域名替换成新域名」—— URL 原封不动，
      //    带着旧域名再发一次 → 必然再失败 → 无限递归。
      final previous = _baseUrl;
      AppLogger.w('Site91', '请求失败 ($e)，尝试自动切换备用域名重试...');
      final newDomain = await _findReachableDomain(tried);
      if (newDomain != null) {
        _baseUrl = newDomain;
        _hasTestedDomain = true;
        unawaited(_persistDomain(newDomain));
        _notifyDomainChanged(previous, automatic: true);
        return _request(url.replaceFirst(previous, newDomain), tried);
      }
      rethrow;
    }

    _saveCookies(response.headers);
    AppLogger.d(
      'Site91',
      '响应状态: ${response.statusCode}, 长度: ${response.data?.length ?? 0}',
    );

    final data = response.data ?? '';

    // A keyword with no matches can be a plain 404 page that includes a generic
    // Cloudflare script. Do not mistake that page for a challenge and probe
    // every mirror; an empty result is the correct search outcome.
    if (response.statusCode == HttpStatus.notFound) {
      AppLogger.i('Site91', '页面不存在 (404)，按空结果处理: $url');
      return '';
    }

    // 检测 Cloudflare 质询 / 403 / 503 验证页面（内容特征判定见 [_looksLikeChallenge]）。
    final isChallenge =
        response.statusCode == 403 ||
        response.statusCode == 429 ||
        response.statusCode == 503 ||
        (response.statusCode == HttpStatus.ok &&
            _looksLikeChallenge(data) &&
            !_looksLikeSiteContent(data));

    if (isChallenge) {
      AppLogger.w(
        'Site91',
        '检测到 Cloudflare 访问质询 (code=${response.statusCode})，尝试自动处理...',
      );
      final cMatch = RegExp(r'href="([^"]*cdn-cgi[^"]*)"').firstMatch(data);
      if (cMatch != null) {
        final challengeUrl = cMatch.group(1)!;
        try {
          final cRes = await _dio.get<String>(
            challengeUrl,
            options: Options(
              headers: {
                'User-Agent': _ua,
                'Referer': url,
                if (_cookies.isNotEmpty) 'Cookie': _cookieHeader(),
              },
            ),
          );
          _saveCookies(cRes.headers);
          // 带新 Cookie 重试原始请求
          final retryRes = await _dio.get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              headers: {
                'User-Agent': _ua,
                'Referer': _baseUrl,
                if (_cookies.isNotEmpty) 'Cookie': _cookieHeader(),
              },
            ),
          );
          _saveCookies(retryRes.headers);
          if (retryRes.statusCode == 200 &&
              (retryRes.data?.length ?? 0) > 1000) {
            return retryRes.data ?? '';
          }
        } catch (e) {
          AppLogger.w('Site91', '自动处理质询异常: $e');
        }
      }

      // 若当前域名依然受阻，自动切到其它候选域名（会通过 [onDomainChanged] 告知用户）。
      final blocked = _baseUrl;
      final alt = await _findReachableDomain(tried);
      if (alt != null) {
        AppLogger.i('Site91', '当前域名受限，自动切换到: $alt');
        _baseUrl = alt;
        _hasTestedDomain = true;
        unawaited(_persistDomain(alt));
        _notifyDomainChanged(blocked, automatic: true);
        return _request(url.replaceFirst(blocked, alt), tried);
      }

      // 质询未能解除：一律抛错，绝不能把验证页当作正常内容返回。
      //
      // 关键：Cloudflare 的挑战页有时以 200 返回。若在此放行，上层会解析出 0 条，
      // 界面显示「没有匹配的内容」—— 把「站点限流」伪装成「真的没结果」，
      // 这正是搜索「时好时坏」的假象来源（返回 403/503 时反而会正确报错）。
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: '站点触发了访问验证 (code=${response.statusCode})，请稍后重试',
      );
    }

    // Top-level _request owns caching so successful challenge/mirror retries
    // are cached as well as this ordinary response path.
    return data;
  }

  @override
  List<VideoCategory> categoriesForChannel(ChannelType channel) {
    switch (channel) {
      case ChannelType.home:
        return const [];
      case ChannelType.video:
        return VideoCategories.videoList;
      case ChannelType.kedou:
        return VideoCategories.kedouList;
      case ChannelType.vod:
        return VideoCategories.vodList;
    }
  }

  @override
  Future<List<String>> fetchTags() async => const <String>[
    '最新发布',
    '高清',
    '热榜',
    '自拍偷拍',
    '国产精品',
    '原创精选',
  ];

  List<String>? _cachedHotKeywords;

  static const List<String> defaultHotKeywords = <String>[
    '极品',
    '少妇批发商',
    '高潮',
    '巨乳',
    '露脸',
    '人妻',
    '黑人',
    '91美男子',
    '熟女',
    'Jahe',
    'heisemeigui',
    '后续完整版请进群',
    '亓一',
    '绿帽',
    'hunshimowanga',
    '内射',
    '阿姨',
    '足交',
    '母狗',
    '调教',
    '肛交',
    '电子女友',
    '黑丝',
    'rzzpxcd',
    '大奶',
    '少妇',
    '91坏叔叔',
    '学生',
    '性感小皮鞭',
    '偷情',
    '找AV导航',
    '绿色小导航',
    '韩国主播',
    '人妻Jolly',
    '国产主播',
    'SWAG合集',
  ];

  @override
  Future<List<String>> fetchHotKeywords() async {
    if (_cachedHotKeywords != null && _cachedHotKeywords!.isNotEmpty) {
      return _cachedHotKeywords!;
    }
    try {
      final html = await _request('$_baseUrl/index');
      final doc = await _parseDocumentInBackground(html);
      final list = <String>[];
      for (final a in doc.querySelectorAll('a[href*="/search?keywords="]')) {
        final kw = a.text.trim();
        if (kw.isNotEmpty && !list.contains(kw)) {
          list.add(kw);
        }
      }
      if (list.isNotEmpty) {
        _cachedHotKeywords = list;
        AppLogger.i('Site91', '成功提取到官网九色热搜词 ${list.length} 个');
        return list;
      }
    } catch (e) {
      AppLogger.w('Site91', '提取热搜词失败，使用离线预置热词: $e');
    }
    _cachedHotKeywords = defaultHotKeywords;
    return defaultHotKeywords;
  }

  /// 首页视频浏览（默认获取最新/主页视频流）
  @override
  Future<VideoPage> fetchPage({required int page, int pageSize = 12}) async {
    return fetchChannelPage(
      channel: ChannelType.home,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 频道与专区分类分页拉取。
  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async {
    try {
      String targetUrl;
      switch (channel) {
        case ChannelType.home:
          // 官网 /index 仅有固定12部推荐视频且不支持 ?page=2 分页。
          // 第1页展示首页精选，第2页起无缝桥接至全量最新视频流 /video/category/latest/{page}
          if (page == 1) {
            targetUrl = '$_baseUrl/index';
          } else {
            targetUrl = '$_baseUrl/video/category/latest/$page';
          }
          break;

        case ChannelType.video:
          final p = (categoryPath != null && categoryPath.isNotEmpty)
              ? categoryPath
              : '/video/category/latest';
          if (p == '/video') {
            targetUrl = page == 1
                ? '$_baseUrl/video'
                : '$_baseUrl/video/category/latest/$page';
          } else if (p.startsWith('/video/category/')) {
            targetUrl = page == 1 ? '$_baseUrl$p' : '$_baseUrl$p/$page';
          } else {
            targetUrl = page == 1 ? '$_baseUrl$p' : '$_baseUrl$p/$page';
          }
          break;

        case ChannelType.kedou:
          final p = (categoryPath != null && categoryPath.isNotEmpty)
              ? categoryPath
              : '/videos/latest-updates';
          if (p == '/videos') {
            targetUrl = '$_baseUrl/videos/latest-updates/$page';
          } else if (p.startsWith('/videos/categories/')) {
            targetUrl = page == 1 ? '$_baseUrl$p' : '$_baseUrl$p/$page';
          } else if (p.startsWith('/videos/')) {
            targetUrl = '$_baseUrl$p/$page';
          } else {
            targetUrl = '$_baseUrl$p/$page';
          }
          break;

        case ChannelType.vod:
          final p = (categoryPath != null && categoryPath.isNotEmpty)
              ? categoryPath
              : '/vod';
          if (page == 1) {
            targetUrl = '$_baseUrl$p';
          } else {
            targetUrl = p.contains('?')
                ? '$_baseUrl$p&page=$page'
                : '$_baseUrl$p?page=$page';
          }
          break;
      }

      AppLogger.i(
        'Site91',
        '正在获取频道 [$channel] 分类 [$categoryPath]: 第 $page 页 ($targetUrl)',
      );
      final html = await _request(targetUrl);
      final doc = await _parseDocumentInBackground(html);
      final items = _parseVideoCards(
        html,
        defaultAuthor: channel == ChannelType.home ? '官方精选' : null,
        parsed: doc,
      );
      final (totalPages, totalItems) = _parsePaginationInfo(
        doc,
        null,
        page,
        items.length,
      );

      AppLogger.i(
        'Site91',
        '[$channel] 第 $page 页成功获取 ${items.length} 个视频, 总页数: $totalPages',
      );
      return VideoPage(
        items: items,
        page: page,
        totalPages: totalPages,
        totalItems: totalItems,
        hasMore: page < totalPages || items.isNotEmpty,
      );
    } catch (e, stack) {
      AppLogger.e('Site91', '获取频道 [$channel] 第 $page 页失败: $e', e, stack);
      return VideoPage.empty();
    }
  }

  /// 搜索：支持多维度过滤、搜索到用户与视频结果
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) async {
    final kw = query.keyword.trim();
    if (kw.isEmpty) {
      return VideoPage.empty();
    }

    try {
      if (query.searchType == SearchType.authorId) {
        // 模式 1：按作者 ID / 用户名搜索
        final url = page == 1
            ? '$_baseUrl/author/${Uri.encodeComponent(kw)}'
            : '$_baseUrl/author/${Uri.encodeComponent(kw)}?page=$page';
        AppLogger.i('Site91', '🔍 [搜作者ID] 第 $page 页: $kw ($url)');
        final html = await _request(url);
        final doc = await _parseDocumentInBackground(html);
        final items = _parseVideoCards(html, defaultAuthor: kw, parsed: doc);

        // 提取汇总信息（如：“669625672” 的搜索结果共计54个视频，第1/3页）
        String? summary;
        final summaryElem = doc.querySelector(
          'h5.container-title, h4.container-title',
        );
        if (summaryElem != null) {
          summary = summaryElem.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        }
        summary ??= '作者 "$kw" 的作品';

        final (totalPages, totalItems) = _parsePaginationInfo(
          doc,
          summary,
          page,
          items.length,
        );
        AppLogger.i(
          'Site91',
          '作者 [$kw] 搜索结果: ${items.length} 个视频, 第 $page/$totalPages 页 (共 $totalItems 部)',
        );
        return VideoPage(
          items: items,
          page: page,
          totalPages: totalPages,
          totalItems: totalItems,
          hasMore: page < totalPages,
          summary: summary,
        );
      } else {
        // 模式 2：按视频名称 / 关键词多维搜索（官网通用 search 接口）
        final queryParams = <String, String>{'keywords': kw};

        // 排序
        if (query.sortParam.isNotEmpty) {
          queryParams['sort'] = query.sortParam;
        } else if (query.sort == SortOrder.newest) {
          queryParams['sort'] = 'new';
        } else if (query.sort == SortOrder.popular) {
          queryParams['sort'] = 'hot';
        }

        // 选择分类
        if (query.category.isNotEmpty) queryParams['category'] = query.category;
        // 发布时间
        if (query.time.isNotEmpty) queryParams['time'] = query.time;
        // 播放量
        if (query.views.isNotEmpty) queryParams['views'] = query.views;
        // 视频长度
        if (query.duration.isNotEmpty) queryParams['duration'] = query.duration;
        // 分页
        if (page > 1) queryParams['page'] = '$page';

        final uri = Uri.parse('$_baseUrl/search')
            .replace(queryParameters: queryParams);
        AppLogger.i('Site91', '🔍 [搜视频] 第 $page 页: $uri');
        final html = await _request(uri.toString());

        final doc = await _parseDocumentInBackground(html);

        // 1. 提取汇总信息（如：“66” 的搜索结果共计380个视频，第1/16页）
        String? summary;
        final summaryElem = doc.querySelector(
          'h5.container-title, h4.container-title',
        );
        if (summaryElem != null) {
          summary = summaryElem.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        }

        // 2. 提取搜索到的用户列表（作者链接同样存在 /author/ 与 /dashen/ 两种形式）
        final users = <SearchedUser>[];
        for (final a in doc.querySelectorAll(
          'a[href*="/author/"], a[href*="/dashen/"]',
        )) {
          final countSpan = a.querySelector('.badge, span[class*="badge"]');
          if (countSpan != null) {
            final countText = countSpan.text.trim();
            final count = int.tryParse(countText) ?? 0;
            String name = '';
            for (final node in a.nodes) {
              if (node != countSpan && !countSpan.contains(node)) {
                name += node.text ?? '';
              }
            }
            name = name.trim();
            if (name.isEmpty) {
              name = a.text.trim().replaceAll(countText, '').trim();
            }
            final href = a.attributes['href']?.trim() ?? '';
            String authorId = '';
            final authorMatch = RegExp(r'/(?:author|dashen)/([^/?#]+)')
                .firstMatch(href);
            if (authorMatch != null) {
              authorId = Uri.decodeComponent(authorMatch.group(1)!.trim());
            }
            if (authorId.isEmpty) {
              authorId = name;
            }
            if (name.isNotEmpty &&
                !users.any((u) => u.authorId == authorId || u.name == name)) {
              users.add(
                SearchedUser(
                  name: name,
                  authorUrl: _resolveUrl(href),
                  authorId: authorId,
                  count: count,
                ),
              );
            }
          }
        }

        // 3. 提取视频列表
        final items = _parseVideoCards(html, parsed: doc);
        final (totalPages, totalItems) = _parsePaginationInfo(
          doc,
          summary,
          page,
          items.length,
        );
        AppLogger.i(
          'Site91',
          '关键词 [$kw] 搜索结果: ${items.length} 个视频, ${users.length} 个用户, 第 $page/$totalPages 页 (共 $totalItems 部)',
        );

        return VideoPage(
          items: items,
          page: page,
          totalPages: totalPages,
          totalItems: totalItems,
          hasMore: page < totalPages,
          users: users,
          summary: summary,
        );
      }
    } catch (e, stack) {
      AppLogger.e('Site91', '搜索出错: $e', e, stack);
      rethrow;
    }
  }

  Future<dom.Document> _parseDocumentInBackground(String html) =>
      Isolate.run(() => html_parser.parse(html));

  /// 从 HTML 页面中解析总页数与总条目数
  (int totalPages, int totalItems) _parsePaginationInfo(
    dynamic doc,
    String? summaryText,
    int currentPage,
    int currentItemCount,
  ) {
    int totalItems = 0;
    int totalPages = 1;

    // 1. 从 summary 文本提取，如：“66” 的搜索结果共计380个视频，第1/16页
    if (summaryText != null && summaryText.isNotEmpty) {
      final itemsMatch = RegExp(r'共计\s*(\d+)\s*个视频').firstMatch(summaryText);
      if (itemsMatch != null) {
        totalItems = int.tryParse(itemsMatch.group(1)!) ?? 0;
      }

      final pageMatch = RegExp(r'第\s*(\d+)\s*/\s*(\d+)\s*页')
          .firstMatch(summaryText);
      if (pageMatch != null) {
        totalPages = int.tryParse(pageMatch.group(2)!) ?? 1;
      }
    }

    // 2. 检查 ul.pagination 中的页码兜底
    try {
      final pageLinks = doc.querySelectorAll('ul.pagination li.page-item');
      for (final li in pageLinks) {
        final text = li.text.trim();
        final p = int.tryParse(text);
        if (p != null && p > totalPages) {
          totalPages = p;
        }
        final a = li.querySelector('a');
        if (a != null) {
          final href = a.attributes['href'] ?? '';
          final m = RegExp(r'[?&]page=(\d+)').firstMatch(href);
          if (m != null) {
            final hp = int.tryParse(m.group(1)!);
            if (hp != null && hp > totalPages) {
              totalPages = hp;
            }
          }
        }
      }
    } catch (e) {
      // 分页兜底解析抛异常 → totalPages 停在 1，用户侧表现为「只有第 1 页、无法翻页」。
      // 下游虽有一条 totalPages<=1 的诊断日志，但它分不清「选择器没匹配」与
      // 「这里抛了异常」，故在此明确记录。控制流不变：仍走后面的兜底赋值。
      AppLogger.w(
        'Site91',
        '分页兜底解析异常 page=$currentPage 本页条目=$currentItemCount: $e',
      );
    }

    if (totalItems == 0 && currentItemCount > 0) {
      totalItems = totalPages > 1 ? totalPages * 24 : currentItemCount;
    }

    if (totalPages < currentPage && currentItemCount > 0) {
      totalPages = currentPage;
    }

    // 诊断：本页确实有内容却只解析出 1 页时，记录分页信息的实际来源。
    // 若 summary 为 null 且 ul.pagination 条目为 0，说明两处选择器都已失配 —— 页码栏会退化成「第 1/1 页」而无法翻页。
    if (totalPages <= 1 && currentItemCount > 0) {
      int pageItemCount = 0;
      try {
        pageItemCount = doc
            .querySelectorAll('ul.pagination li.page-item')
            .length;
      } catch (_) {}
      AppLogger.i(
        'Site91',
        '分页仅解析出 1 页 —— summary=${summaryText ?? "null"}，'
            'ul.pagination 条目 $pageItemCount 个，本页条目 $currentItemCount',
      );
    }

    return (totalPages, totalItems);
  }

  /// 视频详情链接的已知形式（均为实测样本）：
  ///   `/view/xxxx`                        —— 短路径式
  ///   `/video/view/238636522`             —— 视频频道
  ///   `/video/viewhd/bbf1c1f4399795642f8c`—— 视频频道·高清
  ///   `/videos/view/127663/<hash>/`       —— 蝌蚪频道（注意结尾带 `/`）
  ///   `/vod/view/Sxfa`                    —— 精品频道
  ///   `/view_video.php?viewkey=xxx`       —— 查询参数式
  ///
  /// 最后一种不可省略：播放与预载服务都以 `viewkey` 作为缓存键
  /// （见 HlsCacheProxy / PreloadService），说明站点真实链接确实带该参数。
  /// 早期版本只匹配前两种，会把这类卡片整体滤掉，表现为「搜索有结果但列表为空」。
  ///
  /// 中间那条 `(?:video|videos|vod)/view(?:hd)?` 是覆盖面最广的一条：
  /// 四种频道路径式全部由它命中，因此新增镜像域名时通常无需改动本正则。
  static final RegExp _videoLinkPattern = RegExp(
    r'''/view/[A-Za-z0-9_-]+'''
    r'''|/(?:video|videos|vod)/view(?:hd)?/[^"'\s<>]+'''
    r'''|/view_video\.php\?[^"'\s<>]*viewkey=[^"'\s<>&]+''',
  );

  /// 解析列表中的卡片，综合提取真实标题、链接、缩略图、作者与日期
  ///
  /// [parsed] 允许调用方复用已经建好的 DOM。同一份 HTML 在同一方法里往往要
  /// 解析两次（取卡片 + 取分页），而 `html_parser.parse` 是主 isolate 上的
  /// 同步全量解析——实测首页 104KB 文档单次约 46ms、首屏 138ms。传入
  /// [parsed] 可省掉其中一次。传 null 时按 [html] 自行解析（保持原行为）。
  List<VideoItem> _parseVideoCards(
    String html, {
    String? defaultAuthor,
    dom.Document? parsed,
  }) {
    if (html.isEmpty && parsed == null) return const <VideoItem>[];
    final doc = parsed ?? html_parser.parse(html);
    final result = <VideoItem>[];
    final seen = <String>{};

    // 精准锁定视频卡片容器，排除筛选栏的 div.col 等
    final containers = doc.querySelectorAll(
      '.video-elem, .colVideoList > div, div.colVideoList, li[class*=video]',
    );

    for (final container in containers) {
      // 真实视频链接有三种已知形式（见 [_videoLinkPattern]），
      // 同时严防包含 /search、keywords=、views= 的伪链接
      final allLinks = container.querySelectorAll('a');
      dynamic videoLink;
      for (final a in allLinks) {
        final h = a.attributes['href']?.trim() ?? '';
        if (_videoLinkPattern.hasMatch(h) &&
            !h.contains('/search') &&
            !h.contains('keywords=') &&
            !h.contains('views=') &&
            !h.contains('/author/') &&
            !h.contains('/dashen/')) {
          videoLink = a;
          break;
        }
      }
      if (videoLink == null) continue;

      final href = videoLink.attributes['href']?.trim() ?? '';
      if (href.isEmpty ||
          href.endsWith('/video') ||
          href.endsWith('/videos') ||
          href.endsWith('/vod')) {
        continue;
      }

      final fullUrl = _resolveUrl(href);
      if (!seen.add(fullUrl)) continue;

      // 1. 提取真实标题（避开时长标签 00:08:00 与筛选“全部”误当标题）
      var title = '';
      final titleElem = container.querySelector('a.title, a[class*="title"]');
      if (titleElem != null) {
        final t = titleElem.text.trim();
        if (t.isNotEmpty &&
            !RegExp(r'^\d{1,2}:\d{2}').hasMatch(t) &&
            t != '全部') {
          title = t;
        }
      }
      if (title.isEmpty) {
        final titleAttr =
            videoLink.attributes['title'] ?? titleElem?.attributes['title'];
        if (titleAttr != null &&
            titleAttr.trim().isNotEmpty &&
            titleAttr.trim() != '全部') {
          title = titleAttr.trim();
        }
      }
      if (title.isEmpty) {
        for (final a in allLinks) {
          final t = a.text.trim();
          if (t.isNotEmpty &&
              t != '全部' &&
              !RegExp(r'^\d{1,2}:\d{2}').hasMatch(t) &&
              !t.contains('作者') &&
              !t.contains('播放') &&
              !t.contains('高清')) {
            title = t;
            break;
          }
        }
      }
      if (title.isEmpty || title == '全部') {
        continue; // 彻底剔除伪卡片
      }

      // 2. 提取封面缩略图：优先提取 CSS background-image: url(...)，其次提取 img 标签
      String? thumbUrl;
      final bgElem = container.querySelector('[style*="background-image"]');
      if (bgElem != null) {
        final style = bgElem.attributes['style'] ?? '';
        final m = RegExp(r"url\(['\x22]?([^'\x22\)]+)['\x22]?\)")
            .firstMatch(style);
        if (m != null) {
          thumbUrl = _resolveUrl(m.group(1)!);
        }
      }
      if (thumbUrl == null || thumbUrl.isEmpty) {
        final img = container.querySelector('img');
        if (img != null) {
          final imgSrc =
              img.attributes['data-src'] ??
              img.attributes['data-original'] ??
              img.attributes['src'];
          if (imgSrc != null && imgSrc.isNotEmpty) {
            thumbUrl = _resolveUrl(imgSrc);
          }
        }
      }

      // 3. 提取时长（如 00:08:00）
      String? durationStr;
      final layerElem = container.querySelector(
        '.layer, small.layer, [class*="duration"]',
      );
      if (layerElem != null) {
        durationStr = layerElem.text.trim();
      }
      if (durationStr == null || durationStr.isEmpty) {
        final dm = RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b')
            .firstMatch(container.text);
        durationStr = dm?.group(1);
      }

      // 4. 提取作者 UP 主（优先解析卡片真实作者，降级使用匿名）
      //
      // 作者链接有两种形式：`/author/xxx`（视频频道）与 `/dashen/xxx`（精品/vod 频道）。
      // 只认前者时，精品频道的 24/24 张卡片全部取不到作者，会统一降级成「匿名」。
      String? author;
      final authorElem = container.querySelector(
        'a[href*="/author/"], a[href*="/dashen/"], span[class*=author], span[class*=user]',
      );
      if (authorElem != null && authorElem.text.trim().isNotEmpty) {
        author = authorElem.text.trim();
      }

      final cText = container.text;
      if (author == null) {
        final am = RegExp(r'(?:作者|UP主)[：:]?\s*(\S+)').firstMatch(cText);
        if (am != null) {
          author = am.group(1);
        }
      }
      author ??= '匿名';

      // 5. 提取播放量与发布时间
      String? viewsStr;
      String? dateStr;

      final vm = RegExp(r'([\d\.]+\s*[kKwW万]?)\s*(?:次播放|次观看|次|views)')
          .firstMatch(cText);
      if (vm != null) {
        viewsStr = '${vm.group(1)}次';
      }

      // 日期：绝对日期（2026-09-28 / 2026/09/28）与相对日期（4小时前、12月前、1年前）。
      // 旧规则只认到「小时/天/分钟/秒前」，会把 `N月前` 形式的卡片全部丢掉日期。
      final tm = RegExp(
        r'(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d+\s*(?:秒|分钟|小时|天|周|个月|月|年)前)',
      ).firstMatch(cText);
      if (tm != null) {
        dateStr = tm.group(1);
      }

      result.add(
        VideoItem(
          id: fullUrl,
          title: title,
          author: author,
          hlsUrl: '', // 留空，进入播放器时按需深度解析
          detailUrl: fullUrl,
          thumbnailUrl: thumbUrl,
          durationStr: durationStr ?? '10:00',
          viewsStr: viewsStr ?? '1.2万次',
          publishedAt: dateStr,
        ),
      );
    }

    // 诊断：请求成功却一条都没解析出来时，留下足以定位问题的证据。
    // 判读方式：候选容器命中 0 个 → 容器选择器失配；链接样本与 [_videoLinkPattern] 不匹配 → 链接正则失配；
    // HTML 长度偏小（<2000）→ 多半是反爬质询页而非真实列表。
    if (result.isEmpty && html.isNotEmpty) {
      final sampleLinks = <String>[];
      for (final a in doc.querySelectorAll('a[href]')) {
        final h = a.attributes['href']?.trim() ?? '';
        if (h.contains('view') && sampleLinks.length < 6) {
          sampleLinks.add(h);
        }
      }
      AppLogger.w(
        'Site91',
        '卡片解析为 0 条 —— HTML 长度 ${html.length}，'
            '候选容器命中 ${containers.length} 个，'
            '含 view 的链接样本: $sampleLinks',
      );
    }

    return result;
  }

  /// 快速同步获取内存中已解析好的 HLS 地址（若已存在，立即返回，耗时 0ms）
  @override
  String? getCachedHlsUrl(String videoIdOrUrl) {
    final detailUrl = rebaseUrl(_resolveUrl(videoIdOrUrl));
    final cached = _detailCache[detailUrl];
    final cachedAt = _detailCacheTime[detailUrl];
    if (cached != null &&
        cached.video.hlsUrl.isNotEmpty &&
        _isStreamUrlFresh(cached.video.hlsUrl) &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) <= const Duration(minutes: 5)) {
      return cached.video.hlsUrl;
    }
    return null;
  }

  /// 快速同步获取内存中已缓存的详情
  VideoDetail? getCachedDetail(String videoIdOrUrl) {
    final detailUrl = rebaseUrl(_resolveUrl(videoIdOrUrl));
    return _detailCache[detailUrl];
  }

  /// Wait for title and recommendation enrichment after returning a fast URL.
  Future<VideoDetail?> waitForDetailEnrichment(String videoIdOrUrl) async {
    final detailUrl = rebaseUrl(_resolveUrl(videoIdOrUrl));
    final job = _detailEnrichmentJobs[detailUrl];
    if (job != null) return job;
    return _detailCache[detailUrl];
  }

  /// 视频详情页深度解析：提取 M3U8 地址、校正真实标题、发布日期及【相关推荐视频】
  @override
  Future<VideoDetail?> fetchDetail(
    String videoIdOrUrl, {
    bool forceRefresh = false,
  }) {
    final detailUrl = rebaseUrl(_resolveUrl(videoIdOrUrl));
    if (!forceRefresh) {
      final cachedTime = _detailCacheTime[detailUrl];
      final cached = _detailCache[detailUrl];
      if (cachedTime != null &&
          cached != null &&
          _isStreamUrlFresh(cached.video.hlsUrl) &&
          DateTime.now().difference(cachedTime) <= const Duration(minutes: 5)) {
        return Future<VideoDetail?>.value(cached);
      }
      final pending = _detailRequests[detailUrl];
      if (pending != null) return pending;
    }

    final request = _fetchDetailCore(videoIdOrUrl, forceRefresh: forceRefresh);
    if (forceRefresh) return request;

    late final Future<VideoDetail?> trackedRequest;
    trackedRequest = request.whenComplete(() {
      if (identical(_detailRequests[detailUrl], trackedRequest)) {
        _detailRequests.remove(detailUrl);
      }
    });
    _detailRequests[detailUrl] = trackedRequest;
    return trackedRequest;
  }

  Future<VideoDetail?> _fetchDetailCore(
    String videoIdOrUrl, {
    required bool forceRefresh,
  }) async {
    // rebaseUrl：观看记录 / 稍后再看 / 收藏里存的是保存当时的绝对 URL。
    // 用户换域名后旧 host 已失效，这里兜底重定位到当前域名，
    // 保证「历史里的视频」仍然点得开（即使调用方忘了先重写）。
    final detailUrl = rebaseUrl(_resolveUrl(videoIdOrUrl));
    final cachedTime = _detailCacheTime[detailUrl];
    final cachedDetail = _detailCache[detailUrl];
    final cachedStreamExpired =
        cachedDetail != null &&
        cachedDetail.video.hlsUrl.isNotEmpty &&
        !_isStreamUrlFresh(cachedDetail.video.hlsUrl);
    final isExpired =
        cachedTime == null ||
        DateTime.now().difference(cachedTime) > const Duration(minutes: 5) ||
        cachedStreamExpired;

    if (!forceRefresh && !isExpired && _detailCache.containsKey(detailUrl)) {
      AppLogger.i('Site91', '从内存缓存命中新鲜详情 (TTL 5m 内): $detailUrl');
      return _detailCache[detailUrl];
    }
    AppLogger.i(
      'Site91',
      '正在解析详情页 (forceRefresh=$forceRefresh, expired=$isExpired): $detailUrl',
    );

    try {
      // forceRefresh must bypass both the parsed-detail cache and HTML cache;
      // this is also the retry path after a signed playback URL expires.
      final html = await _request(
        detailUrl,
        null,
        forceRefresh || cachedStreamExpired,
      );
      if (html.isEmpty) {
        AppLogger.w('Site91', '详情页返回空内容');
        return null;
      }

      // A 91 watch page usually contains the final stream URL directly in the
      // video tag. Extract that small attribute before parsing the full page so
      // PlayerController can start the stream while title/recommendations are
      // decoded in the background.
      final quickStreamUrl = _extractStreamUrlFromHtml(html);
      if (quickStreamUrl != null) {
        final quickDetail = VideoDetail(
          video: VideoItem(
            id: detailUrl,
            title: '',
            author: '',
            hlsUrl: quickStreamUrl,
            detailUrl: detailUrl,
          ),
          variants: <VideoVariant>[
            VideoVariant(label: '原画 (Auto)', url: quickStreamUrl),
          ],
        );
        _rememberDetail(detailUrl, quickDetail);
        final enrichment = _parseDetailHtml(detailUrl, html, quickStreamUrl);
        _detailEnrichmentJobs[detailUrl] = enrichment;
        unawaited(() async {
          try {
            final enriched = await enrichment;
            _rememberDetail(detailUrl, enriched);
          } catch (e, stack) {
            AppLogger.e('Site91', '后台补充详情异常: $e', e, stack);
          } finally {
            if (identical(_detailEnrichmentJobs[detailUrl], enrichment)) {
              _detailEnrichmentJobs.remove(detailUrl);
            }
          }
        }());
        AppLogger.i('Site91', '已快速提取播放地址，详情资料改为后台补齐');
        return quickDetail;
      }

      final detail = await _parseDetailHtml(detailUrl, html);
      _rememberDetail(detailUrl, detail);
      return detail;
    } catch (e, stack) {
      AppLogger.e('Site91', '详情解析异常: $e', e, stack);
      return null;
    }
  }

  String? _extractStreamUrlFromHtml(String html) {
    final videoTag = RegExp(
      r'<video\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(html)?.group(0);
    final dataSrc = videoTag == null
        ? null
        : RegExp(
            r'''\bdata-src\s*=\s*(["'])(.*?)\1''',
            caseSensitive: false,
          ).firstMatch(videoTag)?.group(2);
    final source =
        dataSrc ??
        (videoTag == null
            ? null
            : RegExp(
                r'''\bsrc\s*=\s*(["'])(.*?)\1''',
                caseSensitive: false,
              ).firstMatch(videoTag)?.group(2));
    final candidate =
        source ??
        RegExp(
          r'''https?://[^"'\s<>]+\.(?:m3u8|mp4)[^"'\s<>]*''',
          caseSensitive: false,
        ).firstMatch(html)?.group(0);
    final cleaned = candidate?.replaceAll('&amp;', '&').trim();
    return cleaned == null || cleaned.isEmpty ? null : _resolveUrl(cleaned);
  }

  Future<VideoDetail> _parseDetailHtml(
    String detailUrl,
    String html, [
    String? knownStreamUrl,
  ]) async {
    final doc = await _parseDocumentInBackground(html);

    // 1. 尝试从 video 标签获取 data-src 或 src，或者回退正则匹配 M3U8/MP4
    final videoTag = doc.querySelector('video#video-play, video');
    var m3u8Url =
        knownStreamUrl ??
        videoTag?.attributes['data-src'] ??
        videoTag?.attributes['src'];

    if (m3u8Url == null || m3u8Url.trim().isEmpty) {
      final m3u8Regex = RegExp(r'https?://[^"\s<>]+\.(m3u8|mp4)[^"\s<>]*');
      m3u8Url = m3u8Regex.firstMatch(html)?.group(0);
    }

    if (m3u8Url != null) {
      m3u8Url = m3u8Url.replaceAll('&amp;', '&');
      m3u8Url = _resolveUrl(m3u8Url);
      AppLogger.i('Site91', '✓ 成功提取视频流地址: $m3u8Url');
    } else {
      AppLogger.w('Site91', '⚠ 详情页未能找到视频流地址');
    }

    // 2. 标题多级提取与清洗
    var title = '';
    final h4 = doc.querySelector('h4, h1, .video-title')?.text.trim();
    if (h4 != null && h4.isNotEmpty) {
      title = h4;
    }
    if (title.isEmpty) {
      final ogTitle = doc
          .querySelector('meta[property="og:title"]')
          ?.attributes['content']
          ?.trim();
      if (ogTitle != null && ogTitle.isNotEmpty) {
        title = ogTitle;
      }
    }
    if (title.isEmpty) {
      title = doc.querySelector('title')?.text.trim() ?? '未知标题';
      if (title.contains(' - ')) {
        title = title.split(' - ').first.trim();
      }
    }

    title = title
        .replaceAll(RegExp(r'[/:*?"<>|\\]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 3. 发布日期多级提取
    String? dateStr;
    final tm = RegExp(
      r'(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d+\s*(?:秒|分钟|小时|天|周|个月|月|年)前)',
    ).firstMatch(html);
    if (tm != null) {
      dateStr = tm.group(1);
    }

    // 4. 提取作者 UP 主与播放量
    // 精品频道（/vod/view/、/videos/view/）的作者链接是 `/dashen/xxx` 而非 `/author/xxx`，
    // 只认后者会一律回退成「官方UP主」。
    var author = '官方UP主';
    final authorElem = doc.querySelector(
      'a[href*="/author/"], a[href*="/dashen/"]',
    );
    if (authorElem != null && authorElem.text.trim().isNotEmpty) {
      author = authorElem.text.trim();
    }

    String? viewsStr;
    final vm = RegExp(r'([\d\.]+\s*[kKwW万]?)\s*(?:次播放|次观看|次|views)')
        .firstMatch(html);
    if (vm != null) {
      viewsStr = '${vm.group(1)}次播放';
    }

    // 5. 提取相关推荐视频 (Related Videos)
    final allCards = _parseVideoCards(html, parsed: doc);
    final relatedVideos = allCards
        .where((item) => item.detailUrl != detailUrl)
        .take(20)
        .toList();
    AppLogger.i(
      'Site91',
      '详情解析完成 -> 标题: $title, 日期: $dateStr, UP主: $author, 相关推荐: ${relatedVideos.length}条',
    );

    final updatedVideo = VideoItem(
      id: detailUrl,
      title: title,
      author: author,
      hlsUrl: m3u8Url ?? '',
      detailUrl: detailUrl,
      publishedAt: dateStr,
      viewsStr: viewsStr ?? '2.5万次',
      durationStr: '12:00',
    );

    final detail = VideoDetail(
      video: updatedVideo,
      variants: m3u8Url != null
          ? [VideoVariant(label: '原画 (Auto)', url: m3u8Url)]
          : const [],
      relatedVideos: relatedVideos,
    );
    return detail;
  }

  void _rememberDetail(String detailUrl, VideoDetail detail) {
    if (_detailCache.length >= 100 && !_detailCache.containsKey(detailUrl)) {
      final oldestKey = _detailCacheTime.keys.first;
      _detailCache.remove(oldestKey);
      _detailCacheTime.remove(oldestKey);
    }
    _detailCache[detailUrl] = detail;
    _detailCacheTime[detailUrl] = DateTime.now();
  }

  String _resolveUrl(String path) {
    late final String resolved;
    if (path.startsWith('//')) {
      resolved = 'https:$path';
    } else if (path.startsWith('http://') || path.startsWith('https://')) {
      resolved = path;
    } else if (path.startsWith('/')) {
      resolved = '$_baseUrl$path';
    } else {
      resolved = '$_baseUrl/$path';
    }
    return _normalizeVideoPageUrl(resolved);
  }
}
