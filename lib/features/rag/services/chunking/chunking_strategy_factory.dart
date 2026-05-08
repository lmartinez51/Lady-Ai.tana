import 'package:aitana/features/rag/services/chunking/chunking_strategy.dart';
import 'package:aitana/features/rag/services/chunking/law_chunking_strategy.dart';
import 'package:aitana/features/rag/services/chunking/jurisprudencia_chunking_strategy.dart';
import 'package:aitana/features/rag/services/chunking/generic_chunking_strategy.dart';

class ChunkingStrategyFactory {
  /// Returns the appropriate [ChunkingStrategy] based on the document category.
  ///
  /// Matches categories defined in `LegalDocumentCategory`:
  /// - 'leyes' -> LawChunkingStrategy
  /// - 'jurisprudencia' -> JurisprudenceChunkingStrategy
  /// - 'doctrina' -> GenericChunkingStrategy
  static ChunkingStrategy getStrategy(String documentCategory) {
    switch (documentCategory.toLowerCase()) {
      case 'leyes':
        return LawChunkingStrategy();
      case 'jurisprudencia':
        return JurisprudenceChunkingStrategy();
      case 'doctrina':
      default:
        return GenericChunkingStrategy();
    }
  }
}
