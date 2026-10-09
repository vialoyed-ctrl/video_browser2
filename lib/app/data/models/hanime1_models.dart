/// Hanime1 专属移动端数据模型体系。
///
/// 严格对齐 Hanime1 官方移动端视觉与结构：
/// 1. 顶部 Hero Banner 焦点视频（标题、播放量、发布时间、标签集、播放/资讯按钮）；
/// 2. 分类横滑胶囊条 (Genre Tabs)；
/// 3. 多栏目视频板块 (Section Rows，如最新上市、最新上傳、裏番、泡麵番等)；
/// 4. 创作者关注列表 (Creator Circles) 与多维筛选器 (Subscriptions Filters)。
library;

// 与 `video_item.dart` 保持一致：数据模型层刻意不依赖 Flutter。
import 'package:meta/meta.dart';

import 'video_item.dart';

/// 移动端顶部 Hero 焦点视频条目
class Hanime1HeroItem {
  const Hanime1HeroItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.coverUrl,
    required this.watchUrl,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String coverUrl;
  final String watchUrl;

  VideoItem toVideoItem() {
    return VideoItem(
      id: id,
      title: title,
      author: subtitle.split('•').first.trim(),
      hlsUrl: '',
      detailUrl: watchUrl,
      thumbnailUrl: coverUrl,
      tags: tags,
      description: subtitle,
    );
  }
}

/// 首页多栏目板块（例如：最新上市、最新上傳、裏番等）
class Hanime1Section {
  const Hanime1Section({
    required this.title,
    required this.morePath,
    required this.items,
  });

  final String title;
  final String morePath;
  final List<VideoItem> items;
}

/// 首页完整结构化数据集合
class Hanime1HomeData {
  const Hanime1HomeData({
    required this.genreTabs,
    required this.hero,
    required this.sections,
    this.genreValues = const <String, String>{},
  });

  final List<String> genreTabs;

  /// Visible category label to the site's `genre` query value.
  final Map<String, String> genreValues;
  final Hanime1HeroItem? hero;
  final List<Hanime1Section> sections;
}

/// 订阅中心创作者头像圆圈条目
class Hanime1Creator {
  const Hanime1Creator({
    required this.name,
    required this.queryPath,
    this.avatarUrl,
    this.isSelected = false,
  });

  final String name;
  final String queryPath;
  final String? avatarUrl;
  final bool isSelected;
}

/// 订阅页（/subscriptions）结构化数据集合
class Hanime1SubscriptionData {
  const Hanime1SubscriptionData({
    required this.creators,
    required this.filters,
    required this.items,
    required this.hasMore,
    this.page = 1,
    this.totalPages = 1,
  });

  final List<Hanime1Creator> creators;
  final List<String> filters;
  final List<VideoItem> items;
  final bool hasMore;
  final int page;
  final int totalPages;
}

/// 单个标签（官网 `div.single-video-tag`，含使用计数 `span`）。
class Hanime1Tag {
  const Hanime1Tag({required this.name, required this.path, this.count = 0});

  /// 标签名，例如 `1080p`。
  final String name;

  /// 站内相对路径，例如 `/search?tags%5B%5D=1080p&genre=裏番`。
  final String path;

  /// 官网标签后括号里的数量，例如 `(5)` → 5。取不到为 0。
  final int count;
}

/// 标签筛选分组（官网 `/search` 页「標籤」弹窗里的一节 `<h5>`）。
class Hanime1TagGroup {
  const Hanime1TagGroup({required this.title, required this.tags});

  /// 分组标题，例如 `影片屬性`。
  final String title;

  /// 该分组下的全部标签值（= `input[name="tags[]"]` 的 value）。
  final List<String> tags;
}

