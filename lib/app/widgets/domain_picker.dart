/// 内容域名选择对话框。
///
/// 设计取向：域名由**用户显式选择**，不做「谁探测通过就用谁」的自动选优 ——
/// 探测结果取决于当时的网络环境，在用户手机上并不可靠。
///
/// 本对话框把「测试」与「采用」彻底分开：
///   - 点单项的「测试」= 纯探测，不改变当前生效域名（[Site91Source.probeDomain]）
///   - 底部主按钮在输入新域名时显示「添加并使用」，否则显示「保存并使用」；
///     两种操作都会采用并持久化（[Site91Source.setBaseUrl]）。
library;

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

import 'package:get/get.dart';

import '../data/sources/site91_source.dart';
import '../data/sources/video_source.dart';
import 'app_toast.dart';

/// 弹出内容域名选择对话框。返回 true 表示用户已选定并保存。
///
/// [force] 为 true 时用于首次启动引导：不可取消（无「取消」按钮、点击外部不关闭），
/// 必须选定一个域名才能继续。
Future<bool> showDomainPicker(
  BuildContext context, {
  bool force = false,
}) async {
  final source = Get.find<VideoSource>();
  if (source is! Site91Source) {
    if (!force) AppToast.show('当前内容源不支持配置域名');
    return false;
  }
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: !force,
    builder: (_) => _DomainPickerDialog(source: source, force: force),
  );
  return ok ?? false;
}

/// 单个域名的探测状态。
enum _ProbeState { unknown, testing, ok, fail }

class _DomainPickerDialog extends StatefulWidget {
  const _DomainPickerDialog({required this.source, required this.force});

  final Site91Source source;
  final bool force;

  @override
  State<_DomainPickerDialog> createState() => _DomainPickerDialogState();
}

class _DomainPickerDialogState extends State<_DomainPickerDialog> {
  late String _selected;
  List<String> _customDomains = <String>[];
  bool _loadingCustomDomains = true;
  bool _saving = false;
  final Map<String, _ProbeState> _probe = <String, _ProbeState>{};
  final TextEditingController _customCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final current = Site91Source.normalizeDomain(widget.source.currentBaseUrl);
    _selected = current.isNotEmpty
        ? current
        : (Site91Source.defaultDomains.isNotEmpty
              ? Site91Source.defaultDomains.first
              : '');
    _loadCustomDomains();
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCustomDomains() async {
    final domains = await widget.source.loadCustomDomains();
    if (!mounted) return;
    setState(() {
      _customDomains = domains;
      _loadingCustomDomains = false;
      if (!Site91Source.defaultDomains.contains(_selected) &&
          !domains.contains(_selected)) {
        _selected = Site91Source.defaultDomains.first;
      }
    });
  }

  Future<void> _test(String domain) async {
    setState(() => _probe[domain] = _ProbeState.testing);
    final ok = await widget.source.probeDomain(domain);
    if (!mounted) return;
    setState(() => _probe[domain] = ok ? _ProbeState.ok : _ProbeState.fail);
  }

  Future<void> _removeCustomDomain(String domain) async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自定义域名'),
        content: Text('确定从列表中删除 $domain 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (shouldRemove != true || !mounted) return;
    setState(() {
      _customDomains = _customDomains.where((item) => item != domain).toList();
      _probe.remove(domain);
      if (_selected == domain) _selected = Site91Source.defaultDomains.first;
    });
  }

  Future<void> _save() async {
    if (_saving || _loadingCustomDomains) return;
    var selected = _selected;
    final customDomains = List<String>.of(_customDomains);
    final input = _customCtrl.text.trim();
    if (input.isNotEmpty) {
      selected = Site91Source.normalizeDomain(input);
      if (selected.isEmpty) {
        AppToast.show('请输入有效的域名，例如 www.example.com');
        return;
      }
      if (!Site91Source.defaultDomains.contains(selected) &&
          !customDomains.contains(selected)) {
        customDomains.add(selected);
      }
    }
    if (selected.isEmpty) return;
    setState(() => _saving = true);
    await widget.source.saveDomainConfiguration(
      selected,
      customDomains: customDomains,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.force ? '请选择内容域名' : '选择内容域名',
        style: const TextStyle(fontSize: 16),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 430),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.force
                    ? '首次使用需要先选择一个内容域名。这类站点域名会经常更换，'
                          '选一个当前可用的即可 —— 不确定就点右侧「测试」。选择结果会被记住。'
                    : '内容域名会经常更换。可删除自定义域名，或输入新域名；'
                          '使用下方按钮添加并使用，或保存当前选择。',
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.hintColor,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              for (final domain in Site91Source.defaultDomains)
                _tile(domain, theme, isCustom: false),
              if (_loadingCustomDomains)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              for (final domain in _customDomains)
                _tile(domain, theme, isCustom: true),
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Text(
                '自定义域名',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _customCtrl,
                decoration: const InputDecoration(
                  hintText: '可省略 https://',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.force)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _customCtrl,
          builder: (context, value, _) {
            final hasCustomInput = value.text.trim().isNotEmpty;
            return FilledButton(
              onPressed:
                  (_selected.isEmpty && !hasCustomInput) ||
                      _loadingCustomDomains ||
                      _saving
                  ? null
                  : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(hasCustomInput ? '添加并使用' : '保存并使用'),
            );
          },
        ),
      ],
    );
  }

  Widget _tile(String domain, ThemeData theme, {required bool isCustom}) {
    final selected = domain == _selected;
    final state = _probe[domain] ?? _ProbeState.unknown;
    return InkWell(
      onTap: () => setState(() => _selected = domain),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? theme.colorScheme.primary : theme.hintColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                domain.replaceFirst(RegExp(r'^https?://'), ''),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _probeBadge(state, theme),
            TextButton(
              onPressed: state == _ProbeState.testing
                  ? null
                  : () => _test(domain),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('测试', style: TextStyle(fontSize: 12)),
            ),
            if (isCustom)
              IconButton(
                tooltip: '删除自定义域名',
                onPressed: () => _removeCustomDomain(domain),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 19),
              ),
          ],
        ),
      ),
    );
  }

  Widget _probeBadge(_ProbeState state, ThemeData theme) {
    switch (state) {
      case _ProbeState.unknown:
        return const SizedBox.shrink();
      case _ProbeState.testing:
        return const Padding(
          padding: EdgeInsets.only(right: 6),
          child: SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _ProbeState.ok:
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Icon(Icons.check_circle, size: 15, color: context.cAccent),
        );
      case _ProbeState.fail:
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Icon(
            Icons.error_outline,
            size: 15,
            color: theme.colorScheme.error,
          ),
        );
    }
  }
}
