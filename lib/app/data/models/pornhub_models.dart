/// PornHub 专有的列表模型（片单、色情明星）。
///
/// 这两类**不是视频**，因此不能塞进 [VideoItem]：片单是一个视频集合，
/// 明星是一个创作者。它们各自的详情页才是视频列表
/// （实测 `/playlist/<id>` 23 张卡片、`/pornstar/<name>` 39 张卡片），
/// 所以这里只描述「集合本身」，点进去后复用标准的视频解析器。
library;

import 'package:meta/meta.dart';

import 'video_item.dart';

/// 一个片单。
@immutable
class PornHubPlaylist {
  const PornHubPlaylist({
    required this.id,
    required this.title,
    required this.url,
    this.videoCount = 0,
    this.coverUrl,
  });

  /// 数字 id（来自 `li#playlist_<id>`）。
  final String id;

  final String title;

  /// 站内相对路径 `/playlist/<id>`。
  final String url;

  /// 片单内视频数（来自 `.number` 文案「15 个视频」）。
  final int videoCount;

  final String? coverUrl;

  /// 从 `.number` 文案里取出数字；取不到返回 0。
  static int parseCount(String raw) {
    final match = RegExp(r'([\d,]+)').firstMatch(raw);
    return match == null
        ? 0
        : (int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0);
  }
}

/// 一位色情明星 / 模特。
@immutable
class PornHubStar {
  const PornHubStar({
    required this.name,
    required this.url,
    this.rank = 0,
    this.avatarUrl,
  });

  /// 展示名（来自 `a[alt]` 或 `img[alt]`）。
  final String name;

  /// 站内相对路径 `/pornstar/<name>`。
  final String url;

  /// 榜单名次（来自 `.rankNumber`）；0 表示未提供。
  final int rank;

  final String? avatarUrl;
}

/// 一个「订阅的创作者」（来自 `/users/<name>/subscriptions` 页）。
///
/// 与 [PornHubStar] 的区别：明星页的名次（`rank`）在这里没有意义，
/// 而这里必须保留**站内相对路径** —— 它同时是「取该创作者视频」的入口
/// （实测该页 href 有三种前缀：`/model/<slug>` 35 个、`/pornstar/<name>` 13 个、
/// `/users/<name>` 3 个，三者都能直接用 `fetchPathPage` 取到视频卡片）。
@immutable
class PornHubSubscription {
  const PornHubSubscription({
    required this.name,
    required this.path,
    this.avatarUrl,
    this.userId = '',
  });

  /// 展示名（来自 `a.usernameLink` 文本，回退 `img.alt`）。
  final String name;

  /// 站内相对路径，如 `/model/vita-won`。既是主页也是取视频的入口。
  final String path;

  final String? avatarUrl;

  /// 官网 `data-userid`（实测 52 项均有值）。
  final String userId;
}

/// 详情页上「分类 / 标签」这类可点击的胶囊项：名字 + 站内路径。
///
/// 分类跳 `/categories/<slug>`、标签跳搜索页；路径原样保留，是否响应跳转由 UI 决定。
@immutable
class PornHubLinkItem {
  const PornHubLinkItem({required this.name, required this.path});

  final String name;

  /// 站内相对路径（如 `/categories/teen`、`/video?search=...`）。
  final String path;
}

/// 详情页 `#under-player-comments` 里的一条评论。
@immutable
class PornHubComment {
  const PornHubComment({
    required this.user,
    required this.message,
    this.avatarUrl,
    this.upvotes = 0,
    this.downvotes = 0,
  });

  final String user;
  final String message;
  final String? avatarUrl;
  final int upvotes;
  final int downvotes;
}

/// 一次详情页抓取解析出的全部扩展内容（四个 Tab + 分类 / 标签 / 明星 + 动作参数）。
///
/// 为什么要合成一个模型一次返回：这四个 Tab、分类、标签、色情明星**都在同一份
/// 详情页 HTML 里**（实测），如果每个 Tab 各自发一次请求，一部片子会重复下载
/// 约 4.7 MB 的页面 4 次。合成一次抓取后，切 Tab 只是切本地数据。
@immutable
class PornHubDetailExtra {
  const PornHubDetailExtra({
    this.related = const <VideoItem>[],
    this.recommended = const <VideoItem>[],
    this.categories = const <PornHubLinkItem>[],
    this.tags = const <PornHubLinkItem>[],
    this.pornstars = const <PornHubLinkItem>[],
    this.comments = const <PornHubComment>[],
    this.playlists = const <PornHubPlaylist>[],
    this.token = '',
    this.videoId = '',
    this.favouriteUrl = '/video/favourite',
    this.creatorPath = '',
    this.subscribeUrl = '',
    this.unsubscribeUrl = '',
    this.isSubscribed = false,
    this.isFavourite = false,
  });

