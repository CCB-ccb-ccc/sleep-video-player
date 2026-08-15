import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:video_player/video_player.dart';
import '../core/folder_store.dart';
import '../models/local_video_model.dart';

/// 本地视频扫描工具（任务 3.2）
class VideoScanUtils {
  // 支持的视频扩展名（大小写不敏感）
  static const List<String> _videoExtensions = [
    'mp4',
    'mkv',
    'mov',
    'avi',
    '3gp',
  ];
  // 小于此大小的文件将被过滤（500KB）
  static const int _minFileSize = 500 * 1024;

  /// 按用户选中的文件夹扫描并返回视频列表（按修改时间倒序）。
  /// 取代原先「全盘遍历 /storage」的方案。
  /// [forceRefresh] 为 true 时清除缓存后重新遍历。
  static Future<List<LocalVideoModel>> scanVideos(
      {bool forceRefresh = false}) async {
    final folders = await FolderStore.getFolders();
    if (folders.isEmpty) {
      // 未选择任何文件夹：返回空，列表页提示去设置页选择
      return [];
    }

    final cacheFile = await _cacheFile();
    if (!forceRefresh && await cacheFile.exists()) {
      try {
        final content = await cacheFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final cachedFolders =
            (decoded['folders'] as List).cast<String>();
        // 文件夹集合未变化才复用缓存（任务 7 P4）；否则重新扫描
        if (_sameSet(cachedFolders, folders)) {
          final list = (decoded['videos'] as List)
              .map((e) => LocalVideoModel.fromJson(e as Map<String, dynamic>))
              .toList();
          return list;
        }
      } catch (_) {
        // 缓存损坏则重新扫描
      }
    }

    final thumbDir = await _thumbnailDir();
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }

    final found = <LocalVideoModel>[];
    for (final root in folders) {
      final dir = Directory(root);
      if (await dir.exists()) {
        await _walk(dir, thumbDir, found);
      }
    }

    // 按文件修改时间倒序
    found.sort((a, b) => b.modifyTime.compareTo(a.modifyTime));

    // 持久化缓存（任务 3.5 / 任务 7 P4）：连同文件夹集合一起保存
    try {
      final json = jsonEncode({
        'folders': folders,
        'videos': found.map((e) => e.toJson()).toList(),
      });
      await cacheFile.writeAsString(json);
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }

    return found;
  }

  /// 比较两个文件夹集合是否一致（顺序无关）
  static bool _sameSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setB = b.toSet();
    for (final x in a) {
      if (!setB.contains(x)) return false;
    }
    return true;
  }

  /// 刷新扫描：清除缓存后重新遍历（任务 3.6）
  static Future<List<LocalVideoModel>> refreshScan() async {
    final cacheFile = await _cacheFile();
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }
    return scanVideos(forceRefresh: true);
  }

  /// 递归遍历目录，收集符合条件的视频
  static Future<void> _walk(
      Directory dir, Directory thumbDir, List<LocalVideoModel> out) async {
    try {
      await for (final entity in dir.list()) {
        // 跳过隐藏文件/目录（以 . 开头）
        if (p.basename(entity.path).startsWith('.')) continue;

        if (entity is Directory) {
          await _walk(entity, thumbDir, out);
        } else if (entity is File) {
          final ext =
              p.extension(entity.path).toLowerCase().replaceAll('.', '');
          if (!_videoExtensions.contains(ext)) continue;
          final stat = await entity.stat();
          if (stat.size < _minFileSize) continue; // 过滤零碎无效小文件
          out.add(await _buildModel(entity, thumbDir));
        }
      }
    } catch (_) {
      // 无权限访问的目录直接跳过
    }
  }

  /// 为单个视频构建模型（生成/复用缩略图、读取时长）
  static Future<LocalVideoModel> _buildModel(
      File file, Directory thumbDir) async {
    final path = file.path;
    final thumbPath = await _ensureThumbnail(path, thumbDir);
    Duration duration = Duration.zero;
    try {
      // 用 video_player 读取真实时长（允许的播放器插件）
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      duration = controller.value.duration;
      await controller.dispose();
    } catch (_) {
      duration = Duration.zero;
    }
    return LocalVideoModel(
      filePath: path,
      thumbnailPath: thumbPath,
      duration: duration,
      fileName: p.basename(path),
      modifyTime: (await file.stat()).modified,
    );
  }

  /// 生成缩略图；已存在则复用（按路径 hash 命名，任务 7 P3）
  static Future<String> _ensureThumbnail(
      String videoPath, Directory thumbDir) async {
    final key = _hash(videoPath);
    final target = File(p.join(thumbDir.path, '$key.jpg'));
    if (await target.exists()) {
      return target.path; // 复用，避免重复生成
    }
    try {
      final generated = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: thumbDir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 320,
        quality: 75,
      );
      if (generated != null && generated.isNotEmpty) {
        return generated;
      }
    } catch (_) {
      // 缩略图生成失败则返回空，列表页显示占位图标
    }
    return '';
  }

  /// 应用私有缓存目录（缩略图，任务 3.3）
  static Future<Directory> _thumbnailDir() async {
    final cache = await getApplicationCacheDirectory();
    return Directory(p.join(cache.path, 'video_thumbnails'));
  }

  /// 扫描结果缓存文件（任务 3.5）
  static Future<File> _cacheFile() async {
    final cache = await getApplicationCacheDirectory();
    return File(p.join(cache.path, 'video_scan_cache.json'));
  }

  /// 确定性 hash（视频路径 -> 文件名）
  static String _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }
}
