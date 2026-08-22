import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:audio_service/audio_service.dart' hide ProcessingState;
import 'package:just_audio/just_audio.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_player_handler.dart';
import '../core/app_settings.dart';
import '../core/series_history_store.dart';
import '../core/sleep_timer.dart';
import '../core/video_name_store.dart';
import '../debug/diag.dart';
import '../models/local_video_model.dart';
import '../models/series_resume.dart';

/// 播放页容器：底部竖向滑动切换视频（抖音式）。
/// 页面级统一管理：横屏、当前激活序号、全局后台开关（来自设置）。
class VideoPlayPage extends StatefulWidget {
  final List<LocalVideoModel> videos;
  final int initialIndex;
  /// 续播起始位置（追剧页「快速续播」/ 单集断点用），为 null 表示从 0 开始。
  final Duration? resumePosition;
  /// 追剧播放上下文（来自追剧页）。非 null 时播放页会把进度写回 SeriesHistoryStore。
  final SeriesPlayContext? seriesContext;

  const VideoPlayPage({
    required this.videos,
    required this.initialIndex,
    this.resumePosition,
    this.seriesContext,
    super.key,
  });

  @override
  State<VideoPlayPage> createState() => _VideoPlayPageState();
}

class _VideoPlayPageState extends State<VideoPlayPage> {
  late PageController _pageController;
  // 横屏状态在页面级统一管理：所有视频项共享，离开页面复位竖屏
  final ValueNotifier<bool> _landscape = ValueNotifier<bool>(false);
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

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    _pageController.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _landscape.dispose();
    _activeIndex.dispose();
    // 需求1：离开播放页（退回首页）则停止音频与视频，不再继续播放。
    // 注意：退出整个 App 时由 main/app 生命周期决定；这里仅“仍停留在 App 内-
    // 播放页首页”情况下停止播放，符合“退出到播放页首页、音频还在播放需改正”。
    globalAudioHandler.value?.stop();
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
              total: widget.videos.length,
              activeIndex: _activeIndex,
              landscape: _landscape,
              pageController: _pageController,
              onToggleOrientation: _toggleOrientation,
              resumePosition:
                  index == widget.initialIndex ? widget.resumePosition : null,
              seriesContext: widget.seriesContext,
            );
          },
        ),
      ),
    );
  }
}

/// 单个视频播放项。
///
/// 设计（重构后）：前台用 video_player 单引擎音画一体（声音+画面同源，无需对表看门狗，
/// 彻底消除双引擎同步卡顿）；后台播放开关来自全局设置（AppSettings），开启时仅在“切后台”
/// 那一刻把音频一次性交给 audio_service（just_audio）续播，前台恢复时再交回 video_player。
/// 即：前台单引擎、后台只用音频，二者按生命周期切换，互不长期并行。
class VideoPlayItem extends StatefulWidget {
  final LocalVideoModel model;
  final int index;
  final int total;
  final ValueNotifier<int> activeIndex;
  final ValueNotifier<bool> landscape;
  final PageController pageController;
  final VoidCallback onToggleOrientation;
  final Duration? resumePosition; // 仅命中 initialIndex 的项才非空
  final SeriesPlayContext? seriesContext;

