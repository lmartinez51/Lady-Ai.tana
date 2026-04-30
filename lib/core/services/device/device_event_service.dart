import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/constants/native_channels.dart';

/// Subscribes to the native `DEVICE_EVENTS` EventChannel and exposes
/// the real hardware recording state as a [ValueNotifier].
///
/// The Kotlin side emits maps like:
/// - `{"event": "videoRecordingStarted"}`
/// - `{"event": "videoRecordingStopped", "uri": "content://..."}` — fired by Finalize
/// - `{"event": "videoRecordingStoppedManual"}` — fired immediately on double-tap
///
/// This service translates those into a single observable boolean so
/// the Flutter UI never needs to maintain optimistic state.
class DeviceEventService {
  static const EventChannel _eventChannel = EventChannel(
    NativeChannels.deviceEvents,
  );

  /// `true` while the CameraX engine has confirmed an active recording
  /// via a real `VideoRecordEvent.Start` hardware event.
  static final ValueNotifier<bool> isVideoRecording = ValueNotifier(false);

  static StreamSubscription<dynamic>? _subscription;

  /// Optional callback invoked when a `videoRecordingStoppedManual` event
  /// arrives (i.e., the user double-tapped the Safety Halo to stop recording).
  ///
  /// Register this from the screen's [State.initState] and clear it in
  /// [State.dispose]. This avoids capturing a stale [BuildContext] inside
  /// the service while still allowing a mounted widget to react promptly.
  ///
  /// Example:
  /// ```dart
  /// DeviceEventService.onManualStop = _handleManualStop;  // in initState
  /// DeviceEventService.onManualStop = null;               // in dispose
  /// ```
  static VoidCallback? onManualStop;

  /// Call once at app startup (after `runApp`) to start listening for
  /// native device events. Safe to call multiple times — subsequent
  /// calls cancel and re-subscribe.
  static void initialize() {
    _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;

        final eventName = event['event'] as String?;
        switch (eventName) {
          case 'videoRecordingStarted':
            isVideoRecording.value = true;
            debugPrint(
              '📹 [DeviceEventService] Recording STARTED (confirmed by hardware).',
            );
            break;
          case 'videoRecordingStopped':
            isVideoRecording.value = false;
            final uri = event['uri'] as String? ?? '';
            debugPrint('📹 [DeviceEventService] Recording STOPPED → $uri');
            break;
          case 'videoRecordingStoppedManual':
            // Double-tap on Safety Halo: the native layer has called
            // recording.stop(). Finalize will fire shortly with the real URI,
            // but we update state immediately so the Flutter UI responds fast.
            isVideoRecording.value = false;
            debugPrint(
              '📹 [DeviceEventService] Recording STOPPED manually (double-tap).',
            );
            onManualStop?.call();
            break;
        }
      },
      onError: (error) {
        debugPrint('🔴 [DeviceEventService] Stream error: $error');
      },
    );
    debugPrint('📡 [DeviceEventService] Initialized.');
  }

  /// Cancel the stream subscription. Call on secure app exit.
  static void dispose() {
    _subscription?.cancel();
    _subscription = null;
    isVideoRecording.value = false;
    onManualStop = null;
    debugPrint('🔌 [DeviceEventService] Disposed.');
  }
}
