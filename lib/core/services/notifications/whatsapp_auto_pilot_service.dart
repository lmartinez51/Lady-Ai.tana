import 'dart:async';

import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@Deprecated(
  'Mini-Aitana now generates WhatsApp replies natively from '
  'AitanaNotificationListenerService. This bridge is retained only for rollback.',
)
class WhatsAppAutoPilotService {
  static const MethodChannel _channel = MethodChannel(NativeChannels.autoPilot);

  static bool _initialized = false;
  static Future<void> _queue = Future.value();

  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    debugPrint('[WhatsAppAutoPilot] Bridge initialized.');
  }

  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onWhatsAppAutoReplyRequest':
        final args = Map<dynamic, dynamic>.from(call.arguments as Map);
        _queue = _queue.then((_) => _processRequest(args)).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint('[WhatsAppAutoPilot] Queue error: $error');
          debugPrintStack(stackTrace: stackTrace);
        });
        unawaited(_queue);
        return 'accepted';

      default:
        throw PlatformException(
          code: 'NOT_IMPLEMENTED',
          message: 'Unknown auto-pilot method: ${call.method}',
        );
    }
  }

  static Future<void> _processRequest(Map<dynamic, dynamic> args) async {
    final requestId = args['requestId'] as String?;
    final sender = args['sender'] as String?;
    final message = args['message'] as String?;

    if (requestId == null || sender == null || message == null) {
      debugPrint('[WhatsAppAutoPilot] Invalid native request: $args');
      return;
    }

    try {
      debugPrint(
        '[WhatsAppAutoPilot] Generating reply for "$sender": $message',
      );
      final reply = await LocalLlmService.runAutoReplyInference(
        sender: sender,
        message: message,
      );

      if (reply.trim().isEmpty) {
        await _channel.invokeMethod<bool>('dropAutoReply', {
          'requestId': requestId,
        });
        return;
      }

      await _channel.invokeMethod<bool>('completeAutoReply', {
        'requestId': requestId,
        'reply': reply,
      });
      debugPrint('[WhatsAppAutoPilot] Reply dispatched for $requestId.');
    } catch (e, stackTrace) {
      debugPrint('[WhatsAppAutoPilot] Failed request $requestId: $e');
      debugPrintStack(stackTrace: stackTrace);
      await _channel.invokeMethod<bool>('dropAutoReply', {
        'requestId': requestId,
      });
    }
  }
}
