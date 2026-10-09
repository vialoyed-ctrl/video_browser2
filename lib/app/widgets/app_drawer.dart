/// 官方移动端风格左侧抽屉导航栏。
///
/// 支持 91 影视版面与 Hanime1 动漫双版面丝滑切换：
/// 1. 顶部登录/注册快捷栏；
/// 2. 主题色“分类菜单”条；
/// 3. 【视频】及其 14 大官方分类；
/// 4. 【蝌蚪】及其 3 大排序 + 18 大专区；
/// 5. 【精品】及其 4 大分类；
/// 6. 核心版面切换按钮（位于【精品】正下方，对应用户标红位置）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

import 'package:get/get.dart';

import '../data/sources/video_source.dart';
import '../modules/hanime1/hanime1_controller.dart';
import '../modules/home/home_controller.dart';
import '../modules/pornhub/pornhub_controller.dart';
import '../modules/root/root_controller.dart';
import '../services/hanime1_auth_service.dart';
import 'app_toast.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rootCtrl = Get.isRegistered<RootController>()
        ? RootController.to
        : null;
    final isHanime = rootCtrl?.isHanime ?? false;
    final isPornHub = rootCtrl?.isPornHub ?? false;
    // 没有 RootController 时按 91 处理，保持与改动前「非 hanime 即 91」一致。
    final is91 = rootCtrl?.is91 ?? true;
    // 91麻豆 是独立版面，共用 91 版面但菜单按自己的分类渲染。
    final is91md = rootCtrl?.is91md ?? false;

    // 只在 91 / 91麻豆 版面下才去取 HomeController。
    //
    // `HomeController` 是 `Get.lazyPut` 注册的，而 `Get.find` 会**立刻把它造出来**，
    // 触发 `onInit → loadFirstPage()`：拉整页 + `preloadList` 整页预加载。
    //
    // 这个抽屉被 `hanime1_main_view.dart` / `pornhub_main_view.dart` 的
    // `Scaffold.drawer` 引用，而 Scaffold **即使抽屉没被打开也会构建它** ——
    // 于是用户在 hanime1 / pornhub 版面时，后台照样在跑 91 的首页加载与整页预加载，
    // 主 isolate 被占满，最终触发 ANR。
    //
    // 91 菜单只在 `is91` / `is91md` 分支里消费 `homeCtrl`，非这两者时给 null 是安全的。
    final homeCtrl = ((is91 || is91md) && Get.isRegistered<HomeController>())
        ? Get.find<HomeController>()
        : null;
    final primaryColor = theme.colorScheme.primary;
    // 抽屉底色跟随主题（原先在深色下写死 #14161A、浅色下写死白色，
    // 等于绕过了 ColorScheme，莫奈取色也传不进来）。
    final drawerBg = theme.colorScheme.surface;

    return Drawer(
      backgroundColor: drawerBg,
      child: SafeArea(
        child: Column(
          children: [
            // 主题色“分类菜单”标题栏
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              color: primaryColor,
              child: Row(
                children: [
                  Icon(
                    isHanime
                        ? Icons.movie_filter_rounded
                        : (isPornHub
                              ? Icons.play_circle_outline_rounded
                              : (is91md
                                    ? Icons.local_movies_rounded
                                    : Icons.category_rounded)),
                    color: theme.colorScheme.onPrimary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isHanime
                        ? 'Hanime1 动漫菜单'
                        : (isPornHub
                              ? 'PornHub 账号'
                              : (is91md ? '91麻豆 分类菜单' : '分类菜单')),
                    style: TextStyle(
                      color: theme.colorScheme.onPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // 菜单列表项
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  if (is91) ...[
                    // 91 原始版面菜单（绝不修改 91 的板块与分类）
                    _buildSingleTile(
                      context: context,
                      icon: Icons.home_rounded,
                      title: '首页精选',
                      isSelected:
                          homeCtrl?.currentChannel.value == ChannelType.home,
                      onTap: () {
                        Navigator.of(context).pop();
                        homeCtrl?.switchChannel(ChannelType.home);
                      },
                    ),

                    // 频道 1：视频
                    _buildChannelExpansionTile(
                      context: context,
                      icon: Icons.videocam_rounded,
                      title: '视频',
                      channel: ChannelType.video,
                      categories:
                          homeCtrl?.source.categoriesForChannel(
                            ChannelType.video,
                          ) ??
                          VideoCategories.videoList,
                      homeCtrl: homeCtrl,
                    ),

                    // 频道 2：蝌蚪
                    _buildChannelExpansionTile(
                      context: context,
                      icon: Icons.play_arrow_rounded,
                      title: '蝌蚪',
                      channel: ChannelType.kedou,
                      categories:
                          homeCtrl?.source.categoriesForChannel(
                            ChannelType.kedou,
                          ) ??
                          VideoCategories.kedouList,
                      homeCtrl: homeCtrl,
                    ),

                    // 频道 3：精品
                    _buildChannelExpansionTile(
                      context: context,
                      icon: Icons.auto_awesome,
                      title: '精品',
                      channel: ChannelType.vod,
                      categories:
                          homeCtrl?.source.categoriesForChannel(
                            ChannelType.vod,
                          ) ??
                          VideoCategories.vodList,
                      homeCtrl: homeCtrl,
                    ),
                  ] else if (isHanime) ...[
                    // Hanime1 专属侧栏快捷项
                    _buildSingleTile(
                      context: context,
                      icon: Icons.home_rounded,
                      title: '主页推荐',
                      isSelected: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (Get.isRegistered<Hanime1Controller>()) {
                          Hanime1Controller.to.switchTab(0);
                        }
                      },
                    ),
                    _buildSingleTile(
                      context: context,
                      icon: Icons.ondemand_video_rounded,
                      title: '本日排行',
                      isSelected: false,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (Get.isRegistered<Hanime1Controller>()) {
                          Hanime1Controller.to.switchTab(1);
                        }
                      },
                    ),
                    _buildSingleTile(
                      context: context,
                      icon: Icons.video_library_rounded,
                      title: '订阅内容',
                      isSelected: false,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (Get.isRegistered<Hanime1Controller>()) {
                          Hanime1Controller.to.switchTab(2);
                        }
                      },
                    ),
                    _buildSingleTile(
                      context: context,
                      icon: Icons.person_rounded,
                      title: '我的 Hanime1',
                      isSelected: false,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (Get.isRegistered<Hanime1Controller>()) {
                          Hanime1Controller.to.switchTab(3);
                        }
                      },
                    ),
                  ] else if (is91md) ...[
                    // 91麻豆 版面：共用 91 版面骨架，但菜单按它自己的分类渲染。
                    _buildSingleTile(
                      context: context,
                      icon: Icons.home_rounded,
                      title: '首页',
                      isSelected:
                          homeCtrl?.currentChannel.value == ChannelType.home,
                      onTap: () {
                        Navigator.of(context).pop();
                        homeCtrl?.switchChannel(ChannelType.home);
                      },
                    ),
                    _buildChannelExpansionTile(
                      context: context,
                      icon: Icons.category_rounded,
                      title: '分类',
                      channel: ChannelType.video,
                      categories:
                          homeCtrl?.source.categoriesForChannel(
                            ChannelType.video,
                          ) ??
                          const <VideoCategory>[],
                      homeCtrl: homeCtrl,
                    ),
                  ] else ...[
                    // PornHub 版面：原「分类菜单」位置改为账号/登录块
                    // （用户要求：91 那组频道菜单只在 91 版面下显示）。
                    _buildPornHubAccountBlock(context),
                  ],

                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Divider(height: 1, thickness: 0.8),
                  ),

                  // 核心入口：版面切换大按钮（精准对应用户红圈所画位置：精品正下方）
                  _buildSourceSwitchCard(context, rootCtrl, isHanime),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    bool isSelected = false,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
      leading: Icon(
        icon,
        size: 20,
        color: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface,
        ),
      ),
      selected: isSelected,
      onTap: onTap,
    );
  }

  /// PornHub 版面的账号/登录块（取代 91 的频道菜单）。
  ///
  /// 未登录 → 一个「登录 PornHub」入口：切到「我的」Tab，那里未登录时会
  /// 就地展示现有的 [PornHubLoginForm]（复用既有登录流程，不另造一套）。
  /// 已登录 → 头像 + 用户名 + 刷新 + 退出。
  Widget _buildPornHubAccountBlock(BuildContext context) {
    final theme = Theme.of(context);
    if (!Get.isRegistered<PornHubController>()) {
      return const SizedBox.shrink();
    }
    final ctrl = PornHubController.to;
    return Obx(() {
      if (!ctrl.isLoggedIn) {
        return _buildSingleTile(
          context: context,
          icon: Icons.login_rounded,
          title: '登录 PornHub',
          onTap: () {
            Navigator.of(context).pop();
            // 我的 Tab（index 3）在未登录时会渲染登录表单。
            ctrl.switchTab(3);
          },
        );
      }
      final name = ctrl.userName;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primary,
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name.isEmpty ? '已登录' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () {
                unawaited(ctrl.loadFavorites());
                unawaited(ctrl.loadHistory());
                unawaited(ctrl.loadMyPlaylists());
                unawaited(ctrl.loadPublicPlaylists());
              },
            ),
            IconButton(
              tooltip: '退出登录',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.logout_rounded, size: 20),
              onPressed: () {
                unawaited(ctrl.logout());
                AppToast.show('已退出 PornHub 账号');
              },
            ),
          ],
        ),
      );
    });
  }

  Widget _buildChannelExpansionTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required ChannelType channel,
    required List<VideoCategory> categories,
    required HomeController? homeCtrl,
  }) {
    final theme = Theme.of(context);

    return Obx(() {
      final currentChannel = homeCtrl?.currentChannel.value;
      final currentCat = homeCtrl?.currentCategory.value;
      final isActive = currentChannel == channel;

      return Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: isActive,
          dense: true,
          visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
          leading: Icon(
            icon,
            size: 20,
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
          ),
          title: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              if (isActive && currentCat != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    currentCat.name,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          children: [
            Container(
              padding: const EdgeInsets.only(left: 32, right: 12, bottom: 8),
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: categories.map((cat) {
                  final isCatSelected = isActive && currentCat?.id == cat.id;
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.of(context).pop();
                      homeCtrl?.switchChannel(channel, cat);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isCatSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        cat.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isCatSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isCatSelected
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 各版面在切换按钮上的图标。
  static IconData _platformIcon(AppPlatform? platform) {
    switch (platform) {
      case AppPlatform.site91:
        return Icons.auto_awesome;
      case AppPlatform.site91md:
        return Icons.local_movies_rounded;
      case AppPlatform.hanime1:
        return Icons.movie_outlined;
      case AppPlatform.pornHub:
        return Icons.play_circle_outline_rounded;
      case null:
        return Icons.swap_horiz_rounded;
    }
  }

  /// 内容版面切换（对应用户红圈所画位置）。
  ///
  /// 三个版面**并列列出、直接点选**，而不是单个「循环切换」按钮 ——
  /// 三个以上时用循环按钮，用户无法判断要点几下才到自己要的版面。
  Widget _buildSourceSwitchCard(
    BuildContext context,
    RootController? rootCtrl,
    bool isHanime,
  ) {
    final theme = Theme.of(context);
    final current = rootCtrl?.platform.value;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              '内容版面',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final platform in AppPlatform.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  Navigator.of(context).pop();
                  rootCtrl?.switchTo(platform);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: platform == current
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: platform == current
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.4,
                            ),
                      width: platform == current ? 1.4 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _platformIcon(platform),
                        size: 18,
                        color: platform == current
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          platform.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: platform == current
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: platform == current
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (platform == current)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              ),
            ),

          // 如果处于 Hanime1 模式，展示账户状态快捷条
          if (isHanime) ...[
            const SizedBox(height: 8),
            Obx(() {
              final auth = Hanime1AuthService.to;
              final loggedIn = auth.isLoggedIn.value;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      loggedIn
                          ? Icons.check_circle
                          : Icons.account_circle_outlined,
                      size: 16,
                      color: loggedIn
                          ? context.cAccent
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        loggedIn
                            ? '${auth.username.value} (UID: ${auth.userId.value})'
                            : '未登录 Hanime1 (可同步订阅)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: loggedIn
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: loggedIn
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.outline,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        if (loggedIn) {
                          auth.logout();
                          AppToast.show('已退出 Hanime1 账号');
                        } else {
                          _showHanime1LoginDialog(context);
                        }
                      },
                      child: Text(
                        loggedIn ? '登出' : '登录',
                        style: TextStyle(
                          fontSize: 11,
                          color: loggedIn
                              ? context.cError
                              : theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  void _showHanime1LoginDialog(BuildContext context) {
    final emailCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    final isLogging = false.obs;
    final errorMsg = ''.obs;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.account_circle,
                color: Theme.of(ctx).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                '登录 Hanime1 账户',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Obx(
            () => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '登录后可同步关注订阅、云端播放列表与观看记录。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: '电邮地址',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pwdCtrl,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  obscureText: true,
                ),
                if (errorMsg.value.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorMsg.value,
                    style: TextStyle(color: context.cError, fontSize: 12),
                  ),
                ],
                if (isLogging.value) ...[
                  const SizedBox(height: 14),
                  const Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text('正在登录并验证凭据...', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton.tonal(
              onPressed: () async {
                final email = emailCtrl.text.trim();
                final pwd = pwdCtrl.text.trim();
                if (email.isEmpty || pwd.isEmpty) {
                  errorMsg.value = '请输入邮箱和密码';
                  return;
                }
                isLogging.value = true;
                errorMsg.value = '';
                final ok = await Hanime1AuthService.to.login(email, pwd);
                isLogging.value = false;
                if (ok) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  AppToast.show(
                    '登录成功：欢迎回来 ${Hanime1AuthService.to.username.value}',
                  );
                  if (Get.isRegistered<Hanime1Controller>()) {
                    Hanime1Controller.to.loadSubscriptions();
                    Hanime1Controller.to.loadHomeData();
                  }
                } else {
                  errorMsg.value = '登录失败，请检查账号密码或网络连接';
                }
              },
              child: const Text('登入'),
            ),
          ],
        );
      },
    );
  }
}
