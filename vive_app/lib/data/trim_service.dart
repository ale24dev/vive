import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

/// Service to trim audio files using FFmpeg
class TrimService {
  /// Trims an audio file from startMs to endMs
  ///
  /// First attempts stream copy (fast, no re-encoding).
  /// Falls back to re-encoding with AAC if stream copy fails.
  ///
  /// Returns true on success, false on failure.
  Future<bool> trimAudio(
    String inputPath,
    String outputPath,
    int startMs,
    int endMs,
  ) async {
    final startTime = _msToFFmpegTime(startMs);
    final endTime = _msToFFmpegTime(endMs);

    // First try stream copy (fast, no quality loss)
    final copyCommand =
        '-i "$inputPath" -ss $startTime -to $endTime -c copy -y "$outputPath"';

    final copySession = await FFmpegKit.execute(copyCommand);
    final copyReturnCode = await copySession.getReturnCode();

    if (ReturnCode.isSuccess(copyReturnCode)) {
      return true;
    }

    // Fallback to re-encoding with AAC
    final encodeCommand =
        '-i "$inputPath" -ss $startTime -to $endTime -c:a aac -b:a 192k -y "$outputPath"';

    final encodeSession = await FFmpegKit.execute(encodeCommand);
    final encodeReturnCode = await encodeSession.getReturnCode();

    return ReturnCode.isSuccess(encodeReturnCode);
  }

  /// Gets the duration of an audio file in milliseconds
  ///
  /// Returns null if the duration cannot be determined.
  Future<int?> getDuration(String filePath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(filePath);
      final mediaInfo = session.getMediaInformation();

      if (mediaInfo == null) {
        return null;
      }

      final durationStr = mediaInfo.getDuration();
      if (durationStr == null) {
        return null;
      }

      // Duration is returned as seconds with decimal (e.g., "123.456")
      final durationSeconds = double.tryParse(durationStr);
      if (durationSeconds == null) {
        return null;
      }

      return (durationSeconds * 1000).round();
    } catch (e) {
      return null;
    }
  }

  /// Converts milliseconds to FFmpeg time format (HH:MM:SS.mmm)
  String _msToFFmpegTime(int ms) {
    final totalSeconds = ms ~/ 1000;
    final milliseconds = ms % 1000;

    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${milliseconds.toString().padLeft(3, '0')}';
  }
}
