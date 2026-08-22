/// 追剧播放上下文：从追剧页进入播放页时携带，用于驱动「历史记录 + 秒级断点续播」。
///
/// 播放页会据此把每一集的播放进度写回 [SeriesHistoryStore]，并在集与集之间
/// （顺序播放模式）自动把「上次看到」推进到下一集，从而实现「重新打开 App → 进追剧页
/// → 一键从断点继续」。
class SeriesPlayContext {
  final String seriesPath; // 剧文件夹路径
  final String seriesName; // 剧名
  final String seasonPath; // 当前季文件夹路径
  final String seasonName; // 当前季名
  final List<String> episodePaths; // 当前季所有集的视频路径（顺序与播放列表一致）

  const SeriesPlayContext({
    required this.seriesPath,
    required this.seriesName,
    required this.seasonPath,
    required this.seasonName,
    required this.episodePaths,
  });
}
