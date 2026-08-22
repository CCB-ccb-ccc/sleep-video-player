import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/local_video_model.dart';
import '../models/series_models.dart';
import 'folder_store.dart';
import 'series_store.dart';
import 'video_scan_utils.dart';

/// 追剧模块扫描工具：把一个「大文件夹」解析为 剧 → 季 → 集 的结构。
///
/// 约定（与用户描述一致）：
///  - 大文件夹下的「直接子文件夹」= 一季（名称可自定义）；
///  - 季文件夹下的「直接视频文件」= 一集，按文件名中的数字从小到大排列（从 1 开始）；
///  - 若大文件夹根目录下也有零散视频，则归入一个名为「未分季」的虚拟季，便于兼容未分季的情况。
class SeriesScanUtils {
  // 支持的视频扩展名（与 VideoScanUtils 保持一致）
  static const List<String> _videoExtensions = [
    'mp4',
    'mkv',
    'mov',
    'avi',
    '3gp',
  ];

  static bool _isVideo(File file) {
    final ext = p.extension(file.path).toLowerCase().replaceAll('.', '');
    return _videoExtensions.contains(ext);
  }

  /// 从字符串中提取第一个连续数字（用于自然排序季/集）。
  /// 例如 "第12季.mp4" -> 12；无数字返回 -1。
  static int _extractNumber(String s) {
    final m = RegExp(r'(\d+)').firstMatch(s);
    return m != null ? int.parse(m.group(1)!) : -1;
  }

  /// 季排序：优先按名称中的数字，其次按名称字典序。无数字者排最后。
  static int _seasonCompare(String a, String b) {
    final na = _extractNumber(a);
    final nb = _extractNumber(b);
    if (na >= 0 && nb >= 0) return na.compareTo(nb);
    if (na >= 0) return -1;
    if (nb >= 0) return 1;
    return a.compareTo(b);
  }

  /// 集排序：按文件名中的数字升序（实现「从 1 开始顺序排列」），无数字则按文件名。
  static int _episodeCompare(LocalVideoModel a, LocalVideoModel b) {
    final na = _extractNumber(a.fileName);
    final nb = _extractNumber(b.fileName);
    if (na >= 0 && nb >= 0) return na.compareTo(nb);
    if (na >= 0) return -1;
    if (nb >= 0) return 1;
    return a.fileName.compareTo(b.fileName);
  }

  /// 列出某文件夹下「直接」的视频文件并构建模型（非递归）。
  static Future<List<LocalVideoModel>> _listEpisodes(String folder) async {
    final dir = Directory(folder);
    final files = <File>[];
    try {
      await for (final e in dir.list()) {
        if (e is File &&
            !p.basename(e.path).startsWith('.') &&
            _isVideo(e)) {
          files.add(e);
        }
      }
    } catch (_) {
      // 无权限访问则忽略
    }
    final models = <LocalVideoModel>[];
    for (final f in files) {
      models.add(await VideoScanUtils.buildModel(f));
    }
    models.sort(_episodeCompare);
    return models;
  }

