import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/audio_service.dart';
import '../../domain/song.dart';
import '../theme/vive_theme.dart';

/// A beautiful, full-featured music player widget with playback controls,
/// progress tracking, and playlist navigation.
///
/// Uses the centralized [AudioService] for playback.
class MusicPlayer extends StatefulWidget {
  /// The audio service instance to use
  final AudioService audioService;

  /// Called when the player is closed
  final VoidCallback? onClose;

  const MusicPlayer({super.key, required this.audioService, this.onClose});

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayer>
    with SingleTickerProviderStateMixin {
  // Animation
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // Drag state for slider
  bool _isDragging = false;
  double _dragValue = 0;

  AudioService get _audio => widget.audioService;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _audio.addListener(_onAudioChanged);
  }

  void _onAudioChanged() {
    if (mounted) setState(() {});
  }

  void _setupAnimations() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);
  }

  void _togglePlayPause() {
    _audio.togglePlayPause();
  }

  void _previous() {
    _audio.previous();
  }

  void _next() {
    _audio.next();
  }

  void _seek(double value) {
    _audio.seekFraction(value);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Song? get _currentSong => _audio.currentSong;

  @override
  void dispose() {
    _audio.removeListener(_onAudioChanged);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = _currentSong;
    if (song == null) {
      return const SizedBox.shrink();
    }

    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: screenHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            ViveTheme.primaryPale,
            ViveTheme.background,
            ViveTheme.background,
          ],
          stops: const [0.0, 0.4, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header with close button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    iconSize: 32,
                    color: ViveTheme.textSecondary,
                  ),
                  const Spacer(),
                  Text(
                    '${_audio.currentIndex + 1} / ${_audio.playlist.length}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: ViveTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),

            // Expanded content area
            Expanded(
              child: Column(
                children: [
                  const Spacer(flex: 1),

                  // Large album art
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _audio.isPlaying ? _pulseAnimation.value : 1.0,
                        child: child,
                      );
                    },
                    child: Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            ViveTheme.primary,
                            ViveTheme.primary.withValues(alpha: 0.7),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [
                          BoxShadow(
                            color: ViveTheme.primary.withValues(alpha: 0.4),
                            blurRadius: 30,
                            offset: const Offset(0, 15),
                          ),
                        ],
                      ),
                      child: _audio.isLoading
                          ? const Center(
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.music_note_rounded,
                              color: Colors.white,
                              size: 80,
                            ),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Song info
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        Text(
                          song.name,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: ViveTheme.textPrimary,
                            letterSpacing: -0.5,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (song.bpm != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: ViveTheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.speed_rounded,
                                  size: 16,
                                  color: ViveTheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${song.bpm} BPM',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: ViveTheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const Spacer(flex: 1),

                  // Progress bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: StreamBuilder<Duration>(
                      stream: _audio.positionStream,
                      builder: (context, snapshot) {
                        final position = snapshot.data ?? _audio.position;
                        final duration = _audio.duration;
                        final progress = duration.inMilliseconds > 0
                            ? (position.inMilliseconds /
                                      duration.inMilliseconds)
                                  .clamp(0.0, 1.0)
                            : 0.0;

                        return Column(
                          children: [
                            SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 6,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 8,
                                  elevation: 3,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 20,
                                ),
                                activeTrackColor: ViveTheme.primary,
                                inactiveTrackColor: ViveTheme.primary
                                    .withValues(alpha: 0.2),
                                thumbColor: ViveTheme.primary,
                                overlayColor: ViveTheme.primary.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                              child: Slider(
                                value: _isDragging ? _dragValue : progress,
                                onChangeStart: (value) {
                                  setState(() {
                                    _isDragging = true;
                                    _dragValue = value;
                                  });
                                },
                                onChanged: (value) {
                                  setState(() => _dragValue = value);
                                },
                                onChangeEnd: (value) {
                                  _seek(value);
                                  setState(() => _isDragging = false);
                                },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatDuration(position),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: ViveTheme.textSecondary,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    _formatDuration(duration),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: ViveTheme.textSecondary,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Playback controls - centered
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Previous button
                      _ControlButton(
                        icon: Icons.skip_previous_rounded,
                        onPressed: _audio.hasPrevious ? _previous : null,
                        size: 64,
                      ),

                      const SizedBox(width: 24),

                      // Play/Pause button (large)
                      _PlayPauseButton(
                        isPlaying: _audio.isPlaying,
                        isLoading: _audio.isLoading,
                        onPressed: _togglePlayPause,
                        size: 80,
                      ),

                      const SizedBox(width: 24),

                      // Next button
                      _ControlButton(
                        icon: Icons.skip_next_rounded,
                        onPressed: _audio.hasNext ? _next : null,
                        size: 64,
                      ),
                    ],
                  ),

                  const Spacer(flex: 1),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Individual control button (previous/next)
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  const _ControlButton({required this.icon, this.onPressed, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isEnabled
                ? ViveTheme.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: size * 0.6,
            color: isEnabled
                ? ViveTheme.primary
                : ViveTheme.textSecondary.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}

/// Main play/pause button with animation
class _PlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;
  final double size;

  const _PlayPauseButton({
    required this.isPlaying,
    required this.isLoading,
    required this.onPressed,
    this.size = 72,
  });

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    if (widget.isPlaying) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_PlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;

    return GestureDetector(
      onTap: widget.onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              ViveTheme.primary,
              ViveTheme.primary.withValues(alpha: 0.85),
            ],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: ViveTheme.primary.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: widget.isLoading
              ? SizedBox(
                  width: size * 0.4,
                  height: size * 0.4,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : AnimatedIcon(
                  icon: AnimatedIcons.play_pause,
                  progress: _controller,
                  color: Colors.white,
                  size: size * 0.5,
                ),
        ),
      ),
    );
  }
}

/// Mini player bar that shows at the bottom of screens
/// Uses streams for progress to avoid rebuilding the entire parent widget
class MiniMusicPlayer extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final Stream<Duration> positionStream;
  final Duration duration;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;

  const MiniMusicPlayer({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.positionStream,
    required this.duration,
    required this.onTap,
    required this.onPlayPause,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ViveTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ViveTheme.divider),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress indicator - uses StreamBuilder to avoid parent rebuilds
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: StreamBuilder<Duration>(
                stream: positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  final progress = duration.inMilliseconds > 0
                      ? (position.inMilliseconds / duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                      : 0.0;
                  return LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation(ViveTheme.primary),
                    minHeight: 3,
                  );
                },
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  // Album art
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [ViveTheme.primary, ViveTheme.primaryLight],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.music_note_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Song info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (song.bpm != null)
                          Text(
                            '${song.bpm} BPM',
                            style: TextStyle(
                              fontSize: 12,
                              color: ViveTheme.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Play/pause button
                  IconButton(
                    onPressed: onPlayPause,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_filled_rounded,
                      color: ViveTheme.primary,
                      size: 44,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
