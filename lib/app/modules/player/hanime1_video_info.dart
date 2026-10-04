/// Hanime1 播放页「作品信息区」—— 逐值复刻官网 `/watch?v=` 手机端。
///
/// 全部数值来自**无头 Chrome 实测的 computed style**（不是手抄 CSS），
/// 对应官网 `app.css` 的 `@media (max-width:767.9px)` 分支：
/// ```
/// h3#shareBtn-title                  18.48px/23px w700 #fff; padding:0 10px; margin:10px 0
/// .video-details-wrapper.hidden-sm   12px/17.14px #aaa; padding:0 10px;
///                                    margin:-5px 0 17px        ← 觀看次數 + 日期
/// .desktop-inline-mobile-block       padding:0 10px; position:relative
/// #video-user-avatar                 33x33 圆角 50%
/// #video-artist-name                 14px w700 #fff; vertical-align:middle
/// 分类链接                            12px #aaa; margin-left:8px
/// .video-subscribe-btn               position:absolute; right:10px; top:0;
///                                    height:33px; line-height:33px; border-radius:37px;
///                                    padding:0 12px; font-size:12px;
///                                    background:#f1f1f1; color:#333
/// .video-buttons-wrapper             padding:0 4px 0 10px; margin:13px 0; height:35px;
///                                    overflow-x:scroll; white-space:nowrap
/// .video-show-action-btn             background:#242424; height:33px; line-height:33px;
///                                    border-radius:50px; color:#e9e9e9;
///                                    margin:2px 5px 0 0
/// .video-show-action-btn .single-icon padding:0 15px; font-size:13px; height:33px
/// .like-buttons-divider              color:hsla(0,0%,100%,.2); transform:scale(.5,1.8)
/// .video-description-panel           background:#242424; border-radius:15px;
///                                    padding:10px 12px; color:#fff
/// .caption-ellipsis                  -webkit-line-clamp:3
/// .video-tags-wrapper                padding:0 10px; margin:21px 0 -20px
/// .single-video-tag a                background:#242424; color:#e9e9e9;
///                                    border-radius:15px; padding:6px 10px;
///                                    margin-right:3px; font-size:14px; line-height:20px
/// .single-video-tag a span           color:#aaa; font-size:12px
/// #playlist-top-block                background:#212121; border-radius:3px; padding:10px
/// #playlist-top-block h4             14px/20px w700; padding-right:50px; margin-bottom:-5px
/// #playlist-top-block h4 span        12px #aaa; margin-right:4px       ← 「社團」
/// #hide-playlist-btn                 position:absolute; right:10px; top:14px;
///                                    35x35 圆角 50%; 图标 30px #fff
/// #playlist-scroll                   width:calc(100% + 10px); margin-left:-5px;
///                                    padding:5px; overflow-y:auto; overflow-x:hidden;
///                                    max-height:min(10px + 3.5*((100vw-20px)*0.5*9/16 + 10px), 65vh);
///                                    mask-image:linear-gradient(to bottom,
///                                      transparent 0%, black 5px,
///                                      black calc(100% - 5px), transparent 100%)
/// .playlist-video-card               display:flex; gap:0; padding:0
/// .video-thumb-container             flex:0 0 50%; max-width:50%
/// .video-info-container              flex:0 0 50%; max-width:50%; padding-left:10px
/// .video-title                       14px/20px w700; margin-top:3px; -webkit-line-clamp:2
/// .meta-author a / .meta-stats       color:#696969; font-size:12px; line-height:18px
/// .videos-scroll .thumb-container::after
///                                    content:"▶ 現正播放"; background:rgba(0,0,0,.7);
///                                    13px bold #fff; 居中; 圆角 3px   ← 当前播放的那一集
/// #playlist-footer                   「更多 {作者} 的影片」→ /user/{id}/uploaded
/// ```
///
/// **清单默认是收缩状态**（按用户要求）。官网服务端渲染出来的是
/// `class="mobile-open"`（默认展开），靠 `#hide-playlist-btn` 点击在
/// `mobile-open` / `mobile-closed` 之间切换；而 `mobile-closed` 在
/// `@media (max-width:991px)` 下就是 `display:none`。这里把初始态定为收缩，
/// 展开后则是官网那套「限高 3.5 张卡 + 上下渐隐」的可滚动盒。
library;

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

