import 'dart:typed_data';
import 'package:objectbox/objectbox.dart';
import 'personal_vault_image.dart';

@Entity()
class PersonalVaultAnalysis {
  @Id()
  int id;

  String rawJson;

  /// Mapped from JSON 'image_description'.
  String imageDescription;

  /// Mapped from JSON 'objects'.
  String objects;

  /// Mapped from JSON 'environment'.
  String environment;

  /// Mapped from JSON 'text_content'.
  String textContent;

  /// Concatenated strings for RAG vector/text matching.
  @Index(type: IndexType.value)
  String searchableText;

  @HnswIndex(dimensions: 384)
  Float32List? metadataVector;

  String? categoryEmoji;
  String? categoryKeyword;

  final parentImage = ToOne<PersonalVaultImage>();

  PersonalVaultAnalysis({
    this.id = 0,
    required this.rawJson,
    required this.imageDescription,
    required this.objects,
    required this.environment,
    required this.textContent,
    required this.searchableText,
    this.metadataVector,
    this.categoryEmoji,
    this.categoryKeyword,
  });
}
