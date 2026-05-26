import 'package:flutter/material.dart';

/// A reusable full-screen overlay that blocks user interaction during
/// critical system operations (RAM-heavy tasks, exit sequences, etc.).
class SystemLockOverlay extends StatefulWidget {
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
  State<SystemLockOverlay> createState() => _SystemLockOverlayState();
}

class _SystemLockOverlayState extends State<SystemLockOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const ModalBarrier(dismissible: false, color: Colors.transparent),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: _CoreGlowBand(animation: _glowController),
        ),
      ],
    );
  }
}

class _CoreGlowBand extends StatelessWidget {
  final Animation<double> animation;

  const _CoreGlowBand({required this.animation});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final value = animation.value;
            final beginX = -1.35 + (value * 0.9);
            final endX = 0.35 + (value * 1.45);

            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(beginX, -1),
                  end: Alignment(endX, 1),
                  colors: const [
                    Color(0xCC2A0F6E),
                    Color(0xD900F0FF),
                    Color(0xCC111827),
                  ],
                  stops: const [0.0, 0.48, 1.0],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x7300F0FF),
                    blurRadius: 34,
                    spreadRadius: -12,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x2200F0FF),
                      Color(0x660B0D17),
                      Color(0x000B0D17),
                    ],
                    stops: [0.0, 0.62, 1.0],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
