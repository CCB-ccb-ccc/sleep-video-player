import 'package:flutter/material.dart';
import 'models/local_video_model.dart';
import 'pages/video_list_page.dart';
import 'pages/video_play_page.dart';

void main() {
  runApp(const MyApp());
}

/// 全局入口与主题（任务 6）
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '助眠播放器',
      // 全局深色黑色主题（任务 6.1）：主底色 #000000，辅助灰 #1A1A1A（规范 G4）
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      initialRoute: '/',
      // 路由栈统一管理：命名路由，播放页返回用 pop（任务 6.3）
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
                builder: (_) => const VideoListPage());
          case '/play':
            final args = settings.arguments as Map<String, dynamic>;
            final videos = args['videos'] as List<LocalVideoModel>;
            final index = args['index'] as int;
            return MaterialPageRoute(
              builder: (_) =>
                  VideoPlayPage(videos: videos, initialIndex: index),
            );
          default:
            return MaterialPageRoute(
                builder: (_) => const VideoListPage());
        }
      },
    );
  }
}