  /// 「相关」Tab：`#relatedVideosListing`。
  final List<VideoItem> related;

  /// 「推荐」Tab：`#recommendedVideosListing`。
  final List<VideoItem> recommended;

  /// `div.categoriesWrapper` 里的 `a.item`。
  final List<PornHubLinkItem> categories;

  /// `div.tagsWrapper` 里的 `a.item.isTag > span`。
  final List<PornHubLinkItem> tags;

  /// `div.pornstarsWrapper` 里的 `a.pstar-list-btn`（name=文本，path=href）。
  final List<PornHubLinkItem> pornstars;

  /// `#under-player-comments` 里的评论。
  final List<PornHubComment> comments;

  /// `#under-player-playlists` 里的片单。
  final List<PornHubPlaylist> playlists;

  /// 本页写操作令牌（内联脚本里的 `token`），随页面下发。
  final String token;

  /// 数字视频 id（`data-video-id` / `video_id`）—— 添加片单的 `vid` 必须用它，
  /// 不能用 viewkey。
  final String videoId;

  /// 最爱端点（内联脚本里的 `favouriteUrl`），默认 `/video/favourite`。
  final String favouriteUrl;

  /// UP主主页路径（上传者链接，如 `/model/<slug>`）。
  ///
  /// 优先用于「作品」按钮；为空时 UI 回退到第一个 [pornstars] 的 path。
  final String creatorPath;
  final String subscribeUrl;
  final String unsubscribeUrl;
  final bool isSubscribed;
  final bool isFavourite;

  PornHubDetailExtra withPlaylists(List<PornHubPlaylist> value) =>
      PornHubDetailExtra(
        related: related,
        recommended: recommended,
        categories: categories,
        tags: tags,
        pornstars: pornstars,
        comments: comments,
        playlists: value,
        token: token,
        videoId: videoId,
        favouriteUrl: favouriteUrl,
        creatorPath: creatorPath,
        subscribeUrl: subscribeUrl,
        unsubscribeUrl: unsubscribeUrl,
        isSubscribed: isSubscribed,
        isFavourite: isFavourite,
      );

  bool get isEmpty =>
      related.isEmpty &&
      recommended.isEmpty &&
      categories.isEmpty &&
      tags.isEmpty &&
      pornstars.isEmpty &&
      comments.isEmpty &&
      playlists.isEmpty;
}

@immutable
class PornHubCreatorProfile {
  const PornHubCreatorProfile({
    required this.path,
    this.name = '',
    this.avatarUrl,
    this.videoCount,
    this.subscribeUrl = '',
    this.unsubscribeUrl = '',
    this.isSubscribed = false,
  });
  final String path;
  final String name;
  final String? avatarUrl;
  final int? videoCount;
  final String subscribeUrl;
  final String unsubscribeUrl;
  final bool isSubscribed;
}

@immutable
class PornHubFilterGroup {
  const PornHubFilterGroup({
    required this.key,
    required this.title,
    required this.options,
    this.multiple = false,
    this.selected = '',
  });
  final String key;
  final String title;
  final List<PornHubLinkItem> options;
  final bool multiple;
  final String selected;
}

@immutable
class PornHubPlaylistDetails {
  const PornHubPlaylistDetails({
    required this.playlist,
    this.token = '',
    this.addUrl = '',
    this.removeUrl = '',
    this.chunkUrl = '',
    this.isFavourite = false,
    this.videos = const [],
    this.createdAt,
    this.updatedAt,
  });
  final DateTime? createdAt, updatedAt;
  final PornHubPlaylist playlist;
  final String token, addUrl, removeUrl, chunkUrl;
  final bool isFavourite;
  final List<VideoItem> videos;
}
