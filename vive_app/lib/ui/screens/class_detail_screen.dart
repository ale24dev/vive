import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/database.dart';
import '../../data/storage_service.dart';
import '../../domain/dance_class.dart';
import '../../domain/song.dart';
import '../../domain/storage_location.dart';
import '../theme/vive_theme.dart';

class ClassDetailScreen extends StatefulWidget {
  final ViveDatabase db;
  final DanceClass danceClass;
  final StorageService storage;
  final bool hasSDCard;

  const ClassDetailScreen({
    super.key,
    required this.db,
    required this.danceClass,
    required this.storage,
    this.hasSDCard = false,
  });

  @override
  State<ClassDetailScreen> createState() => _ClassDetailScreenState();
}

class _ClassDetailScreenState extends State<ClassDetailScreen> {
  List<Song> _classSongs = [];
  List<Song> _allSongs = [];
  bool _loading = true;
  final _player = AudioPlayer();
  int? _playingId;
  StreamSubscription? _playerSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    _playerSubscription = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() => _playingId = null);
      }
    });
  }

  @override
  void dispose() {
    _playerSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final classSongs = await widget.db.getSongsForClass(widget.danceClass.id!);
    final allSongs = await widget.db.getAllSongs();
    if (!mounted) return;
    setState(() {
      _classSongs = classSongs;
      _allSongs = allSongs;
      _loading = false;
    });
  }

  Future<void> _addSongs() async {
    final classIds = _classSongs.map((s) => s.id).toSet();
    final available = _allSongs.where((s) => !classIds.contains(s.id)).toList();

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Todas las canciones ya están en esta clase'),
        ),
      );
      return;
    }

    final folders = await widget.storage.getFolders();

    if (!mounted) return;

    final selected = await showModalBottomSheet<List<Song>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _SongPickerWithFolders(
        songs: available,
        folders: folders,
        hasSDCard: widget.hasSDCard,
      ),
    );

    if (selected != null && selected.isNotEmpty) {
      for (final song in selected) {
        await widget.db.addSongToClass(
          widget.danceClass.id!,
          song.id!,
          position: _classSongs.length,
        );
      }
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${selected.length} canción(es) agregada(s)'),
            backgroundColor: ViveTheme.primary,
          ),
        );
      }
    }
  }

  Future<void> _removeSong(Song song) async {
    await widget.db.removeSongFromClass(widget.danceClass.id!, song.id!);
    await _loadData();
  }

  Future<void> _togglePlay(Song song) async {
    if (_playingId == song.id) {
      await _player.stop();
      setState(() => _playingId = null);
    } else {
      await _player.setFilePath(song.filePath);
      await _player.play();
      setState(() => _playingId = song.id);
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.danceClass.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    _formatDate(widget.danceClass.date),
                    style: TextStyle(
                      color: ViveTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _classSongs.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.queue_music_outlined,
                                size: 48,
                                color: ViveTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Sin canciones en esta clase',
                                style: TextStyle(
                                  color: ViveTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: _classSongs.length,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              if (newIndex > oldIndex) newIndex--;
                              final song = _classSongs.removeAt(oldIndex);
                              _classSongs.insert(newIndex, song);
                            });
                            // TODO: persist order
                          },
                          itemBuilder: (context, index) {
                            final song = _classSongs[index];
                            final isPlaying = _playingId == song.id;

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
                              onDismissed: (_) => _removeSong(song),
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
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_handle),
                                ),
                                onTap: () => _togglePlay(song),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'class_detail_add_fab',
        onPressed: _addSongs,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Song picker with folder navigation and storage location filter
class _SongPickerWithFolders extends StatefulWidget {
  final List<Song> songs;
  final List<String> folders;
  final bool hasSDCard;

  const _SongPickerWithFolders({
    required this.songs,
    required this.folders,
    required this.hasSDCard,
  });

  @override
  State<_SongPickerWithFolders> createState() => _SongPickerWithFoldersState();
}

