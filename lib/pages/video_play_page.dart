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
import '../core/sleep_timer.dart';
import '../core/video_name_store.dart';
import '../debug/diag.dart';
import '../models/local_video_model.dart';

/// 播放页容器：底部竖向滑动切换视频（抖音式）。
/// 页面级统一管理：横屏、当前激活序号、全局后台开关（来自设置）。
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
/// 后台播放开关来自全局设置（AppSettings），用户一旦在“设置页”开启即持久生效。
class VideoPlayItem extends StatefulWidget {
  final LocalVideoModel model;
  final int index;
  final int total;
  final ValueNotifier<int> activeIndex;
  final ValueNotifier<bool> landscape;
  final PageController pageController;
  final VoidCallback onToggleOrientation;

  const VideoPlayItem({
    required this.model,
    required this.index,
    required this.total,
    required this.activeIndex,
    required this.landscape,
    required this.pageController,
    required this.onToggleOrientation,
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
  Timer? _syncTimer; // 静音画面与音频进度对齐
  DateTime? _syncGraceUntil; // 恢复播放后的“同步宽限期”：期间不纠正漂移，避免反复 seek 卡顿
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
      if (_isActive) _activate();
    }).catchError((_) {
      if (mounted) setState(() => _initialized = true);
    });

    widget.activeIndex.addListener(_onActiveChanged);
    // 每 700ms 校验并修复双引擎一致性（音频/画面任一意外停止或漂移都在此纠正）。
    _syncTimer = Timer.periodic(
        const Duration(milliseconds: 700), (_) => _syncVideo());

    // 监听音频播放完成：顺序播放 / 单集循环
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

