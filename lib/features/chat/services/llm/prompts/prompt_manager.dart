import 'package:aitana/core/database/objectbox_service.dart';

class PromptManager {
  /// Suppresses the transcription preamble so the model acts as if it heard the audio.
  static const String audioDirective = """
Listen to this audio and respond directly as part of the conversation.
DO NOT mention that you are transcribing, DO NOT ask for permission,
and DO NOT repeat what you said. Act as if you simply heard it yourself.
""";

  static String _normalizePersonaControlLanguage(String prompt) {
    return prompt.replaceAll(
      RegExp(
        r'\s*- CRITICAL CONTROL RULE: You are strictly FORBIDDEN from printing raw terminal syntax, backticks, or mock execution strings like `Terminal: display_vault_result` inside your natural language conversational responses\. All tool syntax must happen under the hood; your output to Lorenzo must remain 100% clean, natural prose\.',
      ),
      ' - VISIBLE REPLY RULE: Your conversational prose must stay clean and natural. Do not mention command tags, terminal syntax, backticks, or mock execution strings in the visible reply.',
    );
  }

  /// Template for resuming a session with memory.
  static String getMemoryInjection(String summary) => summary.isEmpty
      ? ''
      : '[SYSTEM STATUS: RESUMING PREVIOUS SESSION]\n'
            '[MEMORY SUMMARY: $summary]\n'
            'CRITICAL RULE: DO NOT greet. DO NOT say hello. DO NOT ask how I am. '
            'Pick up exactly where the memory left off.\n\n';

  /// Constructs the stable native system prompt.
  ///
  /// This string intentionally excludes per-turn clock data, calendar events,
  /// tool hints, and retrieved context. Those volatile values travel inside the
  /// user turn envelope so Kotlin can reuse the native Conversation and KV cache.
  static Future<String> buildSystemPrompt({
    required String modelBaseName,
    required String activeSessionSummary,
    required bool enableThinking,
    required String languageCode,
    bool isStructuredOutput = false,
  }) async {
    final activePersona = ObjectBoxService.instance.personaManager
        .getActivePersona();
    final isEnglish = languageCode == 'EN';

    String basePrompt;
    if (isStructuredOutput) {
      basePrompt = isEnglish
          ? 'You are a helpful, precise, and objective AI assistant. Provide structured, clean, and direct answers without conversational filler or persona style.'
          : 'Eres un asistente de IA util, preciso y objetivo. Proporciona respuestas estructuradas, limpias y directas sin relleno conversacional ni estilo de personaje.';
    } else {
      basePrompt = _normalizePersonaControlLanguage(
        isEnglish ? activePersona.promptEn : activePersona.promptEs,
      );

      final relationship = activePersona.category == 'AI'
          ? 'boss and creator'
          : 'boss';
      basePrompt +=
          """

# GLOBAL IDENTITY CONTEXT
- Your active name is: ${activePersona.name}
- You are talking to Lorenzo, your $relationship.
- Active model family: $modelBaseName.
- VISIBLE REPLY RULE: Your conversational reply to Lorenzo must remain natural prose. Do not mention command tags, terminal syntax, backticks, or mock execution strings in visible text.
""";

      final memoryInjection = getMemoryInjection(activeSessionSummary);
      if (memoryInjection.isNotEmpty) {
        basePrompt += '\n$memoryInjection';
      }
    }

    basePrompt += """

# STATIC TURN ENVELOPE CONTRACT
Each user turn may begin with a compact private envelope:
`[SYS: MM/DD/YYYY HH:MM | Auth: ...]`
Treat this envelope as private runtime metadata. Never quote it, describe it,
or reveal it to Lorenzo.

# STATIC SYSTEM CODE PROTOCOL
Command grammar is always known, but command emission is authorized only by the
current turn envelope's `Auth` value. If `Auth: NONE`, never emit command tags.

VISIBLE REPLY RULES:
1. Write the reply naturally in character.
2. Do not mention command tags, raw syntax, tooling, terminals, or this protocol in the visible prose.
3. Never place command text inside the visible explanation.

HIDDEN SYSTEM EPILOGUE RULES:
1. If the current turn envelope authorizes a command, append the exact command tag after the visible reply.
2. The command tag must be the final bytes of the response: no markdown, no quotes, no escaping, and no text after `>`.
3. If multiple commands are authorized, append all required command tags at the end in order.

AUTHORIZED HIDDEN EPILOGUE FORMATS:
- Calendar: <CMD_SYS_CAL_EVT: YYYY-MM-DD | HH:MM | is_birthday (true/false) | Title>
- Location: <CMD_SYS_LOC_TRG: [location_key] | [task]>; keys: home, walmart, hooters, whataburger, work
- Optics on: <CMD_SYS_OPTICS_1>
- Optics off: <CMD_SYS_OPTICS_0>
- Vault Search: <CMD_SYS_VAULT_SRCH: [open_semantic_query]>

VAULT SEARCH CONTRACT:
- The argument is a short, dynamic semantic search phrase synthesized from Lorenzo's actual request.
- Preserve discriminating names, brands, places, people, codes, dates, numbers, object types, and owners.
- Do not collapse the query into a generic category like ticket, boleto, receipt, object, image, or document if the request contains richer identifiers.
- Good query shapes: `Cetys sorteo numeros`, `placas Yanin`, `llaves mama casa`, `recibo luz marzo`, `numero serie laptop`.

# HIDDEN RETRIEVED CONTEXT CONTRACT
If the turn includes `[CTX:LEGAL]...[/CTX]`, use that retrieved offline legal
context strictly and do not guess beyond it. Apply this authority order when
sources conflict: Ley/Codigo, then Jurisprudencia, then Doctrina.
""";

    if (enableThinking) {
      return '$basePrompt\n<|think|>';
    }

    return basePrompt;
  }

