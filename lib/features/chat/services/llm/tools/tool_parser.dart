/// Handles the mid-stream parsing and interception of special tags
/// (Gemma thoughts, device commands, tools) during LLM inference.
class ToolParser {
  final Function(String command)? onCommandDetected;
  final Function(String location, String task)? onGeofenceDetected;
  final Function(Map<String, dynamic> args)? onCalendarDetected;

  // ─── Internal Buffers ─────────────────────────────────────────────────────

  /// Accumulates the FULL raw output from the engine (including thoughts).
  final StringBuffer rawBuffer = StringBuffer();

  /// Accumulates the "clean" output (thoughts and intercepted tags stripped).
  final StringBuffer cleanBuffer = StringBuffer();

  // ─── State Machine Flags ──────────────────────────────────────────────────

  bool _insideThought = false;
  bool _startVideoFired = false;
  bool _stopVideoFired = false;

  // ─── Sentinel Substrings ──────────────────────────────────────────────────

  static const String thinkOpen = '<|channel>thought';
  static const String thinkClose = '<channel|>';
  static const String startVideoTag = '<START_VIDEO>';
  static const String stopVideoTag = '<STOP_VIDEO>';

  static final RegExp geofenceRegex =
      RegExp(r'<GEOFENCE:\s*([^|]+)\s*\|\s*([^>]+)>');

  static final RegExp calendarRegex = RegExp(
    r'<CALENDAR:\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^>]+)>',
  );

  ToolParser({
    this.onCommandDetected,
    this.onGeofenceDetected,
    this.onCalendarDetected,
  });

  /// Processes a single token received from the stream.
  ///
  /// Returns the "clean" text suitable for UI display (after stripping tags).
  String parseToken(String token) {
    // Append raw token to the unfiltered buffer.
    rawBuffer.write(token);
    final String raw = rawBuffer.toString();

    // ── 1. Thought-channel filter ───────────────────────────────────────────

    if (!_insideThought) {
      final openIdx = raw.indexOf(thinkOpen);
      if (openIdx != -1) {
        // Everything before the opening tag is clean output.
        final beforeTag = raw.substring(cleanBuffer.length, openIdx);
        if (beforeTag.isNotEmpty) {
          cleanBuffer.write(beforeTag);
        }
        _insideThought = true;

        final closeIdx = raw.indexOf(thinkClose, openIdx);
        if (closeIdx != -1) {
          _insideThought = false;
          final afterClose = raw.substring(closeIdx + thinkClose.length);
          if (afterClose.isNotEmpty) {
            cleanBuffer.write(afterClose);
          }
        }
      } else {
        final newContent = raw.substring(cleanBuffer.length);
        if (newContent.isNotEmpty) {
          cleanBuffer.write(newContent);
        }
      }
    } else {
      final closeIdx = raw.indexOf(thinkClose);
      if (closeIdx != -1) {
        _insideThought = false;
        final afterClose = raw.substring(closeIdx + thinkClose.length);
        if (afterClose.isNotEmpty) {
          cleanBuffer.write(afterClose);
        }
      }
    }

    // ── 2. Device command detection ─────────────────────────────────────────

    final String currentClean = cleanBuffer.toString();

    if (!_startVideoFired && currentClean.contains(startVideoTag)) {
      _startVideoFired = true;
      _stripTag(startVideoTag);
      onCommandDetected?.call('START_VIDEO');
    }

    if (!_stopVideoFired && currentClean.contains(stopVideoTag)) {
      _stopVideoFired = true;
      _stripTag(stopVideoTag);
      onCommandDetected?.call('STOP_VIDEO');
    }

    // ── 3. Tool Interceptors ───────────────────────────────────────────────

    final geofenceMatch = geofenceRegex.firstMatch(cleanBuffer.toString());
    if (geofenceMatch != null) {
      final locationKey = geofenceMatch.group(1)?.trim() ?? '';
      final taskDesc =
          geofenceMatch.group(2)?.trim() ?? 'Recordatorio de ubicación';

      _stripTag(geofenceMatch.group(0)!);
      onGeofenceDetected?.call(locationKey, taskDesc);
    }

    final calMatch = calendarRegex.firstMatch(cleanBuffer.toString());
    if (calMatch != null) {
      final dateStr = calMatch.group(1)?.trim() ?? '';
      final timeStr = calMatch.group(2)?.trim() ?? '17:00';
      final isBirthdayStr = calMatch.group(3)?.trim().toLowerCase() ?? 'false';
      final titleStr = calMatch.group(4)?.trim() ?? 'Evento';

      _stripTag(calMatch.group(0)!);

      final isBirthday = isBirthdayStr == 'true';
      int reminderMins = (isBirthday || timeStr == '17:00') ? 60 : 0;

      onCalendarDetected?.call({
        'action': 'add',
        'title': titleStr,
        'date': dateStr,
        'time': timeStr,
        'reminder_minutes': reminderMins,
        'is_all_day': isBirthday,
        'is_birthday': isBirthday,
      });
    }

    // ── 4. UI Text Formatting (Flicker Prevention) ─────────────────────────

    String uiText = cleanBuffer
        .toString()
        .replaceAll(startVideoTag, '')
        .replaceAll(stopVideoTag, '')
        .replaceAll(geofenceRegex, '')
        .replaceAll(calendarRegex, '');

    // Avoid partial tags appearing in the UI
    uiText = uiText.replaceAll(RegExp(r'<GEOFENCE:[^>]*$'), '');
    uiText = uiText.replaceAll(RegExp(r'<CALENDAR:[^>]*$'), '');

    final possibleTags = [
      startVideoTag,
      stopVideoTag,
      '<GEOFENCE:',
      '<CALENDAR:',
    ];

    for (final tag in possibleTags) {
      for (int i = tag.length - 1; i > 0; i--) {
        final partial = tag.substring(0, i);
        if (uiText.endsWith(partial)) {
          uiText = uiText.substring(0, uiText.length - partial.length);
          break;
        }
      }
    }

    return uiText.trim();
  }

  /// Helper to remove a matched tag from the clean buffer.
  void _stripTag(String tag) {
    final content = cleanBuffer.toString().replaceAll(tag, '');
    cleanBuffer.clear();
    cleanBuffer.write(content);
  }

  /// Final cleanup for logs or state.
  String getFinalCleanText() => cleanBuffer.toString().trim();

  bool get startVideoFired => _startVideoFired;
}
