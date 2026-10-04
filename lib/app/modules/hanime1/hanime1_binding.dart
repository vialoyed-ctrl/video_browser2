library;

import 'package:get/get.dart';

import '../../data/sources/hanime1_source.dart';
import '../../data/sources/video_source.dart';
import 'hanime1_controller.dart';

class Hanime1Binding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<Hanime1Controller>()) {
      final src = SourceRegistry.byId('hanime1') as Hanime1Source? ?? Hanime1Source();
      Get.put<Hanime1Controller>(Hanime1Controller(src), permanent: true);
    }
  }
}
