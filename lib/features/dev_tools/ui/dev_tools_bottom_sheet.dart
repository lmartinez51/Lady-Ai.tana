import 'package:flutter/material.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/core/services/foreground_service_handler.dart';
import 'package:aitana/features/geofencing/ui/widgets/dev_geofence_modal.dart';

/// @brief A comprehensive developer toolkit menu.
///
/// Styled as a "Hacker/God Mode" control panel for Aitana.
class DevToolsBottomSheet extends StatelessWidget {
  const DevToolsBottomSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF161719), // Deeper obsidian for dev tools
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: AppColors.glassBorder, width: 1.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 24),

          Row(
            children: [
              const Icon(
                Icons.terminal_rounded,
                color: AppColors.cyberBlue,
                size: 24,
              ),
              const SizedBox(width: 12),
              const Text(
                'AITANA_DEV_CORE',
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
          const SizedBox(height: 24),

          // Grid of tools
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
                  Navigator.pop(context);
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
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Surveillance Terminated.'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      } else {
                        await ForegroundServiceControl.startService();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Surveillance Manually Activated.'),
                              backgroundColor: AppColors.cyberBlue,
                            ),
                          );
                        }
                      }
                    },
                  );
                },
              ),
              _DevToolTile(
                title: 'API Inspector',
                subtitle: 'Coming Soon',
                icon: Icons.api_rounded,
                color: Colors.white24,
                enabled: false,
                onTap: () {},
              ),
              _DevToolTile(
                title: 'Neural Logs',
                subtitle: 'LLM Context Audit',
                icon: Icons.psychology_rounded,
                color: Colors.white24,
                enabled: false,
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _DevToolTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;

  const _DevToolTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : Colors.white10;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: enabled
              ? effectiveColor.withAlpha(20)
              : Colors.white.withAlpha(5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: enabled
                ? effectiveColor.withAlpha(40)
                : Colors.white.withAlpha(10),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: effectiveColor, size: 28),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontFamily: 'Outfit',
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: enabled ? Colors.white54 : Colors.white12,
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
