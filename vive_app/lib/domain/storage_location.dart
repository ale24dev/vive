/// Represents the storage location for media files.
///
/// - [internal]: Device internal storage (app-specific directory)
/// - [sd]: External SD card storage
/// - [all]: Used for filtering queries only, not for actual storage
enum StorageLocation {
  internal,
  sd,
  all;

  /// Convert from database string value to enum
  static StorageLocation fromString(String value) {
    return StorageLocation.values.firstWhere(
      (e) => e.name == value,
      orElse: () => StorageLocation.internal,
    );
  }

  /// Convert to database string value
  String toDbValue() => name;
}
