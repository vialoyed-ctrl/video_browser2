/// 根视图控制器：管理底部 Tab 页签索引及 91 / Hanime1 / PornHub 三版面切换。
library;

import 'package:get/get.dart';

import '../../data/sources/video_source.dart';
import '../../widgets/app_toast.dart';
import '../home/home_controller.dart';

/// 四个独立版面。
///
/// 统一列出可选版面，切换入口由 [RootController.switchTo] 管理。
/// `site91md`（91麻豆）与 `site91` 共用同一套「91 版面」（HomeView），
/// 区别只是数据源不同 —— 因此切换时要同步把 HomeController 的源换过去。
enum AppPlatform {
  site91('site91', '91 影视'),
  site91md('site91md', '91麻豆'),
  hanime1('hanime1', 'Hanime1 动漫'),
  pornHub('pornhub', 'PornHub');

  const AppPlatform(this.id, this.label);

  final String id;
  final String label;
}

class RootController extends GetxController {
  static RootController get to => Get.find<RootController>();

  /// 91 版面的底部 Tab 索引 (0: 浏览, 1: 我的)
  final RxInt currentIndex = 0.obs;

  /// 当前激活的版面。
  final Rx<AppPlatform> platform = AppPlatform.site91.obs;

  /// 兼容既有调用点（多处只判断「是不是 hanime1」）。
  final RxString activePlatform = 'site91'.obs;

  bool get isHanime => platform.value == AppPlatform.hanime1;
  bool get isHanime1 => isHanime;
  bool get isPornHub => platform.value == AppPlatform.pornHub;

  /// 是否为 91 影视版面。抽屉据此只在 91 下展示原来的频道菜单
  /// （PornHub 版面下那组菜单不再适用，改展示账号/登录块）。
  ///
  /// 注意：91麻豆是**独立版面**，`is91` 对它恒为 false —— 它有自己的菜单分支，
  /// 不会被误当成 91。
  bool get is91 => platform.value == AppPlatform.site91;

  /// 是否为 91麻豆版面。
  bool get is91md => platform.value == AppPlatform.site91md;

  void switchTab(int index) {
    if (index < 0 || index > (is91 ? 2 : 1)) return;
    currentIndex.value = index;
  }

  /// 切到指定版面。所有版面切换都走这一个入口，避免各写一套造成状态不同步。
  void switchTo(AppPlatform target) {
    final source = SourceRegistry.byId(target.id);
    if (source == null) {
      AppToast.show('未注册内容源：${target.id}');
      return;
    }
    platform.value = target;
    activePlatform.value = target.id;
    SourceRegistry.setActiveSource(source);
    Get.replace<VideoSource>(source);
    currentIndex.value = 0;

    // 91 与 91麻豆 共用同一套「91 版面」（HomeView / HomeController），
    // 必须把首页控制器的数据源切过去，否则会一直显示上一个源的内容。
    // hanime1 / pornhub 各有独立主视图，不动 HomeController。
    if ((target == AppPlatform.site91 || target == AppPlatform.site91md) &&
        Get.isRegistered<HomeController>()) {
      Get.find<HomeController>().switchSource(source);
    }

    AppToast.show('已切换到${target.label}');
  }

  /// 切回 91 影视版面
  void switchTo91() => switchTo(AppPlatform.site91);
}
