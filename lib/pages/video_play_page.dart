import 'dart:async';
import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/local_video_model.dart';

/// 后台保活服务通道：开启后让进程以“前台服务”身份存活，
/// 息屏 / 切后台也不会被系统回收，音频得以继续（这是之前息屏就停的根本原因）。
const MethodChannel _bgChannel = MethodChannel('com.sleep.localvideoplayer/background');

Future<void> _startBgService() async {
  // 尽量申请通知权限，使前台服务通知可见（失败也不影响保活）
  try {
    await Permission.notification.request();
  } catch (_) {}
  try {
    await _bgChannel.invokeMethod<void>('start');
  } catch (_) {}
}

Future<void> _stopBgService() async {
  try {
    await _bgChannel.invokeMethod<void>('stop');
  } catch (_) {}
}

/// 上下滑动短视频播放页（任务 5 / 改造：自动隐藏面板 + 横屏按钮 + 后台播放保活）
class VideoPlayPage extends StatefulWidget {
  final List<LocalVideoModel> videos;
  final int initialIndex;

  const VideoPlayPage({
    required this.videos,
    required this.initialIndex,
    super.key,
  });

  @override
  State<VideoPlayPage> createState() => _VideoPlayPageState();
}

class _VideoPlayPageState extends State<VideoPlayPage> {
  late PageController _pageController;
  // 横屏状态在页面级统一管理：所有视频项共享，离开页面复位竖屏
  final ValueNotifier<bool> _landscape = ValueNotifier<bool>(false);
  // 后台播放开关（页面级，所有视频项共享）
  final ValueNotifier<bool> _backgroundPlay = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    // 强制全屏沉浸式（任务 5.1.1），进入页隐藏状态栏/导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _pageController = PageController(initialPage: widget.initialIndex);
    // 默认前台观看：保持屏幕常亮
    WakelockPlus.enable().catchError((_) {});
  }

  /// 切换横/竖屏
  void _toggleOrientation() {
    _landscape.value = !_landscape.value;
    if (_landscape.value) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  /// 切换后台播放。
  /// 关键修复：后台播放开启时必须保持 CPU 唤醒锁（PARTIAL_WAKE_LOCK）。
  /// 该锁只保持 CPU 唤醒、不保持屏幕 —— 屏幕照样会熄（省电），
  /// 但 CPU 不休眠才能让 ExoPlayer 持续解码，从而息屏/锁屏后声音继续。
  /// 之前错误地 disable 了它，导致息屏后 CPU 睡眠、解码停止、声音戛然而止。
  void _setBackgroundPlay(bool on) {
    _backgroundPlay.value = on;
    // 无论前后台，播放页都持有 CPU 唤醒锁；开关只控制前台服务启停。
    WakelockPlus.enable().catchError((_) {});
    if (on) {
      _startBgService();
    } else {
      _stopBgService();
    }
  }

  @override
  void dispose() {
    // 后台播放仍开启时，不在此处停服务/释放唤醒锁（由用户关闭“后台”开关来终止）；
    // 否则离开播放页会让 CPU 重新可休眠，息屏后音频又停。
    if (!_backgroundPlay.value) {
      _stopBgService();
      WakelockPlus.disable().catchError((_) {});
    }
    _pageController.dispose();
    // 离开页面：复位竖屏并恢复系统 UI（任务 5.1.1）
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _landscape.dispose();
    _backgroundPlay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 播放页忽略安全区以全屏铺满（任务 6.4）
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        child: PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical, // 垂直滚动，对标抖音（任务 5.1.2）
          itemCount: widget.videos.length,
          itemBuilder: (context, index) {
            // 懒加载：仅构建当前及相邻页面（任务 7 P1）
            return VideoPlayItem(
              model: widget.videos[index],
              landscape: _landscape,
              backgroundPlay: _backgroundPlay,
              onToggleOrientation: _toggleOrientation,
              onToggleBackground: _setBackgroundPlay,
            );
          },
        ),
      ),
    );
  }
}

/// 单个视频播放项（自动播放、切走销毁，任务 5.3）
class VideoPlayItem extends StatefulWidget {
  final LocalVideoModel model;
  final ValueNotifier<bool> landscape;
  final ValueNotifier<bool> backgroundPlay;
  final VoidCallback onToggleOrientation;
  final ValueChanged<bool> onToggleBackground;

