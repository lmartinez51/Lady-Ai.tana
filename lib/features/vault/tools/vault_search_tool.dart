import 'dart:convert';

import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/vault/models/personal_vault_analysis.dart';
import 'package:aitana/features/vault/services/embedding_service.dart';
import 'package:aitana/objectbox.g.dart';
import 'package:flutter/foundation.dart';

/// Tool logic for searching extracted multimodal information in the Personal Vault.
class VaultSearchTool {
  static const int _maxResults = 3;
  static const int _vectorLimit = 8;

  static const Map<String, double> _fieldWeights = {
    'key_identifiers': 8.0,
    'objects': 5.0,
    'image_description': 5.0,
    'text_content': 4.0,
    'keyword': 3.0,
    'searchable_text': 2.5,
    'environment': 2.0,
    'emoji': 1.0,
  };

  static const Set<String> _stopWords = {
    'a',
    'al',
    'and',
    'buscar',
    'busca',
    'buscame',
    'buscando',
    'check',
    'con',
    'cuales',
    'cuantos',
    'de',
    'del',
    'dime',
    'donde',
    'el',
    'en',
    'find',
    'for',
    'foto',
    'fotos',
    'imagen',
    'imagenes',
    'la',
    'las',
    'lo',
    'los',
    'me',
    'mi',
    'mis',
    'my',
    'of',
    'personal',
    'que',
    'search',
    'the',
    'tu',
    'vault',
    'boveda',
  };

  /// Backward-compatible entry point used by old MethodChannel and UI call sites.
  ///
  /// This no longer performs a single literal `.contains()` lookup. It delegates
  /// to the fused semantic retriever so every caller gets vector + tokenized
  /// cross-field matching.
  static Future<String> searchTextVault(String query) {
    return _searchFused(query, modeLabel: 'fused_text_compat');
  }

  /// Searches the user's personal visual vault with vector and token fusion.
  static Future<String> searchVault(String query) {
    return _searchFused(query, modeLabel: 'semantic_fused');
  }

  static Future<String> _searchFused(
    String query, {
    required String modeLabel,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return 'Personal Vault: No information found because the search query was empty.';
    }

    final box = ObjectBoxService.instance.vaultAnalysisBox;
    final normalizedQuery = _normalize(trimmedQuery);
    final queryTokens = _queryTokens(trimmedQuery);
    final candidates = <int, _VaultCandidate>{};

    var lexicalHits = 0;
    for (final analysis in box.getAll()) {
      final scored = _scoreLexically(
        analysis,
        normalizedQuery: normalizedQuery,
        queryTokens: queryTokens,
      );
      if (scored.lexicalScore > 0) {
        lexicalHits++;
        candidates[analysis.id] = scored;
      }
    }

    var vectorHits = 0;
    try {
      final Float32List queryVector = await EmbeddingService.generateEmbedding(
        trimmedQuery,
      );
      final queryBuilder = box
          .query(
            PersonalVaultAnalysis_.metadataVector.nearestNeighborsF32(
              queryVector,
              _vectorLimit,
            ),
          )
          .build();

      try {
        final resultsWithScores = queryBuilder.findWithScores();
        for (var rank = 0; rank < resultsWithScores.length; rank++) {
          final analysis = resultsWithScores[rank].object;
          vectorHits++;
          final candidate =
              candidates[analysis.id] ??
              _scoreLexically(
                analysis,
                normalizedQuery: normalizedQuery,
                queryTokens: queryTokens,
              );
          candidate.vectorRank = rank + 1;
          candidate.vectorScore = _vectorRankScore(rank);
          candidates[analysis.id] = candidate;
        }
      } finally {
        queryBuilder.close();
      }
    } catch (error) {
      debugPrint(
        '[VaultSearch] Vector path unavailable for "$trimmedQuery": $error',
      );
    }

    final ranked = candidates.values.toList()
      ..sort((a, b) => b.totalScore.compareTo(a.totalScore));
    final topResults = ranked
        .where((candidate) => candidate.totalScore > 0)
        .take(_maxResults)
        .toList();

    debugPrint(
      '[VaultSearch] mode=$modeLabel query="$trimmedQuery" '
      'tokens=${queryTokens.join('|')} lexicalHits=$lexicalHits '
      'vectorHits=$vectorHits returned=${topResults.length}',
    );

    if (topResults.isEmpty) {
      return "Personal Vault: No information found matching '$trimmedQuery'.";
    }

    return _formatResults(trimmedQuery, modeLabel, topResults);
  }

