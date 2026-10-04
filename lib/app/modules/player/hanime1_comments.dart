/// Hanime1 播放页「評論」区 —— 对齐官网 `#comment-section-wrapper` 的异步加载评论。
///
/// 官网行为（`/js/app.js`）：
/// ```js
/// // 点「評論」Tab 才拉评论
/// $.ajax({type:"GET", url:"/loadComment",
///   data:{id:$(this).data("foreignid"), type:$(this).data("type"), content:this.id},
///   success:function(t){ $("div#comment-section-wrapper").html(t.comments) }})
/// // 点「查看 N 則回覆」才拉回复
/// $.ajax({type:"GET", url:"/loadReplies", data:{id:$(this).data("commentid")},
///   success:function(t){ $("div#reply-section-wrapper-"+t.comment_id).html(t.replies) }})
/// ```
/// 所以这里也是**按需加载**：本组件挂载时才拉一级评论，展开某条才拉它的回复。
///
/// 视觉取值（`app.css`，注意官网 `html{font-size:10px}` 只影响 rem，
/// `em` 仍按 `body{font-size:14px}` 计算）：
/// ```
/// .video-show-comment-width { padding:5px 0 2px; margin:10px 0 }
///   + 移动端 padding-left/right: 15px
/// .comment-index-text        { padding-left:56px }          ← 正文缩进到头像右侧
/// .comment-index-text        第一行 font-size:.9em  → 12.6px
/// .comment-index-text        正文   font-size:1em   → 14px
/// .comment-index-text span   时间   font-size:.85em → 10.7px, color:darkgray
/// #comment-like-form-wrapper { margin-left:50px }           ← 点赞行缩进
/// 点赞数 span font-size:.90em → 12.6px, color:darkgray
/// 「回覆」    font-size:.95em → 13.3px, color:darkgray
/// div.load-replies-btn       { color:red; margin-top:13px; margin-left:-5px }
/// 头像：一级 40px / 回复 30px（img.img-circle）
/// ```
///
/// ## 为什么有两个入口
///
/// 评论条数由官网决定（实测一部片子可达上百条），**必须懒加载**：
/// 早期版本把整个列表放进一个 `Column`，再用 `SliverToBoxAdapter` 挂到播放页的
/// `CustomScrollView` 上 —— `SliverToBoxAdapter` 是 box 子项，没有懒加载，
/// 于是切到「評論」的瞬间会一次性构建全部评论（连同全部头像 `CachedNetworkImage`），
/// 表现为「打开评论区卡一下」，而建完之后滚动本身并不卡。
/// （同一个 `CustomScrollView` 里的「相關影片」此前踩过同样的坑，已由 `SliverList` 修好，
/// 见 `player_view.dart` 的 `_buildPlayerBody` 注释。）
///
/// 现在拆成两层：
/// - [Hanime1CommentsSliver] —— 真正实现，返回 sliver，用 `SliverList.builder`
///   只构建可见评论。hanime1 播放页走这一条。
/// - [Hanime1CommentsSection] —— 盒式包装，供**非 sliver 上下文**使用
///   （91 播放页的 `ListView(children:)`）。它内部套一个 `shrinkWrap` 的
///   `CustomScrollView` 来承载 sliver；该路径正常不会执行（hanime1 视频不会走到
///   91 的信息区），保留是为了不动 91 的调用链。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

import '../../data/models/hanime1_models.dart';
import '../../data/sources/hanime1_source.dart';
import '../../data/sources/video_source.dart';

/// 盒式入口：把评论区当成一个普通 box widget 使用。
///
/// 仅用于**非 sliver 上下文**（91 播放页的 `ListView(children:)`）。
/// hanime1 播放页请直接用 [Hanime1CommentsSliver] —— 用本类会被迫全量构建。
class Hanime1CommentsSection extends StatelessWidget {
  const Hanime1CommentsSection({
    super.key,
    required this.videoId,
    this.countText = '',
  });

  final String videoId;
  final String countText;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      // 这里是被嵌进外层滚动视图的从属列表，必须 shrinkWrap。
      // 该路径正常不会执行，代价可接受；hanime1 播放页走的是 sliver 版。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      slivers: [Hanime1CommentsSliver(videoId: videoId, countText: countText)],
    );
  }
}

/// 播放页评论区（sliver 版）。挂载即拉取一级评论（对应官网点「評論」Tab 的动作）。
///
/// 返回 [SliverMainAxisGroup]，只能挂在 sliver 上下文（`CustomScrollView.slivers`）。
class Hanime1CommentsSliver extends StatefulWidget {
  const Hanime1CommentsSliver({
    super.key,
    required this.videoId,
    this.countText = '',
  });

