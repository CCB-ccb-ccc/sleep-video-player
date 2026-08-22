import 'local_video_model.dart';

/// 追剧模块的数据模型。
///
/// 结构：一部「剧」(SeriesData) = 一个大文件夹；
/// 一部剧包含若干「季」(SeasonData) = 大文件夹下的子文件夹；
/// 一季包含若干「集」(LocalVideoModel) = 该季文件夹下的视频文件。

/// 一部剧（对应用户在追剧页手动选择的大文件夹）。
class SeriesData {
  final String path; // 大文件夹完整路径
  final String name; // 剧名（自定义名或文件夹名）
  final List<SeasonData> seasons; // 各季（子文件夹）

  SeriesData({
    required this.path,
    required this.name,
    required this.seasons,
  });
}

/// 一季（对应大文件夹下的子文件夹）。
class SeasonData {
  final String path; // 季文件夹完整路径
  final String name; // 季名（自定义名或文件夹名）
  final List<LocalVideoModel> episodes; // 该季下的视频（按文件名数字升序）

  SeasonData({
    required this.path,
    required this.name,
    required this.episodes,
  });
}
