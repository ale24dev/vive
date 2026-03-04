import '../domain/storage_location.dart';

/// Represents a root storage path where media files can be stored.
///
/// Each [StorageRoot] corresponds to either internal storage or an SD card
/// mount point, along with metadata about its availability and write access.
class StorageRoot {
  /// The absolute file system path to this storage root
  final String path;

  /// The type of storage (internal or sd)
  final StorageLocation location;

  /// Whether this storage is currently mounted and accessible
  final bool isAvailable;

  /// Whether the app has write permission to this storage
  final bool canWrite;

  const StorageRoot({
    required this.path,
    required this.location,
    required this.isAvailable,
    required this.canWrite,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageRoot &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          location == other.location;

  @override
  int get hashCode => path.hashCode ^ location.hashCode;

  @override
  String toString() =>
      'StorageRoot(path: $path, location: $location, isAvailable: $isAvailable, canWrite: $canWrite)';
}
