import 'dart:async';
import 'package:flutter/foundation.dart';

/// 全局睡眠定时器（定时关闭）。
/// 之所以放在全局而非单个播放页：用户在某一集设置了定时关闭后，
/// 下滑切换到另一集时该页面实例会被重建（状态丢失），定时关闭随之失效。
/// 全局单例保证：定时器跨视频切换持续生效，倒计时在所有页面都可见。
class SleepTimer {
  SleepTimer._();
  static final SleepTimer instance = SleepTimer._();

  /// 剩余秒数；null 表示未设置。
  final ValueNotifier<int?> remaining = ValueNotifier<int?>(null);

  /// 总时长（分钟），用于显示“X 分钟后关闭”等。
  int? totalMinutes;

  Timer? _timer;

  /// 由“当前激活的播放页”注册：定时器到期时暂停音视频。
  /// 仅激活页持有真正的暂停能力（同时暂停音频服务与静音画面）。
  VoidCallback? onExpire;

  bool get active => remaining.value != null && remaining.value! > 0;

  void start(int minutes) {
    cancel();
    totalMinutes = minutes;
    remaining.value = minutes * 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final cur = remaining.value;
      if (cur == null) return;
      final left = cur - 1;
      if (left <= 0) {
        remaining.value = null;
        _timer?.cancel();
        _timer = null;
        totalMinutes = null;
        // 通知当前激活页暂停（音视频一起停）
        final cb = onExpire;
        cb?.call();
      } else {
        remaining.value = left;
      }
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    remaining.value = null;
    totalMinutes = null;
  }
}
