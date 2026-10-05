/// 内容源抽象层。
///
/// 设计意图：把"视频从哪来"和"视频怎么展示/播放/下载"彻底分开。
/// 上层（home / search / player / downloads 四个模块）只依赖本文件里的接口，
/// 不认识任何具体的站点或协议。
///
/// 新增一个内容源 = 新增一个 [VideoSource] 实现 + 在 [SourceRegistry] 注册一行。
/// 上层代码零改动。
library;

import '../models/video_item.dart';

/// 搜索到的用户/作者条目。
class SearchedUser {
  const SearchedUser({
    required this.name,
    required this.authorUrl,
    this.authorId = '',
    this.count = 0,
  });

  final String name;
  final String authorUrl;
  final String authorId;
  final int count;
}

/// 一页结果。
class VideoPage {
  const VideoPage({
    required this.items,
    required this.page,
    required this.hasMore,
    this.totalPages = 1,
    this.totalItems = 0,
    this.users = const <SearchedUser>[],
    this.summary,
  });

  const VideoPage.empty()
    : items = const <VideoItem>[],
      page = 1,
      hasMore = false,
      totalPages = 1,
      totalItems = 0,
      users = const <SearchedUser>[],
      summary = null;

  final List<VideoItem> items;
  final int page;
  final bool hasMore;
  final int totalPages;
  final int totalItems;
  final List<SearchedUser> users;
  final String? summary;

  bool get isEmpty => items.isEmpty && users.isEmpty;
}

/// 同一路视频的不同清晰度。
class VideoVariant {
  const VideoVariant({required this.label, required this.url});

  /// 展示用标签，例如 `1080p` / `720p`。
  final String label;

  /// 对应的 m3u8 地址。
  final String url;
}

/// 详情页数据：条目本体 + 可选的多清晰度列表 + 相关推荐视频。
class VideoDetail {
  const VideoDetail({
    required this.video,
    this.variants = const <VideoVariant>[],
    this.relatedVideos = const <VideoItem>[],
  });

  final VideoItem video;
  final List<VideoVariant> variants;
  final List<VideoItem> relatedVideos;
}

/// 排序方式。
enum SortOrder {
  relevance('相关度'),
  newest('最新'),
  popular('最热');

  const SortOrder(this.label);
  final String label;
}

enum SearchType {
  videoName('搜视频名称'),
  authorId('搜作者ID');

  const SearchType(this.label);
  final String label;
}

/// 检索条件（支持按官网维度的排序、分类、发布时间、播放量、时长多重筛选）。
class SearchQuery {
  const SearchQuery({
    this.keyword = '',
    this.searchType = SearchType.videoName,
    this.tags = const <String>[],
    this.tagBroad = false,
    this.author,
    this.sort = SortOrder.relevance,
    this.sortParam = '',
    this.category = '',
    this.time = '',
    this.views = '',
    this.duration = '',
  });

  final String keyword;
  final SearchType searchType;

  /// 标签筛选值。多选 —— 数组里每一项都会单独提交一次（如 `tags[]=A&tags[]=B`）。
  final List<String> tags;

  /// 多标签之间的匹配语义。
  ///
  /// `false`（默认）= 必须**同时包含全部**所选标签（AND）；
  /// `true` = 包含**任意一个**即可（OR）。
  ///
  /// 对应 Hanime1 官网「標籤」弹窗顶部的 `broad` 开关（`broad=on` 表示 OR）。
  /// 其余内容源暂不支持该维度，忽略此字段即可。
  final bool tagBroad;

  final String? author;
  final SortOrder sort;
  final String sortParam;
  final String category;
  final String time;
  final String views;
  final String duration;

  bool get isEmpty =>
      keyword.trim().isEmpty &&
      tags.isEmpty &&
      (author == null || author!.trim().isEmpty);

  SearchQuery copyWith({
    String? keyword,
    SearchType? searchType,
    List<String>? tags,
    bool? tagBroad,
    String? author,
    SortOrder? sort,
    String? sortParam,
    String? category,
    String? time,
    String? views,
    String? duration,
  }) {
    return SearchQuery(
      keyword: keyword ?? this.keyword,
      searchType: searchType ?? this.searchType,
      tags: tags ?? this.tags,
      tagBroad: tagBroad ?? this.tagBroad,
      author: author ?? this.author,
      sort: sort ?? this.sort,
      sortParam: sortParam ?? this.sortParam,
      category: category ?? this.category,
      time: time ?? this.time,
      views: views ?? this.views,
      duration: duration ?? this.duration,
    );
  }
}

enum ChannelType {
  home('首页'),
  video('视频'),
  kedou('蝌蚪'),
  vod('精品');

