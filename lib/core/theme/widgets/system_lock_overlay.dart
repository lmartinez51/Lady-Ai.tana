import 'package:flutter/material.dart';
import 'package:aitana/core/theme/app_colors.dart';

/// A reusable full-screen overlay that blocks user interaction during
/// critical system operations (RAM-heavy tasks, exit sequences, etc.).
class SystemLockOverlay extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool showSpinner;
  final Color? overlayColor;

  const SystemLockOverlay({
    super.key,
    required this.title,
    required this.subtitle,
    this.showSpinner = true,
    this.overlayColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ── Interaction Lock ──────────────────────────────────────────────────
        // The ModalBarrier absorbs all pointer events, preventing the user
        // from interacting with the background UI (Drawer, buttons, keyboard).
        const ModalBarrier(
          dismissible: false,
          color: Colors.transparent,
        ),

        // ── Visual Scrim & Content ────────────────────────────────────────────
        Container(
          width: double.infinity,
          height: double.infinity,
          color: overlayColor ?? Colors.black.withAlpha(178), // ≈ 0.70 opacity for premium feel
          child: Material(
            // Material ancestor is CRITICAL here to prevent the yellow/red 
            // underline bug when this is used at the top level of a Stack 
            // outside of a normal Scaffold/Material widget hierarchy.
            color: Colors.transparent,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSpinner) ...[
                      const CircularProgressIndicator(
                        color: AppColors.cyberBlue,
                        strokeWidth: 2.5,
                      ),
                      const SizedBox(height: 32),
                    ],
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.textHigh,
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                        letterSpacing: 0.5,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.textMedium,
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w400,
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
