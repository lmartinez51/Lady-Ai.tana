import 'package:flutter/material.dart';

class PersonaThemeRouter {
  static const Color humanColor = Color(0xFF00FF41);
  static const Color aiColor = Color(0xFF00F0FF);
  static const Color legalColor = Color(0xFFFFD700);

  /// Returns the target model base name. Only HUMAN uses the variant model.
  static String getModelBaseName(String category) {
    final cat = category.toUpperCase();
    if (cat == 'HUMAN') {
      return 'gemma_4b_variant';
    } else {
      return 'gemma_4b';
    }
  }

  /// Returns the primary theme color for the given persona category.
  static Color getThemeColor(String category) {
    final cat = category.toUpperCase();
    switch (cat) {
      case 'HUMAN':
        return humanColor;
      case 'AI':
        return aiColor;
      case 'LEGAL':
        return legalColor;
      default:
        return Colors.white;
    }
  }
}
