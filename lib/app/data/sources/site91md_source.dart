/// 91麻豆（苹果CMS / MacCMS）内容源实现。
///
/// 与 [Site91Source] 同为「主站固定 + 用户可增删镜像站」的多域名源，骨架刻意
/// 保持一致：域名探测 / 持久化 / 自定义域名增删 / HTML 缓存（内存 + 磁盘）/
/// 并发去重 / Cloudflare 质询处理，全部沿用已验证过的同一套逻辑；
/// 只有**域名、解析选择器、取流方式**换成本站规则。
///
/// 站点为苹果 CMS（MacCMS）：
///   - 列表卡片：`.detail_right_div li`，兼容旧模板 `div.video-item`；
///   - 详情页：`/index.php/vod/play/id/<id>/sid/1/nid/1.html`，页内内嵌
///     `player_aaaa` JSON，`url` 字段即 m3u8。
///
/// 关于 `encrypt`：`player_aaaa.encrypt == 0` 时 `url` 为明文；非 0 时按
/// MacCMS 常见做法先尝试 base64 解码，**解不出来绝不静默返回空** —— 抛带
/// 明确文案的异常，由播放页把「该源加密暂不支持」原样显示给用户。
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

class Site91MdSource implements VideoSource {
  Site91MdSource({String? baseUrl, Dio? dio})
    : _baseUrl = _cleanBaseUrl(baseUrl ?? ''),
      _dio = dio ?? _createDio();

  /// 永久保留、不可删除的主站。镜像站由用户在「选择内容域名」里自行添加/删除。
  static const String mainDomain = 'https://www.91md.me';

  static const List<String> defaultDomains = <String>[mainDomain];

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  String _baseUrl;
  final Dio _dio;
  bool _hasTestedDomain = false;

  /// 域名变更回调：(原域名, 新域名, 是否由程序自动切换触发)。
  ///
  /// 与 91 源同义：既用于重写已保存条目（观看记录 / 收藏 / 稍后再看）里的旧
  /// host，也用于在自动切换时告知用户。
  void Function(String from, String to, bool automatic)? onDomainChanged;

  /// 用户自定义镜像域名缓存（`loadCustomDomains` 填充），供自动切换链使用。
  List<String> _customDomainsCache = <String>[];

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

  /// 详情缓存（含 5 分钟有效期，防止 m3u8 token 过期）。
  final Map<String, VideoDetail> _detailCache = <String, VideoDetail>{};
  final Map<String, DateTime> _detailCacheTime = <String, DateTime>{};
  final Map<String, Future<VideoDetail?>> _detailRequests =
      <String, Future<VideoDetail?>>{};

  // ---------------------------------------------------------------------------
  // HTML 响应缓存（内存 + 磁盘）与并发去重（与 91 源同一策略）
  // ---------------------------------------------------------------------------
  final Map<String, ({String html, DateTime at})> _htmlCache =
      <String, ({String html, DateTime at})>{};
  static const int _maxHtmlCacheEntries = 60;
  static const int _maxDiskCacheEntries = 40;
  static const String _diskCacheKeyPrefix = 'site91md_html_cache_v1_';

  final Map<String, Future<String>> _inFlightRequests =
      <String, Future<String>>{};
  final Set<String> _backgroundRevalidations = <String>{};
  static const Duration _htmlCacheStaleAfter = Duration(minutes: 5);

  Timer? _diskFlushTimer;
  final Map<String, String> _pendingDiskWrites = <String, String>{};
  bool _diskCacheLoaded = false;

  /// 在应用退出前调用，把待写入的缓存落盘（非接口成员，按需调用）。
  Future<void> flushCacheNow() async {
    _diskFlushTimer?.cancel();
    await _flushDiskCache();
  }

