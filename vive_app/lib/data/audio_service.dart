import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../domain/song.dart';

/// Centralized audio playback service.
///
/// Manages a single [AudioPlayer] instance across the entire app,
/// providing playlist support and playback controls.
class AudioService extends ChangeNotifier {
  static AudioService? _instance;
  static AudioService get instance => _instance ??= AudioService._();

  AudioService._() {
    _setupListeners();
  }

  final AudioPlayer _player = AudioPlayer();

  // Current playback state
  List<Song> _playlist = [];
  int _currentIndex = -1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isLoading = false;

  // Subscriptions
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;

  // Stream controller for position updates (separate from main state changes)
  final _positionController = StreamController<Duration>.broadcast();

  /// Stream of position updates - use this for progress bars to avoid
  /// rebuilding entire widgets on every tick
  Stream<Duration> get positionStream => _positionController.stream;

  // Getters
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Song? get currentSong =>
      _currentIndex >= 0 && _currentIndex < _playlist.length
      ? _playlist[_currentIndex]
      : null;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  bool get hasNext => _currentIndex < _playlist.length - 1;
  bool get hasPrevious => _currentIndex > 0 || _position.inSeconds > 3;

  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  /// Whether a song is currently active (playing or paused with a song loaded)
  bool get isActive => currentSong != null;

  void _setupListeners() {
    _positionSub = _player.positionStream.listen((pos) {
      _position = pos;
      // Use stream for position updates - doesn't trigger full rebuilds
      _positionController.add(pos);
    });

    _durationSub = _player.durationStream.listen((dur) {
      if (dur != null) {
        _duration = dur;
        notifyListeners();
      }
    });

    _stateSub = _player.playerStateStream.listen((state) {
      final wasPlaying = _isPlaying;
      final wasLoading = _isLoading;

      _isPlaying = state.playing;
      _isLoading =
          state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering;

      // Only notify when state actually changes
      if (wasPlaying != _isPlaying || wasLoading != _isLoading) {
        notifyListeners();
      }

      // Auto-advance to next song when completed
      if (state.processingState == ProcessingState.completed) {
        next();
      }
    });
  }

  /// Play a single song
  Future<void> playSong(Song song) async {
    await playPlaylist([song], startIndex: 0);
  }

  /// Play a playlist starting at the given index
  Future<void> playPlaylist(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;

    _playlist = List.from(songs);
    _currentIndex = startIndex.clamp(0, songs.length - 1);
    await _loadAndPlay();
  }

  /// Add songs to the current playlist
  void addToPlaylist(List<Song> songs) {
    _playlist.addAll(songs);
    notifyListeners();
  }

  /// Clear the current playlist and stop playback
  Future<void> clearPlaylist() async {
    await stop();
    _playlist = [];
    _currentIndex = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
  }

  Future<void> _loadAndPlay() async {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) return;

    _isLoading = true;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();

    try {
      final song = _playlist[_currentIndex];
      await _player.setFilePath(song.filePath);
      await _player.play();
    } catch (e) {
      debugPrint('Error loading song: $e');
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Toggle play/pause
  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  /// Play
  Future<void> play() async {
    await _player.play();
  }

  /// Pause
  Future<void> pause() async {
    await _player.pause();
  }

  /// Stop playback
  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
    notifyListeners();
  }

  /// Go to previous song (or restart if > 3 seconds in)
  Future<void> previous() async {
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
    } else if (_currentIndex > 0) {
      _currentIndex--;
      await _loadAndPlay();
    }
  }

  /// Go to next song
  Future<void> next() async {
    if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
      await _loadAndPlay();
    } else {
      // End of playlist
      await stop();
      await seek(Duration.zero);
    }
  }

  /// Jump to a specific song in the playlist
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;
    await _loadAndPlay();
  }

  /// Seek to a specific position
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  /// Seek to a position as a fraction (0.0 to 1.0)
  Future<void> seekFraction(double fraction) async {
    final position = Duration(
      milliseconds: (fraction * _duration.inMilliseconds).round(),
    );
    await seek(position);
  }

  /// Check if a specific song is currently playing
  bool isSongPlaying(Song song) {
    return currentSong?.id == song.id && _isPlaying;
  }

  /// Check if a specific song is the current song (playing or paused)
  bool isSongActive(Song song) {
    return currentSong?.id == song.id;
  }

  /// Get audio duration from a file path without playing it
  /// Returns null if the file cannot be loaded
  static Future<Duration?> getDuration(String filePath) async {
    try {
      final player = AudioPlayer();
      final duration = await player.setFilePath(filePath);
      await player.dispose();
      return duration;
    } catch (e) {
      debugPrint('Error getting duration for $filePath: $e');
      return null;
    }
  }

  /// Format a duration as mm:ss
  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _positionController.close();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
