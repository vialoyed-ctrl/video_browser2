/// Hanime1 官网「儲存」弹层的原生实现。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/hanime1_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/hanime1_source.dart';
import '../../services/hanime1_auth_service.dart';
import '../../widgets/app_toast.dart';

class Hanime1SaveSheet extends StatefulWidget {
  const Hanime1SaveSheet({
    super.key,
    required this.source,
    required this.video,
    required this.onSavedStateChanged,
  });

  static Future<bool?> show(
    BuildContext context, {
    required Hanime1Source source,
    required VideoItem video,
    required ValueChanged<bool> onSavedStateChanged,
  }) {
    if (!Hanime1AuthService.to.isLoggedIn.value) {
      AppToast.show('請先登入 Hanime1');
      return Future<bool?>.value(null);
    }
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: .72,
        child: Hanime1SaveSheet(
          source: source,
          video: video,
          onSavedStateChanged: onSavedStateChanged,
        ),
      ),
    );
  }

  final Hanime1Source source;
  final VideoItem video;
  final ValueChanged<bool> onSavedStateChanged;

  @override
  State<Hanime1SaveSheet> createState() => _Hanime1SaveSheetState();
}

class _Hanime1SaveSheetState extends State<Hanime1SaveSheet> {
  List<Hanime1SaveOption> _options = <Hanime1SaveOption>[];
  final Set<String> _syncingIds = <String>{};
  final Map<String, bool> _pendingSavedStates = <String, bool>{};
  final Map<String, bool> _confirmedSavedStates = <String, bool>{};
  final Set<String> _unconfirmedSaveIds = <String>{};
  bool _loading = true;
  bool _loadFailed = false;
  bool _serverReadCompleted = false;
  bool _hasAuthoritativeSavedStates = false;
  bool _creating = false;

  bool get _hasSaved => _options.any((option) => option.isSaved);

  @override
  void initState() {
    super.initState();
    final cached = widget.source.getCachedVideoSaveOptions(widget.video.id);
    if (cached != null) _applyCachedOptions(cached);
    _loadOptions(showLoading: cached == null);
    if (cached == null) unawaited(_loadLocalCachedOptions());
  }

  void _applyCachedOptions(Hanime1CachedSaveOptions cached) {
    _options = cached.options;
    _loading = false;
    _hasAuthoritativeSavedStates = cached.hasCurrentVideoState;
    if (cached.hasCurrentVideoState) {
      for (final option in cached.options) {
        _confirmedSavedStates[option.id] = option.isSaved;
      }
    }
  }

  Future<void> _loadLocalCachedOptions() async {
    final cached = await widget.source.loadCachedVideoSaveOptions(
      widget.video.id,
    );
    if (!mounted ||
        _hasAuthoritativeSavedStates ||
        _options.isNotEmpty ||
        cached == null) {
      return;
    }
    setState(() {
      _applyCachedOptions(cached);
      _loadFailed = false;
    });
    if (cached.hasCurrentVideoState) {
      widget.onSavedStateChanged(_hasSaved);
    }
  }

