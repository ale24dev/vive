import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DownloadScreen(),
    );
  }
}

class DownloadedSong {
  final String title;
  final String artist;
  final int duration;
  final String filePath;
  final int fileSize;

  const DownloadedSong({
    required this.title,
    required this.artist,
    required this.duration,
    required this.filePath,
    required this.fileSize,
  });
}

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  static const _baseUrl = 'https://vive-k1rt.onrender.com';

  final _urlController = TextEditingController();
  final _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(minutes: 2),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  bool _isDownloading = false;
  double _progress = 0;
  String? _statusMessage;
  final List<DownloadedSong> _downloadedSongs = [];

  @override
  void dispose() {
    _urlController.dispose();
    _dio.close();
    super.dispose();
  }

  Future<void> _download() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _progress = 0;
      _statusMessage = 'Connecting to server...';
    });

    try {
      // Get the app's documents directory
      final dir = await getApplicationDocumentsDirectory();
      final songsDir = Directory('${dir.path}/songs');
      if (!songsDir.existsSync()) {
        songsDir.createSync(recursive: true);
      }

      // Temporary path — we'll rename after we get the headers
      final tempPath =
          '${songsDir.path}/downloading_${DateTime.now().millisecondsSinceEpoch}.tmp';

      setState(() => _statusMessage = 'Downloading from YouTube...');

      final response = await _dio.post(
        '/download',
        data: {'url': url, 'format': 'mp3'},
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Content-Type': 'application/json'},
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            setState(() {
              _progress = received / total;
              _statusMessage =
                  'Downloading... ${(received / 1024 / 1024).toStringAsFixed(1)} MB';
            });
          }
        },
      );

      // Extract metadata from response headers
      final headers = response.headers;
      final title = Uri.decodeComponent(
        headers.value('x-video-title') ?? 'Unknown',
      );
      final artist = Uri.decodeComponent(
        headers.value('x-video-artist') ?? 'Unknown',
      );
      final duration =
          int.tryParse(headers.value('x-video-duration') ?? '0') ?? 0;

      // Save file with a proper name
      final safeTitle = title.replaceAll(RegExp(r'[^\w\s\-]'), '').trim();
      final filePath = '${songsDir.path}/$safeTitle.mp3';

      final file = File(tempPath);
      await file.writeAsBytes(response.data as List<int>);

      // Rename to final name
      final finalFile = await file.rename(filePath);
      final fileSize = await finalFile.length();

      setState(() {
        _downloadedSongs.insert(
          0,
          DownloadedSong(
            title: title,
            artist: artist,
            duration: duration,
            filePath: filePath,
            fileSize: fileSize,
          ),
        );
        _urlController.clear();
        _statusMessage = null;
      });
    } on DioException catch (e) {
      String message;
      if (e.type == DioExceptionType.connectionTimeout) {
        message = 'Server is waking up... try again in a minute.';
      } else if (e.type == DioExceptionType.receiveTimeout) {
        message = 'Download took too long. Try again.';
      } else if (e.response?.statusCode == 400) {
        message = 'Invalid URL. Check and try again.';
      } else if (e.response?.statusCode == 500) {
        final detail = e.response?.data is Map
            ? e.response?.data['detail'] ?? 'Server error'
            : 'Server error. Try again.';
        message = detail.toString();
      } else {
        message = 'Connection error. Check your internet.';
      }
      setState(() => _statusMessage = message);
    } catch (e) {
      setState(() => _statusMessage = 'Unexpected error: $e');
    } finally {
      setState(() {
        _isDownloading = false;
        _progress = 0;
      });
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  String _formatFileSize(int bytes) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vive')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // URL Input
            TextField(
              controller: _urlController,
              enabled: !_isDownloading,
              decoration: const InputDecoration(
                hintText: 'YouTube URL',
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: _isDownloading ? null : (_) => _download(),
            ),
            const SizedBox(height: 12),

            // Download button
            FilledButton.icon(
              onPressed: _isDownloading ? null : _download,
              icon: _isDownloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_isDownloading ? 'Downloading...' : 'Download MP3'),
            ),

            // Progress bar
            if (_isDownloading && _progress > 0) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress),
            ],

            // Status message
            if (_statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _statusMessage!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],

            const SizedBox(height: 24),

            // Downloaded songs list
            if (_downloadedSongs.isNotEmpty) ...[
              Text(
                'Downloaded',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _downloadedSongs.length,
                  itemBuilder: (context, index) {
                    final song = _downloadedSongs[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.music_note),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(song.artist),
                        trailing: Text(
                          '${_formatDuration(song.duration)}\n${_formatFileSize(song.fileSize)}',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
