import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR');

  const LogLevel(this.label);
  final String label;
}

class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final String? error;
  final String? stackTrace;

  String format() {
    final timestamp = time.toLocal().toIso8601String().replaceFirst('T', ' ');
    final errStr = error == null ? '' : '\nError: $error';
    final stackStr = stackTrace == null ? '' : '\n$stackTrace';
    return '[$timestamp][${level.label}][$tag] $message$errStr$stackStr';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'time': time.toIso8601String(),
    'level': level.name,
    'tag': tag,
    'message': message,
    'error': error,
    'stackTrace': stackTrace,
  };

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    final levelName = json['level'] as String?;
    return LogEntry(
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      level: LogLevel.values.firstWhere(
        (value) => value.name == levelName,
        orElse: () => LogLevel.info,
      ),
      tag: json['tag'] as String? ?? 'App',
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
      stackTrace: json['stackTrace'] as String?,
    );
  }
}

/// In-memory diagnostics for the log viewer, backed by a small rotating file
/// so the previous run is still available after an app restart.
class AppLogger {
  AppLogger._();

  static const int _maxLogs = 500;
  static const int _maxFileBytes = 2 * 1024 * 1024;
  static final DoubleLinkedQueue<LogEntry> _history =
      DoubleLinkedQueue<LogEntry>();
  static final ValueNotifier<int> logCountNotifier = ValueNotifier<int>(0);

  static File? _logFile;
  static Future<void> _persistQueue = Future<void>.value();
  static bool _initialized = false;

  static final RegExp _emailPattern = RegExp(
    r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
    caseSensitive: false,
  );
  static final RegExp _querySecretPattern = RegExp(
    r'((?:[?&]|\b)(?:secure|token|access_token|refresh_token|auth|csrf|session|key)=)[^&#\s]+',
    caseSensitive: false,
  );
  static final RegExp _credentialFieldPattern = RegExp(
    r"""\b(cookie|set-cookie|authorization|password|passwd|pwd)\b["']?\s*[:=]\s*["']?[^\r\n,"'}]+""",
    caseSensitive: false,
  );

  static List<LogEntry> get logs => _history.toList(growable: false);

  /// Load recent entries from the previous run before normal app startup.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}application.log.jsonl',
      );
      await file.parent.create(recursive: true);
      _logFile = file;
      if (!await file.exists()) return;

      final lines = await file.readAsLines();
      for (final line in lines.skip(
        (lines.length - _maxLogs).clamp(0, lines.length),
      )) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            _addToHistory(LogEntry.fromJson(decoded));
          }
        } catch (_) {
          // A torn final line after an abrupt shutdown should not hide older logs.
        }
      }
      logCountNotifier.value++;
    } catch (error) {
      _logFile = null;
      debugPrint('[AppLogger] Persistent logging unavailable: $error');
    }
  }

  static void d(String tag, String message) =>
      _log(LogLevel.debug, tag, message);
  static void i(String tag, String message) =>
      _log(LogLevel.info, tag, message);
  static void w(String tag, String message, [dynamic error]) =>
      _log(LogLevel.warn, tag, message, error);
  static void e(
    String tag,
    String message, [
    dynamic error,
    StackTrace? stack,
  ]) => _log(LogLevel.error, tag, message, error, stack);

  static void _log(
    LogLevel level,
    String tag,
    String message, [
    dynamic error,
    StackTrace? stack,
  ]) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: _sanitize(tag),
      message: _sanitize(message),
      error: error == null ? null : _sanitize(error.toString()),
      stackTrace: stack == null ? null : _sanitize(stack.toString()),
    );

    _addToHistory(entry);
    logCountNotifier.value++;
    _persist(entry);

    // Keep Android logcat capture and the in-app viewer consistent.
    // ignore: avoid_print
    print('[91DL] ${entry.format()}');
    debugPrint('[91DL]${entry.format()}');
  }

  static String _sanitize(String value) => value
      .replaceAllMapped(
        _credentialFieldPattern,
        (match) => '${match[1]}=[redacted]',
      )
      .replaceAllMapped(_querySecretPattern, (match) => '${match[1]}[redacted]')
      .replaceAll(_emailPattern, '[email]');

  static void _addToHistory(LogEntry entry) {
    _history.addLast(entry);
    while (_history.length > _maxLogs) {
      _history.removeFirst();
    }
  }

  static void _persist(LogEntry entry) {
    final file = _logFile;
    if (file == null) return;
    final line = '${jsonEncode(entry.toJson())}\n';
    _persistQueue = _persistQueue
        .then((_) async {
          await file.writeAsString(line, mode: FileMode.append);
          if (await file.length() > _maxFileBytes) await _trimFile(file);
        })
        .catchError((Object error, StackTrace stack) {
          debugPrint('[AppLogger] Could not persist log: $error');
        });
  }

  static Future<void> _trimFile(File file) async {
    final lines = await file.readAsLines();
    final keepFrom = lines.length ~/ 2;
    final retained = lines.skip(keepFrom).join('\n');
    await file.writeAsString(retained.isEmpty ? '' : '$retained\n');
  }

  static void clear() {
    _history.clear();
    logCountNotifier.value++;
    final file = _logFile;
    if (file == null) return;
    _persistQueue = _persistQueue
        .then((_) async {
          if (await file.exists()) await file.writeAsString('');
        })
        .catchError((Object error, StackTrace stack) {
          debugPrint('[AppLogger] Could not clear persisted logs: $error');
        });
  }

  static String exportAll() =>
      _history.map((entry) => entry.format()).join('\n');
}
