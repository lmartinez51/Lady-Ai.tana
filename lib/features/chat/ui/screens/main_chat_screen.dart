import 'dart:io';
import 'dart:async';
import 'package:aitana/core/domain/entities/chat_session.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/services/llm/models/llm_inference_params.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/core/services/network/network_service.dart';
import 'package:aitana/core/services/device/device_event_service.dart';
import 'package:aitana/features/chat/ui/widgets/audio_bubble.dart';
import 'package:aitana/features/auth/providers/auth_provider.dart';
import 'package:aitana/features/chat/ui/widgets/exit_sequence_widget.dart';
import 'package:aitana/features/geofencing/ui/widgets/dev_geofence_modal.dart';
import 'package:aitana/core/theme/widgets/system_lock_overlay.dart';

class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();

  final List<ChatMessage> _messages = [];

  // --- ESTADO GLOBAL DE LA UI ---
  bool _isLoading = false;
  // ValueNotifier instead of a plain bool so typing never triggers a
  // full setState / rebuild of the TextField's RenderEditable subtree.
  final ValueNotifier<bool> _isTypingNotifier = ValueNotifier(false);
  bool _isRecording = false;
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

  // --- VAD (Silence Detection) PARAMS ---
  /// Amplitude floor that must be exceeded to initially classify audio as
  /// speech. Set aggressively to reject car noise, AC units, and breathing.
  final double _vadThreshold = -20.0;

  /// Lower hysteresis bound used as the gate for resetting the trailing
  /// silence timer after speech has been detected. A micro-spike of ambient
  /// noise that stays below this level will NOT defer the submission countdown,
  /// preventing the indefinite-hang symptom observed in vehicular environments.
  final double _vadSpeechHysteresisDb = -28.0;

  final int _vadSilenceDurationMs = 2500;
  final int _vadInitialTimeoutMs = 7000;

  bool _isVoiceWakeSession = false;
  bool _hasSpoken = false;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _silenceTimer;

  /// Absolute hard-stop timer. Regardless of noise or VAD state, cancels and
  /// discards the recording after [_hardStopDurationS] seconds of total mic
  /// time, preventing the microphone from ever hanging indefinitely.
  Timer? _hardStopTimer;
  static const int _hardStopDurationS = 20;

  // --- ESTADO DINÁMICO (PREPARACIÓN FASE 5) ---
  // Model state is now managed by LocalLlmService.currentModel

  // --- PARÁMETROS DEL LLM ---
  double _temperature = 0.45;
  double _topP = 0.90;
  int _topK = 40;
  bool _enableThinking = false;

  @override
  void initState() {
    super.initState();
    _refreshHistory();
    // Register the manual-stop callback so the Safety Halo double-tap
    // can surface a SnackBar and inject AI context without a BuildContext
    // living inside the service.
    DeviceEventService.onManualStop = _handleManualVideoStop;
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _hardStopTimer?.cancel();
    _silenceTimer?.cancel();
    _amplitudeSubscription?.cancel();
    // [Fix #4] _handleExit() eagerly disposes the AudioRecorder before pushing
    // the shader overlay to prevent the Android HAL teardown race. If the exit
    // sequence ran, _isExiting == true and the recorder is already disposed —
    // calling dispose() a second time would throw on the record package.
    if (!_isExiting) _audioRecorder.dispose();
    _isTypingNotifier.dispose();
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
      _checkForNexusWakeOnResume();
    } else if (state == AppLifecycleState.paused) {
      // Re-arm the one-shot guard so the next foreground-resume cycle
      // can fire the auto-greeting again if the Nexus wake flag is set.
      _hasFiredAutoGreeting = false;
    }
  }

  void _refreshHistory() {
    setState(() {
      _chatHistory = ObjectBoxService.instance.getAllSessionsSorted();
    });
  }

  /// Re-queries the Kotlin wake-source channel on every foreground resume.
  ///
  /// [initState] is only called once per [State] lifetime, so it cannot
  /// detect the case where the app is paused and then brought back to the
  /// foreground by the Nexus Dispatcher voice command. This method, driven
  /// by [WidgetsBindingObserver], fills that gap by directly invoking
  /// [checkWakeSource] without going through the full [AuthProvider]
  /// biometric flow again.
  Future<void> _checkForNexusWakeOnResume() async {
    if (!mounted) return;
    // Do not interrupt an active LLM inference or an ongoing recording session.
    if (_isLoading || _isRecording) return;

    try {
      const channel = MethodChannel('com.lmartinez.aitana/aicore');
      final bool isWoken =
          await channel.invokeMethod<bool>('checkWakeSource') ?? false;

      if (!isWoken || _hasFiredAutoGreeting) return;

      _hasFiredAutoGreeting = true;
      _isVoiceWakeSession = true;
      await _sendMessage(
        autoText: "¡Hola Aitana! Necesito que hagas algo por mi.",
      );
    } catch (e) {
      debugPrint('🔴 Nexus wake-on-resume check failed: $e');
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
        content: Text('Video guardado en Movies/Aitana-Videos'),
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // With reverse: true on the ListView, the newest message lives at
        // scroll position 0.0 (minScrollExtent), not maxScrollExtent.
        // Animating to 0.0 brings the latest bubble into view.
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ⚙️ EL RETO: DIÁLOGO DE CONFIGURACIÓN AVANZADA
  void _showSettingsDialog() {
    // Variables temporales para no afectar el estado real hasta presionar OK
    double tempTemp = _temperature;
    double tempTopP = _topP;
    int tempTopK = _topK;
    bool tempThinking = _enableThinking;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          // Aisla el refresco solo a esta ventana
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.obsidian,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: AppColors.glassBorder, width: 1),
              ),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Model Parameters",
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Outfit',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showParameterInfo(
                      context,
                      '🔥 Roast Protocol (Spicy Mode)',
                      'Need to blow off some steam and start a digital bar fight? Dial in these settings for maximum emotional damage:\n\n• Temperature: 0.85 (Liquid courage)\n• Top K: 80 (Unlocks the forbidden dictionary)\n• Enable Thinking: ON (So she logically plots your demise)\n\nDisclaimer: Do not use these settings if you actually need to schedule something... or if you have a fragile ego.',
                      actionLabel: 'ENGAGE SPICY MODE',
                      onAction: () {
                        setDialogState(() {
                          tempTemp = 0.85;
                          tempTopK = 80;
                          tempThinking = true;
                        });
                      },
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.local_fire_department,
                        color: Colors.deepOrangeAccent,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // INFORMATIVO: ACCELERATOR
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.deepIndigo.withAlpha(127),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.memory,
                            color: Colors.white54,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Accelerator: ",
                            style: TextStyle(
                              color: Colors.white54,
                              fontFamily: 'Outfit',
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.cyberBlue.withAlpha(40),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: AppColors.cyberBlue.withAlpha(100),
                                width: 0.5,
                              ),
                            ),
                            child: const Text(
                              "√ CPU",
                              style: TextStyle(
                                color: AppColors.cyberBlue,
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ENABLE THINKING
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          const Text(
                            "Enable thinking",
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => _showParameterInfo(
                              context,
                              "Enable Thinking",
                              'Forces the AI to reason internally before replying. Slower response, but much smarter logic.',
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Icon(
                                Icons.info_outline,
                                size: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Switch(
                            activeTrackColor: AppColors.cyberBlue,
                            value: tempThinking,
                            onChanged: (val) =>
                                setDialogState(() => tempThinking = val),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppColors.glassBorder),

                    // SLIDERS DINÁMICOS
                    _ParameterSlider(
                      label: "Temperature",
                      tooltipMessage:
                          'Controls randomness. Low (0.2): Strict & focused (Best for tools/tasks). High (0.8): Creative & chaotic (Best for roasting).',
                      min: 0.0,
                      max: 2.0,
                      value: tempTemp,
                      isDouble: true,
                      onChanged: (val) => setDialogState(() => tempTemp = val),
                    ),
                    _ParameterSlider(
                      label: "Top K",
                      tooltipMessage:
                          'Vocabulary pool size. Low: Uses common, safe words. High: Expands word choices, more dynamic.',
                      min: 1,
                      max: 100,
                      value: tempTopK.toDouble(),
                      isDouble: false,
                      onChanged: (val) =>
                          setDialogState(() => tempTopK = val.toInt()),
                    ),
                    _ParameterSlider(
                      label: "Top P",
                      tooltipMessage:
                          'Probability threshold. Low: Predictable phrasing. High: Diverse and expressive sentence structures.',
                      min: 0.0,
                      max: 1.0,
                      value: tempTopP,
                      isDouble: true,
                      onChanged: (val) => setDialogState(() => tempTopP = val),
                    ),
                  ],
                ),
              ),
              // ── ACTIONS ROW ─────────────────────────────────────────────
              // Uses a single Row widget so we can push "Reset" to the far
              // left while keeping "Cancel" and "OK" on the right.
              actionsAlignment: MainAxisAlignment.spaceBetween,
              actions: [
                // ── LEFT: Reset to defaults ──────────────────────────────
                TextButton.icon(
                  onPressed: () {
                    // Reset ONLY the temp dialog state – does NOT close the
                    // dialog or touch the native engine. The user must still
                    // press OK to apply (which triggers the confirm dialog).
                    setDialogState(() {
                      tempTemp = const LlmInferenceParams().temperature;
                      tempTopK = const LlmInferenceParams().topK;
                      tempTopP = const LlmInferenceParams().topP;
                      tempThinking = const LlmInferenceParams().enableThinking;
                    });
                  },
                  icon: const Icon(
                    Icons.restart_alt_rounded,
                    size: 18,
                    color: Colors.redAccent,
                  ),
                  label: const Text(
                    'Reset',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),

                // ── RIGHT: Cancel + OK ───────────────────────────────────
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: Colors.white54,
                          fontFamily: 'Outfit',
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.cyberBlue,
                        foregroundColor: AppColors.obsidian,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      // ⚙️ Async: closes settings, optionally confirms memory
                      // loss, then applies params and resets native session.
                      onPressed: () async {
                        // Close the settings dialog first to avoid a nested
                        // modal stack (confusing back-gesture behaviour).
                        Navigator.pop(context);

                        // Only warn if there is history that would be erased.
                        final bool hasHistory = _messages.isNotEmpty;

                        if (hasHistory) {
                          final bool? confirmed = await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (BuildContext ctx) {
                              return AlertDialog(
                                backgroundColor: AppColors.obsidian,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: const BorderSide(
                                    color: AppColors.glassBorder,
                                    width: 1,
                                  ),
                                ),
                                title: const Row(
                                  children: [
                                    Icon(
                                      Icons.warning_amber_rounded,
                                      color: Colors.orangeAccent,
                                      size: 22,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Clear Memory?',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'Outfit',
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                content: const Text(
                                  'Applying new parameters will clear the '
                                  'current conversation memory. Proceed?',
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
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontFamily: 'Outfit',
                                      ),
                                    ),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.orangeAccent,
                                      foregroundColor: AppColors.obsidian,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text(
                                      'Proceed',
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

                          // User cancelled – abort without changing anything.
                          if (confirmed != true) return;
                        }

                        // Apply params: update the service (fires native
                        // resetConversation) then sync the UI state.
                        await LocalLlmService.updateSamplerParams(
                          LlmInferenceParams(
                            temperature: tempTemp,
                            topK: tempTopK,
                            topP: tempTopP,
                            enableThinking: tempThinking,
                          ),
                        );

                        // Keep visible message list in sync with the reset
                        // native session to avoid misleading context display.
                        if (mounted) {
                          setState(() {
                            _temperature = tempTemp;
                            _topP = tempTopP;
                            _topK = tempTopK;
                            _enableThinking = tempThinking;
                            if (hasHistory) _messages.clear();
                          });
                        }
                      },
                      child: const Text(
                        'OK',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Outfit',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
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
                  ...AiModelCatalog.models.map((model) {
                    final isSelected = currentModel.baseName == model.baseName;
                    return ListTile(
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
                      trailing: isSelected
                          ? const Icon(
                              Icons.check_circle,
                              color: AppColors.cyberBlue,
                            )
                          : null,
                      onTap: () => _handleModelSwitch(model),
                    );
                  }),
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

  /// Shows the attachment options bottom sheet.
  /// Allows the user to select camera or gallery as the source for an image.
  ///
  /// The bottom sheet includes two options:
  /// - Camera: Launches the camera to take a photo
  /// - Gallery: Opens the image gallery to select an existing photo
  ///
  /// This method is called when the user taps the attachment button in the chat input.
  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.deepIndigo,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(
                  Icons.camera_alt,
                  color: AppColors.cyberBlue,
                ),
                title: const Text(
                  'Camera',
                  style: TextStyle(color: Colors.white, fontFamily: 'Outfit'),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.photo_library,
                  color: AppColors.cyberBlue,
                ),
                title: const Text(
                  'Gallery',
                  style: TextStyle(color: Colors.white, fontFamily: 'Outfit'),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Picks an image from the gallery or camera.
  ///
  /// [source]: The source to pick the image from (gallery or camera).
  ///
  /// Uses [ImagePicker] to select an image with 80% quality.
  /// Updates the [_selectedImagePath] state when an image is successfully selected.
  ///
  /// This method is called by [_showAttachmentOptions] when the user selects
  /// either "Camera" or "Gallery".
  ///
  /// Throws [Exception] if image picking fails.
  /// Logs the error to the debug console.
  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (image != null) {
        setState(() {
          _selectedImagePath = image.path;
        });
      }
    } catch (e) {
      debugPrint("Error picking image: $e");
    }
  }

  /// Toggles the recording state.
  ///
  /// If currently recording, stops the recording.
  /// If not recording, starts the recording.
  ///
  /// This method is called when the user taps the microphone button.
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  /// Starts the audio recording.
  ///
  /// Checks for microphone permission before starting.
  /// Updates the recording state and plays a startup beep sound.
  ///
  /// If permission is denied, shows an error message.
  /// Logs errors to the debug console.
  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      // Update UI first for immediate user feedback
      setState(() {
        _isRecording = true;
        _hasSpoken = false;
      });

      // Haptic feedback
      // vibrate() drives the haptic actuator at maximum strength — perceptible
      // even through a car mount, and volume-independent by design.
      HapticFeedback.vibrate();

      // Audio feedback
      // Short audible beep routed through the SYSTEM sonification stream.
      final beepPlayer = AudioPlayer();
      await beepPlayer.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.none,
            isSpeakerphoneOn: false,
          ),
        ),
      );
      await beepPlayer.play(AssetSource('sounds/beep.wav'));
      // beepPlayer is short-lived; audioplayers disposes it after playback.

      // Critical step: "Grace Delay" (Anti-Acoustic Feedback Loop)
      // Wait half a second for the sound to exit the speaker and the room
      // to return to silence before "opening the ears" to the app.
      await Future.delayed(const Duration(milliseconds: 500));

      // ONLY AFTER the delay, start the real recording and VAD
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/aitana_audio_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: filePath,
      );

      // Absolute safety cap: discard and stop regardless of noise levels.
      // Prevents the mic from staying open indefinitely in any edge case.
      // _hardStopDurationS se asume definido como constante en tu clase (ej. 20)
      _hardStopTimer = Timer(const Duration(seconds: _hardStopDurationS), () {
        debugPrint('⏱️ VAD hard-stop triggered after 20s.');
        if (_isRecording && mounted) _stopRecording(cancelAndDiscard: true);
      });

      _amplitudeSubscription = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((Amplitude amplitude) {
            if (amplitude.current > _vadThreshold) {
              // ── Active speech (above -20 dB) ──────────────────────────────
              // Clears any pending timer and marks speech as detected.
              _silenceTimer?.cancel();
              _silenceTimer = null;
              _hasSpoken = true;
            } else {
              // ── Below speech gate (quieter than -20 dB) ───────────────────
              if (_hasSpoken) {
                // Post-speech silence window.
                // HYSTERESIS: only restart the trailing timer if the sample also
                // clears the lower _vadSpeechHysteresisDb gate (-28 dB).
                if (amplitude.current > _vadSpeechHysteresisDb) {
                  // Genuine transient sound (between -28 and -20 dB) — restart.
                  _silenceTimer?.cancel();
                  _silenceTimer = Timer(
                    Duration(milliseconds: _vadSilenceDurationMs),
                    () {
                      if (_isRecording && mounted) _stopRecording();
                    },
                  );
                } else {
                  // Pure ambient noise (below -28 dB) — do NOT restart the timer.
                  _silenceTimer ??= Timer(
                    Duration(milliseconds: _vadSilenceDurationMs),
                    () {
                      if (_isRecording && mounted) _stopRecording();
                    },
                  );
                }
              } else {
                // Pre-speech silence: arm the initial no-speech timeout exactly
                // once. The above-threshold branch cancels it if speech arrives.
                _silenceTimer ??= Timer(
                  Duration(milliseconds: _vadInitialTimeoutMs),
                  () {
                    if (_isRecording && mounted) {
                      _stopRecording(cancelAndDiscard: true);
                    }
                  },
                );
              }
            }
          });
    } else {
      debugPrint('🔴 Microphone permission denied.');
    }
  }

  /// Stops the audio recording.
  ///
  /// Cancels any pending timers and the amplitude subscription.
  /// Saves the recording if it's valid (not cancelled), otherwise discards it.
  ///
  /// [cancelAndDiscard]: If true, the recording is discarded immediately.
  ///
  /// This method is called automatically when speech is detected or when
  /// the hard stop timer expires.
  ///
  /// Logs errors to the debug console.
  Future<void> _stopRecording({bool cancelAndDiscard = false}) async {
    _hardStopTimer?.cancel();
    _hardStopTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    final String? path = await _audioRecorder.stop();
    if (path != null) {
      if (cancelAndDiscard) {
        // Delete the orphaned temp WAV to prevent accumulation of
        // discarded recordings in the device's temporary storage.
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('⚠️ Could not delete discarded temp audio: $e');
        }
        if (mounted) setState(() => _isRecording = false);
      } else {
        setState(() {
          _isRecording = false;
          _messages.add(
            ChatMessage(
              text: "",
              isUser: true,
              audioPath: path,
              audioDuration: "Audio",
            ),
          );
          _messages.add(ChatMessage(text: "", isUser: false));
          _isLoading = true;
        });
        _scrollToBottom();

        final response = await LocalLlmService.runInference(
          "Responde a la solicitud de Lorenzo.",
          audioPath: path,
          onTokenUpdate: _handleTokenUpdate,
          onCommandDetected: _handleDeviceCommand,
        );

        _finalizeResponse(response);
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

    if (autoText == null) {
      _textController.clear();
      _selectedImagePath = null;
      _focusNode.unfocus();
    }

    setState(() {
      _messages.add(
        ChatMessage(text: text, isUser: true, imagePath: imagePath),
      );
      _messages.add(ChatMessage(text: "", isUser: false));
      _isLoading = true;
      _needsSaving = true; // 👈 ¡NUESTRA BANDERA DE GUARDADO!
    });

    _scrollToBottom();

    final response = await LocalLlmService.runInference(
      text.isEmpty ? "Describe esto" : text,
      imagePath: imagePath,
      onTokenUpdate: _handleTokenUpdate,
      onCommandDetected: _handleDeviceCommand,
    );

    _finalizeResponse(response);
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
    if (mounted) {
      setState(() {
        // Solo apagamos la animación si ya hay texto real para mostrar
        if (accumulatedText.trim().isNotEmpty) {
          _isLoading = false;
        }
        _messages.last.text = accumulatedText;
      });
      _scrollToBottom();
    }
  }

  /// Handles device commands detected mid-stream by [LocalLlmService].
  /// All tag stripping has already occurred in the service layer, so
  /// this method only manages native channel invocations and UI feedback.
  Future<void> _handleDeviceCommand(String command) async {
    const channel = MethodChannel('com.lmartinez.aitana/aicore');
    if (command == 'START_VIDEO') {
      try {
        await channel.invokeMethod('startVideoRecording');
        // State is now driven by DeviceEventService.isVideoRecording
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Grabando video — preview flotante activo'),
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
              content: Text('Video guardado en Movies/Aitana-Videos'),
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
      generatedTitle = "Charla del ${now.day}/${now.month}";
      finalSummary = "Conversación guardada automáticamente al salir.";
    } else {
      // Flujo normal (Lento): Mandamos a la IA a hacer el resumen
      final rawConversation = _messages
          .map((m) {
            final role = m.isUser ? "Lorenzo" : "Aitana";
            final content = m.text.trim().isNotEmpty
                ? m.text
                : "[Mensaje de Voz/Imagen]";
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
      setState(() {
        _messages.clear();
        _messages.add(
          ChatMessage(
            text: "Memoria del sistema:\n${session.summary}",
            isUser: false,
            isSystemOracle: true,
          ),
        );
      });
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
        setState(() {
          _messages.clear();
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

      setState(() {
        _isLoading = false;
        // Solo actualizamos si quedó texto real después de limpiar
        if (cleanText.isNotEmpty) {
          _messages.last.text = cleanText;
        } else {
          // Si el modelo SOLO escupió el tag (sin decir "órale ya grabo"),
          // le ponemos un mensaje por defecto o lo dejamos vacío.
          _messages.last.text = "Acción ejecutada.";
        }
      });
      _scrollToBottom();

      if (_isVoiceWakeSession) {
        _isVoiceWakeSession = false;
        _startRecording();
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

    // Detén audio primero para evitar carreras con el hardware.
    if (_isRecording) {
      _hardStopTimer?.cancel();
      _silenceTimer?.cancel();
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _audioRecorder.stop();

      if (mounted) {
        setState(() => _isRecording = false);
      }
    }

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

  @override
  Widget build(BuildContext context) {
    final userBubbleColor = AppColors.cyberBlue.withAlpha(50);

    return Stack(
      children: [
        Scaffold(
          key: _scaffoldKey,
          backgroundColor: AppColors.obsidian,
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
                            await LocalLlmService.clearContext(); // Limpia el LLM
                            if (mounted) {
                              setState(() {
                                _messages.clear(); // Limpia la pantalla
                                _currentSessionId = null; // ID a 0
                                _needsSaving = false;
                              });
                            }
                            LocalLlmService.activeSessionSummary = '';
                            _refreshHistory(); // Refresca la lista
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
                              color: Colors.purpleAccent.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.language_rounded,
                              color: Colors.purpleAccent,
                              size: 20,
                            ),
                          ),
                          title: const Text(
                            'Context Mode',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            LocalLlmService.isEnglishDemoMode
                                ? 'English Demo (Sarcastic)'
                                : 'Spanish Default (Mexican)',
                            style: const TextStyle(
                              color: AppColors.textMedium,
                              fontFamily: 'Outfit',
                              fontSize: 12,
                            ),
                          ),
                          onTap: () async {
                            LocalLlmService.isEnglishDemoMode =
                                !LocalLlmService.isEnglishDemoMode;
                            Navigator.pop(context);
                            await LocalLlmService.clearContext();
                            LocalLlmService.activeSessionSummary = '';
                            if (mounted) {
                              setState(() {
                                _messages.clear();
                                _currentSessionId = null;
                                _needsSaving = false;
                              });
                            }
                            _refreshHistory();
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
          body: Column(
            children: [
              // ── FLOATING PILL HEADER (M3 Search Bar layout) ──────────────────
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: DeviceEventService.isVideoRecording,
                    builder: (context, isRecordingVideo, _) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // ── FAR LEFT: Hamburger (outside pill) ─────────────────
                          IconButton(
                            icon: const Icon(
                              Icons.menu_rounded,
                              color: AppColors.textMedium,
                            ),
                            onPressed: () =>
                                _scaffoldKey.currentState?.openDrawer(),
                            tooltip: 'Menu',
                          ),
                          const SizedBox(width: 4),

                          // ── MIDDLE: Animated Pill ───────────────────────────────
                          Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeInOut,
                              height: 46,
                              decoration: BoxDecoration(
                                color: AppColors.deepIndigo,
                                borderRadius: BorderRadius.circular(50),
                                border: Border.all(
                                  color: isRecordingVideo
                                      ? Colors.redAccent.withAlpha(120)
                                      : AppColors.glassBorder,
                                  width: isRecordingVideo ? 1.5 : 1.0,
                                ),
                                boxShadow: isRecordingVideo
                                    ? [
                                        BoxShadow(
                                          color: Colors.redAccent.withAlpha(80),
                                          blurRadius: 18,
                                          spreadRadius: 2,
                                        ),
                                        BoxShadow(
                                          color: Colors.redAccent.withAlpha(40),
                                          blurRadius: 40,
                                          spreadRadius: 4,
                                        ),
                                      ]
                                    : [
                                        BoxShadow(
                                          color: Colors.black.withAlpha(60),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                              ),
                              // Pill contents: centered title + status LEDs only
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(50),
                                  onTap: _showModelSelector,
                                  onLongPress: () {
                                    showModalBottomSheet(
                                      context: context,
                                      backgroundColor: Colors.transparent,
                                      isScrollControlled: true,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(24),
                                        ),
                                      ),
                                      builder: (_) => const DevGeofenceModal(),
                                    );
                                  },
                                  child: ValueListenableBuilder<String>(
                                    valueListenable: LocalLlmService.status,
                                    builder: (context, status, _) {
                                      Color modelColor = Colors.white;
                                      if (status == 'loading') {
                                        modelColor = Colors.orangeAccent;
                                      } else if (status == 'error') {
                                        modelColor = Colors.redAccent;
                                      } else if (status == 'ready') {
                                        modelColor = Colors.white;
                                      } else if (status == 'idle') {
                                        modelColor = Colors.white;
                                      }
                                      return Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            child:
                                                ValueListenableBuilder<
                                                  AiModelInfo
                                                >(
                                                  valueListenable:
                                                      LocalLlmService
                                                          .currentModel,
                                                  builder:
                                                      (
                                                        context,
                                                        currentModel,
                                                        _,
                                                      ) {
                                                        return Text(
                                                          'Lady Ai.tana (${currentModel.shortName})',
                                                          style: TextStyle(
                                                            color: modelColor,
                                                            fontFamily:
                                                                'Outfit',
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            fontSize: 14,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        );
                                                      },
                                                ),
                                          ),
                                          const SizedBox(width: 8),
                                          // 📶 Wi-Fi status icon
                                          ValueListenableBuilder<bool>(
                                            valueListenable:
                                                NetworkService.isOnline,
                                            builder: (context, isOnline, _) {
                                              return Tooltip(
                                                message: isOnline
                                                    ? 'Online'
                                                    : 'Offline',
                                                child: Icon(
                                                  Icons.wifi,
                                                  size: 16,
                                                  color: isOnline
                                                      ? const Color(0xFF00E676)
                                                      : Colors.grey[600],
                                                ),
                                              );
                                            },
                                          ),
                                          // 🔴 Video recording icon (only when active)
                                          if (isRecordingVideo) ...[
                                            const SizedBox(width: 6),
                                            Tooltip(
                                              message: 'Grabando video',
                                              child: Icon(
                                                Icons.fiber_manual_record,
                                                size: 14,
                                                color: Colors.redAccent
                                                    .withAlpha(220),
                                              ),
                                            ),
                                          ],
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // ── FAR RIGHT: Royal Avatar (outside pill) ─────────────
                          PopupMenuButton<String>(
                            tooltip: 'More options',
                            color: AppColors.deepIndigo,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: const BorderSide(
                                color: AppColors.glassBorder,
                                width: 1,
                              ),
                            ),
                            offset: const Offset(0, 52),
                            onSelected: (value) {
                              if (value == 'clear_memory') {
                                LocalLlmService.clearContext();
                                if (mounted) {
                                  setState(() {
                                    _messages.clear();
                                    _currentSessionId = null;
                                    _needsSaving = false;
                                  });
                                }
                                LocalLlmService.activeSessionSummary = '';
                                _refreshHistory();
                              } else if (value == 'switch_model') {
                                _showModelSelector();
                              } else if (value == 'exit') {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted) {
                                    _handleExit();
                                  }
                                });
                              }
                            },
                            itemBuilder: (BuildContext ctx) =>
                                <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'switch_model',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.swap_horiz_rounded,
                                          color: AppColors.cyberBlue,
                                          size: 20,
                                        ),
                                        SizedBox(width: 12),
                                        Text(
                                          'Switch Model',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontFamily: 'Outfit',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem<String>(
                                    value: 'clear_memory',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.cleaning_services_rounded,
                                          color: Colors.redAccent,
                                          size: 20,
                                        ),
                                        SizedBox(width: 12),
                                        Text(
                                          'Clear Memory',
                                          style: TextStyle(
                                            color: Colors.redAccent,
                                            fontFamily: 'Outfit',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuDivider(height: 1),
                                  const PopupMenuItem<String>(
                                    value: 'exit',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.power_settings_new_rounded,
                                          color: Colors.redAccent,
                                          size: 20,
                                        ),
                                        SizedBox(width: 12),
                                        Text(
                                          'Exit',
                                          style: TextStyle(
                                            color: Colors.redAccent,
                                            fontFamily: 'Outfit',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                            // Royal gold border wrapping the avatar
                            child: Container(
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.fromBorderSide(
                                  BorderSide(
                                    color: Color(0xFFEA4335),
                                    width: 2.5,
                                  ),
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 19,
                                backgroundColor: AppColors.cyberBlue.withAlpha(
                                  40,
                                ),
                                backgroundImage: const AssetImage(
                                  'assets/images/aitana_avatar.webp',
                                ),
                                onBackgroundImageError:
                                    (exception, stackTrace) {},
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              // 🗣️ ÁREA DE CHAT
              // ── Holy Grail Layout Pattern ───────────────────────────────────
              // reverse: true  → newest message is at the bottom visually and
              //                  at scroll position 0, so the native layout
              //                  engine pushes content up when the keyboard
              //                  rises — zero manual listeners required.
              // shrinkWrap: true → the list is only as tall as its children,
              //                    which lets Align pin it to the top of the
              //                    Expanded area when there are few messages.
              // Align(topCenter) → when shrinkWrap makes the list short, this
              //                    anchors it to the top instead of floating.
              // Index mapping   → reversed list means index 0 is the LAST
              //                    message. We un-reverse via .reversed.toList()
              //                    so the build order matches visual order.
              Expanded(
                child: Stack(
                  children: [
                    // ── Empty-state placeholder ─────────────────────────────
                    if (_messages.isEmpty)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FaIcon(
                              FontAwesomeIcons.robot,
                              size: 48,
                              color: AppColors.cyberBlue.withAlpha(76),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              "System Idle. Awaiting input.",
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),

                    // ── Message list ────────────────────────────────────────
                    Align(
                      alignment: Alignment.topCenter,
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          // Invert the index so that the most recent message
                          // (last in the list) maps to index 0 of the reversed
                          // render order, keeping chronological top-to-bottom
                          // visual order while anchoring physics at the bottom.
                          final reversedMessages = _messages.reversed.toList();
                          final msg = reversedMessages[index];
                          if (msg.text.isEmpty &&
                              !msg.isUser &&
                              msg.audioPath == null) {
                            return const SizedBox.shrink();
                          }
                          return _buildChatBubble(msg, userBubbleColor);
                        },
                      ),
                    ),

                    // 🌀 ANIMACIÓN DE PENSANDO (SpinKit)
                    if (_isLoading &&
                        _messages.isNotEmpty &&
                        _messages.last.text.isEmpty)
                      Positioned(
                        bottom: 16,
                        left: 44,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.deepIndigo,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(25),
                                blurRadius: 3,
                                offset: const Offset(0, 2),
                              ),
                            ],
                            border: Border.all(
                              color: AppColors.glassBorder,
                              width: 0.5,
                            ),
                          ),
                          child: SpinKitThreeBounce(
                            color: AppColors.cyberBlue.withAlpha(127),
                            size: 14.0,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ⌨️ DYNAMIC INPUT PANEL (Gemini Edition)
              Container(
                color: AppColors.obsidian,
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  bottom: MediaQuery.of(context).padding.bottom + 12,
                  top: 6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Image preview chip ──────────────────────────────────
                    if (_selectedImagePath != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0, left: 4.0),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppColors.cyberBlue,
                                  width: 2,
                                ),
                                image: DecorationImage(
                                  image: FileImage(File(_selectedImagePath!)),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              top: -8,
                              right: -8,
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _selectedImagePath = null),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // ── Floating pill input row ─────────────────────────────
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.deepIndigo,
                        borderRadius: BorderRadius.circular(36),
                        border: Border.all(
                          color: AppColors.glassBorder,
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(70),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // ── Left actions: visible only when NOT recording ──
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: _isRecording
                                ? const SizedBox(
                                    width: 12,
                                    key: ValueKey('pad'),
                                  )
                                : Padding(
                                    key: const ValueKey('actions'),
                                    padding: const EdgeInsets.only(
                                      left: 6.0,
                                      top: 6.0,
                                      bottom: 6.0,
                                    ),
                                    child: Container(
                                      height: 44,
                                      width: 44,
                                      decoration: BoxDecoration(
                                        // Le damos el mismo fondo circular que al micrófono
                                        color: AppColors.cyberBlue.withAlpha(
                                          40,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.attach_file_rounded,
                                          color: AppColors.cyberBlue,
                                          size: 22,
                                        ),
                                        onPressed: _isLoading
                                            ? null
                                            : _showAttachmentOptions,
                                        tooltip: 'Attach',
                                      ),
                                    ),
                                  ),
                          ),

                          // ── Center: TextField OR Waveform ──────────────────
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: _isRecording
                                  ? const Padding(
                                      key: ValueKey('wave'),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 14,
                                      ),
                                      child: _WaveformWidget(),
                                    )
                                  : TextField(
                                      key: const ValueKey('textfield'),
                                      controller: _textController,
                                      focusNode: _focusNode,
                                      maxLines: 5,
                                      minLines: 1,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'Outfit',
                                        fontSize: 15,
                                      ),
                                      cursorColor: AppColors.cyberBlue,
                                      onTapOutside: (PointerDownEvent event) =>
                                          FocusManager.instance.primaryFocus
                                              ?.unfocus(),
                                      decoration: const InputDecoration(
                                        hintText: 'Message Aitana...',
                                        hintStyle: TextStyle(
                                          color: Colors.white30,
                                          fontFamily: 'Outfit',
                                        ),
                                        // LA MAGIA: Forzamos fondo transparente y matamos bordes
                                        filled: true,
                                        fillColor: Colors.transparent,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        errorBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 12,
                                        ),
                                      ),
                                    ),
                            ),
                          ),

                          // ── Right: dynamic action button ───────────────────
                          // ValueListenableBuilder scopes rebuilds to ONLY
                          // this button. The TextField's RenderEditable is
                          // never re-mounted when the user types, eliminating
                          // the mid-gesture rebuild that caused the
                          // tap-to-position → drag-selection bug.
                          ValueListenableBuilder<bool>(
                            valueListenable: _isTypingNotifier,
                            builder: (context, isTyping, _) {
                              return Padding(
                                padding: const EdgeInsets.all(6),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  height: 44,
                                  width: 44,
                                  decoration: BoxDecoration(
                                    color: _isLoading
                                        ? Colors.grey[800]
                                        : _isRecording
                                        ? Colors.redAccent.withAlpha(30)
                                        : AppColors.cyberBlue.withAlpha(40),
                                    shape: BoxShape.circle,
                                    border: _isRecording
                                        ? Border.all(
                                            color: Colors.redAccent.withAlpha(
                                              160,
                                            ),
                                            width: 1.5,
                                          )
                                        : null,
                                  ),
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    transitionBuilder: (child, animation) =>
                                        ScaleTransition(
                                          scale: animation,
                                          child: child,
                                        ),
                                    child: _isLoading
                                        ? const IconButton(
                                            key: ValueKey('stop'),
                                            icon: Icon(
                                              Icons.stop_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            onPressed: null,
                                          )
                                        : (isTyping ||
                                              _selectedImagePath != null)
                                        ? IconButton(
                                            key: const ValueKey('send'),
                                            icon: const Icon(
                                              Icons.send_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            onPressed: _sendMessage,
                                          )
                                        : IconButton(
                                            key: const ValueKey('mic'),
                                            icon: Icon(
                                              _isRecording
                                                  ? Icons.stop_rounded
                                                  : Icons.mic_none_rounded,
                                              color: _isRecording
                                                  ? Colors.redAccent
                                                  : AppColors.cyberBlue,
                                              size: 22,
                                            ),
                                            onPressed: _toggleRecording,
                                          ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ), // Column
        ), // Scaffold
        // ── THE ARMOR ── RAM-lock overlay (Ghost Summary / model init) ─────────
        // Sits at the TOP of the Stack so it covers everything, including the
        // Drawer, FABs, and the keyboard. The ModalBarrier absorbs all pointer
        // events so the user cannot dispatch new messages while the C++ engine
        // is saturating all CPU cores and RAM is critically constrained.
        ValueListenableBuilder<bool>(
          valueListenable: LocalLlmService.isEngineBusy,
          builder: (context, isBusy, _) {
            if (!isBusy) return const SizedBox.shrink();
            return const SystemLockOverlay(
              title: 'Synthesizing memory...',
              subtitle: 'Protecting system memory...',
            );
          },
        ),
      ], // Stack children
    ); // Stack
  }

  // 💬 CONSTRUCTOR DE BURBUJAS
  Widget _buildChatBubble(ChatMessage message, Color userBubbleColor) {
    // ─── CASO ESPECIAL: BURBUJA ORÁCULO (Resumen del Historial) ───
    if (message.isSystemOracle) {
      return Align(
        alignment: Alignment.center, // Centrado total
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          padding: const EdgeInsets.all(16),
          width: MediaQuery.of(context).size.width * 0.85, // Más ancha
          decoration: BoxDecoration(
            color: AppColors.deepIndigo.withAlpha(
              150,
            ), // Fondo cristalino oscuro
            borderRadius: BorderRadius.circular(16), // Completamente redondeada
            border: Border.all(
              color: const Color(
                0xFFD4AF37,
              ).withAlpha(100), // Borde dorado tenue
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              // El icono de la cápsula del tiempo / ojo
              const Icon(
                Icons.history_edu_rounded,
                color: Color(0xFFD4AF37), // Dorado
                size: 28,
              ),
              const SizedBox(height: 8),
              Text(
                message.text,
                textAlign: TextAlign.center, // Texto centrado
                style: const TextStyle(
                  color: Colors
                      .white70, // Texto un poco más tenue que los mensajes normales
                  fontSize: 14,
                  fontFamily: 'Outfit',
                  height: 1.5,
                  fontStyle: FontStyle.italic, // Cursiva para denotar memoria
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ─── CASO NORMAL: MENSAJES DE LORENZO O AITANA ───
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isUser) ...[
            CircleAvatar(
              radius: 12,
              backgroundColor: AppColors.cyberBlue.withAlpha(50),
              child: const Text(
                'A',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMedium,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: message.isUser ? userBubbleColor : AppColors.deepIndigo,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(message.isUser ? 18 : 4),
                  bottomRight: Radius.circular(message.isUser ? 4 : 18),
                ),
                border: message.isUser
                    ? null
                    : Border.all(color: AppColors.glassBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(25),
                    blurRadius: 3,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: message.isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (message.imagePath != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(message.imagePath!),
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    if (message.text.isNotEmpty || message.audioPath != null)
                      const SizedBox(height: 8),
                  ],
                  if (message.audioPath != null) ...[
                    AudioBubble(
                      audioPath: message.audioPath!,
                      durationText: message.audioDuration ?? '0.0s',
                      isUser: message.isUser,
                    ),
                    if (message.text.isNotEmpty) const SizedBox(height: 8),
                  ],
                  if (message.text.isNotEmpty)
                    Text(
                      message.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontFamily: 'Outfit',
                        height: 1.4,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showParameterInfo(
  BuildContext context,
  String title,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.deepIndigo,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Outfit',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepOrangeAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      onAction();
                    },
                    child: Text(
                      actionLabel,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

// 📦 WIDGET PERSONALIZADO PARA LOS SLIDERS Y CAJAS DE TEXTO (El Reto)
class _ParameterSlider extends StatefulWidget {
  final String label;
  final String tooltipMessage;
  final double min;
  final double max;
  final double value;
  final bool isDouble;
  final ValueChanged<double> onChanged;

  const _ParameterSlider({
    required this.label,
    required this.tooltipMessage,
    required this.min,
    required this.max,
    required this.value,
    required this.isDouble,
    required this.onChanged,
  });

  @override
  State<_ParameterSlider> createState() => _ParameterSliderState();
}

class _ParameterSliderState extends State<_ParameterSlider> {
  late TextEditingController _inputCtrl;
  late double _currentValue;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.value;
    _inputCtrl = TextEditingController(text: _formatValue(_currentValue));
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  /// Reacts to parent-driven value changes (e.g. the "Reset" button calling
  /// [setDialogState] with new defaults). Without this, [_currentValue] and
  /// [_inputCtrl] would only ever reflect the value passed at construction time.
  @override
  void didUpdateWidget(covariant _ParameterSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      setState(() {
        _currentValue = widget.value;
        _inputCtrl.text = _formatValue(_currentValue);
      });
    }
  }

  String _formatValue(double val) {
    return widget.isDouble ? val.toStringAsFixed(2) : val.toInt().toString();
  }

  void _updateFromText(String text) {
    double? parsed = double.tryParse(text);
    if (parsed != null) {
      if (parsed < widget.min) parsed = widget.min;
      if (parsed > widget.max) parsed = widget.max;
      setState(() {
        _currentValue = parsed!;
        _inputCtrl.text = _formatValue(_currentValue);
      });
      widget.onChanged(_currentValue);
    } else {
      _inputCtrl.text = _formatValue(
        _currentValue,
      ); // Revertir si escriben basura
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'Outfit',
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _showParameterInfo(
                  context,
                  widget.label,
                  widget.tooltipMessage,
                ),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.info_outline, size: 16, color: Colors.grey),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: AppColors.cyberBlue,
                    inactiveTrackColor: Colors.white12,
                    thumbColor: Colors.white,
                    overlayColor: AppColors.cyberBlue.withAlpha(50),
                    trackHeight: 4.0,
                  ),
                  child: Slider(
                    value: _currentValue,
                    min: widget.min,
                    max: widget.max,
                    divisions: widget.isDouble
                        ? 100
                        : (widget.max - widget.min).toInt(),
                    onChanged: (val) {
                      setState(() {
                        _currentValue = val;
                        _inputCtrl.text = _formatValue(val);
                      });
                      widget.onChanged(val);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _inputCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Outfit',
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    filled: true,
                    fillColor: Colors.white.withAlpha(15),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: _updateFromText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// 🎙️ ANIMATED WAVEFORM WIDGET (shown during voice recording)
class _WaveformWidget extends StatefulWidget {
  const _WaveformWidget();

  @override
  State<_WaveformWidget> createState() => _WaveformWidgetState();
}

class _WaveformWidgetState extends State<_WaveformWidget>
    with TickerProviderStateMixin {
  static const int _barCount = 5;
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  // Staggered delays (ms) so each bar pulses at a different phase
  static const List<int> _delays = [0, 120, 60, 180, 30];
  // Unique speed multipliers for organic feel
  static const List<int> _durations = [420, 360, 500, 380, 450];

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(_barCount, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: _durations[i]),
      );
    });

    _animations = List.generate(_barCount, (i) {
      return Tween<double>(begin: 0.15, end: 1.0).animate(
        CurvedAnimation(parent: _controllers[i], curve: Curves.easeInOut),
      );
    });

    // Start each bar with its own delay for a stagger effect
    for (int i = 0; i < _barCount; i++) {
      Future.delayed(Duration(milliseconds: _delays[i]), () {
        if (mounted) {
          _controllers[i].repeat(reverse: true);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(_barCount, (i) {
        return AnimatedBuilder(
          animation: _animations[i],
          builder: (context, child) {
            final height = 6.0 + (_animations[i].value * 22.0);
            return Container(
              width: 4,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: AppColors.cyberBlue.withAlpha(200),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          },
        );
      }),
    );
  }
}

// 📦 MODELO DE DATOS
class ChatMessage {
  String text;
  final bool isUser;
  final String? imagePath;
  final String? audioPath;
  final String? audioDuration;
  final bool isSystemOracle;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.audioPath,
    this.audioDuration,
    this.isSystemOracle = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// RENAME DIALOG WIDGET
// ─────────────────────────────────────────────────────────────────────────────

/// A self-contained rename dialog whose [TextEditingController] is bound to
/// the widget's own [State] lifecycle.
///
/// **Why a [StatefulWidget] instead of an inline builder?**
/// When `showDialog` resolves (i.e., after `Navigator.pop`), the builder
/// closure is immediately eligible for garbage collection, but Flutter may
/// still be running the dialog's *closing animation*. Any `TextEditingController`
/// that is disposed in a `finally` block at the call site will be accessed by
/// the [TextField] during that animation, producing a fatal
/// `"used after being disposed"` assertion. Binding the controller to
/// `initState` / `dispose` ensures it lives exactly as long as the widget
/// subtree, which is the correct Flutter contract.
class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.initialTitle});

  /// The pre-filled value shown in the [TextField] when the dialog opens.
  final String initialTitle;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller;

  /// Guards against double-taps on the "Save" button.
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Controller is created once and lives until this State is disposed —
    // safely after the closing animation finishes.
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSave() {
    if (_isProcessing) return;

    final newTitle = _controller.text.trim();
    if (newTitle.isEmpty) return;

    setState(() => _isProcessing = true);

    // Return the validated title to the caller via Navigator.
    // The caller (_renameSession) handles the ObjectBox write.
    Navigator.pop(context, newTitle);
  }

  void _handleCancel() {
    if (_isProcessing) return;
    Navigator.pop(context, null);
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
        cursorColor: AppColors.cyberBlue,
        // Allow "Done" / "Go" on the software keyboard to trigger Save.
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _handleSave(),
        decoration: InputDecoration(
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.cyberBlue),
          ),
          filled: true,
          fillColor: Colors.white.withAlpha(10),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _handleCancel,
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white54, fontFamily: 'Outfit'),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.cyberBlue,
            foregroundColor: AppColors.obsidian,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _isProcessing ? null : _handleSave,
          child: const Text(
            'Save',
            style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
          ),
        ),
      ],
    );
  }
}
