// 轻量诊断日志：记录后台播放链路关键事件，供用户在播放页「状态」浮层查看并截图，
// 以定位荣耀/华为“前台有声、息屏断声”的真正原因。
//
// 可能根因：
//  A. 荣耀/华为息屏后杀掉整个 App 进程（含媒体服务）→ 进程被杀类。
//  B. audio_service 媒体服务未真正以“前台服务”常驻（息屏即被回收）→ 服务未起类。
//  C. 用户未把 App 设为“电池不受限制 / 受保护应用”→ 白名单未设类。
// 诊断浮层会把 init/handler/音频播放/息屏前后等关键状态都打出来，便于区分。
final List<String> kDiagLog = <String>[];

void diag(String msg) {
  final t = DateTime.now().toIso8601String().substring(11, 19);
  kDiagLog.add('$t $msg');
  if (kDiagLog.length > 400) kDiagLog.removeAt(0);
  // 同时打到控制台，便于 CI/本地抓日志
  // ignore: avoid_print
  print('[DIAG] $t $msg');
}
