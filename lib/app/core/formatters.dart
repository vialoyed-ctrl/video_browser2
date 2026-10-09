/// 展示格式化工具。
///
/// 不引入 `intl`，避免为一个格式化需求增加依赖与本地化初始化成本。
library;

class Formatters {
  const Formatters._();

  /// `10:34` / `1:02:15`。
  static String duration(Duration? d) {
    if (d == null || d.inSeconds <= 0) return '--:--';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '${d.inMinutes}:$ss';
  }

  /// 播放量：`8600` -> `8.6千`，`182400` -> `18.2万`。
  static String count(int value) {
    if (value < 1000) return '$value';
    if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}千';
    if (value < 100000000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '${(value / 100000000).toStringAsFixed(1)}亿';
  }

  /// 字节：`1536` -> `1.5 KB`。
  static String bytes(int value) {
    if (value < 1024) return '$value B';
    const units = <String>['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }

  /// `2026-03-14` -> `2026.03.14`（与原项目文件名日期风格一致）。
  static String dottedDate(String? iso) {
    if (iso == null || iso.isEmpty) return 'unknown';
    return iso.replaceAll('-', '.');
  }

  /// 相对时间：`3天前`。
  static String relativeDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;

    final diff = DateTime.now().difference(parsed);
    if (diff.isNegative) return dottedDate(iso);
    if (diff.inDays >= 365) return '${(diff.inDays / 365).floor()}年前';
    if (diff.inDays >= 30) return '${(diff.inDays / 30).floor()}个月前';
    if (diff.inDays >= 1) return '${diff.inDays}天前';
    if (diff.inHours >= 1) return '${diff.inHours}小时前';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}分钟前';
    return '刚刚';
  }

  /// 播放进度 `0.42` -> `42%`。
  static String percent(double value) =>
      '${(value * 100).clamp(0, 100).round()}%';
}