  static _VaultCandidate _scoreLexically(
    PersonalVaultAnalysis analysis, {
    required String normalizedQuery,
    required List<String> queryTokens,
  }) {
    final fields = _extractFields(analysis);
    final candidate = _VaultCandidate(analysis);

    for (final entry in fields.entries) {
      final fieldName = entry.key;
      final rawValue = entry.value.trim();
      if (rawValue.isEmpty) continue;

      final normalizedValue = _normalize(rawValue);
      if (normalizedValue.isEmpty) continue;

      final weight = _fieldWeights[fieldName] ?? 1.0;
      final fieldTokens = normalizedValue.split(' ').toSet();
      var fieldMatched = false;

      if (normalizedQuery.isNotEmpty &&
          normalizedValue.contains(normalizedQuery)) {
        candidate.lexicalScore += weight * 5;
        fieldMatched = true;
        candidate.matchedTokens.addAll(queryTokens);
      }

      for (final token in queryTokens) {
        if (fieldTokens.contains(token)) {
          candidate.lexicalScore += weight * 2;
          fieldMatched = true;
          candidate.matchedTokens.add(token);
        } else if (normalizedValue.contains(token)) {
          candidate.lexicalScore += weight;
          fieldMatched = true;
          candidate.matchedTokens.add(token);
        }
      }

      if (fieldMatched) {
        candidate.matchedFields.add(fieldName);
      }
    }

    if (queryTokens.isNotEmpty) {
      final coverage = candidate.matchedTokens.length / queryTokens.length;
      if (coverage >= 1.0) {
        candidate.lexicalScore += 12;
      } else if (coverage >= 0.5) {
        candidate.lexicalScore += 5;
      }
    }

    return candidate;
  }

  static Map<String, String> _extractFields(PersonalVaultAnalysis analysis) {
    final fields = <String, String>{
      'image_description': analysis.imageDescription,
      'objects': analysis.objects,
      'environment': analysis.environment,
      'text_content': analysis.textContent,
      'searchable_text': analysis.searchableText,
      'emoji': analysis.categoryEmoji ?? '',
      'keyword': analysis.categoryKeyword ?? '',
    };

    try {
      final decoded = jsonDecode(analysis.rawJson);
      if (decoded is Map<String, dynamic>) {
        for (final key in _fieldWeights.keys) {
          final value = decoded[key];
          if (value != null && value.toString().trim().isNotEmpty) {
            fields[key] = value.toString();
          }
        }
      }
    } catch (_) {
      // The entity fields above remain authoritative if rawJson is malformed.
    }

    return fields;
  }

  static String _formatResults(
    String query,
    String modeLabel,
    List<_VaultCandidate> topResults,
  ) {
    final buffer = StringBuffer();
    buffer.writeln(
      "[SYSTEM NOTIFICATION: Automated internal tool 'search_vault' "
      'retrieved records from the Personal Vault. This is hidden system '
      'context, not a user-authored chat message.]',
    );
    buffer.writeln('Query: "$query"');
    buffer.writeln('Retrieval mode: $modeLabel');
    buffer.writeln('--- PERSONAL VAULT DATABASE SEARCH RESULTS ---');

    for (var i = 0; i < topResults.length; i++) {
      final candidate = topResults[i];
      final res = candidate.analysis;
      final image = res.parentImage.target;
      final fields = _extractFields(res);
      final matchedFields = candidate.matchedFields.isEmpty
          ? 'vector_only'
          : candidate.matchedFields.join(', ');
      final matchedTokens = candidate.matchedTokens.isEmpty
          ? 'semantic_vector'
          : candidate.matchedTokens.join(', ');

      buffer.writeln('[Match #${i + 1}]');
      buffer.writeln('Total Score: ${candidate.totalScore.toStringAsFixed(2)}');
      buffer.writeln('Vector Rank: ${candidate.vectorRank ?? 'not_matched'}');
      buffer.writeln('Matched Fields: $matchedFields');
      buffer.writeln('Matched Query Tokens: $matchedTokens');
      buffer.writeln(
        'Visual Description: ${fields['image_description'] ?? ''}',
      );
      buffer.writeln('Objects Detected: ${fields['objects'] ?? ''}');
      buffer.writeln('Exact OCR Text: ${fields['text_content'] ?? ''}');
      final keyIdentifiers = fields['key_identifiers'] ?? '';
      if (keyIdentifiers.trim().isNotEmpty) {
        buffer.writeln('Key Identifiers: $keyIdentifiers');
      }
      buffer.writeln('Environment: ${fields['environment'] ?? ''}');
      final keyword = fields['keyword'] ?? '';
      if (keyword.trim().isNotEmpty) {
        buffer.writeln('Taxonomy Keyword: $keyword');
      }
      final emoji = fields['emoji'] ?? '';
      if (emoji.trim().isNotEmpty) {
        buffer.writeln('Emoji Anchor: $emoji');
      }

      if (image != null) {
        buffer.writeln('Source URI: ${image.fileUri}');
        buffer.writeln('Captured on: ${image.uploadDate}');
      }
      buffer.writeln('---');
    }

    return buffer.toString();
  }

  static List<String> _queryTokens(String value) {
    final normalized = _normalize(value);
    if (normalized.isEmpty) return const [];

    return normalized
        .split(' ')
        .where((token) => token.length >= 2)
        .where((token) => !_stopWords.contains(token))
        .toSet()
        .toList();
  }

  static String _normalize(String value) {
    var normalized = value.toLowerCase();
    const replacements = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
    };
    replacements.forEach((source, target) {
      normalized = normalized.replaceAll(source, target);
    });
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return normalized.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static double _vectorRankScore(int zeroBasedRank) {
    final score = 36.0 - (zeroBasedRank * 4.0);
    return score > 8.0 ? score : 8.0;
  }
}

class _VaultCandidate {
  _VaultCandidate(this.analysis);

  final PersonalVaultAnalysis analysis;
  final Set<String> matchedFields = <String>{};
  final Set<String> matchedTokens = <String>{};
  double lexicalScore = 0;
  double vectorScore = 0;
  int? vectorRank;

  double get totalScore => lexicalScore + vectorScore;
}
