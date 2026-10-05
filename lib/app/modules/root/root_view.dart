/// 导航外壳：手机端底部导航栏 / 平板横屏与宽屏侧边导航栏 (NavigationRail) / Hanime1 独立全量版面。
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/responsive_utils.dart';
import '../../data/sources/site91_source.dart';
import '../../data/sources/video_source.dart';
import '../../widgets/domain_picker.dart';
import '../hanime1/views/hanime1_main_view.dart';
import '../home/home_view.dart';
import '../feed/feed_view.dart';
import '../mine/mine_view.dart';
import '../pornhub/views/pornhub_main_view.dart';
import 'root_controller.dart';

class RootView extends StatefulWidget {
  const RootView({super.key});

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  /// 内容域名是否已就绪。
  bool _domainReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareDomain());
  }

  /// 恢复上次选择的域名；从未选过则强制引导用户选一个。
  ///
  /// 只有 91（91porny）需要首次显式选择域名（无默认），因此这里仍写死 [Site91Source]。
  /// 91麻豆 主站固定，恢复时会自动回退主站，不在此处弹窗打断。
  Future<void> _prepareDomain() async {
    final source = Get.find<VideoSource>();
    if (source is! Site91Source) {
      if (mounted) setState(() => _domainReady = true);
      return;
    }
    if (await source.restoreSelectedDomain()) {
      if (mounted) setState(() => _domainReady = true);
      return;
    }
    if (!mounted) return;
    await showDomainPicker(context, force: true);
    if (mounted) setState(() => _domainReady = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_domainReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final rootCtrl = Get.find<RootController>();
    final isWide = ResponsiveLayout.isWideScreen(context);

    return Obx(() {
      // 若当前切换为 Hanime1 动漫专版，展示其专属移动端视觉（主页/本日排行/订阅内容/我的 Hanime1）
      if (rootCtrl.isHanime1) {
        return Hanime1MainView(onSwitchTo91: rootCtrl.switchTo91);
      }

      // PornHub 专版：主页 / 分类 / 搜索 / 我的
      if (rootCtrl.isPornHub) {
        return const PornHubMainView();
      }

      final currentIndex = rootCtrl.currentIndex.value;
      final pages = <Widget>[
        const HomeView(),
        if (rootCtrl.is91) const FeedView(),
        const MineView(),
      ];

      if (isWide) {
        // 平板大屏 / 宽屏横向模式：Material 3 规范侧边导航栏
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: currentIndex,
                onDestinationSelected: rootCtrl.switchTab,
                labelType: NavigationRailLabelType.all,
                minWidth: 72,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Theme.of(context).colorScheme.primary,
                    size: 32,
                  ),
                ),
                destinations: <NavigationRailDestination>[
                  NavigationRailDestination(
                    icon: Icon(Icons.video_library_outlined),
                    selectedIcon: Icon(Icons.video_library),
                    label: Text('浏览'),
                  ),
                  if (rootCtrl.is91)
                    const NavigationRailDestination(
                      icon: Icon(Icons.dynamic_feed_outlined),
                      selectedIcon: Icon(Icons.dynamic_feed),
                      label: Text('动态'),
                    ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: Text('我的'),
                  ),
                ],
              ),
              const VerticalDivider(thickness: 0.8, width: 0.8),
              Expanded(
                child: IndexedStack(index: currentIndex, children: pages),
              ),
            ],
          ),
        );
      }

      // 手机竖屏与窄屏模式：标准 91 底部导航栏
      return Scaffold(
        body: IndexedStack(index: currentIndex, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: rootCtrl.switchTab,
          destinations: <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library),
              label: '浏览',
            ),
            if (rootCtrl.is91)
              const NavigationDestination(
                icon: Icon(Icons.dynamic_feed_outlined),
                selectedIcon: Icon(Icons.dynamic_feed),
                label: '动态',
              ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      );
    });
  }
}
