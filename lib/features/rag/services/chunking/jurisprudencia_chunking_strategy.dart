import 'package:aitana/features/rag/services/chunking/chunking_strategy.dart';

class JurisprudenceChunkingStrategy implements ChunkingStrategy {
  /// Matches common structural headers in Mexican Jurisprudence (SCJN)
  static final RegExp _boundaryRegex = RegExp(
    r'^(RUBRO|EPOCA|[EÉ]POCA|VISTOS|RESULTANDOS|CONSIDERANDOS|RESUELVE|TRIBUNAL|PONENTE)\b',
    caseSensitive: false,
  );

  @override
  bool isBoundary(String paragraph) {
    return _boundaryRegex.hasMatch(paragraph);
  }

  @override
  String? extractChapterContext(String paragraph) {
    // In jurisprudence, "Época" or "Tribunal" often serve as high-level context
    if (paragraph.toUpperCase().contains('EPOCA') || 
        paragraph.toUpperCase().contains('ÉPOCA') ||
        paragraph.toUpperCase().contains('TRIBUNAL')) {
      return paragraph;
    }
    return null;
  }

  @override
  String? extractSectionContext(String paragraph) {
    // Specific sections like Rubro or Considerandos
    if (isBoundary(paragraph)) {
      return paragraph.length > 80 
          ? '${paragraph.substring(0, 80)}…' 
          : paragraph;
    }
    return null;
  }
}
