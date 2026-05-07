import 'package:objectbox/objectbox.dart';
import 'package:aitana/features/rag/models/legal_document_record.dart';

@Entity()
class LegalKnowledgeChunk {
  @Id()
  int id;

  String documentName;
  String chapterContext;
  String sectionContext;
  String rawText;

  @Index(type: IndexType.value)
  String searchableText;

  /// Authority weight inherited from the parent [LegalDocumentRecord].
  ///
  /// Used by [ObjectBoxService.searchLegalContext] to multiply the raw keyword
  /// hit count, ensuring higher-authority sources rank above doctrine even when
  /// the keyword overlap is identical.
  int authorityWeight;

  final document = ToOne<LegalDocumentRecord>();

  LegalKnowledgeChunk({
    this.id = 0,
    required this.documentName,
    required this.chapterContext,
    required this.sectionContext,
    required this.rawText,
    required this.searchableText,
    this.authorityWeight = 1,
  });
}