  const VideoPlayItem({
    required this.model,
    required this.landscape,
    required this.backgroundPlay,
    required this.onToggleOrientation,
    required this.onToggleBackground,
    super.key,
  });

  @override
  State<VideoPlayItem> createState() => _VideoPlayItemState();
}

class _VideoPlayItemState extends State<VideoPlayItem> with WidgetsBindingObserver {
  late VideoPlayerController _vpc;
  ChewieController? _chewieController;
  bool _initialized = false;
  // 进入播放默认完全隐藏控制面板，用户点击屏幕才临时显示（任务：用户看不到的程度）
  bool _showControls = false;
  bool _isPlaying = true;
  Timer? _autoHideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 监听前后台切换（后台播放）
    // mixWithOthers=true → 关闭 ExoPlayer 的自动音频焦点管理（handleAudioFocus=false），
    // 息屏/锁屏后系统回收焦点时不再自动 pause，配合前台保活服务实现真正的后台续播。
    _vpc = VideoPlayerController.file(
      File(widget.model.filePath),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _vpc.addListener(_onVideoChanged);
    _vpc.initialize().then((_) {
      if (!mounted) return;
      // 使用 chewie 渲染（规范 G6 固定选型），关闭其自带控制条，用自定义面板
      _chewieController = ChewieController(
        videoPlayerController: _vpc,
        autoPlay: true,
        looping: false,
        showControls: false,
        aspectRatio: _vpc.value.aspectRatio.isFinite
            ? _vpc.value.aspectRatio
            : 16 / 9,
      );
      _vpc.play(); // 默认自动播放（任务 5.3.3）
      if (mounted) {
        setState(() {
          _initialized = true;
          _isPlaying = true;
          _showControls = false; // 进入即隐藏，不闪现控制面板
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _initialized = true);
    });
  }

  void _onVideoChanged() {
    // 仅在控制面板显示时刷新进度，避免无谓重建（性能）
    if (mounted && _showControls) setState(() {});
  }

  /// 播放中延时自动隐藏控制面板（2.5 秒）
  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  // ===== 定时关闭（睡眠定时） =====
  /// 选定的定时时长（分钟），null 表示未开启
  int? _sleepMinutes;
  int _sleepRemaining = 0; // 剩余秒数
  Timer? _sleepTimer;

  String _fmtSleep(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildTimerButton() {
    final active = _sleepMinutes != null;
    return TextButton.icon(
      onPressed: _pickSleepTimer,
      icon: Icon(Icons.timer, color: active ? Colors.amber : Colors.white, size: 20),
      label: Text(
        active ? _fmtSleep(_sleepRemaining) : '定时',
        style: TextStyle(color: active ? Colors.amber : Colors.white, fontSize: 12),
      ),
    );
  }

  Future<void> _pickSleepTimer() async {
    final choice = await showDialog<int?>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('定时关闭（到时自动停止）', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.grey[900],
        children: [
          SimpleDialogOption(
            child: const Text('关闭', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(context, null),
          ),
          for (final m in [15, 30, 45, 60, 75, 90, 105, 120])
            SimpleDialogOption(
              child: Text('$m 分钟', style: const TextStyle(color: Colors.white)),
              onPressed: () => Navigator.pop(context, m),
            ),
        ],
      ),
    );
    if (choice == null && _sleepMinutes == null) return;
    _setSleepTimer(choice);
  }

  void _setSleepTimer(int? minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes == null) {
      _sleepMinutes = null;
      _sleepRemaining = 0;
    } else {
      _sleepMinutes = minutes;
      _sleepRemaining = minutes * 60;
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        _sleepRemaining -= 1;
        if (_sleepRemaining <= 0) {
          t.cancel();
          _sleepTimer = null;
          _sleepMinutes = null;
          _sleepRemaining = 0;
          if (_vpc.value.isPlaying) {
            _vpc.pause();
            _isPlaying = false;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已到设定时间，已停止播放'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        if (mounted) setState(() {});
      });
    }
    setState(() {});
  }

  // ===== 后台播放按钮（读取页面级 notifier） =====
  Widget _buildBackgroundButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.backgroundPlay,
      builder: (_, bg, _) => TextButton.icon(
        onPressed: () => widget.onToggleBackground(!bg),
        icon: Icon(
          bg ? Icons.headset : Icons.headset_off,
          color: bg ? Colors.amber : Colors.white,
          size: 20,
        ),
        label: Text(
          bg ? '后台开' : '后台',
          style: TextStyle(color: bg ? Colors.amber : Colors.white, fontSize: 12),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台播放关闭：切后台/锁屏则暂停，避免离开后继续出声
    // 后台播放开启：不暂停，音频在后台/锁屏继续（配合前台保活服务）
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (widget.backgroundPlay.value) {
        // 后台播放：不暂停；并作为保底，确保进入后台后仍在播放（对抗任何意外暂停）
        if (_initialized && !_vpc.value.isPlaying) {
          _vpc.play();
          _isPlaying = true;
        }
      } else if (_vpc.value.isPlaying) {
        // 未开启后台播放：切后台/锁屏则暂停，避免离开后继续出声
        _vpc.pause();
        _isPlaying = false;
        if (mounted) setState(() {});
      }
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() => _isPlaying = _vpc.value.isPlaying);
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _sleepTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this); // 移除前后台监听
    _vpc.removeListener(_onVideoChanged);
    _chewieController?.dispose();
    _vpc.dispose(); // 切换/离开即销毁，释放内存（任务 5.3.2 / 任务 7 P2）
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && _isPlaying) {
      _scheduleAutoHide(); // 重新显示后重新计时隐藏
    } else {
      _autoHideTimer?.cancel();
    }
  }

