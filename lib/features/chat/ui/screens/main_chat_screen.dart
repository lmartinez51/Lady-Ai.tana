import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:aitana/core/domain/entities/chat_session.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:aitana/core/theme/persona_theme_router.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/core/services/network/network_service.dart';
import 'package:aitana/core/services/device/device_event_service.dart';
import 'package:aitana/features/chat/services/llm/models/llm_inference_params.dart';
import 'package:aitana/features/chat/ui/dialogs/settings_dialog_widget.dart';
import 'package:aitana/features/auth/providers/auth_provider.dart';
import 'package:aitana/features/chat/ui/widgets/exit_sequence_widget.dart';
import 'package:aitana/features/dev_tools/ui/dev_tools_bottom_sheet.dart';
import 'package:aitana/features/chat/domain/entities/chat_message.dart';
import 'package:aitana/features/chat/ui/widgets/chat_bubble_widget.dart';
import 'package:aitana/features/chat/ui/widgets/voice_input_panel.dart';
import 'package:aitana/core/theme/widgets/system_lock_overlay.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/features/chat/ui/widgets/chat_header_widget.dart';
import 'package:aitana/features/rag/screens/legal_library_screen.dart';
import 'package:aitana/features/vault/services/vault_ingestion_service.dart';
import 'package:aitana/features/vault/ui/screens/vault_manager_screen.dart';
import 'package:aitana/features/developer/screens/persona_vault_screen.dart';

const Color _kChatObsidian = Color(0xFF0B0D17);
const Color _kLorenzoBubbleColor = Color(0xFF102A33);

enum _VaultContinuationState { idle, queued, retrieving }

enum _AttachmentMenuAction { camera, gallery, legalLibrary, personalVault }

