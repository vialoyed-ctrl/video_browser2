/// Hanime1 专属移动端订阅内容 Tab (订阅内容)。
///
/// 严格还原截图 2 (/subscriptions) 视觉：
/// 1. 顶部创作者圆形头像横滑条（全部、NT00...）；
/// 2. 4 大筛选下拉胶囊（全部类型 ∨、标签 ∨、排序方式 ∨、发布日期 ∨）；
/// 3. 橙红色信息提示图标 (i)；
/// 4. 关注创作者发布的双列视频卡片流；
/// 5. 未登录状态下友好引导与一键登录测试账号。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../widgets/pull_to_next_page.dart';

import '../../../core/app_theme.dart';

import 'package:get/get.dart';

import '../../../services/hanime1_auth_service.dart';
import '../../../data/models/hanime1_models.dart';
import '../../search/search_controller.dart' as app_search;
import '../hanime1_controller.dart';
import '../widgets/hanime1_card.dart';
import '../widgets/hanime1_pagination.dart';

class Hanime1SubscriptionsTab extends StatefulWidget {
  const Hanime1SubscriptionsTab({super.key});

  @override
  State<Hanime1SubscriptionsTab> createState() =>
      _Hanime1SubscriptionsTabState();
}

class _Hanime1SubscriptionsTabState extends State<Hanime1SubscriptionsTab> {
  @override
  Widget build(BuildContext context) {
    final auth = Hanime1AuthService.to;
    final ctrl = Hanime1Controller.to;

    return Obx(() {
      final isLoggedIn = auth.isLoggedIn.value;

      return Column(
        children: [
          // 未登录提示与一键登录栏
          if (!isLoggedIn) _buildLoginPrompt(context, ctrl),

          // 1. 创作者圆形头像横滑列表（还原截图 2：全部、NT00 等）
          _buildCreatorsBar(context, ctrl),

          // 2. 筛选下拉胶囊条（还原截图 2：全部类型 ∨、标签 ∨、排序方式 ∨、发布日期 ∨）
          _buildFilterBar(context),

          const SizedBox(height: 6),

          // 3. 订阅视频网格列表
          Expanded(
            child: Obx(() {
              if (ctrl.isLoadingSub.value && ctrl.subVideos.isEmpty) {
                return Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: context.cAccent,
                  ),
                );
              }

              if (ctrl.subVideos.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.subscriptions_outlined,
                          size: 48,
                          color: context.cTextSub,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isLoggedIn ? '暂无订阅创作者的新视频' : '登录后可同步关注的创作者与作品',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.cTextSub,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: () => ctrl.loadSubscriptions(
                            creatorQuery: ctrl.selectedCreator.value,
                          ),
                          child: const Text('刷新'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return RefreshIndicator(
                color: context.cAccent,
                onRefresh: () => ctrl.loadSubscriptions(
                  creatorQuery: ctrl.selectedCreator.value,
                ),
                // 与官网一致：`.horizontal-row` 是 2 列 CSS grid（行高内容自适应），
                // 所以用 Hanime1VideoGridSliver 而不是 GridView + 固定 childAspectRatio。
                child: PullToNextPage(
                  hasNext: ctrl.hasMoreSub.value,
                  isLoading: ctrl.isLoadingSub.value,
                  onNext: ctrl.loadMoreSubscriptions,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: [
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      Hanime1VideoGridSliver(
                        items: ctrl.subVideos.toList(growable: false),
                        padding: const EdgeInsets.fromLTRB(
                          Hanime1CardH.horizontalPadding,
                          0,
                          Hanime1CardH.horizontalPadding,
                          24,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Hanime1Pagination(
                          currentPage: ctrl.subscriptionsPage.value,
                          onNext: ctrl.loadMoreSubscriptions,
                          hasNext: ctrl.hasMoreSub.value,
                          error: ctrl.subscriptionsError.value,
                          totalPages: ctrl.subscriptionsTotalPages.value,
                          isLoading: ctrl.isLoadingSub.value,
                          onPageChanged: (page) => ctrl.loadSubscriptions(
                            creatorQuery: ctrl.selectedCreator.value,
                            isRefresh: false,
                            page: page,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ],
      );
    });
  }

  /// 未登录状态引导卡片
  Widget _buildLoginPrompt(BuildContext context, Hanime1Controller ctrl) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.cAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.cAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.account_circle_outlined, color: context.cAccent, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '未登录 Hanime1 账号',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                Text(
                  '登录后可获取个人关注的创作者作品流',
                  style: TextStyle(fontSize: 11, color: context.cTextSub),
                ),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccentContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
            ),
            onPressed: () => ctrl.switchTab(3),
            child: Text(
              '前往登入',
              style: TextStyle(fontSize: 12, color: context.cOnAccentContainer),
            ),
          ),
        ],
      ),
    );
  }

  /// 创作者圆形头像横滑条（还原截图 2：全部、NT00 等）
  Widget _buildCreatorsBar(BuildContext context, Hanime1Controller ctrl) {
    return Obx(() {
      final creators = ctrl.subData.value?.creators ?? [];
      if (creators.isEmpty) {
        return const SizedBox(height: 8);
      }

      final selected = ctrl.selectedCreator.value;

      return Container(
        height: 86,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: creators.length,
          separatorBuilder: (context, index) => const SizedBox(width: 14),
          itemBuilder: (ctx, idx) {
            final c = creators[idx];
            final isAll = c.name == '全部';
            final isSelected = isAll
                ? (selected == null || selected.isEmpty)
                : (selected == c.name);

            return InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: () {
                ctrl.selectCreator(isAll ? null : c.name);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 圆形头像
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? context.cAccent : context.cBorder,
                        width: isSelected ? 2.2 : 1.0,
                      ),
                    ),
                    child: ClipOval(
                      child: isAll
                          ? Container(
                              color: context.cSurfaceAlt,
                              alignment: Alignment.center,
                              child: Text(
                                '全部',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: context.cAccent,
                                ),
                              ),
                            )
                          : (c.avatarUrl != null && c.avatarUrl!.isNotEmpty)
                          ? CachedNetworkImage(
                              imageUrl: c.avatarUrl!,
                              fit: BoxFit.cover,
                              // 头像容器只有 50dp，3x 屏 150px，限制解码避免拉原图
                              memCacheWidth: 150,
                              httpHeaders: const {
                                'Referer': 'https://hanime1.me/',
                              },
                              errorWidget: (context, url, error) => Container(
                                color: context.cSurfaceAlt,
                                alignment: Alignment.center,
                                child: Text(
                                  c.name.substring(
                                    0,
                                    c.name.length > 2 ? 2 : c.name.length,
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              color: context.cSurfaceAlt,
                              alignment: Alignment.center,
                              child: Text(
                                c.name.substring(
                                  0,
                                  c.name.length > 2 ? 2 : c.name.length,
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                    ),
                  ),

                  const SizedBox(height: 4),

                  // 创作者名称
                  SizedBox(
                    width: 60,
                    child: Text(
                      c.name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected ? context.cAccent : context.cTextSub,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    });
  }

  /// 筛选下拉胶囊条。
  ///
  /// 文案与顺序**取自数据源解析结果**（官网 `.home-genre-tabs-wrapper`），
  /// 而不是在这里再硬编码一份 —— 官网一共 5 个（全部類型 / 標籤 / 排序方式 /
  /// 發佈日期 / 時長），早期 UI 自己写死了 4 个简体，比官网少一个「時長」。
  Widget _buildFilterBar(BuildContext context) {
    final parsed = Hanime1Controller.to.subData.value?.filters;
    final filters = (parsed == null || parsed.isEmpty)
        ? const <String>['全部類型', '標籤', '排序方式', '發佈日期', '時長']
        : parsed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: filters.asMap().entries.map((entry) {
                  final f = entry.value;
                  final type = const [
                    'genre',
                    'tags',
                    'sort',
                    'date',
                    'duration',
                  ][entry.key];
                  final ctrl = Hanime1Controller.to;
                  final active = switch (type) {
                    'genre' => ctrl.subscriptionGenre.value.isNotEmpty,
                    'tags' => ctrl.subscriptionTags.isNotEmpty,
                    'sort' => ctrl.subscriptionSort.value.isNotEmpty,
                    'date' => ctrl.subscriptionDate.value.isNotEmpty,
                    _ => ctrl.subscriptionDuration.value.isNotEmpty,
                  };
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _openFilter(context, type),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: active
                              ? context.cAccentContainer
                              : context.cSurfaceAlt,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: context.cTextMain.withValues(alpha: 0.15),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              f,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: context.cTextMain,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 16,
                              color: context.cTextSub,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          // 橙红色信息小圆圈 (还原截图 2 的 (i) 标)
          Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.info_outline, size: 16, color: context.cAccent),
          ),
        ],
      ),
    );
  }

  Future<void> _openFilter(BuildContext context, String type) async {
    if (type == 'tags') {
      await _openTagFilter(context);
      return;
    }
    final options = switch (type) {
      'genre' =>
        app_search.SearchController.hanime1GenreOptions
            .where((option) => option.$2 != 'H漫畫')
            .toList(),
      'sort' => <(String, String)>[
        ('全部', ''),
        ...app_search.SearchController.hanime1SortOptions,
      ],
      'date' => app_search.SearchController.hanime1DateOptions,
      _ => app_search.SearchController.hanime1DurationOptions,
    };
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cSurfaceAlt,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.62,
          child: ListView.builder(
            itemCount: options.length,
            itemBuilder: (ctx, index) {
              final option = options[index];
              return ListTile(
                title: Text(
                  option.$1,
                  style: TextStyle(color: context.cTextMain),
                ),
                onTap: () => Navigator.pop(ctx, option.$2),
              );
            },
          ),
        ),
      ),
    );
    if (selected != null) {
      Hanime1Controller.to.setSubscriptionFilter(type, selected);
    }
  }

  Future<void> _openTagFilter(BuildContext context) async {
    final ctrl = Hanime1Controller.to;
    final selected = ctrl.subscriptionTags.toSet();
    var broad = ctrl.subscriptionBroad.value;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cSurfaceAlt,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.78,
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(
                    '廣泛配對',
                    style: TextStyle(color: context.cTextMain),
                  ),
                  subtitle: Text(
                    '匹配任意一个所选标签',
                    style: TextStyle(color: context.cTextSub),
                  ),
                  value: broad,
                  onChanged: (value) => setSheetState(() => broad = value),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: hanime1TagGroups.length,
                    itemBuilder: (ctx, index) {
                      final group = hanime1TagGroups[index];
                      return ExpansionTile(
                        title: Text(
                          group.title,
                          style: TextStyle(color: context.cTextMain),
                        ),
                        children: group.tags
                            .map(
                              (tag) => CheckboxListTile(
                                title: Text(
                                  tag,
                                  style: TextStyle(color: context.cTextSub),
                                ),
                                value: selected.contains(tag),
                                onChanged: (value) => setSheetState(() {
                                  if (value == true) {
                                    selected.add(tag);
                                  } else {
                                    selected.remove(tag);
                                  }
                                }),
                              ),
                            )
                            .toList(),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        ctrl.setSubscriptionTags(
                          selected.toList(),
                          broad: broad,
                        );
                        Navigator.pop(ctx);
                      },
                      child: const Text('套用标签'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
