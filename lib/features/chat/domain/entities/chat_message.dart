class ChatMessage {
  String text;
  final bool isUser;
  final String? imagePath;
  final String? audioPath;
  final String? audioDuration;
  final bool isSystemOracle;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.audioPath,
    this.audioDuration,
    this.isSystemOracle = false,
  });
}
