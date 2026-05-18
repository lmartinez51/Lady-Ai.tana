class NativeChannels {
  /// The primary command bridge for AI operations (inference, init, tools).
  static const String aiCore = 'com.lmartinez.aitana/aicore';

  /// The broadcast stream for real-time LLM token delivery.
  static const String aiCoreStream = 'com.lmartinez.aitana/aicore_stream';

  /// Bridge for geofencing registration and lifecycle management.
  static const String geofence = 'com.lmartinez.aitana/geofence';

  /// The broadcast stream for low-level device events (e.g. video recording status).
  static const String deviceEvents = 'com.lmartinez.aitana/device_events';

  /// Bridge for Android NotificationListenerService access management.
  static const String notificationMonitor =
      'com.lmartinez.aitana/notification_monitor';

  /// Bridge for WhatsApp auto-pilot request/response handoff.
  static const String autoPilot = 'com.lmartinez.aitana/autopilot';
}
