import 'package:aitana/features/rag/services/chunking/chunking_strategy.dart';

class LawChunkingStrategy implements ChunkingStrategy {
  static final RegExp _chapterRegex = RegExp(
    r'^(I{1,3}|IV|V|VI{1,3}|IX|X|XI{1,3}|XII)\.\s+[A-Z]',
  );

  static final RegExp _sectionRegex = RegExp(r'^[A-Z]\.\s+[A-Z]');

  /// Matches Mexican legal article headers: "Artículo 4o.", "Art. 4", etc.
  static final RegExp _articleRegex = RegExp(
    r'^Art[ií]culo\s+\d+|^Art\.\s*\d+',
    caseSensitive: false,
    unicode: true,
  );

  @override
  bool isBoundary(String paragraph) {
    return _chapterRegex.hasMatch(paragraph) ||
        _sectionRegex.hasMatch(paragraph) ||
        _articleRegex.hasMatch(paragraph);
  }

  @override
  String? extractChapterContext(String paragraph) {
    if (_chapterRegex.hasMatch(paragraph)) {
      return paragraph;
    }
    return null;
  }

  @override
  String? extractSectionContext(String paragraph) {
    if (_sectionRegex.hasMatch(paragraph)) {
      return paragraph;
    }
    if (_articleRegex.hasMatch(paragraph)) {
      // Articles are usually short headers, we truncate if too long
      return paragraph.length > 60
          ? '${paragraph.substring(0, 60)}…'
          : paragraph;
    }
    return null;
  }
}
