import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局应用设置（持久化 + 全局可访问）。
///
/// 后台播放开关与播放模式都放在这里，由「设置页」修改、由「播放页」读取，
/// 并用 ValueNotifier 暴露，确保跨页面实时同步。
class AppSettings {
  static const String _keyBackgroundPlay = 'background_play_enabled';
  static const String _keyPlayMode = 'play_mode'; // manual / sequence / loopOne

  // 单例，方便全局访问。
  static final AppSettings instance = AppSettings._();

  AppSettings._();

  bool _backgroundPlay = false;
  PlayMode _playMode = PlayMode.manual;

  /// 是否已加载持久化数据。
  bool _loaded = false;

  /// 后台播放开关（用户开启后持久生效，跨应用重启仍有效）。
  bool get backgroundPlay => _backgroundPlay;

  /// 播放模式：手动 / 顺序播放 / 单集循环。
  PlayMode get playMode => _playMode;

  /// 后台播放开关变更通知（设置页切换时，播放页可监听）。
  final ValueNotifier<bool> backgroundPlayNotifier = ValueNotifier<bool>(false);

  /// 播放模式变更通知。
  final ValueNotifier<PlayMode> playModeNotifier =
      ValueNotifier<PlayMode>(PlayMode.manual);

  /// 异步加载持久化数据（main 启动时调用一次）。
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _backgroundPlay = prefs.getBool(_keyBackgroundPlay) ?? false;
    final modeStr = prefs.getString(_keyPlayMode);
    _playMode = PlayMode.fromString(modeStr);
    backgroundPlayNotifier.value = _backgroundPlay;
    playModeNotifier.value = _playMode;
    _loaded = true;
  }

  /// 设置后台播放开关并持久化。
  Future<void> setBackgroundPlay(bool on) async {
    if (_backgroundPlay == on) return;
    _backgroundPlay = on;
    backgroundPlayNotifier.value = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBackgroundPlay, on);
  }

  /// 设置播放模式并持久化。
  Future<void> setPlayMode(PlayMode mode) async {
    if (_playMode == mode) return;
    _playMode = mode;
    playModeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPlayMode, mode.name);
  }
}

/// 播放模式枚举。
enum PlayMode {
  /// 手动：看完一个不自动播下一个。
  manual,

  /// 顺序播放：看完当前自动播下一个，到末尾停止。
  sequence,

  /// 单集循环：看完当前重新从头播放本集。
  loopOne;

  static PlayMode fromString(String? s) {
    switch (s) {
      case 'sequence':
        return PlayMode.sequence;
      case 'loopOne':
        return PlayMode.loopOne;
      case 'manual':
      default:
        return PlayMode.manual;
    }
  }

  String get label {
    switch (this) {
      case PlayMode.sequence:
        return '顺序播放';
      case PlayMode.loopOne:
        return '单集循环';
      case PlayMode.manual:
      default:
        return '手动播放';
    }
  }
}
