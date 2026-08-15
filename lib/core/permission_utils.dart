import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// 权限工具类（任务 2）
/// 负责请求并校验本地视频扫描所需的存储权限。
class PermissionUtils {
  /// 请求存储权限。
  /// Android 11+(API30+) 需“所有文件访问”权限(MANAGE_EXTERNAL_STORAGE)才能全盘遍历；
  /// 低版本使用 READ_EXTERNAL_STORAGE / READ_MEDIA_VIDEO。
  /// 返回 true 表示已获得足够权限。
  static Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) {
      // 本应用仅适配 Android（规范 G1），非 Android 平台直接视为通过。
      return true;
    }

    // 1) 优先尝试“所有文件访问”（Android 11+ 全盘遍历必须）
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;
    final manageReq = await Permission.manageExternalStorage.request();
    if (manageReq.isGranted) return true;

    // 2) 退回：媒体视频权限（Android 13+）/ 旧版存储权限
    final videosReq = await Permission.videos.request();
    if (videosReq.isGranted) return true;
    final storageReq = await Permission.storage.request();
    return storageReq.isGranted;
  }
}
