/// PornHub 内容源实现。
///
/// 设计目标：把 cn.pornhub.com 的浏览能力接到现有 [VideoSource] 抽象上，
/// 使上层（home / search / player / downloads）**零改动**即可支持该站点。
///
/// 三个关键事实（均来自对真实页面的实测，非推测）：
///
/// 1. **取流形态与 91 同构**。详情页内嵌 `var flashvars_<数字ID> = {...}`，
///    其中 `mediaDefinitions` 为 4 档 HLS（240/480/720/1080，720 为默认），
///    每档一条 `master.m3u8?validfrom=…&validto=…&ipa=1&hdl=-1&hash=…`。
///    因此播放、下载、预缓存管线全部复用，不需要新增任何媒体处理代码。
///
/// 2. **广告在结构上不存在**。本项目把页面解析成数据后用自己的控件渲染，
///    从不执行官网的 `<script>` / `<iframe>`；更重要的是**从不实例化官网播放器**，
///    所以由它发起的贴片广告（VAST/VMAP）请求根本不会发出。解析层再叠加一道
///    容器级过滤（[_isAdNode]），用于兜住官网随登录态插入的推广卡片。
///
/// MP4 media definitions can point to a JSON quality endpoint. Resolve that
/// endpoint before ranking its actual streams alongside HLS variants.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../core/app_logger.dart';
import '../../services/background_decode_transformer.dart';
import '../../services/pornhub_auth_service.dart';
import '../models/pornhub_models.dart';
import '../models/video_item.dart';
import 'video_source.dart';

class PornHubRequestException implements Exception {
  const PornHubRequestException();

  @override
  String toString() => PornHubSource.requestFailureMessage;
}

class PornHubBrowseData {
  const PornHubBrowseData({
    this.videos = const [],
    this.creators = const [],
    this.playlists = const [],
    this.filters = const [],
    this.suggestions = const [],
    this.hasMore = false,
    this.total,
  });
  final List<VideoItem> videos;
  final List<PornHubSubscription> creators;
  final List<PornHubPlaylist> playlists;
  final List<PornHubFilterGroup> filters;
  final List<PornHubLinkItem> suggestions;
  final bool hasMore;
  final int? total;
}

/// 官网分类体系（实测自 `/categories`，96 项，ID 与名称均为真实值）。
class PornHubCategories {
  PornHubCategories._();

  /// 首页入口（非分类，但同属「频道」维度）。
  ///
  /// 排序参数 `o=ht/mv/tr/cm` 与 `p=homemade` 均为官网真实链接（实测自首页与分类页），
  /// 不是推断值。注意**没有** `min_duration` 这类参数 —— 不要凭直觉添加。
  static const List<VideoCategory> entryList = <VideoCategory>[
    VideoCategory(id: 'ph_home', name: '首页推荐', path: '/video'),
    VideoCategory(id: 'ph_ht', name: '最热', path: '/video?o=ht'),
    VideoCategory(id: 'ph_mv', name: '最多次观看', path: '/video?o=mv'),
    VideoCategory(id: 'ph_tr', name: '最高分', path: '/video?o=tr'),
    VideoCategory(id: 'ph_cm', name: '最新', path: '/video?o=cm'),
    VideoCategory(
      id: 'ph_homemade',
      name: '热门自制',
      path: '/video?p=homemade&o=tr',
    ),
  ];

  /// 96 个官方分类（`/video?c=<id>`）。
  static const List<VideoCategory> categoryList = <VideoCategory>[
    VideoCategory(id: 'c1', name: '亚洲人', path: '/video?c=1'),
    VideoCategory(id: 'c2', name: '乱交群欢', path: '/video?c=2'),
    VideoCategory(id: 'c3', name: '素人', path: '/video?c=3'),
    VideoCategory(id: 'c4', name: '肥臀', path: '/video?c=4'),
    VideoCategory(id: 'c6', name: '大号美女', path: '/video?c=6'),
    VideoCategory(id: 'c7', name: '巨屌', path: '/video?c=7'),
    VideoCategory(id: 'c8', name: '巨乳', path: '/video?c=8'),
    VideoCategory(id: 'c9', name: '金发女', path: '/video?c=9'),
    VideoCategory(id: 'c10', name: '捆绑', path: '/video?c=10'),
    VideoCategory(id: 'c11', name: '深发女', path: '/video?c=11'),
    VideoCategory(id: 'c12', name: '名人', path: '/video?c=12'),
    VideoCategory(id: 'c13', name: '口交', path: '/video?c=13'),
    VideoCategory(id: 'c14', name: '集体颜射', path: '/video?c=14'),
    VideoCategory(id: 'c15', name: '内射中出', path: '/video?c=15'),
    VideoCategory(id: 'c16', name: '射精', path: '/video?c=16'),
    VideoCategory(id: 'c17', name: '黑人女', path: '/video?c=17'),
    VideoCategory(id: 'c18', name: '恋物癖', path: '/video?c=18'),
    VideoCategory(id: 'c19', name: '拳交', path: '/video?c=19'),
    VideoCategory(id: 'c20', name: '手交', path: '/video?c=20'),
    VideoCategory(id: 'c21', name: '劲爆重口味', path: '/video?c=21'),
    VideoCategory(id: 'c22', name: '手淫', path: '/video?c=22'),
    VideoCategory(id: 'c23', name: '性玩具', path: '/video?c=23'),
    VideoCategory(id: 'c24', name: '公众野战', path: '/video?c=24'),
    VideoCategory(id: 'c25', name: '跨种族', path: '/video?c=25'),
    VideoCategory(id: 'c26', name: '拉丁裔美女', path: '/video?c=26'),
    VideoCategory(id: 'c27', name: '女同', path: '/video?c=27'),
    VideoCategory(id: 'c28', name: '熟女', path: '/video?c=28'),
    VideoCategory(id: 'c29', name: '辣妈', path: '/video?c=29'),
    VideoCategory(id: 'c31', name: '真人实拍', path: '/video?c=31'),
    VideoCategory(id: 'c32', name: '搞笑', path: '/video?c=32'),
    VideoCategory(id: 'c33', name: '脱衣舞', path: '/video?c=33'),
    VideoCategory(id: 'c35', name: '爆菊', path: '/video?c=35'),
    VideoCategory(id: 'c41', name: '第一视角', path: '/video?c=41'),
    VideoCategory(id: 'c42', name: '红毛', path: '/video?c=42'),
    VideoCategory(id: 'c43', name: '古典派', path: '/video?c=43'),
    VideoCategory(id: 'c53', name: '聚会', path: '/video?c=53'),
    VideoCategory(id: 'c55', name: '欧洲人', path: '/video?c=55'),
    VideoCategory(id: 'c57', name: '合集', path: '/video?c=57'),
    VideoCategory(id: 'c59', name: '贫乳', path: '/video?c=59'),
    VideoCategory(id: 'c61', name: '视频激情', path: '/video?c=61'),
    VideoCategory(id: 'c65', name: '3P', path: '/video?c=65'),
    VideoCategory(id: 'c67', name: '粗暴性爱', path: '/video?c=67'),
    VideoCategory(id: 'c69', name: '潮吹', path: '/video?c=69'),
    VideoCategory(id: 'c72', name: '双龙入洞', path: '/video?c=72'),
    VideoCategory(id: 'c76', name: '双性恋男', path: '/video?c=76'),
    VideoCategory(id: 'c78', name: '按摩', path: '/video?c=78'),
    VideoCategory(id: 'c80', name: '轮交', path: '/video?c=80'),
    VideoCategory(id: 'c81', name: '角色扮演', path: '/video?c=81'),
    VideoCategory(id: 'c86', name: '卡通', path: '/video?c=86'),
    VideoCategory(id: 'c88', name: '校园', path: '/video?c=88'),
    VideoCategory(id: 'c89', name: '火辣保姆', path: '/video?c=89'),
    VideoCategory(id: 'c90', name: '试镜', path: '/video?c=90'),
    VideoCategory(id: 'c91', name: '抽烟', path: '/video?c=91'),
    VideoCategory(id: 'c92', name: '男性自慰', path: '/video?c=92'),
    VideoCategory(id: 'c93', name: '恋足', path: '/video?c=93'),
    VideoCategory(id: 'c94', name: '法国人', path: '/video?c=94'),
    VideoCategory(id: 'c95', name: '德国人', path: '/video?c=95'),
    VideoCategory(id: 'c96', name: '英国人', path: '/video?c=96'),
    VideoCategory(id: 'c97', name: '意大利人', path: '/video?c=97'),
    VideoCategory(id: 'c98', name: '阿拉伯人', path: '/video?c=98'),
    VideoCategory(id: 'c99', name: '俄国人', path: '/video?c=99'),
    VideoCategory(id: 'c100', name: '捷克人', path: '/video?c=100'),
    VideoCategory(id: 'c101', name: '印度人', path: '/video?c=101'),
    VideoCategory(id: 'c102', name: '巴西人', path: '/video?c=102'),
    VideoCategory(id: 'c103', name: '韩国人', path: '/video?c=103'),
    VideoCategory(id: 'c105', name: '60帧', path: '/video?c=105'),
    VideoCategory(id: 'c111', name: '日本人', path: '/video?c=111'),
    VideoCategory(id: 'c115', name: '独家', path: '/video?c=115'),
    VideoCategory(id: 'c121', name: '音乐', path: '/video?c=121'),
    VideoCategory(id: 'c131', name: '舔屄', path: '/video?c=131'),
    VideoCategory(id: 'c138', name: '已认证素人', path: '/video?c=138'),
    VideoCategory(id: 'c139', name: '已认证模特', path: '/video?c=139'),
    VideoCategory(id: 'c141', name: '片场直击', path: '/video?c=141'),
    VideoCategory(id: 'c181', name: '老少欢', path: '/video?c=181'),
    VideoCategory(id: 'c201', name: '滑稽模仿', path: '/video?c=201'),
    VideoCategory(id: 'c211', name: '撒尿', path: '/video?c=211'),
    VideoCategory(id: 'c241', name: 'Cosplay', path: '/video?c=241'),
    VideoCategory(id: 'c242', name: '娇妻偷吃', path: '/video?c=242'),
    VideoCategory(id: 'c444', name: '继家庭幻想', path: '/video?c=444'),
    VideoCategory(id: 'c482', name: '已认证情侣', path: '/video?c=482'),
    VideoCategory(id: 'c492', name: '女性自慰', path: '/video?c=492'),
    VideoCategory(id: 'c502', name: '女性高潮', path: '/video?c=502'),
    VideoCategory(id: 'c512', name: '肌肉男', path: '/video?c=512'),
    VideoCategory(id: 'c522', name: '浪漫', path: '/video?c=522'),
    VideoCategory(id: 'c532', name: 'Scissoring', path: '/video?c=532'),
    VideoCategory(id: 'c542', name: '佩戴式阳具', path: '/video?c=542'),
    VideoCategory(id: 'c562', name: '纹身女', path: '/video?c=562'),
    VideoCategory(id: 'c572', name: 'Trans With Girl', path: '/video?c=572'),
    VideoCategory(id: 'c592', name: '指交', path: '/video?c=592'),
    VideoCategory(id: 'c612', name: '360°', path: '/video?c=612'),
    VideoCategory(id: 'c712', name: 'Uncensored A', path: '/video?c=712'),
    VideoCategory(id: 'c722', name: 'Uncensored B', path: '/video?c=722'),
    VideoCategory(id: 'c732', name: '内嵌字幕', path: '/video?c=732'),
    VideoCategory(id: 'c761', name: 'FFM', path: '/video?c=761'),
    VideoCategory(id: 'c881', name: '赌博', path: '/video?c=881'),
    VideoCategory(id: 'c891', name: '播客', path: '/video?c=891'),
  ];

  static List<VideoCategory> get all => <VideoCategory>[
    ...entryList,
    ...categoryList,
  ];
}

class PornHubSource implements VideoSource {
  PornHubSource({Dio? dio}) : _dio = dio ?? _createDio() {
    // HTML decoding must never consume binary streams or cast JSON as HTML.
    _mediaDio = Dio(_dio.options.copyWith())
      ..httpClientAdapter = _dio.httpClientAdapter;
  }

  static const String baseUrl = 'https://cn.pornhub.com';
  static const String requestFailureMessage = '网络请求失败，请检查网络后重试';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String playbackUserAgent =
      'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';
  static const String playbackFallbackUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _defaultCookie = 'age_verified=1; platform=pc';
  static const Set<String> _allowedPageHosts = <String>{
    'cn.pornhub.com',
    'www.pornhub.com',
  };
  static const int _maxCachedDetails = 64;

  @override
  String get id => 'pornhub';

  @override
  String get displayName => 'PornHub';

  static String _normalizeKey(String videoIdOrUrl) {
    final trimmed = videoIdOrUrl.trim();
    if (trimmed.isEmpty) return trimmed;
    final match = RegExp(r'[?&]viewkey=([^&#]+)').firstMatch(trimmed);
    if (match != null) {
      final vkey = match.group(1);
      if (vkey != null && vkey.isNotEmpty) {
        return Uri.tryParse(trimmed)?.path == '/view_clip.php'
            ? 'clip:$vkey'
            : vkey;
      }
    }
    return trimmed;
  }

  @override
  String? getCachedHlsUrl(String videoId) {
    final key = _normalizeKey(videoId);
    final detail = _detailCache[key] ?? _detailCache[videoId];
    if (detail == null) return null;
    if (_isExpiredUrl(detail.video.hlsUrl)) {
      _detailCache.remove(key);
      _detailCache.remove(videoId);
      _fallbackVariantCache.remove(key);
      _fallbackVariantCache.remove(videoId);
      return null;
    }
    return detail.video.hlsUrl;
  }

  @override
  List<VideoCategory> categoriesForChannel(ChannelType channel) {
    switch (channel) {
      case ChannelType.home:
        return PornHubCategories.entryList;
      case ChannelType.video:
        return PornHubCategories.categoryList;
      case ChannelType.kedou:
      case ChannelType.vod:
        // 该源没有对应官网分区，返回空列表让上层隐藏该 Tab。
        return const <VideoCategory>[];
    }
  }

  final Dio _dio;
  late final Dio _mediaDio;

  final Map<String, VideoDetail> _detailCache = <String, VideoDetail>{};
  final Map<String, List<VideoVariant>> _fallbackVariantCache =
      <String, List<VideoVariant>>{};
  final Map<String, Future<VideoDetail?>> _detailInFlight =
      <String, Future<VideoDetail?>>{};

