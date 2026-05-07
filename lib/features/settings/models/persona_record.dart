import 'package:objectbox/objectbox.dart';

@Entity()
class PersonaRecord {
  @Id()
  int id;

  String name;
  String category;
  String promptEs;
  String promptEn;
  String defaultLang;
  bool isActive;

  PersonaRecord({
    this.id = 0,
    required this.name,
    required this.category,
    required this.promptEs,
    required this.promptEn,
    required this.defaultLang,
    this.isActive = false,
  });
}
