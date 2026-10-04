/// Hanime1 动漫网页数据源实现。
///
/// 极简纯 Dart 原生实现（依赖已有 Dio + html_parser，零多余组件）：
/// 1. 首页多板块结构化解析与 Hero 焦点大卡片（对齐官网移动端）；
/// 2. 订阅内容专区 (/subscriptions) 创作者头像圈与筛选器（对齐截图 2）；
/// 3. 分类番剧与多周期排行榜单分页抓取；
/// 4. 详情页原生 MP4 多清晰度（1080p/720p/480p）直链与防盗链 Token 提取；
/// 5. 自动集成 Hanime1AuthService 登录会话，支持云端订阅与个人记录同步。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_logger.dart';
import '../../services/background_decode_transformer.dart';
import '../../services/hanime1_auth_service.dart';
import '../models/hanime1_models.dart';
import '../models/video_item.dart';
import 'video_source.dart';

/// Hanime1 官方移动端分类体系
class Hanime1Categories {
  Hanime1Categories._();

  /// 番剧专区 11 大分类 (ChannelType.video)
  static const List<VideoCategory> genreList = <VideoCategory>[
    VideoCategory(
      id: 'h_all',
      name: '全部番剧',
      path: '/search?genre=全部',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_riban',
      name: '裏番',
      path: '/search?genre=裏番',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_paomian',
      name: '泡麵番',
      path: '/search?genre=泡麵番',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_motion',
      name: 'Motion Anime',
      path: '/search?genre=Motion Anime',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_3dcg',
      name: '3DCG',
      path: '/search?genre=3DCG',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_2.5d',
      name: '2.5D',
      path: '/search?genre=2.5D',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_2d',
      name: '2D動畫',
      path: '/search?genre=2D動畫',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_ai',
      name: 'AI生成',
      path: '/search?genre=AI生成',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_mmd',
      name: 'MMD',
      path: '/search?genre=MMD',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_cosplay',
      name: 'Cosplay',
      path: '/search?genre=Cosplay',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'h_preview',
      name: '新番預告',
      path: '/search?genre=新番預告',
      channel: ChannelType.video,
    ),
  ];

  /// 排行与上新榜单 (ChannelType.kedou)
  static const List<VideoCategory> rankingList = <VideoCategory>[
    VideoCategory(
      id: 'r_daily',
      name: '本日排行',
      path: '/search?sort=本日排行',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'r_weekly',
      name: '本週排行',
      path: '/search?sort=本週排行',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'r_monthly',
      name: '本月排行',
      path: '/search?sort=本月排行',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'r_latest_rel',
      name: '最新上市',
      path: '/search?sort=最新上市',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'r_latest_up',
      name: '最新上傳',
      path: '/search?sort=最新上傳',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'r_watching',
      name: '他們在看',
      path: '/search?sort=他們在看',
      channel: ChannelType.kedou,
    ),
  ];

  /// 个人云端中心 (ChannelType.vod)。
  ///
  /// ⚠️ 旧的写死路径有两个是 **404**：`/user_history` 与 `/user_likes`。
  /// 官网真实的用户区路径都挂在用户 id 下面（实测 uid=100001）：
  /// `/user/{uid}`、`/user/{uid}/histories`、`/user/{uid}/saves`、
  /// `/user/{uid}/likes`、`/user/{uid}/playlists`、`/user/{uid}/uploaded`、
  /// `/user/{uid}/uploading`，以及不依赖 id 的 `/subscriptions`。
  ///
  /// 所以这里改成**按 uid 动态生成**；未登录时只暴露不依赖 id 的「我的訂閱」，
  /// 免得再给出会 404 的入口。
  static List<VideoCategory> userListFor(String uid) {
    final id = uid.trim();
    return <VideoCategory>[
      const VideoCategory(
        id: 'u_subs',
        name: '我的訂閱',
        path: '/subscriptions',
        channel: ChannelType.vod,
      ),
      if (id.isNotEmpty) ...<VideoCategory>[
        VideoCategory(
          id: 'u_history',
          name: '觀看紀錄',
          path: '/user/$id/histories',
          channel: ChannelType.vod,
        ),
        VideoCategory(
          id: 'u_saves',
          name: '稍後觀看',
          path: '/user/$id/saves',
          channel: ChannelType.vod,
        ),
        VideoCategory(
          id: 'u_likes',
          name: '讚好的影片',
          path: '/user/$id/likes',
          channel: ChannelType.vod,
        ),
        VideoCategory(
          id: 'u_playlists',
          name: '播放清單',
          path: '/user/$id/playlists',
          channel: ChannelType.vod,
        ),
      ],
    ];
  }
}

class Hanime1CachedSaveOptions {
  const Hanime1CachedSaveOptions({
    required this.options,
    required this.hasCurrentVideoState,
  });

  final List<Hanime1SaveOption> options;
  final bool hasCurrentVideoState;
}

class Hanime1Source implements VideoSource {
  Hanime1Source({Dio? dio}) : _dio = dio ?? _createDio();

  @override
  String get id => 'hanime1';

  @override
  String get displayName => 'Hanime1 动漫';

  @override
  String? getCachedHlsUrl(String videoId) {
    if (_detailCache.containsKey(videoId)) {
      return _detailCache[videoId]?.video.hlsUrl;
    }
    return null;
  }

  static const String baseUrl = 'https://hanime1.me';

  /// 官网标签区里**不是标签**的两个「編輯標籤」按钮文案。
  ///
  /// 它们的 DOM（`.single-video-tag > a`）和真标签一模一样，只按结构筛会把它们
  /// 一起抓进来，在播放页渲染成伪标签 `#add` `#remove`。
  static const Set<String> _tagEditButtonNames = <String>{'add', 'remove'};

  final Dio _dio;
  final Map<String, ({VideoPage value, DateTime expires})> _searchPageCache =
      {};
  final Map<String, Future<VideoPage>> _searchInFlight = {};

  /// 视频详情缓存，避免高频切片重复解析
  final Map<String, VideoDetail> _detailCache = <String, VideoDetail>{};
  final Map<String, DateTime> _detailCacheTime = <String, DateTime>{};
  final Map<String, Future<VideoDetail?>> _detailInFlight =
      <String, Future<VideoDetail?>>{};
  final Map<String, String> _relatedHtmlCache = <String, String>{};
  final Map<String, List<Hanime1SaveOption>> _saveOptionsCache =
      <String, List<Hanime1SaveOption>>{};
  final Map<String, List<Hanime1SaveOption>> _saveCatalogCache =
      <String, List<Hanime1SaveOption>>{};
  static const int _maxRelatedHtmlCacheEntries = 12;
  final Map<String, List<VideoItem>> _relatedVideoCache =
      <String, List<VideoItem>>{};

  /// 播放页附加元数据缓存（点赞/评论数/上传者/标签计数/剧集清单）。
  ///
  /// 与 [_detailCache] 同生命周期：解析详情时一并写入，播放页直接读。
  final Map<String, Hanime1VideoExtra> _extraCache =
      <String, Hanime1VideoExtra>{};

  /// Playlist pages are loaded before their videos are opened. Keep that
  /// context so playback can show the user's selected playlist.
  final Map<String, Hanime1PlaylistPage> _playlistCache =
      <String, Hanime1PlaylistPage>{};

  /// 取播放页附加元数据。返回 null 表示该视频尚未解析过详情。
  Hanime1VideoExtra? getExtra(String videoId) => _extraCache[videoId];

  /// Parse recommendations after the player has started, keeping the first
  /// video frame independent from the large related-card section.
  Future<List<VideoItem>> fetchRelatedVideos(String videoId) async {
    final parsedUri = Uri.tryParse(videoId);
    var id = parsedUri?.queryParameters['v'] ?? videoId;
    if (id.startsWith('http')) {
      final segments = Uri.tryParse(id)?.pathSegments ?? const <String>[];
      if (segments.isNotEmpty) id = segments.last;
    }
    final cached = _relatedVideoCache[id];
    if (cached != null) {
      AppLogger.i(
        'Hanime1Source',
        '相关推荐命中解析缓存: video=$id count=${cached.length}',
      );
      return cached;
    }
    final html = _relatedHtmlCache[id];
    if (html == null || html.isEmpty) {
      AppLogger.w('Hanime1Source', '相关推荐缺少详情页 HTML 缓存: video=$id');
      return const <VideoItem>[];
    }
    final timer = Stopwatch()..start();
    final related = await Isolate.run<List<VideoItem>>(
      () => _parseHanimeRelatedCards(html, id),
    );
    _relatedHtmlCache.remove(id);
    _relatedVideoCache[id] = related;
    while (_relatedVideoCache.length > 3) {
      _relatedVideoCache.remove(_relatedVideoCache.keys.first);
    }
    AppLogger.i(
      'Hanime1Source',
      '相关推荐解析完成: video=$id html=${html.length} chars '
          'count=${related.length} ${timer.elapsedMilliseconds}ms',
    );
    return related;
  }

  static bool _formFlag(dom.Element? form, String name) {
    final value = form
        ?.querySelector('input[name="$name"]')
        ?.attributes['value']
        ?.trim()
        .toLowerCase();
    return value == '1' || value == 'true' || value == 'yes' || value == 'on';
  }

  /// 使用官网自己的表单和登录 Cookie 提交操作，返回服务器渲染的新按钮。
  Future<dom.Document?> _submitWatchForm(
    String videoId,
    String formId,
    String responseKey, {
    String? vote,
  }) async {
    try {
      if (!Hanime1AuthService.to.isLoggedIn.value) {
        AppLogger.w('Hanime1Source', '官网操作失败：未登录');
        return null;
      }
      final watchUrl = '$baseUrl/watch?v=${Uri.encodeQueryComponent(videoId)}';
      final page = await _dio.get<String>(
        watchUrl,
        options: Options(headers: _buildHeaders()),
      );
      if (page.statusCode != 200) {
        AppLogger.w('Hanime1Source', '官网操作失败：页面状态 ${page.statusCode}');
        return null;
      }
      final form = html_parser.parse(page.data ?? '').querySelector(formId);
      if (form == null) {
        AppLogger.w('Hanime1Source', '官网操作失败：表单不存在 $formId');
        return null;
      }

      final action = Uri.parse(baseUrl)
          .resolve(form.attributes['action'] ?? '');
      if (action.host != Uri.parse(baseUrl).host || action.scheme != 'https') {
        AppLogger.w('Hanime1Source', '官网操作失败：表单目标无效');
        return null;
      }
      final fields = <String, String>{};
      for (final input in form.querySelectorAll('input[name]')) {
        final name = input.attributes['name'] ?? '';
        if (name.isNotEmpty) fields[name] = input.attributes['value'] ?? '';
      }
      if ((fields['_token'] ?? '').isEmpty) {
        AppLogger.w('Hanime1Source', '官网操作失败：页面没有 CSRF 令牌');
        return null;
      }
      if (vote != null) fields['like-is-positive'] = vote;

      final method = (form.attributes['method'] ?? 'GET').toUpperCase();
      final response = await _sendSiteForm(
        action,
        method: method,
        fields: fields,
        referer: watchUrl,
      );
      if (response == null) return null;
      if (response.statusCode != 200 || response.data is! Map) {
        final body = response.data?.toString() ?? '';
        final reason = body.contains('CSRF')
            ? 'CSRF'
            : body.contains('Cloudflare') || body.contains('cloudflare')
            ? 'Cloudflare'
            : body.contains('Forbidden')
            ? 'Forbidden'
            : 'unknown';
        AppLogger.w(
          'Hanime1Source',
          '官网操作失败：响应状态 ${response.statusCode}，原因提示 $reason',
        );
        return null;
      }
      final html = (response.data as Map)[responseKey];
      if (html is! String || html.isEmpty) {
        AppLogger.w('Hanime1Source', '官网操作失败：响应缺少 $responseKey');
        return null;
      }
      _detailCache.remove(videoId);
      _detailCacheTime.remove(videoId);
      return html_parser.parse(html);
    } catch (e) {
      AppLogger.w('Hanime1Source', '提交官网操作失败: $e');
      return null;
    }
  }

  Future<bool?> toggleArtistSubscription(String videoId) async {
    final doc = await _submitWatchForm(
      videoId,
      '#video-subscribe-form',
      'subscribeBtn',
    );
    final label = doc?.querySelector('#video-subscribe-btn')?.text.trim();
    if (label == null || label.isEmpty) return null;
    return label.contains('已');
  }