/// 官网 `/search` 页「標籤」弹窗的全部标签，逐字取自真实 HTML。
///
/// 来源结构（弹窗 `div.modal > div.modal-body`）：
/// ```
/// <h5>影片屬性</h5>
/// <label class="hentai-tags-wrapper">
///   <input name="tags[]" type="checkbox" value="無碼">
///   <span class="checkmark">無碼</span>
/// </label>
/// ```
/// 共 7 组 240 项。分组顺序与组内顺序都与官网一致 —— 这个顺序是站点排的，
/// 不要按字母或笔画重排，否则用户找不到熟悉的位置。
///
/// 提交语义（由官网 `#broad` 开关决定，见 [Hanime1Source.search]）：
/// * 默认（`broad` 关闭）：**同时包含全部**所选标签；
/// * 打开 `broad=on`：包含**任意一个**所选标签。
const List<Hanime1TagGroup> hanime1TagGroups = <Hanime1TagGroup>[
  Hanime1TagGroup(
    title: '影片屬性',
    tags: <String>[
      '無碼',
      'AI解碼',
      '中文字幕',
      '中文配音',
      '同人作品',
      '斷面圖',
      'ASMR',
      '1080p',
      '60FPS',
    ],
  ),
  Hanime1TagGroup(
    title: '人物關係',
    tags: <String>['近親', '姐', '妹', '母', '女兒', '師生', '情侶', '青梅竹馬', '同事'],
  ),
  Hanime1TagGroup(
    title: '角色設定',
    tags: <String>[
      'JK',
      '處女',
      '御姐',
      '熟女',
      '人妻',
      '女教師',
      '男教師',
      '女醫生',
      '女病人',
      '護士',
      'OL',
      '女警',
      '大小姐',
      '偶像',
      '女僕',
      '巫女',
      '魔女',
      '修女',
      '風俗娘',
      '公主',
      '女忍者',
      '女戰士',
      '女騎士',
      '魔法少女',
      '異種族',
      '天使',
      '妖精',
      '魔物娘',
      '魅魔',
      '吸血鬼',
      '女鬼',
      '獸娘',
      '福瑞',
      '乳牛',
      '機械娘',
      '碧池',
      '痴女',
      '雌小鬼',
      '不良少女',
      '傲嬌',
      '病嬌',
      '無口',
      '無表情',
      '眼神死',
      '正太',
      '偽娘',
      '扶他',
    ],
  ),
  Hanime1TagGroup(
    title: '外貌身材',
    tags: <String>[
      '短髮',
      '馬尾',
      '雙馬尾',
      '丸子頭',
      '巨乳',
      '乳環',
      '舌環',
      '貧乳',
      '黑皮膚',
      '曬痕',
      '眼鏡娘',
      '獸耳',
      '尖耳朵',
      '異色瞳',
      '美人痣',
      '肌肉女',
      '白虎',
      '陰毛',
      '腋毛',
      '大屌',
      '黑屌',
      '著衣',
      '水手服',
      '體操服',
      '泳裝',
      '比基尼',
      '死庫水',
      '和服',
      '兔女郎',
      '圍裙',
      '啦啦隊',
      '絲襪',
      '吊襪帶',
      '熱褲',
      '迷你裙',
      '性感內衣',
      '緊身衣',
      '丁字褲',
      '高跟鞋',
      '睡衣',
      '婚紗',
      '旗袍',
      '古裝',
      '哥德',
      '口罩',
      '刺青',
      '淫紋',
      '身體寫字',
    ],
  ),
  Hanime1TagGroup(
    title: '情境場所',
    tags: <String>[
      '校園',
      '教室',
      '圖書館',
      '保健室',
      '體育倉庫',
      '游泳池',
      '愛情賓館',
      '醫院',
      '辦公室',
      '浴室',
      '窗邊',
      '公共廁所',
      '公眾場合',
      '戶外野戰',
      '電車',
      '車震',
      '遊艇',
      '露營帳篷',
      '電影院',
      '健身房',
      '沙灘',
      '溫泉',
      '夜店',
      '監獄',
      '教堂',
    ],
  ),
  Hanime1TagGroup(
    title: '故事劇情',
    tags: <String>[
      '純愛',
      '戀愛喜劇',
      '後宮',
      '十指緊扣',
      '開大車',
      'NTR',
      '精神控制',
      '藥物',
      '痴漢',
      '阿嘿顏',
      '哭泣',
      '精神崩潰',
      '獵奇',
      'BDSM',
      '綑綁',
      '眼罩',
      '項圈',
      '調教',
      '異物插入',
      '尋歡洞',
      '肉便器',
      '性奴隸',
      '胃凸',
      '強制',
      '輪姦',
      '凌辱',
      '性暴力',
      '逆強制',
      '女王樣',
      '榨精',
      '母女丼',
      '姐妹丼',
      '出軌',
      '醉酒',
      '攝影',
      '睡眠姦',
      '機械姦',
      '蟲姦',
      '性轉換',
      '百合',
      '耽美',
      '時間停止',
      '異世界',
      '怪獸',
      '哥布林',
      '世界末日',
    ],
  ),
  Hanime1TagGroup(
    title: '性交體位',
    tags: <String>[
      '手交',
      '指交',
      '玩乳頭',
      '乳交',
      '乳頭交',
      '肛交',
      '雙洞齊下',
      '腳交',
      '素股',
      '拳交',
      '3P',
      '群交',
      '口交',
      '跪舔',
      '深喉嚨',
      '口爆',
      '吞精',
      '舔蛋蛋',
      '舔穴',
      '69',
      '自慰',
      '腋交',
      '舔腋下',
      '髮交',
      '舔耳朵',
      '舔腳',
      '內射',
      '外射',
      '顏射',
      '潮吹',
      '懷孕',
      '噴奶',
      '放尿',
      '排便',
      '騎乘位',
      '背後位',
      '側面位',
      '顏面騎乘',
      '火車便當',
      '一字馬',
      '性玩具',
      '飛機杯',
      '跳蛋',
      '毒龍鑽',
      '觸手',
      '獸交',
      '頸手枷',
      '扯頭髮',
      '掐脖子',
      '打屁股',
      '肉棒打臉',
      '陰道外翻',
      '男乳首責',
      '接吻',
      '舌吻',
      'POV',
    ],
  ),
];

