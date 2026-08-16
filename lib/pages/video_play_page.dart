import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent_plus.dart';
import 'package:audio_service/audio_service.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_player_handler.dart';
import '../models/local_video_model.dart';
import '../debug/diag.dart';

/// 播放页容器：底部竖向滑动切换视频（抖音式）。
/// 页面级统一管理：横屏、后台播放开关、当前激活序号。
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
  // 当前激活（可见）的视频序号：只有激活项驱动音频服务，避免相邻预载项抢占音频
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _pageController = PageController(initialPage: widget.initialIndex);
    _activeIndex.value = widget.initialIndex;
    // 前台观看默认保持屏幕常亮
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

  /// 切换后台播放：仅改变开关值。
  /// 真正的“息屏续播”由音频服务（audio_service）保障，不再依赖自定义前台服务/唤醒锁
  /// —— 那是之前 4 个版本在华为上失败的根因（video_player 绑定 Activity，息屏即被回收）。
  void _setBackgroundPlay(bool on) {
    _backgroundPlay.value = on;
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    _pageController.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _landscape.dispose();
    _backgroundPlay.dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        child: PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          itemCount: widget.videos.length,
          onPageChanged: (i) => _activeIndex.value = i,
          itemBuilder: (context, index) {
            return VideoPlayItem(
              model: widget.videos[index],
              index: index,
              activeIndex: _activeIndex,
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

/// 单个视频播放项。
///
/// 设计：video_player 仅渲染“静音画面”，声音统一由音频服务（just_audio）播放。
/// 这样：前台看得到视频画面、听得到声音；息屏/切后台时，Activity 被回收也不影响音频服务，
/// 声音由媒体服务继续播放（系统级通道，华为等激进省电机型也会尊重）。
class VideoPlayItem extends StatefulWidget {
  final LocalVideoModel model;
  final int index;
  final ValueNotifier<int> activeIndex;
  final ValueNotifier<bool> landscape;
  final ValueNotifier<bool> backgroundPlay;
  final VoidCallback onToggleOrientation;
  final ValueChanged<bool> onToggleBackground;

  const VideoPlayItem({
    required this.model,
    required this.index,
    required this.activeIndex,
    required this.landscape,
    required this.backgroundPlay,
    required this.onToggleOrientation,
    required this.onToggleBackground,
    super.key,
  });

  @override
  State<VideoPlayItem> createState() => _VideoPlayItemState();
}

class _VideoPlayItemState extends State<VideoPlayItem>
    with WidgetsBindingObserver {
  late VideoPlayerController _vpc;
  ChewieController? _chewieController;
  bool _initialized = false;
  bool _audioReady = false; // 音频服务是否已加载本文件
  // 进入播放默认完全隐藏控制面板，用户点击屏幕才临时显示
  bool _showControls = false;
  bool _isPlaying = true;
  bool _playbackIntended = true; // 用户是否希望播放（暂停/定时关闭会置否）
  Timer? _autoHideTimer;
  Timer? _sleepTimer;
  Timer? _syncTimer; // 静音画面与音频进度对齐
  AudioPlayerHandler? _handler;

  bool get _isActive => widget.activeIndex.value == widget.index;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 音频服务在 main 中“异步”初始化（为防开屏卡死），这里先取当前值；
    // 若尚未就绪，globalAudioHandler 的 listener 会在其就绪后自动接管，
    // 避免“启动顺序竞争”导致一直拿不到 handler 而彻底没声音。
    _handler = globalAudioHandler.value;
    globalAudioHandler.addListener(_onHandlerReady);

    _vpc = VideoPlayerController.file(File(widget.model.filePath));
    _vpc.addListener(_onVideoChanged);
    _vpc.initialize().then((_) {
      if (!mounted) return;
      _vpc.setVolume(0); // 视频仅作画面，声音统一由音频服务播放
      _chewieController = ChewieController(
        videoPlayerController: _vpc,
        autoPlay: false,
        looping: false,
        showControls: false,
        aspectRatio: _vpc.value.aspectRatio.isFinite
            ? _vpc.value.aspectRatio
            : 16 / 9,
      );
      if (mounted) setState(() => _initialized = true);
      // 若本项已是激活项，则开始播放（音频 + 静音视频）
      if (_isActive) _activate();
    }).catchError((_) {
      if (mounted) setState(() => _initialized = true);
    });

    widget.activeIndex.addListener(_onActiveChanged);
    // 每 500ms 把静音画面seek到音频进度，保持画面与声音同步
    _syncTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _syncVideo());
  }

  void _onActiveChanged() {
    if (_isActive) {
      _activate();
    } else {
      _deactivate();
    }
  }

  /// 音频服务初始化完成（或失败置 null）后触发：若本项激活且尚未用上音频服务，
  /// 立即接管，避免因为“启动顺序竞争”导致一直拿不到 handler 而彻底没声音。
  void _onHandlerReady() {
    final h = globalAudioHandler.value;
    _handler = h;
    if (h != null && _isActive && _initialized) {
      _activate();
    }
  }

  /// 成为激活项：加载音频到音频服务并开始播放（视频静音同步）。
  /// 若音频服务尚未就绪/失败：退化用视频播放器自身出声（仅前台可用），
  /// 绝不再因为拿不到 handler 就“彻底静音”。
  Future<void> _activate() async {
    if (!_initialized) return;
    diag('activate: isActive=$_isActive');
    // 每次都重新读取最新 handler（它可能在 init 完成后才就绪）
    final handler = globalAudioHandler.value;
    _handler = handler;
    if (handler == null) {
      // 退化路径：直接用 video_player 出声（前台可用，后台不续播）
      diag('activate: handler=null -> 退化 video 出声(仅前台)');
      _audioReady = false;
      _vpc.setVolume(1);
      if (_playbackIntended && _vpc.value.isInitialized) _vpc.play();
      if (mounted) {
        setState(() {
          _isPlaying = _playbackIntended;
          _showControls = false;
        });
      }
      return;
    }
    try {
      await handler.loadFile(widget.model.filePath);
      _audioReady = true;
      _vpc.setVolume(0); // 正常：声音走音频服务
      diag('activate: 音频服务加载成功, 走音频路径');
    } catch (_) {
      // 兜底：音频服务加载失败，则直接用视频播放器出声（仅前台可用）
      diag('activate: 音频加载失败 -> 退化 video 出声');
      _audioReady = false;
      _vpc.setVolume(1);
    }
    if (!mounted) return;
    if (_playbackIntended) {
      if (_audioReady) handler.player.play();
      if (_vpc.value.isInitialized) _vpc.play();
    }
    if (mounted) {
      setState(() {
        _isPlaying = _playbackIntended;
        _showControls = false; // 进入即隐藏，不闪现控制面板
      });
    }
  }

  /// 离开激活：暂停本项视频解码（音频由新的激活项接管）
  void _deactivate() {
    if (_vpc.value.isInitialized) _vpc.pause();
  }

  void _onVideoChanged() {
    if (mounted && _showControls) setState(() {});
  }

  /// 当前播放位置/时长：优先取音频服务（正常路径），兜底取 video_player。
  Duration _curPos() {
    if (_audioReady && _handler != null) return _handler!.player.position;
    return _vpc.value.isInitialized ? _vpc.value.position : Duration.zero;
  }

  Duration _curDur() {
    if (_audioReady && _handler != null) {
      return _handler!.player.duration ?? Duration.zero;
    }
    return _vpc.value.isInitialized ? _vpc.value.duration : Duration.zero;
  }

  Future<void> _seekTo(Duration d) async {
    if (_audioReady && _handler != null) await _handler!.player.seek(d);
    if (_vpc.value.isInitialized) _vpc.seekTo(d);
  }

  /// 静音画面跟随音频进度（允许 400ms 偏差，避免频繁 seek）
  void _syncVideo() {
    if (!_isActive || !_initialized || _handler == null) return;
    if (!_handler!.player.playing) return;
    final ap = _handler!.player.position;
    final vp = _vpc.value.position;
    if ((ap - vp).abs() > const Duration(milliseconds: 400)) {
      _vpc.seekTo(ap);
    }
  }

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  // ===== 定时关闭（睡眠定时） =====
  int? _sleepMinutes;
  int _sleepRemaining = 0;
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
          _pauseAll();
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
        onPressed: () {
          final willOn = !bg;
          widget.onToggleBackground(willOn);
          if (willOn && mounted) {
            diag('后台播放开关=开');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                duration: Duration(seconds: 6),
                content: Text(
                  '已开启后台播放。若息屏仍断声，请点右上角「续航」把本App设为“电池不受限制”，'
                  '荣耀/华为会杀掉未设白名单的后台媒体服务。',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            );
          }
        },
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

  /// 一键跳转系统电池/应用设置，引导用户把本 App 设为“电池不受限制 / 受保护应用”，
  /// 这是荣耀/华为息屏后不杀后台媒体的决定性步骤。
  Future<void> _openBatterySettings() async {
    const intent = AndroidIntent(
      action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      data: 'package:com.sleep.localvideoplayer',
    );
    try {
      await intent.launch();
      diag('openBatterySettings: 跳转电池优化豁免页');
    } catch (e) {
      // 部分机型无此 action，退回应用详情页
      const intent2 = AndroidIntent(
        action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
        data: 'package:com.sleep.localvideoplayer',
      );
      try {
        await intent2.launch();
        diag('openBatterySettings: 跳转应用详情页');
      } catch (e2) {
        diag('openBatterySettings FAIL: $e2');
      }
    }
  }

  /// 诊断状态浮层：把后台播放链路关键事件打出来，方便用户截图定位“息屏断声”根因。
  Widget _buildStatusButton() {
    return TextButton.icon(
      onPressed: () => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('诊断状态', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.grey[900],
          content: SizedBox(
            width: double.maxFinite,
            height: 340,
            child: SingleChildScrollView(
              child: Text(
                kDiagLog.isEmpty ? '（暂无记录）' : kDiagLog.join('\n'),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
      icon: const Icon(Icons.bug_report, color: Colors.white, size: 20),
      label: const Text('状态', style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  /// 续航设置按钮：一键跳转电池白名单设置。
  Widget _buildSettingsButton() {
    return TextButton.icon(
      onPressed: _openBatterySettings,
      icon: const Icon(Icons.battery_charging_full, color: Colors.white, size: 20),
      label: const Text('续航', style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  // ===== 播放/暂停：控制音频服务（声音）+ 静音视频 =====
  Future<void> _pauseAll() async {
    await _handler?.player.pause();
    if (_vpc.value.isInitialized) _vpc.pause();
    _isPlaying = false;
    _playbackIntended = false;
  }

  Future<void> _playAll() async {
    if (_audioReady && _handler != null) await _handler!.player.play();
    if (_vpc.value.isInitialized) _vpc.play();
    _isPlaying = true;
    _playbackIntended = true;
  }

  void _togglePlay() {
    if (_isPlaying) {
      _pauseAll();
      _autoHideTimer?.cancel();
    } else {
      _playAll();
      _scheduleAutoHide();
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final audioPlaying =
        _audioReady && _handler != null && _handler!.player.playing;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      diag('lifecycle=离开前台($state) 后台开关=${widget.backgroundPlay.value} '
          'audioPlayingBefore=$audioPlaying');
      // 离开前台：释放屏幕唤醒锁，允许息屏
      WakelockPlus.disable().catchError((_) {});
      if (widget.backgroundPlay.value) {
        // 后台播放开启：音频服务（媒体服务）继续出声；仅暂停本项视频解码省电
        if (_vpc.value.isInitialized) _vpc.pause();
      } else {
        // 未开启：离开即整体暂停
        _pauseAll();
      }
    } else if (state == AppLifecycleState.resumed) {
      diag('lifecycle=resumed 回前台 audioPlayingAfter=$audioPlaying');
      // 回到前台：恢复常亮 + 视频画面
      WakelockPlus.enable().catchError((_) {});
      if (widget.backgroundPlay.value) {
        if (_vpc.value.isInitialized) _vpc.play(); // 静音视频继续显示
        // 音频服务在后台模式一直播放，无需处理
      } else {
        if (_playbackIntended) {
          if (_audioReady && _handler != null) _handler!.player.play();
          if (_vpc.value.isInitialized) _vpc.play();
          _isPlaying = true;
        }
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _sleepTimer?.cancel();
    _syncTimer?.cancel();
    globalAudioHandler.removeListener(_onHandlerReady);
    widget.activeIndex.removeListener(_onActiveChanged);
    WidgetsBinding.instance.removeObserver(this);
    _vpc.removeListener(_onVideoChanged);
    _chewieController?.dispose();
    _vpc.dispose();
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && _isPlaying) {
      _scheduleAutoHide();
    } else {
      _autoHideTimer?.cancel();
    }
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
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.black,
            child: Chewie(controller: _chewieController!),
          ),
          if (_showControls) _buildControls(),
        ],
      ),
    );
  }

  /// 自定义控制面板（顶部按钮 + 中央播放/暂停 + 底部进度条）
  Widget _buildControls() {
    final pos = _curPos();
    final dur = _curDur();
    final maxSec = dur.inSeconds.toDouble();
    final posSec = pos.inSeconds.toDouble().clamp(0.0, maxSec);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 16,
          left: 8,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
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
          _buildStatusButton(),
          _buildBackgroundButton(),
          _buildSettingsButton(),
          ValueListenableBuilder<bool>(
            valueListenable: widget.landscape,
                builder: (_, isLandscape, _) => IconButton(
                  icon: Icon(
                    isLandscape
                        ? Icons.stay_current_portrait
                        : Icons.stay_current_landscape,
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
        // 底部可拖拽进度条
        Positioned(
          left: 12,
          right: 12,
          bottom: 24,
          child: Row(
            children: [
              Text(_fmt(pos), style: const TextStyle(color: Colors.white, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: posSec,
                  max: maxSec <= 0 ? 1 : maxSec,
                  onChanged: (v) async {
                    await _seekTo(Duration(seconds: v.toInt()));
                  },
                  activeColor: Colors.white,
                  inactiveColor: Colors.white30,
                ),
              ),
              Text(_fmt(dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
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
