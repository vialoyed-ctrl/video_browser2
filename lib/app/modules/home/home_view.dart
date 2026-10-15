/// 首页视图：浏览列表 + 触底分页 + 官方侧边栏 + 九色热搜 + 分类标签栏。
library;

import 'package:flutter/material.dart';

import 'package:get/get.dart';

import '../../data/models/video_item.dart';
import '../../data/sources/site91_source.dart';
import '../../data/sources/site91md_source.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_routes.dart';
import '../../services/download_service.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/domain_picker.dart';
import '../../widgets/log_viewer_dialog.dart';
import '../../widgets/site91md_domain_picker.dart';
import '../downloads/downloads_view.dart';
import 'home_controller.dart';
import 'home_feed.dart';
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
              final active = Get.find<DownloadService>().activeTaskCount.value;
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
              Expanded(
                child: HomeFeed(controller: controller, onDownload: _enqueue),
              ),
            ],
          );
        }
        return HomeFeed(controller: controller, onDownload: _enqueue);
      }),
    );
  }

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
