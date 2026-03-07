import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/dance_class.dart';
import '../domain/song.dart';
import '../domain/storage_location.dart';
import 'storage_service.dart';

class ViveDatabase {
  static Database? _db;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), 'vive.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE songs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            bpm INTEGER,
            duration_seconds INTEGER NOT NULL,
            file_path TEXT NOT NULL UNIQUE,
            folder TEXT,
            created_at TEXT NOT NULL,
            storage_location TEXT DEFAULT 'internal'
          )
        ''');

        await db.execute('''
          CREATE TABLE classes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            date TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE class_songs (
            class_id INTEGER NOT NULL,
            song_id INTEGER NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (class_id, song_id),
            FOREIGN KEY (class_id) REFERENCES classes(id) ON DELETE CASCADE,
            FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_class_songs_class ON class_songs(class_id)',
        );
        await db.execute(
          'CREATE INDEX idx_class_songs_song ON class_songs(song_id)',
        );
        await db.execute('CREATE INDEX idx_songs_folder ON songs(folder)');
        await db.execute(
          'CREATE INDEX idx_songs_storage_location ON songs(storage_location)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE songs ADD COLUMN folder TEXT');
          await db.execute('CREATE INDEX idx_songs_folder ON songs(folder)');
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE songs ADD COLUMN storage_location TEXT DEFAULT 'internal'",
          );
          await db.execute(
            'CREATE INDEX idx_songs_storage_location ON songs(storage_location)',
          );
        }
      },
    );
  }

  // ─── Songs ───────────────────────────────────────────────────────────────

  Future<int> insertSong(Song song) async {
    final db = await database;
    return db.insert('songs', song.toMap());
  }

  Future<List<Song>> getAllSongs() async {
    final db = await database;
    final maps = await db.query('songs', orderBy: 'created_at DESC');
    return maps.map(Song.fromMap).toList();
  }

  Future<Song?> getSongById(int id) async {
    final db = await database;
    final maps = await db.query('songs', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : Song.fromMap(maps.first);
  }

  Future<int> updateSong(Song song) async {
    final db = await database;
    return db.update(
      'songs',
      song.toMap(),
      where: 'id = ?',
      whereArgs: [song.id],
    );
  }

  Future<int> deleteSong(int id) async {
    final db = await database;
    return db.delete('songs', where: 'id = ?', whereArgs: [id]);
  }

  /// Get songs filtered by storage location
  ///
  /// Pass `null` or [StorageLocation.all] to get songs from all locations
  Future<List<Song>> getSongsByStorageLocation(
    StorageLocation? location,
  ) async {
    final db = await database;

    if (location == null || location == StorageLocation.all) {
      final maps = await db.query('songs', orderBy: 'created_at DESC');
      return maps.map(Song.fromMap).toList();
    }

    final maps = await db.query(
      'songs',
      where: 'storage_location = ?',
      whereArgs: [location.toDbValue()],
      orderBy: 'created_at DESC',
    );
    return maps.map(Song.fromMap).toList();
  }

  // ─── Classes ─────────────────────────────────────────────────────────────

  Future<int> insertClass(DanceClass danceClass) async {
    final db = await database;
    return db.insert('classes', danceClass.toMap());
  }

  Future<List<DanceClass>> getAllClasses() async {
    final db = await database;
    final maps = await db.query('classes', orderBy: 'date DESC');
    return maps.map(DanceClass.fromMap).toList();
  }

  Future<DanceClass?> getClassById(int id) async {
    final db = await database;
    final maps = await db.query('classes', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : DanceClass.fromMap(maps.first);
  }

  Future<int> updateClass(DanceClass danceClass) async {
    final db = await database;
    return db.update(
      'classes',
      danceClass.toMap(),
      where: 'id = ?',
      whereArgs: [danceClass.id],
    );
  }

  Future<int> deleteClass(int id) async {
    final db = await database;
    return db.delete('classes', where: 'id = ?', whereArgs: [id]);
  }

  // ─── Class-Song Relationship ─────────────────────────────────────────────

  Future<void> addSongToClass(
    int classId,
    int songId, {
    int position = 0,
  }) async {
    final db = await database;
    await db.insert('class_songs', {
      'class_id': classId,
      'song_id': songId,
      'position': position,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeSongFromClass(int classId, int songId) async {
    final db = await database;
    await db.delete(
      'class_songs',
      where: 'class_id = ? AND song_id = ?',
      whereArgs: [classId, songId],
    );
  }

  Future<List<Song>> getSongsForClass(int classId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT s.* FROM songs s
      INNER JOIN class_songs cs ON s.id = cs.song_id
      WHERE cs.class_id = ?
      ORDER BY cs.position
    ''',
      [classId],
    );
    return maps.map(Song.fromMap).toList();
  }

  Future<List<DanceClass>> getClassesForSong(int songId) async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
      SELECT c.* FROM classes c
      INNER JOIN class_songs cs ON c.id = cs.class_id
      WHERE cs.song_id = ?
      ORDER BY c.date DESC
    ''',
      [songId],
    );
    return maps.map(DanceClass.fromMap).toList();
  }

  // ─── Sync with Filesystem ────────────────────────────────────────────────

  /// Sync database with filesystem - add new files, remove deleted ones
  Future<SyncResult> syncWithFilesystem(List<ScannedFile> scannedFiles) async {
    int added = 0;
    int removed = 0;

    // Get all songs from database
    final existingSongs = await getAllSongs();
    final existingPaths = {for (final s in existingSongs) s.filePath: s};

    // Add new files
    for (final file in scannedFiles) {
      if (!existingPaths.containsKey(file.absolutePath)) {
        final song = Song(
          name: _extractSongName(file.fileName),
          durationSeconds: 0, // Will be updated when played
          filePath: file.absolutePath,
          folder: file.folder,
          createdAt: file.modifiedAt,
          storageLocation: file.storageLocation,
        );
        await insertSong(song);
        added++;
      }
    }

    // Remove songs whose files no longer exist
    final scannedPaths = {for (final f in scannedFiles) f.absolutePath};
    for (final song in existingSongs) {
      if (!scannedPaths.contains(song.filePath)) {
        await deleteSong(song.id!);
        removed++;
      }
    }

    return SyncResult(added: added, removed: removed);
  }

  String _extractSongName(String fileName) {
    // Remove extension
    final withoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    // Clean up common patterns
    return withoutExt
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Get songs filtered by folder
  Future<List<Song>> getSongsByFolder(String? folder) async {
    final db = await database;
    if (folder == null) {
      // Root folder only (no subfolder)
      final maps = await db.query(
        'songs',
        where: 'folder IS NULL',
        orderBy: 'name ASC',
      );
      return maps.map(Song.fromMap).toList();
    } else {
      final maps = await db.query(
        'songs',
        where: 'folder = ?',
        whereArgs: [folder],
        orderBy: 'name ASC',
      );
      return maps.map(Song.fromMap).toList();
    }
  }

  /// Update song file path (when moved)
  Future<void> updateSongPath(int id, String newPath, String? newFolder) async {
    final db = await database;
    await db.update(
      'songs',
      {'file_path': newPath, 'folder': newFolder},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get song by file path
  Future<Song?> getSongByPath(String path) async {
    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'file_path = ?',
      whereArgs: [path],
    );
    return maps.isEmpty ? null : Song.fromMap(maps.first);
  }

  /// Search songs by name across all storage locations
  Future<List<Song>> searchSongs(String query) async {
    if (query.trim().isEmpty) return [];

    final db = await database;
    final maps = await db.query(
      'songs',
      where: 'name LIKE ?',
      whereArgs: ['%${query.trim()}%'],
      orderBy: 'name ASC',
    );
    return maps.map(Song.fromMap).toList();
  }
}

class SyncResult {
  final int added;
  final int removed;

  const SyncResult({required this.added, required this.removed});

  bool get hasChanges => added > 0 || removed > 0;
}