  Future<Hanime1VoteState?> voteVideo(
    String videoId, {
    required bool positive,
  }) async {
    final doc = await _submitWatchForm(
      videoId,
      '#video-like-form',
      'likeBtn',
      vote: positive ? '1' : '0',
    );
    final form = doc?.querySelector('#video-like-form');
    if (form == null) return null;
    final button = form.querySelector('#video-like-btn');
    final text = button?.text ?? '';
    return Hanime1VoteState(
      liked: _formFlag(form, 'like-status'),
      disliked: _formFlag(form, 'unlike-status'),
      percent: RegExp(r'(\d+(?:\.\d+)?%)').firstMatch(text)?.group(1) ?? '',
      count: RegExp(r'\((\d+)\)').firstMatch(text)?.group(1) ?? '',
    );
  }

  String _normalizeSaveVideoId(String videoId) {
    var id = videoId.trim();
    final uri = Uri.tryParse(id);
    if (id.contains('v=')) {
      id = uri?.queryParameters['v'] ?? id;
    } else if (id.startsWith('http')) {
      final segments = uri?.pathSegments ?? const <String>[];
      if (segments.isNotEmpty) id = segments.last;
    }
    return id;
  }

  String _saveAccountCacheId() {
    final auth = Hanime1AuthService.to;
    final userId = auth.userId.value.trim();
    final email = auth.userEmail.value.trim().toLowerCase();
    final username = auth.username.value.trim();
    final identity = userId.isNotEmpty
        ? userId
        : email.isNotEmpty
        ? email
        : username;
    return base64Url.encode(utf8.encode(identity));
  }

  String _saveOptionsCacheKey(String videoId) =>
      '${_saveAccountCacheId()}:${_normalizeSaveVideoId(videoId)}';

  String _saveOptionsStorageKey(String videoId) =>
      'hanime1_save_options_v1_${_saveAccountCacheId()}_${base64Url.encode(utf8.encode(_normalizeSaveVideoId(videoId)))}';

  String _saveCatalogStorageKey() =>
      'hanime1_playlist_catalog_v1_${_saveAccountCacheId()}';

