import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'audio/audio_player_handler.dart';
import 'debug/diag.dart';
import 'models/local_video_model.dart';
import 'pages/home_page.dart';
import 'pages/video_play_page.dart';

Future<void> main() async {
  // 必须在任何插件调用前初始化 Flutter 绑定
  WidgetsFlutterBinding.ensureInitialized();

  // 全局错误兜底：任何 widget 抛错都显示可读错误页，而不是卡在原生开屏/黑屏。
  ErrorWidget.builder = (details) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '运行出错：${details.exception}\n\n请尝试重启应用。',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  };

  // 关键修复（1.10.0）：先启动 UI，确保原生开屏（splash）一定被移除。
  // 之前把 `AudioService.init` 放在 runApp 之前 await —— 一旦它抛错或挂起，
  // runApp 永不执行 → App 永远卡在开屏。现改为 runApp 后立即异步初始化音频服务，
  // 失败也仅降级为「前台 video_player 出声」，绝不阻塞启动。
  runApp(const MyApp());

  _initAudioService();
}

/// 异步、非阻塞地初始化音频服务（独立于 Activity 的 Android 媒体服务）。
/// 失败不影响 App 启动；播放页在 handler 为空时会降级用 video_player 出声（仅前台可用）。
Future<void> _initAudioService() async {
  try {
    globalAudioHandler.value = await AudioService.init(
      builder: () => AudioPlayerHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.sleep.localvideoplayer.audio',
        androidNotificationChannelName: '助眠播放器',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: false,
      ),
    ) as AudioPlayerHandler;
    diag('AudioService.init OK');
  } catch (e, st) {
    globalAudioHandler.value = null;
    diag('AudioService.init FAIL: $e');
    debugPrint('AudioService.init 失败，降级为前台播放: $e\n$st');
  }
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
