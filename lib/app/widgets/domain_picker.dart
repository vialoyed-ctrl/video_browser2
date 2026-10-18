/// 内容域名选择对话框。
///
/// 设计取向：**默认自动**，手动只作为兜底。
///   - 打开对话框即自动检测：优先复用当前地址，失败才尝试少量发布页 → 取直连清单 →
///     逐个探测，**命中一个就停**，然后自动加入列表、选中、保存并关闭。
///   - 「测试」仍然只是纯探测，不改变当前生效域名（[Site91Source.probeDomain]）。
///   - 底部主按钮在输入新域名时显示「添加并使用」，否则显示「保存并使用」；
///     两种操作都会采用并持久化（[Site91Source.saveDomainConfiguration]）。
///
/// 自动检测期间若用户已经开始手动操作（输入框有内容 / 点过测试 / 选过条目），
/// 则不再自动采用，只把检测结果摆进列表，把决定权交回用户。
///
/// 本文件只服务 91 源（91porny），恢复为原先写死 [Site91Source] 的形态。
/// 91麻豆 有独立的 `site91md_domain_picker.dart`，两者互不影响。
library;

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

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

  /// 自动检测是否在进行中。
  bool _autoDetecting = false;
  CancelToken? _discoveryCancel;

  /// 自动检测当前阶段：`publish` 找发布页 / `direct` 探直连。
  String _autoStage = 'publish';

  /// 当前阶段已探测的数量，用于给用户一个「还在动」的反馈。
  int _autoTested = 0;

  /// 自动检测是否已经跑完且没找到可用域名。
  bool _autoFailed = false;

  /// 用户是否已经手动干预过。为 true 时自动检测不再抢方向盘。
  bool _userTouched = false;

  @override
  void initState() {
    super.initState();
    final current = widget.source.normalizeDomainInput(
      widget.source.currentBaseUrl,
    );
    _selected = current.isNotEmpty
        ? current
        : (widget.source.domainCandidates.isNotEmpty
              ? widget.source.domainCandidates.first
              : '');
    // 先把手动清单读完，再开始自动检测 —— 否则两边的 setState 会互相覆盖。
    _loadCustomDomains().then((_) {
      if (mounted) _autoDetect();
    });
  }

  @override
  void dispose() {
    _discoveryCancel?.cancel('Domain dialog closed');
    _customCtrl.dispose();
    super.dispose();
  }

  /// 自动检测并采用一个可用域名。**找到一个就停**（由数据层保证）。
  Future<void> _autoDetect() async {
    if (_autoDetecting) return;
    setState(() {
      _autoDetecting = true;
      _autoStage = 'publish';
      _autoTested = 0;
      _autoFailed = false;
    });

    final cancel = CancelToken();
    _discoveryCancel = cancel;
    DomainDiscoveryResult result;
    try {
      result = await widget.source.discoverWorkingDomain(
        cancelToken: cancel,
        onProgress: (stage, tested) {
          if (!mounted) return;
          setState(() {
            _autoStage = stage;
            _autoTested = tested;
          });
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _autoDetecting = false;
        _autoFailed = true;
      });
      return;
    } finally {
      cancel.cancel('Dialog discovery finished');
      if (identical(_discoveryCancel, cancel)) _discoveryCancel = null;
    }
    if (!mounted) return;

    setState(() {
      _autoDetecting = false;
      _autoFailed = !result.found;
    });
    if (!result.found) return;

    final domain = widget.source.normalizeDomainInput(result.domain!);
    if (domain.isEmpty) return;

    final customDomains = List<String>.of(_customDomains);
    if (!widget.source.domainCandidates.contains(domain) &&
        !customDomains.contains(domain)) {
      customDomains.add(domain);
    }
    setState(() {
      _customDomains = customDomains;
      if (!_userTouched && !_saving) _selected = domain;
    });

    // 用户已经在手动操作，就不自动保存 —— 把结果摆在列表里让他自己定。
    if (_userTouched || _saving) return;

    setState(() => _saving = true);
    await widget.source.saveDomainConfiguration(
      domain,
      customDomains: customDomains,
    );
    if (!mounted) return;
    AppToast.show('已自动检测并启用 ${domain.replaceFirst(RegExp(r'^https?://'), '')}');
    Navigator.of(context).pop(true);
  }

  Future<void> _loadCustomDomains() async {
    final domains = await widget.source.loadCustomDomains();
    if (!mounted) return;
    setState(() {
      _customDomains = domains;
      _loadingCustomDomains = false;
      if (!widget.source.domainCandidates.contains(_selected) &&
          !domains.contains(_selected)) {
        _selected = widget.source.domainCandidates.first;
      }
    });
  }

  Future<void> _test(String domain) async {
    _userTouched = true;
    setState(() => _probe[domain] = _ProbeState.testing);
    final ok = await widget.source.probeDomain(domain);
    if (!mounted) return;
    setState(() => _probe[domain] = ok ? _ProbeState.ok : _ProbeState.fail);
  }

  Future<void> _removeCustomDomain(String domain) async {
    _userTouched = true;
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
      if (_selected == domain) {
        _selected = widget.source.domainCandidates.first;
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _loadingCustomDomains) return;
    var selected = _selected;
    final customDomains = List<String>.of(_customDomains);
    final input = _customCtrl.text.trim();
    if (input.isNotEmpty) {
      selected = widget.source.normalizeDomainInput(input);
      if (selected.isEmpty) {
        AppToast.show('请输入有效的域名，例如 www.example.com');
        return;
      }
      if (!widget.source.domainCandidates.contains(selected) &&
          !customDomains.contains(selected)) {
        customDomains.add(selected);
      }
    }
    if (selected.isEmpty) return;
    _userTouched = true;
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
                    ? '首次使用会自动从地址发布页检测一个可用域名。检测不到时，'
                          '手动输入或点右侧「测试」选一个即可。选择结果会被记住。'
                    : '内容域名会经常更换。打开时已自动检测；也可删除自定义域名，'
                          '或输入新域名后添加并使用。',
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.hintColor,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 8),
              _autoStatusRow(theme),
              const SizedBox(height: 2),
              for (final domain in widget.source.domainCandidates)
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
                onChanged: (_) => _userTouched = true,
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

  Widget _autoStatusRow(ThemeData theme) {
    if (!_autoDetecting && !_autoFailed) return const SizedBox.shrink();
    final label = _autoDetecting
        ? (_autoStage == 'direct'
              ? '正在探测直连域名…（已试 $_autoTested 个）'
              : '正在查找地址发布页…（已试 $_autoTested 个）')
        : '自动检测未找到可用域名，请手动输入或点「测试」';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (_autoDetecting)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.info_outline, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String domain, ThemeData theme, {required bool isCustom}) {
    final selected = domain == _selected;
    final state = _probe[domain] ?? _ProbeState.unknown;
    return InkWell(
      onTap: () => setState(() {
        _selected = domain;
        _userTouched = true;
      }),
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
