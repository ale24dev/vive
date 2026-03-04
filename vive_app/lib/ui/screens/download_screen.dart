import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../data/preferences_service.dart';
import '../../data/storage_service.dart';
import '../../domain/song.dart';
import '../../domain/storage_location.dart';
import '../theme/vive_theme.dart';

class DownloadScreen extends StatefulWidget {
  final ViveDatabase db;
  final StorageService storage;
  final PreferencesService preferences;
  final bool hasSDCard;
  final VoidCallback? onDownloadComplete;

  const DownloadScreen({
    super.key,
    required this.db,
    required this.storage,
    required this.preferences,
    this.hasSDCard = false,
    this.onDownloadComplete,
  });

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  static const _baseUrl = 'https://vive-k1rt.onrender.com';
  static const _pollInterval = Duration(seconds: 10);

  final _urlController = TextEditingController();
  final _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  bool _isDownloading = false;
  int _progress = 0;
  String? _statusMessage;
  String? _currentJobId;
  Timer? _pollTimer;
  StorageLocation _destination = StorageLocation.internal;

  @override
  void initState() {
    super.initState();
    _loadDestination();
  }

  Future<void> _loadDestination() async {
    final destination = await widget.preferences.getDownloadDestination();
    if (mounted) {
      setState(() => _destination = destination);
    }
  }

  Future<void> _setDestination(StorageLocation location) async {
    await widget.preferences.setDownloadDestination(location);
    setState(() => _destination = location);
  }