  final String videoId;

  /// 官网上评论数来自 `#tab-comments-count`，此处用于标题徽标。
  final String countText;

  @override
  State<Hanime1CommentsSliver> createState() => _Hanime1CommentsSliverState();
}

class _Hanime1CommentsSliverState extends State<Hanime1CommentsSliver> {
  /// null = 还没拉过（用于区分「加载中」与「确实没有评论」）。
  List<Hanime1Comment>? _comments;
  bool _loading = false;
  String? _error;

  /// commentId -> 已加载的回复。
  final Map<String, List<Hanime1Comment>> _replies =
      <String, List<Hanime1Comment>>{};

  /// 正在拉回复的 commentId。
  final Set<String> _repliesLoading = <String>{};

  /// 已展开回复的 commentId。
  final Set<String> _repliesOpen = <String>{};

  Hanime1Source? get _source {
    final src = SourceRegistry.byId('hanime1');
    return src is Hanime1Source ? src : null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant Hanime1CommentsSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      // 播放页可以在原地切下一个视频，评论必须跟着换。
      setState(() {
        _comments = null;
        _error = null;
        _replies.clear();
        _repliesLoading.clear();
        _repliesOpen.clear();
      });
      _load();
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final src = _source;
    if (src == null) {
      setState(() => _error = '當前內容源不支持評論');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final list = await src.fetchComments(
      widget.videoId,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _comments = list;
      // 切走 Tab 再切回来时组件会重新挂载，_repliesOpen 会清空。
      // 这里把「之前展开过、且回复缓存仍在」的那几条自动恢复成展开态，
      // 让来回切 Tab 看不出差别。
      for (final c in list) {
        if (c.replyCount > 0 && src.getCachedReplies(c.commentId) != null) {
          _repliesOpen.add(c.commentId);
        }
      }
    });
  }

  /// 取某条评论的回复：优先用本组件的局部状态，其次用数据源缓存。
  ///
  /// 后者是为了「切走 Tab 再切回来」时不丢已加载的回复 ——
  /// 组件会被重新挂载，但 [Hanime1Source] 的缓存还在。
  List<Hanime1Comment>? _repliesFor(String commentId) =>
      _replies[commentId] ?? _source?.getCachedReplies(commentId);

