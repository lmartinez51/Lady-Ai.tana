import 'package:objectbox/objectbox.dart';
import 'package:aitana/features/rag/models/legal_knowledge_chunk.dart';

/// Hierarchical authority taxonomy for legal documents.
///
/// The weight determines how strongly this document's chunks influence
/// the final RAG scoring. Higher-authority sources always outrank doctrine.
enum LegalDocumentCategory {
  /// Primary law sources: codes, statutes, regulations. Weight: 3.
  leyes(weight: 3, displayName: 'Ley / Código'),

  /// Supreme Court jurisprudence and case law. Weight: 2.
  jurisprudencia(weight: 2, displayName: 'Jurisprudencia (SCJN)'),

  /// Academic doctrine and legal literature. Weight: 1.
  doctrina(weight: 1, displayName: 'Doctrina / Literatura');

  const LegalDocumentCategory({required this.weight, required this.displayName});

  /// Multiplier applied to rawScore during RAG retrieval scoring.
  final int weight;

  /// Human-readable label for the UI dropdown.
  final String displayName;
}

@Entity()
class LegalDocumentRecord {
  @Id()
  int id;

  String title;
  String authorOrSource;

  @Property(type: PropertyType.date)
  DateTime uploadDate;

  int chunkCount;

  @Index(type: IndexType.value)
  String fileName;

  /// Stores the [LegalDocumentCategory] name (e.g., 'leyes', 'jurisprudencia').
  ///
  /// Stored as a String for ObjectBox compatibility. Parse back via
  /// `LegalDocumentCategory.values.byName(category)`.
  String category;

  @Backlink('document')
  final chunks = ToMany<LegalKnowledgeChunk>();

  LegalDocumentRecord({
    this.id = 0,
    required this.title,
    required this.authorOrSource,
    required this.uploadDate,
    this.chunkCount = 0,
    required this.fileName,
    this.category = 'doctrina',
  });
}