  /// 扫描整部剧：返回各季与各季的集列表。
  static Future<SeriesData> scanSeries(String seriesPath) async {
    final dir = Directory(seriesPath);
    if (!await dir.exists()) {
      return SeriesData(
        path: seriesPath,
        name: FolderStore.defaultLabel(seriesPath),
        seasons: [],
      );
    }

    final subDirs = <Directory>[];
    final rootVideos = <File>[];
    try {
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('.')) continue;
        if (e is Directory) {
          subDirs.add(e);
        } else if (e is File && _isVideo(e)) {
          rootVideos.add(e);
        }
      }
    } catch (_) {
      // 忽略无权限目录
    }

    final seasons = <SeasonData>[];
    for (final d in subDirs) {
      final label = await SeriesStore.getSeasonLabel(d.path);
      final name =
          label.isNotEmpty ? label : FolderStore.defaultLabel(d.path);
      final episodes = await _listEpisodes(d.path);
      seasons.add(SeasonData(path: d.path, name: name, episodes: episodes));
    }

    // 根目录下的零散视频：归入「未分季」虚拟季（仅在有零散视频时）
    if (rootVideos.isNotEmpty) {
      final models = <LocalVideoModel>[];
      for (final f in rootVideos) {
        models.add(await VideoScanUtils.buildModel(f));
      }
      models.sort(_episodeCompare);
      seasons.add(SeasonData(
        path: seriesPath,
        name: '未分季',
        episodes: models,
      ));
    }

    seasons.sort((a, b) => _seasonCompare(a.name, b.name));
    return SeriesData(
      path: seriesPath,
      name: FolderStore.defaultLabel(seriesPath),
      seasons: seasons,
    );
  }

  /// 轻量扫描一部剧的「季」列表：仅列出子文件夹（季）+ 每季集数，
  /// **不生成缩略图、不读取时长**，因此进入季列表时极快（避免大剧集卡顿）。
  /// 季封面/集缩略图由 UI 层异步懒加载。
  static Future<SeriesData> listSeasonsLight(String seriesPath) async {
    final dir = Directory(seriesPath);
    if (!await dir.exists()) {
      return SeriesData(
        path: seriesPath,
        name: FolderStore.defaultLabel(seriesPath),
        seasons: [],
      );
    }
    final subDirs = <Directory>[];
    final rootVideos = <File>[];
    try {
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('.')) continue;
        if (e is Directory) {
          subDirs.add(e);
        } else if (e is File && _isVideo(e)) {
          rootVideos.add(e);
        }
      }
    } catch (_) {
      // 忽略无权限目录
    }

    final seasons = <SeasonData>[];
    for (final d in subDirs) {
      final label = await SeriesStore.getSeasonLabel(d.path);
      final name = label.isNotEmpty ? label : FolderStore.defaultLabel(d.path);
      // 仅统计该季视频文件数（列入目录条目，不读缩略图/时长），速度很快。
      int count = 0;
      try {
        await for (final f in Directory(d.path).list()) {
          if (f is File && !p.basename(f.path).startsWith('.') && _isVideo(f)) {
            count++;
          }
        }
      } catch (_) {
        // 忽略
      }
      seasons.add(SeasonData(
        path: d.path,
        name: name,
        episodes: [],
        episodeCount: count,
      ));
    }

    if (rootVideos.isNotEmpty) {
      seasons.add(SeasonData(
        path: seriesPath,
        name: '未分季',
        episodes: [],
        episodeCount: rootVideos.length,
      ));
    }

    seasons.sort((a, b) => _seasonCompare(a.name, b.name));
    return SeriesData(
      path: seriesPath,
      name: FolderStore.defaultLabel(seriesPath),
      seasons: seasons,
    );
  }

  /// 扫描单季：返回该季完整数据（含每集缩略图+时长）。
  /// 用于点击某季进入集列表时（只扫这一季，相比整部剧扫描快得多）。
  static Future<SeasonData> scanSeason(String seasonPath) async {
    final label = await SeriesStore.getSeasonLabel(seasonPath);
    final name = label.isNotEmpty ? label : FolderStore.defaultLabel(seasonPath);
    final episodes = await _listEpisodes(seasonPath);
    return SeasonData(path: seasonPath, name: name, episodes: episodes);
  }

  /// 取单季的封面路径（轻量：仅生成/复用「该季第一集」的缩略图）。
  /// 用于季列表卡片封面异步懒加载。
  static Future<String?> seasonCoverPath(String seasonPath) async {
    final dir = Directory(seasonPath);
    if (!await dir.exists()) return null;
    File? target;
    try {
      await for (final e in dir.list()) {
        if (e is File && !p.basename(e.path).startsWith('.') && _isVideo(e)) {
          target = e;
          break;
        }
      }
    } catch (_) {
      // 忽略
    }
    if (target == null) return null;
    final model = await VideoScanUtils.buildModel(target);
    return model.thumbnailPath;
  }

  /// 取一部剧的封面路径（轻量：仅生成/复用「第一季第一集」的缩略图）。
  /// 用于剧列表卡片，避免为封面扫描整部剧。
  static Future<String?> seriesCoverPath(String seriesPath) async {
    final dir = Directory(seriesPath);
    if (!await dir.exists()) return null;
    Directory? firstSeason;
    File? firstVideo;
    try {
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('.')) continue;
        if (e is Directory && firstSeason == null) firstSeason = e;
        if (e is File && _isVideo(e) && firstVideo == null) firstVideo = e;
      }
    } catch (_) {
      // 忽略
    }
    File? target = firstVideo;
    if (target == null && firstSeason != null) {
      try {
        await for (final e in firstSeason.list()) {
          if (e is File && !p.basename(e.path).startsWith('.') && _isVideo(e)) {
            target = e;
            break;
          }
        }
      } catch (_) {
        // 忽略
      }
    }
    if (target == null) return null;
    final model = await VideoScanUtils.buildModel(target);
    return model.thumbnailPath;
  }

  /// 轻量统计季数（仅列目录，不生成缩略图/读时长）：
  /// 子文件夹数 + 若根目录有零散视频则 +1（归入「未分季」）。
  static Future<int> seriesSeasonCount(String seriesPath) async {
    final dir = Directory(seriesPath);
    if (!await dir.exists()) return 0;
    int count = 0;
    bool hasRootVideo = false;
    try {
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('.')) continue;
        if (e is Directory) {
          count++;
        } else if (e is File && _isVideo(e)) {
          hasRootVideo = true;
        }
      }
    } catch (_) {
      // 忽略
    }
    if (hasRootVideo) count++;
    return count;
  }
}
