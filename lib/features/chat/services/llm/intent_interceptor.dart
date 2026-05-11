import 'package:flutter/foundation.dart';

/// Intercepts and analyzes user prompts to inject routing hints for the LLM.
/// This reduces the model's cognitive load and enforces strict tool usage
/// rules prior to hitting the native engine.
class IntentInterceptor {
  // ─── Dictionaries & Regex Patterns ────────────────────────────────────────

  // Hardware Keywords (Flexibilidad para tildes y formas de decirlo)
  static final RegExp _hardwareRegex = RegExp(
    r'\b(toma video|tomar video|graba|grabar|grabame|grábame|empieza a grabar|pon a grabar|record video|camera feed|video interface|turn on the video|take a video|open the camera|video feed|run the camera)\b',
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
    r'\b(qu[eé] tengo|dime|revisa|what do i have|check)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Action Verbs for Calendar (with optional clitic pronouns 'me', 'lo', etc.)
  static final RegExp _calendarActionVerbsRegex = RegExp(
    r'\b(agrega|pon|add|schedule|apunta|anota|guarda|agenda|agendar)(?:lo|la|los|las|le|les|me)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Geofence Keywords (Slang norteño/fronterizo, sin tildes, El Paso/Juárez)
  static final RegExp _geofenceLocationRegex = RegExp(
    r'\b(work|home|walmart|hooters|whataburger|trabajo|casa|oficina|jale|chamba|cant[oó]n|el paso|ju[aá]rez|chuco)\b',
    caseSensitive: false,
    unicode: true,
  );

  // Spatial Triggers (Gatillos espaciales clave para geocercas)
  static final RegExp _geofenceTriggersRegex = RegExp(
    r'\b(llegando|llegar|llegue|cuando ande|en cuanto llegue|al llegar)\b',
    caseSensitive: false,
    unicode: true,
  );

  // General Action Verbs used in both Geofence and Calendar
  // Incluye "recordatorio", modismos como "tira paro", "echame un grito"
  static final RegExp _actionVerbsRegex = RegExp(
    r'\b(av[ií]same|recu[eé]rdame|remind|notify|tell|acu[eé]rdame|recordatorio|avisa|recuerda|acuerda|tira paro|hazme el paro|echame un grito|[eé]chame un grito)(?:lo|la|los|las|le|les|me)?\b',
    caseSensitive: false,
    unicode: true,
  );

  // Implicit Time Markers
  static final RegExp _timeMarkersRegex = RegExp(
    r'\b(ma[ñn]ana|hoy|a las|pm|am|lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo|tomorrow|today)\b',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _vaultRegex = RegExp(
    r'\b(bóveda|boveda|vault|mis fotos|mis recibos|mi boveda|personal vault|receipts|documents|analyzed images|search vault)\b',
    caseSensitive: false,
    unicode: true,
  );

  // ─── Main Intercept Method ────────────────────────────────────────────────

  static String processPrompt(String originalPrompt) {
    final lowerPrompt = originalPrompt.toLowerCase();
    final List<String> hints = [];

    // 1. HARDWARE (Evaluated first, does not block others)
    if (_hardwareRegex.hasMatch(lowerPrompt)) {
      debugPrint('🧠 [IntentInterceptor] Hardware match detected.');
      hints.add('USE <CMD_SYS_OPTICS_1>');
    }

    bool geofenceDetected = false;

    // 2. GEOFENCE
    // Dispara si encuentra el lugar (jale, cantón) Y alguna acción, gatillo espacial o verbo de agenda (ej. "ponme" + "cuando llegue")
    if (_geofenceLocationRegex.hasMatch(lowerPrompt) &&
        (_actionVerbsRegex.hasMatch(lowerPrompt) ||
            _geofenceTriggersRegex.hasMatch(lowerPrompt) ||
            (_calendarActionVerbsRegex.hasMatch(lowerPrompt) &&
                _geofenceTriggersRegex.hasMatch(lowerPrompt)))) {
      debugPrint('🧠 [IntentInterceptor] Geofence match detected.');
      hints.add('USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.');
      geofenceDetected = true;
    }

    // 3. CALENDAR (Explicit and Implicit)
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

    // 4. VAULT SEARCH
    if (_vaultRegex.hasMatch(lowerPrompt)) {
      debugPrint('🧠 [IntentInterceptor] Vault match detected.');
      // NO HINT INJECTED: Native Tool API handles intent.
    }

    // 4. GENERAL CHAT (No hints)
    if (hints.isEmpty) {
      return originalPrompt;
    }

    final combinedHints = hints.join(' | ');
    return '[SYSTEM HINT: $combinedHints]\n\n$originalPrompt';
  }
}
