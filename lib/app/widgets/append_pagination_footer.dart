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
  });
  final int page;
  final bool hasMore;
  final bool loading;
  final String? error;
  final VoidCallback? onNext;
  final ValueChanged<int>? onJump;

  Future<void> _jump(BuildContext context) async {
    final target = await showDialog<int>(
      context: context,
      builder: (_) => _PageJumpDialog(page: page),
    );
    if (target != null && context.mounted) onJump?.call(target);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: loading || onJump == null
                  ? null
                  : () => _jump(context),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text('第 $page 页'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(120, 44)),
            ),
            FilledButton.tonalIcon(
              onPressed: loading || (!hasMore && error == null) ? null : onNext,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more, size: 18),
              label: Text(
                loading
                    ? '加载中'
                    : error != null
                    ? '重试本页'
                    : hasMore
                    ? '续接下一页'
                    : '已到最后一页',
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(140, 44)),
            ),
          ],
        ),
      ],
    ),
  );
}

class _PageJumpDialog extends StatefulWidget {
  const _PageJumpDialog({required this.page});
  final int page;
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
      decoration: InputDecoration(labelText: '页码', errorText: validation),
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