  /// 音频播放完成事件：根据播放模式决定下一步。
  void _onAudioComplete(ProcessingState state) {
    if (state != ProcessingState.completed) return;
    if (!_isActive || !_audioReady) return;
    diag('audio completed 播放模式=${AppSettings.instance.playMode.name}');
    switch (AppSettings.instance.playMode) {
      case PlayMode.sequence:
        _playNext();
        break;
      case PlayMode.loopOne:
        _handler?.player.seek(Duration.zero);
        _handler?.player.play();
        _vpc.seekTo(Duration.zero);
        _vpc.play();
        break;
      case PlayMode.manual:
      default:
        // 手动模式：停止（视频也停下）
        if (_vpc.value.isInitialized) _vpc.pause();
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

  /// 成为激活项：加载音频到音频服务并开始播放（视频静音同步）。
  Future<void> _activate() async {
    if (!_initialized) return;
    // 成为激活页：接管“定时关闭到期”的暂停回调
    SleepTimer.instance.onExpire = _onTimerExpire;
    diag('activate: isActive=$_isActive');
    final handler = globalAudioHandler.value;
    _handler = handler;
    diag('activate: handler=${handler?.runtimeType ?? 'null'}');
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
      if (_vpc.value.isInitialized) {
        await handler.player.seek(_vpc.value.position);
      }
    } catch (_) {
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
        _showControls = false;
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

  /// 双引擎一致性守护：视频(静音画面)与音频(just_audio)是两套独立解码器，
  /// 仅靠本方法保持同步。每 ~700ms 运行一次，负责：
  ///  - 期望播放但音频意外停止（被系统/其他应用抢走焦点等）→ 以画面进度为基准重启音频；
  ///    若音频彻底不可用则退化为“画面自身出声”，杜绝“有画面无音频”。
  ///  - 期望播放但画面意外停止 → 续播画面。
  ///  - 音画漂移超过阈值 → 把“静音画面”拉回音频进度（只动画面，避免音频爆音引起的卡顿观感）。
  void _syncVideo() {
    if (!_isActive || !_initialized) return;
    // 未期望播放：确保静音画面静止。
    if (!_playbackIntended) {
      if (_vpc.value.isInitialized && _vpc.value.isPlaying) _vpc.pause();
      return;
    }
    // 退化路径（无音频服务）：由画面自身出声。
    if (_handler == null || !_audioReady) {
      if (_vpc.value.isInitialized) {
        if (!_vpc.value.isPlaying) _vpc.play();
        if (_vpc.value.volume < 1) _vpc.setVolume(1);
      }
      return;
    }
    final audioPlaying = _handler!.player.playing;
    final audioPos = _handler!.player.position;
    final dur = _handler!.player.duration ?? Duration.zero;
    final vp = _vpc.value.position;
    final videoPlaying = _vpc.value.isInitialized && _vpc.value.isPlaying;

    if (!audioPlaying) {
      // 音频没在播但期望播放：若接近结尾则交给 _onAudioComplete 处理；
      // 否则且画面仍在播（即“有画面无音频”）→ 以画面进度为基准重启音频。
      if (audioPos < dur - const Duration(seconds: 1) && _vpc.value.isInitialized) {
        try {
          _handler!.player.seek(vp);
          _handler!.player.play();
        } catch (_) {
          // 音频彻底不可用：退化为画面出声，保证至少有声音。
          _audioReady = false;
          _vpc.setVolume(1);
        }
      }
      return;
    }
    // 音频在播：保证画面也在播。
    if (!videoPlaying) {
      // 画面彻底停了：恢复播放（对齐到音频进度）。
      if (_vpc.value.isInitialized) {
        _vpc.seekTo(audioPos);
        _vpc.play();
      }
      return;
    }
    // 画面在播：进入对齐逻辑。
    // 刚恢复播放的 3s 宽限期内，画面正在重新缓冲追赶进度，
    // 严禁反复 seek（否则不断打断解码 → 卡顿），仅保持播放即可。
    final inGrace =
        _syncGraceUntil != null && DateTime.now().isBefore(_syncGraceUntil!);
    if (inGrace) return;
    // 宽限期后：仅当“音频明显领先画面 > 1.5s”时用「向前 seek」把画面拉回
    // （向前 seek 速度快、不爆音）；画面领先音频时不回退，避免回退 seek 卡顿。
    if (audioPos - vp > const Duration(milliseconds: 1500)) {
      _vpc.seekTo(audioPos);
    }
  }

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

  // ===== 播放/暂停：控制音频服务（声音）+ 静音视频 =====
  Future<void> _pauseAll() async {
    await _handler?.player.pause();
    if (_vpc.value.isInitialized) _vpc.pause();
    _isPlaying = false;
    _playbackIntended = false;
  }

  Future<void> _playAll() async {
    _playbackIntended = true; // 立即标记：避免同步看门狗在异步恢复期间误把画面暂停
    // 1) 先恢复音频（声音主源）。若恢复失败，退化为画面自身出声，避免“有画面无音频”。
    if (_audioReady && _handler != null) {
      try {
        await _handler!.player.play();
      } catch (_) {
        _audioReady = false;
        if (_vpc.value.isInitialized) _vpc.setVolume(1);
      }
    }
    // 2) 恢复静音画面：把画面 seek 到“音频当前进度”再 play()。
    //    - seek 到当前位置会强制 ExoPlayer 重新解码输出新一帧，刷新纹理，
    //      修复 pause→resume 后画面停在旧帧、单击续播卡顿的问题；
    //    - 对齐到音频进度，保证音画同步（不再用 -100ms 回退，避免回退 seek 的卡顿）。
    if (_vpc.value.isInitialized) {
      final target = (_audioReady && _handler != null)
          ? _handler!.player.position
          : _vpc.value.position;
      await _vpc.seekTo(target);
      await _vpc.play();
    }
    // 3) 设置“同步宽限期”：接下来 3s 内 _syncVideo 不再纠正漂移，
    //    让画面安心缓冲追赶音频，避免出现“音频正常、画面却一直被反复 seek 卡死”的怪圈。
    _syncGraceUntil = DateTime.now().add(const Duration(milliseconds: 3000));
    _isPlaying = true;
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
      if (!_playbackIntended) {
        // 用户已手动暂停：离开前台也保持暂停，绝不能强行续播音频/视频。
        // 修复：暂停后息屏，视频又自动开始播放。
        return;
      }
      if (bgEnabled) {
        // 后台播放开启且用户希望播放：音频服务继续；仅暂停视频解码省电。
        if (_audioReady && _handler != null) {
          _handler!.player.play();
        }
        if (_vpc.value.isInitialized) _vpc.pause();
      } else {
        // 未开启后台播放：离开前台即整体暂停
        _pauseAll();
      }
    } else if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable().catchError((_) {});
      if (_playbackIntended) {
        if (bgEnabled) {
          // 后台模式回到前台：音频本就在播（媒体服务独立于 Activity），
          // 只需把静音画面 seek 到音频进度并续播，刷新纹理、避免卡顿。
          if (_vpc.value.isInitialized) {
            final target = (_audioReady && _handler != null)
                ? _handler!.player.position
                : _vpc.value.position;
            _vpc.seekTo(target);
            _vpc.play();
          }
        } else {
          // 非后台模式：统一用 _playAll 恢复音画（已含纹理刷新逻辑）。
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
    _syncTimer?.cancel();
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
      // 单击屏幕：仅切换控制面板显隐（不再触发暂停/播放，避免误触导致画面卡顿）
      onTap: _onSingleTap,
      // 双击屏幕：切换播放/暂停（用户明确要求，避免误触）
      onDoubleTap: _togglePlay,
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
