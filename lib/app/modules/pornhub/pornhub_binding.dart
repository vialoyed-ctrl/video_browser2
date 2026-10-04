library;

import 'package:get/get.dart';

import '../../data/sources/pornhub_source.dart';
import '../../data/sources/video_source.dart';
import 'pornhub_controller.dart';

class PornHubBinding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<PornHubController>()) {
      final src =
          SourceRegistry.byId('pornhub') as PornHubSource? ?? PornHubSource();
      Get.put<PornHubController>(PornHubController(src), permanent: true);
    }
  }
}
