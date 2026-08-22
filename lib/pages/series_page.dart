import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/permission_utils.dart';
import '../core/series_history_store.dart';
import '../core/series_scan_utils.dart';
import '../core/series_store.dart';
import '../core/video_name_store.dart';
import '../models/local_video_model.dart';
import '../models/series_models.dart';
import '../models/series_resume.dart';
import '../widgets/video_grid_item.dart';

/// 追剧页：三级浏览（剧 → 季 → 集）+ 历史记录 + 快速续播。
///
/// 交互贴近常规剧集 App：手动选择大文件夹=一部剧；子文件夹=一季（名称可自定义）；
/// 季内视频按文件名数字升序=集（从 1 开始）。进入播放页时携带 SeriesPlayContext，
/// 由播放页把进度写回历史，离开 App 后再进追剧页会弹窗提示「继续播放」。
class SeriesPage extends StatefulWidget {
  const SeriesPage({super.key});

  // 由首页在切到「追剧」tab 时调用，触发续播弹窗（避免冷启动时未可见就弹窗）。
  static VoidCallback? onResumeRequested;

  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  int _level = 0; // 0=剧列表 1=季列表 2=集列表
  SeriesData? _series;
  SeasonData? _season;
  List<SeriesEntry> _seriesEntries = [];
  bool _loading = false;
  bool _permissionDenied = false;

  Map<String, Future<String?>> _coverFutures = {};
  Map<String, Future<int>> _seasonCountFutures = {};
  LastWatched? _lastWatched;

  Map<String, String> _epNames = {};
  Map<String, EpisodeProgress> _epProgress = {};

  // 每个 App 会话仅提示一次续播弹窗
  static bool _resumePromptShown = false;

  @override
  void initState() {
    super.initState();
    SeriesPage.onResumeRequested = _promptResume; // 同步注册，确保点击追剧 tab 即可触发
    _init();
  }

