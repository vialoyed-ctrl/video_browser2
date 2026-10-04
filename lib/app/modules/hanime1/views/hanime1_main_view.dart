/// Hanime1 专属移动端主框架视图。
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../routes/app_navigator.dart';
import '../../../widgets/app_drawer.dart';
import '../hanime1_controller.dart';
import 'hanime1_home_tab.dart';
import 'hanime1_profile_tab.dart';
import 'hanime1_ranking_tab.dart';
import 'hanime1_subscriptions_tab.dart';

class Hanime1MainView extends StatelessWidget {
  const Hanime1MainView({super.key, required this.onSwitchTo91});

  final VoidCallback onSwitchTo91;

  @override
  Widget build(BuildContext context) {
    final ctrl = Hanime1Controller.to;
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
                'H',
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
              'Hanime1',
              style:
                  theme.appBarTheme.titleTextStyle ??
                  theme.textTheme.titleMedium,
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '新番預告',
            icon: const Icon(Icons.cast_rounded),
            onPressed: () => AppNavigator.toSearch(category: '新番預告'),
          ),
          IconButton(
            tooltip: '搜索番剧与作者',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => AppNavigator.toSearch(),
          ),
          IconButton(
            tooltip: '我的 Hanime1',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => ctrl.switchTab(3),
          ),
        ],
      ),
      body: Obx(() {
        final currentIdx = ctrl.currentTabIndex.value;
        return IndexedStack(
          index: currentIdx,
          children: <Widget>[
            const Hanime1HomeTab(),
            const Hanime1RankingTab(),
            const Hanime1SubscriptionsTab(),
            Hanime1ProfileTab(onSwitchTo91: onSwitchTo91),
          ],
        );
      }),
      // 91 与 Hanime1 版面共用应用主题定义的 Material 3 导航样式。
      bottomNavigationBar: Obx(
        () => NavigationBar(
          selectedIndex: ctrl.currentTabIndex.value,
          onDestinationSelected: ctrl.switchTab,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '主页',
            ),
            NavigationDestination(
              icon: Icon(Icons.ondemand_video_outlined),
              selectedIcon: Icon(Icons.ondemand_video_rounded),
              label: '本日排行',
            ),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library_rounded),
              label: '订阅内容',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: '我的 Hanime1',
            ),
          ],
        ),
      ),
    );
  }
}
