import 'package:objectbox/objectbox.dart';

@Entity()
class AutoPilotContact {
  @Id()
  int id;

  String contactName;
  bool isActive;

  AutoPilotContact({
    this.id = 0,
    required this.contactName,
    this.isActive = true,
  });
}
