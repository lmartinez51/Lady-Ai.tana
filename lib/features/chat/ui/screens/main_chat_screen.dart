import 'dart:io';
import 'dart:async';
import 'package:aitana/core/domain/entities/chat_session.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:aitana/core/database/objectbox_service.dart';
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
    if (_isLoading) return;

    try {
      const channel = MethodChannel(NativeChannels.aiCore);
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
    _scrollToBottom();

    final response = await LocalLlmService.runInference(
      "Responde a la solicitud de Lorenzo.",
      audioPath: path,
      onTokenUpdate: _handleTokenUpdate,
      onCommandDetected: _handleDeviceCommand,
    );

    _finalizeResponse(response);
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

    _addMessage(ChatMessage(text: text, isUser: true, imagePath: imagePath));
    _addMessage(ChatMessage(text: "", isUser: false));
    setState(() {
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
      if (accumulatedText.trim().isNotEmpty && _isLoading) {
        setState(() {
          _isLoading = false;
        });
      }
      _messages.last.text = accumulatedText;
      _notifyMessagesChanged();
      _scrollToBottom();
    }
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

      setState(() {
        _isLoading = false;
      });
      if (cleanText.isNotEmpty) {
        _messages.last.text = cleanText;
      } else {
        _messages.last.text = "Acción ejecutada.";
      }
      _notifyMessagesChanged();
      _scrollToBottom();

      if (_isVoiceWakeSession) {
        _isVoiceWakeSession = false;
        // Por hacer: Trigger recording via VoiceInputPanel if needed.
        // For now, we skip auto-recording to maintain stability.
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
                              _clearMessages();
                              setState(() {
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
              ChatHeaderWidget(
                onMenuPressed: () => _scaffoldKey.currentState?.openDrawer(),
                onModelSelectorPressed: _showModelSelector,
                onClearMemoryPressed: () {
                  LocalLlmService.clearContext();
                  if (mounted) {
                    _clearMessages();
                    setState(() {
                      _currentSessionId = null;
                      _needsSaving = false;
                    });
                  }
                  LocalLlmService.activeSessionSummary = '';
                  _refreshHistory();
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
                    // ── Empty-state placeholder and Message list ─────────────────────────────
                    ValueListenableBuilder<List<ChatMessage>>(
                      valueListenable: _messagesNotifier,
                      builder: (context, messagesList, child) {
                        return Stack(
                          children: [
                            if (messagesList.isEmpty)
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
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            Align(
                              alignment: Alignment.topCenter,
                              child: ListView.builder(
                                controller: _scrollController,
                                reverse: true,
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  16,
                                  12,
                                  8,
                                ),
                                itemCount: messagesList.length,
                                itemBuilder: (context, index) {
                                  // PERFORMANCE FIX: Access messages by direct index instead of .reversed.toList()
                                  final msg =
                                      messagesList[messagesList.length -
                                          1 -
                                          index];
                                  if (msg.text.isEmpty &&
                                      !msg.isUser &&
                                      msg.audioPath == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return ChatBubbleWidget(
                                    message: msg,
                                    userBubbleColor: userBubbleColor,
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
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
                    VoiceInputPanel(
                      textController: _textController,
                      focusNode: _focusNode,
                      isLoading: _isLoading,
                      selectedImagePath: _selectedImagePath,
                      isTypingNotifier: _isTypingNotifier,
                      onAttachmentPressed: _showAttachmentOptions,
                      onSendText: _sendMessage,
                      onAudioRecorded: _handleAudioRecorded,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 🛡️ THE ARMOR (OOM BLOCKER)
        ValueListenableBuilder<bool>(
          valueListenable: LocalLlmService.isEngineBusy,
          builder: (context, isBusy, child) {
            if (!isBusy) return const SizedBox.shrink();
            return const SystemLockOverlay(
              title: "Neural Core Engine Busy",
              subtitle:
                  "Reconfiguring memory for high-performance inference...",
            );
          },
        ),
      ],
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