  const ChannelType(this.label);
  final String label;
}

/// 官方视频分类定义
class VideoCategory {
  const VideoCategory({
    required this.id,
    required this.name,
    required this.path,
    this.channel = ChannelType.video,
  });

  final String id;
  final String name;
  final String path;
  final ChannelType channel;
}

/// 官方三大频道全量分类集合
class VideoCategories {
  VideoCategories._();

  /// 视频频道 14 大官方分类
  static const List<VideoCategory> videoList = <VideoCategory>[
    VideoCategory(
      id: 'latest',
      name: '最近更新',
      path: '/video/category/latest',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'hd',
      name: '高清视频',
      path: '/video/category/hd',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'ori',
      name: '91原创',
      path: '/video/category/ori',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'hot-list',
      name: '当前最热',
      path: '/video/category/hot-list',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'recent-favorite',
      name: '最近加精',
      path: '/video/category/recent-favorite',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'recent-rating',
      name: '最近得分',
      path: '/video/category/recent-rating',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'nonpaid',
      name: '非付费',
      path: '/video/category/nonpaid',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'long-list',
      name: '10分钟以上',
      path: '/video/category/long-list',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'longer-list',
      name: '20分钟以上',
      path: '/video/category/longer-list',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'month-discuss',
      name: '本月讨论',
      path: '/video/category/month-discuss',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'top-favorite',
      name: '本月收藏',
      path: '/video/category/top-favorite',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'most-favorite',
      name: '收藏最多',
      path: '/video/category/most-favorite',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'top-list',
      name: '本月最热',
      path: '/video/category/top-list',
      channel: ChannelType.video,
    ),
    VideoCategory(
      id: 'top-last',
      name: '上月最热',
      path: '/video/category/top-last',
      channel: ChannelType.video,
    ),
  ];

  /// 蝌蚪频道 3 大排序 + 18 大专区
  static const List<VideoCategory> kedouSorts = <VideoCategory>[
    VideoCategory(
      id: 'latest-updates',
      name: '最近更新',
      path: '/videos/latest-updates',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'top-rated',
      name: '最高评分',
      path: '/videos/top-rated',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'most-popular',
      name: '最受欢迎',
      path: '/videos/most-popular',
      channel: ChannelType.kedou,
    ),
  ];

  static const List<VideoCategory> kedouCategories = <VideoCategory>[
    VideoCategory(
      id: 'chinese',
      name: '国产',
      path: '/videos/categories/chinese',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'europe-america',
      name: '欧美',
      path: '/videos/categories/europe-america',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'japan-korea',
      name: '日韩',
      path: '/videos/categories/japan-korea',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'anime',
      name: '动漫',
      path: '/videos/categories/anime',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'hd',
      name: '高清AV',
      path: '/videos/categories/hd',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'fornication',
      name: '乱伦',
      path: '/videos/categories/fornication',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'homosexual',
      name: '同性',
      path: '/videos/categories/homosexual',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'sm',
      name: 'SM专区',
      path: '/videos/categories/sm',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'guodong',
      name: '果冻传媒',
      path: '/videos/categories/guodong',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'xingkong',
      name: '星空传媒',
      path: '/videos/categories/xingkong',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'madou',
      name: '麻豆传媒',
      path: '/videos/categories/madou',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'tianmei',
      name: '天美传媒',
      path: '/videos/categories/tianmei',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'jingdong',
      name: '精东影业',
      path: '/videos/categories/jingdong',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'swag',
      name: '台湾SWAG',
      path: '/videos/categories/swag',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'tuzi',
      name: '兔子先生',
      path: '/videos/categories/tuzi',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'mitao',
      name: '蜜桃传媒',
      path: '/videos/categories/mitao',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'huangjia',
      name: '皇家华人',
      path: '/videos/categories/huangjia',
      channel: ChannelType.kedou,
    ),
    VideoCategory(
      id: 'jijin',
      name: '片商集锦',
      path: '/videos/categories/jijin',
      channel: ChannelType.kedou,
    ),
  ];

  static List<VideoCategory> get kedouList => [
    ...kedouSorts,
    ...kedouCategories,
  ];

  /// 精品频道 4 大分类
  static const List<VideoCategory> vodList = <VideoCategory>[
    VideoCategory(
      id: 'all',
      name: '全部',
      path: '/vod',
      channel: ChannelType.vod,
    ),
    VideoCategory(
      id: 'ori',
      name: '原创',
      path: '/vod/%E5%8E%9F%E5%88%9B',
      channel: ChannelType.vod,
    ),
    VideoCategory(
      id: 'fwd',
      name: '转发',
      path: '/vod/%E8%BD%AC%E5%8F%91',
      channel: ChannelType.vod,
    ),
    VideoCategory(
      id: 'sponsor',
      name: '赞助',
      path: '/vod/%E8%B5%9E%E5%8A%A9',
      channel: ChannelType.vod,
    ),
  ];
}

