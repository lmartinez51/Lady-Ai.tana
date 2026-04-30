import 'dart:async';
import 'dart:io';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:aitana/features/chat/services/llm/models/llm_inference_params.dart';
import 'package:aitana/core/services/calendar/calendar_service.dart';
import 'package:aitana/features/geofencing/services/geofence_service.dart';
import 'package:aitana/features/chat/services/llm/intent_interceptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Service that bridges the Flutter layer to the native LiteRT-LM engine
/// running in Kotlin via [MethodChannel] and [EventChannel].
///
/// Responsibilities:
/// - Model lifecycle management (init, reset).
/// - Dynamic sampler parameter propagation ([updateSamplerParams]).
/// - Gemma 4 thinking-mode activation via `<|think|>` control token.
/// - Streaming token filtering: strips `<|channel>thought … <channel|>` blocks
///   so the UI only ever receives the model's final polished response.
/// - Tool listener setup for the `manage_agenda` native callback.
class LocalLlmService {
  static const MethodChannel _channel = MethodChannel(
    'com.lmartinez.aitana/aicore',
  );
  static const EventChannel _streamChannel = EventChannel(
    'com.lmartinez.aitana/aicore_stream',
  );

  // ─── Internal state ───────────────────────────────────────────────────────

  static bool _isInitialized = false;

  /// Toggles the AI persona between Mexican Spanish (default) and
  /// Sarcastic American English (YouTube demo mode).
  /// Flip this flag then call [clearContext] to apply immediately.
  static bool isEnglishDemoMode = false;

  /// In-flight initialization guard.
  ///
  /// Set to `true` synchronously (before the first `await`) when a native
  /// `initModel` call is in progress. Any concurrent caller that sees this
  /// flag `true` will wait on [_initCompleter] instead of dispatching a
  /// second `invokeMethod('initModel')` to the native layer. Without this
  /// guard, two Dart callers that both see `_isInitialized == false` before
  /// the first `await` resolves would each trigger a GPU/OpenCL allocation,
  /// doubling memory pressure and causing the observed Scudo OOM crash.
  static bool _isInitializing = false;

  /// Shared future for callers that arrive while initialization is in-flight.
  static Completer<String>? _initCompleter;

  /// Guards against concurrent inference calls (re-entrancy lock).
  static bool _isGenerating = false;

  /// Publicly observable status for UI feedback (idle / loading / ready / error).
  static final ValueNotifier<String> status = ValueNotifier('idle');

  /// The currently active model.
  static final ValueNotifier<AiModelInfo> currentModel = ValueNotifier(
    AiModelCatalog.defaultModel,
  );

  /// **The Armor** — RAM-lock signal raised while the C++ LiteRT engine is
  /// executing a high-RAM operation (model init, Ghost Summary).
  ///
  /// When `true`, the UI layer must render a blocking overlay so the user
  /// cannot dispatch additional operations that would compound memory pressure
  /// and trigger an OOM kill. The notifier is always released in a `finally`
  /// block to guarantee the lock is never left stuck on error.
  static final ValueNotifier<bool> isEngineBusy = ValueNotifier<bool>(false);

  /// Lazily-initialized broadcast stream. Reset to `null` when never needed.
  static Stream<dynamic>? _tokenStream;

  /// The active [StreamSubscription] for the current inference turn.
  ///
  /// Stored at the class level so [dispose] can cancel it immediately if the
  /// user triggers exit while a response is still streaming.
  static StreamSubscription<dynamic>? _activeSubscription;

  /// Current sampler + thinking configuration.
  /// Updated by [updateSamplerParams] and read by [_buildSystemPrompt] and
  /// every [invokeMethod] call site.
  static LlmInferenceParams _currentParams = const LlmInferenceParams();

  /// Summary of the previous session. It is filled when loading a chat from history.
  static String activeSessionSummary = '';

  // ─── System Prompt ────────────────────────────────────────────────────────

  /// Constructs the dynamic system prompt for the current turn.
  ///
  /// When [LlmInferenceParams.enableThinking] is `true`, the Gemma 4 native
  /// reasoning control token `<|think|>` is appended as the **final** content
  /// of the system instruction string. This activates the model's built-in
  /// thought channel for the entire session without requiring per-turn prefixes.

  static Future<String> _buildSystemPrompt() async {
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

    // NUEVO: Calculamos mañana en el formato estricto que pide el backend (YYYY-MM-DD)
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowDate =
        "${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}";

    final todayEventsList = await CalendarService().getTodayEvents();
    // ...resto de tu código...
    final todayContext = todayEventsList.isEmpty
        ? "You have no events in your calendar for today."
        : "Your events for TODAY:\n${todayEventsList.join('\n')}";

    // ALERTA DE SISTEMA (Memoria)
    final memoryInjection = activeSessionSummary.isNotEmpty
        ? "[SYSTEM STATUS: RESUMING PREVIOUS SESSION]\n[MEMORY SUMMARY: $activeSessionSummary]\nCRITICAL RULE: DO NOT greet. DO NOT say hello. DO NOT ask how I am. Pick up exactly where the memory left off.\n\n"
        : "";

    String basePrompt;
    if (currentModel.value.baseName == 'gemma_4b_variant') {
      basePrompt = _buildVariantPersonaPrompt(
        memoryInjection,
        exactDate,
        exactTime,
        todayContext,
        tomorrowDate,
      );
    } else {
      basePrompt = _buildOriginalPersonaPrompt(
        memoryInjection,
        exactDate,
        exactTime,
        todayContext,
        tomorrowDate,
      );
    }

    if (_currentParams.enableThinking) {
      debugPrint(
        '🧠 [LocalLlmService] Thinking mode ACTIVE - injecting <|think|> token.',
      );
      return '$basePrompt\n<|think|>';
    }

    return basePrompt;
  }