/// 播放页评论（官网 `#comment-section-wrapper` 内的一级评论或回复）。
///
/// 官网评论是 AJAX 异步加载的：进入「評論」Tab 才 `GET /loadComment`，
/// 展开「查看 N 則回覆」才 `GET /loadReplies`，所以这里也按需拉取。
///
/// 抓到的真实结构（一级评论）：
/// ```
/// <a><img class="img-circle" src=头像></a>
/// <div class="report-btn-wrapper">
///   <div class="comment-index-text"><a>作者名 <span>1年前</span></a></div>
///   <div class="comment-index-text">正文</div>
///   <span class="report-btn" data-reportable-id="177147" data-reportable-type="comment">
/// </div>
/// <div id="comment-like-form-wrapper">
///   <div><span>thumb_up</span><span>59</span></div>
///   <div><span>thumb_down</span></div>
///   <span>回覆</span>
///   <div class="load-replies-btn" data-commentid="177147">…查看 16 則回覆</div>
///   <div id="reply-section-wrapper-177147"></div>
/// </div>
/// ```
/// 回复（`GET /loadReplies`）的差别只有两处：外层是 `div#reply-start-{id}`，
/// 头像 `<a>` 被包进 `.report-btn-wrapper` 内部。
class Hanime1Comment {
  const Hanime1Comment({
    required this.commentId,
    required this.authorName,
    this.authorPath = '',
    this.avatarUrl = '',
    this.timeText = '',
    this.body = '',
    this.likeCount = 0,
    this.replyCount = 0,
    this.replies = const <Hanime1Comment>[],
  });

  /// 评论 id（`data-reportable-id`），也是 `/loadReplies?id=` 的参数。
  final String commentId;

  final String authorName;

  /// 作者主页链接。官网评论的作者名是不带 href 的 `<a>`，通常为空。
  final String authorPath;

  final String avatarUrl;

  /// 相对时间，例如 `1年前`。
  final String timeText;

  /// 评论正文（官网为纯文本，`\n` 未转 `<br>`，这里保留原样）。
  final String body;

  /// 点赞数，可为负数（官网确实出现过 `-8`）。
  final int likeCount;

  /// 回复条数。0 表示没有「查看 N 則回覆」入口。
  final int replyCount;

  /// 已展开的回复。空列表 = 尚未展开或确实没有回复。
  final List<Hanime1Comment> replies;

  Hanime1Comment copyWith({List<Hanime1Comment>? replies}) {
    return Hanime1Comment(
      commentId: commentId,
      authorName: authorName,
      authorPath: authorPath,
      avatarUrl: avatarUrl,
      timeText: timeText,
      body: body,
      likeCount: likeCount,
      replyCount: replyCount,
      replies: replies ?? this.replies,
    );
  }
}

/// 播放页（`/watch?v=`）的附加元数据。
///
/// 对齐官网 `video-buttons-wrapper` / `video-tags-wrapper` /
/// `video-description-panel` / `#tab-comments-count` 四处结构。
///
/// 这些字段无法塞进通用 [VideoItem]（那是为「内容源无关」设计的），
/// 所以单独用一个模型，由 [Hanime1Source] 解析后在播放页读取。
class Hanime1VideoExtra {
  const Hanime1VideoExtra({
    this.viewsText = '',
    this.releaseDate = '',
    this.likePercent = '',
    this.likeCount = '',
    this.isSubscribed = false,
    this.isLiked = false,
    this.isDisliked = false,
    this.commentCount = '',
    this.uploaderName = '',
    this.uploaderPath = '',
    this.uploaderAvatar = '',
    this.artistName = '',
    this.artistPath = '',
    this.artistAvatar = '',
    this.genreName = '',
    this.genrePath = '',
    this.durationText = '',
    this.coverUrl = '',
    this.captionText = '',
    this.tags = const <Hanime1Tag>[],
    this.playlistTitle = '',
    this.playlistPath = '',
    this.playlistAuthor = '',
    this.playlistAuthorPath = '',
    this.playlistItems = const <VideoItem>[],
    this.savedPlaylistIds = const <String>[],
  });

