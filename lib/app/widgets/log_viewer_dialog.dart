import 'package:flutter/material.dart';

import '../core/app_theme.dart';

import 'package:flutter/services.dart';

import '../core/app_logger.dart';
import 'app_toast.dart';

class LogViewerDialog extends StatefulWidget {
  const LogViewerDialog({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const LogViewerDialog(),
    );
  }

  @override
  State<LogViewerDialog> createState() => _LogViewerDialogState();
}

class _LogViewerDialogState extends State<LogViewerDialog> {
  final ScrollController _scrollController = ScrollController();
  final bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _copyLogs(BuildContext context) {
    final text = AppLogger.exportAll();
    Clipboard.setData(ClipboardData(text: text));
    AppToast.show('已复制全部日志到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.82,
      decoration: BoxDecoration(
        color: context.cSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // 顶部标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 22),
                const SizedBox(width: 8),
                const Text(
                  '运行日志 (LogViewer)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '清空日志',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () {
                    AppLogger.clear();
                    setState(() {});
                  },
                ),
                IconButton(
                  tooltip: '一键复制日志',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copyLogs(context),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 日志内容列表
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: AppLogger.logCountNotifier,
              builder: (context, _, _) {
                final logs = AppLogger.logs;
                if (logs.isEmpty) {
                  return Center(
                    child: Text(
                      '暂无日志记录',
                      style: TextStyle(color: context.cTextSub),
                    ),
                  );
                }

                if (_autoScroll && _scrollController.hasClients) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(
                        _scrollController.position.maxScrollExtent,
                      );
                    }
                  });
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final item = logs[index];
                    Color levelColor = context.cTextSub;
                    if (item.level == LogLevel.info) {
                      levelColor = context.cAccent;
                    }
                    if (item.level == LogLevel.warn) {
                      levelColor = context.scheme.tertiary;
                    }
                    if (item.level == LogLevel.error) {
                      levelColor = context.cError;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text:
                                  '[${item.time.toLocal().toIso8601String().replaceFirst('T', ' ')}] ',
                              style: TextStyle(
                                fontSize: 11,
                                color: context.cTextSub,
                                fontFamily: 'monospace',
                              ),
                            ),
                            TextSpan(
                              text: '[${item.level.label}] ',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: levelColor,
                                fontFamily: 'monospace',
                              ),
                            ),
                            TextSpan(
                              text: '[${item.tag}] ',
                              style: TextStyle(
                                fontSize: 11,
                                color: context.cAccent,
                                fontFamily: 'monospace',
                              ),
                            ),
                            TextSpan(
                              text: item.message,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.cTextMain,
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (item.error != null)
                              TextSpan(
                                text: '\nError: ${item.error}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.cError,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            if (item.stackTrace != null)
                              TextSpan(
                                text: '\n${item.stackTrace}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: context.cTextSub,
                                  fontFamily: 'monospace',
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
