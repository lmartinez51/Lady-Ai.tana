import 'package:flutter/material.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:aitana/core/services/device/device_event_service.dart';

/// The floating "pill" header for the main chat interface.
///
/// Extracted from MainChatScreen to satisfy SRP and improve readability.
/// Orchestrates model switching, status visualization, and quick actions.
class ChatHeaderWidget extends StatelessWidget {
  final VoidCallback onMenuPressed;
  final VoidCallback onModelSelectorPressed;
  final VoidCallback onClearMemoryPressed;
  final VoidCallback onExitPressed;
  final VoidCallback onLongPressPill;
  final String personaCategory;

  const ChatHeaderWidget({
    super.key,
    required this.onMenuPressed,
    required this.onModelSelectorPressed,
    required this.onClearMemoryPressed,
    required this.onExitPressed,
    required this.onLongPressPill,
    required this.personaCategory,
  });

  Color _getPersonaColor() {
    switch (personaCategory) {
      case 'AI':
        return const Color(0xFFFFFFFF); // Cyberpunk Purple
      case 'HUMAN':
        return const Color(0xFF03DAC6); // Matrix Teal
      case 'LEGAL':
        return const Color(0xFFFFD700); // Prestige Gold
      default:
        return Colors.white;
    }
  }

  @override
  Widget build(BuildContext context) {
    final personaColor = _getPersonaColor();
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
        child: ValueListenableBuilder<bool>(
          valueListenable: DeviceEventService.isVideoRecording,
          builder: (context, isRecordingVideo, _) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── FAR LEFT: Hamburger (outside pill) ─────────────────
                IconButton(
                  icon: const Icon(
                    Icons.menu_rounded,
                    color: AppColors.textMedium,
                  ),
                  onPressed: onMenuPressed,
                  tooltip: 'Menu',
                ),
                const SizedBox(width: 4),

                // ── MIDDLE: Animated Pill ───────────────────────────────
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeInOut,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AppColors.deepIndigo,
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(
                        color: isRecordingVideo
                            ? Colors.redAccent.withAlpha(120)
                            : personaColor.withAlpha(150),
                        width: isRecordingVideo ? 1.5 : 1.0,
                      ),
                      boxShadow: isRecordingVideo
                          ? [
                              BoxShadow(
                                color: Colors.redAccent.withAlpha(80),
                                blurRadius: 18,
                                spreadRadius: 2,
                              ),
                              BoxShadow(
                                color: Colors.redAccent.withAlpha(40),
                                blurRadius: 40,
                                spreadRadius: 4,
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: personaColor.withAlpha(51),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(50),
                        onTap: onModelSelectorPressed,
                        onLongPress: onLongPressPill,
                        child: ValueListenableBuilder<String>(
                          valueListenable: LocalLlmService.status,
                          builder: (context, status, _) {
                            Color modelColor = personaColor;
                            if (status == 'loading') {
                              modelColor = Colors.orangeAccent;
                            } else if (status == 'error') {
                              modelColor = Colors.redAccent;
                            }

                            return Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: ValueListenableBuilder<AiModelInfo>(
                                    valueListenable:
                                        LocalLlmService.currentModel,
                                    builder: (context, currentModel, _) {
                                      return ValueListenableBuilder<String>(
                                        valueListenable: LocalLlmService
                                            .currentLanguageNotifier,
                                        builder: (context, currentLang, _) {
                                          return Text(
                                            'Lady Ai.tana (${currentModel.shortName})      [$currentLang]',
                                            style: TextStyle(
                                              color: modelColor,
                                              fontFamily: 'Outfit',
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                                // 🔴 Video recording icon (only when active)
                                if (isRecordingVideo) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: 'Recording video',
                                    child: Icon(
                                      Icons.fiber_manual_record,
                                      size: 14,
                                      color: Colors.redAccent.withAlpha(220),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // ── FAR RIGHT: Royal Avatar (outside pill) ─────────────
                PopupMenuButton<String>(
                  tooltip: 'More options',
                  color: AppColors.deepIndigo,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(
                      color: AppColors.glassBorder,
                      width: 1,
                    ),
                  ),
                  offset: const Offset(0, 52),
                  onSelected: (value) {
                    if (value == 'clear_memory') {
                      onClearMemoryPressed();
                    } else if (value == 'switch_model') {
                      onModelSelectorPressed();
                    } else if (value == 'exit') {
                      onExitPressed();
                    }
                  },
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'switch_model',
                      child: Row(
                        children: [
                          Icon(
                            Icons.swap_horiz_rounded,
                            color: AppColors.cyberBlue,
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Switch Model',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'clear_memory',
                      child: Row(
                        children: [
                          Icon(
                            Icons.cleaning_services_rounded,
                            color: Colors.orangeAccent,
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Clear Context',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(height: 1),
                    const PopupMenuItem<String>(
                      value: 'exit',
                      child: Row(
                        children: [
                          Icon(
                            Icons.power_settings_new_rounded,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Exit Aitana',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.cyberBlue.withAlpha(100),
                        width: 1.5,
                      ),
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/aitana_avatar.webp',
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.face_retouching_natural,
                          color: AppColors.cyberBlue,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
