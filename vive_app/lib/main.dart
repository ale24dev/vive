import 'package:flutter/material.dart';

import 'data/audio_service.dart';
import 'data/database.dart';
import 'data/preferences_service.dart';
import 'data/storage_service.dart';
import 'domain/storage_location.dart';
import 'ui/screens/classes_screen.dart';
import 'ui/screens/download_screen.dart';
import 'ui/screens/songs_screen.dart';
import 'ui/theme/vive_theme.dart';
import 'ui/widgets/music_player.dart';

void main() {
  runApp(const ViveApp());
}

class ViveApp extends StatelessWidget {
  const ViveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vive',
      debugShowCheckedModeBanner: false,
      theme: ViveTheme.theme,
      home: const InitScreen(),
    );
  }
}

/// Initial screen that handles permissions and storage setup
class InitScreen extends StatefulWidget {
  const InitScreen({super.key});

  @override
  State<InitScreen> createState() => _InitScreenState();
}

class _InitScreenState extends State<InitScreen> {
  final _storage = StorageService();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeStorage();
  }

  Future<void> _initializeStorage() async {
    try {
      final success = await _storage.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Timeout inicializando storage');
        },
      );
      if (!mounted) return;

      if (success) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomeScreen(storage: _storage)),
        );
      } else {
        setState(() {
          _loading = false;
          _error = 'No se pudo acceder al almacenamiento';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _initializeStorage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _loading
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 24),
                    Text('Preparando Vive...'),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: ViveTheme.textSecondary,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Error al iniciar',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error ?? 'Error desconocido',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ViveTheme.textSecondary),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final StorageService storage;

  const HomeScreen({super.key, required this.storage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = ViveDatabase();
  final _preferences = PreferencesService();
  final _audioService = AudioService.instance;
  int _currentIndex = 0;
  bool _syncing = false;
  bool _hasSDCard = false;

  final _songsKey = GlobalKey<_SongsTabState>();

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _audioService.addListener(_onAudioStateChanged);
  }

  void _onAudioStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _audioService.removeListener(_onAudioStateChanged);
    super.dispose();
  }

  Future<void> _initializeServices() async {
    await _preferences.initialize();
    _checkSDCardAvailability();
    _syncFiles();
  }

  void _checkSDCardAvailability() {
    final roots = widget.storage.getAvailableRoots();
    final hasSD = roots.any((r) => r.location == StorageLocation.sd);
    if (mounted) {
      setState(() => _hasSDCard = hasSD);
    }
  }

  Future<void> _syncFiles() async {
    setState(() => _syncing = true);

    final files = await widget.storage.scanFiles();
    final result = await _db.syncWithFilesystem(files);

    if (mounted) {
      setState(() => _syncing = false);

      if (result.hasChanges) {
        _songsKey.currentState?.refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sincronizado: ${result.added} nuevas, ${result.removed} eliminadas',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showExpandedPlayer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => MusicPlayer(
        audioService: _audioService,
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasActivePlayer = _audioService.isActive;

    return Scaffold(
      appBar: AppBar(
        title: Text(_getTitle()),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sincronizar',
              onPressed: _syncFiles,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                _SongsTab(
                  key: _songsKey,
                  db: _db,
                  storage: widget.storage,
                  hasSDCard: _hasSDCard,
                  audioService: _audioService,
                ),
                ClassesScreen(
                  db: _db,
                  storage: widget.storage,
                  hasSDCard: _hasSDCard,
                ),
                DownloadScreen(
                  db: _db,
                  storage: widget.storage,
                  preferences: _preferences,
                  hasSDCard: _hasSDCard,
                  onDownloadComplete: () {
                    _syncFiles();
                  },
                ),
              ],
            ),
          ),
          // Mini player - shown when music is active
          if (hasActivePlayer && _audioService.currentSong != null)
            MiniMusicPlayer(
              song: _audioService.currentSong!,
              isPlaying: _audioService.isPlaying,
              positionStream: _audioService.positionStream,
              duration: _audioService.duration,
              onTap: _showExpandedPlayer,
              onPlayPause: _audioService.togglePlayPause,
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.music_note_outlined),
            activeIcon: Icon(Icons.music_note),
            label: 'Canciones',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.event_outlined),
            activeIcon: Icon(Icons.event),
            label: 'Clases',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download_outlined),
            activeIcon: Icon(Icons.download),
            label: 'Descargar',
          ),
        ],
      ),
    );
  }

  String _getTitle() {
    switch (_currentIndex) {
      case 0:
        return 'Canciones';
      case 1:
        return 'Clases';
      case 2:
        return 'Descargar';
      default:
        return 'Vive';
    }
  }
}

// Wrapper to expose refresh method
class _SongsTab extends StatefulWidget {
  final ViveDatabase db;
  final StorageService storage;
  final bool hasSDCard;
  final AudioService audioService;

  const _SongsTab({
    super.key,
    required this.db,
    required this.storage,
    required this.audioService,
    this.hasSDCard = false,
  });

  @override
  State<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends State<_SongsTab> {
  void refresh() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SongsScreen(
      key: ValueKey(DateTime.now()),
      db: widget.db,
      storage: widget.storage,
      hasSDCard: widget.hasSDCard,
      audioService: widget.audioService,
    );
  }
}