  /// 「觀看次數：269.9萬次」里的数值部分，例如 `269.9萬次`。
  final String viewsText;

  /// 发布/贩卖日期，例如 `2024-12-12`。
  final String releaseDate;

  /// 点赞率，例如 `100%`。
  final String likePercent;

  /// 点赞数（已去掉括号），例如 `1273`。
  final String likeCount;

  /// 当前官网账号在此视频上的操作状态。
  final bool isSubscribed;
  final bool isLiked;
  final bool isDisliked;

  /// 评论条数，例如 `40`。
  final String commentCount;

  /// 上传者（官网 `video-description-panel` 里的 `上傳者`）。
  final String uploaderName;
  final String uploaderPath;
  final String uploaderAvatar;

  /// 制作方 / 作者（官网 `#video-artist-name`）。
  final String artistName;
  final String artistPath;
  final String artistAvatar;

  /// 所属分类，例如 `泡麵番`。
  final String genreName;
  final String genrePath;

  /// 时长，例如 `06:43`。
  final String durationText;

  /// 封面图（官网 `img.main-thumb`）。
  final String coverUrl;

  /// 简介原文（官网 `.video-caption-text`）。
  ///
  /// 官网播放页把它放在 `.video-description-panel` 里，用
  /// `.caption-ellipsis` 做 3 行截断（`-webkit-line-clamp:3`）。
  /// 内容是站方拼好的多行文本，形如：
  /// ```
  /// Title / タイトル: …
  /// Release / 販売日: …
  /// ```
  final String captionText;

  /// 标签集合（官网 `video-tags-wrapper` 下的 `single-video-tag`）。
  final List<Hanime1Tag> tags;

  /// 所属清单（官网 `#playlist-top-block`）。
  final String playlistTitle;
  final String playlistPath;
  final String playlistAuthor;
  final String playlistAuthorPath;

  /// 清单内的剧集（官网 `#playlist-scroll` 下的 `playlist-video-card`）。
  final List<VideoItem> playlistItems;

  /// 官网 `#video-save-form` 中当前已勾选的清单 ID。
  final List<String> savedPlaylistIds;

  /// 是否有任何值得一提的附加信息（避免播放页渲染空壳）。
  bool get hasAny =>
      viewsText.isNotEmpty ||
      likePercent.isNotEmpty ||
      commentCount.isNotEmpty ||
      uploaderName.isNotEmpty ||
      tags.isNotEmpty ||
      playlistItems.isNotEmpty;
}

/// 官网「儲存」弹层中的一个目标清单。
@immutable
class Hanime1SaveOption {
  const Hanime1SaveOption({
    required this.id,
    required this.title,
    required this.isSaved,
    this.isWatchLater = false,
  });

  /// 官网 checkbox 的 ID；内建「稍後觀看」使用 `save`。
  final String id;
  final String title;
  final bool isSaved;
  final bool isWatchLater;

  Hanime1SaveOption copyWith({bool? isSaved}) => Hanime1SaveOption(
    id: id,
    title: title,
    isSaved: isSaved ?? this.isSaved,
    isWatchLater: isWatchLater,
  );
}

/// 官网 `/playlist?list={id}` 的清单详情页。
@immutable
class Hanime1PlaylistPage {
  const Hanime1PlaylistPage({
    required this.id,
    required this.title,
    required this.creator,
    required this.creatorPath,
    required this.coverUrl,
    required this.videoCount,
    required this.viewsText,
    required this.items,
    required this.page,
    required this.hasMore,
    required this.sort,
    this.totalPages = 1,
  });

  final String id;
  final String title;
  final String creator;
  final String creatorPath;
  final String coverUrl;
  final String videoCount;
  final String viewsText;
  final List<VideoItem> items;
  final int page;
  final bool hasMore;
  final String sort;
  final int totalPages;
}

/// 官网点赞接口返回的当前状态。
class Hanime1VoteState {
  const Hanime1VoteState({
    required this.liked,
    required this.disliked,
    required this.percent,
    required this.count,
  });

  final bool liked;
  final bool disliked;
  final String percent;
  final String count;
}

