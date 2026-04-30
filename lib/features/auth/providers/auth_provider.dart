import 'package:flutter/material.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

enum AuthStatus {
  initial,
  authenticating,
  authenticated,
  unauthenticated,
  noBiometrics,
}

class AuthProvider extends ChangeNotifier {
  final LocalAuthentication _auth = LocalAuthentication();
  AuthStatus _status = AuthStatus.initial;
  String _errorMessage = '';
  bool _isWokenByNexus = false;

  AuthStatus get status => _status;
  String get errorMessage => _errorMessage;
  bool get isWokenByNexus => _isWokenByNexus;

  AuthProvider() {
    checkBiometrics();
  }

  Future<void> checkBiometrics() async {
    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool canAuthenticate =
          canAuthenticateWithBiometrics || await _auth.isDeviceSupported();

      if (!canAuthenticate) {
        _status = AuthStatus.noBiometrics;
        _errorMessage =
            'Device security not configured. Please set up a screen lock.';
        notifyListeners();
        return;
      }

      final List<BiometricType> availableBiometrics = await _auth
          .getAvailableBiometrics();

      if (availableBiometrics.isEmpty) {
        // According to strict constraint: if no enrolled biometrics, treat as noBiometrics error
        _status = AuthStatus.noBiometrics;
        _errorMessage =
            'No biometric signatures found. Please enroll a fingerprint or face in OS settings.';
        notifyListeners();
        return;
      }

      // If we reach here, hardware exists and something is enrolled.
      // We start in unauthenticated state waiting for interaction or auto-trigger.
      _status = AuthStatus.unauthenticated;
      notifyListeners();

      // 🕵️‍♂️ PREGUNTAR A KOTLIN SI VENIMOS DE UN COMANDO DE VOZ
      try {
        const platform = MethodChannel(NativeChannels.aiCore);
        _isWokenByNexus =
            await platform.invokeMethod('checkWakeSource') ?? false;

        if (_isWokenByNexus) {
          // ¡Bypass autorizado! Se saltan la huella y entran directo.
          _status = AuthStatus.authenticated;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint("Error al revisar el Wake Source: $e");
      }

      // 🔒 Auto-trigger authentication (SOLO si se abrió tocando el ícono)
      authenticate();
    } catch (e) {
      _status = AuthStatus.noBiometrics;
      _errorMessage = 'Security error: ${e.toString()}';
      notifyListeners();
    }
  }

  Future<void> authenticate() async {
    if (_status == AuthStatus.noBiometrics) return;

    _status = AuthStatus.authenticating;
    notifyListeners();

    try {
      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: 'Please authenticate to access Aitana Core',
      );

      if (didAuthenticate) {
        _status = AuthStatus.authenticated;
      } else {
        _status = AuthStatus.unauthenticated;
      }
      notifyListeners();
    } on PlatformException catch (e) {
      _status = AuthStatus.unauthenticated;
      _errorMessage = e.message ?? 'Authentication failed';
      notifyListeners();
    }
  }

  /// Clears the Nexus wake flag after it has been acted upon.
  ///
  /// Calls [notifyListeners] so that any [context.watch] consumer (e.g.
  /// [AuthenticationWrapper]) immediately picks up the cleared value and
  /// does not hold a stale `true` across a future rebuild.
  void consumeWakeFlag() {
    if (!_isWokenByNexus) return; // already cleared – no-op
    _isWokenByNexus = false;
    notifyListeners();
  }

  void logout() {
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }
}
