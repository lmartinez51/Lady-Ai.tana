import 'dart:typed_data';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/vault/services/embedding_service.dart';
import 'package:aitana/objectbox.g.dart';

/// Tool logic for searching extracted multimodal information in the Personal Vault.
class VaultSearchTool {
  /// Searches the user's personal visual vault.
  ///
  /// CRITICAL: The LLM must use this tool automatically when the user asks about
  /// an image, photo, or item they saved. It MUST NOT ask the user for a keyword.
  /// It must INFER and synthesize the best search keyword (e.g., 'vehicle', 'receipt').
  static Future<String> searchVault(String query) async {
    final box = ObjectBoxService.instance.vaultAnalysisBox;

    // 🧠 Pilar 2: El Cerebro Vectorial
    // Convert query text to vector
    final Float32List queryVector = await EmbeddingService.generateEmbedding(
      query,
    );

    // Perform nearest neighbor search in ObjectBox
    final queryBuilder = box
        .query(
          PersonalVaultAnalysis_.metadataVector.nearestNeighborsF32(
            queryVector,
            5,
          ),
        )
        .build();

    final resultsWithScores = queryBuilder.findWithScores();
    final results = resultsWithScores.map((s) => s.object).toList();
    queryBuilder.close();

    if (results.isEmpty) {
      return "Personal Vault: No information found matching '$query'.";
    }

    // Sort by relevance (number of hits) or simply take the top 3 recent entries.
    final topResults = results.take(3).toList();
    final buffer = StringBuffer("--- PERSONAL VAULT SEARCH RESULTS ---\n");

    for (var i = 0; i < topResults.length; i++) {
      final res = topResults[i];
      final image = res.parentImage.target;

      buffer.writeln("[Match #${i + 1}]");
      buffer.writeln("Visual Description: ${res.imageDescription}");
      buffer.writeln("Objects Detected: ${res.objects}");
      buffer.writeln("Exact OCR Text found in image: ${res.textContent}");
      buffer.writeln("Environment: ${res.environment}");

      if (image != null) {
        buffer.writeln("Source URI: ${image.fileUri}");
        buffer.writeln("Captured on: ${image.uploadDate}");
      }
      buffer.writeln("---");
    }

    return buffer.toString();
  }
}
