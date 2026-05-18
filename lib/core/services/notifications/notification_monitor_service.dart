import 'package:aitana/core/constants/native_channels.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationMonitorService {
  static const MethodChannel _channel = MethodChannel(
    NativeChannels.notificationMonitor,
  );

  static Future<bool> hasNotificationAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasNotificationAccess') ??
          false;
    } on PlatformException catch (e) {
      debugPrint(
        'NotificationMonitorService access check failed: ${e.message}',
      );
      return false;
    }
  }

  static Future<void> openNotificationAccessSettings() async {
    try {
      await _channel.invokeMethod<bool>('openNotificationAccessSettings');
    } on PlatformException catch (e) {
      debugPrint(
        'NotificationMonitorService settings launch failed: ${e.message}',
      );
    }
  }
}