  List<Hanime1SaveOption> _decodeCachedSaveOptions(
    String? encoded, {
    required bool includeSavedState,
  }) {
    if (encoded == null || encoded.isEmpty) return <Hanime1SaveOption>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return <Hanime1SaveOption>[];
      final options = <Hanime1SaveOption>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final id = item['id'];
        final title = item['title'];
        if (id is! String || title is! String || id.isEmpty || title.isEmpty) {
          continue;
        }
        options.add(
          Hanime1SaveOption(
            id: id,
            title: title,
            isSaved: includeSavedState && item['isSaved'] == true,
            isWatchLater: item['isWatchLater'] == true,
          ),
        );
      }
      return options;
    } catch (_) {
      return <Hanime1SaveOption>[];
    }
  }

  String _encodeCachedSaveOptions(
    List<Hanime1SaveOption> options, {
    required bool includeSavedState,
  }) => jsonEncode(
    options
        .map(
          (option) => <String, Object>{
            'id': option.id,
            'title': option.title,
            'isSaved': includeSavedState && option.isSaved,
            'isWatchLater': option.isWatchLater,
          },
        )
        .toList(),
  );

  void _rememberVideoSaveOptions(
    String videoId,
    List<Hanime1SaveOption> options,
  ) {
    final accountId = _saveAccountCacheId();
    _saveOptionsCache[_saveOptionsCacheKey(videoId)] =
        List<Hanime1SaveOption>.of(options);
    final catalog = options
        .map((option) => option.copyWith(isSaved: false))
        .toList();
    _saveCatalogCache[accountId] = catalog;
    unawaited(_persistVideoSaveOptions(videoId, options, catalog));
  }

  Future<void> _persistVideoSaveOptions(
    String videoId,
    List<Hanime1SaveOption> options,
    List<Hanime1SaveOption> catalog,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _saveOptionsStorageKey(videoId),
        _encodeCachedSaveOptions(options, includeSavedState: true),
      );
      await prefs.setString(
        _saveCatalogStorageKey(),
        _encodeCachedSaveOptions(catalog, includeSavedState: false),
      );
    } catch (e) {
      AppLogger.w('Hanime1Source', '保存播放清单本地缓存失败: $e');
    }
  }

  /// 读取当前视频缓存的清单，供弹层先行展示，再于后台刷新官网状态。
  Hanime1CachedSaveOptions? getCachedVideoSaveOptions(String videoId) {
    if (!Hanime1AuthService.to.isLoggedIn.value) return null;
    final cacheKey = _saveOptionsCacheKey(videoId);
    final cachedOptions = _saveOptionsCache[cacheKey];
    if (cachedOptions != null) {
      return Hanime1CachedSaveOptions(
        options: List<Hanime1SaveOption>.of(cachedOptions),
        hasCurrentVideoState: true,
      );
    }

    final catalog = _saveCatalogCache[_saveAccountCacheId()];
    if (catalog == null) return null;
    return Hanime1CachedSaveOptions(
      options: catalog
          .map((option) => option.copyWith(isSaved: false))
          .toList(),
      hasCurrentVideoState: false,
    );
  }

  /// 从磁盘读取上次清单；清单目录可先展示，勾选状态由官网刷新。
  Future<Hanime1CachedSaveOptions?> loadCachedVideoSaveOptions(
    String videoId,
  ) async {
    final inMemory = getCachedVideoSaveOptions(videoId);
    if (inMemory != null) return inMemory;
    if (!Hanime1AuthService.to.isLoggedIn.value) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final exact = _decodeCachedSaveOptions(
        prefs.getString(_saveOptionsStorageKey(videoId)),
        includeSavedState: true,
      );
      if (exact.isNotEmpty) {
        _saveOptionsCache[_saveOptionsCacheKey(videoId)] = exact;
        return Hanime1CachedSaveOptions(
          options: exact,
          hasCurrentVideoState: true,
        );
      }

      final accountId = _saveAccountCacheId();
      var catalog = _saveCatalogCache[accountId];
      if (catalog == null) {
        catalog = _decodeCachedSaveOptions(
          prefs.getString(_saveCatalogStorageKey()),
          includeSavedState: false,
        );
        if (catalog.isNotEmpty) _saveCatalogCache[accountId] = catalog;
      }
      if (catalog.isEmpty) return null;
      return Hanime1CachedSaveOptions(
        options: catalog
            .map((option) => option.copyWith(isSaved: false))
            .toList(),
        hasCurrentVideoState: false,
      );
    } catch (e) {
      AppLogger.w('Hanime1Source', '读取播放清单本地缓存失败: $e');
      return null;
    }
  }

  /// 读取官网「儲存」弹层中的清单及当前勾选状态。
  Future<List<Hanime1SaveOption>?> fetchVideoSaveOptions(String videoId) async {
    if (!Hanime1AuthService.to.isLoggedIn.value) {
      AppLogger.w('Hanime1Source', '读取播放清单：未登录，跳过');
      return null;
    }
    try {
      final url = '$baseUrl/watch?v=${Uri.encodeQueryComponent(videoId)}';
      final response = await _dio.get<String>(
        url,
        options: Options(headers: _buildHeaders()),
      );
      if (response.statusCode != 200) {
        AppLogger.w(
          'Hanime1Source',
          '读取播放清单：watch 页状态 ${response.statusCode}（非 200）',
        );
        return null;
      }
      final document = html_parser.parse(response.data ?? '');
      final form = document.querySelector('#video-save-form');
      if (form == null) {
        AppLogger.w(
          'Hanime1Source',
          '读取播放清单：页面没有 #video-save-form（可能未登录或官网改版）',
        );
        return null;
      }
      final options = _parseSaveOptions(form);
      _rememberVideoSaveOptions(videoId, options);
      return options;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '读取官网播放清单失败: $e', e, stack);
      return null;
    }
  }

  List<Hanime1SaveOption> _parseSaveOptions(dom.Element form) {
    final options = <Hanime1SaveOption>[];
    for (final input in form.querySelectorAll('input.playlist-checkbox')) {
      final id = (input.attributes['id'] ?? '').trim();
      if (id.isEmpty) continue;
      final parent = input.parent;
      final label = parent is dom.Element ? parent : null;
      final title = (label?.querySelector('span')?.text ?? label?.text ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (title.isEmpty) continue;
      options.add(
        Hanime1SaveOption(
          id: id,
          title: title,
          isSaved: input.attributes.containsKey('checked'),
          isWatchLater: id == 'save',
        ),
      );
    }
    return options;
  }

  /// 按官网 checkbox 的状态切换规则收藏/取消收藏，并重新读取服务端状态确认。
  Future<bool> setVideoSavedInPlaylist(
    String videoId,
    String playlistId, {
    required bool saved,
  }) async {
    if (!Hanime1AuthService.to.isLoggedIn.value) {
      AppLogger.w('Hanime1Source', '更新官网播放清单失败：未登录');
      return false;
    }
    try {
      final watchUrl = '$baseUrl/watch?v=${Uri.encodeQueryComponent(videoId)}';
      final page = await _dio.get<String>(
        watchUrl,
        options: Options(headers: _buildHeaders()),
      );
      if (page.statusCode != 200) return false;
      final document = html_parser.parse(page.data ?? '');
      final form = document.querySelector('#video-save-form');
      if (form == null) return false;
      final currentOptions = _parseSaveOptions(form);
      // Refresh the local confirmed state from the live page before applying a
      // user change, so a failed update can roll back to the server's latest value.
      _rememberVideoSaveOptions(videoId, currentOptions);
      Hanime1SaveOption? option;
      for (final item in currentOptions) {
        if (item.id == playlistId) {
          option = item;
          break;
        }
      }
      if (option == null) {
        AppLogger.w('Hanime1Source', '更新官网播放清单失败：找不到清单 $playlistId');
        return false;
      }
      if (option.isSaved == saved) return true;

      final fields = <String, String>{};
      for (final input in form.querySelectorAll('input[name]')) {
        final name = input.attributes['name'] ?? '';
        if (name.isNotEmpty) fields[name] = input.attributes['value'] ?? '';
      }
      final pageUserId =
          document
              .querySelector('#playlist-user-id')
              ?.attributes['value']
              ?.trim() ??
          '';
      final userId = pageUserId.isNotEmpty
          ? pageUserId
          : Hanime1AuthService.to.userId.value.trim();
      final formVideoId =
          document
              .querySelector('#playlist-video-id')
              ?.attributes['value']
              ?.trim() ??
          fields['playlist-video-id']?.trim() ??
          videoId;
      if ((fields['_token'] ?? '').isEmpty ||
          userId.isEmpty ||
          formVideoId.isEmpty) {
        AppLogger.w(
          'Hanime1Source',
          '更新官网播放清单失败：缺少字段 '
              'token=${(fields['_token'] ?? '').isNotEmpty} '
              'pageUser=${pageUserId.isNotEmpty} '
              'sessionUser=${Hanime1AuthService.to.userId.value.isNotEmpty} '
              'video=${formVideoId.isNotEmpty}',
        );
        return false;
      }

      // Match Hanime1's app.js checkbox handler: it sends these four fields.
      fields.remove('playlist-video-id');
      fields['input_id'] = playlistId;
      fields['user_id'] = userId;
      fields['video_id'] = formVideoId;
      fields['is_checked'] = saved.toString();
      final action = Uri.parse(baseUrl)
          .resolve(form.attributes['action'] ?? '');
      if (action.host != Uri.parse(baseUrl).host || action.scheme != 'https') {
        return false;
      }
      final response = await _sendSiteForm(
        action,
        method: (form.attributes['method'] ?? 'GET').toUpperCase(),
        fields: fields,
        referer: watchUrl,
      );
      if (response == null || response.statusCode != 200) {
        AppLogger.w(
          'Hanime1Source',
          '更新官网播放清单失败：响应状态 ${response?.statusCode ?? "null"} '
              'path=${response?.realUri.path ?? action.path}',
        );
        return false;
      }

      final refreshed = await fetchVideoSaveOptions(videoId);
      bool? serverState;
      for (final item in refreshed ?? const <Hanime1SaveOption>[]) {
        if (item.id == playlistId) {
          serverState = item.isSaved;
          break;
        }
      }
      AppLogger.i(
        'Hanime1Source',
        '播放清单回读：requested=$saved actual=$serverState found=${serverState != null}',
      );
      if (serverState == saved) {
        _detailCache.remove(videoId);
        _detailCacheTime.remove(videoId);
        return true;
      }
      return false;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '更新官网播放清单失败: $e', e, stack);
      return false;
    }
  }

  /// 通过官网 `#video-create-playlist-form` 创建清单；官网会同时把当前视频加入新清单。
  Future<bool> createPlaylistForVideo(String videoId, String title) async {
    if (!Hanime1AuthService.to.isLoggedIn.value || title.trim().isEmpty) {
      return false;
    }
    try {
      final watchUrl = '$baseUrl/watch?v=${Uri.encodeQueryComponent(videoId)}';
      final page = await _dio.get<String>(
        watchUrl,
        options: Options(headers: _buildHeaders()),
      );
      if (page.statusCode != 200) return false;
      final form = html_parser
          .parse(page.data ?? '')
          .querySelector('#video-create-playlist-form');
      if (form == null) return false;
      final fields = <String, String>{};
      for (final input in form.querySelectorAll('input[name]')) {
        final name = input.attributes['name'] ?? '';
        if (name.isNotEmpty) fields[name] = input.attributes['value'] ?? '';
      }
      fields['playlist-title'] = title.trim();
      if ((fields['_token'] ?? '').isEmpty ||
          (fields['create-playlist-video-id'] ?? '').isEmpty) {
        return false;
      }
      final action = Uri.parse(baseUrl)
          .resolve(form.attributes['action'] ?? '');
      if (action.host != Uri.parse(baseUrl).host || action.scheme != 'https') {
        return false;
      }
      final response = await _sendSiteForm(
        action,
        method: (form.attributes['method'] ?? 'GET').toUpperCase(),
        fields: fields,
        referer: watchUrl,
      );
      if (response == null || response.statusCode != 200) return false;
      final refreshed = await fetchVideoSaveOptions(videoId);
      return refreshed?.any(
            (item) => item.title == title.trim() && item.isSaved,
          ) ??
          false;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '创建官网播放清单失败: $e', e, stack);
      return false;
    }
  }

  Future<Response<dynamic>?> _sendSiteForm(
    Uri action, {
    required String method,
    required Map<String, String> fields,
    required String referer,
  }) async {
    final headers = <String, String>{
      ..._buildHeaders(),
      'Referer': referer,
      'Origin': baseUrl,
      // ⚠️ 这里**故意不设 User-Agent**，不要加回来。
      //
      // 实测（同一台机器 / 同一个 Dio / 同一 TLS 指纹 / 同一 IP，只改 UA）：
      //   GET  /         不带 UA（Dart 默认，与所有 GET 一致）→ 200
      //   GET  /         带下面那个 Chrome UA                  → 403 Cloudflare 拦截页
      //   POST /register 带 Chrome UA（先发，排除限流）        → 403（同一个 5485 字节拦截页）
      //   POST /register 不带 UA（后发）                       → 419（到达 Laravel，仅 CSRF 失效）
      //
      // 原因：UA 声称是 Chrome，但 TLS 指纹是 Dart 的，属于典型 bot 特征，
      // Cloudflare 会直接拦。而本工程所有 GET（详情/搜索/评论）都没设 UA，所以一直正常。
      //
      // 本方法是订阅 / 播放清单勾选 / 点赞等**所有写操作**的唯一出口，
      // 此前 UA 不一致导致这些功能整体不可用（GET 正常、一点就失败）。
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    };
    // BackgroundDecodeTransformer serializes Map request bodies as JSON. These
    // endpoints expect application/x-www-form-urlencoded, so encode the fields
    // before passing them to Dio (which then leaves String bodies unchanged).
    final formBody = fields.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    // These website forms are intercepted by Hanime1's JavaScript and submitted
    // as AJAX POSTs even when the HTML form declares GET. The server confirms
    // this with Allow: POST; sending GET causes HTTP 405.
    final requestMethod = method.toUpperCase() == 'GET'
        ? 'POST'
        : method.toUpperCase();
    AppLogger.i(
      'Hanime1Source',
      '官网写请求：method=$requestMethod（网页表单声明 $method） path=${action.path}',
    );
    final response = await _dio.request<dynamic>(
      action.toString(),
      data: requestMethod == 'GET' ? null : formBody,
      queryParameters: requestMethod == 'GET' ? fields : null,
      options: Options(
        method: requestMethod,
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.json,
        headers: headers,
      ),
    );
    AppLogger.i(
      'Hanime1Source',
      '官网写响应：status=${response.statusCode} path=${response.realUri.path} '
          'allow=${response.headers.value("allow") ?? ""} '
          'contentType=${response.headers.value(Headers.contentTypeHeader) ?? ""}',
    );
    return response;
  }

  /// 抓取官网用户清单详情，包括排序、封面、创建者和清单内视频。
  Future<Hanime1PlaylistPage?> fetchPlaylist(
    String playlistId, {
    int page = 1,
    String sort = 'latest',
  }) async {
    final id = playlistId.trim();
    if (id.isEmpty) return null;
    try {
      final uri = Uri.parse('$baseUrl/playlist').replace(
        queryParameters: {
          'list': id,
          'sort': sort,
          if (page > 1) 'page': '$page',
        },
      );
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(headers: _buildHeaders()),
      );
      if (response.statusCode != 200) return null;
      final parsed = _parsePlaylistPage(
        response.data ?? '',
        id,
        page: page,
        sort: sort,
      );
      final previous = _playlistCache[id];
      if (page == 1 || previous == null || previous.sort != parsed.sort) {
        _playlistCache[id] = parsed;
      } else {
        final seen = previous.items.map((item) => item.id).toSet();
        _playlistCache[id] = Hanime1PlaylistPage(
          id: parsed.id,
          title: parsed.title,
          creator: parsed.creator,
          creatorPath: parsed.creatorPath,
          coverUrl: parsed.coverUrl,
          videoCount: parsed.videoCount,
          viewsText: parsed.viewsText,
          items: <VideoItem>[
            ...previous.items,
            ...parsed.items.where((item) => seen.add(item.id)),
          ],
          page: parsed.page,
          hasMore: parsed.hasMore,
          sort: parsed.sort,
          totalPages: parsed.totalPages,
        );
      }
      return parsed;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '抓取官网播放清单失败: $e', e, stack);
      return null;
    }
  }

  Hanime1PlaylistPage _parsePlaylistPage(
    String html,
    String id, {
    required int page,
    required String sort,
  }) {
    final doc = html_parser.parse(html);
    final creator = doc.querySelector('.playlist-author-info a');
    final stats = doc.querySelector('.playlist-stats')?.text ?? '';
    final count = RegExp(r'(\d[\d,]*)\s*部影片').firstMatch(stats)?.group(1) ?? '';
    final views =
        RegExp(r'觀看次數[:：]\s*([^•]+)').firstMatch(stats)?.group(1)?.trim() ?? '';
    final items = <VideoItem>[];
    final seen = <String>{};
    for (final card in doc.querySelectorAll(
      '.playlist-video-list .playlist-video-card, .playlist-video-card',
    )) {
      final item = _parseSingleCard(card);
      if (item != null && seen.add(item.id)) items.add(item);
    }
    final activeSortHref = doc
        .querySelector('.playlist-video-list .filter-pill.active')
        ?.attributes['href'];
    final currentSort = activeSortHref == null
        ? sort
        : Uri.tryParse(activeSortHref)?.queryParameters['sort'] ?? sort;
    final hasNext =
        doc.querySelector(
          '.playlist-pagination a[rel="next"], '
          '.search-pagination a[rel="next"], '
          '.playlist-video-list a[rel="next"], '
          '.pagination a[rel="next"]',
        ) !=
        null;
    return Hanime1PlaylistPage(
      id: id,
      title: doc.querySelector('.playlist-title')?.text.trim() ?? '',
      creator: creator?.text.trim() ?? '',
      creatorPath: _relativePath(creator?.attributes['href'] ?? ''),
      coverUrl:
          doc.querySelector('.playlist-main-thumbnail')?.attributes['src'] ??
          '',
      videoCount: count,
      viewsText: views,
      items: items,
      page: page,
      hasMore: hasNext,
      totalPages: _extractTotalPagesFromDocument(doc, page, hasNext),
      sort: currentSort,
    );
  }

  /// 评论缓存（videoId -> 一级评论）。
  ///
  /// 播放页的「評論」Tab 每次切回来都会重新挂载评论组件，
  /// 没有缓存的话每次切换都要重下 ~90KB 的评论 HTML，体感很卡。
  final Map<String, List<Hanime1Comment>> _commentCache =
      <String, List<Hanime1Comment>>{};

  /// 回复缓存（commentId -> 该条评论的回复）。
  final Map<String, List<Hanime1Comment>> _replyCache =
      <String, List<Hanime1Comment>>{};

  /// 已缓存的回复（未加载过返回 null，区别于「加载过但没有回复」的空列表）。
  List<Hanime1Comment>? getCachedReplies(String commentId) =>
      _replyCache[commentId];

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Referer': '$baseUrl/',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    // 把响应体的 UTF-8 解码挪到后台 isolate。
    // dio 默认实现是**主 isolate 同步** utf8.decode —— 真机 ANR 主线程栈顶就是它
    // （见 background_decode_transformer.dart 里的取证）。详情页 HTML 动辄几百 KB，
    // 启动阶段几十次请求叠加起来足以顶满 ANR 的 5 秒门槛。
    dio.transformer = BackgroundDecodeTransformer();
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final requestHasLoginCookie = response.requestOptions.headers.entries
              .any(
                (entry) =>
                    entry.key.toLowerCase() == 'cookie' &&
                    entry.value is String &&
                    (entry.value as String).isNotEmpty,
              );
          if (requestHasLoginCookie) {
            try {
              Hanime1AuthService.to.updateSessionCookies(
                response.headers['set-cookie'],
              );
            } catch (e) {
              AppLogger.w('Hanime1Auth', '同步官网会话 Cookie 失败: $e');
            }
          }
          handler.next(response);
        },
      ),
    );
    return dio;
  }

  /// 构造请求头。
  ///
  /// [anonymous] 为 true 时**不携带登录 Cookie** —— 专供后台预取使用。
  ///
  /// 为什么需要它：官网的觀看紀錄是**服务端在收到 watch 页请求时记录**的
  /// （`app.js` 里没有任何客户端上报：无 sendBeacon / fetch / 播放进度监听，
  /// 只有订阅、点赞、收藏、评论这几类表单）。因此后台预取若带上登录态，
  /// 就会给用户刷出一堆**从没点开过的**观看记录。
  /// 需要记录观看历史请走 [markWatched]。
  Map<String, String> _buildHeaders({bool anonymous = false}) {
    final headers = <String, String>{
      'Referer': '$baseUrl/',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    if (anonymous) return headers;
    try {
      final auth = Hanime1AuthService.to;
      final cookie = auth.cookieHeader;
      if (cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
      }
    } catch (e) {
      // 此处失败会让**后续所有请求静默变成未登录态**（用户侧表现为「明明登录了，
      // 内容却是游客视角」），此前无任何日志可查。控制流不变：仍然只发不带 Cookie 的请求。
      AppLogger.w('Hanime1', '读取认证 Cookie 失败，本次请求将以未登录态发出: $e');
    }
    return headers;
  }

  @override
  List<VideoCategory> categoriesForChannel(ChannelType channel) {
    switch (channel) {
      case ChannelType.home:
        return const [];
      case ChannelType.video:
        return Hanime1Categories.genreList;
      case ChannelType.kedou:
        return Hanime1Categories.rankingList;
      case ChannelType.vod:
        // 用户区路径挂在 uid 下（见 [Hanime1Categories.userListFor]），
        // 未登录时 uid 为空，只返回不依赖 id 的「我的訂閱」。
        String uid = '';
        try {
          uid = Hanime1AuthService.to.userId.value;
        } catch (e) {
          // 降级为 uid 为空（未登录路径）。这是设计内的回退，但静默会让
          // 「用户区列表少了内容」无从排查，故留一条 W。控制流不变。
          AppLogger.w('Hanime1', '读取 userId 失败，用户区路径退化为不含 id: $e');
        }
        return Hanime1Categories.userListFor(uid);
    }
  }

  @override
  Future<List<String>> fetchHotKeywords() async {
    return const [
      '裏番',
      '3DCG',
      '無碼',
      '同人作品',
      '1080p',
      '人妻',
      '御姐',
      '巨乳',
      '原神',
      '崩壞',
      'ASMR',
      'Cosplay',
      '女僕',
      '純愛',
    ];
  }

  @override
  Future<List<String>> fetchTags() async => fetchHotKeywords();

  /// 抓取并解析移动端首页完整结构化数据（包含 Hero Banner、分类胶囊和 12 大板块）
  Future<Hanime1HomeData?> fetchHomeStructured() async {
    try {
      AppLogger.i('Hanime1Source', '拉取首页结构化数据: $baseUrl/');
      final resp = await _dio.get<String>(
        '$baseUrl/',
        options: Options(headers: _buildHeaders()),
      );

      final html = resp.data ?? '';
      final doc = await Isolate.run(() => html_parser.parse(html));

      // 1. 分类胶囊标签
      final genreTabs = <String>[];
      final genreValues = <String, String>{};
      // Each official category is its own wrapper, with one link inside.
      // Use the link's query value because the visible label may use different
      // characters (e.g. 里番 -> 裏番, 泡面番 -> 泡麵番).
      for (final a in doc.querySelectorAll('.home-genre-tabs-wrapper a')) {
        final label = a.text.trim();
        final uri = Uri.tryParse(a.attributes['href'] ?? '');
        final genre = uri?.queryParameters['genre']?.trim() ?? '';
        if (label.isEmpty ||
            genre.isEmpty ||
            (uri!.hasAuthority && uri.host != Uri.parse(baseUrl).host) ||
            genreValues.containsKey(label)) {
          continue;
        }
        genreTabs.add(label);
        genreValues[label] = genre;
      }

      // 2. 移动端 Hero 焦点卡片
      Hanime1HeroItem? hero;
      dom.Element? heroContainer = doc.querySelector('div.hidden-md.hidden-lg');
      if (heroContainer == null || !heroContainer.text.contains('播放')) {
        heroContainer = doc.querySelector('#home-banner-wrapper');
      }

      if (heroContainer != null) {
        final h1 = heroContainer.querySelector('h1')?.text.trim() ?? '';
        final h4 = heroContainer.querySelector('h4')?.text.trim() ?? '';
        final tags = <String>[];
        for (final s in heroContainer.querySelectorAll('span')) {
          final t = s.text.trim();
          if (t.isNotEmpty &&
              !t.contains('•') &&
              t.length < 15 &&
              t != 'play_arrow' &&
              t != 'info') {
            tags.add(t);
          }
        }

        String coverUrl = '';
        String heroId = '';
        for (final img in heroContainer.querySelectorAll('img')) {
          final src = img.attributes['src'] ?? '';
          if (src.contains('thumbnail')) {
            coverUrl = src;
            final m = RegExp(r'thumbnail/(\d+)').firstMatch(src);
            if (m != null) heroId = m.group(1)!;
            break;
          }
        }

        // 如果在当前容器内未找到图片，从前置同级元素寻找
        if (coverUrl.isEmpty && heroContainer.parent != null) {
          for (final img in heroContainer.parent!.querySelectorAll('img')) {
            final src = img.attributes['src'] ?? '';
            if (src.contains('thumbnail')) {
              coverUrl = src;
              final m = RegExp(r'thumbnail/(\d+)').firstMatch(src);
              if (m != null) heroId = m.group(1)!;
              break;
            }
          }
        }

        if (h1.isNotEmpty && heroId.isNotEmpty) {
          hero = Hanime1HeroItem(
            id: heroId,
            title: h1,
            subtitle: h4,
            tags: tags,
            coverUrl: coverUrl,
            watchUrl: '$baseUrl/watch?v=$heroId',
          );
        }
      }

      // 3. 首页多板块 (Section Rows)
      final sections = <Hanime1Section>[];
      final headerElements = doc.querySelectorAll('a.horizontal-row-title');

      for (final a in headerElements) {
        var secTitle = a.querySelector('h3')?.text.trim() ?? a.text.trim();
        // 清理类似 "最新上市查看更多arrow_forward_ios" 尾缀
        secTitle = secTitle
            .replaceAll('查看更多', '')
            .replaceAll('arrow_forward_ios', '')
            .trim();
        final href = a.attributes['href'] ?? '';

        // 寻找跟随此标题的视频卡片容器
        dom.Element? rowWrap;
        dom.Element? next = a.nextElementSibling;
        while (next != null) {
          if (next.classes.any(
                (c) =>
                    c.contains('home-rows-videos-wrapper') ||
                    c.contains('row') ||
                    c.contains('horizontal-row'),
              ) ||
              next.querySelector('.video-item-container') != null) {
            rowWrap = next;
            break;
          }
          next = next.nextElementSibling;
        }

        rowWrap ??= a.parent?.querySelector(
          '.home-rows-videos-wrapper, .horizontal-row',
        );

        final items = <VideoItem>[];
        if (rowWrap != null) {
          for (final cardEl in rowWrap.querySelectorAll(
            '.video-item-container',
          )) {
            final item = _parseSingleCard(cardEl);
            if (item != null) items.add(item);
          }
        }

        if (secTitle.isNotEmpty && items.isNotEmpty) {
          sections.add(
            Hanime1Section(title: secTitle, morePath: href, items: items),
          );
        }
      }

      return Hanime1HomeData(
        genreTabs: genreTabs,
        genreValues: genreValues,
        hero: hero,
        sections: sections,
      );
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取首页结构化数据异常: $e', e, stack);
      return null;
    }
  }

  /// 抓取并解析订阅页结构化数据（创作者圆圈 + 筛选器 + 视频列表）
  Future<Hanime1SubscriptionData> fetchSubscriptionsData({
    int page = 1,
    String? query,
    String genre = '',
    String sort = '',
    String date = '',
    String duration = '',
    List<String> tags = const <String>[],
    bool broad = false,
  }) async {
    try {
      var url = '$baseUrl/subscriptions';
      final params = <String>[];
      if (query != null && query.isNotEmpty) {
        params.add('query=${Uri.encodeComponent(query)}');
      }
      if (genre.isNotEmpty) params.add('genre=${Uri.encodeComponent(genre)}');
      if (sort.isNotEmpty) params.add('sort=${Uri.encodeComponent(sort)}');
      if (date.isNotEmpty) params.add('date=${Uri.encodeComponent(date)}');
      if (duration.isNotEmpty) {
        params.add('duration=${Uri.encodeComponent(duration)}');
      }
      for (final tag in tags) {
        if (tag.isNotEmpty) {
          params.add('tags%5B%5D=${Uri.encodeComponent(tag)}');
        }
      }
      if (broad && tags.isNotEmpty) params.add('broad=on');
      if (page > 1) {
        params.add('page=$page');
      }
      if (params.isNotEmpty) {
        url += '?${params.join('&')}';
      }

      AppLogger.i('Hanime1Source', '拉取订阅内容: $url');
      final resp = await _dio.get<String>(
        url,
        options: Options(headers: _buildHeaders()),
      );

      final html = resp.data ?? '';
      final doc = html_parser.parse(html);

      // 1. 创作者圆形头像列表
      //
      // ⚠️ 创作者圆圈**根本没有 `<a>` 标签** —— 它是纯 div 卡片。早期实现用
      // `a[href*="/search?query="]` 去抓，命中的其实是**每张视频卡片里的作者链接**，
      // 于是圆圈列表退化成「作者名去重列表」、并且全都没有头像
      // （真机实测：只有图标和文字，见 .perf/t_sub.png）。
      //
      // 官网真实结构：
      //   .subscriptions-artist-card                        ← 一个圆圈
      //     .card-mobile-panel.inner > div
      //       <img src="…/card_artist_background.jpg">      ← 底层默认背景图
      //       <img src="https://c.fantia.jp/…/thumb_webp…"> ← 上层真实头像
      //     .card-mobile-title.search-artist-title          ← 创作者名
      // 页面上的「全部」是另一个独立元素：`a[href="/subscribe/artist"]`。
      final creators = <Hanime1Creator>[];
      creators.add(
        Hanime1Creator(
          name: '全部',
          queryPath: '',
          isSelected: query == null || query.isEmpty,
        ),
      );

      final seenCreator = <String>{};
      for (final card in doc.querySelectorAll(
        '.subscriptions-artist-card, .home-artist-card',
      )) {
        final name =
            card.querySelector('.search-artist-title')?.text.trim() ?? '';
        if (name.isEmpty || name == '全部' || !seenCreator.add(name)) continue;

        // 头像有两张 img：第一张是默认背景图，第二张才是真头像
        // —— 取最后一张非默认图（顺序敏感，官网把真头像放在后面）。
        String? avatar;
        for (final img in card.querySelectorAll('img')) {
          final src = img.attributes['src'] ?? img.attributes['data-src'] ?? '';
          if (src.isEmpty || src.contains('card_artist_background')) continue;
          avatar = src;
        }

        creators.add(
          Hanime1Creator(
            name: name,
            queryPath: '/search?query=${Uri.encodeComponent(name)}',
            avatarUrl: avatar,
            isSelected: query == name,
          ),
        );
      }

      // 2. 筛选器
      //
      // 官网 `.home-genre-tabs-wrapper` 一共 5 个：全部類型 / 標籤 / 排序方式 /
      // 發佈日期 / 時長（后面还有一个 `search-type-button`「訂閱的作者」）。
      // 早期只列了前 4 个，少一个「時長」。
      final filters = <String>['全部類型', '標籤', '排序方式', '發佈日期', '時長'];

      // 3. 订阅视频列表
      final items = <VideoItem>[];
      for (final cardEl in doc.querySelectorAll('.video-item-container')) {
        final item = _parseSingleCard(cardEl);
        if (item != null) items.add(item);
      }

      final hasNext = _checkHasNextPage(html, page);
      final totalPages = _extractTotalPagesFromDocument(doc, page, hasNext);

      return Hanime1SubscriptionData(
        creators: creators,
        filters: filters,
        items: items,
        hasMore: hasNext,
        page: page,
        totalPages: totalPages,
      );
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取订阅页数据异常: $e', e, stack);
      return const Hanime1SubscriptionData(
        creators: [],
        filters: [],
        items: [],
        hasMore: false,
      );
    }
  }

  /// 抓取排行榜单或指定排序列表
  Future<VideoPage> fetchRankingList(String sort, {int page = 1}) async {
    final encodedSort = Uri.encodeComponent(sort);
    final url =
        '$baseUrl/search?sort=$encodedSort${page > 1 ? "&page=$page" : ""}';
    return _fetchSearchUrl(url, page);
  }

  @override
  Future<VideoPage> fetchPage({required int page, int pageSize = 12}) async {
    if (page <= 1) {
      try {
        final resp = await _dio.get<String>(
          '$baseUrl/',
          options: Options(headers: _buildHeaders()),
        );
        final html = resp.data ?? '';
        final items = _parseVideoCards(html);
        return VideoPage(
          items: items,
          page: 1,
          hasMore: true,
          totalPages: 100,
          totalItems: items.length,
        );
      } catch (e, stack) {
        AppLogger.e('Hanime1Source', '抓取首页失败: $e', e, stack);
        return const VideoPage.empty();
      }
    }

    return fetchRankingList('最新上市', page: page);
  }

  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async {
    try {
      var path = categoryPath ?? '/search?sort=最新上市';

      if (path.startsWith('/user_')) {
        String uid = '';
        try {
          uid = Hanime1AuthService.to.userId.value;
        } catch (e) {
          // 降级为 uid 为空（未登录路径）。这是设计内的回退，但静默会让
          // 「用户区列表少了内容」无从排查，故留一条 W。控制流不变。
          AppLogger.w('Hanime1', '读取 userId 失败，用户区路径退化为不含 id: $e');
        }

        if (uid.isEmpty) {
          return const VideoPage(
            items: [],
            page: 1,
            hasMore: false,
            summary: '未登录 Hanime1 账户，请先登录',
          );
        }

        switch (path) {
          case '/user_history':
            path = '/user/$uid/histories';
            break;
          case '/user_saves':
            path = '/user/$uid/saves';
            break;
          case '/user_likes':
            path = '/user/$uid/likes';
            break;
          default:
            path = '/user/$uid';
            break;
        }
      }

      // 安全编码路径中的中文字符
      final uri = Uri.parse('$baseUrl$path');
      final newQueryMap = Map<String, String>.from(uri.queryParameters);
      if (page > 1) {
        newQueryMap['page'] = '$page';
      }
      final fullUri = uri.replace(
        queryParameters: newQueryMap.isNotEmpty ? newQueryMap : null,
      );

      return await _fetchSearchUrl(fullUri.toString(), page);
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取频道分类异常: $e', e, stack);
      return const VideoPage.empty();
    }
  }

  Future<VideoPage> _fetchSearchUrl(
    String url,
    int page, {
    bool artistDirectory = false,
  }) async {
    final headers = _buildHeaders();
    // Partition by session so switching accounts cannot reuse another user's
    // results. This short-lived memory cache never stores authentication on disk.
    final key = '$url::$page::$artistDirectory::${headers['Cookie'] ?? ''}';
    final cached = _searchPageCache[key];
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      return cached.value;
    }
    final pending = _searchInFlight[key];
    if (pending != null) return pending;
    final request = _loadSearchPage(url, page, artistDirectory, headers);
    _searchInFlight[key] = request;
    try {
      final result = await request;
      if (result.items.isNotEmpty) {
        _searchPageCache.remove(key);
        _searchPageCache[key] = (
          value: result,
          expires: DateTime.now().add(const Duration(seconds: 30)),
        );
        while (_searchPageCache.length > 24) {
          _searchPageCache.remove(_searchPageCache.keys.first);
        }
      }
      return result;
    } finally {
      _searchInFlight.remove(key);
    }
  }

  Future<VideoPage> _loadSearchPage(
    String url,
    int page,
    bool artistDirectory,
    Map<String, String> headers,
  ) async {
    try {
      AppLogger.i('Hanime1Source', '拉取列表: $url');
      final resp = await _dio.get<String>(
        url,
        options: Options(headers: headers),
      );

      final html = resp.data ?? '';
      final doc = await Isolate.run(() => html_parser.parse(html));
      final items = artistDirectory
          ? _parseArtistDirectoryCards(html, document: doc)
          : _parseVideoCards(html, document: doc);
      final hasNext = _checkHasNextPage(html, page, document: doc);
      final totalPages = _extractTotalPagesFromDocument(doc, page, hasNext);

      return VideoPage(
        items: items,
        page: page,
        hasMore: hasNext,
        totalPages: totalPages,
        totalItems: items.length,
      );
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取 URL 失败: $e', e, stack);
      return const VideoPage.empty();
    }
  }

  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) async {
    // 官网 /search 的筛选靠隐藏 input 提交，参数名与取值必须逐字一致。
    // 抓到的原始结构（form#hentai-form method=GET action=/search）：
    //   <input type="hidden" id="page"     name="page"     value="1">
    //   <input type="hidden" id="type"     name="type"     value="">
    //   <input type="hidden" id="genre"    name="genre"    value="">
    //   <input type="hidden" id="sort"     name="sort"     value="">
    //   <input type="hidden" id="date"     name="date"     value="">
    //   <input type="hidden" id="duration" name="duration" value="">
    //   <input type="hidden" name="query"  value="...">
    //   <input name="tags[]" type="checkbox" value="無碼">   × 240（弹窗内）
    //   <input type="checkbox" name="broad" id="broad">      ← OR/AND 开关
    // 取值来自 div.simple-dropdown-item[...].data-value，不能翻译成简体。
    final params = <String>[];

    final kw = query.keyword.trim();
    if (kw.isNotEmpty) params.add('query=${Uri.encodeComponent(kw)}');
    if (query.searchType == SearchType.authorId) {
      params.add('type=artist');
    }
    if (query.category.isNotEmpty) {
      params.add('genre=${Uri.encodeComponent(query.category)}');
    }
    if (query.sortParam.isNotEmpty) {
      params.add('sort=${Uri.encodeComponent(query.sortParam)}');
    }
    if (query.time.isNotEmpty) {
      params.add('date=${Uri.encodeComponent(query.time)}');
    }
    if (query.duration.isNotEmpty) {
      params.add('duration=${Uri.encodeComponent(query.duration)}');
    }
    // 标签多选：每选中一项都单独提交一次 tags[]=（方括号必须编码成 %5B%5D）。
    // 顺序保持用户在弹窗里的勾选顺序，站点侧不关心顺序。
    for (final t in query.tags) {
      final v = t.trim();
      if (v.isEmpty) continue;
      params.add('tags%5B%5D=${Uri.encodeComponent(v)}');
    }
    // broad=on → 命中任意一个标签即可（OR）；不带该参数 → 必须同时包含全部（AND）。
    if (query.tagBroad && query.tags.isNotEmpty) {
      params.add('broad=on');
    }
    if (page > 1) params.add('page=$page');

    final url = params.isEmpty
        ? '$baseUrl/search'
        : '$baseUrl/search?${params.join('&')}';
    return _fetchSearchUrl(
      url,
      page,
      artistDirectory: query.searchType == SearchType.authorId,
    );
  }

  /// The official type=artist route is a studio directory. Its cards link to a
  /// normal video search for that studio, and share the same search pager.
  List<VideoItem> _parseArtistDirectoryCards(
    String html, {
    dom.Document? document,
  }) {
    final doc = document ?? html_parser.parse(html);
    final results = <VideoItem>[];
    final seen = <String>{};
    final countPattern = RegExp(r'([\d,.]+)\s*个视频');

    for (final link in doc.querySelectorAll('a[href*="/search?query="]')) {
      final href = link.attributes['href'] ?? '';
      final uri = Uri.tryParse(href);
      final name = (uri?.queryParameters['query'] ?? link.text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;

      dom.Element? card;
      dom.Element? ancestor = link;
      for (var depth = 0; depth < 5 && ancestor != null; depth++) {
        if (ancestor.querySelector('img') != null &&
            countPattern.hasMatch(ancestor.text)) {
          card = ancestor;
          break;
        }
        ancestor = ancestor.parent;
      }
      if (card == null) continue;

      final count = countPattern.firstMatch(card.text)?.group(1) ?? '';
      final image = link.querySelector('img') ?? card.querySelector('img');
      var imageUrl =
          image?.attributes['data-src'] ??
          image?.attributes['data-original'] ??
          image?.attributes['src'] ??
          '';
      if (imageUrl.startsWith('//')) imageUrl = 'https:$imageUrl';
      if (imageUrl.isNotEmpty) {
        imageUrl = Uri.parse(baseUrl).resolve(imageUrl).toString();
      }

      final target = Uri.parse(baseUrl).resolve(href).toString();
      results.add(
        VideoItem(
          id: 'artist:${Uri.encodeComponent(name)}',
          title: name,
          author: 'Hanime1',
          hlsUrl: '',
          detailUrl: target,
          thumbnailUrl: imageUrl.isEmpty ? null : imageUrl,
          viewsStr: count.isEmpty ? null : '$count 个视频',
        ),
      );
    }
    return results;
  }

  @override
  Future<VideoDetail?> fetchDetail(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    final uri = Uri.tryParse(videoId);
    var id = uri?.queryParameters['v'] ?? videoId;
    if (id.startsWith('http')) {
      final segments = Uri.tryParse(id)?.pathSegments ?? const <String>[];
      if (segments.isNotEmpty) id = segments.last;
    }
    final playlistId = uri?.queryParameters['list'];
    final key = playlistId == null ? id : '$id::playlist:$playlistId';
    final pending = _detailInFlight[key];
    if (pending != null) {
      AppLogger.i('Hanime1Source', '合并同一详情页请求: video=$id');
      return pending;
    }

    final request = _fetchDetailInternal(videoId, forceRefresh: forceRefresh);
    _detailInFlight[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_detailInFlight[key], request)) {
        _detailInFlight.remove(key);
      }
    }
  }

  /// 后台预取专用的详情拉取：**不携带登录 Cookie**。
  ///
  /// 官网的觀看紀錄由服务端在收到 watch 页请求时写入（`app.js` 里没有任何
  /// 客户端上报），所以后台预取必须匿名 —— 否则会给用户刷出一堆他从未点开过的
  /// 观看记录。用户主动点开请走 [markWatched]。
  ///
  /// 为什么不做成接口成员：`VideoSource` 的实现方用的是 `implements`，
  /// 加成员会强制 91 源一起补齐（而 91 源不允许改动）。与 `ownsItem` 同理，
  /// 走扩展 + 类型判断。
  Future<VideoDetail?> fetchDetailAnonymous(
    String videoId, {
    bool forceRefresh = false,
  }) => _fetchDetailInternal(
    videoId,
    forceRefresh: forceRefresh,
    anonymous: true,
  );

  /// 上报「用户主动打开了这个视频」—— **唯一**会在官网留下观看记录的入口。
  ///
  /// ## 为什么需要单独上报
  /// 官网的觀看紀錄完全由服务端在收到 watch 页请求时写入。而 App 的详情带
  /// **15 分钟缓存**（见 [_fetchDetailInternal] 开头的 `_detailCache` 判断），
  /// 用户点开视频时往往直接命中缓存、一个请求都不发 —— 于是出现
  /// 「**真正点开的不记录，后台预取过的反而记录了**」这种颠倒的结果。
  /// 这里强制发一次带登录态的 watch 页请求来修正。
  ///
  /// 只在用户主动点开时调用；后台预取走 [fetchDetailAnonymous]。
  Future<void> markWatched(String videoId) async {
    if (!Hanime1AuthService.to.isLoggedIn.value) return;
    var vid = videoId;
    if (vid.contains('v=')) {
      vid = Uri.tryParse(vid)?.queryParameters['v'] ?? vid;
    } else if (vid.startsWith('http')) {
      final segs = Uri.tryParse(vid)?.pathSegments ?? const <String>[];
      if (segs.isNotEmpty) vid = segs.last;
    }
    if (vid.isEmpty) return;
    try {
      await _dio.get<String>(
        '$baseUrl/watch?v=${Uri.encodeQueryComponent(vid)}',
        options: Options(headers: _buildHeaders()),
      );
      AppLogger.i('Hanime1Source', '已上报官网观看记录: $vid');
    } catch (e) {
      AppLogger.w('Hanime1Source', '上报官网观看记录失败: $e');
    }
  }

  Future<VideoDetail?> _fetchDetailInternal(
    String videoId, {
    required bool forceRefresh,
    bool anonymous = false,
  }) async {
    final requestedUri = Uri.tryParse(videoId);
    final requestedPlaylistId = requestedUri?.queryParameters['list'];
    var vid = videoId;
    if (vid.contains('v=')) {
      vid = Uri.tryParse(vid)?.queryParameters['v'] ?? vid;
    } else if (vid.startsWith('http')) {
      final segs = Uri.tryParse(vid)?.pathSegments ?? [];
      if (segs.isNotEmpty) vid = segs.last;
    }

    if (!forceRefresh && _detailCache.containsKey(vid)) {
      final time = _detailCacheTime[vid];
      if (time != null && DateTime.now().difference(time).inMinutes < 15) {
        if (requestedPlaylistId == null ||
            !_playlistCache.containsKey(requestedPlaylistId)) {
          return _detailCache[vid];
        }
        // Reparse when the same video is opened from a user playlist so the
        // player's list context does not remain bound to a stale creator list.
        _detailCache.remove(vid);
        _detailCacheTime.remove(vid);
      }
    }

    try {
      final detailUrl = '$baseUrl/watch?v=$vid';
      AppLogger.i(
        'Hanime1Source',
        '现场拉取视频详情${anonymous ? '（匿名，不计入观看记录）' : ''}: $detailUrl',
      );

      final resp = await _dio.get<String>(
        detailUrl,
        options: Options(headers: _buildHeaders(anonymous: anonymous)),
      );

      final html = resp.data ?? '';
      final parseTimer = Stopwatch()..start();
      // Detail pages include a large recommendation block. Parsing the DOM on
      // Flutter's UI isolate can starve input for several seconds on phones.
      final doc = await Isolate.run<dom.Document>(
        () => html_parser.parse(html),
      );
      AppLogger.i(
        'Hanime1Source',
        '详情 HTML 已在后台解析 (${html.length} 字符，${parseTimer.elapsedMilliseconds}ms)',
      );

      // 1. 提取播放流源地址 (原生 MP4 多分辨率)
      final videoEl =
          doc.querySelector('video#player') ?? doc.querySelector('video');
      final sourceEls = videoEl?.querySelectorAll('source') ?? [];
      final variants = <VideoVariant>[];

      for (final s in sourceEls) {
        final src = s.attributes['src'] ?? '';
        if (src.isEmpty) continue;
        // `size` 属性优先；**缺失时从文件名里抠**（官网形如 `408437-1080p.mp4`）。
        //
        // 以前这里写的是 `?? '720'`，看起来无害，实则会让「默认最高画质」失效：
        // 任何一个没带 `size` 的 1080p 源都会被当成 720p，排到真正的 720p 后面，
        // 于是 `variants.first` 取到的是低画质。实测官网的 `<source>` 顺序就是
        // 720p → 480p → 1080p，全靠 `size` 属性排序，所以这里必须能兜住缺属性。
        final size = s.attributes['size'] ?? _inferQuality(src);
        variants.add(VideoVariant(label: '${size}p', url: src));
      }

      if (variants.isEmpty && videoEl != null) {
        final directSrc = videoEl.attributes['src'] ?? '';
        if (directSrc.isNotEmpty) {
          variants.add(VideoVariant(label: '默认', url: directSrc));
        }
      }

      // 优选最高分辨率（降序取第一）—— 用户要求「画质默认是最高画质」。
      variants.sort((a, b) {
        final numA = int.tryParse(a.label.replaceAll(RegExp(r'\D'), '')) ?? 0;
        final numB = int.tryParse(b.label.replaceAll(RegExp(r'\D'), '')) ?? 0;
        return numB.compareTo(numA);
      });

      final bestStreamUrl = variants.isNotEmpty ? variants.first.url : '';
      AppLogger.i(
        'Hanime1Source',
        '画质清单: ${variants.map((v) => v.label).join(' > ')} → 默认选用 '
            '${variants.isNotEmpty ? variants.first.label : '(无)'}',
      );

      // 2. 标题与发布信息
      final titleCaption = doc.querySelector('.video-caption-text');
      // 官网页面可见的标题在 #shareBtn-title；简介中的 Title 是原作标题，
      // 有时为空或与上传标题不同。
      var title = doc.querySelector('#shareBtn-title')?.text.trim() ?? '';
      var publishedAt = '';
      if (titleCaption != null) {
        final rawText = titleCaption.text;
        final titleMatch = RegExp(r'(?:Title|タイトル):\s*([^\n\r]+)')
            .firstMatch(rawText);
        if (title.isEmpty && titleMatch != null) {
          title = titleMatch.group(1)?.trim() ?? '';
        }
        final dateMatch = RegExp(r'(?:Release|販売日):\s*([^\n\r]+)')
            .firstMatch(rawText);
        if (dateMatch != null) {
          publishedAt = dateMatch.group(1)?.trim() ?? '';
        }
      }

      if (title.isEmpty) {
        final h1 = doc.querySelector('h1') ?? doc.querySelector('h2');
        title = h1?.text.trim() ?? 'Hanime1 #$vid';
      }

      // 3. 作者
      final authorEl =
          doc.querySelector('.meta-author') ??
          doc.querySelector('a[href*="/user/"]');
      final author = authorEl?.text.trim() ?? 'Hanime1';

      // 4. 标签（带计数）—— 官网结构：div.video-tags-wrapper > div.single-video-tag
      //    > a[href="/search?tags[]=xxx&genre=yyy"] + span "(5)"
      //
      // ⚠️ 标签区**末尾还有两个「編輯標籤」按钮**（`#add` / `#remove`，作者本人可见），
      // 它们的 DOM 结构（`.single-video-tag > a`）和真标签**完全一样**，会被一并抓进来。
      // 实测在真机播放页渲染成两个伪标签 `#add` `#remove`（见 .perf/t_play_final.png）。
      final tagDetails = <Hanime1Tag>[];
      final tagWrapper = doc.querySelector('.video-tags-wrapper');
      if (tagWrapper != null) {
        for (final t in tagWrapper.querySelectorAll('.single-video-tag')) {
          final a = t.querySelector('a');
          if (a == null) continue;
          final name = a.text
              .replaceAll(RegExp(r'\(\d+\)$'), '')
              .replaceFirst(RegExp(r'^\s*#+\s*'), '')
              .trim();
          if (name.isEmpty) continue;
          if (_tagEditButtonNames.contains(name.toLowerCase())) continue;
          final cnt =
              int.tryParse(
                (t.querySelector('span')?.text ?? '').replaceAll(
                  RegExp(r'\D'),
                  '',
                ),
              ) ??
              0;
          tagDetails.add(
            Hanime1Tag(
              name: name,
              path: a.attributes['href'] ?? '',
              count: cnt,
            ),
          );
        }
      }
      // 兼容兜底：若新结构没命中，退回旧选择器（只取名字，无计数）
      if (tagDetails.isEmpty) {
        for (final t in doc.querySelectorAll(
          'a[href*="tags%5B%5D"], a[href*="tags[]"]',
        )) {
          final txt = t.text
              .replaceAll(RegExp(r'\(\d+\)$'), '')
              .replaceFirst(RegExp(r'^\s*#+\s*'), '')
              .trim();
          if (txt.isNotEmpty) {
            tagDetails.add(
              Hanime1Tag(name: txt, path: t.attributes['href'] ?? ''),
            );
          }
        }
      }
      final tags = tagDetails.map((t) => t.name).toList();

      // 4.1 播放量与发布日期（官网形如「觀看次數：269.9萬次  2024-12-12」）
      var viewsText = '';
      var releaseDate = publishedAt;
      final metaText =
          doc.querySelector('.video-details-wrapper.hidden-xs')?.text.trim() ??
          '';
      final viewsMatch = RegExp(r'觀看次數[：:]\s*([^\s]+)').firstMatch(metaText);
      if (viewsMatch != null) viewsText = viewsMatch.group(1)!;
      if (releaseDate.isEmpty) {
        final dm = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(metaText);
        if (dm != null) releaseDate = dm.group(1)!;
      }

      // 4.2 点赞率与点赞数（#video-like-btn 内含 "100%" 与 "(1273)"）
      var likePercent = '';
      var likeCount = '';
      final likeBtn = doc.querySelector('#video-like-btn');
      final likeForm = doc.querySelector('#video-like-form');
      final subscribeLabel =
          doc.querySelector('#video-subscribe-btn')?.text.trim() ?? '';
      if (likeBtn != null) {
        final pct = RegExp(r'(\d+(?:\.\d+)?%)').firstMatch(likeBtn.text);
        if (pct != null) likePercent = pct.group(1)!;
        final cnt = RegExp(r'\((\d+)\)').firstMatch(likeBtn.text);
        if (cnt != null) likeCount = cnt.group(1)!;
      }

      // 4.3 评论条数
      final commentCount =
          doc.querySelector('#tab-comments-count')?.text.trim() ?? '';

      // 4.4 上传者（官网 video-description-panel 里标注「上傳者」的那个用户）
      var uploaderName = '';
      var uploaderPath = '';
      var uploaderAvatar = '';
      final descPanel = doc.querySelector('.video-description-panel');
      if (descPanel != null) {
        final a = descPanel.querySelector('a[href*="/user/"]');
        if (a != null) {
          uploaderPath = a.attributes['href'] ?? '';
          uploaderName = (a.querySelector('span')?.text ?? a.text).trim();
        }
        uploaderAvatar =
            descPanel.querySelector('img')?.attributes['src'] ?? '';
      }

      // 4.5 制作方（#video-artist-name）与所属分类（作者区的 genre 链接）
      var artistName = '';
      var artistPath = '';
      var artistAvatar = '';
      final artistEl = doc.querySelector('#video-artist-name');
      if (artistEl != null) {
        artistName = artistEl.text.trim();
        artistPath = artistEl.attributes['href'] ?? '';
      }
      final artistAvatarEl = doc.querySelector(
        '.video-details-wrapper.desktop-inline-mobile-block img',
      );
      if (artistAvatarEl != null) {
        artistAvatar = artistAvatarEl.attributes['src'] ?? '';
      }

      var genreName = '';
      var genrePath = '';
      final genreEl = doc.querySelector('a[href*="genre="]');
      if (genreEl != null) {
        genreName = genreEl.text.trim();
        genrePath = genreEl.attributes['href'] ?? '';
      }

      // 4.6 封面与时长
      final coverUrl =
          doc.querySelector('img.main-thumb')?.attributes['src'] ?? '';
      final durationText = doc.querySelector('div.duration')?.text.trim() ?? '';

      // 4.7 所属清单（剧集系列）：#playlist-top-block 标题 + #playlist-scroll 剧集
      var playlistTitle = '';
      var playlistPath = '';
      var playlistAuthor = '';
      var playlistAuthorPath = '';
      final plTop = doc.querySelector('#playlist-top-block');
      if (plTop != null) {
        final h4a = plTop.querySelector('h4 a');
        if (h4a != null) {
          playlistTitle = h4a.text.trim();
          playlistPath = h4a.attributes['href'] ?? '';
        }
        final authorA = plTop.querySelector('a[href*="/user/"]');
        if (authorA != null) {
          playlistAuthor = authorA.text.trim();
          playlistAuthorPath = authorA.attributes['href'] ?? '';
        }
      }
      final playlistItems = <VideoItem>[];
      final plScroll = doc.querySelector('#playlist-scroll');
      if (plScroll != null) {
        for (final el in plScroll.querySelectorAll('.video-item-container')) {
          final it = _parseSingleCard(el);
          if (it != null) playlistItems.add(it);
        }
      }
      final requestedPlaylist = requestedPlaylistId == null
          ? null
          : _playlistCache[requestedPlaylistId];
      if (requestedPlaylist != null) {
        playlistTitle = requestedPlaylist.title;
        playlistPath = '/playlist?list=${requestedPlaylist.id}';
        playlistAuthor = requestedPlaylist.creator;
        playlistAuthorPath = requestedPlaylist.creatorPath;
        playlistItems
          ..clear()
          ..addAll(requestedPlaylist.items);
      }
      final saveForm = doc.querySelector('#video-save-form');
      final savedPlaylistIds = saveForm == null
          ? <String>[]
          : _parseSaveOptions(saveForm)
                .where((option) => option.isSaved)
                .map((option) => option.id)
                .toList();

      // 4.8 简介原文（官网 `.video-caption-text`，播放页描述面板用 3 行截断展示）
      final captionText =
          doc.querySelector('.video-caption-text')?.text.trim() ?? '';

      _extraCache[vid] = Hanime1VideoExtra(
        viewsText: viewsText,
        releaseDate: releaseDate,
        likePercent: likePercent,
        likeCount: likeCount,
        isSubscribed: subscribeLabel.contains('已'),
        isLiked: _formFlag(likeForm, 'like-status'),
        isDisliked: _formFlag(likeForm, 'unlike-status'),
        commentCount: commentCount,
        uploaderName: uploaderName,
        uploaderPath: uploaderPath,
        uploaderAvatar: uploaderAvatar,
        artistName: artistName,
        artistPath: artistPath,
        artistAvatar: artistAvatar,
        genreName: genreName,
        genrePath: genrePath,
        durationText: durationText,
        coverUrl: coverUrl,
        captionText: captionText,
        tags: tagDetails,
        playlistTitle: playlistTitle,
        playlistPath: playlistPath,
        playlistAuthor: playlistAuthor,
        playlistAuthorPath: playlistAuthorPath,
        playlistItems: playlistItems,
        savedPlaylistIds: savedPlaylistIds,
      );

      final item = VideoItem(
        id: vid,
        title: title,
        author: author,
        hlsUrl: bestStreamUrl,
        detailUrl: detailUrl,
        // 以下四项原先全部漏传 —— 播放页因此显示不出封面/时长/播放量。
        thumbnailUrl: coverUrl.isNotEmpty ? coverUrl : null,
        durationStr: durationText.isNotEmpty ? durationText : null,
        viewsStr: viewsText.isNotEmpty ? viewsText : null,
        publishedAt: releaseDate.isNotEmpty ? releaseDate : null,
        tags: tags,
      );

      final detail = VideoDetail(video: item, variants: variants);

      _relatedVideoCache.remove(vid);
      _relatedHtmlCache[vid] = html;
      if (!anonymous && Hanime1AuthService.to.isLoggedIn.value) {
        final saveForm = doc.querySelector('#video-save-form');
        if (saveForm != null) {
          _rememberVideoSaveOptions(vid, _parseSaveOptions(saveForm));
        }
      }
      while (_relatedHtmlCache.length > _maxRelatedHtmlCacheEntries) {
        _relatedHtmlCache.remove(_relatedHtmlCache.keys.first);
      }

      _detailCache[vid] = detail;
      _detailCacheTime[vid] = DateTime.now();

      return detail;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '解析详情异常: $e', e, stack);
      return null;
    }
  }

  // ==================================================================
  // 播放页评论（官网 AJAX 异步加载）
  // ==================================================================

  static String? _ajaxFragment(dynamic data, String key) {
    if (data is Map) return data[key] is String ? data[key] as String : null;
    if (data is! String) return null;
    final trimmed = data.trimLeft();
    if (!trimmed.startsWith('{')) return data;
    try {
      final decoded = jsonDecode(data);
      return decoded is Map && decoded[key] is String
          ? decoded[key] as String
          : null;
    } catch (_) {
      return null;
    }
  }

  /// 抓取播放页评论列表。
  ///
  /// 官网实现（`/js/app.js`）：
  /// ```js
  /// $.ajax({type:"GET", url:"/loadComment",
  ///   data:{id:$(this).data("foreignid"), type:$(this).data("type"), content:this.id},
  ///   success:function(t){ $("div#comment-section-wrapper").html(t.comments); ... }})
  /// ```
  /// 触发元素是 `button#comment-tablink[data-foreignid=视频id][data-type=video]`，
  /// 所以参数就是 `id` / `type` / `content`（`content` 固定为容器 id）。
  ///
  /// 返回 JSON：`{"comments": "<html 片段>", "content": "comment-section-wrapper"}`。
  ///
  /// [forceRefresh] 为 false 时命中 [_commentCache] 直接返回，
  /// 避免反复切 Tab 时重复下载。
  Future<List<Hanime1Comment>> fetchComments(
    String videoId, {
    String type = 'video',
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _commentCache.containsKey(videoId)) {
      return _commentCache[videoId]!;
    }

    try {
      AppLogger.i('Hanime1Source', '拉取评论: $videoId');
      final resp = await _dio.get<dynamic>(
        '$baseUrl/loadComment',
        queryParameters: <String, String>{
          'id': videoId,
          'type': type,
          'content': 'comment-section-wrapper',
        },
        options: Options(
          headers: <String, String>{
            ..._buildHeaders(),
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );

      final raw = resp.data;
      final fragment = _ajaxFragment(raw, 'comments');
      if (fragment == null) return const <Hanime1Comment>[];
      if (fragment.trim().isEmpty) {
        _commentCache[videoId] = const <Hanime1Comment>[];
        return const <Hanime1Comment>[];
      }

      final list = _parseCommentList(fragment);
      _commentCache[videoId] = list;
      return list;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取评论异常: $e', e, stack);
      return const <Hanime1Comment>[];
    }
  }

  /// 展开某条评论的回复。
  ///
  /// 官网：`GET /loadReplies?id={commentId}` →
  /// `{"comment_id": "177147", "replies": "<html 片段>"}`。
  Future<List<Hanime1Comment>> fetchReplies(
    String commentId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _replyCache.containsKey(commentId)) {
      return _replyCache[commentId]!;
    }

    try {
      final resp = await _dio.get<dynamic>(
        '$baseUrl/loadReplies',
        queryParameters: <String, String>{'id': commentId},
        options: Options(
          headers: <String, String>{
            ..._buildHeaders(),
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );

      final fragment = _ajaxFragment(resp.data, 'replies');
      if (fragment == null) return const <Hanime1Comment>[];
      if (fragment.trim().isEmpty) {
        _replyCache[commentId] = const <Hanime1Comment>[];
        return const <Hanime1Comment>[];
      }

      final list = _parseCommentList(fragment);
      _replyCache[commentId] = list;
      return list;
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '拉取回复异常: $e', e, stack);
      return const <Hanime1Comment>[];
    }
  }

  /// 解析评论 HTML 片段。
  ///
  /// 关键点：一级评论与回复的 DOM 形状**不一样**，只有 `.report-btn-wrapper`
  /// 是两者共有的锚点，所以以它为基准做「向前找头像、向后找点赞区」：
  ///
  /// | 位置 | 一级评论 | 回复（`#reply-start-N` 内） |
  /// |---|---|---|
  /// | 头像 `<a><img class="img-circle">` | `.report-btn-wrapper` 的**前一个兄弟** | `.report-btn-wrapper` 的**第一个子元素** |
  /// | 点赞区 | 后一个兄弟 `#comment-like-form-wrapper` | 后一个兄弟 `<div>`（无 id） |
  ///
  /// 注意 `#comment-start` 这个 id 在官网被**重复使用**（每条一级评论都带），
  /// 所以不能拿它当每条评论的边界。
  List<Hanime1Comment> _parseCommentList(String fragment) {
    if (fragment.trim().isEmpty) return const <Hanime1Comment>[];

    final doc = html_parser.parse(fragment);
    final out = <Hanime1Comment>[];

    for (final wrap in doc.querySelectorAll('div.report-btn-wrapper')) {
      // 1) 头像：优先取前置兄弟 <a>（一级评论），否则取内部第一个 <a>（回复）。
      dom.Element? avatarAnchor = wrap.previousElementSibling;
      if (avatarAnchor == null || avatarAnchor.localName != 'a') {
        avatarAnchor = wrap.querySelector('a');
      }
      final avatarUrl =
          avatarAnchor?.querySelector('img')?.attributes['src'] ?? '';

      // 2) 作者名 / 时间 / 正文
      final indexTexts = wrap.querySelectorAll('div.comment-index-text');
      var authorName = '';
      var timeText = '';
      if (indexTexts.isNotEmpty) {
        final header = indexTexts.first;
        final authorAnchor = header.querySelector('a') ?? header;
        timeText = header.querySelector('span')?.text.trim() ?? '';
        // <a> 的 text 把 <span>1年前</span> 也算进去了，得剔掉。
        authorName = authorAnchor.text.trim();
        if (timeText.isNotEmpty) {
          authorName = authorName.replaceAll(timeText, '').trim();
        }
        authorName = authorName.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
      final body = indexTexts.length > 1 ? indexTexts[1].text.trim() : '';

      // 3) 点赞数：点赞区里 thumb_up 图标 span 的下一个 span
      final likeArea = wrap.nextElementSibling;
      var likeCount = 0;
      var replyCount = 0;
      var commentId = '';

      final reportBtn = wrap.querySelector('[data-reportable-id]');
      commentId = reportBtn?.attributes['data-reportable-id'] ?? '';

      if (likeArea != null) {
        final spans = likeArea.querySelectorAll('span');
        for (var i = 0; i < spans.length; i++) {
          if (spans[i].text.trim() == 'thumb_up' && i + 1 < spans.length) {
            likeCount = int.tryParse(spans[i + 1].text.trim()) ?? 0;
            break;
          }
        }

        // 4) 回复数：div.load-replies-btn 文本形如「查看 16 則回覆」
        final loadBtn = likeArea.querySelector('.load-replies-btn');
        if (loadBtn != null) {
          final digits = RegExp(r'\d+').firstMatch(loadBtn.text)?.group(0);
          replyCount = int.tryParse(digits ?? '') ?? 0;
          if (commentId.isEmpty) {
            commentId = loadBtn.attributes['data-commentid'] ?? '';
          }
        }
      }

      // 没有 id 的条目（例如站点插入的提示块）直接跳过，否则无法做回复定位。
      if (commentId.isEmpty) continue;

      out.add(
        Hanime1Comment(
          commentId: commentId,
          authorName: authorName.isNotEmpty ? authorName : '匿名',
          avatarUrl: avatarUrl,
          timeText: timeText,
          body: body,
          likeCount: likeCount,
          replyCount: replyCount,
        ),
      );
    }

    return out;
  }

  bool _checkHasNextPage(
    String html,
    int currentPage, {
    dom.Document? document,
  }) {
    if (!html.contains('pagination')) return false;
    final doc = document ?? html_parser.parse(html);
    final pagination = doc.querySelector('ul.pagination, .pagination');
    if (pagination == null) return false;

    for (final a in pagination.querySelectorAll('a')) {
      final text = a.text.trim();
      if (text == '›' || text == '»' || text == '下一頁' || text == '>') {
        return true;
      }
      final pageNum = int.tryParse(text);
      if (pageNum != null && pageNum > currentPage) {
        return true;
      }
    }
    return false;
  }

  int _extractTotalPagesFromDocument(
    dom.Document doc,
    int currentPage,
    bool hasNext,
  ) {
    var total = currentPage;
    for (final link in doc.querySelectorAll(
      '.pagination a, .search-pagination a, .playlist-pagination a, '
      '.user-items-pagination a, .playlist-video-list a',
    )) {
      final linkedPage = int.tryParse(link.text.trim());
      if (linkedPage != null && linkedPage > total) total = linkedPage;
      final href = Uri.tryParse(link.attributes['href'] ?? '');
      final queryPage = int.tryParse(href?.queryParameters['page'] ?? '');
      if (queryPage != null && queryPage > total) total = queryPage;
    }
    if (total <= currentPage && hasNext) return currentPage + 1;
    return total < 1 ? 1 : total;
  }

  /// 单独解析单个 video-item-container 卡片
  // ================================================================ 用户「我的」页

  /// 抓取并解析官网 `/user/{uid}`（「我的 Hanime1」首屏）。
  ///
  /// 官网手机端该页 = 头部资料区 + 7 个 Tab 条 + 4 个视频横排：
  /// ```
  /// #playlist-headings-wrapper > .profile-main-container
  ///   .profile-avatar-wrapper img         头像（70x70 圆角 50%）
  ///   h1.profile-display-name             昵称
  ///   .profile-sub-stats-id               "@ 100001"
  ///   .profile-sub-stats-new-line         "1 位訂閱者 • 0 部影片"
  /// .tab-index-rows-wrapper
  ///   a.horizontal-row-title[href] > h3   "觀看紀錄" / "稍後觀看" / "讚好的影片" / "播放清單"
  ///   div > .home-row.horizontal-row      N 张 .horizontal-card
  /// ```
  ///
  /// 实测（uid=100001）每行条数：12 / 12 / 12 / 4。
  /// 卡片结构与首页、搜索页**完全相同**，所以直接复用 [_parseSingleCard]。
  Future<Hanime1UserProfile?> fetchUserProfile(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return null;

    try {
      final url = '$baseUrl/user/$id';
      AppLogger.i('Hanime1Source', '抓取用户「我的」页: $url');

      final resp = await _dio.get<String>(
        url,
        options: Options(headers: _buildHeaders()),
      );

      final doc = html_parser.parse(resp.data ?? '');

      final name =
          doc.querySelector('.profile-display-name')?.text.trim() ?? '';
      final avatar =
          doc.querySelector('.profile-avatar-wrapper img')?.attributes['src'] ??
          '';
      final subId =
          doc.querySelector('.profile-sub-stats-id')?.text.trim() ?? '';
      final subLine =
          doc.querySelector('.profile-sub-stats-new-line')?.text.trim() ?? '';

      // UID 以页面里的 "@ 100001" 为准（URL 里的可能是别名）。
      var realId = id;
      final idMatch = RegExp(r'(\d+)').firstMatch(subId);
      if (idMatch != null) realId = idMatch.group(1)!;

      final rows = <Hanime1UserRow>[];
      for (final titleEl in doc.querySelectorAll(
        '.tab-index-rows-wrapper .horizontal-row-title',
      )) {
        final title = _userRowTitle(titleEl);
        if (title.isEmpty) continue;

        final rowEl = _homeRowAfter(titleEl);
        final items = <VideoItem>[];
        final seen = <String>{};
        if (rowEl != null) {
          for (final el in rowEl.querySelectorAll(
            '.video-item-container, .horizontal-card',
          )) {
            final item = _parseSingleCard(el);
            if (item != null && seen.add(item.id)) items.add(item);
          }
        }

        rows.add(
          Hanime1UserRow(
            title: title,
            path: _relativePath(titleEl.attributes['href'] ?? ''),
            tabKey: _userRowKey(titleEl.attributes['href'] ?? ''),
            items: items,
          ),
        );
      }

      AppLogger.i(
        'Hanime1Source',
        '用户页解析完成: name="$name" uid=$realId rows=${rows.length} '
            '(${rows.map((r) => '${r.title}:${r.items.length}').join(', ')})',
      );

      return Hanime1UserProfile(
        displayName: name,
        userId: realId,
        avatarUrl: avatar,
        subStatsIdText: subId,
        subStatsLineText: subLine,
        rows: rows,
      );
    } catch (e, stack) {
      AppLogger.e('Hanime1Source', '用户页抓取失败: $e', e, stack);
      return null;
    }
  }

  /// 从 `a.horizontal-row-title > h3` 里取**纯**行标题。
  ///
  /// `h3` 里除了标题还嵌着一个「更多 ›」的 `<div>`，直接取 `.text` 会拼成
  /// `觀看紀錄查看更多arrow_forward_ios` —— 因为那个箭头是图标字体
  /// （`<span class="material-icons">arrow_forward_ios</span>`），
  /// 一旦字体没加载，字面量 `arrow_forward_ios` 就会混进文本里。
  /// 只取 `h3` 的**直接文本子节点**即可拿到干净标题。
  static String _userRowTitle(dom.Element titleEl) {
    final h3 = titleEl.querySelector('h3');
    if (h3 == null) return '';
    final direct = h3.nodes
        .whereType<dom.Text>()
        .map((t) => t.text)
        .join()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (direct.isNotEmpty) return direct;
    return h3.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 取标题锚点之后的 `.home-row` 容器。
  ///
  /// 官网的 DOM 不是「标题的紧邻兄弟就是行容器」，而是
  /// `a.horizontal-row-title` → `div` → `.home-rows-videos-wrapper.home-row`，
  /// 中间隔了一层没有类名的定位 div，所以往后找几层、并向下钻一层。
  static dom.Element? _homeRowAfter(dom.Element titleEl) {
    var sib = titleEl.nextElementSibling;
    for (var i = 0; i < 3 && sib != null; i++) {
      if (sib.classes.contains('home-row')) return sib;
      final inner = sib.querySelector('.home-row');
      if (inner != null) return inner;
      sib = sib.nextElementSibling;
    }
    return null;
  }

  /// 把 `https://hanime1.me/user/1/histories` 归一成 `/user/1/histories`。
  static String _relativePath(String href) {
    if (href.isEmpty) return '';
    final u = Uri.tryParse(href);
    if (u == null) return href;
    final p = u.path.isEmpty ? href : u.path;
    return u.hasQuery ? '$p?${u.query}' : p;
  }

  /// 取路径尾段作为**稳定行标识**：`histories` / `saves` / `likes` / `playlists`。
  ///
  /// 为什么不能用标题：官网对登录用户返回的 HTML 里标题会**简繁混排**
  /// （实测 `觀看紀錄` 繁体，但 `稍后观看` / `点赞的视频` / `播放清单` 是简体），
  /// 而 App 的 Tab 文案固定繁体。任何 `title == '稍後觀看'` 的等值判断都会失败，
  /// 表现就是切到该 Tab 永远显示「暫無內容」。路径尾段不受文案变化影响。
  static String _userRowKey(String href) {
    if (href.isEmpty) return '';
    final u = Uri.tryParse(href);
    if (u == null) return '';
    final segs = u.pathSegments;
    // `/user/{uid}/{tab}` —— 少于 3 段说明不是行标题链接。
    if (segs.length < 3) return '';
    return segs.last;
  }

  /// 抓取「我的」页**单个 Tab 的独立分页**。
  ///
  /// 官网点 Tab 不是前端切显隐，而是真的跳到独立分页
  /// （`/user/{uid}/histories` / `/saves` / `/likes` / `/playlists`）：
  /// ```
  /// .tab-content-container > .specific-tab-view.home-rows-videos-wrapper
  ///   .filter-button-group > a.filter-pill[href]    「最新 / 熱門 / 最早」
  ///   .video-item-container ×60                     每页 60 张卡片
  /// .search-pagination.user-items-pagination
  ///   li.page-item.active > .page-link              当前页
  ///   a[rel="next"]                                 存在 = 还有下一页
  /// ```
  ///
  /// 首屏 `/user/{uid}` 每行只给 12 个预览，所以点进单个 Tab 必须重新抓这一页，
  /// 否则用户永远只能看到 12 条（官网是 60 条/页 × 多页）。
  Future<Hanime1UserTabPage> fetchUserTabPage(
    String uid,
    String tabKey, {
    int page = 1,
    String sort = 'latest',
  }) async {
    final id = uid.trim();
    final key = tabKey.trim();
    if (id.isEmpty || key.isEmpty) return Hanime1UserTabPage.empty;

    try {
      final params = <String>['sort=$sort'];
      if (page > 1) params.add('page=$page');
      final url = '$baseUrl/user/$id/$key?${params.join('&')}';
      AppLogger.i('Hanime1Source', '抓取用户分页: $url');

      final resp = await _dio.get<String>(
        url,
        options: Options(headers: _buildHeaders()),
      );
      final html = resp.data ?? '';
      final doc = html_parser.parse(html);

      // 只在 `.specific-tab-view` 范围内取卡片 —— 页面顶部还有别的卡片区
      // （侧栏推荐等），不限定范围会把无关视频混进来。
      final scope =
          doc.querySelector('.specific-tab-view') ??
          doc.querySelector('.tab-content-container') ??
          doc;

      final items = <VideoItem>[];
      final seen = <String>{};
      for (final el in scope.querySelectorAll(
        '.video-item-container, .horizontal-card',
      )) {
        final item = _parseSingleCard(el);
        if (item != null && seen.add(item.id)) items.add(item);
      }

      // 官网分页器到最后一页时，`›` 会从 `<a rel="next">` 退化成 disabled 的
      // `<span>`，所以「`a[rel="next"]` 是否存在」就是最准的 hasMore 判据。
      final hasNext =
          doc.querySelector('.user-items-pagination a[rel="next"]') != null;
      final totalPages = _extractTotalPagesFromDocument(doc, page, hasNext);

      AppLogger.i(
        'Hanime1Source',
        '用户分页解析完成: /user/$id/$key page=$page sort=$sort '
            'items=${items.length} hasNext=$hasNext',
      );

      return Hanime1UserTabPage(
        items: items,
        page: page,
        hasMore: hasNext,
        sort: sort,
        totalPages: totalPages,
      );
    } catch (e, stack) {
      AppLogger.e(
        'Hanime1Source',
        '用户分页抓取失败 /user/$id/$key page=$page: $e',
        e,
        stack,
      );
      return Hanime1UserTabPage.empty;
    }
  }

  /// 从直链文件名里推断清晰度标签（返回纯数字，如 `1080`）。
  ///
  /// 官网直链形如 `https://vdownload.hembed.com/408437-1080p.mp4?secure=…`，
  /// 先试 `1080p`，再试 `-1080.mp4`，都没有就退回 `720`（与旧行为一致）。
  static String _inferQuality(String url) {
    final withP = RegExp(r'(\d{3,4})p').firstMatch(url);
    if (withP != null) return withP.group(1)!;
    final bare = RegExp(r'-(\d{3,4})\.(?:mp4|m3u8|ts)').firstMatch(url);
    if (bare != null) return bare.group(1)!;
    return '720';
  }

  static VideoItem? _parseSingleCard(dom.Element el) {
    final link = el.localName == 'a'
        ? el
        : el.querySelector('a.video-link') ??
              el.querySelector('a[href*="/watch?v="]');
    if (link == null) return null;
    final href = link.attributes['href'] ?? '';

    // 卡片其实有**两种**实体，必须都认：
    //   - 视频：`/watch?v=781`
    //   - 播放清单：`/playlist?list=38158`（「我的」页第 4 行「播放清單」整行都是这种）
    // 早期只认 `/watch?v=`，于是「播放清單」行解析出 0 条 —— 表现是首頁少一整行、
    // 「播放清單」Tab 永远显示「暫無內容」。实测日志：
    //   rows=4 (觀看紀錄:12, 稍后观看:12, 点赞的视频:12, 播放清单:0)
    final isPlaylist = href.contains('/playlist?list=');
    if (!href.contains('/watch?v=') && !isPlaylist) return null;

    final uri = Uri.tryParse(href);
    final String cardId;
    final String detailUrl;
    if (isPlaylist) {
      final listId = uri?.queryParameters['list'] ?? '';
      if (listId.isEmpty) return null;
      cardId = 'pl_$listId';
      detailUrl = '$baseUrl/playlist?list=$listId';
    } else {
      final videoId = uri?.queryParameters['v'] ?? '';
      if (videoId.isEmpty) return null;
      cardId = videoId;
      detailUrl = '$baseUrl/watch?v=$videoId';
    }

    final img = el.querySelector('img.main-thumb') ?? el.querySelector('img');
    final thumb = img?.attributes['src'] ?? img?.attributes['data-src'] ?? '';

    final durationText = el.querySelector('.duration')?.text.trim() ?? '';

    final stats = el.querySelectorAll('.stat-item');
    String viewsText = '';
    String likesText = '';
    for (final s in stats) {
      final t = s.text.trim();
      if (t.contains('%')) {
        likesText = t.replaceAll('thumb_up', '').trim();
      } else if (t.contains('次') ||
          t.contains('萬') ||
          t.contains('k') ||
          t.contains('M') ||
          t.contains('部影片')) {
        // 「1 部影片」是播放清单卡片独有的统计文案。
        viewsText = t;
      }
    }
    if (isPlaylist && viewsText.isEmpty) {
      final count = RegExp(r'([\d,]+\s*部影片)').firstMatch(link.text);
      if (count != null) {
        viewsText = count.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }

    // 标题有两套选择器，必须都认：
    //   - 首页 / 搜索页 / 订阅页 / 排行榜的 `.horizontal-card`：标题是 `<a>` 里的 `.title`
    //   - 播放页「相關影片」的另一套布局（`.playlist-video-card`）：标题在 `<a>` **外面**的
    //     `.video-info-container > h4.video-title`，那个 `<a>` 只包住封面 + 时长 + 统计
    // 漏掉后者会 fallback 到整个 `<a>`，把「时长 + 好评率 + 播放量」拼成标题
    // —— 实测在真机上显示为 `04:54 thumb_up 99% 55.4萬次`。
    final titleEl =
        el.querySelector('.title') ??
        el.querySelector('.video-title') ??
        el.querySelector('.home-rows-videos-title') ??
        link;
    var title = titleEl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (isPlaylist) {
      final explicitPlaylistTitle =
          el.querySelector('.playlist-title, .playlist-name, .title')?.text ??
          el.attributes['title'] ??
          '';
      title = (explicitPlaylistTitle.isNotEmpty ? explicitPlaylistTitle : title)
          .replaceAll('playlist_play', '')
          .replaceAll(RegExp(r'\d[\d,]*\s*部影片'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    // 作者 / 时间同样两套：前者 `.subtitle > a` + `.subtitle-time`，
    // 后者 `.meta-author > a` + `.meta-stats > span`。
    // 漏掉后者的表现是作者全部退化成兜底值 `Hanime1`。
    final subtitle = el.querySelector('.subtitle');
    final authorEl =
        subtitle?.querySelector('a') ?? el.querySelector('.meta-author a');
    final author = authorEl?.text.trim() ?? 'Hanime1';
    final timeEl =
        subtitle?.querySelector('.subtitle-time') ??
        el.querySelector('.meta-stats span');
    final timeStr = timeEl?.text.replaceAll('•', '').trim() ?? '';

    return VideoItem(
      id: cardId,
      title: title.isNotEmpty
          ? title
          : (isPlaylist ? 'Hanime1 播放清單 #$cardId' : 'Hanime1 动漫 #$cardId'),
      author: author,
      hlsUrl: '',
      detailUrl: detailUrl,
      thumbnailUrl: thumb.isNotEmpty ? thumb : null,
      durationStr: durationText.isNotEmpty ? durationText : null,
      viewsStr: viewsText.isNotEmpty ? viewsText : null,
      publishedAt: timeStr.isNotEmpty ? timeStr : null,
      description: likesText.isNotEmpty ? likesText : null, // 保存好评率
    );
  }

  List<VideoItem> _parseVideoCards(String html, {dom.Document? document}) {
    final doc = document ?? html_parser.parse(html);
    final items = <VideoItem>[];
    final seen = <String>{};

    for (final el in doc.querySelectorAll(
      '.video-item-container, .horizontal-card, '
      '.search-rows-wrapper a[href*="/watch?v="], '
      'a[href*="/playlist?list="]',
    )) {
      final item = _parseSingleCard(el);
      if (item != null && seen.add(item.id)) {
        items.add(item);
      }
    }
    return items;
  }
}

/// Parse only the official recommendations tab. The whole watch page also
/// contains the series playlist, navigation cards, and unrelated home rows;
/// scanning the document globally made those cards appear as recommendations.
List<VideoItem> _parseHanimeRelatedCards(String html, String currentVideoId) {
  final doc = html_parser.parse(html);
  final relatedRoot = doc.querySelector('#related-tabcontent');
  if (relatedRoot == null) return const <VideoItem>[];

  final results = <VideoItem>[];
  final seen = <String>{currentVideoId};
  final cards = relatedRoot.querySelectorAll(
    '.video-item-container, .horizontal-card, .playlist-video-card, '
    'a[href*="/watch?v="]',
  );
  final parser = Hanime1Source._parseSingleCard;
  for (final card in cards) {
    final item = parser(card);
    if (item != null && seen.add(item.id)) results.add(item);
  }
  return results;
}
