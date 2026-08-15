import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:video_player/video_player.dart';
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

  /// 全盘扫描并返回视频列表（按修改时间倒序）。
  /// [forceRefresh] 为 true 时清除缓存后重新遍历。
  static Future<List<LocalVideoModel>> scanVideos(
      {bool forceRefresh = false}) async {
    final cacheFile = await _cacheFile();
    if (!forceRefresh && await cacheFile.exists()) {
      try {
        final content = await cacheFile.readAsString();
        final list = (jsonDecode(content) as List)
            .map((e) => LocalVideoModel.fromJson(e as Map<String, dynamic>))
            .toList();
        // 二次启动直接读缓存，不重新扫描（任务 7 P4）
        return list;
      } catch (_) {
        // 缓存损坏则重新扫描
      }
    }

    final thumbDir = await _thumbnailDir();
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }

    final found = <LocalVideoModel>[];
    for (final root in await _scanRoots()) {
      final dir = Directory(root);
      if (await dir.exists()) {
        await _walk(dir, thumbDir, found);
      }
    }

    // 按文件修改时间倒序
    found.sort((a, b) => b.modifyTime.compareTo(a.modifyTime));

    // 持久化缓存（任务 3.5 / 任务 7 P4）
    try {
      final json = jsonEncode(found.map((e) => e.toJson()).toList());
      await cacheFile.writeAsString(json);
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }

    return found;
  }

  /// 刷新扫描：清除缓存后重新遍历（任务 3.6）
  static Future<List<LocalVideoModel>> refreshScan() async {
    final cacheFile = await _cacheFile();
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }
    return scanVideos(forceRefresh: true);
  }

  /// 枚举可扫描的根目录：内置存储 + 外置 SD 卡
  static Future<List<String>> _scanRoots() async {
    final roots = <String>[];
    const primary = '/storage/emulated/0';
    roots.add(primary);
    // 枚举 /storage 下的外置卷（排除 emulated/self/obb 等系统目录）
    final storageDir = Directory('/storage');
    if (await storageDir.exists()) {
      try {
        await for (final e in storageDir.list()) {
          if (e is Directory) {
            final name = p.basename(e.path);
            if (name == 'emulated' || name == 'self' || name == 'obb') continue;
            roots.add(e.path);
          }
        }
      } catch (_) {
        // 无权限枚举则忽略
      }
    }
    return roots;
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
