// @file main.dart
// @brief Entry point for the Aitana application. Handles initialization of services, database, and LLM.
// @author Lorenzo Martínez
// @date 2026-04-29
// @version 1.0.0

import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/features/chat/services/llm/models/ai_model_catalog.dart';
import 'package:aitana/core/services/network/network_service.dart';
import 'package:aitana/core/services/device/device_event_service.dart';
import 'package:aitana/core/theme/persona_theme_router.dart';

import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/geofencing/services/geofence_service.dart';
import 'package:aitana/core/services/foreground_service_handler.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:aitana/core/theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/features/auth/providers/auth_provider.dart';
import 'package:aitana/features/auth/ui/screens/lock_screen.dart';
import 'package:aitana/features/chat/ui/screens/main_chat_screen.dart';

/// @brief Main entry point of the application.
/// @note Initializes Flutter bindings, Google Fonts, ObjectBox, and LLM services before running the app.
/// @return `Future<void>`
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Foreground Service Configuration
  await ForegroundServiceControl.initForegroundTask();

  // Disable runtime fetching for offline-first compliance
  GoogleFonts.config.allowRuntimeFetching = false;

  // Initialize Database & LLM
  try {
    await ObjectBoxService.create();
    await NetworkService.initialize();
    debugPrint("🔓 Bóveda de ObjectBox abierta exitosamente.");
    // Use this to delete all data in the database (CAUTION)
    // Uncomment the following lines to delete all data in the database
    // ObjectBoxService.instance.agendaBox.removeAll();
    // debugPrint("🧹 Bóveda de ObjectBox limpiada exitosamente.");

    // Sincronizar estado de geofencing pendiente
    await GeofenceService().init();

    // Check if woken by voice command immediately at startup (cold start)
    try {
      const channel = MethodChannel(NativeChannels.aiCore);
      final bool isWoken =
          await channel.invokeMethod<bool>('checkWakeSource') ?? false;
      if (isWoken) {
        LocalLlmService.isWokenByVoiceOnStartup = true;
        // Force active persona to "AI" category in database
        final personaManager = ObjectBoxService.instance.personaManager;
        final aiPersona = personaManager.getAllPersonas().firstWhere(
          (p) => p.category == 'AI',
        );
        personaManager.setActivePersona(aiPersona.id);
        debugPrint('🎙️ [Voice Startup] Force-set active persona to AI.');
      }
    } catch (e) {
      debugPrint('🔴 [Voice Startup] Error checking wake source: $e');
    }

    // 🧠 MoE Startup Routing: select the correct model before the engine loads.
    // Route parity: HUMAN uses the variant; AI and LEGAL use the base model.
    final startupPersona = ObjectBoxService.instance.personaManager
        .getActivePersona();
    await LocalLlmService.setLanguageOverride(
      startupPersona.defaultLang,
      resetContext: false,
    );

    final startupTargetBaseName = PersonaThemeRouter.getModelBaseName(
      startupPersona.category,
    );
    final startupTargetModel = AiModelCatalog.findByBaseName(
      startupTargetBaseName,
    );
    if (startupTargetModel != null) {
      LocalLlmService.currentModel.value = startupTargetModel;
      if (startupPersona.category == 'LEGAL' ||
          startupPersona.category == 'HUMAN') {
        debugPrint(
          '🧠 [MoE Startup] ${startupPersona.category} persona active → '
          'pre-selecting ${startupTargetModel.displayName}',
        );
      }
    }

    // 🧠 Arrancamos el cerebro de Aitana y le conectamos la base de datos.
    // A 30-second timeout is applied as a safety net: if the native engine
    // hangs (e.g., corrupted model file, OOM before allocation), we still
    // call runApp() so the user sees an error UI rather than a blank screen.
    try {
      await LocalLlmService.initModel().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint(
            '🔴 [main] initModel() timed out after 30 s — '
            'launching app in degraded mode.',
          );
          LocalLlmService.status.value = 'error';
          return 'timeout';
        },
      );
    } catch (e) {
      debugPrint('🔴 [main] initModel() threw unexpectedly: $e');
      LocalLlmService.status.value = 'error';
    }
    // Inyectamos la instancia Singleton al puente nativo
    LocalLlmService.setupNativeToolListener();
    // 📡 Subscribe to native hardware device events (video recording state, etc.)
    DeviceEventService.initialize();

    // 🚀 SOLO ARRANCAMOS LA APP SI EL LLM Y LA BASE DE DATOS FUNCIONARON
    runApp(
      MultiProvider(
        providers: [
          Provider<ObjectBoxService>.value(value: ObjectBoxService.instance),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: const AitanaApp(),
      ),
    );
  } catch (e) {
    debugPrint("🔴 Error crítico al abrir ObjectBox o inicializar LLM: $e");
    // Aquí en el futuro podrías hacer runApp() de una pantalla de "Error de Sistema"
  }
}

/// @brief Root widget of the Aitana application.
/// @note Configures the global theme and initial navigation wrapper.
class AitanaApp extends StatelessWidget {
  const AitanaApp({super.key});

  /// @brief Builds the top-level MaterialApp widget.
  /// @param context The build context.
  /// @return `Widget`
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aitana',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const AuthenticationWrapper(),
    );
  }
}

/// @brief A wrapper widget that handles conditional routing based on authentication state.
class AuthenticationWrapper extends StatelessWidget {
  const AuthenticationWrapper({super.key});

  /// @brief Determines the initial route based on authentication status.
  /// @param context The build context.
  /// @return `Widget`
  @override
  Widget build(BuildContext context) {
    // State-Based Routing: listen to AuthProvider
    final authStatus = context.watch<AuthProvider>().status;

    if (authStatus == AuthStatus.authenticated) {
      return const MainChatScreen();
    } else {
      return const LockScreen();
    }
  }
}
