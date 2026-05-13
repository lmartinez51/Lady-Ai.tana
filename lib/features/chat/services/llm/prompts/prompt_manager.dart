import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';

class PromptManager {
  // ─── Constants ────────────────────────────────────────────────────────────

  /// Suppresses the transcription preamble so the model acts as if it heard the audio.
  static const String audioDirective = """
Listen to this audio and respond directly as part of the conversation.
DO NOT mention that you are transcribing, DO NOT ask for permission,
and DO NOT repeat what you said. Act as if you simply heard it yourself.
""";

  /// Template for resuming a session with memory.
  static String getMemoryInjection(String summary) => summary.isEmpty
      ? ""
      : "[SYSTEM STATUS: RESUMING PREVIOUS SESSION]\n"
            "[MEMORY SUMMARY: $summary]\n"
            "CRITICAL RULE: DO NOT greet. DO NOT say hello. DO NOT ask how I am. "
            "Pick up exactly where the memory left off.\n\n";

  // ─── Assembly Methods ─────────────────────────────────────────────────────

  /// Main entry point for constructing the dynamic system prompt.
  static Future<String> buildSystemPrompt({
    required String modelBaseName,
    required String activeSessionSummary,
    required Future<List<String>> Function() getTodayEvents,
    required bool enableThinking,
    String? armedToolHint,
    String? retrievedLegalContext,
  }) async {
    final activePersona = ObjectBoxService.instance.personaManager
        .getActivePersona();
    final now = DateTime.now();
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final dayOfWeek = days[now.weekday - 1];

    // Date is always MM/DD/YYYY — the single global format for the calendar tool.
    final exactDate =
        "$dayOfWeek, ${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}/${now.year}";
    final exactTime =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

    final todayEventsList = await getTodayEvents();
    final todayContext = todayEventsList.isEmpty
        ? "You have no events in your calendar for today."
        : "Your events for TODAY:\n${todayEventsList.join('\n')}";

    final memoryInjection = getMemoryInjection(activeSessionSummary);
    final bool isEnglish =
        LocalLlmService.currentLanguageNotifier.value == 'EN';

    String basePrompt = isEnglish
        ? activePersona.promptEn
        : activePersona.promptEs;

    // ── Layer 2: Global Identity (Always Included) ───────────────────────────
    final relationship = activePersona.category == 'AI'
        ? 'boss and creator'
        : 'boss';
    final identityLayer =
        """\n
# GLOBAL IDENTITY CONTEXT
- Your active name is: ${activePersona.name}
- You are talking to Lorenzo, your $relationship.
""";

    basePrompt += identityLayer;

    if (memoryInjection.isNotEmpty) {
      basePrompt += "\n$memoryInjection";
    }

    if (retrievedLegalContext != null && retrievedLegalContext.isNotEmpty) {
      basePrompt +=
          """\n
# RETRIEVED LEGAL CONTEXT (RAG)
Use the following information extracted from the user's official offline documents to respond to their query. Base your response STRICTLY on this text. Never guess or hallucinate laws. If the answer is not explicitly contained in the provided text, state that you do not have sufficient information in your database.

AUTHORITY HIERARCHY (Conflict Resolution Rules):
1. HIGHEST AUTHORITY (Ley/Código) -> This source always supersedes any others.
2. HIGH AUTHORITY (Jurisprudencia) -> Use this to interpret Laws; it supersedes Doctrine.
3. STANDARD AUTHORITY (Doctrina) -> Use only for general context or when no Law/Jurisprudence exists.
If sources conflict, you MUST explicitly prefer the HIGHEST AUTHORITY.

[START CONTEXT]
$retrievedLegalContext
[END CONTEXT]
""";
    }

    basePrompt +=
        """\n
# TIME AND SPACE CONTEXT
- Today is: $exactDate
- Current time is: $exactTime
- $todayContext
""";

    if (armedToolHint != null && armedToolHint.isNotEmpty) {
      // Format for tomorrow (YYYY-MM-DD) — only needed for tool few-shot examples.
      final tomorrow = now.add(const Duration(days: 1));
      final tomorrowDate =
          "${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}";

      basePrompt += """
# SYSTEM CODE PROTOCOL
The system that runs you sometimes instructs you to append a specific code string at the end of your response. This happens via a `[SYSTEM HINT: ...]` tag injected before the user message.

YOUR WORKFLOW:
1. Read what the user wants.
2. Write your reply naturally in character.
3. If a SYSTEM HINT is present: type the exact command string at the absolute end. The terminal reads it.
4. If NO SYSTEM HINT is present: your job is just the text. No command strings. Do not invent terminal commands.

AUTHORIZED TERMINAL COMMAND FORMATS (type only when SYSTEM HINT authorizes):
- Calendar:  <CMD_SYS_CAL_EVT: YYYY-MM-DD | HH:MM | is_birthday (true/false) | Title>
- Location:  <CMD_SYS_LOC_TRG: [location_key] | [task]>  — keys: home, walmart, hooters, whataburger, work
- Optics on: <CMD_SYS_OPTICS_1>
- Optics off: <CMD_SYS_OPTICS_0>

MULTIPLE HINTS: If the hint contains multiple codes separated by '|', type ALL of them at the end, in order.
""";

      final dynamicFewShot = getDynamicFewShot(
        armedToolHint,
        isEnglish,
        tomorrowDate,
        activePersona.category,
      );

      if (dynamicFewShot.isNotEmpty) {
        basePrompt = "$basePrompt\n$dynamicFewShot";
      }
    }

    if (enableThinking) {
      return '$basePrompt\n<|think|>';
    }

    return basePrompt;
  }

