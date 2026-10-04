import 'package:get/get.dart';

import '../downloads/downloads_binding.dart';
import '../hanime1/hanime1_binding.dart';
import '../home/home_binding.dart';
import '../pornhub/pornhub_binding.dart';
import '../search/search_binding.dart';
import 'root_controller.dart';

/// 根导航外壳的依赖注入。
class RootBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<RootController>(RootController(), permanent: true);
    HomeBinding().dependencies();
    Hanime1Binding().dependencies();
    PornHubBinding().dependencies();
    SearchBinding().dependencies();
    DownloadsBinding().dependencies();
  }
}
