import 'package:shared_preferences/shared_preferences.dart';

import '../domain/storage_location.dart';

/// Service to manage app preferences using shared_preferences.
///
/// Handles user settings like the preferred download destination.
class PreferencesService {
  static const String _downloadDestinationKey = 'download_destination';

  SharedPreferences? _prefs;

  /// Initialize the preferences service
  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Get the current download destination preference.
  ///
  /// Returns [StorageLocation.internal] by default if not set.
  Future<StorageLocation> getDownloadDestination() async {
    await initialize();
    final value = _prefs!.getString(_downloadDestinationKey);
    if (value == null) {
      return StorageLocation.internal;
    }
    return StorageLocation.fromString(value);
  }

  /// Set the preferred download destination.
  Future<void> setDownloadDestination(StorageLocation location) async {
    await initialize();
    await _prefs!.setString(_downloadDestinationKey, location.toDbValue());
  }
}
