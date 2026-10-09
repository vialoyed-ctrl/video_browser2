/// PornHub 专属移动端主框架视图。
///
/// 与 [Hanime1MainView] 同构：AppBar（版面徽标 + 搜索入口）+ IndexedStack 四 Tab
/// + Material 3 NavigationBar。这样三个版面的导航观感完全一致。
///
/// 四个 Tab 与官网路径一一对应（均由实测确认）：
///   推荐 `/recommended?o=time` · 最热 `/video?o=ht`
///   订阅 `/subscriptions`     · 我的（收藏 `/users/<name>/videos/favorites`
///                              片单 `/users/<name>/playlists/favorites`
///                              历史 `/users/<name>/videos/recent`）
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../widgets/app_drawer.dart';
import '../pornhub_controller.dart';
import 'pornhub_more_page.dart';
import 'pornhub_mine_tab.dart';
import 'pornhub_search_page.dart';
import 'pornhub_subscriptions_tab.dart';
import 'pornhub_video_list_tab.dart';

class PornHubMainView extends StatelessWidget {
  const PornHubMainView({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = PornHubController.to;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: '打开功能与版面抽屉',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'P',
                style: TextStyle(
                  // 徽标底是 colorScheme.primary，文字必须用 onPrimary ——
                  // 莫奈取色下 primary 可能是浅色，写死白色会看不清。
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'PornHub',
              style:
                  theme.appBarTheme.titleTextStyle ??
                  theme.textTheme.titleMedium,
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索视频',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Get.to<void>(() => const PornHubSearchPage()),
          ),
          // 分类 / 片单 / 明星 作为子页面入口，不占主导航。
          PopupMenuButton<int>(
            tooltip: '更多',
            onSelected: (value) =>
                Get.to<void>(() => PornHubMorePage(initialIndex: value)),
            itemBuilder: (context) => const <PopupMenuEntry<int>>[
              PopupMenuItem<int>(value: 0, child: Text('分类')),
              PopupMenuItem<int>(value: 1, child: Text('片单')),
              PopupMenuItem<int>(value: 2, child: Text('明星')),
            ],
          ),
        ],
      ),
      body: Obx(() {
        final currentIdx = ctrl.currentTabIndex.value;
        return IndexedStack(
          index: currentIdx,
          children: <Widget>[
            const PornHubVideoListTab(path: '/recommended?o=time'),
            PornHubVideoListTab(
              path: PornHubController.hotPath,
              showSortBar: true,
            ),
            const PornHubSubscriptionsTab(),
            // 最右位原为「收藏」，现按用户要求改为「我的」：
            // 内含 收藏 / 片单 / 历史 三个板块（顶部按钮切换）。
            const PornHubMineTab(),
          ],
        );
      }),
      bottomNavigationBar: Obx(
        () => NavigationBar(
          selectedIndex: ctrl.currentTabIndex.value,
          onDestinationSelected: ctrl.switchTab,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.recommend_outlined),
              selectedIcon: Icon(Icons.recommend_rounded),
              label: '推荐',
            ),
            NavigationDestination(
              icon: Icon(Icons.local_fire_department_outlined),
              selectedIcon: Icon(Icons.local_fire_department_rounded),
              label: '最热',
            ),
            NavigationDestination(
              icon: Icon(Icons.subscriptions_outlined),
              selectedIcon: Icon(Icons.subscriptions_rounded),
              label: '订阅',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