class _SongPickerWithFoldersState extends State<_SongPickerWithFolders> {
  final Set<int> _selectedSongIds = {};
  final TextEditingController _searchController = TextEditingController();
  StorageLocation _filterLocation = StorageLocation.all;
  String? _currentFolder; // null = root
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isSearching => _searchQuery.isNotEmpty;

  /// Songs matching search query (across all folders)
  List<Song> get _searchResults {
    if (!_isSearching) return [];
    final query = _searchQuery.toLowerCase();
    return widget.songs.where((s) {
      if (_filterLocation != StorageLocation.all &&
          s.storageLocation != _filterLocation) {
        return false;
      }
      return s.name.toLowerCase().contains(query);
    }).toList();
  }

  /// Folders matching search query
  List<String> get _searchFolderResults {
    if (!_isSearching) return [];
    final query = _searchQuery.toLowerCase();
    return widget.folders.where((f) {
      final folderName = f.contains('/') ? f.split('/').last : f;
      return folderName.toLowerCase().contains(query);
    }).toList();
  }

  List<Song> get _filteredSongs {
    return widget.songs.where((s) {
      // Filter by storage location
      if (_filterLocation != StorageLocation.all &&
          s.storageLocation != _filterLocation) {
        return false;
      }
      // Filter by current folder
      return s.folder == _currentFolder;
    }).toList();
  }

  List<String> get _currentSubfolders {
    // Get folders for current storage filter
    final foldersForLocation = widget.folders.where((f) {
      if (_filterLocation == StorageLocation.all) return true;
      // Check if any song in this folder matches the location
      return widget.songs.any(
        (s) => s.folder == f && s.storageLocation == _filterLocation,
      );
    }).toList();

    if (_currentFolder == null) {
      // Root: show top-level folders
      return foldersForLocation.where((f) => !f.contains('/')).toList()..sort();
    } else {
      // Show immediate subfolders
      final prefix = '$_currentFolder/';
      return foldersForLocation
          .where(
            (f) =>
                f.startsWith(prefix) &&
                !f.substring(prefix.length).contains('/'),
          )
          .map((f) => f.substring(prefix.length))
          .toList()
        ..sort();
    }
  }

  /// Get all songs in a folder (including subfolders)
  List<Song> _getSongsInFolder(String folder) {
    return widget.songs.where((s) {
      if (_filterLocation != StorageLocation.all &&
          s.storageLocation != _filterLocation) {
        return false;
      }
      if (s.folder == null) return false;
      return s.folder == folder || s.folder!.startsWith('$folder/');
    }).toList();
  }

  /// Count songs in folder (for display)
  int _countSongsInFolder(String folderName) {
    final fullPath = _currentFolder == null
        ? folderName
        : '$_currentFolder/$folderName';
    return _getSongsInFolder(fullPath).length;
  }

  /// Check if all songs in a folder are selected
  bool _isFolderSelected(String fullPath) {
    final songsInFolder = _getSongsInFolder(fullPath);
    if (songsInFolder.isEmpty) return false;
    return songsInFolder.every((s) => _selectedSongIds.contains(s.id));
  }

  /// Check how many songs from folder are selected
  int _selectedCountInFolder(String fullPath) {
    final songsInFolder = _getSongsInFolder(fullPath);
    return songsInFolder.where((s) => _selectedSongIds.contains(s.id)).length;
  }

