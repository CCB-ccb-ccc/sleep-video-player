import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../debug/diag.dart';

/// 全局音频服务处理器实例（用 ValueNotifier 包裹，便于播放页在 init 完成后感知）。
/// 说明：audio_service 0.18 起移除了 `AudioService.handler` 静态成员，
/// 改为由 `AudioService.init(...)` 的返回值持有；这里用全局 notifier 中转供播放页访问。
/// 播放页通过 addListener 在初始化完成时自动接管，避免因启动顺序竞争拿到 null 而彻底没声音。
final ValueNotifier<AudioPlayerHandler?> globalAudioHandler =
    ValueNotifier<AudioPlayerHandler?>(null);

/// 音频服务处理器：用 just_audio 播放“同一视频文件”的音频轨道。
///
/// 关键：它运行在 audio_service 提供的 Android 媒体服务（MediaBrowserService）中，
/// 该服务独立于 Flutter 的 Activity —— 因此息屏 / 切后台 / 锁屏时，即使 Activity 被系统回收，
/// 媒体服务仍会继续出声。这正是 video_player（绑定 Activity）在华为上息屏即停的根本解法。
class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  // handleAudioSessionActivation=false：禁止 just_audio 自动处理音频焦点/会话。
  // 否则荣耀/华为息屏或系统通知可能触发焦点丢失，导致音频被自动 pause，
  // 出现“息屏后需在锁屏界面再点播放键”的现象。
  final AudioPlayer _player = AudioPlayer(
    handleAudioSessionActivation: false,
  );
  String? _loadedPath;

  AudioPlayerHandler() {
    // 将 just_audio 的播放状态同步到系统媒体通知（锁屏/通知栏可见）
    _player.playbackEventStream.listen((_) {
      final playing = _player.playing;
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.stop,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[_player.processingState]!,
          playing: playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ),
      );
    });
  }

  /// 加载本地文件（视频文件仅取音频轨道）。同一路径只加载一次。
  Future<Duration?> loadFile(String path) async {
    try {
      if (_loadedPath == path &&
          _player.processingState != ProcessingState.idle) {
        return _player.duration;
      }
      _loadedPath = path;
      final duration = await _player.setAudioSource(AudioSource.file(path));
      mediaItem.add(
        MediaItem(
          id: path,
          album: '助眠播放器',
          title: path.split('/').last,
          duration: duration,
        ),
      );
      diag('loadFile OK file=${path.split('/').last} dur=$duration');
      return duration;
    } catch (e) {
      diag('loadFile FAIL file=${path.split('/').last} err=$e');
      rethrow;
    }
  }

  @override
  Future<void> play() {
    diag('audio play');
    return _player.play();
  }

  @override
  Future<void> pause() {
    diag('audio pause');
    return _player.pause();
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  AudioPlayer get player => _player;
}
