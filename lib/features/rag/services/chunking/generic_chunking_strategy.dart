import 'package:aitana/features/rag/services/chunking/chunking_strategy.dart';

class GenericChunkingStrategy implements ChunkingStrategy {
  @override
  bool isBoundary(String paragraph) {
    // Generic strategy doesn't enforce structural boundaries beyond size
    // which is handled in the main chunking loop.
    return false;
  }

  @override
  String? extractChapterContext(String paragraph) => null;

  @override
  String? extractSectionContext(String paragraph) => null;
}
