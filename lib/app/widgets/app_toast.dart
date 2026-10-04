import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart';

/// 全局统一轻量提示组件：
/// 1. 采用顶部浮动展示 (ToastGravity.TOP)，完全避免遮挡底部操作栏与导航按键。
/// 2. 弹出前自动取消旧的提示 (Fluttertoast.cancel)，避免连续点击时提示排队堆叠。
/// 3. 系统原生穿透层，完全不拦截屏幕触摸事件。
class AppToast {
  static void show(String message) {
    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.TOP,
      backgroundColor: Get.theme.colorScheme.inverseSurface,
      textColor: Get.theme.colorScheme.onInverseSurface,
      fontSize: 13.0,
    );
  }
}