  Future<void> _init() async {
    final granted = await PermissionUtils.ensureStoragePermission();
    if (!granted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    await _loadSeriesEntries();
  }

  /// 进入追剧页时触发：若有上次观看且本会话未提示过，弹窗询问是否续播。
  void _promptResume() {
    if (_resumePromptShown) return;
    _resumePromptShown = true;
    SeriesHistoryStore.getLastWatched().then((lw) {
      if (lw != null && mounted) _showResumeDialog(lw);
    });
  }

  Future<void> _loadSeriesEntries() async {
    final entries = await SeriesStore.getEntries();
    final lw = await SeriesHistoryStore.getLastWatched();
    final covers = <String, Future<String?>>{};
    final counts = <String, Future<int>>{};
    for (final e in entries) {
      covers[e.path] = SeriesScanUtils.seriesCoverPath(e.path);
      counts[e.path] = SeriesScanUtils.seriesSeasonCount(e.path);
    }
    if (mounted) {
      setState(() {
        _seriesEntries = entries;
        _coverFutures = covers;
        _seasonCountFutures = counts;
        _lastWatched = lw;
      });
    }
  }

  // ===== 选择 / 增删剧 =====

  Future<void> _addSeries() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择一部剧的文件夹（内含各季子文件夹）',
    );
    if (path == null) return;
    await SeriesStore.addSeries(path);
    await _loadSeriesEntries();
    if (mounted) _snack('已添加剧集');
  }

  Future<void> _removeSeries(SeriesEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('移除该剧？', style: TextStyle(color: Colors.white)),
        content: const Text('仅从列表中移除记录，不会删除你硬盘上的文件。',
            style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SeriesStore.removeSeries(entry.path);
    await _loadSeriesEntries();
  }

  // ===== 导航：进入季 / 进入集 =====

  Future<void> _enterSeries(SeriesEntry entry) async {
    setState(() => _loading = true);
    final data = await SeriesScanUtils.scanSeries(entry.path);
    if (!mounted) return;
    setState(() {
      _series = data;
      _season = null;
      _level = 1;
      _loading = false;
    });
  }

  Future<void> _enterSeason(SeasonData season) async {
    final paths = season.episodes.map((e) => e.filePath).toList();
    final names = await VideoNameStore.getAll(paths);
    final prog = await SeriesHistoryStore.getAllProgress();
    if (!mounted) return;
    setState(() {
      _season = season;
      _epNames = names;
      _epProgress = prog;
      _level = 2;
    });
  }

  void _back() {
    if (_level == 2) {
      setState(() => _level = 1);
    } else if (_level == 1) {
      setState(() {
        _level = 0;
        _series = null;
        _season = null;
      });
    }
  }

  // ===== 播放 / 续播 =====

  void _playEpisode(SeasonData season, int index) {
    final eps = season.episodes;
    final ctx = SeriesPlayContext(
      seriesPath: _series!.path,
      seriesName: _series!.name,
      seasonPath: season.path,
      seasonName: season.name,
      episodePaths: eps.map((e) => e.filePath).toList(),
    );
    final prog = _epProgress[eps[index].filePath];
    final resume = (prog != null && !prog.completed && prog.positionMs > 0)
        ? Duration(milliseconds: prog.positionMs)
        : null;
    Navigator.of(context).pushNamed('/play', arguments: {
      'videos': eps,
      'index': index,
      'resumePosition': resume,
      'seriesContext': ctx,
    });
  }

  Future<void> _resumeLastWatched(LastWatched lw) async {
    setState(() => _loading = true);
    final data = await SeriesScanUtils.scanSeries(lw.seriesPath);
    if (!mounted) return;
    SeasonData? season;
    for (final s in data.seasons) {
      if (s.path == lw.seasonPath) {
        season = s;
        break;
      }
    }
    season ??= data.seasons.isNotEmpty ? data.seasons.first : null;
    if (season == null || season.episodes.isEmpty) {
      setState(() => _loading = false);
      _snack('未找到该剧集视频');
      return;
    }
    var index = lw.episodeIndex;
    if (index < 0 || index >= season.episodes.length) index = 0;
    final ctx = SeriesPlayContext(
      seriesPath: lw.seriesPath,
      seriesName: lw.seriesName,
      seasonPath: season.path,
      seasonName: season.name,
      episodePaths: season.episodes.map((e) => e.filePath).toList(),
    );
    setState(() => _loading = false);
    if (!mounted) return;
    Navigator.of(context).pushNamed('/play', arguments: {
      'videos': season.episodes,
      'index': index,
      'resumePosition': Duration(milliseconds: lw.positionMs),
      'seriesContext': ctx,
    });
  }

  void _showResumeDialog(LastWatched lw) {
    final ep = lw.episodeIndex + 1;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('继续观看？', style: TextStyle(color: Colors.white)),
        content: Text(
          '检测到上次在《${lw.seriesName}》${lw.seasonName} 第 $ep 集'
          '看到 ${_fmtMs(lw.positionMs)}，是否继续播放？',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _resumeLastWatched(lw);
            },
            child: const Text('继续播放', style: TextStyle(color: Colors.amber)),
          ),
        ],
      ),
    );
  }

  // ===== 重命名 =====

  Future<void> _renameSeries(SeriesEntry entry) async {
    final name = await _textDialog('自定义剧名', entry.label);
    if (name == null) return;
    await SeriesStore.renameSeries(entry.path, name);
    await _loadSeriesEntries();
  }

  Future<void> _renameSeason(SeasonData season) async {
    final name = await _textDialog('自定义季名', season.name);
    if (name == null) return;
    await SeriesStore.setSeasonLabel(season.path, name);
    // 刷新季名
    if (_series != null) {
      final refreshed = await SeriesScanUtils.scanSeries(_series!.path);
      if (mounted) {
        setState(() {
          _series = refreshed;
          _season = refreshed.seasons
              .where((s) => s.path == season.path)
              .firstOrNull;
        });
      }
    }
  }

  Future<void> _renameEpisode(LocalVideoModel v) async {
    final current = _epNames[v.filePath] ?? VideoNameStore.defaultName(v.filePath);
    final name = await _textDialog('自定义集名', current);
    if (name == null) return;
    await VideoNameStore.setName(v.filePath, name);
    final paths = _season!.episodes.map((e) => e.filePath).toList();
    final names = await VideoNameStore.getAll(paths);
    if (mounted) setState(() => _epNames = names);
  }

  Future<String?> _textDialog(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '留空则使用原名',
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
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes;
    final s = (d.inSeconds % 60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: _level > 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _back,
              )
            : null,
        title: Text(
          _level == 0
              ? '追剧'
              : _level == 1
                  ? (_series?.name ?? '剧')
                  : (_season?.name ?? '季'),
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          if (_level == 2)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新扫描本剧',
              onPressed: () async {
                if (_series == null) return;
                final refreshed =
                    await SeriesScanUtils.scanSeries(_series!.path);
                final season = refreshed.seasons
                    .where((s) => s.path == _season?.path)
                    .firstOrNull;
                final paths = season?.episodes.map((e) => e.filePath).toList() ?? [];
                final names = await VideoNameStore.getAll(paths);
                final prog = await SeriesHistoryStore.getAllProgress();
                if (mounted) {
                  setState(() {
                    _series = refreshed;
                    _season = season;
                    _epNames = names;
                    _epProgress = prog;
                  });
                }
                _snack('已重新扫描');
              },
            ),
          if (_level == 0)
            TextButton(
              onPressed: _addSeries,
              child: const Text('添加', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('需要存储权限才能读取所选文件夹中的剧集',
                style: TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _init, child: const Text('去授权')),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_level == 0) return _buildSeriesList();
    if (_level == 1) return _buildSeasonList();
    return _buildEpisodeList();
  }

  Widget _buildSeriesList() {
    if (_seriesEntries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('还没有添加剧集',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 8),
              const Text('点击下方「添加」，选择存放整部剧的大文件夹',
                  style: TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _addSeries,
                icon: const Icon(Icons.folder_open),
                label: const Text('添加剧集文件夹'),
              ),
            ],
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: _seriesEntries.length,
      itemBuilder: (context, i) => _seriesCard(_seriesEntries[i]),
    );
  }

  Widget _seriesCard(SeriesEntry entry) {
    final future = _coverFutures[entry.path];
    final name = entry.label.isEmpty
        ? SeriesStore.defaultLabel(entry.path)
        : entry.label;
    final last = _lastWatched?.seriesPath == entry.path ? _lastWatched : null;
    return GestureDetector(
      onTap: () => _enterSeries(entry),
      onLongPress: () => _seriesMenu(entry),
      child: Container(
        color: const Color(0xFF1A1A1A),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (future != null)
              FutureBuilder<String?>(
                future: future,
                builder: (ctx, snap) {
                  final cover = snap.data;
                  if (cover != null && cover.isNotEmpty) {
                    return Image.file(File(cover), fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _folderIcon());
                  }
                  return _folderIcon();
                },
              )
            else
              _folderIcon(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withAlpha(210), Colors.transparent],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    FutureBuilder<int>(
                      future: _seasonCountFutures[entry.path],
                      builder: (ctx, snap) => Text(
                        '${snap.data ?? 0} 季',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                    if (last != null)
                      Text(
                        '上次看到：${last.seasonName} 第 ${last.episodeIndex + 1} 集',
                        style: const TextStyle(color: Colors.amber, fontSize: 11),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _folderIcon() => const Center(
        child: Icon(Icons.folder, color: Colors.grey, size: 56),
      );

  Future<void> _seriesMenu(SeriesEntry entry) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: Colors.grey[900],
        title: Text(entry.label.isEmpty
            ? SeriesStore.defaultLabel(entry.path)
            : entry.label),
        children: [
          SimpleDialogOption(
            child: const Text('自定义剧名', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(ctx, 'rename'),
          ),
          SimpleDialogOption(
            child: const Text('移除', style: TextStyle(color: Colors.redAccent)),
            onPressed: () => Navigator.pop(ctx, 'remove'),
          ),
        ],
      ),
    );
    if (choice == 'rename') await _renameSeries(entry);
    if (choice == 'remove') await _removeSeries(entry);
  }

  Widget _buildSeasonList() {
    final seasons = _series?.seasons ?? [];
    if (seasons.isEmpty) {
      return const Center(
        child: Text('该文件夹下未找到季（子文件夹）',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: seasons.length,
      itemBuilder: (context, i) => _seasonCard(seasons[i]),
    );
  }

  Widget _seasonCard(SeasonData season) {
    final cover = season.episodes.isNotEmpty
        ? season.episodes.first.thumbnailPath
        : '';
    return GestureDetector(
      onTap: () => _enterSeason(season),
      onLongPress: () => _seasonMenu(season),
      child: Container(
        color: const Color(0xFF1A1A1A),
        child: Stack(
          fit: StackFit.expand,
          children: [
            cover.isNotEmpty
                ? Image.file(File(cover), fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _folderIcon())
                : _folderIcon(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withAlpha(210), Colors.transparent],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(season.name,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('${season.episodes.length} 集',
                        style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _seasonMenu(SeasonData season) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: Colors.grey[900],
        title: Text(season.name),
        children: [
          SimpleDialogOption(
            child: const Text('自定义季名', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.pop(ctx, 'rename'),
          ),
        ],
      ),
    );
    if (choice == 'rename') await _renameSeason(season);
  }

  Widget _buildEpisodeList() {
    final episodes = _season?.episodes ?? [];
    if (episodes.isEmpty) {
      return const Center(
        child: Text('该季文件夹下未找到视频文件',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: episodes.length,
      itemBuilder: (context, i) {
        final v = episodes[i];
        final progress = _epFraction(v);
        final completed = _epCompleted(v);
        return GestureDetector(
          onLongPress: () => _renameEpisode(v),
          child: VideoGridItem(
            video: v,
            displayName: _epNames[v.filePath] ?? '',
            progress: progress,
            completed: completed,
            onTap: () => _playEpisode(_season!, i),
          ),
        );
      },
    );
  }

  double? _epFraction(LocalVideoModel v) {
    final prog = _epProgress[v.filePath];
    if (prog == null) return null;
    final durMs = prog.durationMs > 0
        ? prog.durationMs
        : v.duration.inMilliseconds;
    if (durMs <= 0) return null;
    return prog.positionMs / durMs;
  }

  bool _epCompleted(LocalVideoModel v) =>
      _epProgress[v.filePath]?.completed ?? false;
}
