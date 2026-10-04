import 'bottom_load_gate.dart';
import 'retained_page_sliver.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One pagination interaction for all remote video lists.
class AppendPaginationFooter extends StatelessWidget {
  const AppendPaginationFooter({
    super.key,
    required this.page,
    required this.hasMore,
    required this.onNext,
    this.onJump,
    this.loading = false,
    this.error,
    this.totalPages,
  });
  final int page;
  final int? totalPages;
  final bool hasMore;
  final bool loading;
  final String? error;
  final VoidCallback? onNext;
  final ValueChanged<int>? onJump;

  Future<void> _jump(BuildContext context) async {
    final target = await showDialog<int>(
      context: context,
      builder: (_) => _PageJumpDialog(
        page: PageFooterScope.of(context)?.page ?? page,
        totalPages: totalPages,
      ),
    );
    if (target != null && context.mounted) onJump?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final scope = PageFooterScope.of(context);
    final displayPage = scope?.page ?? page;
    final active = scope?.active ?? true;
    final total = totalPages != null && totalPages! > 0 ? totalPages : null;
    final numbers = <int>{
      1,
      for (var n = displayPage - 2; n <= displayPage + 2; n++)
        if (n > 0 && (total == null || n <= total)) n,
      ?total,
    }.toList()..sort();
    final chips = <Widget>[];
    for (var i = 0; i < numbers.length; i++) {
      if (i > 0 && numbers[i] - numbers[i - 1] > 1) {
        chips.add(
          TextButton(
            onPressed: loading ? null : () => _jump(context),
            child: const Text('…'),
          ),
        );
      }
      final number = numbers[i];
      chips.add(
        SizedBox(
          width: 44,
          height: 44,
          child: Material(
            color: number == displayPage
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: loading || onJump == null
                  ? null
                  : () => number == displayPage
                        ? _jump(context)
                        : onJump!(number),
              onLongPress: loading || onJump == null
                  ? null
                  : () => _jump(context),
              child: Center(
                child: Text(
                  '$number',
                  style: TextStyle(
                    fontWeight: number == displayPage
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return BottomLoadGate(
      enabled: active && !loading && error == null && hasMore,
      onNext: onNext,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              total == null
                  ? '第 $displayPage 页'
                  : '第 $displayPage 页 · 共 $total 页',
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    chips[i],
                  ],
                ],
              ),
            ),
            if (active) ...[
              const SizedBox(height: 10),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (error != null)
                TextButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(error!),
                )
              else
                Text(
                  hasMore ? '↑ 继续上滑，加载下一页' : '已到最后一页',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PageJumpDialog extends StatefulWidget {
  const _PageJumpDialog({required this.page, this.totalPages});
  final int page;
  final int? totalPages;
  @override
  State<_PageJumpDialog> createState() => _PageJumpDialogState();
}

class _PageJumpDialogState extends State<_PageJumpDialog> {
  late final input = TextEditingController(text: '${widget.page}');
  String? validation;
  @override
  void initState() {
    super.initState();
    input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: input.text.length,
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void confirm() {
    final value = int.tryParse(input.text);
    if (value == null || value < 1) {
      setState(() => validation = '请输入大于 0 的页码');
      return;
    }
    if (widget.totalPages != null && value > widget.totalPages!) {
      setState(() => validation = '最大页码为 ${widget.totalPages}');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('跳转页码'),
    content: TextField(
      controller: input,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(7),
      ],
      onSubmitted: (_) => confirm(),
      decoration: InputDecoration(
        labelText: '页码',
        helperText: widget.totalPages == null
            ? null
            : '可输入 1–${widget.totalPages}',
        errorText: validation,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: confirm, child: const Text('跳转')),
    ],
  );
}