  void _toggleFolderSelection(String folderName, {String? fullPathOverride}) {
    final fullPath =
        fullPathOverride ??
        (_currentFolder == null ? folderName : '$_currentFolder/$folderName');
    final songsInFolder = _getSongsInFolder(fullPath);
    final isSelected = _isFolderSelected(fullPath);

    setState(() {
      if (isSelected) {
        // Deselect all songs in folder
        for (final song in songsInFolder) {
          _selectedSongIds.remove(song.id);
        }
      } else {
        // Select all songs in folder
        for (final song in songsInFolder) {
          _selectedSongIds.add(song.id!);
        }
      }
    });

    final action = isSelected ? 'deseleccionada(s)' : 'seleccionada(s)';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${songsInFolder.length} canción(es) $action'),
        duration: const Duration(seconds: 1),
        backgroundColor: isSelected
            ? ViveTheme.textSecondary
            : ViveTheme.primary,
      ),
    );
  }

  void _navigateToFolder(String folderName) {
    final fullPath = _currentFolder == null
        ? folderName
        : '$_currentFolder/$folderName';
    setState(() => _currentFolder = fullPath);
  }

  void _navigateUp() {
    if (_currentFolder == null) return;

    if (_currentFolder!.contains('/')) {
      final parts = _currentFolder!.split('/');
      parts.removeLast();
      setState(() => _currentFolder = parts.join('/'));
    } else {
      setState(() => _currentFolder = null);
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  Widget _buildSearchResults() {
    final folderResults = _searchFolderResults;
    final songResults = _searchResults;

    if (folderResults.isEmpty && songResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 48,
              color: ViveTheme.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Sin resultados para "$_searchQuery"',
              style: TextStyle(color: ViveTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        // Folder results
        if (folderResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              'CARPETAS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ViveTheme.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...folderResults.map((folder) {
            final songCount = _getSongsInFolder(folder).length;
            final folderName = folder.contains('/')
                ? folder.split('/').last
                : folder;
            final isSelected = _isFolderSelected(folder);
            final selectedCount = _selectedCountInFolder(folder);
            final hasPartialSelection = selectedCount > 0 && !isSelected;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor: isSelected
                    ? ViveTheme.primary
                    : ViveTheme.primaryPale,
                child: Icon(
                  Icons.folder,
                  color: isSelected ? Colors.white : ViveTheme.primary,
                ),
              ),
              title: Text(
                folderName,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: isSelected ? ViveTheme.primary : null,
                ),
              ),
              subtitle: Text(
                hasPartialSelection
                    ? '$selectedCount/$songCount seleccionadas • $folder'
                    : '$songCount canción(es) • $folder',
                style: TextStyle(
                  color: isSelected
                      ? ViveTheme.primary
                      : ViveTheme.textSecondary,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: Icon(
                  isSelected ? Icons.remove_circle : Icons.add_circle_outline,
                ),
                color: isSelected ? Colors.red.shade400 : ViveTheme.primary,
                tooltip: isSelected ? 'Deseleccionar todo' : 'Seleccionar todo',
                onPressed: () => _toggleFolderSelection(
                  folderName,
                  fullPathOverride: folder,
                ),
              ),
              onTap: () {
                // Navigate to folder and clear search
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                  _currentFolder = folder;
                });
              },
            );
          }),
        ],

        // Song results
        if (songResults.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              'CANCIONES',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ViveTheme.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...songResults.map((song) {
            final isSelected = _selectedSongIds.contains(song.id);
            return CheckboxListTile(
              value: isSelected,
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selectedSongIds.add(song.id!);
                  } else {
                    _selectedSongIds.remove(song.id);
                  }
                });
              },
              secondary: CircleAvatar(
                backgroundColor: isSelected
                    ? ViveTheme.primary
                    : ViveTheme.surface,
                child: Icon(
                  Icons.music_note,
                  color: isSelected ? Colors.white : ViveTheme.textSecondary,
                  size: 20,
                ),
              ),
              title: Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${_formatDuration(song.durationSeconds)}${song.bpm != null ? ' • ${song.bpm} BPM' : ''}${song.folder != null ? ' • ${song.folder}' : ''}',
                style: TextStyle(color: ViveTheme.textSecondary, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              activeColor: ViveTheme.primary,
              checkboxShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = _filteredSongs;
    final subfolders = _currentSubfolders;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: ViveTheme.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Agregar canciones',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: _selectedSongIds.isEmpty
                        ? null
                        : () {
                            final selectedSongs = widget.songs
                                .where((s) => _selectedSongIds.contains(s.id))
                                .toList();
                            Navigator.pop(context, selectedSongs);
                          },
                    child: Text('Agregar (${_selectedSongIds.length})'),
                  ),
                ],
              ),
            ),

            // Storage filter (only show if SD card available)
            if (widget.hasSDCard)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedButton<StorageLocation>(
                  segments: const [
                    ButtonSegment(
                      value: StorageLocation.all,
                      label: Text('Todas'),
                    ),
                    ButtonSegment(
                      value: StorageLocation.internal,
                      label: Text('Interna'),
                    ),
                    ButtonSegment(value: StorageLocation.sd, label: Text('SD')),
                  ],
                  selected: {_filterLocation},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _filterLocation = selected.first;
                      _currentFolder = null; // Reset to root
                    });
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),

            const SizedBox(height: 8),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Buscar canciones o carpetas...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _isSearching
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: ViveTheme.surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              ),
            ),

            const SizedBox(height: 8),

            // Breadcrumb navigation (only when not searching)
            if (_currentFolder != null && !_isSearching)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ViveTheme.primaryPale,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: _navigateUp,
                      tooltip: 'Volver',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _currentFolder!,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 8),
            const Divider(height: 1),

            // Content
            Expanded(
              child: _isSearching
                  ? _buildSearchResults()
                  : (songs.isEmpty && subfolders.isEmpty)
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.folder_off_outlined,
                            size: 48,
                            color: ViveTheme.textSecondary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Sin canciones disponibles',
                            style: TextStyle(color: ViveTheme.textSecondary),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.only(bottom: 20),
                      children: [
                        // Folders
                        ...subfolders.map((folder) {
                          final fullPath = _currentFolder == null
                              ? folder
                              : '$_currentFolder/$folder';
                          final songCount = _countSongsInFolder(folder);
                          final isSelected = _isFolderSelected(fullPath);
                          final selectedCount = _selectedCountInFolder(
                            fullPath,
                          );
                          final hasPartialSelection =
                              selectedCount > 0 && !isSelected;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isSelected
                                  ? ViveTheme.primary
                                  : ViveTheme.primaryPale,
                              child: Icon(
                                Icons.folder,
                                color: isSelected
                                    ? Colors.white
                                    : ViveTheme.primary,
                              ),
                            ),
                            title: Text(
                              folder,
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: isSelected ? ViveTheme.primary : null,
                              ),
                            ),
                            subtitle: Text(
                              hasPartialSelection
                                  ? '$selectedCount/$songCount seleccionadas'
                                  : '$songCount canción(es)',
                              style: TextStyle(
                                color: isSelected
                                    ? ViveTheme.primary
                                    : ViveTheme.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Toggle folder selection
                                IconButton(
                                  icon: Icon(
                                    isSelected
                                        ? Icons.remove_circle
                                        : Icons.add_circle_outline,
                                  ),
                                  color: isSelected
                                      ? Colors.red.shade400
                                      : ViveTheme.primary,
                                  tooltip: isSelected
                                      ? 'Deseleccionar todo'
                                      : 'Seleccionar todo',
                                  onPressed: () =>
                                      _toggleFolderSelection(folder),
                                ),
                                // Navigate into folder
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () => _navigateToFolder(folder),
                          );
                        }),

                        if (subfolders.isNotEmpty && songs.isNotEmpty)
                          const Divider(indent: 16, endIndent: 16),

                        // Songs
                        ...songs.map((song) {
                          final isSelected = _selectedSongIds.contains(song.id);
                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedSongIds.add(song.id!);
                                } else {
                                  _selectedSongIds.remove(song.id);
                                }
                              });
                            },
                            secondary: CircleAvatar(
                              backgroundColor: isSelected
                                  ? ViveTheme.primary
                                  : ViveTheme.surface,
                              child: Icon(
                                Icons.music_note,
                                color: isSelected
                                    ? Colors.white
                                    : ViveTheme.textSecondary,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              '${_formatDuration(song.durationSeconds)}${song.bpm != null ? ' • ${song.bpm} BPM' : ''}',
                              style: TextStyle(
                                color: ViveTheme.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            activeColor: ViveTheme.primary,
                            checkboxShape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          );
                        }),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