// ---------------------------------------------------------------- 用户「我的」页
//
// 对齐官网 `/user/{uid}`（手机端）的真实结构，抓取的 DOM 骨架：
// ```
// #playlist-headings-wrapper            （头部，背景是头像自身的模糊图）
//   .profile-main-container
//     .profile-avatar-wrapper > a > img      头像 70x70 圆角 50%
//     .profile-content-right
//       h1.profile-display-name              昵称 25px/w700
//       .profile-sub-stats
//         .profile-sub-stats-id              "@ 100001"
//         .profile-sub-stats-new-line        "1 位訂閱者 • 0 部影片"
//       .profile-action-buttons              手機端只剩「帳戶設定」「分享」两个
//   .user-nav-bar > .nav-tabs-scroll > a.yt-tab ×7 + .yt-divider + 搜索图标
//   .tab-content-container > .tab-index-rows-wrapper
//     a.horizontal-row-title[href=...] > h3 "觀看紀錄" + div「更多 ›」
//     .home-rows-videos-wrapper.home-row.horizontal-row
//       .video-item-container > .horizontal-card ×N
// ```
//
// 实测数据（uid=100001）：4 个横排 = 觀看紀錄 12 / 稍後觀看 12 / 讚好的影片 12 / 播放清單 4。

/// 用户页里的一个视频横排（对应官网一个 `a.horizontal-row-title` + 其后的 `.home-row`）。
@immutable
class Hanime1UserRow {
  const Hanime1UserRow({
    required this.title,
    required this.path,
    required this.items,
    this.tabKey = '',
  });

  /// 行标题，例如 `觀看紀錄`。
  ///
  /// ⚠️ 官网对**登录用户**返回的 HTML 里，这个标题可能是简体
  /// （实测 `觀看紀錄` 繁体 / `稍后观看`、`点赞的视频`、`播放清单` 简体混排），
  /// 而 App 的 Tab 文案固定为繁体。**任何按标题做的等值判断都会踩坑**，
  /// 需要定位某一行时请一律用 [tabKey]。
  final String title;

  /// 「更多 ›」跳转的站内相对路径，例如 `/user/100001/histories`。
  final String path;

  /// 该行的视频（官网每行最多 12 个）。
  final List<VideoItem> items;

  /// 行标识，取自 [path] 尾段：`histories` / `saves` / `likes` / `playlists`。
  ///
  /// 这是**唯一稳定**的行标识 —— 官网改文案（简繁切换、翻译）时不会变。
  /// 解析失败时为空串，此时调用方应回退到标题归一化比对。
  final String tabKey;

  bool get isEmpty => items.isEmpty;
}

/// 官网「我的」页**单个 Tab 的独立分页**（`/user/{uid}/histories` 等）。
///
/// 官网点 Tab 不是前端切显隐，而是真的跳到一个独立分页：每页 60 张卡片、
/// 顶部带「最新 / 熱門 / 最早」排序胶囊、底部带数字分页器。首屏
/// `/user/{uid}` 只给每行 12 个预览，所以点进单个 Tab 必须重新抓这一页。
@immutable
class Hanime1UserTabPage {
  const Hanime1UserTabPage({
    required this.items,
    required this.page,
    required this.hasMore,
    this.sort = 'latest',
    this.totalPages = 1,
  });

  final List<VideoItem> items;

  /// 已加载到的页码（从 1 开始）。
  final int page;

  /// 是否还有下一页（由 `.user-items-pagination a[rel="next"]` 是否存在决定）。
  final bool hasMore;

  /// `latest` / `popular` / `oldest`，对应官网三个 `.filter-pill`。
  final String sort;
  final int totalPages;

  static const Hanime1UserTabPage empty = Hanime1UserTabPage(
    items: <VideoItem>[],
    page: 1,
    hasMore: false,
  );
}

/// 用户「我的」页数据（对应官网 `/user/{uid}` 首屏）。
@immutable
class Hanime1UserProfile {
  const Hanime1UserProfile({
    required this.displayName,
    required this.userId,
    required this.avatarUrl,
    required this.subStatsIdText,
    required this.subStatsLineText,
    required this.rows,
  });

  /// `h1.profile-display-name`，例如 `example_user`。
  final String displayName;

  /// 数字 UID（从 URL 或 `.profile-sub-stats-id` 取），例如 `100001`。
  final String userId;

  /// 头像地址（官网用的是默认头像 `user_default_image.jpg`）。
  final String avatarUrl;

  /// `.profile-sub-stats-id` 原文，例如 `@ 100001`。
  final String subStatsIdText;

  /// `.profile-sub-stats-new-line` 原文，例如 `1 位訂閱者 • 0 部影片`。
  final String subStatsLineText;

  /// 4 个横排。
  final List<Hanime1UserRow> rows;

  bool get hasAnything => displayName.isNotEmpty || rows.isNotEmpty;
}
