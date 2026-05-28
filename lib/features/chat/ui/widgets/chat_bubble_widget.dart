import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/core/ui/app_snackbars.dart';
import 'package:aitana/features/chat/domain/entities/chat_message.dart';
import 'package:aitana/features/chat/ui/widgets/audio_bubble.dart';

const Color _kAitanaBubbleBase = Color(0xFF101827);
const Color _kLorenzoBubbleBorder = Color(0x333EE7F2);
const Color _kAitanaBubbleBorder = Color(0x6600ADB5);
const Color _kBubbleTextHigh = Color(0xFFF4F8FF);
const Color _kAitanaTextHigh = Color(0xFFEAFBFF);

class ChatBubbleWidget extends StatelessWidget {
  final ChatMessage message;
  final Color userBubbleColor;
  final double? snackBarBottomMargin;

  const ChatBubbleWidget({
    super.key,
    required this.message,
    required this.userBubbleColor,
    this.snackBarBottomMargin,
  });

  void _copyToClipboard(String text, BuildContext context) {
    Clipboard.setData(ClipboardData(text: text));
    AppSnackBars.showSuccess(
      context,
      'Copied to clipboard',
      bottomMargin: snackBarBottomMargin,
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
          child: Container(
            padding: const EdgeInsets.only(
              left: 24,
              right: 24,
              top: 20,
              bottom: 0,
            ),
            decoration: const BoxDecoration(
              color: Color(0xF20B0D17),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                top: BorderSide(color: Color(0x3300ADB5), width: 1.0),
              ),
            ),
            child: SafeArea(
              bottom: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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

                  const Text(
                    'Select an active protocol to apply to this data transmission.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontFamily: 'Outfit',
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),

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
                ],
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
          decoration: const BoxDecoration(
            color: Color(0xFF11131E),
            borderRadius: BorderRadius.all(Radius.circular(16)),
            border: Border.fromBorderSide(
              BorderSide(color: Color(0x66D4AF37), width: 1.0),
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
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
    final isUser = message.isUser;
    final bubbleColor = isUser ? userBubbleColor : _kAitanaBubbleBase;
    final borderColor = isUser ? _kLorenzoBubbleBorder : _kAitanaBubbleBorder;
    final textColor = isUser ? _kBubbleTextHigh : _kAitanaTextHigh;
    final textWeight = isUser ? FontWeight.w500 : FontWeight.w400;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x1A00ADB5),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x6600ADB5), width: 1),
              ),
              child: const Text(
                'AI',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFFD7FBFF),
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: !isUser ? () => _showContextMenu(context) : null,
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
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isUser ? 18 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 18),
                  ),
                  border: Border.all(color: borderColor, width: 1),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: isUser
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
                        isUser: isUser,
                      ),
                      if (message.text.isNotEmpty) const SizedBox(height: 8),
                    ],
                    // ─── VAULT IMAGE RENDERING ───
                    if (!isUser && message.text.contains('Source URI: ')) ...[
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
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          fontFamily: 'Outfit',
                          fontWeight: textWeight,
                          height: 1.42,
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
