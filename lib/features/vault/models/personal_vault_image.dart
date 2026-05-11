import 'package:objectbox/objectbox.dart';
import 'personal_vault_analysis.dart';

@Entity()
class PersonalVaultImage {
  @Id()
  int id;

  /// Absolute path in the native sandbox.
  String fileUri;

  /// SHA-256 for deduplication.
  @Index()
  String imageHash;

  @Property(type: PropertyType.date)
  DateTime uploadDate;

  /// To categorize, e.g., 'receipts', 'general'.
  String shelf;

  @Backlink('parentImage')
  final analysisChunks = ToMany<PersonalVaultAnalysis>();

  PersonalVaultImage({
    this.id = 0,
    required this.fileUri,
    required this.imageHash,
    required this.uploadDate,
    required this.shelf,
  });
}
