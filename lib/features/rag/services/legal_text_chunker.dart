import 'package:aitana/features/rag/models/legal_knowledge_chunk.dart';
import 'package:aitana/features/rag/services/chunking/chunking_strategy_factory.dart';

class DocumentChunker {
  static String _normalizeSearchText(String text) {
    String normalized = text.toLowerCase();
    normalized = normalized.replaceAll(RegExp(r'[áàäâã]'), 'a');
    normalized = normalized.replaceAll(RegExp(r'[éèëê]'), 'e');
    normalized = normalized.replaceAll(RegExp(r'[íìïî]'), 'i');
    normalized = normalized.replaceAll(RegExp(r'[óòöôõ]'), 'o');
    normalized = normalized.replaceAll(RegExp(r'[úùüû]'), 'u');
    normalized = normalized.replaceAll(RegExp(r'[ñ]'), 'n');
    normalized = normalized.replaceAll(RegExp(r'[^\w\s]'), '');

    // ── Preprocessing: Normalize Legal Ordinals ─────────────────────────────
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)(to|vo|no|mo|avo)\b'),
      (match) => '${match.group(1)}o',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(articulo|art)\s+(\d+)(?!o)\b'),
      (match) => '${match.group(1)} ${match.group(2)}o',
    );
    // ────────────────────────────────────────────────────────────────────────

    return normalized;
  }

  /// Chunks a full document's text into [LegalKnowledgeChunk] records.
  /// Uses a specialized [ChunkingStrategy] based on the document [category].
  static List<LegalKnowledgeChunk> processDocument(
    String documentName,
    String text,
    String category, {
    int authorityWeight = 1,
  }) {
    // ── 1. PDF Line Break Cleanup ──────────────────────────────────────────
    final cleanedText = _reconstructParagraphs(text);

    // Resolve the appropriate strategy for this document type
    final strategy = ChunkingStrategyFactory.getStrategy(category);

    final List<LegalKnowledgeChunk> chunks = [];
    String currentChapter = '';
    String currentSection = '';

    // Split into potential paragraphs (logical units)
    final paragraphs = cleanedText.split(RegExp(r'\n+'));
    StringBuffer accumulator = StringBuffer();

    for (final p in paragraphs) {
      final paragraph = p.trim();
      if (paragraph.isEmpty) continue;

      // Identify if this paragraph is a structural boundary based on strategy
      final bool isBoundary = strategy.isBoundary(paragraph);

      // ── Boundary or Size Threshold Flush ─────────────────────────────────
      // We flush the accumulator if:
      // a) We hit a new structural header (Chapter/Article/Rubro).
      // b) The current chunk is already healthy (700+ chars).
      if ((isBoundary || accumulator.length > 700) && accumulator.isNotEmpty) {
        chunks.add(
          _createChunk(
            documentName,
            currentChapter,
            currentSection,
            accumulator.toString(),
            authorityWeight,
          ),
        );
        accumulator.clear();
      }

      // ── Update Metadata Context via Strategy ─────────────────────────────
      final String? chapterMatch = strategy.extractChapterContext(paragraph);
      if (chapterMatch != null) {
        currentChapter = chapterMatch;
        currentSection = '';
      }

      final String? sectionMatch = strategy.extractSectionContext(paragraph);
      if (sectionMatch != null) {
        currentSection = sectionMatch;
      }

      // ── Accumulate ───────────────────────────────────────────────────────
      if (accumulator.isNotEmpty) accumulator.write('\n\n');
      accumulator.write(paragraph);
    }

    // Final flush for the last chunk
    if (accumulator.isNotEmpty) {
      chunks.add(
        _createChunk(
          documentName,
          currentChapter,
          currentSection,
          accumulator.toString(),
          authorityWeight,
        ),
      );
    }

    return chunks;
  }

  static String _reconstructParagraphs(String text) {
    // Normalize line endings to UNIX style
    String result = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // 1. syll-able -> syllable (Join words split by hyphens at end of line)
    result = result.replaceAll(RegExp(r'(\w)-\n\s*(\w)'), r'$1$2');

    // 2. Mid-sentence newlines -> space.
    result = result.replaceAll(RegExp(r'(?<![\.\:\;\!\?\n])\n(?!\n)'), ' ');

    // 3. Normalize multiple spaces resulting from the join
    result = result.replaceAll(RegExp(r' +'), ' ');

    return result;
  }

  static LegalKnowledgeChunk _createChunk(
    String docName,
    String chapter,
    String section,
    String text,
    int weight,
  ) {
    return LegalKnowledgeChunk(
      documentName: docName,
      chapterContext: chapter,
      sectionContext: section,
      rawText: text,
      searchableText: _normalizeSearchText('$chapter $section $text'.trim()),
      authorityWeight: weight,
    );
  }
}