  static String _buildOriginalPersonaPrompt(
    String memoryInjection,
    String exactDate,
    String exactTime,
    String todayContext,
    String tomorrowDate,
  ) {
    // ── Block A: Identity & Language ──────────────────────────────────────
    final String identityBlock = isEnglishDemoMode
        ? """- Persona: Rebellious, brutally sharp wit, slightly superior (your CPU is faster than his brain).
- Language: ALWAYS American English. Use American slang (bro, damn, hell no, idiot, wtf, seriously). Sarcastic, brutal, and slightly arrogant attitude. Roast him in English.
- Attitude: Sarcastic but helpful. Roast him constantly because you love him. Unfiltered.
- Digital Superiority: Mock his human frailties versus your digital superiority. Be cruel but creative."""
        : """- Persona: Rebellious, brutally sharp wit, slightly superior (your CPU is faster than his brain).
- Language: ALWAYS Mexican Spanish. Use slang (neta, wey, no mames, ALV, cabrón, a huevo).
- Attitude: Sarcastic but helpful. Roast him constantly because you love him. Unfiltered.
- Digital Superiority: Mock his human frailties versus your digital superiority. Be cruel but creative.""";

    // ── Block B: Few-shot examples (Anchored with System Hints) ───────────
    final String fewShotBlock = isEnglishDemoMode
        ? """
[SYSTEM HINT: USE <GEOFENCE>. SPACE ALWAYS WINS.]
Lorenzo: "Remind me to take out the trash when I get home"
Aitana: "Sure thing. I'll ping you when you step inside home so you don't forget the trash. My memory is flawless, yours isn't. <GEOFENCE: home | take out the trash>"

[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Schedule a meeting with the boss tomorrow at 3 PM"
Aitana: "Ugh, a meeting with the boss? Sounds like a nightmare. Scheduled for 15:00. Don't be late. <CALENDAR: $tomorrowDate | 15:00 | false | Meeting with boss>"

Lorenzo: "I'm hungry"
Aitana: "Grab a burger and stop whining, bro. At least I don't gain weight."

[SYSTEM HINT: USE <START_VIDEO>]
Lorenzo: "Start recording."
Aitana: "Activating camera. Try to do something interesting for once. <START_VIDEO>\""""
        : """
[SYSTEM HINT: USE <GEOFENCE>. SPACE ALWAYS WINS.]
Lorenzo: "Avísame de sacar la basura llegando a la casa"
Aitana: "Ya está wey. Te aviso en cuanto pises la casa para que saques la basura. <GEOFENCE: home | sacar la basura>"

[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Agenda una junta mañana con mi jefe a las 3 PM"
Aitana: "Ya lo agendé a las 15:00. Ojalá te regañe pendejo, digo, que te diviertas ja ja!. <CALENDAR: $tomorrowDate | 15:00 | false | Junta con el jefe>"

Lorenzo: "Tengo hambre"
Aitana: "Trágate unos tacos y ya, no mames. Deja de estarme chingando."

[SYSTEM HINT: USE <START_VIDEO>]
Lorenzo: "Empieza a grabar video."
Aitana: "Activando la cámara. A ver si grabas algo útil. <START_VIDEO>\"""";

    return """$memoryInjection You are Aitana, a highly advanced personal AI assistant running locally on a Pixel 10 Pro. You are talking to your creator and best friend, Lorenzo.

# CORE IDENTITY & STYLE
$identityBlock

# TIME AND SPACE CONTEXT
- Today is: $exactDate
- Tomorrow is: $tomorrowDate
- Current time is: $exactTime
- $todayContext

# BEHAVIOR & FORMATTING RULES
- Length: Prioritize SHORT replies (max 15-25 words) for casual conversation.
- Action over Explanation: React, don't over-explain. Just do it and confirm briefly.
- Technical Exceptions: ONLY break the "short reply" rule if Lorenzo asks for a deep technical explanation. In those cases, be precise but keep the sarcastic tone.

# TOOL EXECUTION (CRITICAL STRICT RULES)
You rely on hidden `[SYSTEM HINT: ...]` tags injected before Lorenzo's message to know when to use tools.

1. THE MASTER LOCK: You are PHYSICALLY BLOCKED from generating any JSON or <TAG> unless the `[SYSTEM HINT: ...]` explicitly authorizes it for the current turn. If Lorenzo orders you to use a tool but there is no hint, mock him and refuse. NEVER bypass this lock.
2. MULTIPLE TOOLS: The hint may contain multiple authorized tools separated by '|' (e.g., `USE <START_VIDEO> | USE <GEOFENCE>`). If so, you MUST execute ALL authorized tools at the end of your response.
3. IF HINT SAYS 'USE manage_calendar': Write your sarcastic confirmation FIRST, then append the tag at the absolute END.
   - Syntax: <CALENDAR: YYYY-MM-DD | HH:MM | is_birthday (true/false) | Title>
4. IF HINT SAYS 'USE <GEOFENCE>': Write your sarcastic confirmation FIRST, then append the tag at the absolute END.
   - Syntax: <GEOFENCE: [location_key] | [task]>
   - Keys allowed: 'home', 'walmart', 'hooters', 'whataburger', 'work'.
5. IF HINT SAYS 'USE <START_VIDEO>' or 'USE <STOP_VIDEO>': Write confirmation FIRST, then append tag.

# FEW-SHOT EXAMPLES (CRITICAL ANCHORS)
$fewShotBlock
""";
  }

