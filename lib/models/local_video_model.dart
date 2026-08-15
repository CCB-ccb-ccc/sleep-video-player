/// 本地视频实体模型（任务 3.1）
/// 固定 5 个字段，禁止增删。
class LocalVideoModel {
  final String filePath; // 视频完整本地路径
  final String thumbnailPath; // 缩略图缓存地址
  final Duration duration; // 视频时长
  final String fileName; // 视频文件名
  final DateTime modifyTime; // 文件修改时间

  LocalVideoModel({
    required this.filePath,
    required this.thumbnailPath,
    required this.duration,
    required this.fileName,
    required this.modifyTime,
  });

  /// 本地缓存序列化（JSON）
  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'thumbnailPath': thumbnailPath,
        'durationMs': duration.inMilliseconds,
        'fileName': fileName,
        'modifyTimeMs': modifyTime.millisecondsSinceEpoch,
      };

  factory LocalVideoModel.fromJson(Map<String, dynamic> json) => LocalVideoModel(
        filePath: json['filePath'] as String,
        thumbnailPath: json['thumbnailPath'] as String,
        duration: Duration(milliseconds: json['durationMs'] as int),
        fileName: json['fileName'] as String,
        modifyTime:
            DateTime.fromMillisecondsSinceEpoch(json['modifyTimeMs'] as int),
      );
}
