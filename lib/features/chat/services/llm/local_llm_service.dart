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
import 'package:aitana/features/chat/services/llm/prompts/prompt_manager.dart';
import 'package:aitana/features/chat/services/llm/tools/tool_parser.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/features/vault/tools/vault_search_tool.dart';

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
  static const MethodChannel _channel = MethodChannel(NativeChannels.aiCore);
  static const EventChannel _streamChannel = EventChannel(
    NativeChannels.aiCoreStream,
  );

  // ─── Internal state ───────────────────────────────────────────────────────

  static final ValueNotifier<String> currentLanguageNotifier = ValueNotifier(
    'ES',
  );
  static bool _isInitialized = false;

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

  /// Emits true while the inference engine is busy generating tokens.
  static final ValueNotifier<bool> isGeneratingNotifier = ValueNotifier(false);

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

  // ─── RAG Gatekeeper ───────────────────────────────────────────────────────

  /// Normalized words that signal a conversational (non-legal) message.
  ///
  /// If ALL meaningful keywords in a query are present in this set, the RAG
  /// pipeline is skipped entirely — Gate 2 blocks the search.
  static const Set<String> _conversationalSignals = {
    // Spanish
    'hola', 'adios', 'gracias', 'ayuda', 'recuerdas', 'dijiste', 'ayer',
    'manana', 'buenas', 'claro', 'perfecto', 'bien', 'vale',
    // English
    'hello', 'goodbye', 'thanks', 'thank', 'remember', 'said', 'yesterday',
    'tomorrow', 'sure', 'okay', 'great', 'good',
  };

  /// Normalizes a raw message to a deduplicated set of 4+ char keywords,
  /// mirroring the chunker's normalization to ensure index compatibility.
  static Set<String> _normalizeToKeywords(String text) {
    String normalized = text.toLowerCase();
    normalized = normalized.replaceAll(RegExp(r'[áàäâã]'), 'a');
    normalized = normalized.replaceAll(RegExp(r'[éèëê]'), 'e');
    normalized = normalized.replaceAll(RegExp(r'[íìïî]'), 'i');
    normalized = normalized.replaceAll(RegExp(r'[óòöôõ]'), 'o');
    normalized = normalized.replaceAll(RegExp(r'[úùüû]'), 'u');
    normalized = normalized.replaceAll(RegExp(r'[ñ]'), 'n');
    normalized = normalized.replaceAll(RegExp(r'[^\w\s]'), '');

    // ── Preprocessing: Normalize Legal Ordinals ─────────────────────────────
    // Convert written suffixes like "4to", "4vo" into the official "4o".
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)(to|vo|no|mo|avo)\b'),
      (match) => '${match.group(1)}o',
    );
    // Convert standalone digits following "articulo" or "art" into ordinals.
    // E.g. "articulo 4" -> "articulo 4o". Lookahead ensures no double 'o'.
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(articulo|art)\s+(\d+)(?!o)\b'),
      (match) => '${match.group(1)} ${match.group(2)}o',
    );
    // ────────────────────────────────────────────────────────────────────────

    return normalized.split(RegExp(r'\s+')).where((k) => k.length >= 2).toSet();
  }

  /// Returns `true` if the keyword set contains at least one non-conversational
  /// term that could plausibly match legal document text.
  static bool _isLikelyLegalQuery(Set<String> keywords) {
    final legalKeywords = keywords.difference(_conversationalSignals);
    return legalKeywords.length >= 2;
  }

  // ─── System Prompt ────────────────────────────────────────────────────────

  /// Constructs the dynamic system prompt for the current turn.
  ///
  /// When [LlmInferenceParams.enableThinking] is `true`, the Gemma 4 native
  /// reasoning control token `<|think|>` is appended as the **final** content
  /// of the system instruction string. This activates the model's built-in
  /// thought channel for the entire session without requiring per-turn prefixes.

  static Future<String> _buildSystemPrompt([
    String? armedToolHint,
    String? userMessage,
  ]) async {
    // ── RAG Gatekeeper Pipeline ────────────────────────────────────────────
    String? retrievedLegalContext;
    final activePersona = ObjectBoxService.instance.personaManager
        .getActivePersona();

    if (activePersona.category == 'LEGAL' &&
        userMessage != null &&
        userMessage.isNotEmpty) {
      // Gate 0: Is the legal library populated at all?
      if (!ObjectBoxService.instance.hasLegalKnowledge) {
        debugPrint('🚫 [RAG Gate 0] Library is empty. Skipping search.');
      } else {
        // Gate 1: Does the query have enough meaningful keywords?
        final keywords = _normalizeToKeywords(userMessage);
        if (keywords.length < 2) {
          debugPrint(
            '🚫 [RAG Gate 1] Too few keywords (${keywords.length}). Skipping search.',
          );
        } else if (!_isLikelyLegalQuery(keywords)) {
          // Gate 2: Is it likely a legal query vs. a conversational message?
          debugPrint(
            '🚫 [RAG Gate 2] Query appears conversational. Skipping search.',
          );
        } else {
          // Gate 3: Execute retrieval and apply score threshold
          debugPrint('🔍 [RAG Gate 3] Querying: "$userMessage"');
          final ranked = ObjectBoxService.instance.searchLegalContext(
            userMessage,
            limit: 6,
          );
          debugPrint('📊 [RAG] Chunks retrieved: ${ranked.length}');

          if (ranked.isEmpty || ranked.first.score < 2) {
            debugPrint(
              '🚫 [RAG Gate 3] Top score (${ranked.isEmpty ? 0 : ranked.first.score}) '
              'below threshold of 2. Aborting injection.',
            );
          } else {
            // ✅ All gates passed — build the context string
            final buffer = StringBuffer();
            for (final entry in ranked) {
              final authLabel = entry.chunk.authorityWeight == 3
                  ? 'HIGHEST AUTHORITY (Ley/Código)'
                  : entry.chunk.authorityWeight == 2
                  ? 'HIGH AUTHORITY (Jurisprudencia)'
                  : 'STANDARD AUTHORITY (Doctrina)';

              buffer.writeln(
                'Document: ${entry.chunk.documentName} [$authLabel]',
              );
              if (entry.chunk.chapterContext.isNotEmpty) {
                buffer.writeln(
                  'Context: ${entry.chunk.chapterContext} / ${entry.chunk.sectionContext}',
                );
              }
              buffer.writeln(entry.chunk.rawText);
              buffer.writeln('---');
            }
            retrievedLegalContext = buffer.toString().trim();
            final snippetEnd = retrievedLegalContext.length > 200
                ? 200
                : retrievedLegalContext.length;
            debugPrint(
              '📚 [RAG] ✅ Injecting ${ranked.length} chunks (top score: ${ranked.first.score}):\n${retrievedLegalContext.substring(0, snippetEnd)}...',
            );
          }
        }
      }
    }

    return PromptManager.buildSystemPrompt(
      modelBaseName: currentModel.value.baseName,
      activeSessionSummary: activeSessionSummary,
      getTodayEvents: () => CalendarService().getTodayEvents(),
      enableThinking: _currentParams.enableThinking,
      armedToolHint: armedToolHint,
      retrievedLegalContext: retrievedLegalContext,
    );
  }

  /// Encapsulates the state-clearing logic previously used in the UI.
  /// Clears the LLM context, clears the active session summary, and
  /// executes the provided callback to clear UI messages and session IDs.
  static Future<void> resetSessionState({Function()? onClearUi}) async {
    await clearContext();

    activeSessionSummary = '';
    if (onClearUi != null) {
      onClearUi();
    }
  }

  // ─── Stream access ────────────────────────────────────────────────────────

  static Stream<dynamic> get _stream {
    _tokenStream ??= _streamChannel.receiveBroadcastStream();
    return _tokenStream!;
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Gracefully stops any active inference mid-stream.
  ///
  /// Cancels the active [StreamSubscription] and signals completion with
  /// whatever text the model has generated so far. This is the correct
  /// handler for the UI's "Stop Generation" button — it works during both
  /// the thinking phase AND the active text-generation phase.
  ///
  /// No-op if no inference is currently in progress.
  static void stopInference() {
    if (_activeSubscription == null) return;
    debugPrint('🛑 [LocalLlmService] stopInference() called by user.');
    _activeSubscription?.cancel();
    _activeSubscription = null;
    // _isGenerating is reset in the `finally` block of runInference().
  }

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
      if (call.method == 'search_vault') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final keyword = args['keyword'] as String;
        return await VaultSearchTool.searchVault(keyword);
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

  /// Routes to the correct AI model based on the newly activated persona category.
  ///
  /// - `'LEGAL'` → `gemma_4b_variant` (Uncensored, higher factual fidelity).
  /// - `'AI'` / `'HUMAN'` → `gemma_4b` (Standard, conversational default).
  ///
  /// Returns [ModelSwitchResult.alreadyActive] if the required model is already
  /// loaded, avoiding an unnecessary native reload cycle.
  static Future<ModelSwitchResult> autoSwitchModelForCategory(
    String category,
  ) async {
    final targetBaseName = (category == 'LEGAL' || category == 'HUMAN')
        ? 'gemma_4b_variant'
        : 'gemma_4b';

    final target = AiModelCatalog.findByBaseName(targetBaseName);
    if (target == null) {
      debugPrint(
        '🔴 [MoE Router] Model "$targetBaseName" not found in catalog.',
      );
      return ModelSwitchResult.notInCatalog;
    }

    if (currentModel.value.baseName == target.baseName) {
      debugPrint(
        '⚡ [MoE Router] "${target.displayName}" already active. No switch needed.',
      );
      return ModelSwitchResult.alreadyActive;
    }

    debugPrint(
      '🧠 [MoE Router] Persona category "$category" → switching to "${target.displayName}"',
    );
    return switchModel(target);
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

    /// already stripped from [cleanBuffer] so the UI never sees it.
    Function(String command)? onCommandDetected,

    /// Fired mid-stream when a vault search request is detected.
    Function(String query)? onVaultSearchDetected,
  }) async {
    if (_isGenerating) {
      debugPrint('🟡 [LocalLlmService] Inferencia ignorada: Motor ocupado.');
      return 'Procesando...';
    }

    ToolParser? toolParser;
    try {
      _isGenerating = true;
      isGeneratingNotifier.value = true;

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

      final interceptedPrompt = IntentInterceptor.processPrompt(prompt);

      // ── Layer 1 & 2: Gating & Dynamic Injection ─────────────────────────
      String? toolHint;
      final List<String> allowedTags = [];

      if (interceptedPrompt.startsWith('[SYSTEM HINT:')) {
        final closingBracket = interceptedPrompt.indexOf(']');
        if (closingBracket != -1) {
          toolHint = interceptedPrompt.substring(0, closingBracket + 1);
          // Optics
          if (toolHint.contains('<CMD_SYS_OPTICS_1>')) {
            allowedTags.add('<CMD_SYS_OPTICS_1>');
            allowedTags.add('<CMD_SYS_OPTICS_0>');
          }
          // Geofence
          if (toolHint.contains('<CMD_SYS_LOC_TRG')) {
            allowedTags.add('<CMD_SYS_LOC_TRG:');
          }
          // Calendar
          if (toolHint.contains('manage_calendar')) {
            allowedTags.add('<CMD_SYS_CAL_EVT:');
          }
        }
      }

      toolParser = ToolParser(
        onCommandDetected: onCommandDetected,
        onGeofenceDetected: (location, task) {
          GeofenceService().addGeofenceByName(
            taskId: task,
            placeName: location,
          );
          debugPrint(
            '📍 [LocalLlmService] Geofence invocado: $location -> $task',
          );
        },
        onCalendarDetected: (args) {
          _handleManageCalendar(args);
          debugPrint(
            '📅 [LocalLlmService] Calendar invocado: ${args['date']} ${args['time']} -> ${args['title']}',
          );
        },
        onVaultSearchDetected: (query) {
          onVaultSearchDetected?.call(query);
          debugPrint('🔐 [LocalLlmService] Vault Search invocado: $query');
        },
      );

      if (allowedTags.isNotEmpty) {
        toolParser.armParser(allowedTags);
      }

      final completer = Completer<String>();

      // ── Dart-side Sliding Window Repetition Guard ────────────────────────
      // Maintains a rolling buffer of the last ~80 tokens (as a joined string).
      // After every token, it tests whether a 10-word phrase appears 3+ times.
      // If so, the stream is force-cancelled and inference is terminated with
      // a diagnostic notice. This is the last-resort fallback when the native
      // engine's repetition_penalty parameter fails to break the feedback loop.
      final List<String> tokenBuffer = [];
      const int bufferMaxTokens = 80;
      const int phraseWords = 10;
      const int repeatThreshold = 3;

      bool detectRepetition(List<String> buffer) {
        if (buffer.length < phraseWords * repeatThreshold) return false;
        final text = buffer.join(' ');
        final words = text.split(' ');
        // Slide a 10-word window; check if it appears >= 3 times in the buffer.
        for (int i = 0; i <= words.length - phraseWords; i++) {
          final phrase = words.sublist(i, i + phraseWords).join(' ');
          int count = 0;
          int searchStart = 0;
          while (true) {
            final idx = text.indexOf(phrase, searchStart);
            if (idx == -1) break;
            count++;
            if (count >= repeatThreshold) return true;
            searchStart = idx + 1;
          }
        }
        return false;
      }

      _activeSubscription?.cancel(); // Cancel any stale subscription first.
      _activeSubscription = _stream.listen(
        (event) {
          final token = event as String;

          if (token == '[DONE]') {
            _activeSubscription?.cancel();
            _activeSubscription = null;
            if (!completer.isCompleted) {
              completer.complete(toolParser?.getFinalCleanText() ?? '');
            }
            return;
          }

          // Feed the repetition guard.
          tokenBuffer.add(token);
          if (tokenBuffer.length > bufferMaxTokens) {
            tokenBuffer.removeAt(0);
          }
          if (detectRepetition(tokenBuffer)) {
            debugPrint(
              '🔁 [LocalLlmService] Repetition loop detected — force-terminating inference.',
            );
            _activeSubscription?.cancel();
            _activeSubscription = null;
            if (!completer.isCompleted) {
              final partial = toolParser?.getFinalCleanText() ?? '';
              completer.complete(
                partial.isNotEmpty
                    ? '$partial\n\n[INFERENCE TERMINATED: REPETITION LOOP DETECTED]'
                    : '[INFERENCE TERMINATED: REPETITION LOOP DETECTED]',
              );
            }
            return;
          }

          final uiText = toolParser?.parseToken(token) ?? '';
          onTokenUpdate?.call(uiText);
        },
        onError: (error) {
          _activeSubscription?.cancel();
          _activeSubscription = null;
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      // ── Dispatch the MethodChannel call for the correct modality ─────────────
      final systemPrompt = await _buildSystemPrompt(toolHint, prompt);

      debugPrint('=== FINAL SYSTEM PROMPT SENT TO KOTLIN ===');
      debugPrint(systemPrompt);
      debugPrint('==========================================');

      if (audioPath != null && audioPath.isNotEmpty) {
        const audioDirective = PromptManager.audioDirective;
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
          final partial = toolParser?.getFinalCleanText() ?? '';
          return partial.isNotEmpty
              ? '$partial... [Timeout]'
              : 'Sorry, my processor exceeded the time limit.';
        },
      );

      final cleanResponse = finalResponse.trim().isEmpty
          ? (toolParser.startVideoFired
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
      toolParser?.disarmParser();
      _activeSubscription = null;
      _isGenerating = false;
      isGeneratingNotifier.value = false;
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
