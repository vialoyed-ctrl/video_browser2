import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

/// Compact page links matching Hanime1's mobile pagination.
class Hanime1Pagination extends StatelessWidget {
  const Hanime1Pagination({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.onPageChanged,
    this.isLoading = false,
  });

  final int currentPage;
  final int totalPages;
  final ValueChanged<int> onPageChanged;
  final bool isLoading;

  // 边框 / 选中色不再写死，改由 AppPalette 语义色提供。

  static List<int?> _window(int current, int total) {
    if (total <= 1) return const [];
    if (total <= 7) return List<int?>.generate(total, (i) => i + 1);
    if (current <= 2) return <int?>[1, 2, 3, 4, null, total - 1, total];
    if (current >= total - 1) {
      return <int?>[1, 2, null, for (var i = total - 4; i <= total; i++) i];
    }
    return <int?>[
      1,
      2,
      null,
      current - 1,
      current,
      current + 1,
      null,
      total - 1,
      total,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    final safeCurrent = currentPage.clamp(1, totalPages);
    final pages = _window(safeCurrent, totalPages);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 30, 8, 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          _cell(
            context,
            '‹',
            enabled: safeCurrent > 1,
            noBorder: safeCurrent <= 1,
            onTap: () => onPageChanged(safeCurrent - 1),
          ),
          for (final page in pages)
            if (page == null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '...',
                  style: TextStyle(color: context.cTextSub, fontSize: 12),
                ),
              )
            else
              _cell(
                context,
                '$page',
                selected: page == safeCurrent,
                enabled: page != safeCurrent,
                onTap: () => onPageChanged(page),
              ),
          _cell(
            context,
            '›',
            enabled: safeCurrent < totalPages,
            noBorder: safeCurrent >= totalPages,
            onTap: () => onPageChanged(safeCurrent + 1),
          ),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    String label, {
    bool selected = false,
    bool enabled = false,
    bool noBorder = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled && !isLoading ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        constraints: const BoxConstraints(minHeight: 31),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: noBorder ? 5 : 10,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: selected ? context.cAccent : Colors.transparent,
          border: noBorder
              ? null
              : Border.all(color: selected ? context.cAccent : context.cBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            height: 1.428571429,
            fontWeight: FontWeight.w700,
            // 选中格是强调色底 → 用 onPrimary；未选中是透明底 → 用主文字色。
            // 原先写死白色，浅色模式下未选中的页码会变成白底白字。
            color: selected ? context.scheme.onPrimary : context.cTextMain,
          ),
        ),
      ),
    );
  }
}
