import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/storage_location.dart';
import 'storage_root.dart';

/// Service to manage the Musik_Vive folder across internal storage and SD card
class StorageService {
  static const String rootFolderName = 'Musik_Vive';

  /// SD card path pattern: /storage/XXXX-XXXX where X is [A-F0-9]
  static final RegExp _sdCardPattern = RegExp(r'^[A-F0-9]{4}-[A-F0-9]{4}$');

  List<StorageRoot> _roots = [];

  /// Get all available storage roots
  List<StorageRoot> get roots => List.unmodifiable(_roots);

  /// Get the primary (internal) root path for backward compatibility
  String? get rootPath {
    final internalRoot = _roots.firstWhere(
      (r) => r.location == StorageLocation.internal && r.isAvailable,
      orElse: () => const StorageRoot(
        path: '',
        location: StorageLocation.internal,
        isAvailable: false,
        canWrite: false,
      ),
    );
    return internalRoot.path.isNotEmpty ? internalRoot.path : null;
  }

  /// Initialize storage - request permissions, detect internal and SD storage
  Future<bool> initialize() async {
    // Request storage permissions
    final hasPermission = await _requestPermissions();
    if (!hasPermission) return false;

    _roots = [];

    // Detect internal storage
    final internalRoot = await _detectInternalStorage();
    if (internalRoot != null) {
      _roots.add(internalRoot);
    }

    // Detect SD card storage
    final sdRoot = await _detectSDCard();
    if (sdRoot != null) {
      _roots.add(sdRoot);
    }

    return _roots.isNotEmpty;
  }

