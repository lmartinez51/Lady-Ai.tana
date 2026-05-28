import 'package:flutter/material.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/core/ui/app_snackbars.dart';
import 'package:aitana/core/services/foreground_service_handler.dart';
import 'package:aitana/features/geofencing/ui/widgets/dev_geofence_modal.dart';
import 'package:aitana/core/database/objectbox_service.dart';

/// @brief A comprehensive developer toolkit menu.
///
/// Styled as a "Hacker/God Mode" control panel for Aitana.
class DevToolsBottomSheet extends StatefulWidget {
  const DevToolsBottomSheet({super.key});

  @override
  State<DevToolsBottomSheet> createState() => _DevToolsBottomSheetState();
}

class _DevToolsBottomSheetState extends State<DevToolsBottomSheet> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 24, right: 24, top: 20, bottom: 0),
      decoration: const BoxDecoration(
        color: Color(0xFF161719), // Deeper obsidian for dev tools
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: AppColors.glassBorder, width: 1.5),
        ),
      ),
      child: ListView(
        shrinkWrap: true,
        physics: const ClampingScrollPhysics(),
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              const Icon(
                Icons.terminal_rounded,
                color: AppColors.cyberBlue,
                size: 24,
              ),
              const SizedBox(width: 12),
              const Text(
                'Developer Tools',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                'MODE: GOD',
                style: TextStyle(
                  color: AppColors.cyberBlue.withAlpha(180),
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          _buildSectionHeader(
            'System & Hardware Diagnostics',
            Icons.sensors_rounded,
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.1,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _DevToolTile(
                title: 'Geofence Logs',
                subtitle: 'Audit surveillance logs',
                icon: Icons.bug_report_rounded,
                color: AppColors.cyberBlue,
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    isScrollControlled: true,
                    builder: (_) => const DevGeofenceModal(),
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: ForegroundServiceControl.isServiceRunning,
                builder: (context, isRunning, _) {
                  return _DevToolTile(
                    title: isRunning
                        ? 'Kill Surveillance'
                        : 'Start Surveillance',
                    subtitle: isRunning
                        ? 'Stop background task'
                        : 'Manual activation',
                    icon: Icons.power_settings_new_rounded,
                    color: isRunning
                        ? Colors.orangeAccent
                        : AppColors.cyberBlue,
                    onTap: () async {
                      Navigator.pop(context);
                      if (isRunning) {
                        await ForegroundServiceControl.stopService();
                      } else {
                        await ForegroundServiceControl.startService();
                      }
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          _buildSectionHeader('Core Data Hygiene', Icons.storage_rounded),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.1,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _DevToolTile(
                title: 'Purge Legal Library',
                subtitle: 'Wipe PDFs & Chunks',
                icon: Icons.gavel_rounded,
                color: Colors.white70,
                onTap: () => _confirmNuke(
                  context,
                  'Purge Legal Library?',
                  'This will delete all physical PDF documents and the semantic ObjectBox index.',
                  () => ObjectBoxService.instance.nukeLegalLibrary(),
                ),
              ),
              _DevToolTile(
                title: 'Clear Chat Logs',
                subtitle: 'Wipe conversation history',
                icon: Icons.forum_rounded,
                color: Colors.white70,
                onTap: () => _confirmNuke(
                  context,
                  'Clear Chat History?',
                  'This will permanently delete all conversations and message records.',
                  () => ObjectBoxService.instance.nukeChatHistory(),
                ),
              ),
              _DevToolTile(
                title: 'Empty Personal Vault',
                subtitle: 'Wipe Images & OCR',
                icon: Icons.lock_reset_rounded,
                color: Colors.white70,
                onTap: () => _confirmNuke(
                  context,
                  'Empty Personal Vault?',
                  'This will delete all analyzed images from the sandbox and purge the OCR database.',
                  () => ObjectBoxService.instance.nukePersonalVault(),
                ),
              ),
              _DevToolTile(
                title: 'MASTER NUKE',
                subtitle: 'Full Factory Reset',
                icon: Icons.bolt_rounded,
                color: Colors.redAccent,
                onTap: () => _confirmNuke(
                  context,
                  'MASTER NUKE (Wipe Everything)?',
                  'EXTREME DANGER: This wipes all chat history, legal documents, personas, and vault images. The system will be factory reset.',
                  () => ObjectBoxService.instance.nukeDatabase(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.white24, size: 16),
        const SizedBox(width: 8),
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  void _confirmNuke(
    BuildContext context,
    String title,
    String content,
    Future<void> Function() action,
  ) {
    final rootMessenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F20),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(content, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              child: const Text(
                'CANCEL',
                style: TextStyle(color: Colors.white54),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: const Text(
                'EXECUTE NUKE',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: () async {
                Navigator.of(dialogContext).pop(); // Close dialog
                Navigator.of(context).pop(); // Close bottom sheet
                await action();
                AppSnackBars.showSuccessFromMessenger(
                  rootMessenger,
                  'Operation Complete. Target Purged.',
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _DevToolTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _DevToolTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withAlpha(40), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'Outfit',
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: Colors.white54,
                fontFamily: 'Outfit',
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
