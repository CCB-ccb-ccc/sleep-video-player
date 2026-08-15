import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/folder_store.dart';
import '../core/video_scan_utils.dart';

/// 设置页：让用户自行指定一个或多个视频文件夹（不再全盘遍历手机）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<String> _folders = [];
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final folders = await FolderStore.getFolders();
    if (mounted) setState(() => _folders = folders);
  }

  /// 通过系统文件夹选择器添加一个视频文件夹（可多次添加）。
  Future<void> _addFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择包含视频的文件夹',
    );
    if (path == null) return; // 用户取消
    if (_folders.contains(path)) {
      _snack('该文件夹已添加');
      return;
    }
    final next = [..._folders, path];
    await FolderStore.saveFolders(next); // 持久化并广播变更
    if (mounted) setState(() => _folders = next);
    _snack('已添加文件夹');
  }

  /// 移除某个文件夹。
  Future<void> _removeFolder(String path) async {
    final next = _folders.where((e) => e != path).toList();
    await FolderStore.saveFolders(next);
    if (mounted) setState(() => _folders = next);
  }

  /// 重新扫描选中文件夹（清缓存后重扫）。
  Future<void> _refreshVideos() async {
    if (_folders.isEmpty) {
      _snack('请先添加视频文件夹');
      return;
    }
    if (mounted) setState(() => _refreshing = true);
    await VideoScanUtils.refreshScan();
    if (mounted) setState(() => _refreshing = false);
    _snack('已重新扫描选中文件夹');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('设置', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '视频来源',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '请选择存放视频的文件夹（可添加多个）。应用只会扫描你指定的文件夹，'
            '不会遍历整台手机。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _addFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('添加视频文件夹'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 16),
          if (_folders.isEmpty)
            const Text(
              '尚未选择任何文件夹。点击上方按钮添加。',
              style: TextStyle(color: Colors.grey),
            )
          else
            ..._folders.map((f) => _folderTile(f)),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _refreshing ? null : _refreshVideos,
            icon: _refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(_refreshing ? '扫描中…' : '重新扫描选中文件夹'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white30),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderTile(String path) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: const Icon(Icons.folder, color: Colors.white70),
        title: Text(
          path,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => _removeFolder(path),
        ),
      ),
    );
  }
}
