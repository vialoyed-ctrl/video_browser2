import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

class Hanime1SearchFilterSelection {
  const Hanime1SearchFilterSelection({
    required this.value,
    this.year = '',
    this.month = '',
  });

  final String value;
  final String year;
  final String month;
}

Future<Hanime1SearchFilterSelection?> showHanime1SearchFilterSheet({
  required BuildContext context,
  required String title,
  required List<(String, String)> options,
  required String selected,
  String selectedYear = '',
  String selectedMonth = '',
  bool showDateParts = false,
}) {
  final media = MediaQuery.of(context);
  final available =
      media.size.height - media.padding.top - media.padding.bottom;

  return showModalBottomSheet<Hanime1SearchFilterSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _Hanime1SearchFilterSheet(
      title: title,
      options: options,
      initialValue: selected,
      initialYear: selectedYear,
      initialMonth: selectedMonth,
      showDateParts: showDateParts,
      height: available * 0.97,
    ),
  );
}

class _Hanime1SearchFilterSheet extends StatefulWidget {
  const _Hanime1SearchFilterSheet({
    required this.title,
    required this.options,
    required this.initialValue,
    required this.initialYear,
    required this.initialMonth,
    required this.showDateParts,
    required this.height,
  });

  final String title;
  final List<(String, String)> options;
  final String initialValue;
  final String initialYear;
  final String initialMonth;
  final bool showDateParts;
  final double height;

  @override
  State<_Hanime1SearchFilterSheet> createState() =>
      _Hanime1SearchFilterSheetState();
}

class _Hanime1SearchFilterSheetState extends State<_Hanime1SearchFilterSheet> {
  late String _value =
      widget.showDateParts &&
          (widget.initialYear.isNotEmpty || widget.initialMonth.isNotEmpty)
      ? '__custom_date__'
      : widget.initialValue;
  late String _year = widget.initialYear;
  late String _month = widget.initialMonth;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: context.cSurface,
        border: Border.all(color: context.cBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(context),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final option in widget.options)
                  _option(option.$1, option.$2),
                if (widget.showDateParts) _dateDropdowns(),
              ],
            ),
          ),
          Divider(height: 1, color: context.cBorder),
          _footer(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: context.cTextMain,
            ),
          ),
          Positioned(
            left: 10,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 36),
              tooltip: '关闭',
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.close, size: 18, color: context.cTextMain),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Divider(height: 1, color: context.cBorder),
          ),
        ],
      ),
    );
  }

  /// 单个选项 —— 3 列网格里的一格。
  ///
  /// **点击即生效**（用户要求：不要再点底部的「显示搜索结果」）。
  /// 日期筛选例外：它要同时选「年 + 月」，只能由底部按钮统一提交。
  Widget _option(String label, String value) {
    final selected = value == _value;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        if (widget.showDateParts) {
          // 日期：只记录，等用户选完年/月再提交。
          setState(() {
            _value = value;
            _year = '';
            _month = '';
          });
          return;
        }
        // 类型 / 标签 / 排序 / 时长都是单选 —— 点了就提交并关闭面板。
        Navigator.pop(
          context,
          Hanime1SearchFilterSelection(
            value: value,
            year: _year,
            month: _month,
          ),
        );
      },
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? context.cSurfaceAlt : context.cSurface,
          border: Border(
            bottom: BorderSide(color: context.cBorder, width: 0.8),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? context.cAccent : context.cTextMain,
          ),
        ),
      ),
    );
  }

  Widget _dateDropdowns() {
    final now = DateTime.now();
    final years = <String>['', for (var y = now.year; y >= 1990; y--) '$y 年'];
    final months = <String>['', for (var m = 1; m <= 12; m++) '$m 月'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: _whiteDropdown(
              value: _year,
              values: years,
              hint: '全部年份…',
              label: (v) => v.isEmpty ? '全部年份…' : v,
              onChanged: (v) => setState(() {
                _year = v ?? '';
                _value = '__custom_date__';
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _whiteDropdown(
              value: _month,
              values: months,
              hint: '全部月份…',
              label: (v) => v.isEmpty ? '全部月份…' : v,
              onChanged: (v) => setState(() {
                _month = v ?? '';
                _value = '__custom_date__';
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _whiteDropdown({
    required String value,
    required List<String> values,
    required String hint,
    required String Function(String) label,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: context.cSurfaceAlt,
        borderRadius: BorderRadius.circular(3),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: TextStyle(fontSize: 11, color: context.cTextFaint),
          ),
          dropdownColor: context.cSurfaceAlt,
          iconEnabledColor: context.cTextSub,
          style: TextStyle(fontSize: 11, color: context.cTextMain),
          items: [
            for (final item in values)
              DropdownMenuItem<String>(value: item, child: Text(label(item))),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return SizedBox(
      height: 49,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: context.cTextMain,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                ),
              ),
              child: const Text('取消'),
            ),
            const Spacer(),
            SizedBox(
              height: 32,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.cSurfaceAlt,
                  foregroundColor: context.cTextMain,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                onPressed: () => Navigator.pop(
                  context,
                  Hanime1SearchFilterSelection(
                    value: _value == '__custom_date__' ? '' : _value,
                    year: _year,
                    month: _month,
                  ),
                ),
                child: const Text(
                  '显示搜索结果',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
