import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'audio/audio_player_handler.dart';
import 'models/local_video_model.dart';
import 'pages/home_page.dart';
import 'pages/video_play_page.dart';

Future<void> main() async {
  // 必须在 AudioService.init 之前初始化 Flutter 绑定
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化音频服务：启动真正的 Android 媒体服务（独立于 Activity），
  // 这是息屏 / 后台能稳定续播的关键引擎。
  await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.sleep.localvideoplayer.audio',
      androidNotificationChannelName: '助眠播放器',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: false,
    ),
  );

  runApp(const MyApp());
}

/// 全局入口与主题
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '助眠播放器',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const HomePage());
          case '/play':
            final args = settings.arguments as Map<String, dynamic>;
            final videos = args['videos'] as List<LocalVideoModel>;
            final index = args['index'] as int;
            return MaterialPageRoute(
              builder: (_) => VideoPlayPage(videos: videos, initialIndex: index),
            );
          default:
            return MaterialPageRoute(builder: (_) => const HomePage());
        }
      },
    );
  }
}
