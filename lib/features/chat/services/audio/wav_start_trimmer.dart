import 'dart:io';
import 'dart:typed_data';

class WavStartTrimmer {
  static Future<String> trimStart({
    required String inputPath,
    required Duration trimDuration,
  }) async {
    if (trimDuration <= Duration.zero) return inputPath;

    final inputFile = File(inputPath);
    final bytes = await inputFile.readAsBytes();
    final trimmedBytes = _trimWavBytes(bytes, trimDuration);
    final outputPath = _trimmedPath(inputPath);

    await File(outputPath).writeAsBytes(trimmedBytes, flush: true);
    return outputPath;
  }

  static Uint8List _trimWavBytes(Uint8List bytes, Duration trimDuration) {
    if (bytes.length < 44) {
      throw const FormatException('WAV file is too short.');
    }

    final byteData = ByteData.sublistView(bytes);
    if (_fourCc(bytes, 0) != 'RIFF' || _fourCc(bytes, 8) != 'WAVE') {
      throw const FormatException('File is not a RIFF/WAVE file.');
    }

    int? fmtPayloadOffset;
    int? fmtChunkSize;
    int? dataChunkOffset;
    int? dataPayloadOffset;
    int? dataChunkSize;

    var chunkOffset = 12;
    while (chunkOffset + 8 <= bytes.length) {
      final chunkId = _fourCc(bytes, chunkOffset);
      final chunkSize = byteData.getUint32(chunkOffset + 4, Endian.little);
      final payloadOffset = chunkOffset + 8;
      final payloadEnd = payloadOffset + chunkSize;

      if (payloadEnd > bytes.length) {
        throw FormatException('Invalid WAV chunk size for $chunkId.');
      }

      if (chunkId == 'fmt ') {
        fmtPayloadOffset = payloadOffset;
        fmtChunkSize = chunkSize;
      } else if (chunkId == 'data') {
        dataChunkOffset = chunkOffset;
        dataPayloadOffset = payloadOffset;
        dataChunkSize = chunkSize;
        break;
      }

      chunkOffset = payloadEnd + (chunkSize.isOdd ? 1 : 0);
    }

    if (fmtPayloadOffset == null || fmtChunkSize == null || fmtChunkSize < 16) {
      throw const FormatException('WAV fmt chunk is missing or invalid.');
    }
    if (dataChunkOffset == null ||
        dataPayloadOffset == null ||
        dataChunkSize == null) {
      throw const FormatException('WAV data chunk is missing.');
    }

    final audioFormat = byteData.getUint16(fmtPayloadOffset, Endian.little);
    final sampleRate = byteData.getUint32(fmtPayloadOffset + 4, Endian.little);
    final blockAlign = byteData.getUint16(fmtPayloadOffset + 12, Endian.little);
    if (audioFormat != 1 || sampleRate <= 0 || blockAlign <= 0) {
      throw const FormatException('Only PCM WAV files can be trimmed safely.');
    }

    final rawTrimBytes =
        (sampleRate * blockAlign * trimDuration.inMicroseconds +
            Duration.microsecondsPerSecond -
            1) ~/
        Duration.microsecondsPerSecond;
    final trimBytes =
        ((rawTrimBytes + blockAlign - 1) ~/ blockAlign) * blockAlign;

    if (trimBytes <= 0) return bytes;
    if (trimBytes >= dataChunkSize) {
      throw const FormatException(
        'Trim duration removes the full WAV payload.',
      );
    }

    final newDataSize = dataChunkSize - trimBytes;
    final originalDataEnd = dataPayloadOffset + dataChunkSize;
    final originalDataPad = dataChunkSize.isOdd ? 1 : 0;
    final trailingOffset = originalDataEnd + originalDataPad;

    final builder = BytesBuilder(copy: false)
      ..add(bytes.sublist(0, dataPayloadOffset))
      ..add(bytes.sublist(dataPayloadOffset + trimBytes, originalDataEnd));

    if (newDataSize.isOdd) {
      builder.addByte(0);
    }
    if (trailingOffset < bytes.length) {
      builder.add(bytes.sublist(trailingOffset));
    }

    final outputBytes = builder.toBytes();
    final outputData = ByteData.sublistView(outputBytes);
    outputData.setUint32(4, outputBytes.length - 8, Endian.little);
    outputData.setUint32(dataChunkOffset + 4, newDataSize, Endian.little);

    return outputBytes;
  }

  static String _fourCc(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }

  static String _trimmedPath(String inputPath) {
    final dotIndex = inputPath.lastIndexOf('.');
    if (dotIndex == -1) return '${inputPath}_trimmed.wav';
    return '${inputPath.substring(0, dotIndex)}_trimmed${inputPath.substring(dotIndex)}';
  }
}