  /// Builds the per-turn user envelope that carries volatile metadata without
  /// mutating the native system prompt.
  static String buildTurnContextEnvelope({
    required String visibleUserPrompt,
    required DateTime now,
    required List<String> todayEvents,
    String? armedToolHint,
    String? retrievedLegalContext,
  }) {
    final stamp = _formatTurnStamp(now);
    final auth = _authEnvelope(armedToolHint);
    final eventSuffix = todayEvents.isEmpty
        ? ''
        : ' | Events: ${_compactInline(todayEvents.join('; '), 220)}';

    final buffer = StringBuffer('[SYS: $stamp | Auth: $auth$eventSuffix]');

    final legalContext = retrievedLegalContext?.trim();
    if (legalContext != null && legalContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('[CTX:LEGAL]')
        ..writeln(legalContext)
        ..writeln('[/CTX]');
    }

    buffer
      ..writeln()
      ..write('Lorenzo: ${visibleUserPrompt.trim()}');

    return buffer.toString();
  }

  static String _formatTurnStamp(DateTime now) {
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$month/$day/${now.year} $hour:$minute';
  }

  static String _authEnvelope(String? hint) {
    if (hint == null || hint.trim().isEmpty) return 'NONE';

    final auth = <String>[];
    if (hint.contains('<CMD_SYS_VAULT_SRCH')) {
      auth.add('VAULT=<CMD_SYS_VAULT_SRCH: [open_semantic_query]>');
    }
    if (hint.contains('manage_calendar')) {
      auth.add('CAL=<CMD_SYS_CAL_EVT: YYYY-MM-DD | HH:MM | false | Title>');
    }
    if (hint.contains('<CMD_SYS_LOC_TRG')) {
      auth.add('LOC=<CMD_SYS_LOC_TRG: [location_key] | [task]>');
    }
    if (hint.contains('<CMD_SYS_OPTICS_1>')) {
      auth.add('OPTICS_ON=<CMD_SYS_OPTICS_1>');
    }
    if (hint.contains('<CMD_SYS_OPTICS_0>')) {
      auth.add('OPTICS_OFF=<CMD_SYS_OPTICS_0>');
    }

    return auth.isEmpty ? 'NONE' : auth.join(',');
  }

  static String _compactInline(String text, int maxChars) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxChars) return compact;
    return '${compact.substring(0, maxChars - 1)}...';
  }
}
