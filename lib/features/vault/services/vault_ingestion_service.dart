import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:aitana/features/chat/services/llm/models/llm_inference_params.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/features/vault/models/personal_vault_image.dart';
import 'package:aitana/features/vault/models/personal_vault_analysis.dart';
import 'package:aitana/features/vault/services/embedding_service.dart';
import 'package:aitana/objectbox.g.dart';

/// Status results for the ingestion process.
enum IngestionStatus {
  /// Image successfully analyzed and persisted.
  success,

  /// Image already exists in the vault (hash match).
  duplicate,

  /// An error occurred during the pipeline.
  error,
}

/// Orchestration service for the "Vision Funnel".
///
/// This service handles the end-to-end pipeline of analyzing an image with
/// the local LLM, extracting structured data, and persisting it in the
/// Personal Vault.
class VaultIngestionService {
  static const MethodChannel _channel = MethodChannel(NativeChannels.aiCore);
  final ObjectBoxService _db = ObjectBoxService.instance;

  /// Helper method to safely extract and stringify nested JSON structures (Lists/Maps).
  String _safeExtract(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    // If it is a List or Map, safely encode it back to a JSON string.
    try {
      return jsonEncode(value);
    } catch (e) {
      debugPrint('VaultIngestionService JSON Encode Error: $e');
      return value.toString();
    }
  }

  /// Ingests an image into the Personal Vault.
  ///
  /// Sequential Pipeline:
  /// 1. Deduplication via Native Hash (SHA-256).
  /// 2. Secure Storage in the app's sandbox.
  /// 3. Vision LLM Inference for structured data extraction.
  /// 4. JSON Sanitization & Parsing.
  /// 5. ObjectBox Persistence with relational linking.
  Future<IngestionStatus> ingestImage(
    String sourcePath, {
    String shelf = 'general',
  }) async {
    try {
      // Step 1: Deduplication via Native Hash
      // We leverage Kotlin for fast file hashing over MethodChannel.
      final String hash = await _channel.invokeMethod('calculateSHA256', {
        'filePath': sourcePath,
      });

      final query = _db.vaultImageBox
          .query(PersonalVaultImage_.imageHash.equals(hash))
          .build();
      final existing = query.findFirst();
      query.close();

      if (existing != null) {
        return IngestionStatus.duplicate;
      }

      // Step 2: Secure Storage (Sandbox)
      // Get the dedicated vault directory from the native layer.
      final String sandboxPath = await _channel.invokeMethod(
        'initVaultSandbox',
      );
      final String fileName =
          '${DateTime.now().millisecondsSinceEpoch}${p.extension(sourcePath)}';
      final String destinationPath = p.join(sandboxPath, fileName);

      // Copy to the secure sandbox.
      await File(sourcePath).copy(destinationPath);

      // Downscale to max 512x512, compress to JPEG 80% quality, and save to cache.
      final String inferenceImagePath = await _downscaleAndCompressImage(
        destinationPath,
        sandboxPath,
      );

      // Step 3: Vision LLM Inference
      // Construct the strict extraction prompt optimized for Gemma 4 (Flat JSON - Agnostic).
      const String prompt = '''
You are a structured data extraction engine. Your output is always machine-parsed.

ABSOLUTE RULES:
- Return ONLY a single flat JSON object. No nested objects, no nested arrays.
- No markdown, no code blocks, no explanations, no text outside the JSON.
- All values must be strings. Empty string ("") if a field has no data.
- Do not invent data not visible in the image.

Analyze the image and return exactly these 7 keys:

"text_content": Every word, number, code, or phrase readable in the image, 
  concatenated into one continuous string separated by spaces. 
  Preserve serial numbers and codes verbatim.

"key_identifiers": Comma-separated list of distinct identifiers only: 
  tracking numbers, invoice IDs, serial codes, account numbers, 
  exact quantities, specific dates, unique proper nouns. 
  Include all. Do not summarize.

"image_description": One concise sentence describing exactly what the image shows.

"objects": Comma-separated list of all visible physical items or subjects, 
  each optionally followed by its position in parentheses.

"environment": One string describing the setting, background, lighting, 
  or physical context of the image.

"emoji": The single emoji that best represents the primary subject of the image.

"keyword": Exactly one word from this list that best classifies the image:
  Document, Receipt, Invoice, Hardware, Vehicle, Person, Animal, 
  Food, Location, Product, Media, Object, Other.

Return the JSON now.
''';

      // 🔴 INYECTAR DETERMINISMO CONTROLADO 🔴
      await LocalLlmService.updateSamplerParams(
        const LlmInferenceParams(
          temperature: 0.25, // Un poco de "aire" para poder cerrar los nodos
          topK: 10, // Margen de maniobra para no atascarse en 1 solo token
          topP: 0.8,
          repetitionPenalty: 1.20, // Scaled up to break repeating patterns
          enableThinking: false,
        ),
      );

      // Invoke the existing LocalLlmService to run vision inference.
      final String rawResponse = await LocalLlmService.runInference(
        prompt,
        imagePath: inferenceImagePath,
        isStructuredOutput: true,
      );

      // Step 4: JSON Sanitization & Parsing
      final Map<String, dynamic> data = _parseAnalysisJson(rawResponse);

      // Step 5: Database Persistence
      final imageRecord = PersonalVaultImage(
        fileUri: destinationPath,
        imageHash: hash,
        uploadDate: DateTime.now(),
        shelf: shelf,
      );

      final String searchableText = _buildSearchableText(data);

      // 🧠 Pilar 2: El Cerebro Vectorial
      // Generate embedding for semantic search.
      final semanticString = [
        _safeExtract(data['image_description']),
        _safeExtract(data['objects']),
        _safeExtract(data['text_content']),
        _safeExtract(data['key_identifiers']),
      ].where((s) => s.isNotEmpty).join(' ');

      final vector = await EmbeddingService.generateEmbedding(semanticString);

      final analysisRecord = PersonalVaultAnalysis(
        rawJson: jsonEncode(data),
        imageDescription: _safeExtract(data['image_description']),
        objects: _safeExtract(data['objects']),
        environment: _safeExtract(data['environment']),
        textContent: _safeExtract(data['text_content']),
        searchableText: searchableText,
        metadataVector: vector,
        categoryEmoji: _safeExtract(data['emoji']),
        categoryKeyword: _safeExtract(data['keyword']),
      );

      // Link and save within an ObjectBox transaction for atomicity.
      analysisRecord.parentImage.target = imageRecord;

      _db.vaultImageBox.put(imageRecord);
      _db.vaultAnalysisBox.put(analysisRecord);

      return IngestionStatus.success;
    } catch (e) {
      debugPrint('VaultIngestionService Error: $e');
      return IngestionStatus.error;
    }
  }

