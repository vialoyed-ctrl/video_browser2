/// 路由表。
library;

import 'package:get/get.dart';

import '../modules/player/player_view.dart';
import '../modules/root/root_binding.dart';
import '../modules/root/root_view.dart';
import '../modules/search/search_binding.dart';
import '../modules/search/search_view.dart';
import 'app_routes.dart';

abstract class AppPages {
  static final List<GetPage<dynamic>> routes = <GetPage<dynamic>>[
    GetPage<dynamic>(
      name: AppRoutes.root,
      page: RootView.new,
      binding: RootBinding(),
    ),
    GetPage<dynamic>(
      name: AppRoutes.player,
      page: PlayerView.new,
      preventDuplicates: false,
      // 播放页是压栈页，禁用返回手势外的转场动画以贴近原生播放器观感。
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 180),
    ),
    GetPage<dynamic>(
      name: AppRoutes.search,
      page: SearchView.new,
      binding: SearchBinding(),
    ),
  ];
}
