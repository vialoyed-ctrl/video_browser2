/// 首页视图：浏览列表 + 触底分页 + 官方侧边栏 + 九色热搜 + 分类标签栏。
library;

import '../../widgets/retained_page_sliver.dart';

import 'package:flutter/material.dart';

import '../../widgets/append_pagination_footer.dart';

import '../../core/app_theme.dart';

import 'package:get/get.dart';

import '../../core/responsive_utils.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/site91_source.dart';
import '../../data/sources/site91md_source.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_navigator.dart';
import '../../routes/app_routes.dart';
import '../../services/download_service.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/bili_video_card.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_picker.dart';
import '../../widgets/log_viewer_dialog.dart';
import '../../widgets/site91md_domain_picker.dart';
import '../downloads/downloads_view.dart';
import 'home_controller.dart';
import 'site91md_category_bar.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: '打开侧边栏菜单',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Obx(() {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      controller.currentTitle,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (controller.currentChannel.value != ChannelType.home) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        controller.currentChannel.value.label,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                controller.sourceName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        }),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: () => Get.toNamed<dynamic>(AppRoutes.search),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '下载管理',
            onPressed: () => Get.to<void>(() => const DownloadsView()),
            icon: Obx(() {
              final active = Get.find<DownloadService>().tasks
                  .where((t) => t.isActive)
                  .length;
              return Badge(
                isLabelVisible: active > 0,
                label: Text('$active'),
                child: const Icon(Icons.download_outlined),
              );
            }),
          ),
          IconButton(
            tooltip: '运行日志',
            onPressed: () => LogViewerDialog.show(context),
            icon: const Icon(Icons.terminal),
          ),
          Obx(() {
            // 只有 91 / 91麻豆 才有「内容域名」这个概念（hanime1 是固定域名）。
            // 这里刻意用类型判断而不是比较 id 字符串 —— 原先写成
            // `source.id == '91porny'`，而 Site91Source.id 实际是 'site91'，
            // 条件恒为 false，导致这个按钮从不显示。
            //
            // 91 与 91麻豆 各自走**独立**的域名对话框（模块隔离：互不依赖、互不影响）。
            if (controller.source is Site91Source) {
              return IconButton(
                tooltip: '选择内容域名',
                onPressed: () => _showDomainDialog(context),
                icon: const Icon(Icons.language),
              );
            }
            if (controller.source is Site91MdSource) {
              return IconButton(
                tooltip: '选择内容域名',
                onPressed: () => _showSite91MdDomainDialog(context),
                icon: const Icon(Icons.language),
              );
            }
            return const SizedBox.shrink();
          }),
          IconButton(
            tooltip: '刷新',
            onPressed: controller.loadFirstPage,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Obx(() {
        if (controller.source is Site91MdSource) {
          return Column(
            children: [
              Site91MdCategoryBar(
                categories: controller.site91mdCategories.toList(),
                selectedId: controller.currentChannel.value == ChannelType.home
                    ? null
                    : controller.currentCategory.value?.id,
                loading: controller.loadingSite91mdCategories.value,
                error: controller.site91mdCategoriesError.value,
                onRetry: () => controller.loadSite91mdCategories(refresh: true),
                onSelect: (category) => controller.switchChannel(
                  category == null ? ChannelType.home : ChannelType.video,
                  category,
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _feed(context)),
            ],
          );
        }
        return _feed(context);
      }),
    );
  }

  Widget _feed(BuildContext context) {
    if (controller.loadingFirst.value &&
        (controller.source is Site91MdSource || controller.videos.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = controller.error.value;
    if (error != null &&
        (controller.source is Site91MdSource || controller.videos.isEmpty)) {
      return ErrorView(message: error, onRetry: controller.loadFirstPage);
    }
    if (controller.videos.isEmpty) {
      return const EmptyView(
        message: '当前分类下没有返回任何视频条目',
        icon: Icons.video_library_outlined,
      );
    }
    return _grid(context);
  }

  Widget _grid(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = ResponsiveLayout.isWideScreen(context);
    final availableWidth = isWide ? screenWidth - 73 : screenWidth;
    final columnCount = ResponsiveLayout.gridColumnCount(availableWidth);
    final columnWidth =
        (availableWidth - 12 - (columnCount - 1) * 6) / columnCount;
    final childAspectRatio = ResponsiveLayout.cardAspectRatio(columnWidth);

    return RefreshIndicator(
      onRefresh: controller.loadFirstPage,
      child: CustomScrollView(
        controller: controller.scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          // 顶部专区横幅：九色热搜（首页）或 二级分类栏（视频/蝌蚪/精品）
          if (controller.source is! Site91MdSource)
            SliverToBoxAdapter(child: Obx(() => _buildHeaderSection(context))),

          // 视频网格列表（动态 2~5 列智能自适应）
          RetainedPageSliver(
            key: ValueKey(
              '${controller.source.id}:${controller.currentChannel.value}:${controller.currentCategory.value?.path}',
            ),
            items: List.of(controller.videos),
            page: controller.currentPage.value,
            footer: _footer(context),
            gridBuilder: (pageItems) => SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columnCount,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                  childAspectRatio: childAspectRatio,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final video = pageItems[index];
                  return BiliVideoCardV(
                    video: video,
                    onTap: () => AppNavigator.toPlayer(video),
                    onDownload: () => _enqueue(video),
                  );
                }, childCount: pageItems.length),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部动态内容区：九色热搜词条（首页模式）或 子分类横向滚动切换条（频道模式）
  Widget _buildHeaderSection(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (controller.currentChannel.value == ChannelType.home) {
      // 首页：展示与官网完全一致的“九色热搜”词流
      final kws = controller.hotKeywords;
      if (kws.isEmpty) return const SizedBox.shrink();

      final expanded = controller.hotKeywordsExpanded.value;
      final displayKws = expanded ? kws : kws.take(16).toList();

      return Container(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.cSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.cBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  color: context.cAccent,
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(
                  controller.source.id == 'hanime1' ? 'Hanime1 热门标签' : '九色热搜',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: context.cTextMain,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: controller.toggleHotKeywordsExpand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        Text(
                          expanded ? '收起' : '+更多',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: displayKws.map((kw) {
                return InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => controller.searchKeyword(kw),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? theme.colorScheme.primary.withValues(alpha: 0.12)
                          : theme.colorScheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      kw,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );
    } else {
      // 频道模式：展示二级子分类横向滑动条
      final categories = controller.currentCategories;
      if (categories.isEmpty) return const SizedBox.shrink();

      final currentCat = controller.currentCategory.value;

      return Container(
        height: 44,
        margin: const EdgeInsets.only(top: 4, bottom: 4),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: categories.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final cat = categories[index];
            final isSelected = currentCat?.id == cat.id;

            return Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => controller.selectCategory(cat),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : (context.cSurfaceAlt),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : (context.cBorder),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? context.scheme.onPrimary
                          : context.cTextMain,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
  }

  Widget _footer(BuildContext context) => Obx(
    () => AppendPaginationFooter(
      page: controller.currentPage.value,
      hasMore: controller.hasMore.value,
      loading: controller.loadingMore.value || controller.loadingFirst.value,
      error: controller.loadMoreError.value,
      onJump: controller.jumpToPage,
      onNext: controller.retryOrLoadMore,
    ),
  );

  void _enqueue(VideoItem video) {
    final service = Get.find<DownloadService>();

    DownloadTask? existing;
    for (final task in service.tasks) {
      if (task.id == video.id) {
        existing = task;
        break;
      }
    }

    if (existing != null && existing.isActive) {
      _toast('「${video.title}」已在下载队列中');
      return;
    }
    service.enqueue(video);
    _toast('已加入下载队列：${video.title}');
  }

  void _toast(String message) {
    AppToast.show(message);
  }

  /// 打开内容域名选择对话框。
  ///
  /// 对话框本身见 [showDomainPicker] —— 首页入口与首次启动引导共用同一份实现，
  /// 避免「首次引导」和「手动切换」两套 UI 行为不一致。
  Future<void> _showDomainDialog(BuildContext context) async {
    final ok = await showDomainPicker(context);
    if (!ok) return;
    _toast('域名已更新，正在刷新...');
    controller.loadFirstPage();
  }

  /// 打开 91麻豆 自己的内容域名对话框。
  ///
  /// 与 91 的对话框完全独立（[showSite91MdDomainPicker]），这样新增源不会
  /// 反过来要求改动 91 的对话框实现。
  Future<void> _showSite91MdDomainDialog(BuildContext context) async {
    final ok = await showSite91MdDomainPicker(context);
    if (!ok) return;
    _toast('域名已更新，正在刷新...');
    controller.loadSite91mdCategories(refresh: true);
    controller.loadFirstPage(supersede: true);
  }
}
