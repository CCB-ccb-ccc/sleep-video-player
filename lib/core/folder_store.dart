import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个视频文件夹条目：路径 + 用户自定义显示名（标签）。
class FolderEntry {
  final String path; // 文件夹完整路径
  final String label; // 用户自定义名称；为空时用文件夹名兜底

  FolderEntry({required this.path, required this.label});

  Map<String, dynamic> toJson() => {'path': path, 'label': label};

  factory FolderEntry.fromJson(Map<String, dynamic> j) => FolderEntry(
        path: j['path'] as String,
        label: (j['label'] as String?) ?? '',
      );
}

/// 用户选中的视频文件夹持久化与变更通知
///
/// 取代原先「全盘遍历 /storage」的方案：用户自行指定一个或多个文件夹，
/// 播放页只展示这些文件夹（含子目录）里的视频。
/// 每个文件夹可设置自定义名称，用于播放页顶部切换栏的按钮文案。
class FolderStore {
  static const String _keyV2 = 'selected_folders_v2';
  static const String _keyV1 = 'selected_folders'; // 兼容旧版仅存路径

  /// 变更计数通知：设置页增删/改名文件夹后 +1，播放列表页监听后自动刷新。
  static final changed = ValueNotifier<int>(0);

  /// 读取带标签的文件夹条目（自动迁移旧版路径列表）。
  static Future<List<FolderEntry>> getEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyV2);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => FolderEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        return list;
      } catch (_) {
        // 数据损坏则走下方迁移兜底
      }
    }
    // 迁移：旧版只存了路径字符串列表
    final old = prefs.getStringList(_keyV1) ?? [];
    return old
        .map((p) => FolderEntry(path: p, label: defaultLabel(p)))
        .toList();
  }

  /// 供扫描工具使用的纯路径列表（保持旧接口不变）。
  static Future<List<String>> getFolders() async {
    final entries = await getEntries();
    return entries.map((e) => e.path).toList();
  }

  /// 保存带标签的文件夹条目并广播变更。
  static Future<void> saveEntries(List<FolderEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyV2, jsonEncode(entries.map((e) => e.toJson()).toList()));
    changed.value++;
  }

  /// 由路径推导默认显示名（取最后一段目录名）。
  static String defaultLabel(String path) {
    final segs = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
    return segs.isEmpty ? path : segs.last;
  }
}