  Future<void> _loadOptions({bool showLoading = true}) async {
    _serverReadCompleted = false;
    if (mounted) {
      setState(() {
        _loadFailed = false;
        if (showLoading && _options.isEmpty) _loading = true;
      });
    }
    final result = await widget.source.fetchVideoSaveOptions(widget.video.id);
    _serverReadCompleted = true;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadFailed = result == null && !_hasAuthoritativeSavedStates;
      if (result != null) {
        _hasAuthoritativeSavedStates = true;
        final currentById = <String, Hanime1SaveOption>{
          for (final option in _options) option.id: option,
        };
        _options = result.map((option) {
          final current = currentById[option.id];
          final hasPendingChange =
              _syncingIds.contains(option.id) ||
              _pendingSavedStates.containsKey(option.id);
          return hasPendingChange && current != null
              ? option.copyWith(isSaved: current.isSaved)
              : option;
        }).toList();
        for (final option in result) {
          if (!_syncingIds.contains(option.id) &&
              !_pendingSavedStates.containsKey(option.id)) {
            _confirmedSavedStates[option.id] = option.isSaved;
            _unconfirmedSaveIds.remove(option.id);
          }
        }
      }
    });
    if (result != null) widget.onSavedStateChanged(_hasSaved);
  }

  void _setSaved(Hanime1SaveOption option, bool saved) {
    if (option.isSaved == saved) return;
    if (_hasAuthoritativeSavedStates) {
      _confirmedSavedStates.putIfAbsent(option.id, () => option.isSaved);
    } else {
      _unconfirmedSaveIds.add(option.id);
    }

    // Reflect the checkbox immediately; server synchronization continues below.
    setState(() {
      _options = _options
          .map(
            (item) =>
                item.id == option.id ? item.copyWith(isSaved: saved) : item,
          )
          .toList();
    });
    widget.onSavedStateChanged(_hasSaved);

    // Keep only the latest requested state while an earlier request is in flight.
    _pendingSavedStates[option.id] = saved;
    unawaited(_drainSavedChanges(option.id));
  }

  Future<void> _drainSavedChanges(String playlistId) async {
    if (!_syncingIds.add(playlistId)) return;
    try {
      while (_pendingSavedStates.containsKey(playlistId)) {
        final saved = _pendingSavedStates.remove(playlistId)!;
        var success = false;
        try {
          success = await widget.source.setVideoSavedInPlaylist(
            widget.video.id,
            playlistId,
            saved: saved,
          );
        } catch (_) {
          success = false;
        }

        if (success) {
          _confirmedSavedStates[playlistId] = saved;
          final wasUnconfirmed = _unconfirmedSaveIds.remove(playlistId);
          if (mounted && wasUnconfirmed) setState(() {});
          continue;
        }

        // If the user changed the checkbox again while syncing, process that
        // newer choice first instead of reverting the visible state.
        if (_pendingSavedStates.containsKey(playlistId)) continue;

        final latest = widget.source.getCachedVideoSaveOptions(widget.video.id);
        if (latest?.hasCurrentVideoState == true) {
          for (final item in latest!.options) {
            if (item.id == playlistId) {
              _confirmedSavedStates[playlistId] = item.isSaved;
              _unconfirmedSaveIds.remove(playlistId);
              break;
            }
          }
        }
        if (!_confirmedSavedStates.containsKey(playlistId)) {
          _unconfirmedSaveIds.add(playlistId);
          AppToast.show('同步官網播放清單失敗，勾選狀態尚未確認');
          continue;
        }
        final confirmed = _confirmedSavedStates[playlistId]!;
        final correctedSavedState = _options.any(
          (item) => item.id == playlistId ? confirmed : item.isSaved,
        );
        if (mounted) {
          setState(() {
            _options = _options
                .map(
                  (item) => item.id == playlistId
                      ? item.copyWith(isSaved: confirmed)
                      : item,
                )
                .toList();
          });
        }
        widget.onSavedStateChanged(correctedSavedState);
        AppToast.show('同步官網播放清單失敗，已恢復原狀');
      }
    } finally {
      _syncingIds.remove(playlistId);
    }
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增播放清單'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '播放清單名稱'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('建立'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || title == null || title.trim().isEmpty) return;
    setState(() => _creating = true);
    final created = await widget.source.createPlaylistForVideo(
      widget.video.id,
      title,
    );
    if (!mounted) return;
    setState(() => _creating = false);
    if (!created) {
      AppToast.show('建立播放清單失敗，請確認名稱後重試');
      return;
    }
    AppToast.show('已建立並加入官網播放清單');
    await _loadOptions(showLoading: _options.isEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '儲存到播放清單',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '關閉',
                onPressed: () => Navigator.of(context).maybePop(_hasSaved),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _creating ? null : _createPlaylist,
            icon: _creating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('新增播放清單'),
          ),
        ),
        Expanded(
          child: _loading && _options.isEmpty
              ? const Center(child: Text('正在讀取官網播放清單…'))
              : _loadFailed && _options.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('無法載入官網播放清單'),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _loadOptions,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重試'),
                      ),
                    ],
                  ),
                )
              : _options.isEmpty
              ? const Center(child: Text('帳號目前沒有可用的播放清單'))
              : ListView.builder(
                  itemCount:
                      _options.length + (_hasAuthoritativeSavedStates ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (!_hasAuthoritativeSavedStates && index == 0) {
                      return ListTile(
                        dense: true,
                        title: Text(
                          _serverReadCompleted
                              ? '官網讀取失敗；可先勾選操作，重試後校正狀態'
                              : '清單已顯示，勾選可立即提交；官網狀態同步中…',
                        ),
                        trailing: _serverReadCompleted
                            ? IconButton(
                                tooltip: '重試',
                                onPressed: () =>
                                    _loadOptions(showLoading: false),
                                icon: const Icon(Icons.refresh_rounded),
                              )
                            : null,
                      );
                    }
                    final option =
                        _options[index -
                            (_hasAuthoritativeSavedStates ? 0 : 1)];
                    return ListTile(
                      leading: Icon(
                        option.isWatchLater
                            ? Icons.watch_later_outlined
                            : Icons.playlist_play_rounded,
                        color: option.isSaved
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        option.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _unconfirmedSaveIds.contains(option.id)
                          ? const Text('等待官網確認')
                          : null,
                      trailing: Checkbox(
                        value: option.isSaved,
                        onChanged: (value) => _setSaved(option, value ?? false),
                      ),
                      onTap: () => _setSaved(option, !option.isSaved),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).pop(_hasSaved),
              child: const Text('完成'),
            ),
          ),
        ),
      ],
    );
  }
}