  void _togglePlay() {
    if (_vpc.value.isPlaying) {
      _vpc.pause();
      _isPlaying = false;
      _autoHideTimer?.cancel(); // 暂停时保持面板可见
    } else {
      _vpc.play();
      _isPlaying = true;
      _scheduleAutoHide();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized || _chewieController == null) {
      return Container(
        color: Colors.black,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return GestureDetector(
      onTap: _toggleControls, // 单击切换控制面板（任务 5.4）
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 视频保持原始宽高比，空余区域纯黑（任务 5.3.1）
          Container(
            color: Colors.black,
            child: Chewie(controller: _chewieController!),
          ),
          if (_showControls) _buildControls(),
        ],
      ),
    );
  }

  /// 自定义控制面板（任务 5.4）
  Widget _buildControls() {
    final pos = _vpc.value.position;
    final dur = _vpc.value.duration;
    final maxSec = dur.inSeconds.toDouble();
    final posSec = pos.inSeconds.toDouble().clamp(0.0, maxSec).toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        // 左上角返回箭头（任务 5.4）
        Positioned(
          top: 16,
          left: 8,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(), // 返回首页（pop，不堆叠）
          ),
        ),
        // 顶部右侧：定时关闭 / 后台播放 / 横屏切换（均置于播放页顶部）
        Positioned(
          top: 16,
          right: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTimerButton(),
              _buildBackgroundButton(),
              ValueListenableBuilder<bool>(
                valueListenable: widget.landscape,
                builder: (_, isLandscape, _) => IconButton(
                  icon: Icon(
                    isLandscape ? Icons.stay_current_portrait : Icons.stay_current_landscape,
                    color: Colors.white,
                  ),
                  onPressed: widget.onToggleOrientation,
                ),
              ),
            ],
          ),
        ),
        // 中央播放/暂停
        Positioned.fill(
          child: Center(
            child: IconButton(
              iconSize: 64,
              icon: Icon(
                _isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: Colors.white70,
              ),
              onPressed: _togglePlay,
            ),
          ),
        ),
        // 底部可拖拽进度条（任务 5.4）
        Positioned(
          left: 12,
          right: 12,
          bottom: 24,
          child: Row(
            children: [
              Text(_fmt(pos),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: posSec,
                  max: maxSec <= 0 ? 1 : maxSec,
                  onChanged: (v) =>
                      _vpc.seekTo(Duration(seconds: v.toInt())),
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                ),
              ),
              Text(_fmt(dur),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
