/// 响应式多端与大屏（Android 平板、折叠屏、车机、横竖屏）自适应工具类。
/// 严格遵循 Google Material 3 Large Screens 规范及 Android 官方 Breakpoints。
library;

import 'package:flutter/material.dart';

class ResponsiveLayout {
  ResponsiveLayout._();

  /// 是否为平板设备（最短边 >= 600dp，Android 官方 Canonical Tablet 定义）
  static bool isTablet(BuildContext context) {
    return MediaQuery.sizeOf(context).shortestSide >= 600;
  }

  /// 是否处于横屏状态
  static bool isLandscape(BuildContext context) {
    return MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  /// 是否激活宽屏桌面/平板分栏模式：
  /// 宽度 >= 720dp，或者为平板且处于横向形态
  static bool isWideScreen(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 720 || (size.shortestSide >= 600 && size.width > size.height);
  }

  /// 依据可用宽度自适应计算瀑布流网格的列数：
  /// - 手机竖屏 (< 600dp)：2 列
  /// - 手机横屏 / 小平板竖屏 (600 ~ 899dp)：3 列
  /// - 平板大屏竖屏 / 标准平板横屏 (900 ~ 1199dp)：4 列
  /// - 平板超宽横屏 (>= 1200dp)：5 列
  static int gridColumnCount(double availableWidth) {
    if (availableWidth >= 1200) return 5;
    if (availableWidth >= 900) return 4;
    if (availableWidth >= 600) return 3;
    return 2;
  }

  /// 依据单列宽度动态计算 BiliVideoCardV 的黄金子组件宽高比 (childAspectRatio)，
  /// 封面比例恒定为 16:10，底部元数据区固定约 72~76dp，
  /// 保证在任何宽度下文字绝不越界、底部绝无空白黑边、封面不拉伸。
  static double cardAspectRatio(double columnWidth) {
    final coverHeight = columnWidth * (10.0 / 16.0);
    const contentHeight = 74.0;
    final totalHeight = coverHeight + contentHeight;
    return (columnWidth / totalHeight).clamp(0.85, 1.25);
  }

  /// 最大内容居中宽度（适用于弹窗、设置列表、超宽屏头部导航卡片）
  static const double maxContentWidth = 1100.0;
}
