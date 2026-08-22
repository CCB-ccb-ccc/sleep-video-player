import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'folder_store.dart';

/// 追剧页的「剧」条目（与「播放」页的文件夹互相独立，用户单独选择）。
class SeriesEntry {
  final String path; // 剧（大文件夹）完整路径
  final String label; // 用户自定义剧名；为空时用文件夹名兜底

  SeriesEntry({required this.path, required this.label});

  Map<String, dynamic> toJson() => {'path': path, 'label': label};

  factory SeriesEntry.fromJson(Map<String, dynamic> j) => SeriesEntry(
        path: j['path'] as String,
        label: (j['label'] as String?) ?? '',
      );
}

/// 追剧模块的持久化：用户添加的「剧」列表 + 各季的自定义名称。
///
/// 与 FolderStore 解耦：追剧的文件夹选择独立于「播放」页的设置，避免相互干扰。
class SeriesStore {
  static const String _keySeries = 'series_entries_v1';
  static const String _keySeasonLabels = 'series_season_labels_v1';

  /// 变更通知：增删/改名剧或季后 +1，追剧页监听后自动刷新。
  static final changed = ValueNotifier<int>(0);

  static Map<String, String> _seasonLabels = {};

  /// 读取所有剧条目。
  static Future<List<SeriesEntry>> getEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySeries);
    if (raw != null && raw.isNotEmpty) {
      try {
        return (jsonDecode(raw) as List)
            .map((e) => SeriesEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        // 数据损坏则回退空
      }
    }
    return [];
  }

  static Future<void> _saveEntries(List<SeriesEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keySeries, jsonEncode(entries.map((e) => e.toJson()).toList()));
    changed.value++;
  }

  /// 添加一部剧（路径去重）。
  static Future<void> addSeries(String path) async {
    final entries = await getEntries();
    if (entries.any((e) => e.path == path)) return;
    entries.add(SeriesEntry(path: path, label: defaultLabel(path)));
    await _saveEntries(entries);
  }

  /// 移除一部剧（仅移除记录，不删除用户硬盘上的文件）。
  static Future<void> removeSeries(String path) async {
    final entries = await getEntries();
    entries.removeWhere((e) => e.path == path);
    await _saveEntries(entries);
  }

  /// 重命名一部剧。
  static Future<void> renameSeries(String path, String label) async {
    final entries = await getEntries();
    final next = entries
        .map((e) =>
            e.path == path ? SeriesEntry(path: e.path, label: label) : e)
        .toList();
    await _saveEntries(next);
  }

  static String defaultLabel(String path) => FolderStore.defaultLabel(path);

  // ===== 季（子文件夹）自定义名称 =====

  static Future<void> _ensureSeasonLabels() async {
    if (_seasonLabels.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySeasonLabels);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _seasonLabels = map.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        _seasonLabels = {};
      }
    }
  }

  /// 获取某季的自定义名称（为空表示未自定义，应使用文件夹名）。
  static Future<String> getSeasonLabel(String seasonPath) async {
    await _ensureSeasonLabels();
    return _seasonLabels[seasonPath] ?? '';
  }

  /// 设置某季的自定义名称（空字符串表示恢复为文件夹名）。
  static Future<void> setSeasonLabel(String seasonPath, String label) async {
    await _ensureSeasonLabels();
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      _seasonLabels.remove(seasonPath);
    } else {
      _seasonLabels[seasonPath] = trimmed;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySeasonLabels, jsonEncode(_seasonLabels));
    changed.value++;
  }
}