  /// Playback-only CDN/quality alternatives. They stay out of the quality menu;
  /// the player uses them automatically after a source-level playback failure.
  List<VideoVariant> fallbackVariantsFor(String videoIdOrUrl) {
    final key = _normalizeKey(videoIdOrUrl);
    final exact =
        _fallbackVariantCache[key] ?? _fallbackVariantCache[videoIdOrUrl];
    if (exact != null) return _freshFallbackVariants(exact);
    for (final entry in _detailCache.entries) {
      if (entry.value.video.detailUrl == videoIdOrUrl ||
          _normalizeKey(entry.value.video.detailUrl ?? '') == key ||
          entry.value.video.id == key) {
        final variants =
            _fallbackVariantCache[entry.key] ??
            _fallbackVariantCache[key] ??
            const <VideoVariant>[];
        if (variants.isNotEmpty) {
          return _freshFallbackVariants(variants);
        }
      }
    }
    return const <VideoVariant>[];
  }

  static List<VideoVariant> _freshFallbackVariants(
    Iterable<VideoVariant> variants,
  ) => List<VideoVariant>.unmodifiable(
    variants.where((variant) => !_isExpiredUrl(variant.url)),
  );

  static bool _isAllowedPageUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    return uri != null &&
        uri.isAbsolute &&
        uri.scheme == 'https' &&
        _allowedPageHosts.contains(uri.host.toLowerCase()) &&
        uri.userInfo.isEmpty &&
        uri.port == 443;
  }

  /// Request URLs can contain search terms, video identifiers, or signed values.
  /// Keep only the origin and path in persistent diagnostics.
  static String _safeUrlLabel(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasAuthority) return '<invalid-url>';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  static String _safeVideoIdLabel(String videoId) {
    final uri = Uri.tryParse(videoId);
    if (uri != null && uri.hasAuthority) return _safeUrlLabel(videoId);
    return videoId.length <= 48 ? videoId : '${videoId.substring(0, 48)}…';
  }

  void _cacheDetail(
    String videoId,
    VideoDetail detail, {
    required List<VideoVariant> fallbackVariants,
  }) {
    final key = _normalizeKey(videoId);
    if (!_detailCache.containsKey(key) &&
        !_detailCache.containsKey(videoId) &&
        _detailCache.length >= _maxCachedDetails) {
      // Map literals preserve insertion order; evict the oldest parsed detail
      // so long browsing sessions cannot grow this cache without a bound.
      final oldest = _detailCache.keys.first;
      _detailCache.remove(oldest);
      _fallbackVariantCache.remove(oldest);
    }
    _detailCache[key] = detail;
    if (key != videoId) {
      _detailCache[videoId] = detail;
    }
    if (fallbackVariants.isEmpty) {
      _fallbackVariantCache.remove(key);
      _fallbackVariantCache.remove(videoId);
    } else {
      final unmodifiable = List<VideoVariant>.unmodifiable(fallbackVariants);
      _fallbackVariantCache[key] = unmodifiable;
      if (key != videoId) {
        _fallbackVariantCache[videoId] = unmodifiable;
      }
    }
  }

  // ------------------------------------------------------------------ 广告过滤

  /// 广告 / 推广容器的 class 关键字。
  ///
  /// 实测首页存在 `adsbytrafficjunky`(7) / `trafficjunky`(15) / `advertisement`(2)
  /// 等标记，但**全部是 script / iframe 形态**，不进入解析结果；该名单用于兜住
  /// 分类页与登录态下才会出现的推广卡片。
  static const List<String> _adClassMarkers = <String>[
    'adsbytrafficjunky',
    'trafficjunky',
    'adcontainer',
    'advertisement',
    'exoclick',
    'juicyads',
    'bannerad',
    'js-ad',
  ];

  /// 广告条目的 `data-entrycode`。留空即不按该维度过滤 —— 实测首页 65 张卡片的
  /// `data-entrycode` 全部是 `VidPg-premVid`，**它是全站通用埋点而非广告标记**，
  /// 若把它当广告会把整页内容清空。这是本文件里最容易踩的一个坑。
  static const Set<String> _adEntryCodes = <String>{};

  /// 该节点是否属于广告容器。
  ///
  /// 沿父链上溯：广告容器通常把内容整个包住，只看节点自身的 class 会漏。
  static bool _isAdNode(dom.Element node) {
    dom.Element? current = node;
    var depth = 0;
    while (current != null && depth < 6) {
      final cls = (current.className).toLowerCase();
      if (cls.isNotEmpty) {
        for (final marker in _adClassMarkers) {
          if (cls.contains(marker)) return true;
        }
      }
      final code = current.attributes['data-entrycode'];
      if (code != null && _adEntryCodes.contains(code)) return true;
      current = current.parent;
      depth++;
    }
    return false;
  }

  // ------------------------------------------------------------------ 解析辅助

  static String _text(dom.Element? node) =>
      node == null ? '' : node.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// `18:14` → 1094 秒。
  static Duration? _parseDuration(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length != 2 && parts.length != 3) return null;
    final nums = parts.map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return null;
    if (nums.length == 2) {
      return Duration(minutes: nums[0]!, seconds: nums[1]!);
    }
    return Duration(hours: nums[0]!, minutes: nums[1]!, seconds: nums[2]!);
  }

  /// `216K` / `1.2M` / `6.3萬` → 整数。
  static int _parseViews(String raw) {
    final text = raw.replaceAll(',', '').trim();
    if (text.isEmpty) return 0;
    final match = RegExp(r'([\d.]+)\s*([KkMmBb萬万億亿]?)').firstMatch(text);
    if (match == null) return 0;
    final value = double.tryParse(match.group(1)!) ?? 0;
    final unit = match.group(2) ?? '';
    final scale = switch (unit) {
      'K' || 'k' => 1000.0,
      'M' || 'm' => 1000000.0,
      'B' || 'b' => 1000000000.0,
      '萬' || '万' => 10000.0,
      '億' || '亿' => 100000000.0,
      _ => 1.0,
    };
    return (value * scale).round();
  }

  /// 把官网的相对时间（`3天前` / `2個月前` / `1年前`）折算成近似 ISO 日期。
  ///
  /// **这是近似值**：官网只给相对时间，无法还原真实日期。取近似而非留空，
  /// 是因为 `VideoItem.downloadBaseName` 用它做下载文件名前缀；留空会退化成
  /// `unknown_标题`，同标题多版本会互相覆盖。详情页若给出绝对日期则以其为准。
  static String? _parseRelativeDate(String raw) {
    if (raw.isEmpty) return null;
    final match = RegExp(r'(\d+)\s*(秒|分鐘|分钟|小時|小时|天|週|周|個月|个月|月|年)')
        .firstMatch(raw);
    if (match == null) return null;
    final amount = int.tryParse(match.group(1)!) ?? 0;
    final unit = match.group(2)!;
    final now = DateTime.now();
    final delta = switch (unit) {
      '秒' => Duration(seconds: amount),
      '分鐘' || '分钟' => Duration(minutes: amount),
      '小時' || '小时' => Duration(hours: amount),
      '天' => Duration(days: amount),
      '週' || '周' => Duration(days: amount * 7),
      '個月' || '个月' || '月' => Duration(days: amount * 30),
      _ => Duration(days: amount * 365),
    };
    final date = now.subtract(delta);

    // 合理性闸门：官网某些卡片的 `added` 是脏值（实测出现过「56年前」），
    // 换算后会落到 1970 年，比留空更糟 —— 播放页会显示成「1970-10-16」。
    // PornHub 2007 年才上线，早于 2005 一律判定为脏值，返回 null。
    if (date.year < 2005) return null;

    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// 卡片容器的标记串。
  static const String _cardMarker = 'pcVideoListItem';

  /// 切片条目的 id 前缀。
  ///
  /// 切片详情页是 `/view_clip.php`（普通视频是 `/view_video.php`），而整条链路
  /// （列表 → 播放 → 下载）只用一个字符串字段携带 id，所以在 id 上打前缀，
  /// 把「这是切片」这个事实带过详情解析那一层，避免为此改动公共模型。
  static const String _clipIdPrefix = 'clip:';

  /// 切片卡片的 class 标记（实测切片页内容区正是 36 个 `li.profileBoxClip`）。
  static const String _clipCardMarker = 'profileBoxClip';

  /// 解析一页里的全部视频卡片。
  ///
  /// 实测：首页 65 张卡片，`title/detailUrl/thumbnailUrl/durationStr/viewsStr/author`
  /// 六个字段完整率均为 65/65。
  ///
  /// **刻意不对整页做 `html_parser.parse`**。PornHub 的页面体量远大于 91
  /// （列表页约 3 MB、详情页约 4.7 MB，而 91 详情页仅约 86 KB），
  /// 整页 DOM 解析在纯 Dart 下会把主 isolate 占满 —— 真机表现为「一直解析中」
  /// 且进程 CPU 长期 100%。这里改成**按字符串切片定位每张卡片，只解析那一小块**
  /// （单块 2~4 KB），开销与页面总长无关。
  List<VideoItem> _parseCards(String html, {dom.Document? document}) {
    if (document != null) return _parseCardsFromDocument(document);
    return _parseCardsSliced(html);
  }

  static List<VideoItem> _parseCardsFromDocument(dom.Document doc) {
    final items = <VideoItem>[];
    final seen = <String>{};
    for (final li in doc.querySelectorAll(
      'li.pcVideoListItem, li.videoblock',
    )) {
      if (_isAdNode(li)) continue;
      final item = _parseCardFragmentElement(li);
      if (item != null && seen.add(item.id)) items.add(item);
    }
    return items;
  }

  /// 按字符串切片提取卡片，逐块解析。
  static List<VideoItem> _parseCardsSliced(String html) {
    // 先去掉页面顶部那个「最热门」下拉菜单（`#dropdownHeaderSubMenu`）。
    // 它里面也塞了 4~6 个 `li.pcVideoListItem`，而且**每个页面都有**。
    // 实测 /subscriptions：页面写着「显示 1-35 个」，DOM 里却有 39 个，
    // 多出来的正是这个菜单 —— 这就是「扒取不对」的根因。
    final cleaned = _stripHeaderMenus(html);
    // **再按容器 id 收口到主列表**（实测可靠：全量 51 个创作者逐个核对过）。
    // 列表页主列表的 id 只有三种：
    //   model 页 `mostRecentVideosSection` · pornstar 页 `moreData` · 用户页 `userVideosSection`
    // 不收口的话，某些页面（实测 /pornstar/jay-bank/videos）主列表 40 条、
    // 全页 49 条，会把主列表外的 5 条一起收进来。
    // 找不到这些 id 时原样返回（例如详情页的 相关/推荐 用的是别的容器，不受影响）。
    final scoped = _scopeToMainList(cleaned);
    final items = <VideoItem>[];
    final seen = <String>{};
    var searchFrom = 0;
    final marker = scoped.contains(_cardMarker)
        ? _cardMarker
        : 'data-video-vkey=';

    // 单次页面卡片数上限，避免异常页面把循环拖成事实上的死循环。
    while (items.length < 200) {
      // Mobile watch pages identify recommendation cards by their video key.
      // Desktop list pages retain the existing marker and scoping rules.
      final markerAt = scoped.indexOf(marker, searchFrom);
      if (markerAt < 0) break;
      final open = scoped.lastIndexOf('<li', markerAt);
      if (open < 0 || open > markerAt) break;

      // 找配对的 </li>。PH 的卡片内部不嵌套 li，这里仍用计数器兜底。
      var depth = 1;
      var pos = open + 3;
      var end = -1;
      while (pos < scoped.length) {
        final nextOpen = scoped.indexOf('<li', pos);
        final nextClose = scoped.indexOf('</li>', pos);
        if (nextClose < 0) break;
        if (nextOpen >= 0 && nextOpen < nextClose) {
          depth++;
          pos = nextOpen + 3;
        } else {
          depth--;
          pos = nextClose + 5;
          if (depth <= 0) {
            end = pos;
            break;
          }
        }
      }
      if (end <= open) break;
      // 保证游标前进：正常情况下 end（卡片 </li> 之后）必然越过 marker；
      // 万一 marker 落在某个非卡片的 <li> 里、导致 end 停在 marker 之前，
      // 下一次必须从 marker 之后继续，否则会反复命中同一个 marker 而死循环。
      searchFrom = end > markerAt ? end : markerAt + marker.length;

      final item = _parseCardFragment(scoped.substring(open, end));
      if (item != null && seen.add(item.id)) items.add(item);
    }
    return items;
  }

  /// 列表页「主列表」容器的 id（实测，全量 51 个创作者逐个核对过）。
  static const List<String> _mainListIds = <String>[
    'mostRecentVideosSection',
    'moreData',
    'userVideosSection',
  ];

  /// 把 HTML 收口到主列表那个 `<ul id="…">` 内。
  ///
  /// ⚠️ **必须按 id 找、且用 `<ul>` 深度配平找配对的 `</ul>`**：
  /// 按 class（`full-row-thumbs`）找会命中页面里更早出现的别的东西，
  /// 用「第一个 `</ul>`」截断又会被容器内的嵌套 `<ul>` 提前截断 —— 两者实测都会把列表切成 0 条。
  /// 找不到时原样返回，保持既有行为。
  static String _scopeToMainList(String html) {
    for (final id in _mainListIds) {
      final marker = 'id="$id"';
      final at = html.indexOf(marker);
      if (at < 0) continue;
      final open = html.lastIndexOf('<ul', at);
      if (open < 0) continue;

      var depth = 1;
      var i = open + 3;
      while (i < html.length) {
        final o = html.indexOf('<ul', i);
        final c = html.indexOf('</ul>', i);
        if (c < 0) break;
        if (o >= 0 && o < c) {
          depth++;
          i = o + 3;
        } else {
          depth--;
          i = c + 5;
          if (depth <= 0) return html.substring(open, c);
        }
      }
    }
    return html;
  }

  /// 去掉页面顶部的「最热门」下拉菜单（`<div id="dropdownHeaderSubMenu">`）。
  ///
  /// 用 div 深度配平定位该块的结束，然后把整块从 HTML 里挖掉。
  static String _stripHeaderMenus(String html) {
    const marker = 'id="dropdownHeaderSubMenu"';
    final at = html.indexOf(marker);
    if (at < 0) return html;
    final tagStart = html.lastIndexOf('<', at);
    if (tagStart < 0) return html;

    var depth = 0;
    var i = tagStart;
    while (i < html.length) {
      final open = html.indexOf('<div', i);
      final close = html.indexOf('</div>', i);
      if (close < 0) break;
      if (open >= 0 && open < close) {
        depth++;
        i = open + 4;
      } else {
        depth--;
        i = close + 6;
        if (depth <= 0) {
          return html.substring(0, tagStart) + html.substring(i);
        }
      }
    }
    return html;
  }

  /// 解析单个 `<li>` 片段（2~4 KB），不做整页解析。
  static VideoItem? _parseCardFragment(String block) {
    final doc = html_parser.parseFragment(block);
    final li = doc.querySelector('li');
    return li == null ? null : _parseCardFragmentElement(li);
  }

  static VideoItem? _parseCardFragmentElement(dom.Element li) {
    if (_isAdNode(li)) return null;
    if (li.querySelector('a[href*="view_clip.php"]') != null) {
      return _parseClipFragmentElement(li);
    }
    final vkey = li.attributes['data-video-vkey'] ?? '';
    if (vkey.isEmpty) return null;
    final link =
        li.querySelector('a.thumbnailTitle') ??
        li.querySelector('a[href*="view_video.php?viewkey="]');
    if (link == null) return null;

    final img = li.querySelector('img[data-image]') ?? li.querySelector('img');
    final thumb = img?.attributes['data-image'] ?? img?.attributes['src'] ?? '';

    final durationStr = _text(
      li.querySelector('var.duration, .duration .time'),
    );
    final viewsStr = _text(li.querySelector('.views var, .videoViews'));
    final userEl = li.querySelector('.usernameWrap a, .uploaderLink');
    final addedStr = _text(li.querySelector('var.added'));

    final rawTitle = link.attributes['title'] ?? '';
    final title = rawTitle.trim().isNotEmpty ? rawTitle.trim() : _text(link);

    final href = link.attributes['href'] ?? '';
    final detailUrl = href.startsWith('http') ? href : '$baseUrl$href';

    return VideoItem(
      id: vkey,
      title: title,
      author: _text(userEl).isEmpty ? 'unknown' : _text(userEl),
      // 列表页拿不到播放地址：官网把 mediaDefinitions 放在详情页。
      hlsUrl: '',
      detailUrl: detailUrl,
      thumbnailUrl: thumb.isEmpty ? null : thumb,
      duration: _parseDuration(durationStr),
      durationStr: durationStr.isEmpty ? null : durationStr,
      publishedAt: _parseRelativeDate(addedStr),
      views: _parseViews(viewsStr),
      viewsStr: viewsStr.isEmpty ? null : viewsStr,
    );
  }

  /// 从 `flashvars_<id>` 里取出 `mediaDefinitions` 数组。
  ///
  /// 用括号配平而不是正则：该数组里嵌着带 `{` `}` 的 URL 与转义引号，
  /// 非贪婪正则会截断，贪婪正则会吞掉后面的脚本。配平是唯一稳妥的做法。
  static List<Map<String, dynamic>> _extractMediaDefinitions(String html) {
    final keyIndex =
        RegExp(r'"mediaDefinitions"\s*:').firstMatch(html)?.start ?? -1;
    if (keyIndex < 0) return const <Map<String, dynamic>>[];
    final start = html.indexOf('[', keyIndex);
    if (start < 0) return const <Map<String, dynamic>>[];

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < html.length; i++) {
      final ch = html[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ']' || ch == '}') {
        depth--;
        if (depth == 0) {
          try {
            final decoded = jsonDecode(html.substring(start, i + 1));
            if (decoded is List) {
              return decoded
                  .whereType<Map<dynamic, dynamic>>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(growable: false);
            }
          } catch (e) {
            AppLogger.w('PornHub', 'mediaDefinitions 解析失败: $e');
          }
          return const <Map<String, dynamic>>[];
        }
      }
    }
    return const <Map<String, dynamic>>[];
  }

  /// 把 `quality` 字段解析成清晰度数值；无法解析返回 0（排序时排最后）。
  ///
  /// 实测该字段有三种形态，必须都覆盖：
  ///   - `"1080"`：字符串（HLS 条目主要形态）
  ///   - `1080`：数值
  ///   - 数组：自适应清晰度取最大值；空数组返回 0。
  static int _qualityRank(dynamic quality) {
    if (quality is int) return quality;
    if (quality is String) {
      final value = quality.trim().toLowerCase();
      if (value == '4k' || value == 'uhd') return 2160;
      if (value == '8k') return 4320;
      return int.tryParse(value.replaceFirst(RegExp(r'p$'), '')) ?? 0;
    }
    if (quality is List) {
      return quality.map(_qualityRank).fold(0, (a, b) => a > b ? a : b);
    }
    return 0;
  }

  /// 该 URL 是否为广告域。仅用于日志与请求侧兜底，解析层已先行过滤。
  static bool _isAdHost(String url) {
    const blocked = <String>[
      'trafficjunky',
      'exoclick',
      'juicyads',
      'bluetrafficstream',
      'doubleclick',
      'googlesyndication',
    ];
    final lower = url.toLowerCase();
    return blocked.any(lower.contains);
  }

  /// 播放地址自带的过期时间是否已过。
  ///
  /// PornHub 两套签名各有一个过期参数：`ev-h` 用 `validto`、`hv-h` 用 `e`。
  /// 只在参数值**看起来像 unix 时间戳**（>1e9）时才据此判定，
  /// 避免把同名的普通参数误判成过期；识别不出就返回 false（宁可当它有效）。
  static bool _isExpiredUrl(String url) {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int? earliestExpiry;
    for (final key in const <String>[
      'validto',
      'e',
      'expires',
      'expire',
      'ttl',
    ]) {
      final raw = uri.queryParameters[key];
      if (raw == null) continue;
      final parsed = int.tryParse(raw);
      if (parsed == null) continue;
      final seconds = parsed > 100000000000 ? parsed ~/ 1000 : parsed;
      if (seconds <= 1000000000) continue;
      if (earliestExpiry == null || seconds < earliestExpiry) {
        earliestExpiry = seconds;
      }
    }
    final embeddedExpiry = RegExp(r'(?:^|~)exp=(\d+)')
        .firstMatch(uri.queryParameters['hdnea'] ?? '');
    final signedExpiry = int.tryParse(embeddedExpiry?.group(1) ?? '');
    if (signedExpiry != null &&
        signedExpiry > 1000000000 &&
        (earliestExpiry == null || signedExpiry < earliestExpiry)) {
      earliestExpiry = signedExpiry;
    }
    return earliestExpiry != null && earliestExpiry <= nowSec + 5;
  }

  /// 同一清晰度在两套 CDN 上都有时的优先级（越小越优先）。
  ///
  /// 实测：`ev-h.phncdn.com` 在本机（手机 + 代理）能正常播放；
  /// `hv-h.phncdn.com` 会返回 **410 Gone**（ExoPlayer 报 Source error）。
  /// 所以同档位优先取 `ev-h`。
  static int _hostPreference(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.contains('ev-h.')) return 0;
    if (host.contains('hv-h.')) return 1;
    return 2;
  }

  // ------------------------------------------------------------------ 请求

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: <String, String>{
          'User-Agent': defaultUserAgent,
          'Referer': '$baseUrl/',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    // 详情页 HTML 达 4.3 MB，UTF-8 解码若留在主 isolate 会直接顶满 ANR 门槛
    // （该结论来自本项目此前的真机取证，见 background_decode_transformer.dart）。
    dio.transformer = BackgroundDecodeTransformer();
    return dio;
  }

  String _accountStamp = '';
  int _accountEpoch = 0;
  String get _currentAccountStamp {
    if (!Get.isRegistered<PornHubAuthService>()) return '';
    final auth = PornHubAuthService.to;
    return '${auth.sessionRevision.value}:${auth.isLoggedIn.value}:${auth.userName}';
  }

  void clearAccountCaches() {
    _accountEpoch++;
    _accountStamp = _currentAccountStamp;
    _extraCache.clear();
    _extraInFlight.clear();
    _playlistDetails.clear();
    _playlistPageCounts.clear();
  }

  void _ensureAccountSession() {
    if (_accountStamp != _currentAccountStamp) clearAccountCaches();
  }

  Map<String, String> _buildHeaders({
    bool anonymous = false,
    bool playback = false,
    String? playbackAgent,
  }) {
    final headers = <String, String>{
      'User-Agent': playback
          ? (playbackAgent ?? playbackUserAgent)
          : defaultUserAgent,
      'Referer': '$baseUrl/',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    if (playback) headers['Cache-Control'] = 'no-cache';
    if (anonymous) {
      headers['Cookie'] = playback
          ? 'age_verified=1; platform=mobile'
          : _defaultCookie;
      return headers;
    }
    try {
      final userCookie = PornHubAuthService.to.cookieHeader;
      if (userCookie.isNotEmpty) {
        final mergedCookies = <String, String>{
          'age_verified': '1',
          'platform': playback ? 'mobile' : 'pc',
        };
        for (final part in userCookie.split(';')) {
          final kv = part.trim().split('=');
          if (kv.length >= 2) {
            mergedCookies[kv[0].trim()] = kv.sublist(1).join('=').trim();
          }
        }
        if (playback) mergedCookies['platform'] = 'mobile';
        headers['Cookie'] = mergedCookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
      } else {
        headers['Cookie'] = playback
            ? 'age_verified=1; platform=mobile'
            : _defaultCookie;
      }
    } catch (e) {
      headers['Cookie'] = playback
          ? 'age_verified=1; platform=mobile'
          : _defaultCookie;
      // 失败会让后续请求静默退回未登录态（用户侧表现为「明明登录了却是游客视角」），
      // 必须留痕。控制流不变。
      AppLogger.w('PornHub', '读取认证 Cookie 失败，本次请求以未登录态发出: $e');
    }
    return headers;
  }

  Future<String?> _getHtml(
    String url, {
    CancelToken? cancelToken,
    bool playback = false,
    bool anonymous = false,
    bool allowEmpty = false,
    String? playbackAgent,
  }) async {
    _ensureAccountSession();
    final account = _currentAccountStamp;
    final headers = _buildHeaders(
      anonymous: anonymous,
      playback: playback,
      playbackAgent: playbackAgent,
    );
    final safeLabel = _safeUrlLabel(url);
    if (!_isAllowedPageUrl(url)) {
      AppLogger.w('PornHub', '拒绝非 HTTPS 或非本站页面请求: $safeLabel');
      return null;
    }
    final sw = Stopwatch()..start();
    AppLogger.i('PornHub', 'GET 开始: $safeLabel');
    try {
      var requestUrl = url;
      for (var redirect = 0; redirect <= 3; redirect++) {
        // Disable automatic redirects so session cookies are only sent to
        // explicitly approved PornHub hosts.
        final resp = await _dio.get<String>(
          requestUrl,
          options: Options(headers: headers, followRedirects: false),
          cancelToken: cancelToken,
        );
        if (!anonymous && account != _currentAccountStamp) return null;
        final status = resp.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          final location = resp.headers.value('location');
          if (location == null || redirect == 3) return null;
          requestUrl = Uri.parse(requestUrl).resolve(location).toString();
          if (!_isAllowedPageUrl(requestUrl)) {
            AppLogger.w('PornHub', '拒绝跳转到非本站地址: ${_safeUrlLabel(requestUrl)}');
            return null;
          }
          continue;
        }

        final data = resp.data;
        AppLogger.i(
          'PornHub',
          'GET 完成: HTTP $status bytes=${data?.length} '
              '耗时=${sw.elapsedMilliseconds}ms',
        );
        // **必须按状态码判失败**：Dio 放行了 404，否则错误页里的推荐卡片
        // 会被误解析进列表。
        if (status >= 400) {
          AppLogger.w('PornHub', 'HTTP $status，按失败处理: $safeLabel');
          return null;
        }
        if (data == null || (data.isEmpty && !allowEmpty)) return null;
        return data;
      }
      return null;
    } on DioException catch (e, stack) {
      if (CancelToken.isCancel(e)) return null;
      AppLogger.e(
        'PornHub',
        'GET 失败(耗时=${sw.elapsedMilliseconds}ms) $safeLabel (${e.type.name})',
        null,
        stack,
      );
      return null;
    } catch (e, stack) {
      AppLogger.e(
        'PornHub',
        'GET 失败(耗时=${sw.elapsedMilliseconds}ms) $safeLabel (${e.runtimeType})',
        null,
        stack,
      );
      return null;
    }
  }

  static VideoPage _failedPage(int page) => VideoPage(
    items: const <VideoItem>[],
    page: page,
    hasMore: true,
    totalPages: page,
    summary: requestFailureMessage,
  );

  String _pageUrl(String path, int page) {
    final uri = Uri.parse('$baseUrl$path');
    final query = Map<String, String>.from(uri.queryParameters);
    if (page > 1) query['page'] = '$page';
    return uri
        .replace(queryParameters: query.isEmpty ? null : query)
        .toString();
  }

  // ------------------------------------------------------------------ VideoSource

  @override
  Future<List<String>> fetchTags() async =>
      PornHubCategories.categoryList.map((c) => c.name).toList(growable: false);

  @override
  Future<List<String>> fetchHotKeywords() async {
    // 官网热搜位未提供稳定的结构化入口；退回分类名作为搜索建议，
    // 比返回空列表对用户更有用，且不需要额外请求。
    return fetchTags();
  }

  @override
  Future<VideoPage> fetchPage({required int page, int pageSize = 12}) async {
    final html = await _getHtml(_pageUrl('/video', page));
    if (html == null) return _failedPage(page);
    final items = _parseCards(html);
    return VideoPage(
      items: items,
      page: page,
      hasMore: items.isNotEmpty,
      totalPages: page + 1,
      totalItems: items.length,
    );
  }

  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async {
    final path = categoryPath ?? '/video';
    final html = await _getHtml(_pageUrl(path, page));
    if (html == null) return _failedPage(page);
    final items = _parseCards(html);
    return VideoPage(
      items: items,
      page: page,
      hasMore: items.isNotEmpty,
      totalPages: page + 1,
      totalItems: items.length,
    );
  }

  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) async {
    final keyword = query.keyword.trim();
    if (keyword.isEmpty && query.category.isEmpty) {
      return const VideoPage.empty();
    }

    // 搜索排序走**官网自己的参数**（实测自搜索页真实链接），与 91 无关：
    //   最相关（无 o） / o=mr 最新 / o=mv 最多次观看 / o=tr 最高分 / o=lg 最长
    final queryParams = <String, String>{
      'search': keyword,
      if (query.sortParam.isNotEmpty) 'o': query.sortParam,
    };
    final path = '/video/search?${Uri(queryParameters: queryParams).query}';

    final html = await _getHtml(_pageUrl(path, page));
    if (html == null) return _failedPage(page);
    final items = _parseCardsSliced(html);
    return VideoPage(
      items: items,
      page: page,
      hasMore: items.isNotEmpty,
      totalPages: page + 1,
      totalItems: items.length,
      summary: items.isEmpty ? '未找到与「$keyword」相关的视频' : null,
    );
  }

  /// 官网搜索排序项（实测）。供搜索页渲染排序芯片。
  static const List<VideoCategory> searchSorts = <VideoCategory>[
    VideoCategory(id: 'relevance', name: '最相关', path: ''),
    VideoCategory(id: 'o=mr', name: '最新', path: 'mr'),
    VideoCategory(id: 'o=mv', name: '最多次观看', path: 'mv'),
    VideoCategory(id: 'o=tr', name: '最高分', path: 'tr'),
    VideoCategory(id: 'o=lg', name: '最长', path: 'lg'),
  ];

  /// 单次详情解析尝试的硬上限。
  ///
  /// 真机实测出现过「详情请求永久 pending」：播放页一直停在「正在解析播放地址…」，
  /// 主 isolate 并不忙（排除死循环），dio 的 receiveTimeout 也不触发 ——
  /// 根因是 **dio 的 receiveTimeout 只覆盖「等响应头」，不覆盖读 body**
  /// （见 `dio/lib/src/adapters/io_adapter.dart`）。代理 / CDN 中途停住时，
  /// 读 body 会 await 到永远。这里给每次尝试加硬上限，并**换一条连接重试一次**：
  /// 偶发的中途停住因此可以自愈，而不是把播放页永远卡死。
  static const Duration _detailAttemptTimeout = Duration(seconds: 12);

  /// Refresh a rejected CDN route before passing it to the native player.
  static const int _detailAttempts = 3;

  /// Called only when the player is explicitly opened. Background resolution is anonymous.
  Future<void> markWatched(String videoId) async {
    if (!isLoggedIn) return;
    _extraCache.remove(_normalizeKey(videoId));
    _extraCache.remove(videoId);
    await fetchDetailExtra(videoId, forceRefresh: true);
  }

  @override
  Future<VideoDetail?> fetchDetail(
    String videoId, {
    bool forceRefresh = false,
  }) {
    final key = _normalizeKey(videoId);
    AppLogger.i(
      'PornHub',
      'fetchDetail 进入: ${_safeVideoIdLabel(videoId)} '
          '(key=$key, forceRefresh=$forceRefresh)',
    );
    if (!forceRefresh) {
      final cached = _detailCache[key] ?? _detailCache[videoId];
      if (cached != null) {
        // **缓存里的 hlsUrl 可能已经过期**：PornHub 的 `hv-h` 那套签名
        // （`?h=..&e=<过期时间>&f=1`）有效期很短，而详情缓存是 15 分钟。
        // 一旦拿过期地址去播放，CDN 返回 **410 Gone** → ExoPlayer `Source error`
        // → 界面「播放失败」。所以过期的缓存详情一律当未命中，重新抓详情页。
        if (!_isExpiredUrl(cached.video.hlsUrl)) {
          return Future<VideoDetail?>.value(cached);
        }
        _detailCache.remove(key);
        _detailCache.remove(videoId);
        _fallbackVariantCache.remove(key);
        _fallbackVariantCache.remove(videoId);
        AppLogger.i('PornHub', '缓存详情的播放地址已过期，重新解析: $videoId');
      }
    }
    final inFlight = _detailInFlight[key] ?? _detailInFlight[videoId];
    if (inFlight != null) return inFlight;
    // 注意：`whenComplete` 的回调类型是 `FutureOr<void>`。**如果回调返回一个 Future，
    // whenComplete 会等它完成再完成自己**。而 `Map.remove` 会返回「被移除的值」——
    // 也就是这里正在构造的这个 future 本身，于是它等自己 → 死锁：
    // `fetchDetail` 永不返回，播放页永远停在「正在解析播放地址…」，
    // 且任何超时都不会触发（.timeout 在 whenComplete 之前，已经正常完成了）。
    // 因此回调**必须**用块体返回 void，不能写成 `() => _detailInFlight.remove(...)`。
    final future = _resolveDetailWithRetry(videoId).whenComplete(() {
      _detailInFlight.remove(key);
      _detailInFlight.remove(videoId);
    });
    _detailInFlight[key] = future;
    if (key != videoId) {
      _detailInFlight[videoId] = future;
    }
    return future;
  }

  /// 带重试的详情解析：每次尝试都有硬上限，超时即换连接重试。
  Future<VideoDetail?> _resolveDetailWithRetry(String videoId) async {
    for (var attempt = 0; attempt < _detailAttempts; attempt++) {
      final cancelToken = CancelToken();
      try {
        final detail = await _fetchDetailInternal(
          videoId,
          cancelToken: cancelToken,
          playbackAgent: attempt == 1
              ? playbackFallbackUserAgent
              : playbackUserAgent,
        ).timeout(_detailAttemptTimeout);
        if (detail != null) return detail;
      } on TimeoutException {
        // Future.timeout only stops awaiting; it does not abort Dio's socket/body
        // read. Cancel the request before retrying to avoid orphaned downloads.
        cancelToken.cancel('PornHub detail request timed out');
        AppLogger.w(
          'PornHub',
          '详情解析超时（第 ${attempt + 1}/$_detailAttempts 次，'
              '${_detailAttemptTimeout.inSeconds}s）: '
              '${_safeVideoIdLabel(videoId)}',
        );
      }
    }
    return null;
  }

  Future<VideoDetail?> _fetchDetailInternal(
    String videoId, {
    CancelToken? cancelToken,
    String? playbackAgent,
  }) async {
    // 列表页传进来的是 viewkey；也兼容直接传详情页 URL 的调用方。
    // 切片条目带 `clip:` 前缀：详情页是 /view_clip.php，而不是普通视频的
    // /view_video.php。普通视频不带前缀，仍走原路径，行为逐位不变。
    videoId = _normalizeKey(videoId);
    final isClip = videoId.startsWith(_clipIdPrefix);
    final rawId = isClip ? videoId.substring(_clipIdPrefix.length) : videoId;
    final parsed = Uri.tryParse(rawId);
    final url = parsed != null && parsed.hasAuthority
        ? (_isAllowedPageUrl(rawId) ? rawId : null)
        : '$baseUrl/${isClip ? 'view_clip.php' : 'view_video.php'}'
              '?viewkey=${Uri.encodeQueryComponent(rawId)}';
    if (url == null) {
      AppLogger.w('PornHub', '拒绝非本站视频详情地址: ${_safeVideoIdLabel(videoId)}');
      return null;
    }
    // The desktop hv-h route can return 410 even with a fresh signature.
    // Mobile watch pages supply em-h/ev-h routes that work with native playback.
    final html = await _getHtml(
      url,
      cancelToken: cancelToken,
      playback: true,
      anonymous: true,
      playbackAgent: playbackAgent,
    );
    if (html == null) return null;

    // 详情页约 4.7 MB。**不整页 parse**，标题/缩略图/上传者一律走字符串定位，
    // 相关推荐走切片解析（见 [_parseCardsSliced]）。
    final title = _metaContent(html, 'og:title') ?? _pageTitle(html) ?? '';
    final thumbnail = _metaContent(html, 'og:image');
    final author = _extractUploader(html);

    final defs = await _resolveMediaDefinitions(
      _extractMediaDefinitions(html),
      cancelToken: cancelToken,
      playbackAgent: playbackAgent,
    );

    // 先解析出「清晰度数值 + 地址」，再按数值从高到低排序后取首条。
    //
    // 不能用官网的 `defaultQuality`：实测它是 720p，而用户要的是**最高清晰度**
    // （1080p）。也不能依赖 `mediaDefinitions` 的数组顺序 —— 实测顺序是
    // 1080 / 240 / 480 / 720，杂乱，不能当作清晰度序。
    final byRank = <int, List<String>>{};
    for (final def in defs) {
      if (def['format'] != 'hls' && def['format'] != 'mp4') continue;
      final raw = (def['videoUrl'] as String?)?.replaceAll(r'\/', '/') ?? '';
      if (raw.isEmpty || _isAdHost(raw) || _isExpiredUrl(raw)) continue;
      final mediaUri = Uri.tryParse(raw);
      if (mediaUri == null ||
          mediaUri.scheme != 'https' ||
          !(mediaUri.host.endsWith('.phncdn.com') ||
              (isClip && mediaUri.host == 'mux.pornhub.com')) ||
          mediaUri.userInfo.isNotEmpty) {
        continue;
      }
      final height = _qualityRank(def['height']);
      final quality = _qualityRank(def['quality']);
      final width = _qualityRank(def['width']);
      final rank = quality > 0
          ? quality
          : (width > 0 && height > 0
                ? (width < height ? width : height)
                : height);
      final urls = byRank.putIfAbsent(rank, () => <String>[]);
      if (!urls.contains(raw)) urls.add(raw);
    }
    if (byRank.isEmpty) {
      AppLogger.w('PornHub', '详情页未提取到可用媒体变体: $videoId');
      return null;
    }
    final ranked = byRank.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    for (final entry in ranked) {
      entry.value.sort(
        (a, b) => _hostPreference(a).compareTo(_hostPreference(b)),
      );
    }
    final allRanked = <({int rank, String url})>[];
    final seenUrls = <String>{};
    for (final entry in ranked) {
      for (final url in entry.value) {
        if (seenUrls.add(url)) allRanked.add((rank: entry.key, url: url));
      }
    }
    // 诊断：确认解析确实走到了这里（PornHub 卡死排查用）。
    AppLogger.i(
      'PornHub',
      '详情解析完成: html=${html.length}B defs=${defs.length} '
          'variants=${ranked.map((e) => e.key).toList()} 最高=${ranked.first.key}p',
    );

    // 清晰度从高到低：起播用最高档，播放页的清晰度切换菜单也按此顺序展示。
    final variants = ranked
        .map(
          (e) => VideoVariant(
            label: e.key > 0 ? '${e.key}p' : '自动',
            url: e.value.first,
          ),
        )
        .toList(growable: false);
    final fallbackVariants = allRanked
        .skip(1)
        .map((entry) {
          final label = entry.rank > 0 ? '${entry.rank}p备用' : '自动备用';
          return VideoVariant(label: label, url: entry.url);
        })
        .toList(growable: false);
    final preferred = variants.first;
    if (!await _isPlayablePlaylist(preferred.url, cancelToken: cancelToken)) {
      // A 410 on one quality also affects the other qualities on that CDN.
      // Fetch a new signed route instead of waiting for four native failures.
      return null;
    }

    // 相关推荐：详情页里的同构卡片，排除当前视频自身。
    //
    // 上限 24 条：原始页面有 77 条，全量进入会让上层预加载去逐个解析详情页
    // （每条约 4.7 MB），真机上表现为 CPU 长期 100%。列表展示 24 条足够。
    final normId = _normalizeKey(videoId);
    final related = _parseCardsSliced(html)
        .where((item) => item.id != normId && item.id != videoId)
        .take(24)
        .toList(growable: false);
    AppLogger.i('PornHub', '相关推荐解析完成: ${related.length} 条（即将返回 detail）');

    final detail = VideoDetail(
      video: VideoItem(
        id: normId,
        title: title,
        author: author,
        hlsUrl: preferred.url,
        detailUrl: url,
        thumbnailUrl: thumbnail,
        tags: const <String>[],
      ),
      variants: variants,
      relatedVideos: related,
    );
    _cacheDetail(videoId, detail, fallbackVariants: fallbackVariants);
    return detail;
  }

  Future<List<Map<String, dynamic>>> _resolveMediaDefinitions(
    List<Map<String, dynamic>> definitions, {
    CancelToken? cancelToken,
    String? playbackAgent,
  }) async {
    final result = <Map<String, dynamic>>[];
    final endpoints = <String>{};
    for (final definition in definitions) {
      final raw = definition['videoUrl'];
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri?.path != '/video/get_media') {
        result.add(definition);
        continue;
      }
      if (!_isAllowedPageUrl(raw as String) || !endpoints.add(raw)) continue;
      final token = CancelToken();
      try {
        final response = await _mediaDio
            .get<String>(
              raw,
              options: Options(
                responseType: ResponseType.plain,
                followRedirects: false,
                headers: _buildHeaders(
                  anonymous: true,
                  playback: true,
                  playbackAgent: playbackAgent,
                ),
              ),
              cancelToken: token,
            )
            .timeout(const Duration(seconds: 3));
        final decoded = jsonDecode(response.data ?? '[]');
        if (decoded is List) {
          for (final entry in decoded.whereType<Map>()) {
            result.add({
              ...Map<String, dynamic>.from(entry),
              'format': entry['format'] ?? 'mp4',
            });
          }
        }
        AppLogger.i('PornHub', 'MP4 清晰度接口解析完成');
      } catch (_) {
        AppLogger.w('PornHub', 'MP4 清晰度接口不可用，保留页面提供的媒体线路');
      } finally {
        token.cancel('Media definition request finished');
      }
      if (cancelToken?.isCancelled ?? false) return result;
    }
    return result;
  }

  Future<bool> _isPlayablePlaylist(
    String url, {
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host.endsWith('.phncdn.com') || uri.host == 'mux.pornhub.com') ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.path.toLowerCase().endsWith('.mp4')) {
      final token = CancelToken();
      try {
        final response = await _mediaDio
            .get<ResponseBody>(
              url,
              options: Options(
                responseType: ResponseType.stream,
                followRedirects: false,
                headers: {
                  'User-Agent': defaultUserAgent,
                  'Referer': '$baseUrl/',
                  'Range': 'bytes=0-1023',
                },
                validateStatus: (status) => status == 200 || status == 206,
              ),
              cancelToken: token,
            )
            .timeout(const Duration(seconds: 4));
        final first = await response.data!.stream.first.timeout(
          const Duration(seconds: 4),
        );
        return first.length >= 8 &&
            ascii.decode(first.sublist(4, 8), allowInvalid: true) == 'ftyp';
      } catch (_) {
        AppLogger.w('PornHub', 'MP4 媒体检查失败，重新获取详情: ${uri.host}');
        return false;
      } finally {
        token.cancel('MP4 header check finished');
      }
    }
    try {
      final response = await _mediaDio
          .get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
              headers: {
                'User-Agent': defaultUserAgent,
                'Referer': '$baseUrl/',
                'Cookie': _defaultCookie,
              },
            ),
            cancelToken: cancelToken,
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200 &&
          (response.data ?? '').trimLeft().startsWith('#EXTM3U')) {
        return true;
      }
      AppLogger.w(
        'PornHub',
        '播放清单不可用，重新获取详情: ${uri.host} HTTP ${response.statusCode}',
      );
    } on TimeoutException {
      cancelToken?.cancel('PornHub playlist validation timed out');
      AppLogger.w('PornHub', '播放清单检查超时，重新获取详情: ${uri.host}');
    } catch (error) {
      AppLogger.w('PornHub', '播放清单检查失败，重新获取详情: ${uri.host}');
    }
    return false;
  }

  /// 取 `<meta property="X" content="Y">` 的 content。属性顺序两种都试。
  static String? _metaContent(String html, String property) {
    final forward = RegExp(
      '<meta[^>]*property="${RegExp.escape(property)}"[^>]*content="([^"]*)"',
    ).firstMatch(html);
    if (forward != null) return _unescapeMeta(forward.group(1)!);
    final reversed = RegExp(
      '<meta[^>]*content="([^"]*)"[^>]*property="${RegExp.escape(property)}"',
    ).firstMatch(html);
    return reversed == null ? null : _unescapeMeta(reversed.group(1)!);
  }

  /// 页面 `<title>` 去掉尾部站点名。
  static String? _pageTitle(String html) {
    final m = RegExp(r'<title>([^<]*)</title>').firstMatch(html);
    if (m == null) return null;
    final raw = _unescapeMeta(m.group(1)!);
    return raw.replaceAll(RegExp(r'\s*[|\-–]\s*Pornhub\s*$'), '').trim();
  }

  /// 反转义常见的 HTML 实体；`&amp;` 最后处理，避免二次反转义。
  static String _unescapeMeta(String raw) => raw
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  /// 取详情页上传者。
  ///
  /// 优先级取自实测：页面 JS 里的 `"username":"auntjudy"` 最准
  /// （`userInfoBlock` 也可能指向同一个值，作为回退）。
  static String _extractUploader(String html) {
    final fromJson = RegExp(r'"username"\s*:\s*"([^"]{1,60})"')
        .firstMatch(html);
    if (fromJson != null && fromJson.group(1)!.trim().isNotEmpty) {
      return fromJson.group(1)!.trim();
    }
    final fromBlock = RegExp(
      r'userInfoBlock[\s\S]{0,1200}?/users/([A-Za-z0-9_.]{2,60})',
    ).firstMatch(html);
    if (fromBlock != null) return fromBlock.group(1)!;
    final anyUser = RegExp(r'/users/([A-Za-z0-9_.]{2,60})').firstMatch(html);
    return anyUser?.group(1) ?? 'PornHub';
  }

  /// 供「我的」页展示登录态。
  bool get isLoggedIn {
    try {
      return PornHubAuthService.to.isLoggedIn.value;
    } catch (_) {
      return false;
    }
  }

  // ==================================================================== 用户区
  //
  // 以下路径**全部来自已登录会话的实测**（2026-10-02）。未登录时它们是 404 或
  // 登录墙，无法通过猜测得到 —— 上一轮我猜的 9 个候选路径全部 404。
  //
  //   /users/<name>/videos/favorites   收藏/最爱（实测 15 条卡片）
  //   /users/<name>/videos             该用户的视频
  //   /users/<name>/playlists          该用户的片单
  //   /users/<name>                    个人主页
  //   /subscriptions                   订阅（登录后实测 39 条卡片）
  //
  /// 登录用户名。未登录返回空串。
  String get currentUserName {
    try {
      return PornHubAuthService.to.userName;
    } catch (_) {
      return '';
    }
  }

  /// 收藏 / 最爱：`/users/<name>/videos/favorites`
  Future<VideoPage> fetchFavorites({int page = 1}) async {
    final name = currentUserName;
    if (name.isEmpty) {
      return const VideoPage(
        items: <VideoItem>[],
        page: 1,
        hasMore: false,
        summary: '请先登录 PornHub',
      );
    }
    return _fetchList('/users/$name/videos/favorites', page);
  }

  /// 官网账号的观看历史。只读取这个列表，不导入本机记录。
  Future<VideoPage> fetchHistory({int page = 1}) async {
    final name = currentUserName;
    if (name.isEmpty) return const VideoPage.empty();
    final html = await _getHtml(
      _pageUrl('/users/${Uri.encodeComponent(name)}/videos/recent', page),
    );
    if (html == null || _isUnavailableListPage(html)) return _failedPage(page);
    final items = await Isolate.run(() {
      final doc = html_parser.parse(_stripHeaderMenus(html));
      final main = doc.querySelector('.profileContentLeft .profileVids');
      return main == null
          ? <VideoItem>[]
          : _parseCardsFromDocument(html_parser.parse(main.outerHtml));
    });
    return VideoPage(
      items: items,
      page: page,
      hasMore: false,
      totalItems: items.length,
    );
  }

  /// 我收藏的片单：`/users/<name>/playlists/favorites`
  ///
  /// 解析复用 [fetchPlaylists] 的片单卡片解析（`li[id^='playlist_']`），
  /// 只是把路径换成用户自己的收藏片单页。
  Future<List<PornHubPlaylist>> fetchUserPlaylists({int page = 1}) async {
    final name = currentUserName;
    if (name.isEmpty) return const <PornHubPlaylist>[];
    return fetchPlaylists(page: page, path: '/users/$name/playlists/favorites');
  }

  /// 我的公开片单：`/users/<name>/playlists/public`
  ///
  /// 与「我收藏的片单」是同一种卡片（`li#playlist_`），解析完全共用，
  /// 只是路径不同，所以直接转调 [fetchPlaylists]。
  Future<List<PornHubPlaylist>> fetchPublicPlaylists({int page = 1}) async {
    final name = currentUserName;
    if (name.isEmpty) return const <PornHubPlaylist>[];
    final account = _currentAccountStamp;
    final public = await fetchPlaylists(
      page: page,
      path: '/users/$name/playlists/public',
    );
    if (account != _currentAccountStamp) throw const PornHubRequestException();
    final private = await fetchPlaylists(
      page: page,
      path: '/users/$name/playlists/private',
    );
    final seen = <String>{};
    if (account != _currentAccountStamp) throw const PornHubRequestException();
    final combined = [
      ...public,
      ...private,
    ].where((p) => seen.add(p.id)).toList();
    return public.isNotEmpty && private.isNotEmpty
        ? sortPlaylistsByTime(combined)
        : combined;
  }

  /// 订阅的创作者列表：`/users/<name>/subscriptions`
  ///
  /// 实测该页**匿名即可访问**（无需登录），共 52 项。每一项是一个 `<li>`：
  /// `a.userLink[href][data-userid]` + `img.avatar[src][alt]` +
  /// `a.usernameLink`（纯名字）。href 实测三种前缀都出现：
  /// `/model/<slug>`(35) · `/pornstar/<name>`(13) · `/users/<name>`(3)，
  /// 三者都能直接交给 [fetchPathPage] 取到视频卡片。
  Future<List<PornHubSubscription>> fetchSubscribedCreators(
    String userName,
  ) async {
    final name = userName.trim();
    if (name.isEmpty) return const <PornHubSubscription>[];
    final html = await _getHtml('$baseUrl/users/$name/subscriptions');
    if (html == null) throw const PornHubRequestException();
    final items = await Isolate.run(() => _parseSubscriptionItems(html));
    if (items.isEmpty && _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }
    return items;
  }

  /// 解析订阅项。
  ///
  /// 与视频卡片同理：**不做整页 DOM 解析**（该页约 3 MB），
  /// 按 `class="userLink clearfix"` 定位后回切到最近的 `<li>`，只解析那一小块。
  static List<PornHubSubscription> _parseSubscriptionItems(String html) {
    final result = <PornHubSubscription>[];
    final seen = <String>{};
    var searchFrom = 0;
    while (result.length < 500) {
      final markerAt = html.indexOf('class="userLink clearfix"', searchFrom);
      if (markerAt < 0) break;
      final open = html.lastIndexOf('<li', markerAt);
      final close = html.indexOf('</li>', markerAt);
      if (open < 0 || close < 0 || open > markerAt) break;
      searchFrom = close + 5;

      final item = _parseSubscriptionItem(html.substring(open, close));
      if (item != null && seen.add(item.path)) result.add(item);
    }
    return result;
  }

  static PornHubSubscription? _parseSubscriptionItem(String block) {
    final doc = html_parser.parseFragment(block);
    final link = doc.querySelector('a.userLink');
    final href = link?.attributes['href'] ?? '';
    if (href.isEmpty) return null;

    final img = doc.querySelector('img.avatar') ?? doc.querySelector('img');
    var name = _text(doc.querySelector('a.usernameLink'));
    if (name.isEmpty) name = (img?.attributes['alt'] ?? '').trim();
    if (name.isEmpty) name = (link?.attributes['title'] ?? '').trim();
    if (name.isEmpty) return null;

    return PornHubSubscription(
      name: name,
      path: href,
      avatarUrl: img?.attributes['src'] ?? img?.attributes['data-image'],
      userId: link?.attributes['data-userid'] ?? '',
    );
  }

  /// 某创作者的视频（入参是**订阅项里的站内路径**，如 `/model/reislin`）。
  ///
  /// **依次尝试多个候选路径，第一个取到卡片的胜出** —— 因为不同创作者
  /// 的视频列表页路径并不统一，而且有些路径会 404：
  ///   - `/model/<slug>`      → 先试 `/model/<slug>/videos`，再退回主页本身
  ///   - `/pornstar/<name>`   → 先试 `/videos/upload`，再 `/videos`，再主页
  ///   - `/users/<name>`      → 先试 `/users/<name>/videos`，再主页
  /// 不这样做的话，某些创作者会直接显示「暂未获取到视频」。
  Future<VideoPage> fetchCreatorVideos(
    String creatorPath, {
    int page = 1,
  }) async {
    final candidates = creatorVideoCandidates(creatorPath);
    if (candidates.isEmpty) return const VideoPage.empty();
    VideoPage? failed;
    for (final candidate in candidates) {
      // The creator's official "Latest" link has no popularity-sort parameter.
      final uri = Uri.parse(candidate);
      final query = Map<String, String>.from(uri.queryParameters)..remove('o');
      final latest = uri
          .replace(queryParameters: query.isEmpty ? null : query)
          .toString();
      final res = await fetchPathPage(latest, page);
      if (res.items.isNotEmpty) return res;
      if (res.summary != null) failed = res;
    }
    return failed ?? const VideoPage.empty();
  }

  /// 由创作者主页路径生成候选「视频列表」路径，按优先级排列。
  ///
  /// ⚠️ **绝不把「主页本身」作为兜底候选**：主页（`/model/<x>`）上除了该模特的作品，
  /// 还会混入「你可能喜欢 / 相关推荐」等**别人家的视频**，实测数量也对不上
  /// （如 `/model/reislin` 主页 24 条 vs `/model/reislin/videos` 40 条）。
  /// 兜底到主页 = 用户看到的「刷出别的视频」。
  /// 所以候选里只保留真正的「视频列表页」；都取不到就返回空，让 UI 明确提示。
  static List<String> creatorVideoCandidates(String creatorPath) {
    final p = creatorPath.trim();
    if (p.isEmpty) return const <String>[];
    if (p.contains('/videos')) return <String>[p];
    if (p.startsWith('/pornstar/')) {
      return <String>['$p/videos/upload', '$p/videos'];
    }
    if (p.startsWith('/model/')) {
      return <String>['$p/videos'];
    }
    if (p.startsWith('/users/')) {
      return <String>['$p/videos'];
    }
    return <String>['$p/videos'];
  }

  /// 某创作者**总共有多少个视频**。
  ///
  /// 实测（2026-10-03）：这个总数**只在主页上有** ——
  /// `/model/misty-queen` 页面里写着「显示1-24个，**共有121个**」，
  /// 而 `/model/misty-queen/videos` 反而**没有**这个标记，所以取计数必须抓主页。
  ///
  /// 注意：主页上混着「你可能喜欢」等其他卡片，**绝不能拿主页当视频列表**；
  /// 但「共有 M 个」这个数字是权威的，正是用户要核对的那个数。
  Future<int?> fetchCreatorTotalCount(String creatorPath) async {
    final p = creatorPath.trim();
    if (p.isEmpty) return null;
    var profile = p;
    final i = profile.indexOf('/videos');
    if (i >= 0) profile = profile.substring(0, i);
    final html = await _getHtml('$baseUrl$profile');
    if (html == null) return null;
    final m = RegExp(
      r'共\s*有\s*([\d,]+)\s*个|\bof\s+([\d,]+)\s*(?:videos|</)',
      caseSensitive: false,
    ).firstMatch(html);
    if (m == null) return null;
    return int.tryParse((m.group(1) ?? m.group(2))!.replaceAll(',', ''));
  }

  /// 官方「订阅」视频流：`/subscriptions`（需登录）。
  ///
  /// 用户要求用它来当「全部订阅」的数据源（替代「52 个创作者逐个聚合」）：
  /// 官方这一页本身就是按时间倒序的订阅视频流，且 `?page=N` 分页，
  /// 一次请求就能拿到一页，比聚合 52 个创作者轻得多。
  Future<VideoPage> fetchSubscriptionsFeed({int page = 1}) async {
    if (!isLoggedIn) {
      return const VideoPage(
        items: <VideoItem>[],
        page: 1,
        hasMore: false,
        summary: '请先登录 PornHub',
      );
    }
    return _fetchList('/subscriptions', page);
  }

  /// 由创作者主页路径推出其「视频列表」路径。**model 与 pornstar 不一样**（实测）：
  ///
  /// | 主页 | 视频列表页 | 实测 |
  /// |---|---|---|
  /// | `/model/<slug>` | `/model/<slug>/videos` | 44 张卡，`?page=N` 分页（5 个页码链接） |
  /// | `/pornstar/<name>` | `/pornstar/<name>/videos/upload` | 40 张卡 |
  /// | `/users/<name>` | `/users/<name>/videos` | — |
  ///
  /// 三者都仍是 `li.pcVideoListItem`，所以解析器完全共用，不需要为 pornstar 另写一套。
  static String videosPathOf(String creatorPath) {
    final p = creatorPath.trim();
    if (p.isEmpty) return p;
    if (p.contains('/videos')) return p;
    if (p.startsWith('/pornstar/')) return '$p/videos/upload';
    if (p.startsWith('/model/')) return '$p/videos';
    if (p.startsWith('/users/')) return '$p/videos';
    return '$p/videos';
  }

  // ============================================================ 切片（clips）
  //
  // 切片与视频是**两套完全不同的页面结构**（实测）：
  //   容器 `ul.videos.row-5-thumbs.verticalClipsListing`，卡片 `li.profileBoxClip`，
  //   链接 `/view_clip.php?viewkey=<id>`，时长 `span.bgEffect.time`，
  //   播放量 `span.videoViews var`，上传者 `.usernameWrap a`。
  // 因此绝不能复用视频解析器（用 `li.pcVideoListItem` 只会取到顶部下拉菜单的 4 条）。

  /// 由创作者主页路径推出其「切片列表」路径。
  ///
  /// 三种主页前缀（实测）都拼 `/clips/by-community`：
  ///   `/model/<slug>` · `/pornstar/<x>` · `/users/<x>`。
  /// 已含 `/clips` 的路径原样使用，避免重复拼接。
  static String clipsPathOf(String creatorPath) {
    final p = creatorPath.trim();
    if (p.isEmpty) return p;
    if (p.contains('/clips')) return p;
    return '$p/clips/by-community';
  }

  /// 某创作者的切片：`/model/<slug>/clips/by-community`（实测 36 条/页、分页）。
  Future<VideoPage> fetchCreatorClips(
    String creatorPath, {
    int page = 1,
  }) async {
    final path = clipsPathOf(creatorPath);
    if (path.isEmpty) return const VideoPage.empty();
    final html = await _getHtml(_pageUrl(path, page));
    if (html == null) return _failedPage(page);
    final items = await Isolate.run(() => _parseClipsSliced(html));
    if (items.isEmpty && _isUnavailableListPage(html)) return _failedPage(page);
    return VideoPage(
      items: items,
      page: page,
      // 切片页的下一页链接形态不稳定，按「本页有条目即可能还有下一页」判断，
      // 由调用方在拿到空页时自然停住。
      hasMore: _hasNextListPage(html, page),
      totalPages: _hasNextListPage(html, page) ? page + 1 : page,
      // 页面文案「显示1-N个，共有M个」里的 M 是权威总数，取不到则回退 0。
      totalItems: _parseClipTotal(html) ?? 0,
    );
  }

  /// 从 `view_clip.php?viewkey=<id>` 里取 viewkey；取不到返回空串。
  ///
  /// 与 [_normalizeKey] 的差异：后者取不到时会原样返回整串，这里必须能判空。
  static String _viewkeyOf(String url) {
    final match = RegExp(r'[?&]viewkey=([^&#]+)').firstMatch(url);
    return match?.group(1) ?? '';
  }

  /// 切片页文案「显示1-36个，共有56个」→ 总数 56；取不到返回 null。
  static int? _parseClipTotal(String html) {
    final match = RegExp(r'共\s*有\s*([\d,]+)\s*个').firstMatch(html);
    if (match == null) return null;
    return int.tryParse(match.group(1)!.replaceAll(',', ''));
  }

  /// 按字符串切片提取切片卡片，逐块解析。
  ///
  /// 与视频卡片同理不做整页 DOM 解析（页面约 3 MB）；差异只在标记串与选择器。
  /// 取卡片沿用 [_parseCardsSliced] 的 `<li>` 深度配平写法，避免被嵌套 li 截断。
  static List<VideoItem> _parseClipsSliced(String html) {
    final items = <VideoItem>[];
    final seen = <String>{};
    var searchFrom = 0;
    while (items.length < 200) {
      final markerAt = html.indexOf(_clipCardMarker, searchFrom);
      if (markerAt < 0) break;
      final open = html.lastIndexOf('<li', markerAt);
      if (open < 0 || open > markerAt) break;

      var depth = 1;
      var pos = open + 3;
      var end = -1;
      while (pos < html.length) {
        final nextOpen = html.indexOf('<li', pos);
        final nextClose = html.indexOf('</li>', pos);
        if (nextClose < 0) break;
        if (nextOpen >= 0 && nextOpen < nextClose) {
          depth++;
          pos = nextOpen + 3;
        } else {
          depth--;
          pos = nextClose + 5;
          if (depth <= 0) {
            end = pos;
            break;
          }
        }
      }
      if (end <= open) break;
      // 保证游标前进，避免 marker 落在非卡片 li 里时反复命中而死循环。
      searchFrom = end > markerAt ? end : markerAt + _clipCardMarker.length;

      final item = _parseClipFragment(html.substring(open, end));
      if (item != null && seen.add(item.id)) items.add(item);
    }
    return items;
  }

  static VideoItem? _parseClipFragment(String block) {
    final doc = html_parser.parseFragment(block);
    final li = doc.querySelector('li');
    return li == null ? null : _parseClipFragmentElement(li);
  }

  static VideoItem? _parseClipFragmentElement(dom.Element li) {
    if (_isAdNode(li)) return null;
    final link = li.querySelector('a[href*="view_clip.php?viewkey="]');
    if (link == null) return null;
    final href = link.attributes['href'] ?? '';
    final viewkey = _viewkeyOf(href);
    if (viewkey.isEmpty) return null;

    final img = li.querySelector('img.thumb') ?? li.querySelector('img');
    final thumb =
        img?.attributes['data-image'] ??
        img?.attributes['data-src'] ??
        img?.attributes['src'] ??
        '';
    final durationStr = _text(
      li.querySelector('span.bgEffect.time, var.duration, .duration .time'),
    );
    final viewsStr = _text(li.querySelector('span.videoViews var, .views var'));
    final userEl = li.querySelector(
      '.usernameWrap a, .userNameInfo .usernameWrapper a',
    );
    final rawTitle =
        link.attributes['title'] ??
        li.querySelector('a[title]')?.attributes['title'] ??
        '';
    final title = rawTitle.trim().isNotEmpty ? rawTitle.trim() : _text(link);
    final detailUrl = href.startsWith('http') ? href : '$baseUrl$href';

    return VideoItem(
      // 前缀标记「这是切片」，详情解析据此改走 /view_clip.php。
      id: '$_clipIdPrefix$viewkey',
      title: title,
      author: _text(userEl).isEmpty ? 'unknown' : _text(userEl),
      // 列表页拿不到播放地址：官网把 mediaDefinitions 放在详情页。
      hlsUrl: '',
      detailUrl: detailUrl,
      thumbnailUrl: thumb.isEmpty ? null : thumb,
      duration: _parseDuration(durationStr),
      durationStr: durationStr.isEmpty ? null : durationStr,
      views: _parseViews(viewsStr),
      viewsStr: viewsStr.isEmpty ? null : viewsStr,
    );
  }

  /// 某用户的视频：`/users/<name>/videos`
  Future<VideoPage> fetchUserVideos(String userName, {int page = 1}) =>
      _fetchList('/users/$userName/videos', page);

  /// 通用列表抓取（分页拼接与解析与主列表一致）。
  Future<VideoPage> _fetchList(String path, int page) async {
    final html = await _getHtml(_pageUrl(path, page));
    if (html == null) return _failedPage(page);
    final items = await Isolate.run(() => _parseCardsSliced(html));
    if (items.isEmpty && _isUnavailableListPage(html)) return _failedPage(page);
    return VideoPage(
      items: items,
      page: page,
      hasMore: items.isNotEmpty && _hasNextListPage(html, page),
      totalPages: _hasNextListPage(html, page) ? page + 1 : page,
      // 官网在列表页写「显示最多 N 个视频」（历史页 N=1858，带千分位逗号），
      // 这是跨页总数；取不到就回退 0，让上层按「总数未知」处理，
      // 而不是把本页条数误当成总数。
      totalItems: _parseTotalItems(html) ?? 0,
    );
  }

  /// 解析列表页上的「显示最多 N 个视频」总数（数字可能带千分位逗号）。
  ///
  /// 实测只有历史 / 收藏这类用户页有这个文案；取不到返回 null，
  /// 由调用方决定如何回退，不在解析层臆造总数。
  static int? _parseTotalItems(String html) {
    final match = RegExp(r'显示最多\s*([\d,]+)\s*个视频').firstMatch(html);
    if (match == null) return null;
    return int.tryParse(match.group(1)!.replaceAll(',', ''));
  }

  static bool _hasNextListPage(String html, int page) {
    // The official next-page link is authoritative; a nonempty last page
    // does not imply that requesting another page will succeed.
    return RegExp(
      r'''href\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html).any((match) {
      final href = match.group(1)!.replaceAll('&amp;', '&');
      return int.tryParse(Uri.tryParse(href)?.queryParameters['page'] ?? '') ==
          page + 1;
    });
  }

  static bool _isUnavailableListPage(String html) {
    final lower = html.toLowerCase();
    if (lower.contains('just a moment') ||
        lower.contains('cf-chl-') ||
        lower.contains('verify you are human') ||
        lower.contains('access denied')) {
      return true;
    }
    // A short interstitial is not a valid empty subscription response.
    return html.length < 10000 &&
        !RegExp(
          r'no videos|no subscriptions|没有视频|暂无视频|尚无视频|尚未订阅|no results',
          caseSensitive: false,
        ).hasMatch(html);
  }

  /// 按任意站内路径抓一页列表。
  ///
  /// 供 UI 直接消费分类入口（`/video?o=tr`、`/video?c=27`、`/hd`、
  /// `/model/<name>`、`/channels/<slug>` 等）—— 这些页面的卡片结构与主列表
  /// **完全一致**（已跨 9 种页面类型实测：六字段完整率 100%），所以共用同一解析器。
  Future<VideoPage> fetchPathPage(String path, int page) =>
      _fetchList(path, page);

  Future<PornHubBrowseData> fetchBrowse(
    String path, {
    int page = 1,
    String kind = 'videos',
  }) async {
    final uri = Uri.parse(baseUrl).resolve(path);
    final query = Map<String, String>.from(uri.queryParameters)..remove('page');
    if (page > 1) query['page'] = '$page';
    final url = uri
        .replace(queryParameters: query.isEmpty ? null : query)
        .toString();
    if (!_isAllowedPageUrl(url)) throw const PornHubRequestException();
    final html = await _getHtml(url);
    if (html == null || _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }
    return Isolate.run(() {
      final doc = html_parser.parse(html);
      final videos = <VideoItem>[];
      final creators = <PornHubSubscription>[];
      final playlists = <PornHubPlaylist>[];
      final seen = <String>{};
      if (kind == 'clips') {
        final main = doc.querySelector(
          'ul#videoCategory.clipsListing, ul.verticalClipsListing, ul.clipsListing',
        );
        for (final li
            in main?.querySelectorAll(
                  'li.verticalVideoBox, li.profileBoxClip',
                ) ??
                <dom.Element>[]) {
          final item = _parseClipFragmentElement(li);
          if (item != null && seen.add(item.id)) videos.add(item);
        }
      } else if (kind == 'creators') {
        for (final card in doc.querySelectorAll(
          '.userWidgetWrapperGrid > li, li.performerCard',
        )) {
          if (_isAdNode(card)) continue;
          final link = card.querySelector(
            'a[href^="/users/"], a[href^="/model/"], a[href^="/pornstar/"]',
          );
          final path = link?.attributes['href'] ?? '';
          if (path.isEmpty || !seen.add(path)) continue;
          final image = card.querySelector('img');
          final name = _text(
            card.querySelector('.usernameLink, .username, .pornstarName'),
          );
          creators.add(
            PornHubSubscription(
              path: path,
              name: name.isNotEmpty
                  ? name
                  : image?.attributes['alt'] ?? _text(link),
              avatarUrl:
                  image?.attributes['data-image'] ??
                  image?.attributes['data-src'] ??
                  image?.attributes['src'],
            ),
          );
        }
      } else if (kind == 'playlists') {
        playlists.addAll(_playlistCards(html));
      } else {
        videos.addAll(_parseCardsSliced(html));
      }
      final groups = <PornHubFilterGroup>[];
      final filterSeen = <String>{};
      for (final ul in doc.querySelectorAll('ul[data-filter]')) {
        final key = ul.attributes['data-filter']!;
        if (!filterSeen.add(key)) continue;
        final options = <PornHubLinkItem>[];
        final optionSeen = <String>{};
        for (final li in ul.querySelectorAll('li[data-value]')) {
          final value = li.attributes['data-value']!;
          final name = _text(li.querySelector('a, label'));
          if (name.isNotEmpty && optionSeen.add(value)) {
            options.add(PornHubLinkItem(name: name, path: value));
          }
        }
        if (options.isEmpty) continue;
        final label =
            const {
              'o': '排序',
              't': '时间区段',
              'p': '出品',
              'filter_category': '包含分类',
              'c': '分类',
              'exclude_category': '排除分类',
            }[key] ??
            key;
        groups.add(
          PornHubFilterGroup(
            key: key,
            title: label,
            options: options,
            multiple: key == 'filter_category' || key == 'exclude_category',
            selected: ul.attributes['data-selected'] ?? '',
          ),
        );
      }
      final suggestions = <PornHubLinkItem>[];
      for (final link in doc.querySelectorAll('.suggestionsListWrapper a')) {
        final path = link.attributes['href'] ?? '';
        if (path.startsWith('/')) {
          suggestions.add(PornHubLinkItem(name: _text(link), path: path));
        }
      }
      final total = RegExp(r'"resultsCount"\s*:\s*(\d+)').firstMatch(html);
      return PornHubBrowseData(
        videos: videos,
        creators: creators,
        playlists: playlists,
        filters: groups,
        suggestions: suggestions,
        hasMore: _hasNextListPage(html, page),
        total: int.tryParse(total?.group(1) ?? ''),
      );
    });
  }

  /// 账号密码登录的便捷入口（转调认证服务，便于 UI 只依赖源）。
  Future<bool> login(String email, String password) async {
    try {
      return await PornHubAuthService.to.login(email, password);
    } catch (e) {
      AppLogger.w('PornHub', '登录调用失败: $e');
      return false;
    }
  }

  // ============================================================ 片单 / 明星
  //
  // 这两类列表的卡片结构与视频卡**完全不同**（实测）：
  //   片单  -> `li#playlist_<id>`，标题 `.title`，数量 `.number`（「15 个视频」），
  //            封面 `.playlist-thumb img[data-thumb_url]`
  //   明星  -> `li.performerCard`，链接 `/pornstar/<name>`，名次 `.rankNumber`，
  //            头像 `img[data-image]`
  //
  // 但两者的**详情页都是标准视频卡片**（`/playlist/<id>` 23 张、
  // `/pornstar/<name>` 39 张），所以详情直接复用 [_parseCards]，不另写解析器。

  /// 片单列表：默认 `/playlists`；也可传入其它片单页路径
  /// （例如「我收藏的片单」`/users/<name>/playlists/favorites`）。
  Future<List<PornHubPlaylist>> fetchPlaylists({
    int page = 1,
    String path = '/playlists?o=mr',
  }) async {
    final html = await _getHtml(_pageUrl(path, page));
    if (html == null || _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }
    return Isolate.run(() => _playlistCards(html));
  }

  static List<PornHubPlaylist> _playlistCards(String html) {
    final doc = html_parser.parseFragment(
      _scopeToMainList(_stripHeaderMenus(html)),
    );
    final result = <PornHubPlaylist>[];
    final seen = <String>{};
    for (final li in doc.querySelectorAll('li[id^="playlist_"]')) {
      if (_isAdNode(li)) continue;
      final id = li.id.replaceFirst('playlist_', '');
      if (!RegExp(r'^\d+$').hasMatch(id) || !seen.add(id)) continue;
      final titleLink = li.querySelector('a.title[href*="/playlist/"]');
      final title =
          titleLink?.attributes['title'] ?? _text(li.querySelector('.title'));
      final image = li.querySelector('img');
      final cover =
          image?.attributes['data-thumb_url'] ??
          image?.attributes['data-image'] ??
          image?.attributes['data-src'] ??
          image?.attributes['src'];
      result.add(
        PornHubPlaylist(
          id: id,
          title: title.isEmpty ? '片单 $id' : title,
          url: '/playlist/$id',
          videoCount: PornHubPlaylist.parseCount(
            _text(li.querySelector('.number')),
          ),
          coverUrl: cover != null && cover.startsWith('https://')
              ? cover
              : null,
        ),
      );
    }
    return result;
  }

  final Map<String, PornHubPlaylistDetails> _playlistDetails = {};
  final Map<String, Map<int, int>> _playlistPageCounts = {};

  Future<PornHubPlaylistDetails> fetchPlaylistDetails(
    String id, {
    bool forceRefresh = false,
  }) async {
    _ensureAccountSession();
    if (!RegExp(r'^\d+$').hasMatch(id)) throw const PornHubRequestException();
    if (!forceRefresh && _playlistDetails.containsKey(id)) {
      return _playlistDetails[id]!;
    }
    final html = await _getHtml('$baseUrl/playlist/$id');
    if (html == null || _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }
    final dataMatch = RegExp(
      r'PLAYLIST_VIEW\s*=\s*({.*?});',
      dotAll: true,
    ).firstMatch(html);
    Map<String, dynamic> data = {};
    if (dataMatch != null) {
      try {
        data = jsonDecode(dataMatch.group(1)!) as Map<String, dynamic>;
      } catch (_) {}
    }
    String variable(String key) =>
        RegExp('\\b$key\\s*=\\s*["\']([^"\']*)["\']')
            .firstMatch(html)
            ?.group(1)
            ?.replaceAll(r'\/', '/') ??
        '';
    final doc = html_parser.parseFragment(
      _sliceElementByMarker(html, 'videoPlaylist'),
    );
    final videos = _parseCardsFromDocument(html_parser.parse(doc.outerHtml));
    final detail = PornHubPlaylistDetails(
      playlist: PornHubPlaylist(
        id: id,
        title: data['title']?.toString() ?? '',
        url: '/playlist/$id',
        videoCount: int.tryParse('${data['video_count']}') ?? videos.length,
      ),
      token: variable('token'),
      addUrl: variable('playlistFavouriteAddUrl'),
      removeUrl: variable('playlistFavouriteRemoveUrl'),
      chunkUrl: variable('lazyloadUrl'),
      isFavourite: RegExp(r'alreadyAddedToFav\s*=\s*1').hasMatch(html),
      videos: videos,
      createdAt: DateTime.tryParse(data['date_added']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(data['date_updated']?.toString() ?? ''),
    );
    _playlistDetails[id] = detail;
    if (forceRefresh) _playlistPageCounts.remove(id);
    if (_playlistDetails.length > 64) {
      _playlistDetails.remove(_playlistDetails.keys.first);
    }
    return detail;
  }

  Future<List<PornHubPlaylist>> sortPlaylistsByTime(
    List<PornHubPlaylist> playlists,
  ) async {
    final dates = <String, DateTime>{};
    for (var i = 0; i < playlists.length; i += 2) {
      await Future.wait(
        playlists.skip(i).take(2).map((p) async {
          try {
            final d = await fetchPlaylistDetails(p.id);
            final date = d.createdAt;
            if (date != null) dates[p.id] = date;
          } catch (_) {}
        }),
      );
    }
    final original = {
      for (var i = 0; i < playlists.length; i++) playlists[i].id: i,
    };
    return [...playlists]..sort((a, b) {
      final x = dates[a.id], y = dates[b.id];
      if (x != null && y != null) {
        final order = y.compareTo(x);
        return order != 0 ? order : original[a.id]!.compareTo(original[b.id]!);
      }
      if (x != null) return -1;
      if (y != null) return 1;
      return original[a.id]!.compareTo(original[b.id]!);
    });
  }

  Future<VideoPage> fetchPlaylistVideos(
    String playlistId, {
    int page = 1,
  }) async {
    _ensureAccountSession();
    final account = _currentAccountStamp;
    final detail = await fetchPlaylistDetails(playlistId);
    List<VideoItem> videos = detail.videos;
    if (page > 1) {
      if (detail.chunkUrl.isEmpty) return const VideoPage.empty();
      final html = await _getHtml(
        _pageUrl(detail.chunkUrl, page),
        allowEmpty: true,
      );
      if (html == null) return _failedPage(page);
      videos = await Isolate.run(() => _parseCardsSliced(html));
    }
    if (account != _currentAccountStamp) throw const PornHubRequestException();
    final counts = _playlistPageCounts.putIfAbsent(playlistId, () => {});
    counts[page] = videos.length;
    final loaded = counts.entries
        .where((e) => e.key <= page)
        .fold<int>(0, (n, e) => n + e.value);
    return VideoPage(
      items: videos,
      page: page,
      totalItems: detail.playlist.videoCount,
      hasMore: videos.isNotEmpty && (loaded < detail.playlist.videoCount),
      totalPages: detail.videos.isEmpty
          ? 1
          : (detail.playlist.videoCount / detail.videos.length).ceil(),
    );
  }

  Future<({bool ok, String message})> setPlaylistFavourite(
    String id, {
    required bool remove,
  }) async {
    if (!PornHubAuthService.to.isLoggedIn.value) {
      return (ok: false, message: '请先登录 PornHub');
    }
    final account = _currentAccountStamp;
    final detail = await fetchPlaylistDetails(id, forceRefresh: true);
    if (account != _currentAccountStamp) {
      return (ok: false, message: '账号已切换，请重试');
    }
    final raw = remove ? detail.removeUrl : detail.addUrl;
    final uri = Uri.parse(baseUrl).resolve(raw);
    if (raw.isEmpty ||
        !_isAllowedPageUrl(uri.toString()) ||
        !uri.path.startsWith('/api/v1/playlist/')) {
      return (ok: false, message: '无法取得片单收藏接口');
    }
    try {
      final response = await _mediaDio.request<String>(
        uri.toString(),
        data: remove ? null : {'pid': int.parse(id), 'token': detail.token},
        options: Options(
          method: remove ? 'DELETE' : 'POST',
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          followRedirects: false,
          headers: {..._buildHeaders(), 'X-Requested-With': 'XMLHttpRequest'},
        ),
      );
      final data = jsonDecode(response.data ?? '') as Map<String, dynamic>;
      final ok =
          response.statusCode != null &&
          response.statusCode! < 300 &&
          (data['success'] == true ||
              data['success'] == 1 ||
              data['success'] == '1' ||
              data['status'] == 'success');
      if (ok) _playlistDetails.remove(id);
      return (
        ok: ok,
        message: ok
            ? (remove ? '已取消收藏片单' : '已收藏片单')
            : (data['message']?.toString() ?? '片单收藏失败'),
      );
    } catch (_) {
      return (ok: false, message: '片单收藏失败，请重试');
    }
  }

  // ============================================================ 详情页扩展
  //
  // 详情页 `/view_video.php?viewkey=<viewkey>`（切片是 `/view_clip.php`）**服务端直出**
  // 了四块内容：4 个 Tab（相关 / 推荐 / 评论 / 片单）、分类、标签、色情明星，
  // 以及写操作所需的 `token` / 数字 `video_id` / `favouriteUrl`。
  //
  // 这些**全部在同一份 HTML 里**，所以只抓一次、只解析一次（[_extraCache] 缓存），
  // 上层切 Tab 不产生任何新请求。这与播放用的 [fetchDetail] 是两次独立抓取：
  // 播放走移动 UA 拿流，这里走桌面 UA 拿版面（移动 watch 页是另一套 DOM）。

  final Map<String, PornHubDetailExtra> _extraCache =
      <String, PornHubDetailExtra>{};
  final Map<String, Future<PornHubDetailExtra>> _extraInFlight =
      <String, Future<PornHubDetailExtra>>{};

  /// 取详情页扩展内容（已缓存则直接返回）。
  ///
  /// 失败 / 空结果**不写缓存**，避免一次网络抖动把空数据钉住 15 分钟。
  Future<PornHubDetailExtra> fetchDetailExtra(
    String videoId, {
    bool forceRefresh = false,
  }) {
    _ensureAccountSession();
    final key = _normalizeKey(videoId);
    if (!forceRefresh) {
      final cached = _extraCache[key] ?? _extraCache[videoId];
      if (cached != null) return Future<PornHubDetailExtra>.value(cached);
    }
    final inFlight = _extraInFlight[key] ?? _extraInFlight[videoId];
    if (inFlight != null) return inFlight;

    // whenComplete 的回调必须返回 void，否则 Map.remove 的返回值会让自己等自己
    // （与 [fetchDetail] 同样的坑，见那里的注释）。
    late final Future<PornHubDetailExtra> future;
    future = _fetchDetailExtraInternal(videoId).whenComplete(() {
      if (identical(_extraInFlight[key], future)) _extraInFlight.remove(key);
      if (identical(_extraInFlight[videoId], future)) {
        _extraInFlight.remove(videoId);
      }
    });
    _extraInFlight[key] = future;
    if (key != videoId) {
      _extraInFlight[videoId] = future;
    }
    return future;
  }

  Future<PornHubDetailExtra> _fetchDetailExtraInternal(String videoId) async {
    final epoch = _accountEpoch;
    final account = _currentAccountStamp;
    videoId = _normalizeKey(videoId);
    final isClip = videoId.startsWith(_clipIdPrefix);
    final rawId = isClip ? videoId.substring(_clipIdPrefix.length) : videoId;
    final parsed = Uri.tryParse(rawId);
    final url = parsed != null && parsed.hasAuthority
        ? (_isAllowedPageUrl(rawId) ? rawId : null)
        : '$baseUrl/${isClip ? 'view_clip.php' : 'view_video.php'}'
              '?viewkey=${Uri.encodeQueryComponent(rawId)}';
    if (url == null) return const PornHubDetailExtra();

    // 桌面 UA（playback 保持 false）：四个 Tab、分类 / 标签、明星都是桌面版结构。
    final html = await _getHtml(url);
    if (html == null || _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }

    final extra = await Isolate.run(() => _parseDetailExtra(html));
    if (epoch != _accountEpoch || account != _currentAccountStamp) {
      throw const PornHubRequestException();
    }
    if (!extra.isEmpty || extra.token.isNotEmpty || extra.videoId.isNotEmpty) {
      _extraCache[_normalizeKey(videoId)] = extra;
    }
    return extra;
  }

  /// 从详情页 HTML 里解析全部扩展内容。整页约 4.7 MB，**不做整页 DOM 解析**：
  /// 按标记串切片出每个容器，只解析那一小块（与 [_parseCardsSliced] 同一策略）。
  static PornHubDetailExtra _parseDetailExtra(String html) {
    final normalized = html.replaceAll(r'\/', '/').replaceAll(r'\"', '"');
    final button = _subscriptionButton(html);
    return PornHubDetailExtra(
      related: _parseCardsInContainer(html, 'relatedVideosListing'),
      recommended: _parseCardsInContainer(html, 'recommendedVideosListing'),
      categories: _parseLinkItems(html, 'categoriesWrapper', 'a.item'),
      tags: _parseLinkItems(html, 'tagsWrapper', 'a.item.isTag'),
      pornstars: _parseLinkItems(html, 'pornstarsWrapper', 'a.pstar-list-btn'),
      comments: _parseComments(html),
      playlists: _parsePlaylistRefs(html),
      token: _extractPageToken(normalized),
      videoId: _extractNumericVideoId(normalized),
      favouriteUrl: _extractFavouriteUrl(normalized),
      creatorPath: _extractUploaderPath(html),
      subscribeUrl: button?.attributes['data-subscribe-url'] ?? '',
      unsubscribeUrl: button?.attributes['data-unsubscribe-url'] ?? '',
      isSubscribed: button?.attributes['data-subscribed'] == '1',
      isFavourite: RegExp(r'"isFavourite"\s*:\s*1').hasMatch(normalized),
    );
  }

  /// 按标记串切出某个元素（用标签名做深度配平找结束标签）。
  ///
  /// 用标签配平而不是「第一个 `</div>`」：容器内部普遍嵌套同名字签，
  /// 直接截断会把内容切掉一半（[_scopeToMainList] 的注释里记录过同类坑）。
  ///
  /// [name] 是容器的 id 或 class 名。**优先按属性形态匹配**（`id="x"` /
  /// `class="x"` / `"x"`），只有都命中不到才退回裸名匹配 —— 因为页面内联脚本
  /// 里也会出现同样的名字（如 `$('#relatedVideosListing')`），裸名可能先命中脚本，
  /// 导致 `lastIndexOf('<')` 落到 `<` 之类的位置、切出错误的块。
  static String _sliceElementByMarker(String html, String name) {
    var at = html.indexOf('id="$name"');
    if (at < 0) at = html.indexOf('class="$name"');
    if (at < 0) at = html.indexOf('"$name"');
    if (at < 0) at = html.indexOf(name);
    if (at < 0) return '';
    final open = html.lastIndexOf('<', at);
    if (open < 0) return '';
    final match = RegExp(r'^<([a-zA-Z0-9]+)').firstMatch(html.substring(open));
    if (match == null) return '';
    final tag = match.group(1)!.toLowerCase();
    final openTag = '<$tag';
    final closeTag = '</$tag>';
    var depth = 0;
    var i = open;
    while (i < html.length) {
      final o = html.indexOf(openTag, i);
      final c = html.indexOf(closeTag, i);
      if (c < 0) break;
      if (o >= 0 && o < c) {
        depth++;
        i = o + openTag.length;
      } else {
        depth--;
        i = c + closeTag.length;
        if (depth <= 0) return html.substring(open, i);
      }
    }
    return '';
  }

  /// 解析某容器内的视频卡片（复用 [_parseCardsSliced]，即 `li.pcVideoListItem` 那套）。
  static List<VideoItem> _parseCardsInContainer(
    String html,
    String containerId,
  ) {
    final block = _sliceElementByMarker(html, containerId);
    if (block.isEmpty) return const <VideoItem>[];
    return _parseCardsSliced(block);
  }

  /// 解析某容器内的链接胶囊项（分类 / 标签 / 明星共用）。
  ///
  /// [selector] 命中容器内的 `<a>`；名字取 `span` 文本（标签是 `a>span`），
  /// 取不到再退回 `a` 自身的文本。按 href 去重。
  static List<PornHubLinkItem> _parseLinkItems(
    String html,
    String containerMarker,
    String selector,
  ) {
    final block = _sliceElementByMarker(html, containerMarker);
    if (block.isEmpty) return const <PornHubLinkItem>[];
    final doc = html_parser.parseFragment(block);
    final result = <PornHubLinkItem>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll(selector)) {
      final href = (a.attributes['href'] ?? '').trim();
      if (href.isEmpty) continue;
      var name = _text(a.querySelector('span')).trim();
      if (name.isEmpty) name = _text(a).trim();
      if (name.isEmpty) continue;
      if (seen.add(href)) result.add(PornHubLinkItem(name: name, path: href));
    }
    return result;
  }

  /// 解析 `#under-player-comments` 里的评论列表。
  static List<PornHubComment> _parseComments(String html) {
    final block = _sliceElementByMarker(html, 'under-player-comments');
    if (block.isEmpty) return const <PornHubComment>[];
    final doc = html_parser.parseFragment(block);
    final result = <PornHubComment>[];
    for (final c in doc.querySelectorAll('div.commentBlock')) {
      if (_isAdNode(c)) continue;
      final messageEl = c.querySelector('div.commentMessage');
      final message = _text(messageEl).trim();
      final userEl =
          c.querySelector('div.boxUserComments a.userLink') ??
          c.querySelector('a.userLink');
      final user = _text(userEl).trim();
      if (message.isEmpty && user.isEmpty) continue;
      final img = c.querySelector('img.commentAvatarImg');
      result.add(
        PornHubComment(
          user: user.isEmpty ? '匿名' : user,
          message: message,
          avatarUrl: img?.attributes['src'],
          upvotes: _parseCount(
            _text(c.querySelector('a[data-label="comment_upvote"]')),
          ),
          downvotes: _parseCount(
            _text(c.querySelector('a[data-label="comment_downvote"]')),
          ),
        ),
      );
    }
    return result;
  }

  /// 从任意文案里取第一个数字（顶/踩计数可能带千分位或夹杂图标文本）。
  static int _parseCount(String raw) {
    final match = RegExp(r'([\d,]+)').firstMatch(raw);
    if (match == null) return 0;
    return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
  }

  /// 解析 `#under-player-playlists` 里的片单条目。
  ///
  /// 官网每条片单同时给 `a.viewPlaylistLink`（标题链接）和 `a.playAllLink`
  /// （播放全部），两者指向同一 pid；这里只认前者，按 `li` 取封面与视频数。
  static List<PornHubPlaylist> _parsePlaylistRefs(String html) {
    final block = _sliceElementByMarker(html, 'under-player-playlists');
    return block.isEmpty ? const [] : _playlistCards(block);
  }

  /// 取本页写操作 token（内联脚本里，形如 `"token":"MTc5..."` 或 `token = '...'`）。
  static String _extractPageToken(String html) {
    final config = RegExp(r'WIDGET_RATINGS_LIKE_FAV\s*=\s*(\{[^;]+\});')
        .firstMatch(html);
    if (config != null) {
      final parsed = _tryDecodeJsonObject(config.group(1)!);
      final token = parsed?['token'];
      if (token is String && token.isNotEmpty) return token;
    }
    final quoted = RegExp(
      r'''["']token["']\s*:\s*["']([A-Za-z0-9_.\-]{16,})["']''',
    ).firstMatch(html);
    if (quoted != null) return quoted.group(1)!;
    final assigned = RegExp(
      r'''\btoken\b\s*[:=]\s*["']([A-Za-z0-9_.\-]{16,})["']''',
    ).firstMatch(html);
    return assigned?.group(1) ?? '';
  }

  /// 取数字视频 id（`data-video-id` 或 `video_id`）。添加片单的 `vid` 必须用它。
  static String _extractNumericVideoId(String html) {
    final own = RegExp(r'''["']itemIdNum["']\s*:\s*(\d+)''').firstMatch(html);
    if (own != null) return own.group(1)!;
    final attr = RegExp(r'''data-video-id\s*=\s*["']?(\d+)''').firstMatch(html);
    if (attr != null) return attr.group(1)!;
    final var2 = RegExp(r'''\bvideo_id\b\s*[:=]\s*["']?(\d+)''')
        .firstMatch(html);
    return var2?.group(1) ?? '';
  }

  /// 取最爱端点（内联脚本里的 `favouriteUrl`），取不到回退默认路径。
  static String _extractFavouriteUrl(String html) {
    final match = RegExp(r'''favouriteUrl["']?\s*[:=]\s*["']([^"']+)["']''')
        .firstMatch(html);
    final path = match?.group(1)?.trim() ?? '';
    return path.isEmpty ? '/video/favourite' : path;
  }

  /// 取上传者主页路径（如 `/model/<slug>`），供「作品」按钮跳转。
  ///
  /// 上传者链接的 class 在桌面详情页实测为 `.usernameWrap a` / `.uploaderLink`，
  /// 只接受三种合法前缀，避免把页头别的链接误当成 UP 主。
  static String _extractUploaderPath(String html) {
    final clean = _stripHeaderMenus(html);
    var block = _sliceElementByMarker(clean, 'videoUploaderBlock');
    if (block.isEmpty) block = _sliceElementByMarker(clean, 'usernameWrap');
    if (block.isEmpty) block = _sliceElementByMarker(clean, 'uploaderLink');
    final doc = html_parser.parseFragment(block);
    for (final link in doc.querySelectorAll('a[href]')) {
      final path = Uri.tryParse(link.attributes['href'] ?? '')?.path ?? '';
      if (RegExp(r'^/(model|pornstar|users|channels)/').hasMatch(path)) {
        return path;
      }
    }
    return '';
  }
  // ------------------------------------------------------------ 写操作（需登录）

  static dom.Element? _subscriptionButton(String html) {
    final match = RegExp(
      r'''<(?:button|a)\b[^>]*data-subscribe-url\s*=\s*["'][^"']+["'][^>]*>''',
      caseSensitive: false,
    ).firstMatch(html);
    return match == null
        ? null
        : html_parser
              .parseFragment('${match.group(0)}</button>')
              .querySelector('[data-subscribe-url]');
  }

  Future<PornHubCreatorProfile> fetchCreatorProfile(String path) async {
    final uri = Uri.tryParse(path);
    if (uri == null ||
        !RegExp(r'^/(model|pornstar|users|channels)/').hasMatch(uri.path)) {
      throw const PornHubRequestException();
    }
    final profilePath = uri.path.split('/videos').first.split('/clips').first;
    final html = await _getHtml('$baseUrl$profilePath');
    if (html == null || _isUnavailableListPage(html)) {
      throw const PornHubRequestException();
    }
    return Isolate.run(() {
      final doc = html_parser.parse(html);
      final button = _subscriptionButton(html);
      final count = RegExp(r'共\s*有\s*([\d,]+)\s*个').firstMatch(html);
      final image = doc.querySelector(
        '.profilePicture img, .profileAvatar img, #profileImage img, img[itemprop="image"]',
      );
      return PornHubCreatorProfile(
        path: profilePath,
        name: doc.querySelector('h1, .profileUserName')?.text.trim() ?? '',
        avatarUrl: image?.attributes['data-src'] ?? image?.attributes['src'],
        videoCount: int.tryParse(count?.group(1)?.replaceAll(',', '') ?? ''),
        subscribeUrl: button?.attributes['data-subscribe-url'] ?? '',
        unsubscribeUrl: button?.attributes['data-unsubscribe-url'] ?? '',
        isSubscribed: button?.attributes['data-subscribed'] == '1',
      );
    });
  }

  static bool _confirmedWriteSuccess(Map<String, dynamic>? value) =>
      value != null &&
      (value['success'] == true ||
          const ['1', 'true'].contains('${value['success']}'.toLowerCase()) ||
          '${value['status']}'.toLowerCase() == 'success');

  Future<({bool ok, String message})> setCreatorSubscription(
    String actionUrl,
  ) async {
    if (!isLoggedIn) return (ok: false, message: '请先登录 PornHub');
    final uri = Uri.parse(baseUrl).resolve(actionUrl);
    if (!_isAllowedPageUrl(uri.toString()) ||
        !RegExp(r'^/(user|channel)/subscribe_(add|remove)_json$')
            .hasMatch(uri.path)) {
      return (ok: false, message: '订阅参数尚未获取，请刷新主页');
    }
    try {
      final response = await _mediaDio.get<String>(
        uri.toString(),
        options: Options(
          headers: {..._buildHeaders(), 'X-Requested-With': 'XMLHttpRequest'},
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final decoded = _tryDecodeJsonObject(response.data ?? '');
      if (response.statusCode != 200 || !_confirmedWriteSuccess(decoded)) {
        return (
          ok: false,
          message: decoded?['message']?.toString() ?? '订阅失败，请检查登录状态后重试',
        );
      }
      _extraCache.clear();
      return (
        ok: true,
        message: uri.path.contains('_remove_') ? '已取消订阅' : '已订阅',
      );
    } catch (_) {
      return (ok: false, message: '网络异常，请重试');
    }
  }

  /// 最爱 / 取消最爱：`POST /video/favourite`。
  ///
  /// ⚠️ 端点已实测确认，但**请求体形态为按官网旧版 AJAX 惯例实现**（表单编码
  /// `video_id` + `token`，取消时附 `remove=1`），未经真机验证 —— 见回报说明。
  /// 返回记录型结果：`ok` 是否成功、`active` 操作后的最爱态、`message` 失败原因。
  Future<({bool ok, bool active, String message})> setFavourite({
    required String videoId,
    required String token,
    String favouriteUrl = '/video/favourite',
    required bool remove,
  }) async {
    if (!isLoggedIn) {
      return (ok: false, active: false, message: '请先登录 PornHub');
    }
    if (videoId.trim().isEmpty || token.trim().isEmpty) {
      return (ok: false, active: false, message: '缺少操作参数，请重进详情页');
    }
    final path = favouriteUrl.trim().isEmpty
        ? '/video/favourite'
        : favouriteUrl.trim();
    final url = path.startsWith('http') ? path : '$baseUrl$path';
    if (!_isAllowedPageUrl(url)) {
      return (ok: false, active: false, message: '非法的操作地址');
    }
    try {
      final resp = await _mediaDio.post<String>(
        url,
        data: <String, String>{
          'id': videoId.trim(),
          'token': token.trim(),
          'toggle': remove ? '0' : '1',
        },
        options: Options(
          headers: _buildHeaders(),
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final status = resp.statusCode ?? 0;
      // 302/401 说明会话失效，给出可操作的提示而不是笼统失败。
      if (status == 302 || status == 401 || status == 403) {
        return (ok: false, active: false, message: '登录已失效，请重新登录');
      }
      if (status >= 400) {
        return (ok: false, active: false, message: '操作失败（HTTP $status）');
      }
      final decoded = _tryDecodeJsonObject(resp.data ?? '');
      final success = _confirmedWriteSuccess(decoded);
      if (!success) {
        final msg = decoded?['message'];
        return (
          ok: false,
          active: !remove,
          message: (msg is String && msg.isNotEmpty) ? msg : '操作失败',
        );
      }
      _extraCache.removeWhere((_, value) => value.videoId == videoId);
      return (
        ok: true,
        active: decoded?['action'] == null
            ? !remove
            : decoded!['action'] == 'remove',
        message: remove ? '已取消最爱' : '已加入最爱',
      );
    } on DioException catch (e) {
      AppLogger.w('PornHub', '最爱操作失败: ${e.type.name}');
      return (ok: false, active: !remove, message: '网络异常，请稍后重试');
    } catch (e) {
      AppLogger.w('PornHub', '最爱操作异常: $e');
      return (ok: false, active: !remove, message: '操作异常：$e');
    }
  }

  /// 添加至片单：`POST /api/v2/playlist/video`，body(JSON) `{pid, vid, token}`。
  ///
  /// `vid` **必须是数字视频 id**（[PornHubDetailExtra.videoId]），不是 viewkey。
  Future<({bool ok, String message})> addVideoToPlaylist({
    required String pid,
    required String vid,
    required String token,
  }) async {
    if (!isLoggedIn) return (ok: false, message: '请先登录 PornHub');
    if (pid.trim().isEmpty || vid.trim().isEmpty || token.trim().isEmpty) {
      return (ok: false, message: '缺少片单参数，请重进详情页');
    }
    try {
      final resp = await _mediaDio.post<String>(
        '$baseUrl/api/v2/playlist/video',
        data: jsonEncode(<String, String>{
          'pid': pid.trim(),
          'vid': vid.trim(),
          'token': token.trim(),
        }),
        options: Options(
          headers: <String, String>{
            ..._buildHeaders(),
            'X-Requested-With': 'XMLHttpRequest',
          },
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status == 302 || status == 401 || status == 403) {
        return (ok: false, message: '登录已失效，请重新登录');
      }
      final decoded = _tryDecodeJsonObject(resp.data ?? '');
      final success =
          status == 200 &&
          (_confirmedWriteSuccess(decoded) || decoded?['toaster'] is Map);
      if (!success) {
        final msg = decoded?['message'] ?? decoded?['error'];
        return (
          ok: false,
          message: (msg is String && msg.isNotEmpty)
              ? msg
              : '添加失败（HTTP $status）',
        );
      }
      return (ok: true, message: '已添加到片单');
    } on DioException catch (e) {
      AppLogger.w('PornHub', '添加片单失败: ${e.type.name}');
      return (ok: false, message: '网络异常，请稍后重试');
    } catch (e) {
      AppLogger.w('PornHub', '添加片单异常: $e');
      return (ok: false, message: '操作异常：$e');
    }
  }

  /// 解析可能为 JSON 对象的响应体；非对象返回 null（不抛）。
  static Map<String, dynamic>? _tryDecodeJsonObject(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 色情明星列表：`/pornstars`
  ///
  /// 注意链接是 `/pornstar/<name>`（单数），**不是** `/model/<name>` ——
  /// 后者是视频卡片上的上传者链接，两者是不同的页面。
  ///
  /// 该页有**两种卡片结构**（实测 67 张里 5 张精选卡 + 43 张普通卡 + 19 张无链接）：
  ///
  /// | 字段 | 精选卡 | 普通卡 |
  /// |---|---|---|
  /// | 名字 | `a[alt]` | `img[alt]` |
  /// | 名次 | `.rankNumber` | `.rank_number` |
  /// | 头像 | `img[data-image]` | `img[data-thumb_url]` |
  ///
  /// 因此每个字段都按「两种结构依次尝试」取值，而不是只认一种。
  /// 名字优先用 `img[alt]`：它在两种结构里都是纯名字，而 `a[alt]` 偶尔会带上
  /// 搭档名（实测 `alt="Hailey Rose And Max Fills"` 对应 `/pornstar/hailey-rose`）。
  Future<List<PornHubStar>> fetchStars({int page = 1}) async {
    final html = await _getHtml(_pageUrl('/pornstars', page));
    if (html == null) return const <PornHubStar>[];
    final doc = html_parser.parse(html);
    final result = <PornHubStar>[];
    final seen = <String>{};

    for (final li in doc.querySelectorAll('li.performerCard')) {
      if (_isAdNode(li)) continue;
      final link = li.querySelector("a[href^='/pornstar/']");
      final href = link?.attributes['href'] ?? '';
      if (href.isEmpty) continue;

      final img = li.querySelector('img');
      // 逐级回退，每级都判空 —— 不用 `??` 串到底：`_text()` 返回非空 String，
      // 串在 `??` 链中间会让后面的分支永远不可达。
      var name = (img?.attributes['alt'] ?? '').trim();
      if (name.isEmpty) {
        name = _text(li.querySelector('.pornstarName')).trim();
      }
      if (name.isEmpty) {
        name = (link?.attributes['alt'] ?? '').trim();
      }
      if (name.isEmpty) {
        name = _text(link).trim();
      }
      if (name.isEmpty) continue;
      if (!seen.add(href)) continue;

      var rankText = _text(li.querySelector('.rankNumber')).trim();
      if (rankText.isEmpty) {
        rankText = _text(li.querySelector('.rank_number')).trim();
      }
      result.add(
        PornHubStar(
          name: name,
          url: href,
          rank: int.tryParse(rankText) ?? 0,
          avatarUrl:
              img?.attributes['data-image'] ??
              img?.attributes['data-thumb_url'] ??
              img?.attributes['src'],
        ),
      );
    }
    return result;
  }

  /// 某位明星的视频：`/pornstar/<name>`
  Future<VideoPage> fetchStarVideos(String starName, {int page = 1}) =>
      _fetchList('/pornstar/$starName', page);
}