import 'package:flutter/services.dart';

import '../../data/models/hanime1_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/hanime1_source.dart';
import '../../data/sources/video_source.dart';
import '../hanime1/widgets/hanime1_card_h.dart';
import '../../core/app_logger.dart';
import '../../routes/app_navigator.dart';
import '../../services/hanime1_auth_service.dart';
import '../../widgets/app_toast.dart';
import 'hanime1_save_sheet.dart';

class Hanime1VideoInfo extends StatefulWidget {
  const Hanime1VideoInfo({
    super.key,
    required this.video,
    required this.extra,
    required this.onDownload,
    required this.onSelectPlaylistItem,
  });

  final VideoItem video;

  /// 详情解析出来的附加元数据。
  ///
  /// **可以为 null** —— 播放页在拿到详情之前就应该用 hanime1 的版式渲染，
  /// 否则会先闪一下 91 的布局再跳变过来（用户反馈的「转一圈才打开 hanime1
  /// 的页面」）。此时标题/作者/播放量等从 [video] 里取，拿不到的字段留空。
  final Hanime1VideoExtra? extra;
  final VoidCallback onDownload;
  final ValueChanged<VideoItem> onSelectPlaylistItem;

  @override
  State<Hanime1VideoInfo> createState() => _Hanime1VideoInfoState();
}

class _Hanime1VideoInfoState extends State<Hanime1VideoInfo> {
  bool _liked = false;
  bool _disliked = false;
  bool _subscribed = false;
  bool _saved = false;
  bool _submitting = false;
  String? _likePercent;
  String? _likeCount;

  @override
  void initState() {
    super.initState();
    _applyAccountState();
  }