  Future<void> _toggleReplies(Hanime1Comment comment) async {
    final id = comment.commentId;

    // 已展开 → 收起
    if (_repliesOpen.contains(id)) {
      setState(() => _repliesOpen.remove(id));
      return;
    }

    setState(() => _repliesOpen.add(id));

    // 已加载过就不重复请求
    if (_repliesFor(id) != null || _repliesLoading.contains(id)) return;

    final src = _source;
    if (src == null) return;

    setState(() => _repliesLoading.add(id));
    final list = await src.fetchReplies(id);
    if (!mounted) return;
    setState(() {
      _repliesLoading.remove(id);
      _replies[id] = list;
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.countText.isNotEmpty
        ? widget.countText
        : (_comments == null ? '' : '${_comments!.length}');

    final comments = _comments;
    final hasComments = comments != null && comments.isNotEmpty;

    // 原实现是 `Padding(fromLTRB(15,5,15,2), child: Column(...))`。
    // 拆成 sliver 后，横向 15 / 上 5 / 下 2 分别落到下面两个 SliverPadding 上，
    // 保证视觉零变化：有评论时底部留白挂在列表上，无评论时挂在状态区上。
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(15, 5, 15, hasComments ? 0 : 2),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(count),
                const SizedBox(height: 6),
                if (_loading && comments == null)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: context.cAccent,
                        ),
                      ),
                    ),
                  )
                else if (_error != null)
                  _buildError()
                else if (!hasComments)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '暫無評論',
                        style: TextStyle(fontSize: 13, color: context.cTextSub),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 评论列表：SliverList.builder 只构建可见项。
        // 此前这里是一个 `Column` 装全部评论 —— 切到「評論」的瞬间一次性构建
        // 全部评论（含全部头像请求），就是「打开评论区卡一下」的来源。
        if (hasComments)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(15, 0, 15, 2),
            sliver: SliverList.builder(
              itemCount: comments.length,
              itemBuilder: (context, index) =>
                  _buildComment(comments[index], isReply: false),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(String count) {
    // 标题不放「評論」二字 —— 上面的 Tab 已经写着「評論 + 数量徽标」了，
    // 这里再来一遍就是重复。只留一行统计与刷新。
    return Row(
      children: [
        Text(
          count.isEmpty ? '' : '共 $count 則評論',
          style: TextStyle(fontSize: 12, color: context.cTextSub),
        ),
        const Spacer(),
        IconButton(
          tooltip: '重新整理',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.refresh, size: 18, color: context.cTextSub),
          // 刷新按钮要绕过缓存，否则点一下什么都不会变。
          onPressed: _loading ? null : () => _load(forceRefresh: true),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        children: [
          Icon(Icons.cloud_off_outlined, size: 32, color: context.cTextSub),
          const SizedBox(height: 8),
          Text(
            _error ?? '評論載入失敗',
            style: TextStyle(fontSize: 13, color: context.cTextSub),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => _load(forceRefresh: true),
            style: OutlinedButton.styleFrom(
              foregroundColor: context.cAccent,
              side: BorderSide(color: context.cAccent, width: 0.8),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('重試', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 单条评论

  Widget _buildComment(Hanime1Comment c, {required bool isReply}) {
    // 头像：一级 40px / 回复 30px
    final avatarSize = isReply ? 30.0 : 40.0;
    // 正文缩进：一级 56px（= 头像 40 + 16），回复 45px（官网内联样式）
    final indent = isReply ? 45.0 : 56.0;

    final replies = _repliesFor(c.commentId);
    final isOpen = _repliesOpen.contains(c.commentId);
    final isLoadingReplies = _repliesLoading.contains(c.commentId);

    return Padding(
      padding: EdgeInsets.only(top: isReply ? 14 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像 + 作者名/时间 + 正文
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(c.avatarUrl, avatarSize),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: indent - avatarSize),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：作者名 + 时间（官网 font-size:.9em / 时间 .85em）
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              c.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.6,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (c.timeText.isNotEmpty)
                            Text(
                              c.timeText,
                              style: TextStyle(
                                fontSize: 10.7,
                                color: context.cTextSub,
                              ),
                            ),
                          const Spacer(),
                          // more_vert 报错入口（官网 data-reportable-type=comment/reply）
                          Icon(
                            Icons.more_vert,
                            size: 15,
                            color: context.cTextSub,
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // 正文（官网 font-size:1em → 14px）
                      Text(
                        c.body,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildLikeRow(c, isReply: isReply),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // 「查看 N 則回覆」
          if (!isReply && c.replyCount > 0)
            Padding(
              padding: EdgeInsets.only(left: indent, top: 4),
              child: InkWell(
                onTap: () => _toggleReplies(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        size: 20,
                        color: context.cAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${isOpen ? '隱藏' : '查看'} ${c.replyCount} 則回覆',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: context.cAccent,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 回复区
          if (!isReply && isOpen) ...[
            if (isLoadingReplies && replies == null)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.cAccent,
                    ),
                  ),
                ),
              )
            else if (replies != null && replies.isEmpty)
              Padding(
                padding: EdgeInsets.only(left: indent, top: 6),
                child: Text(
                  '回覆已刪除',
                  style: TextStyle(fontSize: 12.5, color: context.cTextSub),
                ),
              )
            else if (replies != null)
              for (final r in replies) _buildComment(r, isReply: true),
          ],
        ],
      ),
    );
  }

  /// 点赞/踩/回覆 一行（官网 `#comment-like-form-wrapper { margin-left:50px }`）。
  Widget _buildLikeRow(Hanime1Comment c, {required bool isReply}) {
    return Row(
      children: [
        const Icon(Icons.thumb_up_alt_outlined, size: 14, color: Colors.white),
        const SizedBox(width: 5),
        Text(
          '${c.likeCount}',
          style: TextStyle(fontSize: 12.6, color: context.cTextSub),
        ),
        const SizedBox(width: 15),
        const Icon(
          Icons.thumb_down_alt_outlined,
          size: 14,
          color: Colors.white,
        ),
        const SizedBox(width: 25),
        Text('回覆', style: TextStyle(fontSize: 13.3, color: context.cTextSub)),
      ],
    );
  }

  Widget _avatar(String url, double size) {
    if (url.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.cSurfaceAlt,
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
          // 头像最大显示 40dp，取 120 足够，避免按原图解码。
          memCacheWidth: 120,
          httpHeaders: const {'Referer': 'https://hanime1.me/'},
          placeholder: (_, _) => Container(color: context.cImagePlaceholder),
          errorWidget: (_, _, _) => Container(
            color: context.cSurfaceAlt,
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
