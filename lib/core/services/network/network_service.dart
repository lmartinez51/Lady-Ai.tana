import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class NetworkService {
  NetworkService._();

  static final ValueNotifier<bool> isOnline = ValueNotifier<bool>(false);
  static StreamSubscription<List<ConnectivityResult>>? _subscription;
  static bool _isDisposed = false;

  static Future<void> initialize() async {
    final connectivity = Connectivity();

    // Initial check
    final results = await connectivity.checkConnectivity();
    _updateStatus(results);

    // Listen to ongoing changes
    _subscription = connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  static void _updateStatus(List<ConnectivityResult> results) {
    final hasConnection = !results.contains(ConnectivityResult.none);
    if (isOnline.value != hasConnection) {
      isOnline.value = hasConnection;
      debugPrint(
        "📡 Network Status Changed: ${hasConnection ? 'Online' : 'Offline'}",
      );
    }
  }

  static void dispose() {
    if (_isDisposed) return; // Si ya se apagó, ignora la orden
    _isDisposed = true;

    _subscription?.cancel();
    isOnline.dispose();
    debugPrint("🌐 NetworkService apagado de forma segura.");
  }
}