/// 内容源接口。所有实现都必须是无状态的（分页游标由调用方传入）。
abstract class VideoSource {
  /// 稳定标识，用于持久化与切换。
  String get id;

  /// 展示名。
  String get displayName;

  /// 该源的频道分类列表
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

  /// 该源提供的全部标签，用于搜索页的筛选芯片。
  Future<List<String>> fetchTags();

  /// 首页 / 分类列表分页拉取。
  Future<VideoPage> fetchPage({required int page, int pageSize = 12});

  /// 频道与专区分类分页拉取。
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  });

  /// 提取首页「热搜」关键词列表。
  Future<List<String>> fetchHotKeywords();

  /// 检索。实现方负责解释 [SearchQuery]。
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  });

  /// 拉取详情（含多清晰度）。
  Future<VideoDetail?> fetchDetail(String videoId, {bool forceRefresh = false});

  /// 快速同步获取内存中已解析就绪的 HLS 地址（若已缓存，立即返回，耗时 0ms）
  String? getCachedHlsUrl(String videoId) => null;
}

/// 各内容源「地址归属」的旁路登记表：源 id → 该源地址里必然出现的标记串。
///
/// **为什么不直接往 [VideoSource] 接口上加成员**：接口的实现方用的是
/// `implements` 而不是 `extends`，加一个抽象成员会**强制所有实现一起补齐**
/// （包括不允许改动的 91 源）。用扩展 + 静态表就绕开了这一点 —— 新增源只需
/// 在下面登记一行，既有源零改动。
const Map<String, Set<String>> _ownedUrlMarkers = <String, Set<String>>{
  'hanime1': <String>{'hanime1.me'},
  // PornHub 有三个域名变体（cn / www / 各地分站），任一命中即视为本源条目。
  'pornhub': <String>{'pornhub.com', 'pornhub.net'},
  // 91麻豆 主站与镜像站都跑同一套 MacCMS，用固定主站标记即可（镜像由用户自加）。
  'site91md': <String>{'91md.me'},
};

/// 内容源归属判断。
///
/// 用途：预加载队列（`PreloadService`）是全局单例，切源后旧源的控制器依然
/// 存活并继续往队列里塞整页条目。`preloadList` 用它把「不属于当前激活源」的
/// 条目挡在门外，避免用户在 A 站浏览时后台却为 B 站做嗅探/下载/解析 ——
/// 真机实测这种错配会让主 isolate 被占满并最终 ANR。
extension VideoSourceOwnership on VideoSource {
  /// 该条目是否属于本源。
  ///
  /// 未登记标记的源一律返回 `true`（不做限制，保持既有行为）；`detailUrl`
  /// 为空的条目也放行（无从判断时不误伤）。
  bool ownsItem(VideoItem item) {
    if (id == 'site91md' && SourceRegistry.isSite91MdVideo(item)) return true;
    final markers = _ownedUrlMarkers[id];
    if (markers == null || markers.isEmpty) return true;
    final url = item.detailUrl ?? '';
    if (url.isEmpty) return true;
    for (final m in markers) {
      if (url.contains(m)) return true;
    }
    return false;
  }
}

/// 内容源注册表。
class SourceRegistry {
  SourceRegistry._();

  static final List<VideoSource> _sources = <VideoSource>[];
  static VideoSource? _activeSource;

  static List<VideoSource> get all => List<VideoSource>.unmodifiable(_sources);

  static void register(VideoSource source) {
    if (_sources.any((s) => s.id == source.id)) return;
    _sources.add(source);
    _activeSource ??= source;
  }

  static VideoSource? byId(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Saved 91md items must keep their parser when another site is selected.
  static bool isSite91MdVideo(VideoItem item) =>
      item.author == '91麻豆' ||
      RegExp(r'/vod/(?:play|detail)/id/\d+')
          .hasMatch(item.detailUrl ?? item.id);

  static VideoSource forVideo(VideoItem item, {required VideoSource fallback}) {
    if (isSite91MdVideo(item)) return byId('site91md') ?? fallback;
    return fallback;
  }

  static VideoSource get defaultSource {
    if (_sources.isEmpty) {
      throw StateError('SourceRegistry 为空。请在 main() 中调用 register。');
    }
    return _activeSource ?? _sources.first;
  }

  static void setActiveSource(VideoSource source) {
    _activeSource = source;
  }
}
