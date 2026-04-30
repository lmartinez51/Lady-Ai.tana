import 'package:flutter/material.dart';

class AppColors {
  // Primary Palette
  static const Color obsidian = Color(0xFF0D0D0E);
  static const Color deepIndigo = Color(0xFF1A1A2E);
  static const Color cyberBlue = Color(0xFF00ADB5);
  static const Color neonPurple = Color(0xFF7B2CBF);
  
  // Neutral Palette
  static const Color glassWhite = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color textHigh = Color(0xFFEEEEEE);
  static const Color textMedium = Color(0xFFB0B0B0);
  static const Color error = Color(0xFFFF4D4D);
  
  // Gradients
  static const LinearGradient premiumGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [deepIndigo, obsidian],
  );
}
