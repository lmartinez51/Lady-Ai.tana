import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/constants/native_channels.dart';

/// Service for generating text embeddings using a local model.
///
/// This service routes requests to the native layer (Kotlin) where a
/// LiteRT (TFLite) model performs the actual inference.
class EmbeddingService {
  static const MethodChannel _channel = MethodChannel(NativeChannels.aiCore);

  /// Generates a 384-dimensional vector for the given [text].
  ///
  /// Uses the 'all-MiniLM-L6-v2' model (or equivalent) in the native layer.
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
      return Float32List(384);
    }
  }
}
