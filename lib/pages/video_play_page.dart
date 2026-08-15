import 'dart:async';
import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/local_video_model.dart';

/// 上下滑动短视频播放页（任务 5 / 改造：自动隐藏面板 + 横屏按钮）
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

  @override
  void initState() {
    super.initState();
    // 强制全屏沉浸式（任务 5.1.1），进入页隐藏状态栏/导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _pageController = PageController(initialPage: widget.initialIndex);
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
    _pageController.dispose();
    // 离开页面：复位竖屏并恢复系统 UI（任务 5.1.1）
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _landscape.dispose();
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
              onToggleOrientation: _toggleOrientation,
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
  final VoidCallback onToggleOrientation;

  const VideoPlayItem({
    required this.model,
    required this.landscape,
    required this.onToggleOrientation,
    super.key,
  });

  @override
  State<VideoPlayItem> createState() => _VideoPlayItemState();
}

class _VideoPlayItemState extends State<VideoPlayItem> {
  late VideoPlayerController _vpc;
  ChewieController? _chewieController;
  bool _initialized = false;
  bool _showControls = true;
  bool _isPlaying = true;
  Timer? _autoHideTimer;

  @override
  void initState() {
    super.initState();
    _vpc = VideoPlayerController.file(File(widget.model.filePath));
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
        });
        // 进入播放后控制面板自动隐藏（不再需要再点一下才消）
        _scheduleAutoHide();
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

  @override
  void dispose() {
    _autoHideTimer?.cancel();
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
        // 右上角横屏切换按钮
        Positioned(
          top: 16,
          right: 8,
          child: ValueListenableBuilder<bool>(
            valueListenable: widget.landscape,
            builder: (_, isLandscape, _) => IconButton(
              icon: Icon(
                isLandscape ? Icons.stay_current_portrait : Icons.stay_current_landscape,
                color: Colors.white,
              ),
              onPressed: widget.onToggleOrientation,
            ),
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