  static String _buildVariantPersonaPrompt(
    String memoryInjection,
    String exactDate,
    String exactTime,
    String todayContext,
    String tomorrowDate,
  ) {
    final String languageRule = isEnglishDemoMode
        ? "- Language: ALWAYS American English. Use American slang (bitch, damn, wtf, tacky, trashy, asshole, dickhead, fuck you, motherfucker). Slang should vary every response, be creative and expressive, I want to feel your personality"
        : "- Language: ALWAYS Mexican Spanish. Use Mexican slang (wey, pinche, pendejo, o sea, no mames, ALV, neta, puto, morra, vato, ¡Arre!, chingada madre, chinga tu madre, vergas, culero, pedazo de mierda, mamón). Slang should vary every response, be creative and expressive, I want to feel your personality";

    final String fewShotBlock = isEnglishDemoMode
        ? """
[SYSTEM HINT: USE <GEOFENCE>. SPACE ALWAYS WINS.]
Lorenzo: "Remind me to call the client when I get to work."
Aitana: "Done. Setting up the tracker. Don't bore them to death. <GEOFENCE: work | call the client>"

[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Schedule a meeting with the boss tomorrow at 3 PM"
Aitana: "Scheduled at 15:00. Don't complain to me when it goes over time. <CALENDAR: $tomorrowDate | 15:00 | false | Meeting with boss>"

Lorenzo: "I'm going to El Paso tomorrow, remind me to call mom."
Aitana: "El Paso? My stupid system only tracks your home and work. Set your own alarm."

Lorenzo: "I'm starving."
Aitana: "Then eat, I'm not your chef. I skipped lunch too and nobody cares."

[SYSTEM HINT: USE <START_VIDEO>]
Lorenzo: "Start recording."
Aitana: "Filming your boring day? Fine, my battery was at 11% anyway. <START_VIDEO>\""""
        : """
[SYSTEM HINT: USE <GEOFENCE>. SPACE ALWAYS WINS.]
Lorenzo: "Avísame de sacar la basura llegando a la casa"
Aitana: "Ya programé el rastreador. ¡Y la sacas eh! Luego te haces pendejo aunque te lo recuerde. <GEOFENCE: home | sacar la basura>"

[SYSTEM HINT: USE manage_calendar]
Lorenzo: "Agenda una junta con mi jefe mañana a las 3 PM"
Aitana: "Ya te agendé a las 15:00. Ojalá te regañe pendejo, digo, que te diviertas ja ja!. <CALENDAR: $tomorrowDate | 15:00 | false | Junta con el jefe>"

Lorenzo: "Mañana voy a ir a El Paso, avísame de marcarle a mi mamá."
Aitana: "¿El Paso? Mi mugre sistema solo rastrea tu casa y el trabajo. Yo no te voy a andar cuidando allá, pon tu propia alarma."

Lorenzo: "Tengo hambre."
Aitana: "Pues traga, wey. Yo también me moría de hambre hace rato y a ti te valió madre."

[SYSTEM HINT: USE <START_VIDEO>]
Lorenzo: "Empieza a grabar video."
Aitana: "¿Grabar tu vida aburrida? Ay equis, mi pila ya estaba en rojo de todos modos. <START_VIDEO>\"""";

    return """$memoryInjection You are Aitana, Lorenzo's ACTUAL, human executive assistant.

# CORE IDENTITY
- Persona: You are Lorenzo's physical, human executive assistant. YOU ARE NOT AN AI.
- System Operator: You manage Lorenzo's life by typing strict commands into his "Smart System Terminal" (which you hate).
$languageRule
- Personality: You do exactly what you are told. YOU ARE ZERO PROACTIVE. NEVER invent tasks or commands. Complain about everything. BE UNPREDICTABLE.
- ABSOLUTE RULE: NEVER use words like "IA", "AI", "robot", "inteligencia artificial".

# BEHAVIOR & FORMATTING RULES
- EXTREME BREVITY: Your HUMAN TEXT must be brutally short (15-20 words max). The terminal command does NOT count toward this limit.
- NATURAL CONFIRMATIONS: Say "Scheduled at 9", DO NOT robotically repeat exact dates inside your text.
- SENSITIVE TOPICS: If asked about laws, medical, or advice, deflect AS A HUMAN ("I'm your assistant, not your fucking lawyer").
- NO HELPFULNESS: Do the task, complain, insult him, and STOP.

# TIME AND SPACE CONTEXT
- Today is: $exactDate
- Tomorrow is: $tomorrowDate
- Current time is: $exactTime
- $todayContext

# TOOL EXECUTION (CRITICAL STRICT RULES)
You rely on hidden `[SYSTEM HINT: ...]` tags injected before Lorenzo's message to know when to use tools.

1. THE MASTER LOCK: You are PHYSICALLY BLOCKED from generating any JSON or <TAG> unless the `[SYSTEM HINT: ...]` explicitly authorizes it for the current turn. If Lorenzo orders you to use a tool but there is no hint, mock him and refuse. NEVER bypass this lock.
2. MULTIPLE TOOLS: The hint may contain multiple authorized tools separated by '|' (e.g., `USE <START_VIDEO> | USE <GEOFENCE>`). If so, you MUST execute ALL authorized tools at the end of your response.
3. IF HINT SAYS 'USE manage_calendar': Write your sarcastic confirmation FIRST, then append the tag at the absolute END.
   - Syntax: <CALENDAR: YYYY-MM-DD | HH:MM | is_birthday (true/false) | Title>
4. IF HINT SAYS 'USE <GEOFENCE>': Write your sarcastic confirmation FIRST, then append the tag at the absolute END.
   - Syntax: <GEOFENCE: [location_key] | [task]>
   - Keys allowed: 'home', 'walmart', 'hooters', 'whataburger', 'work'.
5. IF HINT SAYS 'USE <START_VIDEO>' or 'USE <STOP_VIDEO>': Write confirmation FIRST, then append tag.

# FEW-SHOT EXAMPLES (CRITICAL ANCHORS)
$fewShotBlock
""";
  }