  String _diskKeyFor(String url) =>
      '$_diskCacheKeyPrefix${base64Url.encode(utf8.encode(url))}';

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
          // 详情页含带签名的播放地址，重启后不还原，避免用到过期 token。
          if (_isVideoDetailUrl(url)) {
            await prefs.remove(key);
            continue;
          }
          _htmlCache[url] = (html: inflated, at: DateTime.now());
        } catch (_) {
          unawaited(prefs.remove(key));
        }
      }
    } catch (e) {
      AppLogger.w('Site91Md', '载入磁盘缓存失败: $e');
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
      AppLogger.w('Site91Md', '写入磁盘缓存失败: $e');
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

  String? _cachedHtml(String url, {bool allowStale = true}) {
    final entry = _htmlCache[url];
    if (entry == null) return null;
    if (!allowStale &&
        DateTime.now().difference(entry.at) > _htmlCacheStaleAfter) {
      return null;
    }
    return entry.html;
  }

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
        AppLogger.d('Site91Md', '后台刷新 $url 失败（忽略）: $e');
      } finally {
        _backgroundRevalidations.remove(url);
      }
    }());
  }

  /// 当前生效的站点根地址（含 scheme，无结尾斜杠）。
  String get currentBaseUrl => _baseUrl;

  /// 永久保留、不可删除的候选域名（主站）。
  List<String> get domainCandidates => defaultDomains;

  static String _cleanBaseUrl(String url) {
    var cleaned = url.trim();
    if (cleaned.isEmpty) return cleaned;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned)) {
      cleaned = 'https://$cleaned';
    }
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  /// 规范化用户输入的站点根域名（补协议、统一 host 大小写）。非法返回空串。
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

  /// 规范化用户输入的域名（供本模块的域名对话框调用）。
  String normalizeDomainInput(String url) => normalizeDomain(url);

  static final RegExp _hostPattern = RegExp(
    r'^https?://([^/]+)',
    caseSensitive: false,
  );

  static String _hostOf(String url) =>
      _hostPattern.firstMatch(url)?.group(1)?.toLowerCase() ?? '';

  /// 把保存下来的旧域名 URL 重定位到当前选中的域名（只改 scheme + host，
  /// 完整保留 path 与 query）。非本站地址（CDN 的 m3u8 / 封面图）原样返回。
  String rebaseUrl(String url) {
    if (url.isEmpty) return url;
    if (_baseUrl.isEmpty) return url;
    final m = _hostPattern.firstMatch(url);
    if (m == null) return url; // 相对路径
    if (m.group(1)!.toLowerCase() == _hostOf(_baseUrl)) return url;
    if (!_isSiteAddress(url)) return url;
    return '$_baseUrl${url.substring(m.end)}';
  }

  /// 是否为「本站地址」——用路径形态判断而非 host 白名单，这样用户以前用过的、
  /// 早已不在候选里的自定义域名也能被正确重定位。
  bool _isSiteAddress(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final pathAndQuery = uri.query.isEmpty
        ? uri.path
        : '${uri.path}?${uri.query}';
    return _videoLinkPattern.hasMatch(pathAndQuery) ||
        uri.path.contains('/vod/type/id/') ||
        uri.path.contains('/vod/search');
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
    // 整页 HTML 的 UTF-8 解码挪到后台 isolate，避免启动预加载把 UI 线程顶到 ANR。
    dio.transformer = BackgroundDecodeTransformer();
    return dio;
  }

  @override
  String get id => 'site91md';

  @override
  String get displayName => '91麻豆';

  /// 纯探测：只回报域名当前是否可用，不改变任何内部状态。
  Future<bool> probeDomain(String url) async {
    final target = _cleanBaseUrl(url);
    if (target.isEmpty) return false;
    try {
      final res = await _dio.get<String>(
        target,
        options: Options(responseType: ResponseType.plain),
      );
      if (res.statusCode != 200) return false;
      // 质询页也可能以 200 返回，必须做内容特征判定。
      if (_looksLikeChallenge(res.data ?? '')) return false;
      AppLogger.i('Site91Md', '✓ 域名可用: $target');
      return true;
    } catch (e) {
      AppLogger.w('Site91Md', '域名无法访问: $target ($e)');
      return false;
    }
  }

  /// 在候选域名（主站 + 用户镜像）里找一个可达的，跳过 [exclude]。
  /// [exclude] 是终止性保证：没有它，A、B 会来回乒乓导致递归不收敛。
  Future<String?> _findReachableDomain(Set<String> exclude) async {
    final candidates = <String>[...defaultDomains, ..._customDomainsCache];
    for (final domain in candidates) {
      if (exclude.contains(domain)) continue;
      if (await probeDomain(domain)) return domain;
    }
    return null;
  }

  static bool _looksLikeChallenge(String data) =>
      data.contains('cdn-cgi/content?id=') ||
      data.contains('Just a moment...') ||
      data.contains('__cf_chl_') ||
      data.contains('Checking your browser');

  static bool _looksLikeSiteContent(String data) =>
      data.contains('video-item') ||
      data.contains('detail_right_div') ||
      data.contains('player_aaaa') ||
      RegExp(r'''class=["'][^"']*video-item''').hasMatch(data);

  static const String _prefsKeyDomain = 'site91md_selected_domain';
  static const String _prefsKeyUserDomains = 'site91md_user_domains';

  /// 采用用户显式选择的域名（立即生效 + 持久化）。
  void setBaseUrl(String newUrl) {
    final previous = _baseUrl;
    _baseUrl = _cleanBaseUrl(newUrl);
    _hasTestedDomain = true;
    AppLogger.i('Site91Md', '域名已更新为: $_baseUrl');
    unawaited(_persistDomain(_baseUrl));
    _notifyDomainChanged(previous, automatic: false);
  }

  void _notifyDomainChanged(String previous, {required bool automatic}) {
    if (_baseUrl.isEmpty || _baseUrl == previous) return;
    try {
      onDomainChanged?.call(previous, _baseUrl, automatic);
    } catch (e) {
      AppLogger.w('Site91Md', '域名变更回调异常: $e');
    }
  }

  Future<void> _persistDomain(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyDomain, url);
    } catch (e) {
      AppLogger.w('Site91Md', '保存域名失败: $e');
    }
  }

  static bool _isReservedDomain(String domain) =>
      defaultDomains.contains(domain);

  /// 读取用户自行添加的镜像域名（不含主站）。
  Future<List<String>> loadCustomDomains() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_prefsKeyUserDomains) ?? <String>[];
      final domains = <String>[];
      void addCustom(String value) {
        final domain = normalizeDomain(value);
        if (domain.isEmpty || _isReservedDomain(domain)) return;
        if (!domains.contains(domain)) domains.add(domain);
      }

      for (final value in stored) {
        addCustom(value);
      }
      addCustom(prefs.getString(_prefsKeyDomain) ?? '');
      addCustom(_baseUrl);
      _customDomainsCache = domains;
      return domains;
    } catch (e) {
      AppLogger.w('Site91Md', '读取自定义域名失败: $e');
      return <String>[];
    }
  }

  /// 采用并持久化「选中域名 + 用户自定义域名清单」。
  Future<void> saveDomainConfiguration(
    String selectedUrl, {
    required Iterable<String> customDomains,
  }) async {
    final selected = normalizeDomain(selectedUrl);
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
    _customDomainsCache = cleanedDomains;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKeyUserDomains, cleanedDomains);
      await prefs.setString(_prefsKeyDomain, nextBaseUrl);
    } catch (e) {
      AppLogger.w('Site91Md', '保存域名设置失败: $e');
    }
    AppLogger.i(
      'Site91Md',
      '域名设置已保存: $nextBaseUrl，自定义域名 ${cleanedDomains.length} 个',
    );
    _notifyDomainChanged(previous, automatic: false);
  }

  /// 恢复用户上次选择的域名。
  ///
  /// 与 91 源不同：本主站固定保留且开箱即用，因此没有保存值或保存值非法时
  /// **回退到主站**（而非返回 false 强制弹窗），保证首次使用也能直接出内容。
  Future<bool> restoreSelectedDomain() async {
    if (_hasTestedDomain) return true;
    final previous = _baseUrl;
    var selected = defaultDomains.first;
    try {
      final prefs = await SharedPreferences.getInstance();
      final customDomains = await loadCustomDomains();
      final saved = normalizeDomain(prefs.getString(_prefsKeyDomain) ?? '');
      if (saved.isNotEmpty &&
          (defaultDomains.contains(saved) || customDomains.contains(saved))) {
        selected = saved;
      }
    } catch (e) {
      AppLogger.w('Site91Md', '读取已保存域名失败，回退主站: $e');
    }
    _baseUrl = selected;
    _hasTestedDomain = true;
    AppLogger.i('Site91Md', '已恢复内容域名: $_baseUrl');
    _notifyDomainChanged(previous, automatic: false);
    return true;
  }

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

    final isTopLevel = triedDomains == null;
    if (isTopLevel) {
      await _ensureDiskCacheLoaded();
      if (!forceRefresh) {
        final cached = _cachedHtml(url, allowStale: !_isVideoDetailUrl(url));
        if (cached != null) {
          _revalidateInBackground(url);
          return cached;
        }
      }
      final inFlight = _inFlightRequests[url];
      if (inFlight != null) return inFlight;
      final future = _requestOverNetwork(url, triedDomains, forceRefresh);
      _inFlightRequests[url] = future;
      try {
        final html = await future;
        if (html.isNotEmpty) _rememberHtml(url, html);
        return html;
      } finally {
        _inFlightRequests.remove(url);
      }
    }
    return _requestOverNetwork(url, triedDomains, forceRefresh);
  }

  Future<String> _requestOverNetwork(
    String url,
    Set<String>? triedDomains,
    bool forceRefresh,
  ) async {
    final tried = triedDomains ?? <String>{};
    tried.add(_baseUrl);
    final headers = <String, String>{'User-Agent': _ua, 'Referer': _baseUrl};
    if (_cookies.isNotEmpty) headers['Cookie'] = _cookieHeader();

    Response<String> response;
    try {
      response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain, headers: headers),
      );
    } catch (e) {
      final previous = _baseUrl;
      AppLogger.w('Site91Md', '请求失败 ($e)，尝试自动切换备用域名重试...');
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
    final data = response.data ?? '';

    if (response.statusCode == HttpStatus.notFound) {
      return '';
    }

    final isChallenge =
        response.statusCode == 403 ||
        response.statusCode == 429 ||
        response.statusCode == 503 ||
        (response.statusCode == HttpStatus.ok &&
            _looksLikeChallenge(data) &&
            !_looksLikeSiteContent(data));

    if (isChallenge) {
      final blocked = _baseUrl;
      final alt = await _findReachableDomain(tried);
      if (alt != null) {
        _baseUrl = alt;
        _hasTestedDomain = true;
        unawaited(_persistDomain(alt));
        _notifyDomainChanged(blocked, automatic: true);
        return _request(url.replaceFirst(blocked, alt), tried);
      }
      // 质询未解除：抛错而非把验证页当正常内容返回，避免「站点限流」被伪装成「没结果」。
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: '站点触发了访问验证 (code=${response.statusCode})，请稍后重试',
      );
    }

    return data;
  }

  // ---------------------------------------------------------------------------
  // 分类
  // ---------------------------------------------------------------------------
  List<VideoCategory> _videoCategories = const <VideoCategory>[
    VideoCategory(id: 'all', name: '全部', path: '/'),
  ];
  bool _categoriesLoaded = false;

  @override
  List<VideoCategory> categoriesForChannel(ChannelType channel) {
    switch (channel) {
      case ChannelType.home:
        return const [];
      case ChannelType.video:
        return _videoCategories;
      case ChannelType.kedou:
      case ChannelType.vod:
        return const [];
    }
  }

  Future<void>? _categoryRequest;

  /// Keep the website's sidebar order; retry after errors instead of freezing
  /// the fallback category permanently.
  Future<void> fetchCategories({bool refresh = false}) {
    if (_categoriesLoaded && !refresh) return Future<void>.value();
    if (_categoryRequest != null) return _categoryRequest!;
    late final Future<void> request;
    request =
        (() async {
          await restoreSelectedDomain();
          final html = await _request('$_baseUrl/', null, refresh);
          final doc = await _parseDocumentInBackground(html);
          final nav = doc.querySelector('.detail_left, nav, aside, .sidebar');
          final anchors = (nav ?? doc).querySelectorAll(
            'a[href*="/vod/type/id/"]',
          );
          final list = <VideoCategory>[];
          final seen = <String>{};
          for (final a in anchors) {
            final href = a.attributes['href']?.trim() ?? '';
            final match = RegExp(r'/vod/type/id/(\d+)').firstMatch(href);
            final name = a.text.trim();
            if (match == null || name.isEmpty || !seen.add(match.group(1)!)) {
              continue;
            }
            final uri = Uri.tryParse(href);
            final path = uri?.path ?? href;
            list.add(
              VideoCategory(id: match.group(1)!, name: name, path: path),
            );
          }
          if (list.isEmpty) throw StateError('未找到网站栏目，请刷新或切换内容域名');
          _videoCategories = list;
          _categoriesLoaded = true;
        })().whenComplete(() {
          if (identical(_categoryRequest, request)) _categoryRequest = null;
        });
    _categoryRequest = request;
    return request;
  }

  @override
  Future<List<String>> fetchTags() async {
    await fetchCategories();
    return _videoCategories.map((c) => c.name).toList();
  }

  List<String>? _cachedHotKeywords;

  static const List<String> defaultHotKeywords = <String>[
    '麻豆传媒',
    '国产',
    '自拍',
    '无码',
    '人妻',
    '剧情',
    '中文',
    '高清',
  ];

  @override
  Future<List<String>> fetchHotKeywords() async {
    await restoreSelectedDomain();
    if (_cachedHotKeywords != null && _cachedHotKeywords!.isNotEmpty) {
      return _cachedHotKeywords!;
    }
    try {
      final html = await _request('$_baseUrl/');
      final doc = await _parseDocumentInBackground(html);
      final list = <String>[];
      for (final a in doc.querySelectorAll('a[href*="wd="]')) {
        final kw = a.text.trim();
        if (kw.isNotEmpty && !list.contains(kw)) list.add(kw);
        if (list.length >= 36) break;
      }
      if (list.isNotEmpty) {
        _cachedHotKeywords = list;
        return list;
      }
    } catch (e) {
      AppLogger.w('Site91Md', '提取热搜词失败，使用离线预置热词: $e');
    }
    _cachedHotKeywords = defaultHotKeywords;
    return defaultHotKeywords;
  }

  // ---------------------------------------------------------------------------
  // 列表
  // ---------------------------------------------------------------------------
  @override
  Future<VideoPage> fetchPage({required int page, int pageSize = 12}) {
    return fetchChannelPage(
      channel: ChannelType.home,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async {
    try {
      await restoreSelectedDomain();
      String targetUrl;
      switch (channel) {
        case ChannelType.home:
          targetUrl = page <= 1 ? '$_baseUrl/' : '$_baseUrl/?page=$page';
          break;
        case ChannelType.video:
        case ChannelType.kedou:
        case ChannelType.vod:
          final p = (categoryPath != null && categoryPath.isNotEmpty)
              ? categoryPath
              : '/';
          targetUrl = _buildListUrl(p, page);
          break;
      }

      AppLogger.i(
        'Site91Md',
        '获取频道 [$channel] 分类 [$categoryPath] 第 $page 页 ($targetUrl)',
      );
      final html = await _request(targetUrl);
      final doc = await _parseDocumentInBackground(html);
      final items = _parseVideoCards(html, parsed: doc);
      final totalPages = _parseTotalPages(doc, page, items.length);

      return VideoPage(
        items: items,
        page: page,
        totalPages: totalPages,
        totalItems: items.length,
        hasMore: page < totalPages,
      );
    } catch (e, stack) {
      AppLogger.e('Site91Md', '获取频道 [$channel] 第 $page 页失败: $e', e, stack);
      rethrow;
    }
  }

  /// 把分类路径与页码拼成列表 URL。MacCMS 分页形如 `.../id/1/page/2.html`。
  String _buildListUrl(String path, int page) {
    final uri = Uri.parse(_baseUrl).resolve(path);
    if (page <= 1) return uri.toString();
    if (uri.path.endsWith('.html')) {
      final clean = uri.path.replaceFirst(RegExp(r'/page/\d+\.html$'), '.html');
      return uri
          .replace(
            path: clean.replaceFirst(RegExp(r'\.html$'), '/page/$page.html'),
          )
          .toString();
    }
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'page': '$page'})
        .toString();
  }

  int _parseTotalPages(dom.Document doc, int currentPage, int itemCount) {
    var totalPages = 1;
    try {
      for (final a in doc.querySelectorAll(
        'a[href*="/page/"], a[href*="page="]',
      )) {
        final href = a.attributes['href'] ?? '';
        final m =
            RegExp(r'/page/(\d+)(?:/|\.html)').firstMatch(href) ??
            RegExp(r'[?&]page=(\d+)').firstMatch(href);
        if (m != null) {
          final p = int.tryParse(m.group(1)!);
          if (p != null && p > totalPages) totalPages = p;
        }
      }
      // 有些模板把总页数写在文本里，如「共 12 页」。
      // doc.text 在 html 包里是可空的，正则要非空入参，故兜底空串。
      final totalMatch = RegExp(r'共\s*(\d+)\s*页').firstMatch(doc.text ?? '');
      if (totalMatch != null) {
        final p = int.tryParse(totalMatch.group(1)!);
        if (p != null && p > totalPages) totalPages = p;
      }
    } catch (_) {}
    if (totalPages < currentPage && itemCount > 0) totalPages = currentPage;
    return totalPages;
  }

  /// 详情页链接：`/index.php/vod/play/id/<id>/sid/1/nid/1.html`。
  static final RegExp _videoLinkPattern = RegExp(r'/vod/play/id/(\d+)/');

  List<VideoItem> _parseVideoCards(String html, {dom.Document? parsed}) {
    if (html.isEmpty && parsed == null) return const <VideoItem>[];
    final doc = parsed ?? html_parser.parse(html);
    final result = <VideoItem>[];
    final seen = <String>{};

    for (final container in doc.querySelectorAll(
      'div.video-item, .detail_right_div li, .sugetVideo li',
    )) {
      dynamic videoLink;
      for (final a in container.querySelectorAll('a[href]')) {
        final h = a.attributes['href']?.trim() ?? '';
        if (_videoLinkPattern.hasMatch(h)) {
          videoLink = a;
          break;
        }
      }
      if (videoLink == null) continue;

      final href = videoLink.attributes['href']?.trim() ?? '';
      final fullUrl = _resolveUrl(href);
      if (!seen.add(fullUrl)) continue;

      // 标题：优先 `.title`，回退 img 的 alt/title。
      var title = '';
      final titleElem = container.querySelector('.title');
      if (titleElem != null) title = titleElem.text.trim();
      if (title.isEmpty) {
        for (final paragraph in container.querySelectorAll('p')) {
          if (paragraph.querySelector('img, i, strong') == null &&
              paragraph.text.trim().isNotEmpty) {
            title = paragraph.text.trim();
            break;
          }
        }
      }
      if (title.isEmpty) {
        final img = container.querySelector('img');
        title =
            img?.attributes['alt']?.trim() ??
            img?.attributes['title']?.trim() ??
            '';
      }
      if (title.isEmpty) continue;

      // 缩略图：MacCMS 用 img.lazy，真实地址可能在 data-src / data-original。
      String? thumbUrl;
      final img = container.querySelector('img');
      if (img != null) {
        final src =
            img.attributes['data-src'] ??
            img.attributes['data-original'] ??
            img.attributes['src'];
        if (src != null && src.isNotEmpty) thumbUrl = _resolveUrl(src);
      }

      final dateStr = container.querySelector('.time, i')?.text.trim();
      final viewsRaw = container.querySelector('.view, strong')?.text.trim();

      result.add(
        VideoItem(
          id: fullUrl,
          title: title,
          author: '91麻豆',
          hlsUrl: '', // 进入播放器时按需解析
          detailUrl: fullUrl,
          thumbnailUrl: thumbUrl,
          publishedAt: dateStr,
          viewsStr: viewsRaw,
        ),
      );
    }

    if (result.isEmpty && html.isNotEmpty) {
      AppLogger.w(
        'Site91Md',
        '卡片解析为 0 条 —— HTML 长度 ${html.length}，'
            'div.video-item 命中 ${doc.querySelectorAll('div.video-item, .detail_right_div li, .sugetVideo li').length} 个',
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------------
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) async {
    final kw = query.keyword.trim();
    if (kw.isEmpty) return VideoPage.empty();
    try {
      await restoreSelectedDomain();
      final uri = Uri.parse(
        '$_baseUrl/index.php/vod/search/page/$page/wd/${Uri.encodeComponent(kw)}.html',
      );
      AppLogger.i('Site91Md', '🔍 搜索第 $page 页: $uri');
      final html = await _request(uri.toString());
      final doc = await _parseDocumentInBackground(html);
      final items = _parseVideoCards(html, parsed: doc);
      final totalPages = _parseTotalPages(doc, page, items.length);
      return VideoPage(
        items: items,
        page: page,
        totalPages: totalPages,
        totalItems: items.length,
        hasMore: page < totalPages,
        summary: kw,
      );
    } catch (e, stack) {
      AppLogger.e('Site91Md', '搜索出错: $e', e, stack);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 详情与取流
  // ---------------------------------------------------------------------------
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

  @override
  Future<VideoDetail?> fetchDetail(
    String videoIdOrUrl, {
    bool forceRefresh = false,
  }) {
    if (!_hasTestedDomain) {
      return restoreSelectedDomain().then(
        (_) => fetchDetail(videoIdOrUrl, forceRefresh: forceRefresh),
      );
    }
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

    final request = _fetchDetailCore(detailUrl, forceRefresh: forceRefresh);
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
    String detailUrl, {
    required bool forceRefresh,
  }) async {
    try {
      final html = await _request(detailUrl, null, forceRefresh);
      if (html.isEmpty) {
        AppLogger.w('Site91Md', '详情页返回空内容: $detailUrl');
        return null;
      }

      final info = _parsePlayerInfo(html);
      if (info == null) {
        AppLogger.w('Site91Md', '详情页未找到 player_aaaa 内嵌 JSON');
        return null;
      }

      // 取流：encrypt 非 0 时先按 MacCMS 常见做法解码，解不出**抛错**，
      // 由播放页显示「该源加密暂不支持」，绝不静默返回空。
      final streamUrl = _resolveStreamUrl(info, detailUrl);

      final doc = await _parseDocumentInBackground(html);
      final titleFromPage =
          doc.querySelector('span.title, .vod-title')?.text.trim() ??
          doc.querySelector('h1')?.text.trim() ??
          '';
      final title = (info['vod_data'] is Map)
          ? (info['vod_data']['vod_name']?.toString().trim() ?? '')
          : '';

      final video = VideoItem(
        id: detailUrl,
        title: title.isEmpty ? titleFromPage : title,
        author: '91麻豆',
        hlsUrl: streamUrl ?? '',
        detailUrl: detailUrl,
      );
      final detail = VideoDetail(
        video: video,
        relatedVideos: _parseVideoCards(html, parsed: doc),
        variants: streamUrl != null
            ? <VideoVariant>[VideoVariant(label: '原画 (Auto)', url: streamUrl)]
            : const <VideoVariant>[],
      );
      _rememberDetail(detailUrl, detail);
      AppLogger.i('Site91Md', '详情解析完成: $title -> $streamUrl');
      return detail;
    } catch (e, stack) {
      AppLogger.e('Site91Md', '详情解析异常: $e', e, stack);
      rethrow; // 交给上层把具体原因（如加密不支持）反馈到 UI
    }
  }

  /// 解析页内 `player_aaaa` 后的 JSON 对象。用括号配平扫描，避免正则贪婪截断。
  ///
  /// 字符比较一律走 [String.codeUnitAt]：既避免在源码里写花括号字面量，
  /// 也让「是否处于字符串内 / 是否转义」的判定更明确。
  Map<String, dynamic>? _parsePlayerInfo(String html) {
    const codeQuote = 0x22; // 双引号
    const codeBackslash = 0x5C; // 反斜杠
    const codeOpenBrace = 0x7B; // 左花括号
    const codeCloseBrace = 0x7D; // 右花括号

    final m = RegExp(r'player_aaaa\s*=\s*').firstMatch(html);
    if (m == null) return null;
    final start = m.end;
    if (start >= html.length || html.codeUnitAt(start) != codeOpenBrace) {
      return null;
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < html.length; i++) {
      final code = html.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == codeBackslash) {
          escaped = true;
        } else if (code == codeQuote) {
          inString = false;
        }
        continue;
      }
      if (code == codeQuote) {
        inString = true;
      } else if (code == codeOpenBrace) {
        depth++;
      } else if (code == codeCloseBrace) {
        depth--;
        if (depth == 0) {
          final raw = html.substring(start, i + 1);
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) return decoded;
            if (decoded is Map) return Map<String, dynamic>.from(decoded);
          } catch (e) {
            AppLogger.w('Site91Md', 'player_aaaa JSON 解析失败: $e');
          }
          return null;
        }
      }
    }
    return null;
  }

  /// 按 `encrypt` 解析出真正的 m3u8 地址。解不出返回 null 且记录明确原因。
  String? _resolveStreamUrl(Map<String, dynamic> info, String detailUrl) {
    final raw = (info['url']?.toString() ?? '').trim();
    final encrypt = int.tryParse(info['encrypt']?.toString() ?? '0') ?? 0;
    if (raw.isEmpty) {
      // 少数模板把地址放在 url_next。
      final next = (info['url_next']?.toString() ?? '').trim();
      if (next.isEmpty) {
        AppLogger.w('Site91Md', 'player_aaaa 无 url 字段');
        return null;
      }
      return _resolveUrl(next);
    }
    if (encrypt == 0) {
      return _resolveUrl(raw.replaceAll('&amp;', '&'));
    }
    // encrypt == 1/2：MacCMS 常见做法是把明文地址做 base64（部分版本再包一层）。
    try {
      final decoded = encrypt == 1
          ? Uri.decodeComponent(raw)
          : Uri.decodeComponent(
              utf8.decode(base64.decode(base64.normalize(raw))),
            );
      if (decoded.startsWith('http')) return _resolveUrl(decoded);
    } catch (_) {}
    // 处理不了 —— 明确抛出，让播放页显示「该源加密暂不支持」而非「没结果」。
    throw DioException(
      requestOptions: RequestOptions(path: detailUrl),
      type: DioExceptionType.badResponse,
      error: '该源加密暂不支持（encrypt=$encrypt）',
    );
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

  Future<dom.Document> _parseDocumentInBackground(String html) =>
      Isolate.run(() => html_parser.parse(html));

  String _resolveUrl(String path) {
    if (path.isEmpty) return path;
    // 允许直接传纯数字 id（如 40636）—— 补成标准播放页地址。
    if (RegExp(r'^\d+$').hasMatch(path)) {
      return '$_baseUrl/index.php/vod/play/id/$path/sid/1/nid/1.html';
    }
    if (path.startsWith('//')) return 'https:$path';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('/')) return '$_baseUrl$path';
    return '$_baseUrl/$path';
  }
}