  const VideoPlayItem({
    required this.model,
    required this.index,
    required this.total,
    required this.activeIndex,
    required this.landscape,
    required this.pageController,
    required this.onToggleOrientation,
    this.resumePosition,
    this.seriesContext,
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
  // 自定义控制面板：仅由「设置」按钮呼出，默认隐藏
  bool _showControls = false;
  bool _isPlaying = true;
  bool _playbackIntended = true; // 用户是否希望播放（暂停/定时关闭会置否）
  Timer? _autoHideTimer;
  Timer? _progressTimer; // 追剧：周期性把播放进度写回历史
  bool _isBackground = false; // 当前是否处于后台（熄屏/切后台），用于前台/后台播放源切换
  // ===== 自定义单击/双击检测 =====
  // Flutter 内置 onTap+onDoubleTap 的双击窗口过严（仅 300ms 且要求两次均为"干净点按"，
  // 躺着握机时手指轻微位移会被判为两次单击，导致"点四下才暂停"）。改为自实现：
  // 时间窗口放宽到 350ms、允许两次点击位置偏移、单击仅在窗口结束后才触发，避免误判。
  DateTime? _lastTapTime;
  Offset? _lastTapPos;
  Timer? _singleTapTimer;
  static const Duration _doubleTapWindow = Duration(milliseconds: 350);
  static const double _doubleTapSlop = 100.0; // 第二次点击允许的最大位移(px)
  // 定时关闭到期时由全局 SleepTimer 调用，暂停当前激活页的音视频
  late final VoidCallback _onTimerExpire;
  AudioPlayerHandler? _handler;
  String _displayName = '';

  bool get _isActive => widget.activeIndex.value == widget.index;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _handler = globalAudioHandler.value;
    globalAudioHandler.addListener(_onHandlerReady);
    // 注册“定时关闭到期”回调：到期时暂停本页音视频（全局 SleepTimer 仅在激活页注册）
    _onTimerExpire = () {
      _pauseAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已到设定时间，已停止播放'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    };

    // 视频显示名称（自定义或默认文件名）
    _loadName();

    _vpc = VideoPlayerController.file(File(widget.model.filePath));
    _vpc.addListener(_onVideoChanged);
    _vpc.initialize().then((_) async {
      if (!mounted) return;
      _vpc.setVolume(1); // 前台单引擎：video_player 自身出声（音画一体）
      // 续播：把画面定位到断点（仅命中 initialIndex 的项有 resumePosition）。
      if (widget.resumePosition != null &&
          widget.resumePosition! > Duration.zero &&
          _vpc.value.isInitialized) {
        try {
          await _vpc.seekTo(widget.resumePosition!);
        } catch (_) {}
      }
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
      if (_isActive) _activate();
    }).catchError((_) {
      if (mounted) setState(() => _initialized = true);
    });

    // 追剧：周期性（每 5s）把当前激活集的进度写回历史，供快速续播使用。
    if (widget.seriesContext != null) {
      _progressTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _saveSeriesProgress(),
      );
    }

    widget.activeIndex.addListener(_onActiveChanged);

    // 监听音频播放完成：后台音频（just_audio）播放完毕时驱动顺序/循环（前台完成由 _onVideoChanged 处理）
    _handler?.player.processingStateStream.listen(_onAudioComplete);
  }

  Future<void> _loadName() async {
    final name = await VideoNameStore.getName(widget.model.filePath);
    if (mounted) setState(() => _displayName = name);
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
    h?.player.processingStateStream.listen(_onAudioComplete);
    if (h != null && _isActive && _initialized) {
      _activate();
    }
  }

  /// 后台音频（just_audio）播放完成事件：根据播放模式决定下一步。
  /// 前台完成由 _onVideoChanged 监测 video_player 的 isCompleted 触发，二者不重复。
  void _onAudioComplete(ProcessingState state) {
    if (state != ProcessingState.completed) return;
    if (!_isActive || !_audioReady) return;
    _handleComplete();
  }

  /// 前台 video_player 播放完成（单引擎，无 just_audio 完成事件）。
  void _onVideoCompleted() {
    if (!_isActive || !_playbackIntended) return;
    _handleComplete();
  }

  /// 追剧：把当前激活集的播放进度写回历史（单集进度 + 上次观看）。
  void _saveSeriesProgress() {
    if (widget.seriesContext == null || !mounted) return;
    if (!_isActive) return; // 只记录正在看的这一集
    if (widget.index >= widget.seriesContext!.episodePaths.length) return;
    final path = widget.seriesContext!.episodePaths[widget.index];
    final pos = _curPos();
    final dur = _curDur();
    SeriesHistoryStore.saveProgress(path, pos, dur, completed: false);
    SeriesHistoryStore.saveLastWatched(
      seriesPath: widget.seriesContext!.seriesPath,
      seriesName: widget.seriesContext!.seriesName,
      seasonPath: widget.seriesContext!.seasonPath,
      seasonName: widget.seriesContext!.seasonName,
      episodePath: path,
      episodeIndex: widget.index,
      position: pos,
      duration: dur,
    );
  }

  /// 追剧：某一集播放完成后的历史处理。
  ///  - 顺序模式：把「上次观看」推进到下一集（断点=0），实现看完一集自动续看下一集；
  ///  - 其它模式：标记本集已看完，上次观看停在本集（断点=0）。
  void _markSeriesCompleted() {
    if (widget.seriesContext == null) return;
    if (widget.index >= widget.seriesContext!.episodePaths.length) return;
    final ctx = widget.seriesContext!;
    final path = ctx.episodePaths[widget.index];
    final dur = _curDur();
    SeriesHistoryStore.saveProgress(path, Duration.zero, dur, completed: true);
    if (AppSettings.instance.playMode == PlayMode.sequence) {
      final next = widget.index + 1;
      if (next < widget.total && next < ctx.episodePaths.length) {
        SeriesHistoryStore.saveLastWatched(
          seriesPath: ctx.seriesPath,
          seriesName: ctx.seriesName,
          seasonPath: ctx.seasonPath,
          seasonName: ctx.seasonName,
          episodePath: ctx.episodePaths[next],
          episodeIndex: next,
          position: Duration.zero,
          duration: Duration.zero,
        );
      }
    } else {
      SeriesHistoryStore.saveLastWatched(
        seriesPath: ctx.seriesPath,
        seriesName: ctx.seriesName,
        seasonPath: ctx.seasonPath,
        seasonName: ctx.seasonName,
        episodePath: path,
        episodeIndex: widget.index,
        position: Duration.zero,
        duration: dur,
      );
    }
  }

  /// 播放完成后的统一后继逻辑：顺序 / 单集循环 / 手动。
  void _handleComplete() {
    // 追剧：先记录完成（推进/标记），再执行模式后继逻辑。
    _markSeriesCompleted();
    diag('completed 播放模式=${AppSettings.instance.playMode.name}');
    switch (AppSettings.instance.playMode) {
      case PlayMode.sequence:
        _playNext();
        break;
      case PlayMode.loopOne:
        if (_isBackground) {
          _handler?.player.seek(Duration.zero);
          _handler?.player.play();
        } else {
          _vpc.seekTo(Duration.zero);
          _vpc.play();
        }
        break;
      case PlayMode.manual:
      default:
        // 手动模式：停止（视频/音频均停下）
        _pauseAll();
        break;
    }
  }

  /// 顺序播放：跳到下一集（若已是最后一集则停止）。
  void _playNext() {
    final next = widget.index + 1;
    if (next >= widget.total) {
      // 已是最后一集
      _pauseAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最后一个视频')),
        );
      }
      return;
    }
    widget.activeIndex.value = next;
    // 由外层 PageController 驱动翻页
    widget.pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    // 翻页后新一集成为激活项，_onActiveChanged 会自动激活并播放。
  }

  /// 成为激活项。
  /// 前台：video_player 单引擎音画一体（声音由 video_player 自身出声，just_audio 仅“待命”不抢声）。
  /// 后台（如后台顺序播放切到下一集）：直接用 just_audio 续播音频。
  Future<void> _activate() async {
    if (!_initialized) return;
    // 成为激活页：接管“定时关闭到期”的暂停回调
    SleepTimer.instance.onExpire = _onTimerExpire;
    final handler = globalAudioHandler.value;
    _handler = handler;
    // 预载音频到 audio_service（仅“待命”，不播放），供切后台时一次性交接。
    if (handler != null) {
      try {
        await handler.loadFile(widget.model.filePath);
        _audioReady = true;
      } catch (_) {
        _audioReady = false;
      }
    }
    if (!_playbackIntended) {
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    if (_isBackground && AppSettings.instance.backgroundPlay) {
      // 后台激活：直接用 just_audio 续播音频（无画面）
      if (_audioReady && _handler != null) {
        try {
          _handler!.player.seek(Duration.zero);
          _handler!.player.play();
        } catch (_) {}
      }
    } else {
      // 前台：单引擎，video_player 音画一体。确保 just_audio 静默，避免双声。
      if (_vpc.value.isInitialized) {
        await _handler?.player.pause();
        _vpc.setVolume(1);
        _vpc.play();
      }
    }
    if (mounted) setState(() => _isPlaying = _playbackIntended);
  }

  /// 离开激活：暂停本项视频解码（音频由新的激活项接管）
  void _deactivate() {
    if (_vpc.value.isInitialized) _vpc.pause();
  }

  void _onVideoChanged() {
    // 前台单引擎：video_player 播放完毕（isCompleted）时驱动后继逻辑（后台由 just_audio 事件处理）。
    if (_vpc.value.isCompleted &&
        _isActive &&
        _playbackIntended &&
        !_isBackground) {
      _onVideoCompleted();
    }
    if (mounted && _showControls) setState(() {});
  }

  Duration _curPos() {
    // 后台用 just_audio 进度；前台用 video_player 进度（单引擎音画同源）。
    if (_isBackground && _audioReady && _handler != null) {
      return _handler!.player.position;
    }
    return _vpc.value.isInitialized ? _vpc.value.position : Duration.zero;
  }

  Duration _curDur() {
    if (_isBackground && _audioReady && _handler != null) {
      return _handler!.player.duration ?? Duration.zero;
    }
    return _vpc.value.isInitialized ? _vpc.value.duration : Duration.zero;
  }

  Future<void> _seekTo(Duration d) async {
    if (_isBackground && _audioReady && _handler != null) {
      await _handler!.player.seek(d);
    }
    if (_vpc.value.isInitialized) _vpc.seekTo(d);
  }

  // 注：原“双引擎同步看门狗 _syncVideo”已移除——重构后前台由 video_player 单引擎音画同源，
  // 后台只用 just_audio 出声，不再需要周期性对表，前台卡顿根因随之消除。

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  // ===== 定时关闭（睡眠定时，状态已移入全局 SleepTimer，跨视频切换持续生效） =====
  String _fmtSleep(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildTimerButton() {
    return ValueListenableBuilder<int?>(
      valueListenable: SleepTimer.instance.remaining,
      builder: (_, rem, __) {
        final active = rem != null;
        return TextButton.icon(
          onPressed: _pickSleepTimer,
          icon: Icon(Icons.timer,
              color: active ? Colors.amber : Colors.white, size: 20),
          label: Text(
            active ? _fmtSleep(rem!) : '定时',
            style: TextStyle(
                color: active ? Colors.amber : Colors.white, fontSize: 12),
          ),
        );
      },
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
            child: const Text('关闭（取消定时）', style: TextStyle(color: Colors.white)),
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
    if (choice == null) {
      SleepTimer.instance.cancel();
    } else {
      SleepTimer.instance.start(choice);
    }
    if (mounted) setState(() {});
  }

  /// 一键跳转系统电池/应用设置，引导用户把本 App 设为“电池不受限制 / 受保护应用”。
  Future<void> _openBatterySettings() async {
    final intent = AndroidIntent(
      action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      data: 'package:com.sleep.localvideoplayer',
    );
    try {
      await intent.launch();
      diag('openBatterySettings: 跳转电池优化豁免页');
    } catch (e) {
      final intent2 = AndroidIntent(
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

  /// 诊断状态浮层
  void _showStatusDialog() {
    showDialog(
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
    );
  }

  Widget _buildStatusButton() {
    return TextButton.icon(
      onPressed: _showStatusDialog,
      icon: const Icon(Icons.bug_report, color: Colors.white, size: 20),
      label: const Text('状态', style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  /// 续航设置按钮：一键跳转电池白名单设置。
  Widget _buildBatteryButton() {
    return TextButton.icon(
      onPressed: _openBatterySettings,
      icon: const Icon(Icons.battery_charging_full, color: Colors.white, size: 20),
      label: const Text('续航', style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  /// 播放模式选择（顺序/单集/手动）
  Widget _buildPlayModeButton() {
    return ValueListenableBuilder<PlayMode>(
      valueListenable: AppSettings.instance.playModeNotifier,
      builder: (_, mode, _) => TextButton.icon(
        onPressed: _pickPlayMode,
        icon: Icon(
          mode == PlayMode.sequence
              ? Icons.playlist_play
              : mode == PlayMode.loopOne
                  ? Icons.repeat_one
                  : Icons.play_circle_outline,
          color: Colors.white,
          size: 20,
        ),
        label: Text(
          mode.label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }

  Future<void> _pickPlayMode() async {
    final choice = await showDialog<PlayMode>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('播放模式', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.grey[900],
        children: [
          SimpleDialogOption(
            child: Text('手动播放（看完不自动播）', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(context, PlayMode.manual),
          ),
          SimpleDialogOption(
            child: Text('顺序播放（自动播下一个）', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(context, PlayMode.sequence),
          ),
          SimpleDialogOption(
            child: Text('单集循环（重复看本集）', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(context, PlayMode.loopOne),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await AppSettings.instance.setPlayMode(choice);
    if (choice != PlayMode.manual) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换为「${choice.label}」')),
      );
    }
  }

  /// 重命名当前视频（自定义名称，默认文件名）
  Future<void> _renameCurrent() async {
    final current = _displayName.isEmpty
        ? VideoNameStore.defaultName(widget.model.filePath)
        : _displayName;
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('视频名称', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '留空则使用文件名',
            hintStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (name == null) return;
    await VideoNameStore.setName(widget.model.filePath, name);
    setState(() => _displayName =
        name.isEmpty ? VideoNameStore.defaultName(widget.model.filePath) : name);
  }

  /// 「设置」按钮：播放页顶部永远只显示这一个按钮；点击弹出设置窗口。
  Widget _buildSettingsButton() {
    return IconButton(
      icon: const Icon(Icons.settings, color: Colors.white),
      tooltip: '设置',
      onPressed: _openSettingsSheet,
    );
  }

  /// 设置弹出窗口（底部弹窗）：集成定时关闭 / 播放模式 / 视频名称 / 诊断状态 / 续航。
  /// 其中「播放模式」下方实时显示当前选择（呼应此前需求）。
  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.timer, color: Colors.white),
              title: const Text('定时关闭', style: TextStyle(color: Colors.white)),
              subtitle: ValueListenableBuilder<int?>(
                valueListenable: SleepTimer.instance.remaining,
                builder: (_, rem, __) => Text(
                  rem == null ? '未设置' : '剩余 ${_fmtSleep(rem)}',
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickSleepTimer();
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play, color: Colors.white),
              title: const Text('播放模式', style: TextStyle(color: Colors.white)),
              subtitle: ValueListenableBuilder<PlayMode>(
                valueListenable: AppSettings.instance.playModeNotifier,
                builder: (_, mode, __) => Text(
                  mode.label,
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickPlayMode();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note, color: Colors.white),
              title: const Text('视频名称', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _renameCurrent();
              },
            ),
            ListTile(
              leading: const Icon(Icons.bug_report, color: Colors.white),
              title: const Text('诊断状态', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showStatusDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.battery_charging_full, color: Colors.white),
              title: const Text('续航白名单', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _openBatterySettings();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 视频名称按钮：点击重命名当前视频（默认文件名）。
  Widget _buildNameButton() {
    return TextButton.icon(
      onPressed: _renameCurrent,
      icon: const Icon(Icons.edit_note, color: Colors.white, size: 20),
      label: const Text('名称', style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  // ===== 播放/暂停（前台单引擎：video_player 音画一体） =====
  Future<void> _pauseAll() async {
    await _handler?.player.pause(); // 仅后台音频在播时需要；前台 just_audio 本就静默
    if (_vpc.value.isInitialized) _vpc.pause();
    _isPlaying = false;
    _playbackIntended = false;
  }

  Future<void> _playAll() async {
    _playbackIntended = true; // 立即标记：异步恢复期间保持“期望播放”
    // 前台恢复：单引擎，video_player 音画一体，无需任何对表/宽限期。
    if (_vpc.value.isInitialized) {
      _vpc.setVolume(1);
      await _vpc.play();
    }
    _isPlaying = true;
  }

  /// 单击/双击统一入口：在 onTapDown 处判断。
  /// - 与上次点按间隔 ≤ 350ms 且位移 ≤ 100px → 判定双击 → 切换播放/暂停；
  /// - 否则记录本次点按并启动 350ms 计时器，窗口内无第二次点按才触发"单击=切面板"。
  void _handleTapDown(TapDownDetails d) {
    final now = DateTime.now();
    final isDouble = _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _doubleTapWindow &&
        _lastTapPos != null &&
        (d.localPosition - _lastTapPos!).distance <= _doubleTapSlop;
    if (isDouble) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapTime = null;
      _lastTapPos = null;
      _togglePlay();
    } else {
      _lastTapTime = now;
      _lastTapPos = d.localPosition;
      _singleTapTimer?.cancel();
      _singleTapTimer = Timer(_doubleTapWindow, () {
        _onSingleTap();
        _lastTapTime = null;
        _lastTapPos = null;
      });
    }
  }

  /// 拖动/翻页（手指位移超过 slop）会触发 onTapCancel：取消待触发的单击，
  /// 避免滑动被误判为"单击切面板"或破坏双击计时。
  void _handleTapCancel() {
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapTime = null;
    _lastTapPos = null;
  }

  /// 单击屏幕：仅切换控制面板（进度条/按钮）的显隐，不再触发暂停/播放，
  /// 避免用户误触导致频繁 pause→resume 引发的画面卡顿。
  void _onSingleTap() {
    if (!mounted) return;
    setState(() => _showControls = !_showControls);
  }

  /// 双击屏幕：播放中 → 弹出控制面板 + 暂停；已暂停（面板可见）→ 隐藏面板 + 继续播放。
  void _togglePlay() {
    if (_isPlaying) {
      // 播放中双击：显示控制面板并暂停
      _showControls = true;
      _pauseAll();
      _autoHideTimer?.cancel();
    } else {
      // 已暂停时双击：隐藏控制面板并继续播放
      _showControls = false;
      _playAll();
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bgEnabled = AppSettings.instance.backgroundPlay;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      WakelockPlus.disable().catchError((_) {});
      _isBackground = true;
      if (!_isActive) return; // 仅激活项负责音频交接；其余项本就暂停，无需处理
      if (!_playbackIntended) {
        // 用户已手动暂停：离开前台也保持暂停，绝不能强行续播音频/视频。
        return;
      }
      if (bgEnabled) {
        // 交接：暂停静音画面，把音频一次性交给 just_audio 从当前进度续播（屏幕熄灭后仍有声）。
        final pos = _vpc.value.isInitialized ? _vpc.value.position : Duration.zero;
        if (_vpc.value.isInitialized) _vpc.pause();
        if (_audioReady && _handler != null) {
          try {
            _handler!.player.seek(pos);
            _handler!.player.play();
          } catch (_) {
            _audioReady = false;
          }
        }
      } else {
        // 未开启后台播放：离开前台即整体暂停
        _pauseAll();
      }
    } else if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable().catchError((_) {});
      _isBackground = false;
      if (!_isActive) return; // 仅激活项负责恢复；其余项保持暂停
      if (_playbackIntended) {
        if (bgEnabled) {
          // 后台→前台：暂停 just_audio，画面回到音频进度续播（前台单引擎音画一体）。
          if (_audioReady && _handler != null) {
            try {
              _handler!.player.pause();
            } catch (_) {}
          }
          if (_vpc.value.isInitialized) {
            final target = (_audioReady && _handler != null)
                ? _handler!.player.position
                : _vpc.value.position;
            _vpc.setVolume(1);
            _vpc.seekTo(target);
            _vpc.play();
          }
        } else {
          // 非后台模式：统一用 _playAll 恢复音画。
          _playAll();
        }
        _isPlaying = true;
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _progressTimer?.cancel();
    // 离开播放页：补存一次最终进度（追剧）。
    _saveSeriesProgress();
    _singleTapTimer?.cancel();
    // 若本页仍是定时关闭的回调持有者，则解绑（避免回调悬空）
    if (SleepTimer.instance.onExpire == _onTimerExpire) {
      SleepTimer.instance.onExpire = null;
    }
    globalAudioHandler.removeListener(_onHandlerReady);
    widget.activeIndex.removeListener(_onActiveChanged);
    WidgetsBinding.instance.removeObserver(this);
    _vpc.removeListener(_onVideoChanged);
    _chewieController?.dispose();
    _vpc.dispose();
    super.dispose();
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
      // 自实现单击/双击：onTapDown 捕获每次点按时间与位置，对时间/位移更宽容，
      // 单击（切面板）延迟到双击窗口结束后才触发，避免把双击误判成两次单击。
      onTapDown: _handleTapDown,
      onTapCancel: _handleTapCancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.black,
            child: Chewie(controller: _chewieController!),
          ),
          // 视频名称：竖屏常显；横屏仅进度条（控制面板）显示时显示
          _buildNameOverlay(),
          // 定时关闭倒计时（屏幕底部中间，全局，设置后常显）
          _buildSleepCountdown(),
          // 「设置」按钮（右上角常显，顶部唯一按钮）
          Positioned(
            top: 16,
            right: 8,
            child: _buildSettingsButton(),
          ),
          if (_showControls) _buildControls(),
        ],
      ),
    );
  }

  /// 视频名称浮层（需求6）。
  /// 竖屏常显；横屏仅进度条（控制面板）显示时显示。
  /// 控制面板显示时左上角有返回按钮，名称下移避免遮挡。
  Widget _buildNameOverlay() {
    final showInLandscape = widget.landscape.value && _showControls;
    final show = !widget.landscape.value || showInLandscape;
    if (!show) return const SizedBox.shrink();
    final top = _showControls ? 60.0 : 16.0;
    return Positioned(
      top: top,
      left: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(150),
          borderRadius: BorderRadius.circular(6),
        ),
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(
          _displayName.isEmpty
              ? VideoNameStore.defaultName(widget.model.filePath)
              : _displayName,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 定时关闭倒计时：设置后显示在播放页底部中间，全局（跨视频切换持续显示）。
  /// 由全局 SleepTimer 驱动；未设置时返回空，不占位。
  Widget _buildSleepCountdown() {
    return ValueListenableBuilder<int?>(
      valueListenable: SleepTimer.instance.remaining,
      builder: (_, rem, __) {
        if (rem == null) return const SizedBox.shrink();
        return Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(150),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer, color: Colors.amber, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    _fmtSleep(rem),
                    style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 自定义控制面板（顶部返回 + 中央播放/暂停 + 底部进度条）。
  /// 默认隐藏，仅当暂停（_showControls=true）时显示。
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
        // 右上角：定时/状态/续航/横屏（设置按钮常显在 build 外层）
        Positioned(
          top: 16,
          right: 56,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTimerButton(),
              _buildStatusButton(),
              _buildBatteryButton(),
              _buildPlayModeButton(),
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