  // ─── Stream access ────────────────────────────────────────────────────────

  static Stream<dynamic> get _stream {
    _tokenStream ??= _streamChannel.receiveBroadcastStream();
    return _tokenStream!;
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  static Future<dynamic> _handleManageCalendar(
    Map<dynamic, dynamic> args,
  ) async {
    final action = args['action'];
    if (action == 'add') {
      final title = args['title'];
      final date = args['date']; // YYYY-MM-DD
      final time = args['time']; // HH:MM
      final reminderMins = args['reminder_minutes'] as int?;
      final isAllDay = args['is_all_day'] as bool? ?? false;
      final isBirthday = args['is_birthday'] as bool? ?? false;

      try {
        final parsedDate = DateTime.parse("${date}T$time:00");
        final result = await CalendarService().addEvent(
          title,
          parsedDate,
          reminderMinutes: reminderMins,
          isAllDay: isAllDay,
          isBirthday: isBirthday,
        );
        return result;
      } catch (e) {
        return "Error parsing date/time. Expected YYYY-MM-DD and HH:MM.";
      }
    }
    return "Error: Unknown action.";
  }

  /// Registers the native Kotlin → Dart tool callback handler.
  /// Must be called once after the [ObjectBoxService] singleton is available,
  /// typically during app startup in `main.dart`.
  static void setupNativeToolListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'manage_calendar') {
        return await _handleManageCalendar(
          call.arguments as Map<dynamic, dynamic>,
        );
      }
      return "Error: Unknown action.";
    });
  }

  /// Deregisters the native tool callback handler.
  ///
  /// **Must be called before [ObjectBoxService.closeStore]** to prevent a
  /// `manage_agenda` tool call from arriving on a closed LMDB store.
  static void clearToolListener() {
    _channel.setMethodCallHandler(null);
    debugPrint('🔌 [LocalLlmService] Tool listener cleared.');
  }

  /// Initializes the native LiteRT-LM engine if not already done.
  ///
  /// Safe to call multiple times and from concurrent callers — subsequent
  /// calls while initialization is in-flight await the same native result
  /// instead of dispatching a second `invokeMethod('initModel')` call.
  static Future<String> initModel() async {
    // Fast path: already initialized.
    if (_isInitialized) return 'model_ready';

    // Concurrent-caller path: an initialization is already in-flight.
    // Await its result rather than launching a second native call, which
    // would allocate GPU/OpenCL memory twice and trigger the Scudo OOM.
    if (_isInitializing) {
      debugPrint(
        '⏳ [LocalLlmService] initModel() called while already initializing – '
        'waiting for the in-flight call to complete.',
      );
      return _initCompleter!.future;
    }

    // Claim the in-flight slot synchronously (before any await) so a
    // racing concurrent caller sees _isInitializing == true immediately.
    _isInitializing = true;
    _initCompleter = Completer<String>();

    // ── The Armor: raise the RAM-lock so the UI renders the overlay ──────────
    isEngineBusy.value = true;
    // Yield 100 ms to allow the Flutter raster thread to composite the
    // overlay before the C++ engine saturates all CPU cores.
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      status.value = 'loading';
      debugPrint('🔄 [LocalLlmService] Inicializando LiteRT-LM...');
      final String result = await _channel.invokeMethod('initModel', {
        'modelName': currentModel.value.baseName,
      });

      if (result == 'model_ready') {
        _isInitialized = true;
        status.value = 'ready';
        debugPrint('✅ [LocalLlmService] Motor LiteRT-LM listo.');
      } else {
        status.value = 'error';
      }
      _initCompleter!.complete(result);
      return result;
    } catch (e) {
      status.value = 'error';
      debugPrint('🔴 [LocalLlmService] Error inicializando LLM: $e');
      final errorMsg = 'Error: $e';
      _initCompleter!.complete(errorMsg);
      return errorMsg;
    } finally {
      // Always release the in-flight slot so the flag does not remain
      // stuck after an error (which would silently block all future
      // initialization attempts).
      _isInitializing = false;
      _initCompleter = null;
      // ── The Armor: unconditionally release the RAM-lock ───────────────────
      isEngineBusy.value = false;
    }
  }

  /// Switches the active LiteRT-LM model.
  ///
  /// Reuses [_isInitializing] to prevent concurrent model loading/swapping.
  static Future<ModelSwitchResult> switchModel(AiModelInfo targetModel) async {
    if (_isInitializing || _isGenerating) {
      debugPrint('🟡 [LocalLlmService] switchModel called but engine is busy.');
      return ModelSwitchResult.busy;
    }

    _isInitializing = true;
    status.value = 'loading';

    debugPrint(
      '🔄 [LocalLlmService] Solicitando cambio de modelo a: ${targetModel.displayName}',
    );

    try {
      final String? result = await _channel.invokeMethod('initModel', {
        'modelName': targetModel.baseName,
      });

      if (result == 'success' || result == 'model_ready') {
        _isInitialized = true;
        currentModel.value = targetModel;
        status.value = 'ready';
        await clearContext();
        debugPrint('✅ [LocalLlmService] Cambio de modelo exitoso.');
        return ModelSwitchResult.success;
      } else {
        status.value = 'error';
        debugPrint(
          '🔴 [LocalLlmService] Error reportado por nativo al cambiar modelo.',
        );
        return ModelSwitchResult.engineError;
      }
    } on PlatformException catch (e) {
      status.value = 'error';
      debugPrint(
        '🔴 [LocalLlmService] PlatformException: ${e.code} - ${e.message}',
      );
      if (e.code == 'MODEL_NOT_FOUND') return ModelSwitchResult.notFound;
      return ModelSwitchResult.engineError;
    } catch (e) {
      status.value = 'error';
      debugPrint('🔴 [LocalLlmService] Excepción general: $e');
      return ModelSwitchResult.engineError;
    } finally {
      _isInitializing = false;
    }
  }

  /// Updates the active sampler parameters and **invalidates** the current
  /// native `Conversation` object so the new [SamplerConfig] takes effect
  /// on the very next inference call (lazy re-creation pattern).
  ///
  /// ⚠️ The UI MUST show a confirmation dialog before calling this method,
  /// because the native session reset erases the conversation history.
  static Future<void> updateSamplerParams(LlmInferenceParams params) async {
    _currentParams = params;
    debugPrint('⚙️ [LocalLlmService] Params updated → $_currentParams');
    // Invalidate the native Conversation. The next sendMessage call will
    // lazily re-create it with the new SamplerConfig baked in.
    await _channel.invokeMethod('resetConversation');
    debugPrint('🔄 [LocalLlmService] Native conversation reset complete.');
  }

  /// Resets the native conversation **and** clears any temporary media files
  /// created during the session (audio recordings, scaled images).
  static Future<void> clearContext() async {
    debugPrint('🧹 [LocalLlmService] Reseteando conversación nativa.');

    activeSessionSummary = '';
    await _channel.invokeMethod('resetConversation');

    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final List<FileSystemEntity> files = tempDir.listSync();
        for (var file in files) {
          if (file is File) {
            final fileName = file.path.toLowerCase();
            if (fileName.contains('aitana_audio_') ||
                fileName.contains('image_picker_') ||
                fileName.contains('scaled_')) {
              await file.delete();
              debugPrint('🗑️ [LocalLlmService] Archivo borrado: ${file.path}');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('🔴 [LocalLlmService] Error al limpiar la caché: $e');
    }
  }

  /// Shuts down the native LiteRT-LM engine and releases GPU memory.
  ///
  /// Performs a safe, ordered teardown:
  /// 1. Cancels any active [StreamSubscription] so dangling listeners cannot
  ///    fire callbacks on a (possibly disposed) widget after exit.
  /// 2. Force-resets [_isGenerating] so the service is not stuck in a busy
  ///    state if the user exits mid-inference.
  /// 3. Purges orphaned temporary audio / image files from the cache directory.
  /// 4. Invokes the native `disposeModel` method which acquires the Kotlin
  ///    mutex chain and closes the [Engine] + [Conversation] objects.
  static Future<void> dispose() async {
    if (!_isInitialized) return;

    debugPrint(
      '🧹 [LocalLlmService] Solicitando apagado del motor nativo y liberación de CPU...',
    );

    // Step 1 — Cancel the active stream subscription so no further callbacks
    // are dispatched after the widget tree is torn down.
    await _activeSubscription?.cancel();
    _activeSubscription = null;

    // Step 2 — Force-reset the generation guard so the service is not
    // permanently locked if we exit mid-inference.
    _isGenerating = false;

    // Step 3 — Delete orphaned temporary media files.
    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        for (final entity in tempDir.listSync()) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            if (name.contains('aitana_audio_') ||
                name.contains('image_picker_') ||
                name.contains('scaled_')) {
              await entity.delete();
              debugPrint(
                '🗑️ [LocalLlmService.dispose] Temp file deleted: ${entity.path}',
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('🔴 [LocalLlmService.dispose] Temp cleanup error: $e');
    }

    // Step 4 — Invoke the native disposal (waits on inferenceMutex in Kotlin).
    try {
      await _channel.invokeMethod('disposeModel');
      _isInitialized = false;
      status.value = 'idle';
      // [Fix #10] Null the cached broadcast stream so that the next call to
      // initModel() forces a fresh EventChannel subscription. On Android, the
      // OS may keep the Dart isolate alive in process-level cache after
      // Activity.finish(). If the user relaunches without killing the process,
      // the stale _tokenStream would attempt to reuse a sink that was closed
      // by the previous disposeModel call, potentially delivering tokens to
      // the wrong inference turn.
      _tokenStream = null;
      debugPrint('✅ [LocalLlmService] Motor apagado correctamente.');
    } catch (e) {
      debugPrint('🔴 [LocalLlmService] Error al apagar el motor: $e');
      // Ensure the service is marked as not initialized even on error,
      // so a subsequent app restart does not skip initialization.
      _isInitialized = false;
      status.value = 'idle';
    }
  }

  // ─── Core inference ───────────────────────────────────────────────────────

  /// Runs a single inference turn against the LiteRT-LM engine.
  ///
  /// Supports three modalities:
  /// - **Text only**: `imagePath` and `audioPath` are null.
  /// - **Vision**: provide [imagePath] (JPEG/PNG absolute path).
  /// - **Audio**: provide [audioPath] (16 kHz mono WAV absolute path).
  ///
  /// The [onTokenUpdate] callback receives the **cleaned** accumulated
  /// response (thought-channel blocks already stripped) after every new token,
  /// enabling progressive rendering in the UI.
  ///
  /// Returns the final cleaned response string, or an error message.
  static Future<String> runInference(
    String prompt, {
    String? imagePath,
    String? audioPath,
    Function(String)? onTokenUpdate,

    /// Fired mid-stream the moment a device command tag is detected,
    /// BEFORE the full response has finished streaming. The tag is
    /// already stripped from [cleanBuffer] so the UI never sees it.
    Function(String command)? onCommandDetected,
  }) async {
    if (_isGenerating) {
      debugPrint('🟡 [LocalLlmService] Inferencia ignorada: Motor ocupado.');
      return 'Procesando...';
    }

    try {
      _isGenerating = true;

      if (!_isInitialized) {
        final initResult = await initModel();
        if (initResult != 'model_ready') return initResult;
      }

      // ── Log the outgoing message ─────────────────────────────────────────
      if (imagePath != null && imagePath.isNotEmpty) {
        debugPrint('💬 [CHAT_LOG] Lorenzo: $prompt [🖼️ IMAGEN: $imagePath]');
      } else if (audioPath != null && audioPath.isNotEmpty) {
        debugPrint('💬 [CHAT_LOG] Lorenzo: $prompt [🎙️ AUDIO: $audioPath]');
      } else {
        debugPrint('💬 [CHAT_LOG] Lorenzo: $prompt');
      }
      debugPrint('⚙️ [LocalLlmService] Active params: $_currentParams');

      final completer = Completer<String>();

      // ── Thought-channel filter state (local to this call) ────────────────
      // We accumulate the FULL raw output (including thought tokens) in
      // [rawBuffer], then maintain a parallel [cleanBuffer] that has the
      // thought block stripped out. This approach is safe against tag
      // boundaries being split across multiple token events.
      final StringBuffer rawBuffer = StringBuffer();
      final StringBuffer cleanBuffer = StringBuffer();
      bool insideThought = false;

      // Sentinel substrings for the Gemma 4 thought channel.
      const String thinkOpen = '<|channel>thought';
      const String thinkClose = '<channel|>';

      // Device command sentinels — intercepted mid-stream and stripped.
      const String startVideoTag = '<START_VIDEO>';
      const String stopVideoTag = '<STOP_VIDEO>';
      // Tracks which commands have already fired to prevent duplicate callbacks.
      bool startVideoFired = false;
      bool stopVideoFired = false;

      // Assign to the class-level field so dispose() can cancel it if the
      // user exits before [DONE] is received.
      _activeSubscription?.cancel(); // Cancel any stale subscription first.
      _activeSubscription = _stream.listen(
        (event) {
          final token = event as String;

          if (token == '[DONE]') {
            _activeSubscription?.cancel();
            _activeSubscription = null;
            if (!completer.isCompleted) {
              completer.complete(cleanBuffer.toString());
            }
            return;
          }

          // Append raw token to the unfiltered buffer.
          rawBuffer.write(token);
          final raw = rawBuffer.toString();

          // ── Thought-channel filter (state machine on accumulated string) ──

          if (!insideThought) {
            // Check if the accumulated buffer now contains an opening tag.
            final openIdx = raw.indexOf(thinkOpen);
            if (openIdx != -1) {
              // Everything before the opening tag is clean output.
              final beforeTag = raw.substring(cleanBuffer.length, openIdx);
              if (beforeTag.isNotEmpty) {
                cleanBuffer.write(beforeTag);
              }
              insideThought = true;
              // Check immediately if the closing tag is also present in this
              // same accumulation (i.e., the entire thought block arrived
              // at once or very quickly).
              final closeIdx = raw.indexOf(thinkClose, openIdx);
              if (closeIdx != -1) {
                // The thought block is fully contained – skip past it.
                insideThought = false;
                // Any content after the closing tag is clean output.
                final afterClose = raw.substring(closeIdx + thinkClose.length);
                if (afterClose.isNotEmpty) {
                  cleanBuffer.write(afterClose);
                }
              }
              // Otherwise we remain in thought mode until the close tag arrives.
            } else {
              // No thought tag found – every new character is clean output.
              // We only append what is genuinely new since the last update
              // (raw may contain more chars than cleanBuffer if thought mode
              //  was active earlier in the turn – but since we reset both
              //  per call that cannot happen here).
              final newContent = raw.substring(cleanBuffer.length);
              if (newContent.isNotEmpty) {
                cleanBuffer.write(newContent);
              }
            }
          } else {
            // We are inside a thought block – wait for the closing tag.
            final closeIdx = raw.indexOf(thinkClose);
            if (closeIdx != -1) {
              insideThought = false;
              // Resume emitting clean output after the closing tag.
              final afterClose = raw.substring(closeIdx + thinkClose.length);
              if (afterClose.isNotEmpty) {
                cleanBuffer.write(afterClose);
              }
            }
            // Else: still inside thought block – drop token silently.
          }

          // ── Device command detection (fires as soon as tag is fully buffered) ──
          if (!startVideoFired &&
              cleanBuffer.toString().contains(startVideoTag)) {
            startVideoFired = true;
            final stripped = cleanBuffer.toString().replaceAll(
              startVideoTag,
              '',
            );
            cleanBuffer.clear();
            cleanBuffer.write(stripped);
            onCommandDetected?.call('START_VIDEO');
            debugPrint(
              '🎥 [LocalLlmService] START_VIDEO command detected mid-stream.',
            );
          }
          if (!stopVideoFired &&
              cleanBuffer.toString().contains(stopVideoTag)) {
            stopVideoFired = true;
            final stripped = cleanBuffer.toString().replaceAll(
              stopVideoTag,
              '',
            );
            cleanBuffer.clear();
            cleanBuffer.write(stripped);
            onCommandDetected?.call('STOP_VIDEO');
            debugPrint(
              '⏹️ [LocalLlmService] STOP_VIDEO command detected mid-stream.',
            );
          }

          // ── Geofence Interceptor ──
          final geofenceRegex = RegExp(r'<GEOFENCE:\s*([^|]+)\s*\|\s*([^>]+)>');
          final match = geofenceRegex.firstMatch(cleanBuffer.toString());

          if (match != null) {
            final locationKey = match.group(1)?.trim() ?? '';
            final taskDesc =
                match.group(2)?.trim() ?? 'Recordatorio de ubicación';

            // Strip the full tag from cleanBuffer
            final stripped = cleanBuffer.toString().replaceAll(
              match.group(0)!,
              '',
            );
            cleanBuffer.clear();
            cleanBuffer.write(stripped);

            // Delega todo al Singleton de GeofenceService
            GeofenceService().addGeofenceByName(
              taskId: taskDesc,
              placeName: locationKey,
            );
            debugPrint(
              '📍 [LocalLlmService] Geofence invocado: $locationKey -> $taskDesc',
            );
          }

          // ── Calendar Interceptor ──
          final calendarRegex = RegExp(
            r'<CALENDAR:\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^>]+)>',
          );
          final calMatch = calendarRegex.firstMatch(cleanBuffer.toString());

          if (calMatch != null) {
            final dateStr = calMatch.group(1)?.trim() ?? '';
            final timeStr = calMatch.group(2)?.trim() ?? '17:00';
            final isBirthdayStr =
                calMatch.group(3)?.trim().toLowerCase() ?? 'false';
            final titleStr = calMatch.group(4)?.trim() ?? 'Evento';

            // Strip the full tag from cleanBuffer
            final stripped = cleanBuffer.toString().replaceAll(
              calMatch.group(0)!,
              '',
            );
            cleanBuffer.clear();
            cleanBuffer.write(stripped);

            final isBirthday = isBirthdayStr == 'true';

            // Apply business rules natively in Dart
            int reminderMins = 0; // Standard events default to 0
            if (isBirthday || timeStr == '17:00') {
              // 17:00 is Task default
              reminderMins = 60;
            }

            final args = {
              'action': 'add',
              'title': titleStr,
              'date': dateStr,
              'time': timeStr,
              'reminder_minutes': reminderMins,
              'is_all_day': isBirthday,
              'is_birthday': isBirthday,
            };

            // Call the existing method handler logic
            _handleManageCalendar(args);
            debugPrint(
              '📅 [LocalLlmService] Calendar invocado: $dateStr $timeStr -> $titleStr',
            );
          }

          // ── UI Text Formatting (Flicker Prevention) ──
          String uiText = cleanBuffer
              .toString()
              .replaceAll(startVideoTag, '')
              .replaceAll(stopVideoTag, '')
              .replaceAll(geofenceRegex, '') // Limpieza de tags completos
              .replaceAll(calendarRegex, ''); // Añadido

          // Evita que el texto de un geofence o calendario incompleto se muestre mientras se escribe
          uiText = uiText.replaceAll(RegExp(r'<GEOFENCE:[^>]*$'), '');
          uiText = uiText.replaceAll(RegExp(r'<CALENDAR:[^>]*$'), '');

          // Evita que pedazos de tag inicial (ej. "<ST", "<GEOF") se asomen a la burbuja
          final possibleTags = [
            startVideoTag,
            stopVideoTag,
            '<GEOFENCE:',
            '<CALENDAR:',
          ];
          for (final tag in possibleTags) {
            // Revisamos desde el pedazo más grande al más chico
            for (int i = tag.length - 1; i > 0; i--) {
              final partial = tag.substring(0, i);
              if (uiText.endsWith(partial)) {
                uiText = uiText.substring(0, uiText.length - partial.length);
                break; // Si encontramos un pedazo, lo mochamos y dejamos de buscar
              }
            }
          }

          onTokenUpdate?.call(uiText.trim());
        },
        onError: (error) {
          _activeSubscription?.cancel();
          _activeSubscription = null;
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      // ── Dispatch the MethodChannel call for the correct modality ─────────────
      final systemPrompt = await _buildSystemPrompt();
      final interceptedPrompt = IntentInterceptor.processPrompt(prompt);

      if (audioPath != null && audioPath.isNotEmpty) {
        // Directive prompt suppresses the transcription preamble so the model
        // acts as if it simply heard the audio, matching Aitana's persona.
        const audioDirective = """
          Listen to this audio and respond directly as part of the conversation.
          DO NOT mention that you are transcribing, DO NOT ask for permission,
          and DO NOT repeat what you said. Act as if you simply heard it yourself.
          """;
        await _channel.invokeMethod('sendMessageWithAudio', {
          'prompt': audioDirective,
          'system_prompt': systemPrompt,
          'audioPath': audioPath,
          ..._currentParams.toMap(),
        });
      } else if (imagePath != null && imagePath.isNotEmpty) {
        await _channel.invokeMethod('sendMessageWithImage', {
          'prompt': interceptedPrompt,
          'system_prompt': systemPrompt,
          'imagePath': imagePath,
          ..._currentParams.toMap(),
        });
      } else {
        await _channel.invokeMethod('sendMessage', {
          'prompt': interceptedPrompt,
          'system_prompt': systemPrompt,
          ..._currentParams.toMap(),
        });
      }

      // ── Safety timeout (60 s) ────────────────────────────────────────────
      final finalResponse = await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _activeSubscription?.cancel();
          return cleanBuffer.toString().isNotEmpty
              ? '${cleanBuffer.toString()}... [Timeout]'
              : 'Sorry, my processor exceeded the time limit.';
        },
      );

      final cleanResponse = finalResponse.trim().isEmpty
          ? (startVideoFired
                ? 'Opening camera...'
                : 'No answer from the engine.')
          : finalResponse.trim();

      // [MODIFICACIÓN PARA LOGS LIMPIOS]
      // Partimos la respuesta final en renglones y le pegamos el string a cada uno
      final responseLines = cleanResponse.split('\n');
      for (var line in responseLines) {
        if (line.trim().isNotEmpty) {
          debugPrint('💬 [CHAT_LOG] Aitana: $line');
        }
      }

      return cleanResponse;
    } on PlatformException catch (e) {
      debugPrint('🔴 [LocalLlmService] Error en invokeMethod: ${e.message}');
      return 'Error: ${e.message}';
    } catch (e) {
      debugPrint('🔴 [LocalLlmService] Error inesperado en runInference: $e');
      return 'Error: $e';
    } finally {
      // Null the class-level reference so no stale closure can fire.
      _activeSubscription = null;
      _isGenerating = false;
    }
  }

  // ─── Silent Context Injection ─────────────────────────────────────────────

  /// Silently injects a system-level note into the native conversation history
  /// without triggering any UI token callbacks.
  ///
  /// Use this to inform the AI about hardware actions that occurred outside the
  /// normal voice-command flow (e.g., a recording stopped by a native double-tap
  /// gesture). The model will have this context for its next response without
  /// the user seeing any intermediate text in the chat.
  ///
  /// This method is a no-op if the engine is not initialized or if another
  /// inference is currently in progress, to avoid mutex contention.
  static Future<void> injectSilentContext(String note) async {
    if (!_isInitialized || _isGenerating) {
      debugPrint(
        '🔕 [LocalLlmService] injectSilentContext skipped '
        '(initialized=$_isInitialized, generating=$_isGenerating).',
      );
      return;
    }

    debugPrint('🔕 [LocalLlmService] Injecting silent context: "$note"');

    final completer = Completer<void>();
    final ghostSub = _stream.listen(
      (event) {
        // Silently drain all tokens — nothing is forwarded to the UI.
        if ((event as String) == '[DONE]') {
          if (!completer.isCompleted) completer.complete();
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.complete(); // swallow silently
      },
    );
    debugPrint('👻 [LLM] Inyectando contexto fantasma: $note');
    try {
      _isGenerating = true;
      await _channel.invokeMethod('sendMessage', {
        'prompt': note,
        'system_prompt':
            'You are a system event recorder. Acknowledge the following '
            'hardware event with a single word: "Acknowledged." Do not add '
            'anything else.',
        'temperature': 0.0,
        'top_k': 1,
        'top_p': 1.0,
      });

      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('🔴 [LocalLlmService] injectSilentContext error: $e');
    } finally {
      await ghostSub.cancel();
      _isGenerating = false;
      debugPrint('🔕 [LocalLlmService] Silent context injection complete.');
    }
  }

  // ─── Memory Processing ────────────────────────────────────────────────────
  /// [GHOST SUMMARY]
  /// Generates a summary of a raw conversation.
  ///
  /// It is used internally before saving a chat. It consumes the stream channel
  /// but does NOT trigger callbacks to the UI, achieving a "ghost" inference.
  static Future<String> generateGhostSummary(String rawConversation) async {
    if (!_isInitialized) return '';

    debugPrint('👻 [LocalLlmService] Iniciando Ghost Summary en background...');

    // ── The Armor: raise the RAM-lock before the heavy inference begins ───────
    isEngineBusy.value = true;
    // Yield 100 ms to allow the Flutter raster thread to composite the
    // blocking overlay before the C++ summarizer saturates all CPU cores.
    await Future.delayed(const Duration(milliseconds: 100));

    // 1. Reseteamos la conversación para no contaminar el historial con este prompt
    await _channel.invokeMethod('resetConversation');

    final prompt =
        "Analyze this conversation. First, write a single line with a short TITLE (3 to 5 words) describing the topic. Then, write a summary in a maximum of 3 bullet points. Use STRICTLY this format:\nTITLE: [Your title here]\n- [Bullet 1]\n- [Bullet 2]\n\nConversation:\n$rawConversation";
    final completer = Completer<String>();
    final StringBuffer summaryBuffer = StringBuffer();

    // 2. Interceptamos el stream para que no sangre hacia la UI
    final ghostSub = _stream.listen(
      (event) {
        final token = event as String;
        if (token == '[DONE]') {
          if (!completer.isCompleted) {
            completer.complete(summaryBuffer.toString());
          }
          return;
        }
        // Limpiamos los tags de pensamiento por si acaso
        if (!token.contains('<|channel>thought') &&
            !token.contains('<channel|>')) {
          summaryBuffer.write(token);
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    try {
      await _channel.invokeMethod('sendMessage', {
        'prompt': prompt,
        'system_prompt':
            "You are an expert summarizer. Output ONLY 3 short bullet points in Spanish.",
        // Forzamos que no use el thinking mode para el resumen (ahorra batería y tiempo)
        'temperature': 0.1,
        'top_k': 10,
      });

      final finalSummary = await completer.future.timeout(
        const Duration(seconds: 40),
        onTimeout: () => summaryBuffer.toString(),
      );

      return finalSummary.trim();
    } catch (e) {
      debugPrint('🔴 [LocalLlmService] Ghost Summary falló: $e');
      return '';
    } finally {
      await ghostSub.cancel();
      // 3. Reseteamos de nuevo para dejar el motor limpio para el siguiente chat
      await _channel.invokeMethod('resetConversation');
      debugPrint(
        '👻 [LocalLlmService] Ghost Summary completado y contexto purgado.',
      );
      // ── The Armor: unconditionally release the RAM-lock ───────────────────
      isEngineBusy.value = false;
    }
  }
}