  /// Cleans markdown artifacts and parses the JSON response from the LLM.
  Map<String, dynamic> _parseAnalysisJson(String raw) {
    try {
      // Strip markdown JSON blocks (common in LLM outputs)
      String clean = raw.trim();
      if (clean.startsWith('```json')) {
        clean = clean.substring(7);
      } else if (clean.startsWith('```')) {
        clean = clean.substring(3);
      }

      if (clean.endsWith('```')) {
        clean = clean.substring(0, clean.length - 3);
      }

      clean = clean.trim();

      return jsonDecode(clean) as Map<String, dynamic>;
    } catch (e) {
      // Fallback Strategy: If JSON parsing fails, we store the raw output
      // in the description to preserve information.
      return {
        'image_description': raw,
        'objects': 'Parsing Failed',
        'environment': '',
        'text_content': '',
        'emoji': '📁',
        'keyword': 'General',
      };
    }
  }

  /// Concatenates all values for full-text search indexing.
  String _buildSearchableText(Map<String, dynamic> data) {
    return [
      _safeExtract(data['image_description']),
      _safeExtract(data['objects']),
      _safeExtract(data['environment']),
      _safeExtract(data['text_content']),
      _safeExtract(data['key_identifiers']),
    ].where((v) => v.isNotEmpty).join(' ');
  }

  /// Downscales the image at [sourcePath] to a maximum resolution of 512x512
  /// preserving aspect ratio, compresses it to JPEG (80% quality), saves it to
  /// a cache file ('compressed_vault_input.jpg') in [sandboxPath], and returns the path.
  Future<String> _downscaleAndCompressImage(
    String sourcePath,
    String sandboxPath,
  ) async {
    try {
      final File originalFile = File(sourcePath);
      final Uint8List bytes = await originalFile.readAsBytes();

      final img.Image? image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint(
          'VaultIngestionService: Failed to decode image for optimization, falling back to original.',
        );
        return sourcePath;
      }

      int? targetWidth;
      int? targetHeight;
      if (image.width > image.height) {
        if (image.width > 512) {
          targetWidth = 512;
        }
      } else {
        if (image.height > 512) {
          targetHeight = 512;
        }
      }

      img.Image resized = image;
      if (targetWidth != null || targetHeight != null) {
        resized = img.copyResize(
          image,
          width: targetWidth,
          height: targetHeight,
        );
        debugPrint(
          'VaultIngestionService: Downscaled image from ${image.width}x${image.height} to ${resized.width}x${resized.height}',
        );
      } else {
        debugPrint(
          'VaultIngestionService: Image is within bounds (${image.width}x${image.height}), no downscaling needed.',
        );
      }

      final List<int> compressedBytes = img.encodeJpg(resized, quality: 80);
      final String compressedPath = p.join(
        sandboxPath,
        'compressed_vault_input.jpg',
      );
      final File compressedFile = File(compressedPath);
      await compressedFile.writeAsBytes(compressedBytes);

      return compressedPath;
    } catch (e) {
      debugPrint(
        'VaultIngestionService image optimization error: $e. Falling back to original.',
      );
      return sourcePath;
    }
  }
}
