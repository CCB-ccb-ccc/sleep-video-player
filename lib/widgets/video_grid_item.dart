import 'dart:io';
import 'package:flutter/material.dart';
import '../core/video_name_store.dart';
import '../models/local_video_model.dart';

/// 首页网格视频卡片组件（任务 4.3）
class VideoGridItem extends StatelessWidget {
  final LocalVideoModel video;
  final VoidCallback onTap;
  final String displayName; // 视频显示名称（自定义或文件名）

  const VideoGridItem({
    required this.video,
    required this.onTap,
    this.displayName = '',
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final name = displayName.isEmpty
        ? VideoNameStore.defaultName(video.filePath)
        : displayName;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: const Color(0xFF1A1A1A), // 辅助灰（规范 G4）
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 缩略图
            _thumbnail(),
            // 顶部名称条
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withAlpha(170),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // 右下角时长（格式 mm:ss）
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(179),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatDuration(video.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail() {
    if (video.thumbnailPath.isEmpty) {
      return const Center(
        child: Icon(Icons.videocam, color: Colors.grey, size: 40),
      );
    }
    return Image.file(
      File(video.thumbnailPath),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.videocam, color: Colors.grey, size: 40),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