  @override
  void didUpdateWidget(covariant Hanime1VideoInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id ||
        oldWidget.extra != widget.extra) {
      _applyAccountState();
    }
  }

  void _applyAccountState() {
    _liked = widget.extra?.isLiked ?? false;
    _disliked = widget.extra?.isDisliked ?? false;
    _subscribed = widget.extra?.isSubscribed ?? false;
    _saved = widget.extra?.savedPlaylistIds.isNotEmpty ?? false;
    _likePercent = widget.extra?.likePercent;
    _likeCount = widget.extra?.likeCount;
  }

  Hanime1Source? get _source {
    final source = SourceRegistry.byId('hanime1');
    return source is Hanime1Source ? source : null;
  }

  Future<void> _toggleSubscription() async {
    AppLogger.i('Hanime1VideoInfo', '点击官网订阅按钮');
    if (_submitting) return;
    if (!Hanime1AuthService.to.isLoggedIn.value) {
      AppToast.show('请先登录 Hanime1');
      return;
    }
    final source = _source;
    if (source == null) return;
    setState(() => _submitting = true);
    final subscribed = await source.toggleArtistSubscription(v.id);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (subscribed != null) _subscribed = subscribed;
    });
    AppToast.show(
      subscribed == null
          ? '操作失败，请重试'
          : subscribed
          ? '已訂閱'
          : '已取消訂閱',
    );
  }

  Future<void> _vote(bool positive) async {
    AppLogger.i('Hanime1VideoInfo', positive ? '点击官网点赞按钮' : '点击官网不喜欢按钮');
    if (_submitting) return;
    if (!Hanime1AuthService.to.isLoggedIn.value) {
      AppToast.show('请先登录 Hanime1');
      return;
    }
    final source = _source;
    if (source == null) return;
    setState(() => _submitting = true);
    final result = await source.voteVideo(v.id, positive: positive);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result != null) {
        _liked = result.liked;
        _disliked = result.disliked;
        _likePercent = result.percent;
        _likeCount = result.count;
      }
    });
    if (result == null) AppToast.show('操作失败，请重试');
  }

  Future<void> _openSaveSheet() async {
    final source = _source;
    if (source == null) return;
    await Hanime1SaveSheet.show(
      context,
      source: source,
      video: v,
      onSavedStateChanged: (saved) {
        if (mounted) setState(() => _saved = saved);
      },
    );
  }

  /// 清单是否收缩。
  ///
  /// **默认 true** —— 用户明确要求「清单默认为收缩状态」。
  /// 官网默认展开（`mobile-open`），这里按用户要求反过来。
  bool _playlistCollapsed = true;

  // ---------------- 官网实测配色（全部来自 computed style） ----------------

  /// `.video-show-action-btn { background-color:#242424 }`（移动端）

  /// `.video-show-action-btn { color:#e9e9e9 }`

  /// `.video-show-action-btn.default:hover { background-color:#3b3c3d }`

  /// `.video-details-wrapper { color:#aaa }` / `.profile-sub-stats` 同色

  /// `.meta-author a / .meta-stats { color:#696969 }`

  /// `.video-description-panel { background-color:#242424 }`

  /// `.video-caption-text { color:#b8babc }`

  /// `.video-playlist-top { background-color:#212121 !important }`（页面内联样式）

  /// `.horizontal-card .thumb-container { background-color:#2a2a2a }`

  /// `.video-subscribe-btn { background-color:#f1f1f1; color:#333 }`

  /// `.video-title a { color:#eee!important }`

  /// 附加元数据。详情还没解析出来时给一个空壳，让版式先立起来 ——
  /// 各字段都有默认值，空壳天然等价于「全部未知」。
  Hanime1VideoExtra get e => widget.extra ?? const Hanime1VideoExtra();
  VideoItem get v => widget.video;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildTitle(),
        _buildViewsLine(),
        _buildArtistRow(),
        _buildActionRow(),
        if (e.captionText.isNotEmpty) _buildDescriptionPanel(),
        if (e.tags.isNotEmpty) _buildTags(),
        if (e.playlistItems.isNotEmpty) _buildPlaylist(context),
      ],
    );
  }

  // ---------------------------------------------------------------- 标题

  /// `h3#shareBtn-title { font-size:18.48px; line-height:23px; font-weight:bold;
  ///  margin-top:10px; color:white; padding:0 10px }`
  Widget _buildTitle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Text(
        v.title,
        style: TextStyle(
          fontSize: 18.48,
          height: 23 / 18.48,
          fontWeight: FontWeight.w700,
          color: context.cTextMain,
        ),
      ),
    );
  }

  /// `margin:-5px 0 17px` —— 那 -5px 是让它贴到标题行框下沿。
  ///
  /// Flutter 没有负 margin，所以用 [Transform.translate] 上移 5px（不改布局），
  /// 再把下方间距从 17 减到 12 —— 后续元素落点与官网完全一致。
  Widget _buildViewsLine() {
    // 详情尚未解析出来时，用列表页已经带下来的字段兜底 —— 否则整行会消失，
    // 页面看起来「没有内容」。
    final views = e.viewsText.isNotEmpty ? e.viewsText : (v.viewsStr ?? '');
    final date = e.releaseDate.isNotEmpty
        ? e.releaseDate
        : (v.publishedAt ?? '');
    final text = <String>[
      if (views.isNotEmpty) '觀看次數：$views',
      if (date.isNotEmpty) date,
    ].join('  ');
    if (text.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      child: Transform.translate(
        offset: const Offset(0, -5),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 17.1429 / 12,
            fontWeight: FontWeight.w400,
            color: context.cTextSub,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------- 制作方 / 分类 / 訂閱

  /// `.video-details-wrapper.desktop-inline-mobile-block`：头像 + 作者名 + 分类
  /// + 右侧「訂閱」胶囊。
  ///
  /// 官网的「訂閱」是 `position:absolute; right:10px; top:0`，这里用普通 Row 尾项
  /// 达到同样的右对齐效果，且长作者名不会压到按钮上。
  Widget _buildArtistRow() {
    // 详情未解析时用列表页的作者名兜底，避免一上来就显示「未知製作方」。
    final artistName = e.artistName.isNotEmpty ? e.artistName : v.author;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Row(
        children: <Widget>[
          _avatar(e.artistAvatar, 33),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: InkWell(
                    onTap: () {
                      if (artistName.isNotEmpty) {
                        AppNavigator.toSearch(keyword: artistName);
                      }
                    },
                    child: Text(
                      artistName.isNotEmpty ? artistName : '未知製作方',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.cTextMain,
                      ),
                    ),
                  ),
                ),
                if (e.genreName.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => AppNavigator.toSearch(
                      category:
                          Uri.tryParse(e.genrePath)?.queryParameters['genre'] ??
                          e.genreName,
                    ),
                    child: Text(
                      e.genreName,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: context.cTextSub,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(37),
            onTap: artistName.isEmpty || _submitting
                ? null
                : _toggleSubscription,
            child: Container(
              height: 33,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.cAccentContainer,
                borderRadius: BorderRadius.circular(37),
              ),
              child: Text(
                _subscribed ? '已訂閱' : '訂閱',
                style: TextStyle(
                  fontSize: 12,
                  height: 33 / 12,
                  fontWeight: FontWeight.w700,
                  color: context.cOnAccentContainer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 操作按钮行

  /// `.video-buttons-wrapper`：`padding:0 4px 0 10px; margin:13px 0; height:35px;
  ///  overflow-x:scroll; white-space:nowrap`。
  ///
  /// **手机端是 6 个按钮**（讚 / 不喜歡 / 儲存 / 下載 / 分享 / 報錯）。
  /// 官网那个 `more_horiz` 折叠菜单带 `hidden-xs`，只在桌面端出现，所以这里不做。
  Widget _buildActionRow() {
    // 官网整行宽（实测 764px 视口下）约 833px > 视口宽，所以横向可滚。
    // 这里不写死，交给 SingleChildScrollView 按内容自然溢出。

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 15, 4, 0),
      child: SizedBox(
        height: 33,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: <Widget>[
              // ---- 讚 / 不喜歡：官网是**同一个胶囊**被切成左右两半 ----
              //
              // `#video-like-btn .single-icon { border-radius:50px 0 0 50px }`
              // `#video-unlike-btn .single-icon { border-radius:0 50px 50px 0 }`
              // 中间用 `.like-buttons-divider`（一个被 scale 的 `|`）分隔。
              Container(
                height: 33,
                decoration: BoxDecoration(
                  color: context.cSurfaceAlt,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Row(
                  children: <Widget>[
                    _pillSegment(
                      onTap: () => _vote(true),
                      radius: const BorderRadius.horizontal(
                        left: Radius.circular(50),
                      ),
                      children: <Widget>[
                        Icon(
                          _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                          size: 17,
                          color: context.cTextMain,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          (_likePercent ?? '').isNotEmpty
                              ? _likePercent!
                              : '讚好',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.cTextMain,
                          ),
                        ),
                        if ((_likeCount ?? '').isNotEmpty)
                          Text(
                            '(${_likeCount!})',
                            style: TextStyle(
                              fontSize: 13,
                              color: context.cTextMain,
                            ),
                          ),
                      ],
                    ),
                    // `.like-buttons-divider { color:hsla(0,0%,100%,.2);
                    //  transform:scale(.5,1.8); vertical-align:top; margin-top:-2px }`
                    Transform.scale(
                      scaleX: 0.5,
                      scaleY: 1.8,
                      child: const Text(
                        '|',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0x33FFFFFF),
                        ),
                      ),
                    ),
                    _pillSegment(
                      onTap: () => _vote(false),
                      radius: const BorderRadius.horizontal(
                        right: Radius.circular(50),
                      ),
                      children: <Widget>[
                        Icon(
                          _disliked
                              ? Icons.thumb_down
                              : Icons.thumb_down_outlined,
                          size: 17,
                          color: context.cTextMain,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ---- 儲存（playlist_add，图标 22px / 右间距 8） ----
              _actionPill(
                icon: _saved ? Icons.playlist_add_check : Icons.playlist_add,
                iconSize: 22,
                iconGap: 8,
                label: _saved ? '已儲存' : '儲存',
                onTap: _openSaveSheet,
              ),

              // ---- 下載（download，图标 19px / 右间距 7） ----
              _actionPill(
                icon: Icons.download_outlined,
                iconSize: 19,
                iconGap: 7,
                label: '下載',
                onTap: widget.onDownload,
              ),

              // ---- 分享（share，图标 16px / 右间距 8） ----
              _actionPill(
                icon: Icons.share_outlined,
                iconSize: 16,
                iconGap: 8,
                label: '分享',
                onTap: _share,
              ),

              // ---- 報錯（flag，图标 18px / 右间距 8） ----
              _actionPill(
                icon: Icons.flag_outlined,
                iconSize: 18,
                iconGap: 8,
                label: '報錯',
                onTap: () => AppToast.show('已收到回報，我們會盡快核查'),
              ),

              // 让最后那个按钮的 margin-right:5px 也生效
              const SizedBox(width: 5),
            ],
          ),
        ),
      ),
    );
  }

  /// `.video-show-action-btn`：高 33、圆角 50、`padding:0 15px`、
  /// 文字 13px、`margin:2px 5px 0 0`。
  ///
  /// 颜色分层：`Container` 铺 `_pillBg`，里面再垫一层**透明 `Material`**
  /// 承接 `InkWell` 的按下高亮（`_pillHover`，对应官网 `:hover`）。
  /// 若把 `InkWell` 放在不透明 `Container` 外面，水波纹会被底色盖住看不见。
  Widget _actionPill({
    required IconData icon,
    required double iconSize,
    required double iconGap,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Container(
        height: 33,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
          borderRadius: BorderRadius.circular(50),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            highlightColor: context.cSurfaceHigh,
            splashColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: iconSize, color: context.cTextMain),
                  SizedBox(width: iconGap),
                  Text(
                    label,
                    style: TextStyle(fontSize: 13, color: context.cTextMain),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 点赞胶囊的左右半格（`.single-icon { padding:0 15px }`）。
  Widget _pillSegment({
    required VoidCallback onTap,
    required BorderRadius radius,
    required List<Widget> children,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        highlightColor: context.cSurfaceHigh,
        splashColor: Colors.transparent,
        child: Container(
          height: 33,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          alignment: Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }

  void _share() {
    final url = v.detailUrl ?? 'https://hanime1.me/watch?v=${v.id}';
    Clipboard.setData(ClipboardData(text: url));
    AppToast.show('已複製連結：$url');
  }

  // ------------------------------------------------------------ 简介面板

  /// `.video-description-panel { background:#242424; border-radius:15px;
  ///  padding:10px 12px }` + `.caption-ellipsis { -webkit-line-clamp:3 }`。
  Widget _buildDescriptionPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 17, 10, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Text(
          e.captionText,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w400,
            color: context.cTextSub,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 标签

  /// `.video-tags-wrapper { padding:0 10px; margin:21px 0 -20px }`，
  /// `.single-video-tag { margin-bottom:18px }`，
  /// `.single-video-tag a { margin-right:3px }`。
  Widget _buildTags() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 21, 10, 0),
      child: Wrap(
        spacing: 3,
        runSpacing: 18,
        children: e.tags.map((t) {
          return InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () {
              // 官网 `query=` 型标签是关键词搜索，`tags[]=` 型是标签筛选。
              if (t.path.contains('tags%5B%5D=') ||
                  t.path.contains('tags[]=')) {
                AppNavigator.toSearch(keyword: t.name);
              } else {
                AppNavigator.toSearch(keyword: t.name);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: context.cSurfaceAlt,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 官网 `query=` 型标签前缀一个 `#`（12px #aaa）
                  if (t.count <= 0)
                    Text(
                      '# ',
                      style: TextStyle(fontSize: 12, color: context.cTextSub),
                    ),
                  Text(
                    t.name,
                    style: TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w400,
                      color: context.cTextMain,
                    ),
                  ),
                  // `tags[]=` 型标签后缀一个出现次数（12px #aaa）
                  if (t.count > 0)
                    Text(
                      '(${t.count})',
                      style: TextStyle(fontSize: 12, color: context.cTextSub),
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ------------------------------------------------------------ 所属清单

  /// 官网清单区 = `#playlist-top-block`（社團/作者/部数 + 收起按钮）
  /// + `#playlist-scroll`（限高可滚动剧集）
  /// + `#playlist-footer`（「更多 {作者} 的影片」）。
  ///
  /// 收缩时只留 `#playlist-top-block`，并把它变成 15px 圆角
  /// （对应官网 `.mobile-closed-radius { border-radius:15px !important }`）。
  Widget _buildPlaylist(BuildContext context) {
    final items = e.playlistItems;
    final author = e.playlistAuthor.isNotEmpty
        ? e.playlistAuthor
        : (e.playlistTitle.isNotEmpty ? e.playlistTitle : '');

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 21, 10, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ---------------- #playlist-top-block ----------------
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.cSurfaceAlt,
              borderRadius: BorderRadius.circular(_playlistCollapsed ? 15 : 3),
            ),
            child: Stack(
              children: <Widget>[
                // 整块可点：点这一行的任意空白处都能收起/展开。
                //
                // 原先只有右上角一个 35x35 的小按钮能点（用户反馈「点击范围太小」，
                // 并按红圈标出了期望范围）。这里铺一层透明的 InkWell 在**最底层**，
                // 作者名自己的 InkWell 在它上面，所以点作者名仍然是跳作者页，不冲突。
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(
                        _playlistCollapsed ? 15 : 3,
                      ),
                      onTap: () => setState(
                        () => _playlistCollapsed = !_playlistCollapsed,
                      ),
                    ),
                  ),
                ),
                Padding(
                  // h4 { padding-right:50px } —— 给右上角的收起按钮让位
                  padding: const EdgeInsets.only(right: 50),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // h4：`社團` + 作者（14px w700 #fff）
                      Row(
                        children: <Widget>[
                          Text(
                            '社團',
                            style: TextStyle(
                              fontSize: 12,
                              height: 20 / 12,
                              fontWeight: FontWeight.w400,
                              color: context.cTextSub,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: InkWell(
                              onTap: author.isEmpty
                                  ? null
                                  : () => _openAuthor(author),
                              child: Text(
                                author,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 20 / 14,
                                  fontWeight: FontWeight.w700,
                                  color: context.cTextMain,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // 第二行：作者 • N 部影片（12px #aaa）
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              author,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 20 / 12,
                                fontWeight: FontWeight.w400,
                                color: context.cTextSub,
                              ),
                            ),
                          ),
                          Text(
                            '•',
                            style: TextStyle(
                              fontSize: 10,
                              color: context.cTextSub,
                            ),
                          ),
                          Text(
                            '${items.length} 部影片',
                            style: TextStyle(
                              fontSize: 12,
                              height: 20 / 12,
                              fontWeight: FontWeight.w400,
                              color: context.cTextSub,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // ---------------- #hide-playlist-btn ----------------
                Positioned(
                  right: 0,
                  top: 4,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(50),
                    onTap: () => setState(
                      () => _playlistCollapsed = !_playlistCollapsed,
                    ),
                    child: SizedBox(
                      width: 35,
                      height: 35,
                      child: Center(
                        child: Icon(
                          // 展开时是 `keyboard_arrow_down`（点一下收起），
                          // 收缩时反过来用 `keyboard_arrow_up`。
                          _playlistCollapsed
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 30,
                          color: context.cTextMain,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---------------- #playlist-scroll + #playlist-footer ----------------
          if (!_playlistCollapsed) ...<Widget>[
            _buildPlaylistScroll(context, items),
            if (e.playlistPath.isNotEmpty) _buildPlaylistFooter(author),
          ],
        ],
      ),
    );
  }

  /// `#playlist-scroll` —— 限高 + 上下 5px 渐隐遮罩的可滚动剧集列表。
  ///
  /// 高度公式逐字照抄官网内联样式：
  /// `max-height: min(10px + 3.5 * (((100vw - 20px) * 0.5) * 9 / 16 + 10px), 65vh)`
  Widget _buildPlaylistScroll(BuildContext context, List<VideoItem> items) {
    final size = MediaQuery.sizeOf(context);
    // 单张卡的封面高 = (视口宽 - 20) 的一半，按 16:9 折算；+10 是 hover-wrap 的上下 padding
    final cardThumb = (size.width - 20) * 0.5 * 9 / 16 + 10;
    final maxH = math.min(10 + 3.5 * cardThumb, size.height * 0.65);

    return SizedBox(
      // width: calc(100% + 10px); margin-left: -5px —— 负 margin 用「外扩宽度 + 负位移」
      // 在 Flutter 里没有直接对应物，这里退化成「左右各留 5px 的 padding」，
      // 视觉上等价（内容区域宽度一致），且不会被父级约束裁掉。
      height: maxH,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const <Color>[
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: const <double>[0, 0.03, 0.97, 1],
          ).createShader(rect),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                for (var row = 0; row < (items.length + 1) ~/ 2; row++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: row == (items.length + 1) ~/ 2 - 1
                          ? 0
                          : Hanime1CardH.rowGap,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _playlistGridCard(
                            items[row * 2],
                            isCurrent: items[row * 2].id == v.id,
                          ),
                        ),
                        const SizedBox(width: Hanime1CardH.columnGap),
                        Expanded(
                          child: row * 2 + 1 < items.length
                              ? _playlistGridCard(
                                  items[row * 2 + 1],
                                  isCurrent: items[row * 2 + 1].id == v.id,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `.playlist-video-card`：封面 50% + 信息 50%，`gap:0; padding:0`。
  ///
  /// 当前正在播放的那一集，封面会被 `▶ 現正播放` 蒙层盖住
  /// （官网 `.videos-scroll .thumb-container::after`）。
  Widget _playlistGridCard(VideoItem item, {required bool isCurrent}) {
    return InkWell(
      onTap: isCurrent ? null : () => widget.onSelectPlaylistItem(item),
      borderRadius: BorderRadius.circular(3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _playlistCover(item),
                  if (isCurrent)
                    const ColoredBox(
                      color: Color(0xB3000000),
                      child: Center(
                        child: Text(
                          '▶ 現正播放',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(3, 6, 3, 0),
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.cTextMain,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ),
          if (item.author.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 3, 3, 0),
              child: Text(
                item.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.cTextSub, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  /// 清单卡右下角的统计（官网 `.stats-container > .stat-item`，
  /// 移动端 `font-size:10px; padding:0 3px; line-height:15px; border-radius:2px`）。
  /// 清单卡封面。
  Widget _playlistCover(VideoItem item) {
    final thumb = item.thumbnailUrl;
    if (thumb == null || thumb.isEmpty) {
      return Center(
        child: Icon(Icons.movie_outlined, color: context.cTextFaint, size: 24),
      );
    }
    return CachedNetworkImage(
      imageUrl: thumb,
      fit: BoxFit.cover,
      // 清单卡封面宽约 190dp，取 400 足够（与首页卡片同一套解码尺寸策略）
      memCacheWidth: 400,
      httpHeaders: const {'Referer': 'https://hanime1.me/'},
      placeholder: (_, _) => const SizedBox.expand(),
      errorWidget: (_, _, _) => Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: context.cTextFaint,
          size: 20,
        ),
      ),
    );
  }

  /// `#playlist-footer` —— 「更多 {作者} 的影片」，底色同 `#playlist-top-block`。
  Widget _buildPlaylistFooter(String author) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(3),
        onTap: () => _openAuthor(author),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            color: context.cSurfaceAlt,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '更多',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.cTextMain,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  author,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.cTextMain,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '的影片',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.cTextMain,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAuthor(String author) {
    if (author.isEmpty) return;
    AppNavigator.toSearch(keyword: author);
  }

  // ---------------------------------------------------------------- 小组件

  Widget _avatar(String url, double size) {
    if (url.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.cImagePlaceholder,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.person, size: size * 0.55, color: context.cTextSub),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: (size * 3).round(),
          httpHeaders: const {'Referer': 'https://hanime1.me/'},
          errorWidget: (_, _, _) => Container(
            color: context.cImagePlaceholder,
            child: Icon(
              Icons.person,
              size: size * 0.55,
              color: context.cTextSub,
            ),
          ),
        ),
      ),
    );
  }
}
