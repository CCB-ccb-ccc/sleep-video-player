import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../core/app_settings.dart';
import '../core/folder_store.dart';
import '../core/permission_utils.dart';
import '../core/video_name_store.dart';
import '../core/video_scan_utils.dart';
import '../models/local_video_model.dart';
import '../widgets/video_grid_item.dart';

/// 首页视频网格列表页（任务 4 / 改造：按文件夹扫描 + 顶部文件夹切换栏）
class VideoListPage extends StatefulWidget {
  final VoidCallback? onGoSettings;

  const VideoListPage({super.key, this.onGoSettings});

  @override
  State<VideoListPage> createState() => _VideoListPageState();
}

class _VideoListPageState extends State<VideoListPage> {
  List<LocalVideoModel> _videos = [];
  List<FolderEntry> _folders = [];
  String? _selectedFolder; // null = 全部
  bool _loading = false;
  bool _permissionDenied = false;
  // 路径 -> 显示名称（自定义或默认文件名）
  Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    // 设置页增删/改名文件夹后自动刷新（通过 FolderStore.changed 通知）
    FolderStore.changed.addListener(_onFoldersChanged);
    // 视频重命名后自动刷新名称显示
    VideoNameStore.changed.addListener(_onNamesChanged);
    _init();
  }

  @override
  void dispose() {
    FolderStore.changed.removeListener(_onFoldersChanged);
    VideoNameStore.changed.removeListener(_onNamesChanged);
    super.dispose();
  }

  void _onFoldersChanged() {
    // 文件夹集合/名称变化：重新加载文件夹与视频
    _loadFolders();
    _loadVideos();
  }

  void _onNamesChanged() {
    // 视频名称变化：刷新名称缓存
    _loadNames();
    if (mounted) setState(() {});
  }

  Future<void> _loadNames() async {
    final paths = _videos.map((v) => v.filePath).toList();
    final map = await VideoNameStore.getAll(paths);
    if (mounted) setState(() => _names = map);
  }

  /// 启动优先执行权限校验（任务 6.2）
  Future<void> _init() async {
    final granted = await PermissionUtils.ensureStoragePermission();
    if (!granted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    await _loadFolders();
    await _loadVideos();
  }

  Future<void> _loadFolders() async {
    final entries = await FolderStore.getEntries();
    if (mounted) {
      setState(() {
        _folders = entries;
        // 选中的文件夹若已被移除，回到「全部」
        if (_selectedFolder != null &&
            !entries.any((e) => e.path == _selectedFolder)) {
          _selectedFolder = null;
        }
      });
    }
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
    await _loadNames();
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
    await _loadNames();
  }

  /// 按当前选中的文件夹筛选视频；null = 全部。
  List<LocalVideoModel> get _displayed {
    if (_selectedFolder == null) return _videos;
    return _videos
        .where((v) => p.isWithin(_selectedFolder!, v.filePath))
        .toList();
  }

  void _openVideo(int index) {
    // 携带筛选后的列表 + 点击索引跳转到播放页（任务 4.6）
    Navigator.of(context).pushNamed(
      '/play',
      arguments: {'videos': _displayed, 'index': index},
    );
  }

  /// 长按视频卡片：重命名显示名称（自定义，默认文件名）。
  Future<void> _renameVideo(LocalVideoModel video) async {
    final current = _names[video.filePath] ??
        VideoNameStore.defaultName(video.filePath);
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
    await VideoNameStore.setName(video.filePath, name);
    _snack(name.isEmpty ? '已恢复为默认文件名' : '已重命名');
  }

  /// 顶部文件夹切换导航栏：全部 + 各文件夹（显示自定义名）
  Widget _buildFolderNav() {
    final chips = <Widget>[
      _chip(null, '全部'),
    ];
    for (final e in _folders) {
      final name = e.label.isEmpty ? FolderStore.defaultLabel(e.path) : e.label;
      chips.add(_chip(e.path, name));
      chips.add(const SizedBox(width: 8));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(children: chips),
    );
  }

  Widget _chip(String? path, String label) {
    final selected = _selectedFolder == path;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _selectedFolder = path),
      backgroundColor: const Color(0xFF1A1A1A),
      selectedColor: Colors.white,
      labelStyle: TextStyle(color: selected ? Colors.black : Colors.white),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('播放', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: _loading ? null : _onRescan,
            child: const Text('重新扫描',
                style: TextStyle(color: Colors.white)),
          ),
        ],
        // 顶部文件夹切换栏（任务：直接在播放页顶部切换文件夹）
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: _buildFolderNav(),
        ),
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
    if (_displayed.isEmpty) {
      // 当前文件夹筛选后无视频（其它文件夹有内容时）
      final name = _selectedFolder == null
          ? ''
          : _folders
              .firstWhere((e) => e.path == _selectedFolder,
                  orElse: () => FolderEntry(path: '', label: ''))
              .label;
      final title = name.isEmpty ? '该文件夹' : '「$name」';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$title 暂无视频',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 8),
              const Text(
                '可切换到其它文件夹，或在设置页重新扫描',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    // 双列网格展示（任务 4.2），按当前选中的文件夹筛选
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: _displayed.length,
      itemBuilder: (context, index) {
        final v = _displayed[index];
        return GestureDetector(
          onLongPress: () => _renameVideo(v),
          child: VideoGridItem(
            video: v,
            displayName: _names[v.filePath] ?? '',
            onTap: () => _openVideo(index),
          ),
        );
      },
    );
  }
}
