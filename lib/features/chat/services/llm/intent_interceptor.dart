import 'package:flutter/foundation.dart';

/// Intercepts and analyzes user prompts to inject routing hints for the LLM.
/// This reduces the model's cognitive load and enforces strict tool usage
/// rules prior to hitting the native engine.
class IntentInterceptor {
  static const String _cameraVerbFragment =
      r'(?:toma(?:me)?|tomar|graba(?:me)?|grabar|enciende|prende|abre|activa|open|turn on|run|record|take)';
  static const String _cameraTargetFragment =
      r'(?:video|camara|camera|feed|grabacion|optics)';

  // Hardware keywords. Evaluated after normalization, so this catches
  // "tomame un video corto", "[toma el video]", and "enciende camara".
  static final RegExp _hardwareRegex = RegExp(
    r'\b(?:empieza|pon|ponte)\s+a\s+grabar\b|'
    r'\b(?:camera feed|video feed|video interface)\b|'
    '\\b$_cameraVerbFragment\\b(?:\\s+\\w+){0,5}\\s+\\b$_cameraTargetFragment\\b|'
    r'\b(?:graba(?:me)?|grabar|record)\b(?:\s+\w+){0,4}',
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
    r'\b(que tengo|dime|revisa|what do i have|check)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Action Verbs for Calendar (with optional clitic pronouns 'me', 'lo', etc.)
  static final RegExp _calendarActionVerbsRegex = RegExp(
    r'\b(agrega|pon|add|schedule|apunta|anota|guarda|agenda|agendar)(?:lo|la|los|las|le|les|me)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Geofence Keywords (normalized Spanish slang and border locations)
  static final RegExp _geofenceLocationRegex = RegExp(
    r'\b(work|home|walmart|hooters|whataburger|trabajo|casa|oficina|jale|chamba|canton|el paso|juarez|chuco)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Spatial Triggers (key location triggers for geofences)
  static final RegExp _geofenceTriggersRegex = RegExp(
    r'\b(llegando|llegar|llegue|cuando ande|en cuanto llegue|al llegar)\b',
    caseSensitive: false,
    unicode: true,
  );

  // General Action Verbs used in both Geofence and Calendar.
  static final RegExp _actionVerbsRegex = RegExp(
    r'\b(avisame|recuerdame|remind|notify|tell|acuerdame|recordatorio|avisa|recuerda|acuerda|tira paro|hazme el paro|echame un grito)(?:lo|la|los|las|le|les|me)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Implicit Time Markers
  static final RegExp _timeMarkersRegex = RegExp(
    r'\b(manana|hoy|a las|pm|am|lunes|martes|miercoles|jueves|viernes|sabado|domingo|tomorrow|today)\b',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _vaultRegex = RegExp(
    r'\b(boveda|vault|mis fotos|mis recibos|mi boveda|personal vault|receipts|documents|analyzed images|search vault)\b',
    caseSensitive: false,
    unicode: true,
  );

  static String _normalizePrompt(String prompt) {
    var normalized = prompt.toLowerCase();

    normalized = normalized.replaceAll(
      RegExp(
        r'\[(?:risa|risas|laughs?|laughter|silencio|noise|ruido)\]',
        caseSensitive: false,
      ),
      ' ',
    );
    normalized = normalized.replaceAll(RegExp(r'[\[\]\(\)\{\}]'), ' ');
    normalized = normalized.replaceAll(
      RegExp('[\u00e1\u00e0\u00e4\u00e2\u00e3]'),
      'a',
    );
    normalized = normalized.replaceAll(
      RegExp('[\u00e9\u00e8\u00eb\u00ea]'),
      'e',
    );
    normalized = normalized.replaceAll(
      RegExp('[\u00ed\u00ec\u00ef\u00ee]'),
      'i',
    );
    normalized = normalized.replaceAll(
      RegExp('[\u00f3\u00f2\u00f6\u00f4\u00f5]'),
      'o',
    );
    normalized = normalized.replaceAll(
      RegExp('[\u00fa\u00f9\u00fc\u00fb]'),
      'u',
    );
    normalized = normalized.replaceAll(RegExp('[\u00f1]'), 'n');
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9_\s]'), ' ');
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();

    return normalized;
  }

  static String processPrompt(String originalPrompt) {
    final normalizedPrompt = _normalizePrompt(originalPrompt);
    final List<String> hints = [];

    // 1. HARDWARE (evaluated first, does not block others)
    if (_hardwareRegex.hasMatch(normalizedPrompt)) {
      debugPrint('[IntentInterceptor] Hardware match detected.');
      hints.add('USE <CMD_SYS_OPTICS_1>');
    }

    bool geofenceDetected = false;

    // 2. GEOFENCE
    // Space wins when a location plus action/spatial trigger is detected.
    if (_geofenceLocationRegex.hasMatch(normalizedPrompt) &&
        (_actionVerbsRegex.hasMatch(normalizedPrompt) ||
            _geofenceTriggersRegex.hasMatch(normalizedPrompt) ||
            (_calendarActionVerbsRegex.hasMatch(normalizedPrompt) &&
                _geofenceTriggersRegex.hasMatch(normalizedPrompt)))) {
      debugPrint('[IntentInterceptor] Geofence match detected.');
      hints.add('USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.');
      geofenceDetected = true;
    }

    // 3. CALENDAR (Explicit and Implicit)
    if (!geofenceDetected) {
      if (_explicitCalendarRegex.hasMatch(normalizedPrompt)) {
        if (_calendarQueryVerbsRegex.hasMatch(normalizedPrompt)) {
          debugPrint(
            '[IntentInterceptor] Explicit Calendar (Query) match detected.',
          );
          hints.add(
            'GENERAL CHAT. Check schedule context but DO NOT use tools.',
          );
        } else if (_calendarActionVerbsRegex.hasMatch(normalizedPrompt) ||
            _actionVerbsRegex.hasMatch(normalizedPrompt)) {
          debugPrint(
            '[IntentInterceptor] Explicit Calendar (Action) match detected.',
          );
          hints.add('USE manage_calendar');
        } else {
          debugPrint(
            '[IntentInterceptor] Explicit Calendar (No Action) match detected.',
          );
          hints.add(
            'GENERAL CHAT. Check schedule context but DO NOT use tools.',
          );
        }
      } else if (_timeMarkersRegex.hasMatch(normalizedPrompt) &&
          (_calendarActionVerbsRegex.hasMatch(normalizedPrompt) ||
              _actionVerbsRegex.hasMatch(normalizedPrompt))) {
        debugPrint('[IntentInterceptor] Implicit Calendar match detected.');
        hints.add('USE manage_calendar');
      }
    }

    // 4. VAULT SEARCH
    if (_vaultRegex.hasMatch(normalizedPrompt)) {
      debugPrint('[IntentInterceptor] Vault match detected.');
      hints.add('USE <CMD_SYS_VAULT_SRCH>');
    }

    // 5. GENERAL CHAT (No hints)
    if (hints.isEmpty) {
      return originalPrompt;
    }

    final combinedHints = hints.join(' | ');
    return '[SYSTEM HINT: $combinedHints]\n\n$originalPrompt';
  }
}
