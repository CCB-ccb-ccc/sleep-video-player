import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户选中的视频文件夹持久化与变更通知
///
/// 取代原先「全盘遍历 /storage」的方案：用户自行指定一个或多个文件夹，
/// 播放页只展示这些文件夹（含子目录）里的视频。
class FolderStore {
  static const String _key = 'selected_folders';

  /// 变更计数通知：设置页增删文件夹后 +1，播放列表页监听后自动重新扫描。
  static final changed = ValueNotifier<int>(0);

  /// 读取已保存的文件夹列表（持久化在应用私有 SharedPreferences 中）。
  static Future<List<String>> getFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }

  /// 保存文件夹列表并广播变更。
  static Future<void> saveFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, folders);
    changed.value++;
  }
}
