// @file main.dart
// @brief Entry point for the Aitana application. Handles initialization of services, database, and LLM.
// @author Lorenzo Martínez
// @date 2026-04-29
// @version 1.0.0

import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/core/services/network/network_service.dart';
import 'package:aitana/core/services/device/device_event_service.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/geofencing/services/geofence_service.dart';
import 'package:aitana/core/services/foreground_service_handler.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:aitana/core/theme/app_theme.dart';
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

    // 🧠 Arrancamos el cerebro de Aitana y le conectamos la base de datos
    await LocalLlmService.initModel();
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
