import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/audio_service.dart';
import '../../data/database.dart';
import '../../data/storage_service.dart';
import '../../domain/song.dart';
import '../../domain/storage_location.dart';
import '../theme/vive_theme.dart';
import 'trim_screen.dart';

class SongsScreen extends StatefulWidget {
  final ViveDatabase db;
  final StorageService storage;
  final bool hasSDCard;
  final AudioService audioService;

  const SongsScreen({
    super.key,
    required this.db,
    required this.storage,
    required this.audioService,
    this.hasSDCard = false,
  });

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  List<Song> _songs = [];
  List<FolderInfo> _folders = [];
  String? _currentFolder; // null = root
  bool _loading = true;
  StorageLocation _filterLocation = StorageLocation.all;

  AudioService get _audioService => widget.audioService;

  @override
  void initState() {
    super.initState();
    _loadData();
    _audioService.addListener(_onAudioChanged);
  }

  void _onAudioChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _audioService.removeListener(_onAudioChanged);
    super.dispose();
  }

  Future<void> _loadData() async {
    final songs = await widget.db.getSongsByStorageLocation(_filterLocation);
    final folders = await widget.storage.getFoldersWithLocation(
      location: _filterLocation == StorageLocation.all ? null : _filterLocation,
    );
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _folders = folders;
      _loading = false;
    });
  }

  void _onFilterChanged(StorageLocation? location) {
    if (location == null || location == _filterLocation) return;
    setState(() {
      _filterLocation = location;
      _loading = true;
      _currentFolder = null; // Reset folder navigation when changing filter
    });
    _loadData();
  }

  List<Song> get _currentSongs {
    return _songs.where((s) => s.folder == _currentFolder).toList();
  }

  List<FolderInfo> get _currentSubfolders {
    if (_currentFolder == null) {
      // Root: show top-level folders only
      return _folders.where((f) => !f.path.contains('/')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } else {
      // Show immediate subfolders
      final prefix = '$_currentFolder/';
      return _folders
          .where(
            (f) =>
                f.path.startsWith(prefix) &&
                !f.path.substring(prefix.length).contains('/'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    }
  }

  Future<void> _togglePlay(Song song) async {
    if (_audioService.isSongActive(song)) {
      // Same song - toggle play/pause
      await _audioService.togglePlayPause();
    } else {
      // Different song - play the current folder as a playlist
      final songs = _currentSongs;
      final index = songs.indexWhere((s) => s.id == song.id);
      if (index >= 0) {
        await _audioService.playPlaylist(songs, startIndex: index);
      } else {
        // Fallback: play single song
        await _audioService.playSong(song);
      }
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();

    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Nueva carpeta',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                hintText: 'Ej: Bachata',
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(context, name);
              },
              child: const Text('Crear'),
            ),
          ],
        ),
      ),
    );

    if (name != null) {
      final fullPath = _currentFolder == null ? name : '$_currentFolder/$name';
      // Use selected filter location, default to internal if "all" is selected
      final targetLocation = _filterLocation == StorageLocation.all
          ? StorageLocation.internal
          : _filterLocation;
      final success = await widget.storage.createFolder(
        fullPath,
        location: targetLocation,
      );
      if (success) {
        await _loadData();
      }
    }
  }

  Future<void> _showSongActions(Song song) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: ViveTheme.primaryPale,
                  child: const Icon(Icons.music_note, color: ViveTheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    song.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Editar'),
            subtitle: const Text('Cambiar nombre y BPM'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Mover a carpeta'),
            subtitle: const Text('Organizar en otra ubicación'),
            onTap: () => Navigator.pop(context, 'move'),
          ),
          ListTile(
            leading: const Icon(Icons.content_cut),
            title: const Text('Recortar'),
            subtitle: const Text('Cortar una sección del audio'),
            onTap: () => Navigator.pop(context, 'trim'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );

    if (result == 'edit') {
      await _editSongDetails(song);
    } else if (result == 'move') {
      await _moveSong(song);
    } else if (result == 'trim') {
      await _trimSong(song);
    }
  }

  Future<void> _editSongDetails(Song song) async {
    final nameController = TextEditingController(text: song.name);
    final bpmController = TextEditingController(
      text: song.bpm?.toString() ?? '',
    );

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Editar canción',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                hintText: 'Nombre de la canción',
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: bpmController,
              decoration: const InputDecoration(
                labelText: 'BPM',
                hintText: 'Ej: 120',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(context, true);
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final updated = song.copyWith(
        name: nameController.text.trim(),
        bpm: int.tryParse(bpmController.text),
      );
      await widget.db.updateSong(updated);
      await _loadData();
    }
  }

  Future<void> _trimSong(Song song) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TrimScreen(song: song, db: widget.db, storage: widget.storage),
      ),
    );
    if (result == true) {
      await _loadData();
    }
  }

  Future<void> _moveSong(Song song) async {
    // Get folder paths for move dialog
    final folderPaths = _folders.map((f) => f.path).toList();

    final selected = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Mover a carpeta',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: folderPaths.length + 1, // +1 for root
              itemBuilder: (context, index) {
                final isRoot = index == 0;
                final folder = isRoot ? null : folderPaths[index - 1];
                final isCurrentFolder = song.folder == folder;

                return ListTile(
                  leading: Icon(
                    isRoot ? Icons.home_outlined : Icons.folder_outlined,
                    color: isCurrentFolder ? ViveTheme.primary : null,
                  ),
                  title: Text(
                    isRoot ? 'Raíz' : folder!,
                    style: TextStyle(
                      color: isCurrentFolder ? ViveTheme.primary : null,
                      fontWeight: isCurrentFolder ? FontWeight.w600 : null,
                    ),
                  ),
                  trailing: isCurrentFolder
                      ? const Icon(Icons.check, color: ViveTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, isRoot ? null : folder),
                );
              },
            ),
          ),
        ],
      ),
    );

    // null means cancelled, empty string would be root
    if (selected != song.folder) {
      final newPath = await widget.storage.moveFile(song.filePath, selected);
      if (newPath != null) {
        await widget.db.updateSongPath(song.id!, newPath, selected);
        await _loadData();
        if (mounted) {
          final destino = selected ?? 'Raíz';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Movido a $destino'),
              backgroundColor: ViveTheme.primary,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<bool> _confirmDelete(Song song) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar canción'),
        content: Text(
          '¿Eliminar "${song.name}"?\n\nEsto también borrará el archivo.',
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eliminar'),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _deleteSong(Song song) async {
    if (_audioService.isSongActive(song)) {
      await _audioService.stop();
    }
    await widget.storage.deleteFile(song.filePath);
    await widget.db.deleteSong(song.id!);
    await _loadData();
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  void _navigateToFolder(String? folder) {
    setState(() => _currentFolder = folder);
  }

  void _navigateUp() {
    if (_currentFolder == null) return;

    if (_currentFolder!.contains('/')) {
      // Go to parent folder
      final parts = _currentFolder!.split('/');
      parts.removeLast();
      setState(() => _currentFolder = parts.join('/'));
    } else {
      // Go to root
      setState(() => _currentFolder = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final songs = _currentSongs;
    final subfolders = _currentSubfolders;
    final isEmpty = songs.isEmpty && subfolders.isEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        heroTag: 'songs_create_folder_fab',
        onPressed: _createFolder,
        backgroundColor: ViveTheme.primary,
        child: const Icon(Icons.create_new_folder, color: Colors.white),
      ),
      body: Column(
        children: [
          // Storage filter (only show if SD card available)
          if (widget.hasSDCard)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<StorageLocation>(
                segments: const [
                  ButtonSegment(
                    value: StorageLocation.all,
                    label: Text('Todas'),
                    icon: Icon(Icons.storage),
                  ),
                  ButtonSegment(
                    value: StorageLocation.internal,
                    label: Text('Interna'),
                    icon: Icon(Icons.phone_android),
                  ),
                  ButtonSegment(
                    value: StorageLocation.sd,
                    label: Text('SD'),
                    icon: Icon(Icons.sd_card),
                  ),
                ],
                selected: {_filterLocation},
                onSelectionChanged: (selected) =>
                    _onFilterChanged(selected.first),
                style: ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),

          // Breadcrumb / navigation bar
          if (_currentFolder != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: ViveTheme.primaryPale,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _navigateUp,
                    tooltip: 'Volver',
                  ),
                  Expanded(
                    child: Text(
                      _currentFolder!,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Content
          Expanded(
            child: isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.music_off_outlined,
                          size: 64,
                          color: ViveTheme.textSecondary.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _currentFolder == null
                              ? 'Sin canciones'
                              : 'Carpeta vacía',
                          style: TextStyle(
                            color: ViveTheme.textSecondary,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _currentFolder == null
                              ? 'Descargá música para comenzar'
                              : 'Mové canciones aquí',
                          style: TextStyle(
                            color: ViveTheme.textSecondary.withValues(
                              alpha: 0.7,
                            ),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadData,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 80),
                      children: [
                        // Subfolders first
                        ...subfolders.map(
                          (folder) => ListTile(
                            leading: CircleAvatar(
                              backgroundColor: ViveTheme.primaryPale,
                              child: const Icon(
                                Icons.folder,
                                color: ViveTheme.primary,
                              ),
                            ),
                            title: Text(
                              folder.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: _filterLocation == StorageLocation.all
                                ? Text(
                                    folder.locationLabel,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: ViveTheme.textSecondary,
                                    ),
                                  )
                                : null,
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              final fullPath = _currentFolder == null
                                  ? folder.path
                                  : '$_currentFolder/${folder.name}';
                              _navigateToFolder(fullPath);
                            },
                          ),
                        ),

                        if (subfolders.isNotEmpty && songs.isNotEmpty)
                          const Divider(),

                        // Songs
                        ...songs.map((song) {
                          final isPlaying = _audioService.isSongPlaying(song);
                          return Dismissible(
                            key: ValueKey(song.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Colors.red.shade100,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: const Icon(
                                Icons.delete,
                                color: Colors.red,
                              ),
                            ),
                            confirmDismiss: (_) => _confirmDelete(song),
                            onDismissed: (_) => _deleteSong(song),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isPlaying
                                    ? ViveTheme.primary
                                    : ViveTheme.primaryPale,
                                child: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: isPlaying
                                      ? Colors.white
                                      : ViveTheme.primary,
                                ),
                              ),
                              title: Text(
                                song.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                '${_formatDuration(song.durationSeconds)}${song.bpm != null ? ' • ${song.bpm} BPM' : ''}',
                                style: TextStyle(
                                  color: ViveTheme.textSecondary,
                                ),
                              ),
                              trailing: song.bpm != null
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: ViveTheme.primaryPale,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '${song.bpm}',
                                        style: TextStyle(
                                          color: ViveTheme.primary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                        ),
                                      ),
                                    )
                                  : null,
                              onTap: () => _togglePlay(song),
                              onLongPress: () => _showSongActions(song),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
