import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

/// 视频自定义名称持久化。
///
/// 按视频“文件完整路径”存储用户自定义名称。未自定义时返回文件名作为默认名。
/// 列表页与播放页共用，确保名称显示一致。
class VideoNameStore {
  static const String _key = 'video_display_names_v1';

  /// 变更通知：重命名后 +1，列表页/播放页可监听刷新。
  static final changed = ValueNotifier<int>(0);

  static Map<String, String> _cache = {};

  /// 加载缓存（首次访问时调用；也可在 main 中预加载）。
  static Future<void> _ensureLoaded() async {
    if (_cache.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _cache = map.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        _cache = {};
      }
    }
  }

  /// 获取某视频的显示名称：自定义优先，否则取文件名（不含扩展名）。
  static Future<String> getName(String filePath) async {
    await _ensureLoaded();
    final custom = _cache[filePath];
    if (custom != null && custom.isNotEmpty) return custom;
    return defaultName(filePath);
  }

  /// 批量获取（返回 path -> 名称）。用于列表页一次取全部。
  static Future<Map<String, String>> getAll(List<String> paths) async {
    await _ensureLoaded();
    final out = <String, String>{};
    for (final path in paths) {
      final custom = _cache[path];
      out[path] = (custom != null && custom.isNotEmpty)
          ? custom
          : defaultName(path);
    }
    return out;
  }

  /// 设置某视频的自定义名称并持久化；name 为空则回到默认文件名。
  static Future<void> setName(String filePath, String name) async {
    await _ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _cache.remove(filePath);
    } else {
      _cache[filePath] = trimmed;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_cache));
    changed.value++;
  }

  /// 由文件路径推导默认名称（文件名去扩展名）。
  static String defaultName(String filePath) {
    final base = p.basenameWithoutExtension(filePath);
    return base.isEmpty ? p.basename(filePath) : base;
  }
}
