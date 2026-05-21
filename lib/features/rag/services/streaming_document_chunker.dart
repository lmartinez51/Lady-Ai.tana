import 'package:aitana/features/rag/models/legal_knowledge_chunk.dart';
import 'package:aitana/features/rag/services/chunking/chunking_strategy_factory.dart';

/// A stateful, page-by-page streaming document chunker.
///
/// Unlike the batch [DocumentChunker], this class is instantiated once per
/// ingestion and retains structural context (chapter / section headings and
/// the current paragraph accumulator) across individual page-level calls.
///
/// ## Memory Profile
/// At any given moment only a **single page's text** lives in the Dart heap.
/// As each page string is processed and the reference is dropped, the GC can
/// collect it during the [Future.delayed] yield that follows. This prevents the
/// OOM spikes seen with the legacy "load everything, then split" approach.
///
/// ## Usage
/// ```dart
/// final chunker = StreamingDocumentChunker(
///   documentName: fileName,
///   category: 'ley',
///   authorityWeight: 3,
/// );
/// for (int i = 0; i < document.pages.count; i++) {
///   final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i);
///   chunker.feedPage(pageText);
///   await Future.delayed(Duration.zero); // yield to event loop / GC
/// }
/// final chunks = chunker.finalize();
/// ```
class StreamingDocumentChunker {
  // ── Public parameters ────────────────────────────────────────────────────
  final String documentName;
  final String category;
  final int authorityWeight;

  // ── Internal state (persists across page calls) ──────────────────────────
  late final _strategy = ChunkingStrategyFactory.getStrategy(category);
  final List<LegalKnowledgeChunk> _chunks = [];
  final StringBuffer _accumulator = StringBuffer();
  String _currentChapter = '';
  String _currentSection = '';

  StreamingDocumentChunker({
    required this.documentName,
    required this.category,
    this.authorityWeight = 1,
  });

  /// Processes the text extracted from a **single PDF page**.
  ///
  /// Internally reconstructs paragraph boundaries (hyphen-joins, mid-sentence
  /// line-breaks) and runs the same boundary-detection / flush logic as the
  /// legacy batch chunker. The caller is expected to `await Future.delayed`
  /// after each call so the GC can reclaim the now-unreferenced [pageText]
  /// string allocation.
  void feedPage(String pageText) {
    if (pageText.trim().isEmpty) return;

    // ── PDF artifact cleanup (same as legacy _reconstructParagraphs) ────────
    String cleaned = pageText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // Join hyphenated word-breaks at end of line (e.g. "syll-\nable" -> "syllable")
    cleaned = cleaned.replaceAll(RegExp(r'(\w)-\n\s*(\w)'), r'$1$2');
    // Convert soft newlines (mid-sentence) to spaces
    cleaned = cleaned.replaceAll(RegExp(r'(?<![\.:\;!\?\n])\n(?!\n)'), ' ');
    // Normalize multiple spaces
    cleaned = cleaned.replaceAll(RegExp(r' +'), ' ');

    // ── Split page into logical units ────────────────────────────────────────
    final paragraphs = cleaned.split(RegExp(r'\n+'));

    for (final raw in paragraphs) {
      final paragraph = raw.trim();
      if (paragraph.isEmpty) continue;

      final bool isBoundary = _strategy.isBoundary(paragraph);

      // Flush the accumulator when a new structural boundary is hit or the
      // current chunk is already at the target size.
      if ((isBoundary || _accumulator.length > 700) &&
          _accumulator.isNotEmpty) {
        _flushAccumulator();
      }

      // Update running metadata context
      final chapterMatch = _strategy.extractChapterContext(paragraph);
      if (chapterMatch != null) {
        _currentChapter = chapterMatch;
        _currentSection = '';
      }

      final sectionMatch = _strategy.extractSectionContext(paragraph);
      if (sectionMatch != null) {
        _currentSection = sectionMatch;
      }

      // Accumulate content
      if (_accumulator.isNotEmpty) _accumulator.write('\n\n');
      _accumulator.write(paragraph);
    }
  }

  /// Signals that all pages have been fed.
  ///
  /// Flushes any remaining content in the accumulator and returns the
  /// complete list of [LegalKnowledgeChunk] records ready for ObjectBox.
  List<LegalKnowledgeChunk> finalize() {
    if (_accumulator.isNotEmpty) {
      _flushAccumulator();
    }
    return List.unmodifiable(_chunks);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  void _flushAccumulator() {
    _chunks.add(
      LegalKnowledgeChunk(
        documentName: documentName,
        chapterContext: _currentChapter,
        sectionContext: _currentSection,
        rawText: _accumulator.toString(),
        searchableText: _normalizeSearchText(
          '$_currentChapter $_currentSection ${_accumulator.toString()}'.trim(),
        ),
        authorityWeight: authorityWeight,
      ),
    );
    _accumulator.clear();
  }

  /// Normalises text for BM25-style keyword matching in ObjectBox:
  /// lowercases, strips diacritics, removes punctuation, and normalises
  /// legal ordinal suffixes (e.g. "4to" → "4o").
  static String _normalizeSearchText(String text) {
    String n = text.toLowerCase();
    n = n.replaceAll(RegExp(r'[áàäâã]'), 'a');
    n = n.replaceAll(RegExp(r'[éèëê]'), 'e');
    n = n.replaceAll(RegExp(r'[íìïî]'), 'i');
    n = n.replaceAll(RegExp(r'[óòöôõ]'), 'o');
    n = n.replaceAll(RegExp(r'[úùüû]'), 'u');
    n = n.replaceAll(RegExp(r'[ñ]'), 'n');
    n = n.replaceAll(RegExp(r'[^\w\s]'), '');
    n = n.replaceAllMapped(
      RegExp(r'\b(\d+)(to|vo|no|mo|avo)\b'),
      (m) => '${m.group(1)}o',
    );
    n = n.replaceAllMapped(
      RegExp(r'\b(articulo|art)\s+(\d+)(?!o)\b'),
      (m) => '${m.group(1)} ${m.group(2)}o',
    );
    return n;
  }
}