class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen>
    with WidgetsBindingObserver {
  static const double _chatHeaderBodyHeight = 60.0;
  static const double _inputFooterMinHeight = 76.0;
  static const double _inputFooterMaxHeight = 244.0;
  static const Color _userBubbleColor = _kLorenzoBubbleColor;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<VoiceInputPanelState> _voiceKey =
      GlobalKey<VoiceInputPanelState>();

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  Timer? _autoScrollThrottle;
  bool _forceNextAutoScroll = false;
  final LayerLink _attachmentMenuLayerLink = LayerLink();
  final ValueNotifier<bool> _attachmentMenuOpenNotifier = ValueNotifier(false);
  OverlayEntry? _attachmentMenuOverlayEntry;
  Timer? _attachmentMenuRemovalTimer;
  final ImagePicker _picker = ImagePicker();

  final ValueNotifier<List<ChatMessage>> _messagesNotifier = ValueNotifier([]);
  List<ChatMessage> get _messages => _messagesNotifier.value;

  void _addMessage(ChatMessage msg) {
    _messagesNotifier.value = List.from(_messagesNotifier.value)..add(msg);
  }

  void _clearMessages() {
    _messagesNotifier.value = [];
  }

  void _notifyMessagesChanged() {
    _messagesNotifier.value = List.from(_messagesNotifier.value);
  }

  // --- ESTADO GLOBAL DE LA UI ---
  bool _isLoading = false;
  // ValueNotifier instead of a plain bool so typing never triggers a
  // full setState / rebuild of the TextField's RenderEditable subtree.
  final ValueNotifier<bool> _isTypingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isWaitingForFirstToken = ValueNotifier(false);
  final ValueNotifier<_VaultContinuationState> _vaultContinuationState =
      ValueNotifier(_VaultContinuationState.idle);
  final ValueNotifier<bool> _tickerModeNotifier = ValueNotifier(true);
  String? _selectedImagePath;

  // ─── Historial y Sesiones ──────────────────────────────────────────────────
  /// The ID of the current session in the database. Null means a new unsaved chat.
  int? _currentSessionId;

  /// Flag to know if this session was already saved or summarized recently
  bool _needsSaving = false;

  // List of sessions
  List<ChatSession> _chatHistory = [];

  /// Flag to prevent double exit
  bool _isExiting = false;

  /// One-shot guard: ensures the Hands-Free auto-greeting is sent at most
  /// once per State lifetime, even if addPostFrameCallback is somehow
  /// re-queued by a widget rebuild before the flag is consumed.
  bool _hasFiredAutoGreeting = false;

  bool _isVoiceWakeSession = false;

  /// Set to `true` by [_checkForNexusWakeOnResume] when a Nexus wake-word
  /// event is detected. Consumed by [_onPersonaCategoryChanged] **after**
  /// the model hot-swap is fully confirmed, guaranteeing the auto-greeting
  /// is dispatched only into a live, ready engine.
  bool _pendingNexusGreeting = false;

  /// Serializes persona runtime sync so notifier-driven switches and Nexus
  /// same-persona wake fallbacks cannot race model hot-swaps.
  bool _isPersonaRuntimeSyncInProgress = false;
  bool _shouldRerunPersonaRuntimeSync = false;

  // --- ESTADO DINÁMICO (PREPARACIÓN FASE 5) ---
  // Model state is now managed by LocalLlmService.currentModel

  // --- PARÁMETROS DEL LLM ---
  double _temperature = 0.45;
  double _topP = 0.90;
  int _topK = 40;
  bool _enableThinking = false;
  String? _lastPersonaCategory;

  @override
  void initState() {
    super.initState();
    _refreshHistory();
    // Register the manual-stop callback so the Safety Halo double-tap
    // can surface a SnackBar and inject AI context without a BuildContext
    // living inside the service.
    DeviceEventService.onManualStop = _handleManualVideoStop;
    WidgetsBinding.instance.addObserver(this);

    ObjectBoxService.instance.personaManager.activeCategoryNotifier.addListener(
      _onPersonaCategoryChanged,
    );

    // CRITICAL: Do NOT call setState here. Calling setState from a
    // TextEditingController listener causes the entire widget tree
    // (including the TextField itself) to rebuild mid-gesture, which
    // corrupts Flutter's pointer-tracking and manifests as the
    // "tap-to-position turns into a text-selection drag" bug.
    // Only the trailing button needs to react to this change; it does
    // so through its own ValueListenableBuilder.
    _textController.addListener(() {
      _isTypingNotifier.value = _textController.text.trim().isNotEmpty;
    });
    // NOTE: We intentionally do NOT call setState from the FocusNode listener.
    // Doing so would rebuild the entire widget tree (including the TextField)
    // mid-gesture, corrupting the tap-to-position-cursor sequence and causing
    // the text selection / double-tap misbehaviour. The border decoration
    // listens to the FocusNode directly via a ValueListenableBuilder below.

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Guard 1: widget must still be mounted.
      if (!mounted) return;

      // Guard 2: execute exactly once per State lifetime regardless of
      // how many subsequent rebuilds may re-schedule this callback.
      if (_hasFiredAutoGreeting) return;

      final authProvider = context.read<AuthProvider>();

      // Guard 3: only fire when the Nexus wake flag is genuinely set.
      if (!authProvider.isWokenByNexus) return;

      // Mark before the async call so a racing rebuild cannot slip through.
      _hasFiredAutoGreeting = true;

      // Consume the provider flag immediately so any subsequent
      // AuthenticationWrapper rebuild reads a clean state.
      authProvider.consumeWakeFlag();

      _isVoiceWakeSession = true;

      // Await the send so errors surface here rather than being silently
      // dropped by the unawaited future.
      await _sendMessage(
        autoText: "¡Hola Aitana! Necesito que hagas algo por mi.",
      );
    });
  }

  @override
  void dispose() {
    ObjectBoxService.instance.personaManager.activeCategoryNotifier
        .removeListener(_onPersonaCategoryChanged);
    WidgetsBinding.instance.removeObserver(this);
    _attachmentMenuRemovalTimer?.cancel();
    _attachmentMenuOverlayEntry?.remove();
    _attachmentMenuOverlayEntry = null;
    _messagesNotifier.dispose();
    _isTypingNotifier.dispose();
    _isWaitingForFirstToken.dispose();
    _vaultContinuationState.dispose();
    _attachmentMenuOpenNotifier.dispose();
    _tickerModeNotifier.dispose();
    _autoScrollThrottle?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    // Clear the manual-stop callback to prevent it from firing on a
    // disposed/unmounted widget after this State has been torn down.
    DeviceEventService.onManualStop = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _tickerModeNotifier.value = true;
      _checkForNexusWakeOnResume();
    } else if (state == AppLifecycleState.paused) {
      _tickerModeNotifier.value = false;
      // Re-arm the one-shot guard so the next foreground-resume cycle
      // can fire the auto-greeting again if the Nexus wake flag is set.
      _hasFiredAutoGreeting = false;
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _tickerModeNotifier.value = false;
    }
  }

  void _refreshHistory() {
    setState(() {
      _chatHistory = ObjectBoxService.instance.getAllSessionsSorted();
    });
  }

  void _onPersonaCategoryChanged() {
    unawaited(
      _syncPersonaRuntimeAndMaybeGreet(source: 'activeCategoryNotifier'),
    );
  }

  Future<void> _syncPersonaRuntimeAndMaybeGreet({
    required String source,
  }) async {
    if (_isPersonaRuntimeSyncInProgress) {
      _shouldRerunPersonaRuntimeSync = true;
      debugPrint(
        '🟡 [PersonaSync] Sync already in progress; queued rerun from $source.',
      );
      return;
    }

    _isPersonaRuntimeSyncInProgress = true;
    var currentSource = source;

    try {
      while (mounted) {
        _shouldRerunPersonaRuntimeSync = false;
        await _runPersonaRuntimeSyncOnce(source: currentSource);

        if (!_shouldRerunPersonaRuntimeSync) break;
        currentSource = 'queued-rerun';
      }
    } finally {
      _isPersonaRuntimeSyncInProgress = false;
    }
  }

  Future<void> _runPersonaRuntimeSyncOnce({required String source}) async {
    final personaManager = ObjectBoxService.instance.personaManager;
    final activePersona = personaManager.getActivePersona();
    final category = activePersona.category;

    debugPrint(
      '🎛️ [PersonaSync] source=$source category=$category '
      'pendingNexusGreeting=$_pendingNexusGreeting',
    );

    // ── Step 1: Unconditionally synchronize language and engine ──────────────
    //
    // This is the Single Actor for all engine operations. Both normal persona
    // switches and Nexus wake-word flows are handled here, in the correct order.
    try {
      await LocalLlmService.setLanguageOverride(
        activePersona.defaultLang,
        resetContext: false,
      );
      // [AWAIT] The model hot-swap is now fully confirmed when this returns.
      // No other code path may dispatch engine commands until this completes.
      await LocalLlmService.autoSwitchModelForCategory(category);
    } catch (e) {
      debugPrint('🔴 [PersonaChanged] Engine sync failed: $e');
      // If the engine swap fails, clear the greeting flag so we do not attempt
      // to send a message into a potentially broken engine state.
      _pendingNexusGreeting = false;
      return;
    }

    // ── Step 2: Conditionally purge conversation context ─────────────────────
    //
    // [AWAIT] resetSessionState is awaited to ensure resetConversation on the
    // native layer completes before Step 3 dispatches a new message. An
    // unawaited fire-and-forget call here would cause NO_MODEL_LOADED errors
    // if the Conversation object is still being closed when sendMessage arrives.
    if (_messages.isNotEmpty) {
      await LocalLlmService.resetSessionState(
        onClearUi: () {
          if (mounted) {
            _clearMessages();
            setState(() {
              _currentSessionId = null;
              _needsSaving = false;
            });
            _refreshHistory();
          }
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Context purged for persona shift.',
              style: TextStyle(fontFamily: 'Outfit', color: Colors.black87),
            ),
            backgroundColor: PersonaThemeRouter.getThemeColor(category),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    // ── Step 3: Consume pending Nexus greeting ────────────────────────────────
    //
    // This executes ONLY after the model swap (Step 1) and context purge
    // (Step 2) are both confirmed complete. The engine is guaranteed ready.
    // The guard on category == 'AI' provides a final safety check: if the
    // DB write somehow landed on a non-AI persona, we never send the greeting.
    if (_pendingNexusGreeting && category == 'AI' && mounted) {
      _pendingNexusGreeting = false;
      debugPrint('🎙️ [PersonaSync] Nexus greeting dispatched via $source.');
      debugPrint(
        '🎙️ [PersonaChanged] Nexus greeting dispatched — '
        'engine confirmed ready for AI persona.',
      );
      await _sendMessage(
        autoText: "¡Hola Aitana! Necesito que hagas algo por mi.",
      );
    }
  }

  /// Re-queries the Kotlin wake-source channel on every foreground resume.
  ///
  /// [initState] is only called once per [State] lifetime, so it cannot
  /// detect the case where the app is paused and then brought back to the
  /// foreground by the Nexus Dispatcher voice command. This method, driven
  /// by [WidgetsBindingObserver], fills that gap by directly invoking
  /// [checkWakeSource] without going through the full [AuthProvider]
  /// biometric flow again.
  /// Re-queries the Kotlin wake-source channel on every foreground resume.
  ///
  /// **Single-Actor Architecture:** This method is intentionally a pure trigger.
  /// It sets [_pendingNexusGreeting] and forces the ObjectBox persona to `AI`.
  /// ALL engine interaction (model swap, context purge, greeting dispatch) is
  /// delegated to [_onPersonaCategoryChanged], which is the single actor that
  /// owns the engine transition. This prevents the two-actor concurrency bug
  /// that caused `PlatformException(NO_MODEL_LOADED)`: previously, both this
  /// method and the reactive listener raced to issue engine commands after
  /// a single `setActivePersona()` call.
  Future<void> _checkForNexusWakeOnResume() async {
    if (!mounted) return;
    // Do not interrupt an active LLM inference or an ongoing recording session.
    if (_isLoading) return;

    try {
      const channel = MethodChannel(NativeChannels.aiCore);
      final bool isWoken =
          await channel.invokeMethod<bool>('checkWakeSource') ?? false;

      if (!isWoken || _hasFiredAutoGreeting) return;

      _hasFiredAutoGreeting = true;
      _isVoiceWakeSession = true;
      debugPrint('🎙️ [NexusWake] Wake flag consumed on resume.');

      // Signal the reactive listener to dispatch the greeting once the
      // engine swap is confirmed. This must be set BEFORE setActivePersona()
      // so the listener sees it when it fires.
      _pendingNexusGreeting = true;

      // Force the active persona to "AI". This synchronously fires
      // activeCategoryNotifier, which triggers _onPersonaCategoryChanged.
      // That listener is now the sole owner of all subsequent engine work.
      final personaManager = ObjectBoxService.instance.personaManager;
      final wasAlreadyAi = personaManager.getActivePersona().category == 'AI';
      final aiPersona = personaManager.getAllPersonas().firstWhere(
        (p) => p.category == 'AI',
      );
      debugPrint(
        '🎙️ [NexusWake] Forcing AI persona; wasAlreadyAi=$wasAlreadyAi.',
      );
      personaManager.setActivePersona(aiPersona.id);

      if (wasAlreadyAi) {
        debugPrint(
          '🎙️ [NexusWake] AI already active; using same-category fallback path.',
        );
        await _syncPersonaRuntimeAndMaybeGreet(source: 'nexus-same-ai');
      } else {
        debugPrint(
          '🎙️ [NexusWake] Persona changed to AI; notifier path will dispatch.',
        );
      }
    } catch (e) {
      // On any failure, clear the flag so a stale greeting is not dispatched
      // on the next unrelated persona switch.
      _pendingNexusGreeting = false;
      debugPrint('🔴 [NexusWake] Resume check failed: $e');
    }
  }

  /// Called by [DeviceEventService] when the user double-taps the Safety Halo
  /// to stop the recording from the native overlay.
  ///
  /// Shows the same confirmation SnackBar that voice-commanded stops use,
  /// then silently injects a note into the AI context so the model knows
  /// the camera is now free. The injection is fire-and-forget to keep the
  /// UI thread unblocked.
  void _handleManualVideoStop() {
    if (!mounted) return;

    // 1. Show the save confirmation SnackBar.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video saved in Movies/Aitana-Videos'),
        backgroundColor: Colors.green,
      ),
    );
    debugPrint(
      '🟢 [Flutter] Evento de paro manual recibido. Mostrando SnackBar...',
    );
    // 2. Inject silent AI context — fire-and-forget.
    //    The model needs to know the recording ended so it doesn't try to
    //    emit a redundant <STOP_VIDEO> tag if the user asks about the video.
    LocalLlmService.injectSilentContext(
      '[SYSTEM EVENT: The user manually stopped the video recording '
      'by double-tapping the floating camera overlay. '
      'The camera is now free. Do not attempt to stop the recording again.]',
    );
  }

  bool _isNearChatBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels <= position.minScrollExtent + 96;
  }

  void _scrollToBottom({bool force = false}) {
    _forceNextAutoScroll = _forceNextAutoScroll || force;
    if (_autoScrollThrottle?.isActive ?? false) return;

    _autoScrollThrottle = Timer(const Duration(milliseconds: 72), () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          _forceNextAutoScroll = false;
          return;
        }

        final forceScroll = _forceNextAutoScroll;
        _forceNextAutoScroll = false;
        if (!forceScroll && !_isNearChatBottom()) return;

        // With reverse: true on the ListView, the newest message lives at
        // minScrollExtent. Animating there keeps the active response in view
        // without pulling the user back if they intentionally scroll upward.
        _scrollController.animateTo(
          _scrollController.position.minScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      });
    });
  }

  // ⚙️ EL RETO: DIÁLOGO DE CONFIGURACIÓN AVANZADA
  void _showSettingsDialog() {
    SettingsDialogWidget.show(
      context,
      initialTemp: _temperature,
      initialTopP: _topP,
      initialTopK: _topK,
      initialThinking: _enableThinking,
      hasHistory: _messages.isNotEmpty,
      onApply: (temp, topP, topK, thinking, clearHistory) {
        if (mounted) {
          setState(() {
            _temperature = temp;
            _topP = topP;
            _topK = topK;
            _enableThinking = thinking;
            if (clearHistory) _clearMessages();
          });
        }
      },
    );
  }

  /// Handles the model switch operation.
  /// Displays a loading dialog while the model is switching.
  /// Clears the chat history and session ID.
  Future<void> _handleModelSwitch(AiModelInfo targetModel) async {
    Navigator.pop(context);

    // Avoid redundant switches
    if (LocalLlmService.currentModel.value.baseName == targetModel.baseName) {
      return;
    }

    // Display loading dialog
    _showLoadingDialog(
      "Switching AI Engine...\nPlease wait a few seconds while we reconfigure the CPU memory.",
    );

    // Execute the change
    final result = await LocalLlmService.switchModel(targetModel);

    // Close loading dialog using Navigator
    if (mounted) {
      Navigator.pop(context); // This closes the Dialog
    }

    if (!mounted) return;

    // Handle results
    if (result == ModelSwitchResult.success) {
      setState(() {
        _messages.clear();
        _currentSessionId = null;
        _needsSaving = false;
        _selectedImagePath = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to ${targetModel.displayName}'),
          backgroundColor: Colors.green,
        ),
      );
    } else if (result == ModelSwitchResult.busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Engine is busy. Please wait.'),
          backgroundColor: Colors.orange,
        ),
      );
    } else if (result == ModelSwitchResult.notFound) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Model file not found on device.'),
          backgroundColor: Colors.red,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error switching model. Check logs.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Shows the model selector bottom sheet.
  /// Allows the user to select a different AI model.
  ///
  /// Uses [ValueListenableBuilder] to reactively display the current model.
  /// Calls [_handleModelSwitch] when a new model is selected.
  ///
  /// The bottom sheet includes a list of all available models from [AiModelCatalog].
  /// The currently selected model is highlighted with a checkmark icon.
  /// Tapping a model closes the bottom sheet and initiates the model switch.
  void _showModelSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.deepIndigo,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        // Read persona category once for the lifetime of this bottom sheet.
        final activeCategory = ObjectBoxService.instance.personaManager
            .getActivePersona()
            .category
            .toUpperCase();
        final isRestrictedMode =
            activeCategory == 'LEGAL' || activeCategory == 'HUMAN';

        return SafeArea(
          child: ValueListenableBuilder<AiModelInfo>(
            valueListenable: LocalLlmService.currentModel,
            builder: (context, currentModel, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      "Select AI Model",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (isRestrictedMode)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            color: PersonaThemeRouter.getThemeColor(
                              activeCategory,
                            ),
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${activeCategory == 'HUMAN' ? 'Human' : 'Legal'} Mode: model locked for ${activeCategory == 'LEGAL' ? 'factual accuracy' : 'uncensored persona'}.',
                            style: TextStyle(
                              color: Colors.white.withAlpha(153),
                              fontFamily: 'Outfit',
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ...AiModelCatalog.models.map((model) {
                    final isSelected = currentModel.baseName == model.baseName;

                    bool isDisabled = false;
                    if (activeCategory == 'HUMAN' &&
                        model.baseName == 'gemma_4b') {
                      isDisabled = true;
                    } else if (activeCategory == 'LEGAL' &&
                        model.baseName == 'gemma_4b_variant') {
                      isDisabled = true;
                    }

                    return Opacity(
                      opacity: isDisabled ? 0.4 : 1.0,
                      child: ListTile(
                        leading: Icon(
                          isSelected ? Icons.psychology : Icons.psychology_alt,
                          color: isSelected
                              ? AppColors.cyberBlue
                              : Colors.white70,
                        ),
                        title: Text(
                          model.displayName,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontFamily: 'Outfit',
                          ),
                        ),
                        subtitle: isDisabled
                            ? Text(
                                'Disabled in ${activeCategory == 'HUMAN' ? 'Human' : 'Legal'} Mode.',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontFamily: 'Outfit',
                                  fontSize: 11,
                                ),
                              )
                            : null,
                        trailing: isSelected
                            ? const Icon(
                                Icons.check_circle,
                                color: AppColors.cyberBlue,
                              )
                            : null,
                        onTap: isDisabled
                            ? null
                            : () => _handleModelSwitch(model),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Shows a loading dialog with the specified message.
  /// The dialog is blocking and cannot be dismissed by tapping outside.
  ///
  /// This dialog is used during model switching to indicate that the AI is busy.
  ///
  /// [message]: The message to display in the dialog.
  void _showLoadingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false, // Cannot be dismissed by tapping outside
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.black87,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.purpleAccent),
                const SizedBox(height: 20),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleAttachmentMenu() {
    if (_attachmentMenuOpenNotifier.value) {
      _hideAttachmentMenu();
    } else {
      _showAttachmentMenu();
    }
  }

  void _showAttachmentMenu() {
    if (!mounted) return;

    _attachmentMenuRemovalTimer?.cancel();
    if (_attachmentMenuOverlayEntry == null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;

      _attachmentMenuOverlayEntry = OverlayEntry(
        builder: (context) {
          return ValueListenableBuilder<bool>(
            valueListenable: _tickerModeNotifier,
            child: _AttachmentMenuOverlay(
              layerLink: _attachmentMenuLayerLink,
              isOpenListenable: _attachmentMenuOpenNotifier,
              onDismiss: _hideAttachmentMenu,
              onSelected: _handleAttachmentMenuAction,
            ),
            builder: (context, tickerModeEnabled, child) {
              return TickerMode(enabled: tickerModeEnabled, child: child!);
            },
          );
        },
      );
      overlay.insert(_attachmentMenuOverlayEntry!);
    }

    _attachmentMenuOpenNotifier.value = true;
  }

  void _hideAttachmentMenu({bool immediately = false}) {
    _attachmentMenuRemovalTimer?.cancel();
    if (_attachmentMenuOverlayEntry == null) {
      _attachmentMenuOpenNotifier.value = false;
      return;
    }

    _attachmentMenuOpenNotifier.value = false;
    if (immediately) {
      _attachmentMenuOverlayEntry?.remove();
      _attachmentMenuOverlayEntry = null;
      return;
    }

    _attachmentMenuRemovalTimer = Timer(const Duration(milliseconds: 180), () {
      _attachmentMenuOverlayEntry?.remove();
      _attachmentMenuOverlayEntry = null;
    });
  }

  void _handleAttachmentMenuAction(_AttachmentMenuAction action) {
    switch (action) {
      case _AttachmentMenuAction.camera:
        _hideAttachmentMenu(immediately: true);
        unawaited(_pickImage(ImageSource.camera));
        break;
      case _AttachmentMenuAction.gallery:
        _hideAttachmentMenu(immediately: true);
        unawaited(_pickImage(ImageSource.gallery));
        break;
      case _AttachmentMenuAction.legalLibrary:
        debugPrint('[AttachmentMenu] Legal Library selected');
        _hideAttachmentMenu(immediately: true);
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const LegalLibraryScreen()));
        break;
      case _AttachmentMenuAction.personalVault:
        debugPrint('[AttachmentMenu] Personal Vault selected');
        _hideAttachmentMenu(immediately: true);
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const VaultManagerScreen()));
        break;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final image = await _picker.pickImage(source: source, imageQuality: 80);
      if (!mounted || image == null) return;

      setState(() {
        _selectedImagePath = image.path;
      });
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  /// Handles the audio recorded by the [VoiceInputPanel].
  Future<void> _handleAudioRecorded(String path) async {
    _addMessage(
      ChatMessage(
        text: "",
        isUser: true,
        audioPath: path,
        audioDuration: "Audio",
      ),
    );
    _addMessage(ChatMessage(text: "", isUser: false));
    setState(() {
      _isLoading = true;
      _needsSaving = true;
    });
    _scrollToBottom(force: true);
    _isWaitingForFirstToken.value = true;

    String? pendingVaultQuery;

    final response = await LocalLlmService.runInference(
      "Responde a la solicitud de Lorenzo.",
      audioPath: path,
      onTokenUpdate: _handleTokenUpdate,
      onCommandDetected: _handleDeviceCommand,
      onVaultSearchDetected: (query) {
        debugPrint(
          '🔐 [ChatVault] Audio turn requested vault search: "$query"',
        );
        if (mounted) {
          _vaultContinuationState.value = _VaultContinuationState.queued;
        }
        pendingVaultQuery = query;
        debugPrint('🔐 [ChatVault] Audio hidden continuation armed.');
      },
    );

    await _finalizeResponse(response);

    final vaultQuery = pendingVaultQuery;
    if (vaultQuery != null && mounted) {
      await _runHiddenVaultContinuation(
        originalUserPrompt: 'Responde a la solicitud de Lorenzo.',
        vaultQuery: vaultQuery,
      );
    }
  }

  Future<void> _runHiddenVaultContinuation({
    required String originalUserPrompt,
    required String vaultQuery,
  }) async {
    if (!mounted) return;

    debugPrint(
      '[ChatVault] Starting hidden vault continuation for "$vaultQuery".',
    );
    _vaultContinuationState.value = _VaultContinuationState.retrieving;
    _addMessage(ChatMessage(text: "", isUser: false));
    setState(() {
      _isLoading = true;
      _needsSaving = true;
    });
    _scrollToBottom(force: true);

    try {
      final continuation = await LocalLlmService.runHiddenVaultContinuation(
        originalUserPrompt: originalUserPrompt,
        vaultQuery: vaultQuery,
        onTokenUpdate: _handleTokenUpdate,
      );

      if (!mounted) return;
      await _finalizeResponse(continuation);
    } finally {
      if (mounted) {
        _vaultContinuationState.value = _VaultContinuationState.idle;
      }
    }
  }

  /// Sends a message to the AI.
  ///
  /// [autoText]: Optional pre-filled text (used for voice transcription).
  ///
  /// If [autoText] is provided, it's used directly and the text controller
  /// is not cleared.
  /// If [autoText] is null, the current text from the controller is used,
  /// and the controller is cleared after sending.
  ///
  /// The method adds the user message to the chat, then adds a loading message
  /// for the AI's response.
  /// It then calls [runInference] to get the AI's response and finally
  /// calls [_finalizeResponse] to process and display the response.
  ///
  /// Throws [Exception] if inference fails.
  /// Logs errors to the debug console.
  Future<void> _sendMessage({String? autoText}) async {
    final text = autoText ?? _textController.text.trim();
    final imagePath = _selectedImagePath;

    if ((text.isEmpty && imagePath == null) || _isLoading) return;

    // ─── Phase 3: Personal Vault Interceptor ──────────────────────────────
    final isVaultCommand = RegExp(
      r'^analiza\b',
      caseSensitive: false,
    ).hasMatch(text);
    final activePersona = ObjectBoxService.instance.personaManager
        .getActivePersona();

    // debugPrint('--- VAULT INTERCEPTOR DEBUG ---');
    // debugPrint(
    //   '1. Regex Match (^analiza): ${RegExp(r'^analiza\b', caseSensitive: false).hasMatch(text)}',
    // );
    // debugPrint('2. Has Image: ${imagePath != null}');
    // debugPrint('3. Active Persona Name: ${activePersona.name}');
    // debugPrint('-------------------------------');

    if (isVaultCommand && imagePath != null && activePersona.name == 'Aitana') {
      // 1. Add user message to UI
      _addMessage(ChatMessage(text: text, isUser: true, imagePath: imagePath));

      // 2. Clear input state immediately
      if (autoText == null) {
        _textController.clear();
        _selectedImagePath = null;
        _focusNode.unfocus();
      }

      // 3. Add temporary system feedback
      _addMessage(
        ChatMessage(
          text: "Iniciando análisis multimodal para la bóveda...",
          isUser: false,
        ),
      );

      setState(() {
        _isLoading = true;
      });
      _scrollToBottom(force: true);

      // 4. Execute the Vault Ingestion pipeline (Deduplication -> Sandbox -> Vision -> Save)
      final result = await VaultIngestionService().ingestImage(imagePath);

      // 5. Finalize UI state with status
      if (mounted) {
        setState(() {
          _isLoading = false;
          final isSpanish =
              LocalLlmService.currentLanguageNotifier.value == 'ES';
          String statusMsg;
          if (result == IngestionStatus.success) {
            statusMsg = isSpanish
                ? "✅ Análisis completado y guardado en la Bóveda"
                : "✅ Analysis completed and saved in the Vault";
          } else if (result == IngestionStatus.duplicate) {
            statusMsg = isSpanish
                ? "ℹ️ Esta imagen ya está en tu Bóveda Personal"
                : "ℹ️ This image is already in your Personal Vault";
          } else {
            statusMsg = isSpanish
                ? "❌ Error: No se pudo completar el análisis de la imagen"
                : "❌ Error: Could not complete image analysis";
          }
          _messages.last.text = statusMsg;
          _notifyMessagesChanged();
        });
      }
      return; // Exit early to bypass standard inference
    }
    // ──────────────────────────────────────────────────────────────────────

    if (autoText == null) {
      _textController.clear();
      _selectedImagePath = null;
      _focusNode.unfocus();
    }

    _addMessage(ChatMessage(text: text, isUser: true, imagePath: imagePath));
    _addMessage(ChatMessage(text: "", isUser: false));
    setState(() {
      _isLoading = true;
      _needsSaving = true; // 👈 ¡NUESTRA BANDERA DE GUARDADO!
    });

    _scrollToBottom(force: true);

    // ── Persona-Aware Inference Parameters ────────────────────────────────
    if (activePersona.category != _lastPersonaCategory) {
      final LlmInferenceParams params;
      if (activePersona.category == 'LEGAL') {
        params = const LlmInferenceParams(
          temperature: 0.2,
          topK: 20,
          topP: 0.8,
          repetitionPenalty: 1.3, // Higher penalty for formulaic legal text
          enableThinking: false,
        );
      } else {
        params = const LlmInferenceParams(
          temperature: 0.45,
          topK: 40,
          topP: 0.9,
          repetitionPenalty: 1.2,
          enableThinking: false,
        );
      }
      await LocalLlmService.updateSamplerParams(params);
      _lastPersonaCategory = activePersona.category;
    }
    // ──────────────────────────────────────────────────────────────────────

    String? pendingVaultQuery;
    _isWaitingForFirstToken.value = true;

    final response = await LocalLlmService.runInference(
      text.isEmpty ? "Describe esto" : text,
      imagePath: imagePath,
      onTokenUpdate: _handleTokenUpdate,
      onCommandDetected: _handleDeviceCommand,
      onVaultSearchDetected: (query) {
        debugPrint('🔐 [ChatVault] Text turn requested vault search: "$query"');
        if (mounted) {
          _vaultContinuationState.value = _VaultContinuationState.queued;
        }
        pendingVaultQuery = query;
        debugPrint('🔐 [ChatVault] Text hidden continuation armed.');
      },
    );

    await _finalizeResponse(response);

    final vaultQuery = pendingVaultQuery;
    if (vaultQuery != null && mounted) {
      await _runHiddenVaultContinuation(
        originalUserPrompt: text.isEmpty ? 'Describe esto' : text,
        vaultQuery: vaultQuery,
      );
    }
  }

  /// Handles token updates during inference.
  ///
  /// This callback is invoked by [LocalLlmService.runInference] for each
  /// token received from the AI model.
  ///
  /// It updates the last chat message with the accumulated text and ensures
  /// the UI is scrolled to the bottom.
  ///
  /// [accumulatedText]: The text accumulated so far from the AI response.
  ///
  /// This method is called for both streaming and non-streaming inference.
  ///
  /// Throws [Exception] if the widget is no longer mounted.
  /// Logs errors to the debug console.
  void _handleTokenUpdate(String accumulatedText) {
    if (!mounted) return;
    if (_isWaitingForFirstToken.value) {
      _isWaitingForFirstToken.value = false;
    }
    _messages.last.text = accumulatedText;
    _notifyMessagesChanged();
    _scrollToBottom();
  }

  /// Handles device commands detected mid-stream by [LocalLlmService].
  /// All tag stripping has already occurred in the service layer, so
  /// this method only manages native channel invocations and UI feedback.
  Future<void> _handleDeviceCommand(String command) async {
    const channel = MethodChannel(NativeChannels.aiCore);
    if (command == 'START_VIDEO') {
      try {
        await channel.invokeMethod('startVideoRecording');
        // State is now driven by DeviceEventService.isVideoRecording
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Recording... video floating preview active'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        debugPrint('🔴 [VideoCmd] startVideoRecording failed: $e');
      }
    } else if (command == 'STOP_VIDEO') {
      try {
        await channel.invokeMethod('stopVideoRecording');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Video saved to Gallery/Aitana-Videos'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        debugPrint('🔴 [VideoCmd] stopVideoRecording failed: $e');
      }
    }
  }

  /// Saves the current chat session if needed.
  ///
  /// Checks if the session needs saving based on the [_needsSaving] flag.
  /// If needed, generates a summary using [LocalLlmService.generateGhostSummary],
  /// parses the title and summary from the response, and saves the session
  /// to the database using [ObjectBoxService.saveChatSession].
  ///
  /// This method is called automatically when the session needs to be saved.
  ///
  /// Logs errors to the debug console.
  Future<void> _saveCurrentSessionIfNeeded({bool isFastSave = false}) async {
    if (_messages.isEmpty) return;
    if (!_needsSaving) return;

    String generatedTitle = "New Chat";
    String finalSummary = "Sin resumen.";

    // BYPASS DEL LLM: Si estamos saliendo, no perdemos 40 segundos generando resumen
    if (isFastSave) {
      final now = DateTime.now();
      generatedTitle = "Chat on ${now.day}/${now.month}";
      finalSummary = "Conversation saved automatically when exiting.";
    } else {
      // Flujo normal (Lento): Mandamos a la IA a hacer el resumen
      final rawConversation = _messages
          .map((m) {
            final role = m.isUser ? "Lorenzo" : "Aitana";
            final content = m.text.trim().isNotEmpty
                ? m.text
                : "[Voice/Image Message]";
            return "$role: $content";
          })
          .join('\n');

      final rawResponse = await LocalLlmService.generateGhostSummary(
        rawConversation,
      );
      if (rawResponse.isEmpty) return;

      if (rawResponse.toUpperCase().contains('TITLE:')) {
        final parts = rawResponse.split('\n');
        final titleLine = parts.firstWhere(
          (line) => line.toUpperCase().startsWith('TITLE:'),
          orElse: () => '',
        );

        if (titleLine.isNotEmpty) {
          generatedTitle = titleLine.substring(7).trim();
          finalSummary = parts
              .where((line) => line != titleLine)
              .join('\n')
              .trim();
        }
      } else {
        finalSummary = rawResponse;
      }
    }

    // BUG FIX: Is it an old or new chat?
    String sessionTitle;
    if (_currentSessionId != null) {
      final existingSession = ObjectBoxService.instance.getSession(
        _currentSessionId!,
      );
      sessionTitle = existingSession?.title ?? generatedTitle;
    } else {
      sessionTitle = generatedTitle;
    }

    // Save to the vault
    final session = ChatSession(
      id: _currentSessionId ?? 0,
      title: sessionTitle,
      summary: finalSummary,
    );

    _currentSessionId = ObjectBoxService.instance.saveSession(session);
    _needsSaving = false;
    debugPrint(
      "💾 Sesión guardada con ID: $_currentSessionId | Título: $sessionTitle",
    );
  }

  // ─── Load Session from History ──────────────────────────────────────────
  /// Loads a chat session from history.
  ///
  /// [session]: The chat session to load.
  ///
  /// This method closes the side menu, saves the current session if needed,
  /// clears the current context, injects the new session's memory, and then
  /// displays the "Oracle Bubble" with the session's summary.
  ///
  /// Throws [Exception] if context clearing fails.
  /// Logs errors to the debug console.
  Future<void> _loadSession(ChatSession session) async {
    // Close the side menu
    Navigator.pop(context);

    // Save the current session in background if we were in the middle of a conversation
    await _saveCurrentSessionIfNeeded();

    // Reset Kotlin memory to avoid mixing topics
    await LocalLlmService.clearContext();

    // Inject new memory
    _currentSessionId = session.id;
    _needsSaving = false;
    LocalLlmService.activeSessionSummary = session.summary;

    // Display the "Oracle Bubble" on the screen
    if (mounted) {
      _clearMessages();
      _addMessage(
        ChatMessage(
          text: "Memoria del sistema:\n${session.summary}",
          isUser: false,
          isSystemOracle: true,
        ),
      );
    }
    debugPrint("🕰️ Viaje en el tiempo exitoso. Sesión ${session.id} cargada.");
  }

  /// Toggles the [isPinned] flag of [session] without mutating its [updatedAt]
  /// timestamp, then re-sorts the history list so pinned items stay at the top.
  /// The Drawer deliberately stays open so the user can see the updated order.
  void _togglePin(ChatSession session) {
    final fresh = ObjectBoxService.instance.getSession(session.id);
    if (fresh == null) return;
    fresh.isPinned = !fresh.isPinned;
    ObjectBoxService.instance.updateSession(fresh);
    _refreshHistory();
  }

  /// Prompts the user to rename [session] via [_RenameSessionDialog].
  ///
  /// The dialog owns its [TextEditingController] lifecycle so there is no
  /// risk of a "controller used after dispose" crash during the closing
  /// animation. This method acts purely as a coordinator: it opens the
  /// dialog, receives the validated title string, and writes to ObjectBox.
  Future<void> _renameSession(ChatSession session) async {
    final newTitle = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RenameSessionDialog(initialTitle: session.title),
    );

    // null  → user cancelled; empty string guard is handled inside the widget.
    if (newTitle == null || newTitle == session.title) return;

    final fresh = ObjectBoxService.instance.getSession(session.id);
    if (fresh == null) return;

    fresh.title = newTitle;
    ObjectBoxService.instance.updateSession(fresh);
    _refreshHistory();
  }

  /// Shows a dark-themed confirmation dialog, then permanently deletes
  /// [session] from ObjectBox.
  ///
  /// **Edge case:** if the deleted session is the currently active one,
  /// the chat screen is cleared and the LLM context is reset so the UI
  /// never shows stale messages tied to a non-existent session.
  Future<void> _deleteSession(ChatSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.glassBorder, width: 1),
          ),
          title: const Text(
            'Delete conversation?',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Outfit',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'This action cannot be undone.',
            style: TextStyle(
              color: Colors.white70,
              fontFamily: 'Outfit',
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54, fontFamily: 'Outfit'),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Delete',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Outfit',
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    ObjectBoxService.instance.deleteSession(session.id);

    // If the deleted session was currently open, wipe the chat screen and
    // reset the LLM context so the UI is not left in an inconsistent state.
    if (session.id == _currentSessionId) {
      await LocalLlmService.clearContext();
      LocalLlmService.activeSessionSummary = '';
      if (mounted) {
        _clearMessages();
        setState(() {
          _currentSessionId = null;
          _needsSaving = false;
        });
      }
    }

    _refreshHistory();
  }

  Future<void> _finalizeResponse(String finalResponse) async {
    if (mounted) {
      // Seguro de vida: Limpieza final por si el stream dejó basura
      String cleanText = finalResponse
          .replaceAll('<START_VIDEO>', '')
          .replaceAll('<STOP_VIDEO>', '')
          .trim();

      if (_isWaitingForFirstToken.value) {
        _isWaitingForFirstToken.value = false;
      }
      setState(() {
        _isLoading = false;
      });
      if (cleanText.isNotEmpty) {
        _messages.last.text = cleanText;
        _notifyMessagesChanged();
      } else {
        final updatedMessages = List<ChatMessage>.from(_messages);
        if (updatedMessages.isNotEmpty &&
            !updatedMessages.last.isUser &&
            updatedMessages.last.text.trim().isEmpty &&
            updatedMessages.last.audioPath == null &&
            updatedMessages.last.imagePath == null) {
          updatedMessages.removeLast();
          _messagesNotifier.value = updatedMessages;
        } else {
          _notifyMessagesChanged();
        }
      }
      _scrollToBottom();

      if (_isVoiceWakeSession) {
        _voiceKey.currentState?.startManualRecording();
        _isVoiceWakeSession =
            false; // CRITICAL: Reset the flag so it only triggers on the first turn of the wake session.
      }
    }
  }

  // ── EXIT sequence (shared by drawer and popup) ────────────────────────────
  /// Handles the exit sequence, saving the current session if needed.
  /// Launches the 4D hypersphere shader overlay while cleanup runs in parallel.
  /// The [onSequenceComplete] callback awaits [_runCleanup] before terminating
  /// so the app never quits before all cleanup work is guaranteed to finish.
  Future<void> _handleExit() async {
    if (_isExiting) return;
    _isExiting = true;

    if (!mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();

    // Recording stop is now handled by the VoiceInputPanel's own lifecycle
    // or through shared state if we implement a controller.

    // 1. Iniciamos el cleanup (que asumo incluye tu guardado LENTO y seguro)
    // OJO: Quitamos el unawaited y guardamos la promesa en una variable.
    final cleanupFuture = _runCleanup();

    if (!mounted) return;

    // 2. Lanzamos tu secuencia de la hiperesfera
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Navigator.of(context, rootNavigator: true).pushReplacement(
        PageRouteBuilder(
          opaque: true,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => ExitSequenceWidget(
            // Le pasamos la tarea pendiente a la secuencia visual.
            // Así, la hiperesfera puede quedarse girando y mostrando mensajes
            // hasta que cleanupFuture se resuelva completamente.
            processToWait: cleanupFuture,
            onSequenceComplete: () {
              exit(0); // Ahora sí, muerte limpia y segura.
            },
          ),
        ),
      );
    });
  }

  /// Runs all heavy cleanup tasks: persists the current session first, then
  /// tears down services. Safe to run concurrently with the shader animation.
  Future<void> _runCleanup() async {
    // Save session before anything else so data is never lost.
    await _saveCurrentSessionIfNeeded();
    // Remaining teardowns can proceed sequentially.
    LocalLlmService.clearToolListener();
    await LocalLlmService.dispose();

    // [Fix #8] Drain one microtask between disposeModel and closeStore.
    // LocalLlmService.dispose() cancels the Dart-side StreamSubscription, but
    // the native Kotlin EventChannel coroutine may still push a final event
    // (e.g. a [DONE] token that triggers a manage_calendar ObjectBox write)
    // before the native sink closes. One microtask gives the platform thread
    // one scheduling cycle to flush that event before LMDB is closed,
    // preventing a potential silent calendar-write data-loss race.
    await Future.microtask(() {});

    ObjectBoxService.closeStore();
    NetworkService.dispose();
  }

  Widget _buildChatHeader(double topPadding) {
    return RepaintBoundary(
      child: SizedBox(
        height: topPadding + _chatHeaderBodyHeight,
        child: ValueListenableBuilder<String>(
          valueListenable:
              ObjectBoxService.instance.personaManager.activeCategoryNotifier,
          builder: (context, category, child) {
            return ChatHeaderWidget(
              personaColor: PersonaThemeRouter.getThemeColor(category),
              onMenuPressed: () => _scaffoldKey.currentState?.openDrawer(),
              onModelSelectorPressed: _showModelSelector,
              onClearMemoryPressed: () async {
                await LocalLlmService.resetSessionState(
                  onClearUi: () {
                    if (mounted) {
                      _clearMessages();
                      setState(() {
                        _currentSessionId = null;
                        _needsSaving = false;
                      });
                      _refreshHistory();
                    }
                  },
                );
              },
              onExitPressed: () {
                if (mounted) {
                  _handleExit();
                }
              },
              onLongPressPill: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  builder: (_) => const DevToolsBottomSheet(),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessageBody() {
    return Expanded(
      child: RepaintBoundary(
        child: ValueListenableBuilder<String>(
          valueListenable:
              ObjectBoxService.instance.personaManager.activeCategoryNotifier,
          builder: (context, category, child) {
            return _ChatMessageViewport(
              messagesListenable: _messagesNotifier,
              scrollController: _scrollController,
              userBubbleColor: _userBubbleColor,
              vaultStateListenable: _vaultContinuationState,
              firstTokenWaitListenable: _isWaitingForFirstToken,
              accentColor: PersonaThemeRouter.getThemeColor(category),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStickyInputFooter(double bottomPadding) {
    return RepaintBoundary(
      child: Container(
        decoration: const BoxDecoration(
          color: _kChatObsidian,
          border: Border(top: BorderSide(color: Color(0x12FFFFFF), width: 1)),
        ),
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: _inputFooterMinHeight,
            maxHeight: _inputFooterMaxHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_selectedImagePath != null)
                  _SelectedImagePreview(
                    imagePath: _selectedImagePath!,
                    onRemove: () => setState(() => _selectedImagePath = null),
                  ),
                CompositedTransformTarget(
                  link: _attachmentMenuLayerLink,
                  child: VoiceInputPanel(
                    key: _voiceKey,
                    textController: _textController,
                    focusNode: _focusNode,
                    isLoading: _isLoading,
                    selectedImagePath: _selectedImagePath,
                    isTypingNotifier: _isTypingNotifier,
                    attachmentMenuOpenListenable: _attachmentMenuOpenNotifier,
                    onAttachmentPressed: _toggleAttachmentMenu,
                    onSendText: _sendMessage,
                    onAudioRecorded: _handleAudioRecorded,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return Stack(
      children: [
        Scaffold(
          key: _scaffoldKey,
          backgroundColor: _kChatObsidian,
          resizeToAvoidBottomInset: true,
          // ── LEFT DRAWER ─────────────────────────────────────────────────────
          drawer: Drawer(
            backgroundColor: const Color(0xFF1E1F20),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── ZONE 1: Fixed Header & Primary Action (Top) ─────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: AppColors.cyberBlue.withAlpha(30),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.cyberBlue.withAlpha(80),
                                  width: 1.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.memory_rounded,
                                color: AppColors.cyberBlue,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Lady Ai.tana',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'Outfit',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  'Neural Core Engine',
                                  style: TextStyle(
                                    color: AppColors.textMedium,
                                    fontFamily: 'Outfit',
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(context); // Cierra el Drawer
                            await _saveCurrentSessionIfNeeded(); // Guarda si había algo a medias
                            await LocalLlmService.resetSessionState(
                              onClearUi: () {
                                if (mounted) {
                                  _clearMessages();
                                  setState(() {
                                    _currentSessionId = null;
                                    _needsSaving = false;
                                  });
                                  _refreshHistory();
                                }
                              },
                            );
                          },
                          icon: const Icon(
                            Icons.edit_square,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'New Chat',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.cyberBlue.withAlpha(150),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(color: AppColors.glassBorder, height: 1),
                  ),

                  // ── ZONE 2: Scrollable History (Middle) ───────────────────────
                  const Padding(
                    padding: EdgeInsets.only(left: 20, top: 16, bottom: 8),
                    child: Text(
                      'CHAT HISTORY',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _chatHistory.isEmpty
                        ? const Center(
                            child: Text(
                              'No conversation started yet.',
                              style: TextStyle(
                                color: Colors.white30,
                                fontSize: 14,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: _chatHistory.length,
                            itemBuilder: (context, index) {
                              final session = _chatHistory[index];
                              // Formateamos la fecha (ej. 2026-04-23)
                              final dateStr =
                                  "${session.updatedAt.year}-${session.updatedAt.month.toString().padLeft(2, '0')}-${session.updatedAt.day.toString().padLeft(2, '0')}";

                              return ListTile(
                                leading: const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  color: AppColors.cyberBlue,
                                  size: 20,
                                ),
                                // Title row: optional pin indicator + truncated
                                // session name. The pin icon is intentionally
                                // small (13 px) to feel like inline metadata
                                // rather than a primary action affordance.
                                title: Row(
                                  children: [
                                    if (session.isPinned)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 5),
                                        child: Icon(
                                          Icons.push_pin,
                                          size: 13,
                                          color: AppColors.cyberBlue,
                                        ),
                                      ),
                                    Expanded(
                                      child: Text(
                                        session.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontFamily: 'Outfit',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  dateStr,
                                  style: const TextStyle(
                                    color: Colors.white30,
                                    fontSize: 12,
                                  ),
                                ),
                                // Three-dot menu — tap the tile body to load,
                                // tap the trailing icon to manage the session.
                                trailing: PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.more_vert,
                                    color: Colors.white38,
                                    size: 20,
                                  ),
                                  color: const Color(0xFF2A2B2C),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: const BorderSide(
                                      color: AppColors.glassBorder,
                                      width: 0.5,
                                    ),
                                  ),
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'pin':
                                        _togglePin(session);
                                      case 'rename':
                                        _renameSession(session);
                                      case 'delete':
                                        _deleteSession(session);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem<String>(
                                      value: 'pin',
                                      child: Row(
                                        children: [
                                          Icon(
                                            session.isPinned
                                                ? Icons.push_pin_outlined
                                                : Icons.push_pin,
                                            size: 18,
                                            color: Colors.white70,
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            session.isPinned ? 'Unpin' : 'Pin',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontFamily: 'Outfit',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'rename',
                                      child: Row(
                                        children: const [
                                          Icon(
                                            Icons.drive_file_rename_outline,
                                            size: 18,
                                            color: Colors.white70,
                                          ),
                                          SizedBox(width: 10),
                                          Text(
                                            'Rename',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontFamily: 'Outfit',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'delete',
                                      child: Row(
                                        children: const [
                                          Icon(
                                            Icons.delete_outline,
                                            size: 18,
                                            color: Colors.redAccent,
                                          ),
                                          SizedBox(width: 10),
                                          Text(
                                            'Delete',
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                              fontFamily: 'Outfit',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                onTap: () => _loadSession(session),
                              );
                            },
                          ),
                  ),

                  // ── ZONE 3: Settings (Collapsible) ───────────────
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(color: AppColors.glassBorder, height: 1),
                  ),
                  Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.cyberBlue.withAlpha(30),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.cyberBlue.withAlpha(80),
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.settings,
                          color: AppColors.cyberBlue,
                          size: 20,
                        ),
                      ),
                      title: const Text(
                        'Settings',
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'Outfit',
                          fontSize: 18,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      iconColor: AppColors.cyberBlue,
                      collapsedIconColor: Colors.white54,
                      textColor: Colors.white,
                      collapsedTextColor: Colors.white54,
                      children: [
                        ListTile(
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.cyberBlue.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.tune_rounded,
                              color: AppColors.cyberBlue,
                              size: 20,
                            ),
                          ),
                          title: const Text(
                            'Parameters',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Temperature, Top-K, Top-P',
                            style: TextStyle(
                              color: AppColors.textMedium,
                              fontFamily: 'Outfit',
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context); // Close drawer
                            _showSettingsDialog();
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.only(
                            left: 40,
                            right: 20,
                            top: 4,
                            bottom: 4,
                          ),
                        ),
                        ListTile(
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.cyberBlue.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.language_rounded,
                              color: AppColors.cyberBlue,
                              size: 20,
                            ),
                          ),
                          title: const Text(
                            'Language Override',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          trailing: ValueListenableBuilder<String>(
                            valueListenable:
                                LocalLlmService.currentLanguageNotifier,
                            builder: (context, currentLang, _) {
                              return CupertinoSlidingSegmentedControl<String>(
                                groupValue: currentLang,
                                backgroundColor: const Color(0xFF1E1F20),
                                thumbColor: AppColors.cyberBlue.withAlpha(40),
                                children: const {
                                  'ES': Text(
                                    ' ES ',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'Outfit',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  'EN': Text(
                                    ' EN ',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'Outfit',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                },
                                onValueChanged: (String? newValue) async {
                                  if (newValue != null &&
                                      newValue != currentLang) {
                                    await LocalLlmService.setLanguageOverride(
                                      newValue,
                                    );
                                  }
                                },
                              );
                            },
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.only(
                            left: 40,
                            right: 20,
                            top: 4,
                            bottom: 4,
                          ),
                        ),
                        ListTile(
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.cyberBlue.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.psychology_rounded,
                              color: AppColors.cyberBlue,
                              size: 20,
                            ),
                          ),
                          title: const Text(
                            'Identity Settings',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'Configure AI personalities and prompts',
                            style: TextStyle(
                              color: AppColors.textMedium,
                              fontFamily: 'Outfit',
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context); // Close drawer
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const PersonaVaultScreen(),
                              ),
                            );
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.only(
                            left: 40,
                            right: 20,
                            top: 4,
                            bottom: 4,
                          ),
                        ),
                      ],
                    ),
                  ),

                  //const Spacer(),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Center(
                      child: Text(
                        'v1.0.0 · Gemma-4-E4B-it',
                        style: TextStyle(
                          color: Colors.white24,
                          fontFamily: 'Outfit',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          body: ValueListenableBuilder<bool>(
            valueListenable: _tickerModeNotifier,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header is painted in the root Stack foreground. This spacer
                // preserves the same top layout budget for the lazy chat body.
                SizedBox(
                  height: mediaQuery.padding.top + _chatHeaderBodyHeight,
                ),
                _buildMessageBody(),
                _buildStickyInputFooter(mediaQuery.viewPadding.bottom),
              ],
            ),
            builder: (context, tickerModeEnabled, child) {
              return TickerMode(enabled: tickerModeEnabled, child: child!);
            },
          ),
        ),
        // 🛡️ THE ARMOR (OOM BLOCKER)
        ValueListenableBuilder<bool>(
          valueListenable: LocalLlmService.isEngineBusy,
          builder: (context, isEngineBusy, child) {
            return ValueListenableBuilder<bool>(
              valueListenable: LocalLlmService.isGeneratingNotifier,
              builder: (context, isGenerating, _) {
                if (!isEngineBusy && !isGenerating) {
                  return const SizedBox.shrink();
                }
                return ValueListenableBuilder<String>(
                  valueListenable: ObjectBoxService
                      .instance
                      .personaManager
                      .activeCategoryNotifier,
                  builder: (context, category, child) {
                    return SystemLockOverlay(
                      title: isEngineBusy
                          ? "Neural Core Engine Busy"
                          : "Neural Core Active",
                      subtitle: isEngineBusy
                          ? "Reconfiguring memory for high-performance inference..."
                          : "Local inference stream is running...",
                      baseColor: PersonaThemeRouter.getThemeColor(category),
                    );
                  },
                );
              },
            );
          },
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: _tickerModeNotifier,
            child: Material(
              type: MaterialType.transparency,
              child: _buildChatHeader(mediaQuery.padding.top),
            ),
            builder: (context, tickerModeEnabled, child) {
              return TickerMode(enabled: tickerModeEnabled, child: child!);
            },
          ),
        ),
      ],
    );
  }
}

class _ChatMessageViewport extends StatelessWidget {
  static const double _messageCacheExtent = 720.0;

  final ValueListenable<List<ChatMessage>> messagesListenable;
  final ScrollController scrollController;
  final Color userBubbleColor;
  final ValueListenable<_VaultContinuationState> vaultStateListenable;
  final ValueListenable<bool> firstTokenWaitListenable;
  final Color accentColor;

  const _ChatMessageViewport({
    required this.messagesListenable,
    required this.scrollController,
    required this.userBubbleColor,
    required this.vaultStateListenable,
    required this.firstTokenWaitListenable,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: _ChatAtmosphere()),
        Positioned.fill(
          child: ValueListenableBuilder<List<ChatMessage>>(
            valueListenable: messagesListenable,
            child: const _EmptyChatPlaceholder(),
            builder: (context, messagesList, emptyState) {
              return Stack(
                children: [
                  if (messagesList.isEmpty) emptyState!,
                  ListView.builder(
                    controller: scrollController,
                    reverse: true,
                    cacheExtent: _messageCacheExtent,
                    addAutomaticKeepAlives: true,
                    addRepaintBoundaries: true,
                    addSemanticIndexes: false,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                    itemCount: messagesList.length,
                    itemBuilder: (context, index) {
                      final msg = messagesList[messagesList.length - 1 - index];
                      if (msg.text.isEmpty &&
                          !msg.isUser &&
                          msg.audioPath == null) {
                        return const SizedBox.shrink();
                      }
                      return ChatBubbleWidget(
                        key: ObjectKey(msg),
                        message: msg,
                        userBubbleColor: userBubbleColor,
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
        Positioned(
          left: 16,
          bottom: 12,
          child: _InferenceFooterStatus(
            vaultStateListenable: vaultStateListenable,
            firstTokenWaitListenable: firstTokenWaitListenable,
            accentColor: accentColor,
          ),
        ),
      ],
    );
  }
}

class _ChatAtmosphere extends StatelessWidget {
  const _ChatAtmosphere();

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: CustomPaint(
        painter: _ChatAtmospherePainter(),
        child: SizedBox.expand(),
      ),
    );
  }
}

class _ChatAtmospherePainter extends CustomPainter {
  const _ChatAtmospherePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = _kChatObsidian);

    _drawRadial(
      canvas,
      size,
      center: const Alignment(-1.1, -0.85),
      radius: size.longestSide * 0.72,
      colors: const [Color(0x2E00ADB5), Color(0x0000ADB5)],
    );
    _drawRadial(
      canvas,
      size,
      center: const Alignment(1.15, 0.85),
      radius: size.longestSide * 0.68,
      colors: const [Color(0x247B2CBF), Color(0x007B2CBF)],
    );
    _drawRadial(
      canvas,
      size,
      center: const Alignment(0.1, -0.2),
      radius: size.shortestSide * 0.55,
      colors: const [Color(0x1000E5FF), Color(0x0000E5FF)],
    );

    final verticalMask = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x770B0D17), Color(0x000B0D17), Color(0x660B0D17)],
        stops: [0.0, 0.44, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, verticalMask);

    final sideMask = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0x660B0D17),
          Color(0x000B0D17),
          Color(0x000B0D17),
          Color(0x660B0D17),
        ],
        stops: [0.0, 0.22, 0.78, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, sideMask);

    final scanLinePaint = Paint()
      ..color = const Color(0x0500ADB5)
      ..strokeWidth = 1;
    for (double y = 18; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), scanLinePaint);
    }
  }

  void _drawRadial(
    Canvas canvas,
    Size size, {
    required Alignment center,
    required double radius,
    required List<Color> colors,
  }) {
    final focalPoint = center.alongSize(size);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: colors,
      ).createShader(Rect.fromCircle(center: focalPoint, radius: radius));
    canvas.drawCircle(focalPoint, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _ChatAtmospherePainter oldDelegate) => false;
}

class _InferenceFooterStatus extends StatelessWidget {
  final ValueListenable<_VaultContinuationState> vaultStateListenable;
  final ValueListenable<bool> firstTokenWaitListenable;
  final Color accentColor;

  const _InferenceFooterStatus({
    required this.vaultStateListenable,
    required this.firstTokenWaitListenable,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: UnconstrainedBox(
          alignment: Alignment.centerLeft,
          child: ValueListenableBuilder<_VaultContinuationState>(
            valueListenable: vaultStateListenable,
            builder: (context, vaultState, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: LocalLlmService.isGeneratingNotifier,
                builder: (context, isGenerating, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: firstTokenWaitListenable,
                    builder: (context, isWaitingForFirstToken, _) {
                      final Widget child;
                      if (vaultState != _VaultContinuationState.idle) {
                        child = _FooterThinkingPill(
                          key: const ValueKey('vault-dots'),
                          accentColor: accentColor,
                        );
                      } else if (isGenerating && isWaitingForFirstToken) {
                        child = _FooterThinkingPill(
                          key: const ValueKey('decode-dots'),
                          accentColor: accentColor,
                        );
                      } else {
                        child = const SizedBox.shrink(
                          key: ValueKey('idle-status'),
                        );
                      }

                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: child,
                          ),
                        ],
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EmptyChatPlaceholder extends StatelessWidget {
  const _EmptyChatPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(FontAwesomeIcons.robot, size: 48, color: Color(0x4C00ADB5)),
          SizedBox(height: 16),
          Text(
            'System Idle. Awaiting input.',
            style: TextStyle(
              color: Color(0xB8DDE8F0),
              fontFamily: 'Outfit',
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterThinkingPill extends StatelessWidget {
  final Color accentColor;

  const _FooterThinkingPill({super.key, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _kChatObsidian,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
          ),
          border: Border.fromBorderSide(
            BorderSide(color: accentColor.withAlpha(128), width: 1), // 0x80
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withAlpha(64), // 0x40
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: SpinKitThreeBounce(color: accentColor, size: 18),
      ),
    );
  }
}

class _AttachmentMenuOverlay extends StatelessWidget {
  static const double _panelGap = 12.0;

  final LayerLink layerLink;
  final ValueListenable<bool> isOpenListenable;
  final VoidCallback onDismiss;
  final ValueChanged<_AttachmentMenuAction> onSelected;

  const _AttachmentMenuOverlay({
    required this.layerLink,
    required this.isOpenListenable,
    required this.onDismiss,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: TextFieldTapRegion(
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onDismiss,
              child: const SizedBox.expand(),
            ),
            CompositedTransformFollower(
              link: layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -_panelGap),
              child: Material(
                type: MaterialType.transparency,
                child: ValueListenableBuilder<bool>(
                  valueListenable: isOpenListenable,
                  child: _AttachmentGlassMenu(onSelected: onSelected),
                  builder: (context, isOpen, child) {
                    return IgnorePointer(
                      ignoring: !isOpen,
                      child: AnimatedOpacity(
                        opacity: isOpen ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        child: AnimatedScale(
                          scale: isOpen ? 1 : 0.94,
                          alignment: Alignment.bottomCenter,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: child,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentGlassMenu extends StatelessWidget {
  final ValueChanged<_AttachmentMenuAction> onSelected;

  const _AttachmentGlassMenu({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final panelWidth = (MediaQuery.sizeOf(context).width - 32)
        .clamp(304.0, 364.0)
        .toDouble();

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(30)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: panelWidth,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xD10B0D17),
              borderRadius: const BorderRadius.all(Radius.circular(30)),
              border: Border.all(color: const Color(0x5200F0FF), width: 1),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x3D00F0FF),
                  blurRadius: 30,
                  spreadRadius: -8,
                  offset: Offset(0, 14),
                ),
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 28,
                  offset: Offset(0, 18),
                ),
              ],
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xE6111724), Color(0xD10B0D17)],
              ),
            ),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildTile(
                  icon: Icons.camera_alt_rounded,
                  title: 'Camera',
                  subtitle: 'Capture vision',
                  action: _AttachmentMenuAction.camera,
                ),
                _buildTile(
                  icon: Icons.photo_library_rounded,
                  title: 'Gallery',
                  subtitle: 'Image upload',
                  action: _AttachmentMenuAction.gallery,
                ),
                _buildTile(
                  icon: Icons.local_library_rounded,
                  title: 'Legal Library',
                  subtitle: 'RAG & PDF Chunking',
                  action: _AttachmentMenuAction.legalLibrary,
                ),
                _buildTile(
                  icon: Icons.inventory_2_rounded,
                  title: 'Personal Vault',
                  subtitle: 'HNSW Vector Search',
                  action: _AttachmentMenuAction.personalVault,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required _AttachmentMenuAction action,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onSelected(action),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        splashColor: const Color(0x3300F0FF),
        highlightColor: const Color(0x1F00F0FF),
        child: Ink(
          decoration: BoxDecoration(
            color: const Color(0x5C101827),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: const Color(0x26FFFFFF), width: 1),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2600F0FF),
                blurRadius: 18,
                spreadRadius: -10,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0x2400F0FF),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    border: Border.all(
                      color: const Color(0x4D00F0FF),
                      width: 1,
                    ),
                  ),
                  child: Icon(icon, color: const Color(0xFF00F0FF), size: 21),
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontFamily: 'Outfit',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontFamily: 'Outfit',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedImagePreview extends StatelessWidget {
  final String imagePath;
  final VoidCallback onRemove;

  const _SelectedImagePreview({
    required this.imagePath,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, left: 4.0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cyberBlue, width: 2),
              image: DecorationImage(
                image: FileImage(File(imagePath)),
                fit: BoxFit.cover,
              ),
            ),
          ),
          Positioned(
            top: -8,
            right: -8,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple dialog for renaming a chat session.
class _RenameSessionDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameSessionDialog({required this.initialTitle});

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1F20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.glassBorder, width: 1),
      ),
      title: const Text(
        'Rename chat',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'Outfit',
          fontWeight: FontWeight.bold,
        ),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontFamily: 'Outfit'),
        decoration: InputDecoration(
          hintText: 'Enter new title...',
          hintStyle: const TextStyle(color: Colors.white30),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.cyberBlue.withAlpha(100)),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.cyberBlue),
          ),
        ),
        onSubmitted: (val) {
          if (val.trim().isNotEmpty) Navigator.pop(context, val.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white54, fontFamily: 'Outfit'),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.cyberBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isNotEmpty) Navigator.pop(context, text);
          },
          child: const Text(
            'Save',
            style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
          ),
        ),
      ],
    );
  }
}
