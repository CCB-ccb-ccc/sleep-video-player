import 'package:flutter/material.dart';
import '../core/folder_store.dart';
import '../core/permission_utils.dart';
import '../core/video_scan_utils.dart';
import '../models/local_video_model.dart';
import '../widgets/video_grid_item.dart';

/// 首页视频网格列表页（任务 4 / 改造为按文件夹扫描）
class VideoListPage extends StatefulWidget {
  final VoidCallback? onGoSettings;

  const VideoListPage({super.key, this.onGoSettings});

  @override
  State<VideoListPage> createState() => _VideoListPageState();
}

class _VideoListPageState extends State<VideoListPage> {
  List<LocalVideoModel> _videos = [];
  bool _loading = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    // 设置页增删文件夹后自动重新扫描（通过 FolderStore.changed 通知）
    FolderStore.changed.addListener(_onFoldersChanged);
    _init();
  }

  @override
  void dispose() {
    FolderStore.changed.removeListener(_onFoldersChanged);
    super.dispose();
  }

  void _onFoldersChanged() {
    // 文件夹集合变化：重新加载（权限已在前次加载中处理）
    _loadVideos();
  }

  /// 启动优先执行权限校验（任务 6.2）
  Future<void> _init() async {
    final granted = await PermissionUtils.ensureStoragePermission();
    if (!granted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    await _loadVideos();
  }

  Future<void> _loadVideos() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _permissionDenied = false;
      });
    }
    final list = await VideoScanUtils.scanVideos();
    if (mounted) {
      setState(() {
        _videos = list;
        _loading = false;
      });
    }
  }

  /// 重新扫描：清缓存重扫（任务 4.4 / 任务 3.6）
  Future<void> _onRescan() async {
    final granted = await PermissionUtils.ensureStoragePermission();
    if (!granted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _permissionDenied = false;
      });
    }
    final list = await VideoScanUtils.refreshScan();
    if (mounted) {
      setState(() {
        _videos = list;
        _loading = false;
      });
    }
  }

  void _openVideo(int index) {
    // 携带完整列表 + 点击索引跳转到播放页（任务 4.6）
    Navigator.of(context).pushNamed(
      '/play',
      arguments: {'videos': _videos, 'index': index},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        // 顶部仅一个【重新扫描】按钮，无其他控件（任务 4.4）
        actions: [
          TextButton(
            onPressed: _loading ? null : _onRescan,
            child: const Text('重新扫描',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) {
      // 未授权停留权限页（任务 6 验收）
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('需要存储权限才能读取所选文件夹中的视频',
                style: TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _onRescan,
              child: const Text('去授权'),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videos.isEmpty) {
      // 空态占位文案（任务 4.5，改造：引导去设置页选择文件夹）
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('还没有视频',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                '请先到「设置」页选择存放视频的文件夹',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: widget.onGoSettings,
                icon: const Icon(Icons.settings),
                label: const Text('去设置选择文件夹'),
              ),
            ],
          ),
        ),
      );
    }
    // 双列网格展示（任务 4.2）
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        return VideoGridItem(
          video: _videos[index],
          onTap: () => _openVideo(index),
        );
      },
    );
  }
}
