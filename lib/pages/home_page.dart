import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'settings_page.dart';
import 'video_list_page.dart';

/// 首页容器：底部导航栏在「播放」与「设置」之间切换。
/// 使用 IndexedStack 让两个页面都保持挂载，列表页状态不丢失。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 请求通知权限：音频服务（后台续播）依赖前台媒体通知，
    // Android 13+ 必须获授权，否则通知被禁、媒体前台服务会被系统杀。
    Permission.notification.request();
  }

  // 由首页持有，切换 tab 时传递给列表页（用于「去设置」空态按钮）
  void _goSettings() => setState(() => _tab = 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // IndexedStack：两个页面常驻，避免来回切换时重新加载
      body: IndexedStack(
        index: _tab,
        children: [
          VideoListPage(onGoSettings: _goSettings),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.grey,
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.play_circle_fill),
            label: '播放',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
