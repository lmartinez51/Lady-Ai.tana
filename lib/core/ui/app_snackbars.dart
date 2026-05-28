import 'package:aitana/core/theme/app_colors.dart';
import 'package:flutter/material.dart';

class AppSnackBars {
  static const double _horizontalMargin = 16.0;
  static const double _defaultBottomGap = 24.0;
  static const double _borderRadius = 12.0;
  static const int _maxMessageLines = 4;
  static const Duration _defaultDuration = Duration(seconds: 4);

  const AppSnackBars._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSuccess(
    BuildContext context,
    String message, {
    double? bottomMargin,
    Duration? duration,
  }) {
    return _show(
      context,
      message,
      bottomMargin: bottomMargin,
      duration: duration,
      tone: const _SnackBarTone(
        icon: Icons.check_circle_rounded,
        accent: Color(0xFF36E27A),
        background: Color(0xF20C1512),
        border: Color(0x9936E27A),
        shadow: Color(0x5236E27A),
      ),
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
  showSuccessFromMessenger(
    ScaffoldMessengerState messenger,
    String message, {
    double? bottomMargin,
    Duration? duration,
  }) {
    return _showWithMessenger(
      messenger,
      message,
      bottomMargin: bottomMargin ?? _defaultBottomGap,
      duration: duration,
      tone: const _SnackBarTone(
        icon: Icons.check_circle_rounded,
        accent: Color(0xFF36E27A),
        background: Color(0xF20C1512),
        border: Color(0x9936E27A),
        shadow: Color(0x5236E27A),
      ),
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showError(
    BuildContext context,
    String message, {
    double? bottomMargin,
    Duration? duration,
  }) {
    return _show(
      context,
      message,
      bottomMargin: bottomMargin,
      duration: duration,
      tone: const _SnackBarTone(
        icon: Icons.error_rounded,
        accent: AppColors.error,
        background: Color(0xF2180D12),
        border: Color(0x99FF4D4D),
        shadow: Color(0x52FF4D4D),
      ),
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showWarning(
    BuildContext context,
    String message, {
    double? bottomMargin,
    Duration? duration,
  }) {
    return _show(
      context,
      message,
      bottomMargin: bottomMargin,
      duration: duration,
      tone: const _SnackBarTone(
        icon: Icons.warning_amber_rounded,
        accent: Color(0xFFFFC857),
        background: Color(0xF2191408),
        border: Color(0x99FFC857),
        shadow: Color(0x52FFC857),
      ),
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showInfo(
    BuildContext context,
    String message, {
    double? bottomMargin,
    Duration? duration,
  }) {
    return _show(
      context,
      message,
      bottomMargin: bottomMargin,
      duration: duration,
      tone: const _SnackBarTone(
        icon: Icons.info_rounded,
        accent: AppColors.cyberBlue,
        background: Color(0xF20B0D17),
        border: Color(0x9900ADB5),
        shadow: Color(0x5200ADB5),
      ),
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _show(
    BuildContext context,
    String message, {
    required _SnackBarTone tone,
    double? bottomMargin,
    Duration? duration,
  }) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final resolvedBottomMargin =
        bottomMargin ??
        ((mediaQuery?.viewPadding.bottom ?? 0.0) + _defaultBottomGap);

    return _showWithMessenger(
      ScaffoldMessenger.of(context),
      message,
      bottomMargin: resolvedBottomMargin,
      duration: duration,
      tone: tone,
    );
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
  _showWithMessenger(
    ScaffoldMessengerState messenger,
    String message, {
    required _SnackBarTone tone,
    required double bottomMargin,
    Duration? duration,
  }) {
    return messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.fromLTRB(
          _horizontalMargin,
          0,
          _horizontalMargin,
          bottomMargin,
        ),
        padding: EdgeInsets.zero,
        duration: duration ?? _defaultDuration,
        dismissDirection: DismissDirection.down,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
        ),
        content: _AppSnackBarContent(message: message, tone: tone),
      ),
    );
  }
}

class _AppSnackBarContent extends StatelessWidget {
  final String message;
  final _SnackBarTone tone;

  const _AppSnackBarContent({required this.message, required this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(AppSnackBars._borderRadius),
        border: Border.all(color: tone.border, width: 1),
        boxShadow: [
          BoxShadow(
            color: tone.shadow,
            blurRadius: 24,
            spreadRadius: -8,
            offset: const Offset(0, 10),
          ),
          const BoxShadow(
            color: Color(0x99000000),
            blurRadius: 18,
            spreadRadius: -10,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tone.accent.withAlpha(31),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tone.accent.withAlpha(112), width: 1),
            ),
            child: Icon(tone.icon, color: tone.accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              maxLines: AppSnackBars._maxMessageLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textHigh,
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnackBarTone {
  final IconData icon;
  final Color accent;
  final Color background;
  final Color border;
  final Color shadow;

  const _SnackBarTone({
    required this.icon,
    required this.accent,
    required this.background,
    required this.border,
    required this.shadow,
  });
}