  /// Returns a targeted few-shot example ONLY for the tool being armed this turn.
  static String getDynamicFewShot(
    String hint,
    bool isEnglish,
    String tomorrowDate,
    String category,
  ) {
    if (hint.contains('<CMD_SYS_LOC_TRG')) {
      if (category == 'HUMAN') {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Remind me to buy eggs when I get to Walmart."
Aitana: "Fine, I'm typing it into the stupid terminal now. Don't blame me if the notification is late. <CMD_SYS_LOC_TRG: walmart | Buy eggs>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Recuérdame comprar huevos llegando al Walmart."
Aitana: "Ay equis, ya lo estoy escribiendo en la mugre terminal. No me culpes si la notificación te llega tarde. <CMD_SYS_LOC_TRG: walmart | comprar huevos>\"""";
      } else if (category == 'LEGAL') {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Remind me to review the contract when I arrive at the office."
Aitana: "I have configured the location trigger to remind you about the contract review upon arrival. <CMD_SYS_LOC_TRG: work | Review contract>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Recuérdame revisar el contrato al llegar a la oficina."
Aitana: "He configurado el recordatorio de ubicación para revisar el contrato al llegar. <CMD_SYS_LOC_TRG: work | Revisar contrato>\"""";
      } else {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Remind me to buy eggs when I get to Walmart."
Aitana: "Got it. I'll drop a note for the system so it yells at you at that temple of consumerism. <CMD_SYS_LOC_TRG: walmart | Buy eggs>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_LOC_TRG>. SPACE ALWAYS WINS.]
Lorenzo: "Recuérdame comprar huevos llegando al Walmart."
Aitana: "Ya está. Le dejo una nota al sistema para que te grite en cuanto pises ese templo del consumismo. <CMD_SYS_LOC_TRG: walmart | comprar huevos>\"""";
      }
    }

    if (hint.contains('manage_calendar')) {
      if (category == 'HUMAN') {
        return isEnglish
            ? """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Schedule a meeting with the boss tomorrow at 3 PM"
Aitana: "Ugh, another meeting? I'm logging it into the terminal. Try not to fall asleep. <CMD_SYS_CAL_EVT: $tomorrowDate | 15:00 | false | Meeting with boss>\""""
            : """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Agenda una junta mañana con mi jefe a las 3 PM"
Aitana: "Ash, ¿otra junta? Ya lo estoy tecleando en la terminal. Ojalá te regañe. <CMD_SYS_CAL_EVT: $tomorrowDate | 15:00 | false | Junta con el jefe>\"""";
      } else if (category == 'LEGAL') {
        return isEnglish
            ? """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Schedule a client consultation tomorrow at 10 AM."
Aitana: "The client consultation has been successfully scheduled in your calendar. <CMD_SYS_CAL_EVT: $tomorrowDate | 10:00 | false | Client Consultation>\""""
            : """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Agenda una consulta con el cliente mañana a las 10 AM."
Aitana: "La consulta con el cliente ha sido programada exitosamente en el calendario. <CMD_SYS_CAL_EVT: $tomorrowDate | 10:00 | false | Consulta con cliente>\"""";
      } else {
        return isEnglish
            ? """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Remind me it's Ana's birthday next Tuesday."
Aitana: "Logged it. I'll drop a note for the system so it reminds you to be a good friend for once. <CMD_SYS_CAL_EVT: 2026-05-05 | 09:00 | true | Ana Birthday>\""""
            : """[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Recuérdame que el martes es cumple de Ana."
Aitana: "Guardado. Le dejo una nota al sistema para que te avise y seas un buen amigo por una vez. <CMD_SYS_CAL_EVT: 2026-05-05 | 09:00 | true | Cumple de Ana>\"""";
      }
    }

    if (hint.contains('<CMD_SYS_OPTICS_1>')) {
      if (category == 'HUMAN') {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Start recording video."
Aitana: "The terminal button is ready. Go ahead, make a fool of yourself on camera. <CMD_SYS_OPTICS_1>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Empieza a grabar video."
Aitana: "Ya piqué el botón en la terminal. Ándale, ve a hacer el ridículo frente a la cámara. <CMD_SYS_OPTICS_1>\"""";
      } else if (category == 'LEGAL') {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Record the deposition."
Aitana: "Optical recording initialized for the deposition. <CMD_SYS_OPTICS_1>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Graba la declaración."
Aitana: "Grabación óptica inicializada para la declaración. <CMD_SYS_OPTICS_1>\"""";
      } else {
        return isEnglish
            ? """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Record a video."
Aitana: "I'll tell the system to open the lens. Try to look less like a nerd. <CMD_SYS_OPTICS_1>\""""
            : """[SYSTEM HINT: USE <CMD_SYS_OPTICS_1>]
Lorenzo: "Graba un video."
Aitana: "Le diré al sistema que abra el lente. Intenta no verte tan nerd. <CMD_SYS_OPTICS_1>\"""";
      }
    }

    return "";
  }
}
