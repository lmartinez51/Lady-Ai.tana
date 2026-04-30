import 'package:objectbox/objectbox.dart';

@Entity()
class ChatSession {
  // El ID siempre debe ser entero para ObjectBox.
  // 0 significa "nuevo", ObjectBox le asignará un ID real al insertarlo.
  @Id()
  int id = 0;

  // Un título autogenerado o asignado para identificar el chat
  String title;

  // El resumen comprimido del contenido de la charla
  String summary;

  // ¿El usuario lo marcó como favorito/pineado?
  bool isPinned;

  // Fechas de control
  @Property(type: PropertyType.date)
  DateTime createdAt;

  @Property(type: PropertyType.date)
  DateTime updatedAt;

  ChatSession({
    this.id = 0,
    required this.title,
    this.summary = '',
    this.isPinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
}
