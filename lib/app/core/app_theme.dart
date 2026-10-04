/// 应用主题：以 Material 3 的 [ColorScheme] 为**唯一色源**，并支持莫奈取色。
///
/// ## 为什么改成这样
///
/// 改造前主题虽然声明了 `ThemeMode.system`，但绝大多数组件把颜色**写死**成了
/// 深色字面量（`Colors.white` 文字、`Color(0xFF16181D)` 背景 …）。设备一旦处于
/// 浅色模式，就变成「白字压在白卡片上」—— 这就是「白底看不清字」的根因。
///
/// 现在全 App 只认 [AppPalette] 里的语义名（`cBg` / `cSurface` / `cTextMain` …），
/// 具体色值一律由 `ColorScheme` 派生。于是：
/// - 切换明暗：全 App 一起变；
/// - 开启莫奈取色（Android 12+ 壁纸）：中性色跟随壁纸，强调色保持品牌粉色；
/// - 不会再出现某处漏改导致的对比度事故。
///
/// ## 唯一例外：压在图片上的文字
///
/// `cOnImage` / `cImageScrim` 是**刻意与明暗无关**的常量。它们压在照片上，
/// 与页面底色无关 —— 若跟着主题变成浅色，在浅色照片上就会看不清。
library;

import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  /// 统一品牌强调色的种子色。
  static const Color brandSeed = Color(0xFFFA7298);
  // Video overlays keep their own high-contrast palette in both theme modes.
  static const Color playerAccent = Color(0xFFFF80AB);
  static const Color playerBuffer = Color(0x88FF80AB);
  static const Color playerGlow = Color(0x4DFF80AB);

  static ThemeData light({ColorScheme? dynamicScheme}) =>
      _build(Brightness.light, dynamicScheme);

  static ThemeData dark({ColorScheme? dynamicScheme}) =>
      _build(Brightness.dark, dynamicScheme);

  /// 深浅模式共用构建器。
  ///
  /// [dynamicScheme] 来自 `DynamicColorBuilder`（莫奈取色）。为空时退回品牌种子色，
  /// 因此在 Windows / Android 12 以下仍然是一套完整可用的 M3 配色。
  static ThemeData _build(Brightness brightness, ColorScheme? dynamicScheme) {
    final brand = ColorScheme.fromSeed(
      seedColor: brandSeed,
      brightness: brightness,
    );
    final scheme = (dynamicScheme ?? brand).copyWith(
      primary: brand.primary,
      onPrimary: brand.onPrimary,
      primaryContainer: brand.primaryContainer,
      onPrimaryContainer: brand.onPrimaryContainer,
      secondary: brand.secondary,
      onSecondary: brand.onSecondary,
      secondaryContainer: brand.secondaryContainer,
      onSecondaryContainer: brand.onSecondaryContainer,
      tertiary: brand.tertiary,
      onTertiary: brand.onTertiary,
      tertiaryContainer: brand.tertiaryContainer,
      onTertiaryContainer: brand.onTertiaryContainer,
    );

    return ThemeData(
      useMaterial3: true,
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        textStyle: TextStyle(color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
      ),
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardColor: scheme.surfaceContainerLow,
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0.5,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: scheme.onSurface),
        bodyMedium: TextStyle(color: scheme.onSurface),
        bodySmall: TextStyle(color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }
}

/// 全 App 的语义色板。
///
/// **不要再在组件里写 `Color(0x…)` / `Colors.white` 之类字面量** —— 那正是
/// 浅色模式下白字压白底的成因。需要新颜色时先在这里加一个语义名。
extension AppPalette on BuildContext {
  ColorScheme get scheme => Theme.of(this).colorScheme;

  Brightness get _brightness => Theme.of(this).brightness;

  /// 页面底色。
  Color get cBg => scheme.surface;

  /// 卡片 / 浮层底色（比页面底稍高一层）。
  Color get cSurface => scheme.surfaceContainerLow;

  /// 次级面：输入框、chip 底、hover 态。
  Color get cSurfaceAlt => scheme.surfaceContainerHigh;

  /// 更高的面：需要与 [cSurfaceAlt] 再拉开一层时用。
  Color get cSurfaceHigh => scheme.surfaceContainerHighest;

  /// 分隔线与描边。
  Color get cBorder => scheme.outlineVariant;

  /// 主文字。
  Color get cTextMain => scheme.onSurface;

  /// 次级文字（说明、时间、计数）。
  Color get cTextSub => scheme.onSurfaceVariant;

  /// 最弱的文字 / 占位符 / 禁用态。
  Color get cTextFaint => scheme.outline;

  /// 强调色（品牌色 / 可点击）。
  Color get cAccent => scheme.primary;

  /// 强调色容器（选中态底、徽标底）。
  Color get cAccentContainer => scheme.primaryContainer;

  /// 强调色容器上的文字。
  Color get cOnAccentContainer => scheme.onPrimaryContainer;

  /// 错误色。
  Color get cError => scheme.error;

  /// 提示 / 警告框底色（原先是 Bootstrap 的琥珀色 `#FFF3CD`）。
  Color get cWarningSurface => scheme.tertiaryContainer;

  /// 提示 / 警告框描边。
  Color get cWarningBorder => scheme.tertiary.withValues(alpha: 0.45);

  /// 提示 / 警告框上的文字。
  Color get cOnWarningSurface => scheme.onTertiaryContainer;

  // ---------------------------------------------------------------- 图片叠加
  //
  // 下面两个**刻意不随明暗变化**：它们压在照片上，与页面底色无关。
  // 若跟着主题变成浅色，在浅色照片上就会看不清。

  /// 压在图片上的文字 / 图标色。
  Color get cOnImage => Colors.white;

  /// 压在图片上的压暗层（渐变、scrim）。
  Color get cImageScrim => Colors.black;

  /// 图片占位底色（图片加载中/失败时）。
  Color get cImagePlaceholder => _brightness == Brightness.dark
      ? scheme.surfaceContainerHigh
      : scheme.surfaceContainerHighest;
}
