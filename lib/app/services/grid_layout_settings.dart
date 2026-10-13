import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/responsive_utils.dart';

class GridLayoutSettings extends ChangeNotifier {
  GridLayoutSettings();
  static final instance = GridLayoutSettings();
  static const preferenceKey = 'video_grid_columns';
  int _columns = 0;
  int get columns => _columns;
  SharedPreferences? _preferences;
  Future<void> _writes = Future<void>.value();

  Future<void> init({SharedPreferences? preferences}) async {
    _preferences = preferences ?? await SharedPreferences.getInstance();
    final stored = _preferences!.getInt(preferenceKey) ?? 0;
    _columns = stored >= 0 && stored <= 6 ? stored : 0;
    notifyListeners();
  }

  int resolveColumns(double width) =>
      _columns == 0 ? ResponsiveLayout.gridColumnCount(width) : _columns;

  Future<void> setColumns(int columns) {
    if (columns < 0 || columns > 6) {
      throw ArgumentError.value(columns, 'columns');
    }
    if (_columns == columns) return _writes;
    _columns = columns;
    notifyListeners();
    // Serialize rapid selections so an older write cannot replace the last one.
    final operation = _writes.then((_) async {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.setInt(preferenceKey, columns);
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