  Future<StorageRoot?> _detectInternalStorage() async {
    // Strategy for Android 11+:
    // 1. Try app's external media directory (no permissions needed for write)
    // 2. This is visible in file managers at Android/media/com.vive.app/

    try {
      // getExternalStorageDirectory gives us app-specific external storage
      // For media files, we want the media directory which is more accessible
      final dirs = await getExternalStorageDirectories(
        type: StorageDirectory.music,
      );

      if (dirs != null && dirs.isNotEmpty) {
        // This gives something like /storage/emulated/0/Android/media/com.vive.app/Music
        // We want to use a Musik_Vive subfolder
        final basePath = dirs.first.path;
        final musikVivePath = '$basePath/$rootFolderName';
        final canWrite = await _ensureFolderExists(musikVivePath);

        if (canWrite) {
          return StorageRoot(
            path: musikVivePath,
            location: StorageLocation.internal,
            isAvailable: true,
            canWrite: true,
          );
        }
      }
    } catch (e) {
      // Fall through to legacy detection
    }

    // Fallback: Try public Music directory (requires READ_MEDIA_AUDIO to read)
    const publicMusicPath = '/storage/emulated/0/Music/$rootFolderName';
    final canWrite = await _ensureFolderExists(publicMusicPath);

    if (canWrite) {
      return StorageRoot(
        path: publicMusicPath,
        location: StorageLocation.internal,
        isAvailable: true,
        canWrite: true,
      );
    }

    // Last resort: app-specific directory (always works, no permissions)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final musikVivePath = '${appDir.path}/$rootFolderName';
        await _ensureFolderExists(musikVivePath);

        return StorageRoot(
          path: musikVivePath,
          location: StorageLocation.internal,
          isAvailable: true,
          canWrite: true,
        );
      }
    } catch (e) {
      // Nothing worked
    }

    return null;
  }

  /// Detect SD card by scanning /storage/ for pattern [A-F0-9]{4}-[A-F0-9]{4}
  Future<StorageRoot?> _detectSDCard() async {
    // For SD card on Android 11+, we need to use the app-specific directory
    // on the SD card, which doesn't require special permissions
    try {
      final dirs = await getExternalStorageDirectories(
        type: StorageDirectory.music,
      );

      if (dirs != null && dirs.length > 1) {
        // Second directory is usually SD card
        for (final dir in dirs.skip(1)) {
          if (dir.path.contains(RegExp(r'/storage/[A-F0-9]{4}-[A-F0-9]{4}/'))) {
            final musikVivePath = '${dir.path}/$rootFolderName';
            final canWrite = await _ensureFolderExists(musikVivePath);

            if (canWrite) {
              return StorageRoot(
                path: musikVivePath,
                location: StorageLocation.sd,
                isAvailable: true,
                canWrite: true,
              );
            }
          }
        }
      }
    } catch (e) {
      // SD card detection failed
    }

    return null;
  }

  Future<bool> _ensureFolderExists(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true;

    // For Android 13+ (API 33+), use READ_MEDIA_AUDIO
    // For Android 10-12, use READ_EXTERNAL_STORAGE
    // We don't need MANAGE_EXTERNAL_STORAGE - we use app-specific directories

    var status = await Permission.audio.status;

    if (status.isDenied) {
      status = await Permission.audio.request();
    }

    // If audio permission denied, try legacy storage permission (Android < 13)
    if (!status.isGranted) {
      var storageStatus = await Permission.storage.status;
      if (storageStatus.isDenied) {
        storageStatus = await Permission.storage.request();
      }
      // Even if denied, we can still use app-specific directories
      // So we return true to continue initialization
    }

    // Always return true - we can at least use app-specific directory
    // which doesn't require any permissions
    return true;
  }

  /// Check if permissions are granted
  Future<bool> hasPermissions() async {
    if (Platform.isAndroid) {
      final audioStatus = await Permission.audio.status;
      final storageStatus = await Permission.storage.status;
      return audioStatus.isGranted || storageStatus.isGranted;
    }
    return true;
  }

  /// Get all available storage roots
  List<StorageRoot> getAvailableRoots() {
    return _roots.where((r) => r.isAvailable).toList();
  }

  /// Get the storage root for a specific location
  StorageRoot? getRootForLocation(StorageLocation location) {
    if (location == StorageLocation.all) return null;
    return _roots.firstWhere(
      (r) => r.location == location && r.isAvailable,
      orElse: () => const StorageRoot(
        path: '',
        location: StorageLocation.internal,
        isAvailable: false,
        canWrite: false,
      ),
    );
  }

  /// Scan ALL roots and return all audio files with their storage locations
  Future<List<ScannedFile>> scanFiles() async {
    final files = <ScannedFile>[];

    for (final root in _roots) {
      if (!root.isAvailable) continue;

      final rootDir = Directory(root.path);
      if (!rootDir.existsSync()) continue;

      await _scanDirectory(rootDir, '', files, root.location);
    }

    return files;
  }

  Future<void> _scanDirectory(
    Directory dir,
    String relativePath,
    List<ScannedFile> files,
    StorageLocation storageLocation,
  ) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (['mp3', 'wav', 'aac', 'm4a', 'flac', 'ogg'].contains(ext)) {
            final fileName = entity.path.split('/').last;
            files.add(
              ScannedFile(
                absolutePath: entity.path,
                relativePath: relativePath.isEmpty
                    ? fileName
                    : '$relativePath/$fileName',
                folder: relativePath.isEmpty ? null : relativePath,
                fileName: fileName,
                modifiedAt: entity.lastModifiedSync(),
                storageLocation: storageLocation,
              ),
            );
          }
        } else if (entity is Directory) {
          final folderName = entity.path.split('/').last;
          // Skip hidden folders
          if (!folderName.startsWith('.')) {
            final newRelativePath = relativePath.isEmpty
                ? folderName
                : '$relativePath/$folderName';
            await _scanDirectory(
              entity,
              newRelativePath,
              files,
              storageLocation,
            );
          }
        }
      }
    } catch (e) {
      // Permission denied or other error - skip this directory
    }
  }

  /// Get all folders in the specified root or all roots
  Future<List<String>> getFolders({StorageLocation? location}) async {
    final folders = <String>[];

    final rootsToScan = location == null || location == StorageLocation.all
        ? _roots.where((r) => r.isAvailable)
        : _roots.where((r) => r.location == location && r.isAvailable);

    for (final root in rootsToScan) {
      final rootDir = Directory(root.path);
      if (!rootDir.existsSync()) continue;

      await _collectFolders(rootDir, '', folders);
    }

    return folders;
  }

  Future<void> _collectFolders(
    Directory dir,
    String relativePath,
    List<String> folders,
  ) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final folderName = entity.path.split('/').last;
          if (!folderName.startsWith('.')) {
            final folderPath = relativePath.isEmpty
                ? folderName
                : '$relativePath/$folderName';
            folders.add(folderPath);
            await _collectFolders(entity, folderPath, folders);
          }
        }
      }
    } catch (e) {
      // Skip on error
    }
  }

  /// Create a new folder in the specified storage location
  Future<bool> createFolder(
    String name, {
    StorageLocation location = StorageLocation.internal,
  }) async {
    final root = getRootForLocation(location);
    if (root == null || !root.canWrite) return false;

    final folderPath = '${root.path}/$name';
    final dir = Directory(folderPath);

    if (dir.existsSync()) return true;

    try {
      await dir.create(recursive: true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Move a file to a different folder
  Future<String?> moveFile(String currentPath, String? targetFolder) async {
    // Determine which root the file is in
    StorageRoot? sourceRoot;
    for (final root in _roots) {
      if (currentPath.startsWith(root.path)) {
        sourceRoot = root;
        break;
      }
    }
    if (sourceRoot == null) return null;

    final file = File(currentPath);
    if (!file.existsSync()) return null;

    final fileName = currentPath.split('/').last;
    final newPath = targetFolder == null
        ? '${sourceRoot.path}/$fileName'
        : '${sourceRoot.path}/$targetFolder/$fileName';

    try {
      // Ensure target folder exists
      if (targetFolder != null) {
        await Directory(
          '${sourceRoot.path}/$targetFolder',
        ).create(recursive: true);
      }

      final newFile = await file.rename(newPath);
      return newFile.path;
    } catch (e) {
      return null;
    }
  }

  /// Delete a file
  Future<bool> deleteFile(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get the absolute path for a file in the specified storage location
  String? getAbsolutePath(
    String relativePath, {
    StorageLocation location = StorageLocation.internal,
  }) {
    final root = getRootForLocation(location);
    if (root == null) return null;
    return '${root.path}/$relativePath';
  }

  /// Save downloaded audio to the specified storage location
  Future<String?> saveDownload(
    List<int> bytes,
    String fileName, {
    String? folder,
    StorageLocation location = StorageLocation.internal,
  }) async {
    final root = getRootForLocation(location);
    if (root == null || !root.canWrite) return null;

    try {
      final targetDir = folder == null ? root.path : '${root.path}/$folder';

      // Ensure folder exists
      await Directory(targetDir).create(recursive: true);

      final filePath = '$targetDir/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      return filePath;
    } catch (e) {
      return null;
    }
  }
}

class ScannedFile {
  final String absolutePath;
  final String relativePath;
  final String? folder;
  final String fileName;
  final DateTime modifiedAt;
  final StorageLocation storageLocation;

  const ScannedFile({
    required this.absolutePath,
    required this.relativePath,
    required this.folder,
    required this.fileName,
    required this.modifiedAt,
    required this.storageLocation,
  });
}
