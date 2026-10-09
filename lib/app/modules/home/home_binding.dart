import 'package:get/get.dart';

import '../../data/sources/video_source.dart';
import 'home_controller.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<HomeController>(
      () => HomeController(Get.find<VideoSource>()),
      fenix: true,
    );
  }
}
