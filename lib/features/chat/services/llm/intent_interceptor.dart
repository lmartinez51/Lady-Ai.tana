import 'package:flutter/foundation.dart';

/// Intercepts and analyzes user prompts to inject routing hints for the LLM.
/// This reduces the model's cognitive load and enforces strict tool usage
/// rules prior to hitting the native engine.
class IntentInterceptor {
  // ─── Dictionaries & Regex Patterns ────────────────────────────────────────

  // Hardware Keywords
  static final RegExp _hardwareRegex = RegExp(
    r'\b(toma video|graba|empieza a grabar video|record video)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Explicit Calendar Keywords
  static final RegExp _explicitCalendarRegex = RegExp(
    r'\b(agenda|calendario|calendar)\b',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _calendarQueryVerbsRegex = RegExp(
    r'\b(qué tengo|que tengo|dime|revisa|what do i have|check)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Action Verbs for Calendar (with optional clitic pronouns)
  static final RegExp _calendarActionVerbsRegex = RegExp(
    r'\b(agrega|pon|add|schedule)(?:lo|la|los|las|le|les)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Geofence Keywords
  static final RegExp _geofenceLocationRegex = RegExp(
    r'\b(work|home|walmart|hooters|whataburger|trabajo|casa|oficina)\b',
    caseSensitive: false,
    unicode: true,
  );

  // General Action Verbs used in both Geofence and Calendar (with optional clitic pronouns)
  static final RegExp _actionVerbsRegex = RegExp(
    r'\b(avísame|avisame|recuérdame|recuerdame|remind|notify|tell)(?:lo|la|los|las|le|les)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Implicit Time Markers
  static final RegExp _timeMarkersRegex = RegExp(
    r'\b(mañana|manana|hoy|a las|pm|am|viernes|tomorrow|today)\b',
    caseSensitive: false,
    unicode: true,
  );

  // ─── Main Intercept Method ────────────────────────────────────────────────

  /// Analyzes the [originalPrompt] and prepends a cumulative `[SYSTEM HINT: ...]`
  /// if it matches criteria for hardware, calendar, or geofence routing.
  /// If no criteria are met, returns the prompt unmodified.
  static String processPrompt(String originalPrompt) {
    final lowerPrompt = originalPrompt.toLowerCase();
    final List<String> hints = [];

    // 1. HARDWARE (Evaluated first, does not block others)
    if (_hardwareRegex.hasMatch(lowerPrompt)) {
      debugPrint('🧠 [IntentInterceptor] Hardware match detected.');
      hints.add('USE <START_VIDEO>');
    }

    bool geofenceDetected = false;

    // 2. GEOFENCE (Evaluated before Calendar to enforce Space Override)
    if (_geofenceLocationRegex.hasMatch(lowerPrompt) &&
        _actionVerbsRegex.hasMatch(lowerPrompt)) {
      debugPrint('🧠 [IntentInterceptor] Geofence match detected.');
      hints.add('USE <GEOFENCE>. SPACE ALWAYS WINS.');
      geofenceDetected = true;
    }

    // 3. CALENDAR (Explicit and Implicit)
    // Enforce Space Override Rule: Do NOT add Calendar hints if Geofence is detected.
    if (!geofenceDetected) {
      if (_explicitCalendarRegex.hasMatch(lowerPrompt)) {
        if (_calendarQueryVerbsRegex.hasMatch(lowerPrompt)) {
          debugPrint(
            '🧠 [IntentInterceptor] Explicit Calendar (Query) match detected.',
          );
          hints.add(
            'GENERAL CHAT. Check schedule context but DO NOT use tools.',
          );
        } else if (_calendarActionVerbsRegex.hasMatch(lowerPrompt) ||
            _actionVerbsRegex.hasMatch(lowerPrompt)) {
          debugPrint(
            '🧠 [IntentInterceptor] Explicit Calendar (Action) match detected.',
          );
          hints.add('USE manage_calendar');
        } else {
          // If it mentions calendar but lacks a clear action verb, default to chat
          debugPrint(
            '🧠 [IntentInterceptor] Explicit Calendar (No Action) match detected.',
          );
          hints.add(
            'GENERAL CHAT. Check schedule context but DO NOT use tools.',
          );
        }
      } else if (_timeMarkersRegex.hasMatch(lowerPrompt) &&
          (_calendarActionVerbsRegex.hasMatch(lowerPrompt) ||
              _actionVerbsRegex.hasMatch(lowerPrompt))) {
        debugPrint('🧠 [IntentInterceptor] Implicit Calendar match detected.');
        hints.add('USE manage_calendar');
      }
    }

    // 4. GENERAL CHAT (No hints)
    if (hints.isEmpty) {
      return originalPrompt;
    }

    // Join cumulative hints with a pipe separator
    final combinedHints = hints.join(' | ');
    return '[SYSTEM HINT: $combinedHints]\n\n$originalPrompt';
  }
}
