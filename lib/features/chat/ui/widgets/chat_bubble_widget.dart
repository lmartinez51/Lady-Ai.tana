import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/domain/entities/chat_message.dart';
import 'package:aitana/features/chat/ui/widgets/audio_bubble.dart';

class ChatBubbleWidget extends StatelessWidget {
  final ChatMessage message;
  final Color userBubbleColor;

  const ChatBubbleWidget({
    super.key,
    required this.message,
    required this.userBubbleColor,
  });

  void _copyToClipboard(String text, BuildContext context) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(
              "Copied to clipboard",
              style: TextStyle(fontFamily: 'Outfit', color: Colors.white),
            ),
          ],
        ),
        backgroundColor: AppColors.cyberBlue,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext bottomSheetContext) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.only(left: 24, right: 24, top: 20, bottom: 0),
              decoration: BoxDecoration(
                color: AppColors.deepIndigo.withAlpha(200),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                border: const Border(
                  top: BorderSide(color: AppColors.glassBorder, width: 1.0),
                ),
              ),
              child: SafeArea(
                bottom: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Title row
                    const Row(
                      children: [
                        Icon(
                          Icons.settings_input_component,
                          color: AppColors.cyberBlue,
                          size: 24,
                        ),
                        SizedBox(width: 12),
                        Text(
                          'Message Protocols',
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'Outfit',
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Subtitle 1
                    const Text(
                      'Select an active protocol to apply to this data transmission.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontFamily: 'Outfit',
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),

                    // Subtitle 2
                    const Text(
                      'Security: Local Sandbox | Source: Verified Inherent State',
                      style: TextStyle(
                        color: Colors.white38,
                        fontFamily: 'Outfit',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Divider(color: Colors.white12, height: 1),
                    const SizedBox(height: 8),

                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy, color: Colors.white),
                      title: const Text(
                        "Copy to Clipboard",
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          color: Colors.white,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(bottomSheetContext);
                        _copyToClipboard(message.text, context);
                      },
                    ),
                    // TODO: Add future actions here (e.g., Delete, Translate, Share)
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ─── CASO ESPECIAL: BURBUJA ORÁCULO (Resumen del Historial) ───
    if (message.isSystemOracle) {
      return Align(
        alignment: Alignment.center, // Centrado total
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          padding: const EdgeInsets.all(16),
          width: MediaQuery.of(context).size.width * 0.85, // Más ancha
          decoration: BoxDecoration(
            color: AppColors.deepIndigo.withAlpha(
              150,
            ), // Fondo cristalino oscuro
            borderRadius: BorderRadius.circular(16), // Completamente redondeada
            border: Border.all(
              color: const Color(
                0xFFD4AF37,
              ).withAlpha(100), // Borde dorado tenue
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              // El icono de la cápsula del tiempo / ojo
              const Icon(
                Icons.history_edu_rounded,
                color: Color(0xFFD4AF37), // Dorado
                size: 28,
              ),
              const SizedBox(height: 8),
              Text(
                message.text,
                textAlign: TextAlign.center, // Texto centrado
                style: const TextStyle(
                  color: Colors
                      .white70, // Texto un poco más tenue que los mensajes normales
                  fontSize: 14,
                  fontFamily: 'Outfit',
                  height: 1.5,
                  fontStyle: FontStyle.italic, // Cursiva para denotar memoria
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ─── CASO NORMAL: MENSAJES DE LORENZO O AITANA ───
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isUser) ...[
            CircleAvatar(
              radius: 12,
              backgroundColor: AppColors.cyberBlue.withAlpha(50),
              child: const Text(
                'AI',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMedium,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: !message.isUser
                  ? () => _showContextMenu(context)
                  : null,
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                decoration: BoxDecoration(
                  color: message.isUser
                      ? userBubbleColor
                      : AppColors.deepIndigo,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(message.isUser ? 18 : 4),
                    bottomRight: Radius.circular(message.isUser ? 4 : 18),
                  ),
                  border: message.isUser
                      ? null
                      : Border.all(color: AppColors.glassBorder, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(25),
                      blurRadius: 3,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: message.isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (message.imagePath != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(message.imagePath!),
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      if (message.text.isNotEmpty || message.audioPath != null)
                        const SizedBox(height: 8),
                    ],
                    if (message.audioPath != null) ...[
                      AudioBubble(
                        audioPath: message.audioPath!,
                        durationText: message.audioDuration ?? '0.0s',
                        isUser: message.isUser,
                      ),
                      if (message.text.isNotEmpty) const SizedBox(height: 8),
                    ],
                    // ─── VAULT IMAGE RENDERING ───
                    if (!message.isUser &&
                        message.text.contains('Source URI: ')) ...[
                      Builder(
                        builder: (context) {
                          final regex = RegExp(r'Source URI: ([^\s\n]+)');
                          final match = regex.firstMatch(message.text);
                          if (match != null) {
                            final path = match.group(1)!;
                            if (File(path).existsSync()) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.file(
                                    File(path),
                                    width: double.infinity,
                                    height: 150,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              );
                            }
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                    if (message.text.isNotEmpty)
                      Text(
                        message.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontFamily: 'Outfit',
                          height: 1.4,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