  void _showDestinationPicker() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Guardar en',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('Almacenamiento interno'),
            trailing: _destination == StorageLocation.internal
                ? const Icon(Icons.check, color: ViveTheme.primary)
                : null,
            onTap: () {
              Navigator.pop(context);
              _setDestination(StorageLocation.internal);
            },
          ),
          if (widget.hasSDCard)
            ListTile(
              leading: const Icon(Icons.sd_card),
              title: const Text('Tarjeta SD'),
              trailing: _destination == StorageLocation.sd
                  ? const Icon(Icons.check, color: ViveTheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(context);
                _setDestination(StorageLocation.sd);
              },
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pollTimer?.cancel();
    _dio.close();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _progress = 0;
      _statusMessage = 'Iniciando descarga...';
    });

    try {
      // Start the download job
      final response = await _dio.post(
        '/download/start',
        data: {'url': url, 'format': 'mp3'},
      );

      final jobId = response.data['job_id'] as String;
      _currentJobId = jobId;

      setState(() => _statusMessage = 'Descargando...');

      // Start polling for status
      _startPolling(jobId);
    } on DioException catch (e) {
      _handleError(e);
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
        _isDownloading = false;
      });
    }
  }

  void _startPolling(String jobId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _checkStatus(jobId));
    // Also check immediately
    _checkStatus(jobId);
  }

  Future<void> _checkStatus(String jobId) async {
    try {
      final response = await _dio.get('/download/status/$jobId');
      final data = response.data;

      final status = data['status'] as String;
      final progress = data['progress'] as int;
      final title = data['title'] as String?;
      final duration = data['duration'] as int? ?? 0;
      final error = data['error'] as String?;

      debugPrint('Poll status: $status, progress: $progress');

      setState(() {
        _progress = progress;
        if (status == 'processing') {
          _statusMessage = 'Procesando audio...';
        } else if (title != null) {
          _statusMessage = 'Descargando: $title ($progress%)';
        }
      });

      if (status == 'completed') {
        debugPrint('Download completed! Starting file download...');
        _pollTimer?.cancel();
        await _downloadFile(jobId, title ?? 'download', duration);
      } else if (status == 'failed') {
        _pollTimer?.cancel();
        setState(() {
          _statusMessage = error ?? 'Error en la descarga';
          _isDownloading = false;
        });
      }
    } on DioException catch (e) {
      // Don't stop polling on network errors, just log
      debugPrint('Poll error: ${e.message}');
    }
  }

  Future<void> _downloadFile(String jobId, String title, int duration) async {
    setState(() => _statusMessage = 'Guardando archivo...');

    try {
      final response = await _dio.get(
        '/download/file/$jobId',
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data as List<int>;
      debugPrint('Downloaded ${bytes.length} bytes, duration: $duration');

      // Clean filename - use m4a extension (native YouTube audio format)
      final safeTitle = title
          .replaceAll(RegExp(r'[^\w\s\-áéíóúÁÉÍÓÚñÑ]'), '')
          .trim();
      final fileName = '$safeTitle.m4a';

      // Save to Musik_Vive folder in selected destination
      final filePath = await widget.storage.saveDownload(
        bytes,
        fileName,
        location: _destination,
      );

      debugPrint('Saved to: $filePath');

      if (filePath == null) {
        setState(() {
          _statusMessage = 'Error al guardar archivo';
          _isDownloading = false;
        });
        return;
      }

      // Save to database with duration and storage location
      await widget.db.insertSong(
        Song(
          name: title,
          durationSeconds: duration,
          filePath: filePath,
          createdAt: DateTime.now(),
          storageLocation: _destination,
        ),
      );

      setState(() {
        _urlController.clear();
        _statusMessage = '¡Descargado!';
        _isDownloading = false;
        _progress = 0;
        _currentJobId = null;
      });

      widget.onDownloadComplete?.call();

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _statusMessage = null);
        }
      });
    } on DioException catch (e) {
      _handleError(e);
    }
  }

  void _handleError(DioException e) {
    String message;
    if (e.type == DioExceptionType.connectionTimeout) {
      message = 'Servidor iniciando... intentá de nuevo.';
    } else if (e.type == DioExceptionType.receiveTimeout) {
      message = 'La descarga tardó mucho.';
    } else if (e.response?.statusCode == 400) {
      message = 'URL inválida.';
    } else if (e.response?.statusCode == 404) {
      message = 'Descarga no encontrada.';
    } else if (e.response?.statusCode == 500) {
      final detail = e.response?.data is Map
          ? e.response?.data['detail'] ?? 'Error del servidor'
          : 'Error del servidor.';
      message = detail.toString();
    } else {
      message = 'Error de conexión: ${e.type}';
    }

    _pollTimer?.cancel();
    setState(() {
      _statusMessage = message;
      _isDownloading = false;
      _progress = 0;
      _currentJobId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.download_rounded,
            size: 64,
            color: ViveTheme.primary.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 24),
          Text(
            'Descargar de YouTube',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Pegá una URL de YouTube para descargar el audio',
            style: TextStyle(color: ViveTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          // Destination selector chip
          GestureDetector(
            onTap: _isDownloading ? null : _showDestinationPicker,
            child: Chip(
              avatar: Icon(
                _destination == StorageLocation.sd
                    ? Icons.sd_card
                    : Icons.phone_android,
                size: 18,
                color: ViveTheme.primary,
              ),
              label: Text(
                _destination == StorageLocation.sd
                    ? 'Guardar en SD'
                    : 'Guardar en Interna',
                style: TextStyle(color: ViveTheme.primary, fontSize: 13),
              ),
              backgroundColor: ViveTheme.primaryPale,
              side: BorderSide.none,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _urlController,
            enabled: !_isDownloading,
            decoration: const InputDecoration(
              hintText: 'https://youtube.com/...',
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: _isDownloading ? null : (_) => _startDownload(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isDownloading ? null : _startDownload,
            icon: _isDownloading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download),
            label: Text(_isDownloading ? 'Descargando...' : 'Descargar'),
          ),
          if (_isDownloading && _progress > 0) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress / 100,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$_progress%',
              textAlign: TextAlign.center,
              style: TextStyle(color: ViveTheme.textSecondary, fontSize: 12),
            ),
          ],
          if (_statusMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _statusMessage!,
              style: TextStyle(
                color: _statusMessage == '¡Descargado!'
                    ? ViveTheme.primary
                    : ViveTheme.textSecondary,
                fontWeight: _statusMessage == '¡Descargado!'
                    ? FontWeight.w500
                    : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
