import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/constants/native_channels.dart';

/// Service for generating text embeddings using a local model.
///
/// This service routes requests to the native layer (Kotlin) where a
/// LiteRT (TFLite) model performs the actual inference.
class EmbeddingService {
  static const MethodChannel _channel = MethodChannel(NativeChannels.aiCore);

  /// Generates a 768-dimensional vector for the given [text].
  ///
  /// Uses the `embeddinggemma-300m` model via the native LiteRT interpreter.
  /// Returns a zero-filled [Float32List] of length 768 on error to prevent
  /// a shape mismatch crash at the ObjectBox HNSW insert boundary.
  static Future<Float32List> generateEmbedding(String text) async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod(
        'generateEmbedding',
        {'text': text},
      );

      if (result == null) {
        throw Exception('Failed to generate embedding: result is null');
      }

      return Float32List.fromList(result.cast<double>());
    } catch (e) {
      debugPrint('🔴 [EmbeddingService] Error: $e');
      // Return an empty vector or handle error as appropriate
      return Float32List(768);
    }
  }
}
