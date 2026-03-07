import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/audio_service.dart';
import '../../data/database.dart';
import '../../data/storage_service.dart';
import '../../data/trim_service.dart';
import '../../domain/song.dart';
import '../theme/vive_theme.dart';

class TrimScreen extends StatefulWidget {
  final Song song;
  final ViveDatabase db;
  final StorageService storage;

  const TrimScreen({
    super.key,
    required this.song,
    required this.db,
    required this.storage,
  });

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> with TickerProviderStateMixin {
  final _player = AudioPlayer();
  final _trimService = TrimService();

  late int _startMs;
  late int _endMs;
  late int _totalDurationMs;

  bool _isPlaying = false;
  bool _isProcessing = false;
  bool _wasMainPlayerPlaying = false;

  StreamSubscription? _playerSubscription;
  StreamSubscription? _positionSubscription;
  int _currentPositionMs = 0;

  // Animation for waveform
  late AnimationController _waveAnimController;

  // Simulated waveform data
  late List<double> _waveformData;

  @override
  void initState() {
    super.initState();
    _totalDurationMs = widget.song.durationSeconds * 1000;
    _startMs = 0;
    _endMs = _totalDurationMs;

    // Generate random waveform for visual effect
    final random = math.Random(widget.song.name.hashCode);
    _waveformData = List.generate(60, (_) => 0.3 + random.nextDouble() * 0.7);

    _waveAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _setupPlayer();
  }

  Future<void> _setupPlayer() async {
    try {
      await _player.setFilePath(widget.song.filePath);

      final duration = _player.duration;
      if (duration != null) {
        setState(() {
          _totalDurationMs = duration.inMilliseconds;
          _endMs = _totalDurationMs;
        });
      }
    } catch (e) {
      debugPrint('Error setting up player: $e');
    }

    _playerSubscription = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() => _isPlaying = false);
      }
    });

    _positionSubscription = _player.positionStream.listen((position) {
      if (!mounted) return;
      final posMs = position.inMilliseconds;

      if (!mounted) return;
      setState(() => _currentPositionMs = posMs);

      if (_isPlaying && posMs >= _endMs) {
        _player.pause();
        if (!mounted) return;
        setState(() => _isPlaying = false);
      }
    });
  }

  @override
  void dispose() {
    _playerSubscription?.cancel();
    _positionSubscription?.cancel();
    _waveAnimController.stop();
    _waveAnimController.dispose();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePreview() async {
    HapticFeedback.lightImpact();
    if (_isPlaying) {
      await _player.pause();
      if (!mounted) return;
      setState(() => _isPlaying = false);
    } else {
      // Pause the main audio service before playing locally
      final mainPlayer = AudioService.instance;
      if (mainPlayer.isPlaying) {
        _wasMainPlayerPlaying = true;
        await mainPlayer.pause();
      }

      await _player.seek(Duration(milliseconds: _startMs));
      await _player.play();
      if (!mounted) return;
      setState(() => _isPlaying = true);
    }
  }

  String _formatTime(int ms) {
    final totalSeconds = ms ~/ 1000;
    final min = totalSeconds ~/ 60;
    final sec = totalSeconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  String _formatTimeDetailed(int ms) {
    final totalSeconds = ms ~/ 1000;
    final millis = (ms % 1000) ~/ 100;
    final min = totalSeconds ~/ 60;
    final sec = totalSeconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}.$millis';
  }

  void _showSaveOptions() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ViveTheme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Guardar recorte',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _formatTimeDetailed(_endMs - _startMs),
              style: TextStyle(
                fontSize: 14,
                color: ViveTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            _SaveOptionTile(
              icon: Icons.add_circle_outline,
              iconColor: ViveTheme.primary,
              title: 'Guardar como nueva',
              subtitle: 'El original se mantiene intacto',
              onTap: () {
                Navigator.pop(context);
                _saveAsNew();
              },
            ),
            const SizedBox(height: 12),
            _SaveOptionTile(
              icon: Icons.sync_alt,
              iconColor: Colors.orange.shade600,
              title: 'Reemplazar original',
              subtitle: 'Acción irreversible',
              onTap: () {
                Navigator.pop(context);
                _confirmReplaceOriginal();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAsNew() async {
    setState(() => _isProcessing = true);

    try {
      await _player.stop();
      setState(() => _isPlaying = false);

      final originalPath = widget.song.filePath;
      final originalDir = originalPath.substring(
        0,
        originalPath.lastIndexOf('/'),
      );
      final originalName = widget.song.name;
      final extension = originalPath.split('.').last;
      final outputName = '$originalName (recortada).$extension';
      final outputPath = '$originalDir/$outputName';

      final success = await _trimService.trimAudio(
        originalPath,
        outputPath,
        _startMs,
        _endMs,
      );

      if (!success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al recortar el audio'),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isProcessing = false);
        return;
      }

      final newDurationSeconds = (_endMs - _startMs) ~/ 1000;
      final newSong = Song(
        name: '$originalName (recortada)',
        durationSeconds: newDurationSeconds,
        filePath: outputPath,
        folder: widget.song.folder,
        createdAt: DateTime.now(),
        storageLocation: widget.song.storageLocation,
        bpm: widget.song.bpm,
      );

      await widget.db.insertSong(newSong);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Canción guardada'),
            backgroundColor: ViveTheme.primary,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Error saving trimmed song: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _confirmReplaceOriginal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reemplazar original'),
        content: const Text(
          '¿Reemplazar la canción original?\n\nEsta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reemplazar'),
          ),
        ],
      ),
    );

    if (confirmed == true) await _replaceOriginal();
  }

  Future<void> _replaceOriginal() async {
    setState(() => _isProcessing = true);

    try {
      await _player.stop();
      setState(() => _isPlaying = false);

      final originalPath = widget.song.filePath;
      final originalDir = originalPath.substring(
        0,
        originalPath.lastIndexOf('/'),
      );
      final extension = originalPath.split('.').last;
      final tempPath = '$originalDir/.temp_trim.$extension';

      final success = await _trimService.trimAudio(
        originalPath,
        tempPath,
        _startMs,
        _endMs,
      );

      if (!success) {
        try {
          await File(tempPath).delete();
        } catch (_) {}

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error al recortar el audio'),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isProcessing = false);
        return;
      }

      await File(originalPath).delete();
      await File(tempPath).rename(originalPath);

      final newDurationSeconds = (_endMs - _startMs) ~/ 1000;
      final updatedSong = widget.song.copyWith(
        durationSeconds: newDurationSeconds,
      );
      await widget.db.updateSong(updatedSong);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Canción actualizada'),
            backgroundColor: ViveTheme.primary,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Error replacing original: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectionDurationMs = _endMs - _startMs;
    final hasValidSelection = selectionDurationMs >= 1000;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                ),
              ],
            ),
            child: const Icon(Icons.close, size: 20),
          ),
          onPressed: _isProcessing ? null : () => Navigator.pop(context),
        ),
        title: const Text(
          'Recortar audio',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
      ),
      body: _isProcessing
          ? _buildProcessingState()
          : _buildContent(hasValidSelection),
    );
  }

  Widget _buildProcessingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: ViveTheme.primary.withValues(alpha: 0.2),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const CircularProgressIndicator(
              strokeWidth: 3,
              color: ViveTheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Procesando audio...',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Esto puede tomar unos segundos',
            style: TextStyle(fontSize: 14, color: ViveTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool hasValidSelection) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 16),
                // Song info card
                _buildSongInfoCard(),
                const SizedBox(height: 32),
                // Waveform & Timeline
                _buildWaveformTimeline(),
                const SizedBox(height: 24),
                // Selection info
                _buildSelectionInfo(),
                const SizedBox(height: 32),
                // Preview button
                _buildPreviewButton(hasValidSelection),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
        // Bottom action
        _buildBottomAction(hasValidSelection),
      ],
    );
  }

  Widget _buildSongInfoCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  ViveTheme.primary,
                  ViveTheme.primary.withValues(alpha: 0.7),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.song.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: ViveTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(_totalDurationMs),
                      style: TextStyle(
                        fontSize: 13,
                        color: ViveTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.song.bpm != null) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: ViveTheme.primaryPale,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${widget.song.bpm} BPM',
                          style: TextStyle(
                            fontSize: 11,
                            color: ViveTheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveformTimeline() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Waveform
          SizedBox(
            height: 120,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return _buildWaveform(width);
              },
            ),
          ),
          const SizedBox(height: 16),
          // Time markers
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '0:00',
                style: TextStyle(
                  fontSize: 12,
                  color: ViveTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                _formatTime(_totalDurationMs),
                style: TextStyle(
                  fontSize: 12,
                  color: ViveTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWaveform(double width) {
    final startFraction = _totalDurationMs > 0
        ? _startMs / _totalDurationMs
        : 0.0;
    final endFraction = _totalDurationMs > 0 ? _endMs / _totalDurationMs : 1.0;
    final playheadFraction = _totalDurationMs > 0
        ? _currentPositionMs / _totalDurationMs
        : 0.0;

    return Stack(
      children: [
        // Waveform bars
        AnimatedBuilder(
          animation: _waveAnimController,
          builder: (context, _) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(_waveformData.length, (i) {
                final barFraction = i / _waveformData.length;
                final isInSelection =
                    barFraction >= startFraction && barFraction <= endFraction;
                final animValue = _isPlaying ? _waveAnimController.value : 0.0;
                final height =
                    _waveformData[i] *
                    80 *
                    (1 + animValue * 0.1 * (_isPlaying ? 1 : 0));

                return Container(
                  width: (width - 40) / _waveformData.length - 2,
                  height: height,
                  decoration: BoxDecoration(
                    color: isInSelection
                        ? ViveTheme.primary.withValues(alpha: 0.8)
                        : ViveTheme.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            );
          },
        ),

        // Start handle
        Positioned(
          left: width * startFraction - 14,
          top: 0,
          bottom: 0,
          child: GestureDetector(
            onHorizontalDragUpdate: (details) {
              HapticFeedback.selectionClick();
              final newFraction = (details.globalPosition.dx - 44) / width;
              final newMs = (newFraction * _totalDurationMs).round();
              final maxStart = _endMs - 1000;
              setState(() => _startMs = newMs.clamp(0, maxStart));
            },
            child: _buildHandle(ViveTheme.primary, Icons.first_page),
          ),
        ),

        // End handle
        Positioned(
          left: width * endFraction - 14,
          top: 0,
          bottom: 0,
          child: GestureDetector(
            onHorizontalDragUpdate: (details) {
              HapticFeedback.selectionClick();
              final newFraction = (details.globalPosition.dx - 44) / width;
              final newMs = (newFraction * _totalDurationMs).round();
              final minEnd = _startMs + 1000;
              setState(() => _endMs = newMs.clamp(minEnd, _totalDurationMs));
            },
            child: _buildHandle(Colors.red.shade400, Icons.last_page),
          ),
        ),

        // Playhead
        if (_isPlaying || _currentPositionMs > _startMs)
          Positioned(
            left: width * playheadFraction - 1,
            top: 0,
            bottom: 0,
            child: Container(
              width: 2,
              decoration: BoxDecoration(
                color: ViveTheme.textPrimary,
                borderRadius: BorderRadius.circular(1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHandle(Color color, IconData icon) {
    return Container(
      width: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(child: Icon(icon, color: Colors.white, size: 18)),
    );
  }

  Widget _buildSelectionInfo() {
    final selectionMs = _endMs - _startMs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: ViveTheme.primaryPale,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildTimeLabel(
            'Inicio',
            _formatTimeDetailed(_startMs),
            ViveTheme.primary,
          ),
          Container(width: 1, height: 40, color: ViveTheme.primaryLight),
          _buildTimeLabel(
            'Fin',
            _formatTimeDetailed(_endMs),
            Colors.red.shade400,
          ),
          Container(width: 1, height: 40, color: ViveTheme.primaryLight),
          _buildTimeLabel(
            'Duración',
            _formatTime(selectionMs),
            ViveTheme.textPrimary,
          ),
        ],
      ),
    );
  }

  Widget _buildTimeLabel(String label, String value, Color valueColor) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: ViveTheme.textSecondary,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            color: valueColor,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewButton(bool hasValidSelection) {
    return GestureDetector(
      onTap: hasValidSelection ? _togglePreview : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hasValidSelection ? ViveTheme.primary : ViveTheme.divider,
          boxShadow: hasValidSelection
              ? [
                  BoxShadow(
                    color: ViveTheme.primary.withValues(alpha: 0.4),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Icon(
          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 40,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildBottomAction(bool hasValidSelection) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: FilledButton.icon(
          onPressed: hasValidSelection ? _showSaveOptions : null,
          icon: const Icon(Icons.content_cut_rounded),
          label: const Text('Guardar recorte'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveOptionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SaveOptionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: ViveTheme.divider),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: ViveTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: ViveTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
