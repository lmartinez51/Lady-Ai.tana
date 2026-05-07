import 'package:aitana/features/rag/models/legal_knowledge_chunk.dart';

class DocumentChunker {
  static final RegExp _chapterRegex = RegExp(
    r'^(I{1,3}|IV|V|VI{1,3}|IX|X|XI{1,3}|XII)\.\s+[A-Z]',
  );
  static final RegExp _sectionRegex = RegExp(r'^[A-Z]\.\s+[A-Z]');

  /// Matches Mexican legal article headers in all common formats:
  /// - "Artículo 4o.", "Artículo 4°.", "Artículo 4.", "Art. 4"
  /// Case-insensitive and diacritic-tolerant.
  static final RegExp _articleRegex = RegExp(
    r'^Art[ií]culo\s+\d+|^Art\.\s*\d+',
    caseSensitive: false,
    unicode: true,
  );

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
    // Convert written suffixes like "4to", "4vo" into the official "4o".
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)(to|vo|no|mo|avo)\b'),
      (match) => '${match.group(1)}o',
    );
    // Convert standalone digits following "articulo" or "art" into ordinals.
    // E.g. "articulo 4" -> "articulo 4o". Lookahead ensures no double 'o'.
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(articulo|art)\s+(\d+)(?!o)\b'),
      (match) => '${match.group(1)} ${match.group(2)}o',
    );
    // ────────────────────────────────────────────────────────────────────────

    return normalized;
  }

  /// Chunks a full document's text into [LegalKnowledgeChunk] records.
  static List<LegalKnowledgeChunk> processDocument(
    String documentName,
    String text, {
    int authorityWeight = 1,
  }) {
    // ── 1. PDF Line Break Cleanup ──────────────────────────────────────────
    // PDFs often contain visual newlines mid-sentence. We reconstruct the
    // natural flow while preserving double-newlines (paragraph breaks).
    final cleanedText = _reconstructParagraphs(text);

    final List<LegalKnowledgeChunk> chunks = [];
    String currentChapter = '';
    String currentSection = '';

    // Split into potential paragraphs (logical units)
    final paragraphs = cleanedText.split(RegExp(r'\n+'));
    StringBuffer accumulator = StringBuffer();

    for (final p in paragraphs) {
      final paragraph = p.trim();
      if (paragraph.isEmpty) continue;

      // Identify if this paragraph is a structural boundary
      final bool isChapter = _chapterRegex.hasMatch(paragraph);
      final bool isSection = _sectionRegex.hasMatch(paragraph);
      final bool isArticle = _articleRegex.hasMatch(paragraph);
      final bool isBoundary = isChapter || isSection || isArticle;

      // ── Boundary or Size Threshold Flush ─────────────────────────────────
      // We flush the accumulator if:
      // a) We hit a new structural header (Chapter/Article).
      // b) The current chunk is already healthy (600+ chars).
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

      // ── Update Metadata Context ──────────────────────────────────────────
      if (isChapter) {
        currentChapter = paragraph;
        currentSection = '';
      } else if (isSection) {
        currentSection = paragraph;
      } else if (isArticle) {
        // Articles are usually short headers, update the section context
        // for subsequent paragraphs but also include the header in the text.
        currentSection = paragraph.length > 60
            ? '${paragraph.substring(0, 60)}…'
            : paragraph;
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
    // Matches a newline that is NOT preceded by a period, colon, or semicolon,
    // and is NOT followed by another newline (which would indicate a real break).
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
