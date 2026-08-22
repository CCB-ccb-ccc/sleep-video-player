import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单集观看进度。
class EpisodeProgress {
  final int positionMs; // 已播放到的位置（毫秒）
  final int durationMs; // 视频总时长（毫秒，可能暂未知为 0）
  final bool completed; // 是否看完
  final int updatedAtMs; // 最后更新时间戳

  EpisodeProgress({
    required this.positionMs,
    required this.durationMs,
    required this.completed,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'positionMs': positionMs,
        'durationMs': durationMs,
        'completed': completed,
        'updatedAtMs': updatedAtMs,
      };

  factory EpisodeProgress.fromJson(Map<String, dynamic> j) => EpisodeProgress(
        positionMs: j['positionMs'] as int? ?? 0,
        durationMs: j['durationMs'] as int? ?? 0,
        completed: j['completed'] as bool? ?? false,
        updatedAtMs: j['updatedAtMs'] as int? ?? 0,
      );
}

/// 上次观看的剧集位置（用于追剧页「快速续播」弹窗）。
class LastWatched {
  final String seriesPath;
  final String seriesName;
  final String seasonPath;
  final String seasonName;
  final String episodePath;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  LastWatched({
    required this.seriesPath,
    required this.seriesName,
    required this.seasonPath,
    required this.seasonName,
    required this.episodePath,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'seriesPath': seriesPath,
        'seriesName': seriesName,
        'seasonPath': seasonPath,
        'seasonName': seasonName,
        'episodePath': episodePath,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAtMs': updatedAtMs,
      };

  factory LastWatched.fromJson(Map<String, dynamic> j) => LastWatched(
        seriesPath: j['seriesPath'] as String? ?? '',
        seriesName: j['seriesName'] as String? ?? '',
        seasonPath: j['seasonPath'] as String? ?? '',
        seasonName: j['seasonName'] as String? ?? '',
        episodePath: j['episodePath'] as String? ?? '',
        episodeIndex: j['episodeIndex'] as int? ?? 0,
        positionMs: j['positionMs'] as int? ?? 0,
        durationMs: j['durationMs'] as int? ?? 0,
        updatedAtMs: j['updatedAtMs'] as int? ?? 0,
      );
}

/// 追剧模块的历史记录持久化：
///  - 每集观看进度（用于进度条 / 已看完打勾）；
///  - 上次观看位置（用于快速续播）。
class SeriesHistoryStore {
  static const String _keyLast = 'series_last_watched_v1';
  static const String _keyProgress = 'series_episode_progress_v1';

  /// 变更通知（集进度 / 上次观看变化后 +1）。
  static final changed = ValueNotifier<int>(0);

  static Map<String, EpisodeProgress> _progressCache = {};
  static LastWatched? _lastWatched;

  // ===== 上次观看 =====

  static Future<LastWatched?> getLastWatched() async {
    if (_lastWatched != null) return _lastWatched;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyLast);
    if (raw != null && raw.isNotEmpty) {
      try {
        _lastWatched = LastWatched.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        _lastWatched = null;
      }
    }
    return _lastWatched;
  }

  static Future<void> saveLastWatched({
    required String seriesPath,
    required String seriesName,
    required String seasonPath,
    required String seasonName,
    required String episodePath,
    required int episodeIndex,
    required Duration position,
    required Duration duration,
  }) async {
    _lastWatched = LastWatched(
      seriesPath: seriesPath,
      seriesName: seriesName,
      seasonPath: seasonPath,
      seasonName: seasonName,
      episodePath: episodePath,
      episodeIndex: episodeIndex,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLast, jsonEncode(_lastWatched!.toJson()));
    changed.value++;
  }

  // ===== 单集进度 =====

  static Future<void> _ensureProgressLoaded() async {
    if (_progressCache.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyProgress);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _progressCache = map.map(
            (k, v) => MapEntry(k, EpisodeProgress.fromJson(v as Map<String, dynamic>)));
      } catch (_) {
        _progressCache = {};
      }
    }
  }

  static Future<EpisodeProgress?> getProgress(String path) async {
    await _ensureProgressLoaded();
    return _progressCache[path];
  }

  /// 批量获取（供集列表一次取全部）。
  static Future<Map<String, EpisodeProgress>> getAllProgress() async {
    await _ensureProgressLoaded();
    return Map.from(_progressCache);
  }

  /// 写入单集进度（[completed]=true 表示已看完）。
  static Future<void> saveProgress(
    String path,
    Duration position,
    Duration duration, {
    bool completed = false,
  }) async {
    await _ensureProgressLoaded();
    _progressCache[path] = EpisodeProgress(
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      completed: completed,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProgress,
        jsonEncode(_progressCache.map((k, v) => MapEntry(k, v.toJson()))));
    changed.value++;
  }

  /// 清空全部历史（可选：用户手动清理）。
  static Future<void> clearAll() async {
    _progressCache = {};
    _lastWatched = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyProgress);
    await prefs.remove(_keyLast);
    changed.value++;
  }
}
