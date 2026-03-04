import 'storage_location.dart';

class Song {
  final int? id;
  final String name;
  final int? bpm;
  final int durationSeconds;
  final String filePath;
  final String? folder;
  final DateTime createdAt;
  final StorageLocation storageLocation;

  const Song({
    this.id,
    required this.name,
    this.bpm,
    required this.durationSeconds,
    required this.filePath,
    this.folder,
    required this.createdAt,
    this.storageLocation = StorageLocation.internal,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'bpm': bpm,
    'duration_seconds': durationSeconds,
    'file_path': filePath,
    'folder': folder,
    'created_at': createdAt.toIso8601String(),
    'storage_location': storageLocation.toDbValue(),
  };

  factory Song.fromMap(Map<String, dynamic> map) => Song(
    id: map['id'] as int,
    name: map['name'] as String,
    bpm: map['bpm'] as int?,
    durationSeconds: map['duration_seconds'] as int,
    filePath: map['file_path'] as String,
    folder: map['folder'] as String?,
    createdAt: DateTime.parse(map['created_at'] as String),
    storageLocation: map['storage_location'] != null
        ? StorageLocation.fromString(map['storage_location'] as String)
        : StorageLocation.internal,
  );

  Song copyWith({
    int? id,
    String? name,
    int? bpm,
    int? durationSeconds,
    String? filePath,
    String? folder,
    DateTime? createdAt,
    StorageLocation? storageLocation,
  }) => Song(
    id: id ?? this.id,
    name: name ?? this.name,
    bpm: bpm ?? this.bpm,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    filePath: filePath ?? this.filePath,
    folder: folder ?? this.folder,
    createdAt: createdAt ?? this.createdAt,
    storageLocation: storageLocation ?? this.storageLocation,
  );
}
