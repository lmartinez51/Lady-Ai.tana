import 'package:flutter/foundation.dart';

/// Handles the mid-stream parsing and interception of special tags
/// (Gemma thoughts, device commands, tools) during LLM inference.
class ToolParser {
  final Function(String command)? onCommandDetected;
  final Function(String location, String task)? onGeofenceDetected;
  final Function(Map<String, dynamic> args)? onCalendarDetected;
  final Function(String query)? onVaultSearchDetected;

  // ─── Internal Buffers ─────────────────────────────────────────────────────

  /// Accumulates the FULL raw output from the engine (including thoughts).
  final StringBuffer rawBuffer = StringBuffer();

  /// Accumulates the "clean" output (thoughts and intercepted tags stripped).
  final StringBuffer cleanBuffer = StringBuffer();

  // ─── State Machine Flags ──────────────────────────────────────────────────

  bool _insideThought = false;
  bool _startVideoFired = false;
  bool _stopVideoFired = false;
  bool _isArmed = false;
  bool _vaultPrefixSeen = false;
  bool _vaultSearchFired = false;
  List<String> _allowedTags = [];

  // ─── Sentinel Substrings ──────────────────────────────────────────────────

  static const String thinkOpen = '<|channel>thought';
  static const String thinkClose = '<channel|>';
  static const String startVideoTag = '<CMD_SYS_OPTICS_1>';
  static const String stopVideoTag = '<CMD_SYS_OPTICS_0>';

  static final RegExp geofenceRegex = RegExp(
    r'<CMD_SYS_LOC_TRG:\s*([^|]+)\s*\|\s*([^>]+)>',
  );

  static final RegExp calendarRegex = RegExp(
    r'<CMD_SYS_CAL_EVT:\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*([^>]+)>',
  );

  static final RegExp vaultSearchRegex = RegExp(
    r'<CMD_SYS_VAULT_SRCH:\s*([^>]+)>',
  );

  ToolParser({
    this.onCommandDetected,
    this.onGeofenceDetected,
    this.onCalendarDetected,
    this.onVaultSearchDetected,
  });

  /// Arms the parser for a specific turn, allowing only certain tags to trigger callbacks.
  void armParser(List<String> expectedTags) {
    _isArmed = true;
    _allowedTags = expectedTags;
  }

  /// Resets the parser state to disarmed.
  void disarmParser() {
    _isArmed = false;
    _allowedTags = [];
  }

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
    if (!_vaultPrefixSeen && currentClean.contains('<CMD_SYS_VAULT_SRCH:')) {
      _vaultPrefixSeen = true;
      debugPrint('🔎 [ToolParser] Vault command prefix detected in stream.');
    }

    if (currentClean.contains(startVideoTag)) {
      _stripTag(startVideoTag);
      if (_isArmed &&
          _allowedTags.contains(startVideoTag) &&
          !_startVideoFired) {
        _startVideoFired = true;
        onCommandDetected?.call('START_VIDEO');
      }
    }

    if (currentClean.contains(stopVideoTag)) {
      _stripTag(stopVideoTag);
      if (_isArmed && _allowedTags.contains(stopVideoTag) && !_stopVideoFired) {
        _stopVideoFired = true;
        onCommandDetected?.call('STOP_VIDEO');
      }
    }

    // ── 3. Tool Interceptors ───────────────────────────────────────────────

    final geofenceMatch = geofenceRegex.firstMatch(cleanBuffer.toString());
    if (geofenceMatch != null) {
      final tag = geofenceMatch.group(0)!;
      _stripTag(tag);

      if (_isArmed && _allowedTags.contains('<CMD_SYS_LOC_TRG:')) {
        final locationKey = geofenceMatch.group(1)?.trim() ?? '';
        final taskDesc =
            geofenceMatch.group(2)?.trim() ?? 'Recordatorio de ubicación';
        onGeofenceDetected?.call(locationKey, taskDesc);
      }
    }

    final calMatch = calendarRegex.firstMatch(cleanBuffer.toString());
    if (calMatch != null) {
      final tag = calMatch.group(0)!;
      _stripTag(tag);

      if (_isArmed && _allowedTags.contains('<CMD_SYS_CAL_EVT:')) {
        final dateStr = calMatch.group(1)?.trim() ?? '';
        final timeStr = calMatch.group(2)?.trim() ?? '17:00';
        final isBirthdayStr =
            calMatch.group(3)?.trim().toLowerCase() ?? 'false';
        final titleStr = calMatch.group(4)?.trim() ?? 'Evento';

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
    }

    final vaultMatch = vaultSearchRegex.firstMatch(cleanBuffer.toString());
    if (vaultMatch != null) {
      final tag = vaultMatch.group(0)!;
      _stripTag(tag);

      debugPrint('🔎 [ToolParser] Full vault command matched: $tag');

      if (_isArmed &&
          _allowedTags.contains('<CMD_SYS_VAULT_SRCH:') &&
          !_vaultSearchFired) {
        _vaultSearchFired = true;
        final query = vaultMatch.group(1)?.trim() ?? '';
        debugPrint('🔎 [ToolParser] Vault semantic query extracted: "$query"');
        onVaultSearchDetected?.call(query);
      } else if (!_isArmed || !_allowedTags.contains('<CMD_SYS_VAULT_SRCH:')) {
        debugPrint(
          '🔎 [ToolParser] Vault command ignored because parser is not armed for it.',
        );
      }
    }

    // ── 4. UI Text Formatting (Flicker Prevention) ─────────────────────────

    String uiText = cleanBuffer
        .toString()
        .replaceAll(startVideoTag, '')
        .replaceAll(stopVideoTag, '')
        .replaceAll(geofenceRegex, '')
        .replaceAll(calendarRegex, '')
        .replaceAll(vaultSearchRegex, '');

    // Avoid partial tags appearing in the UI
    uiText = uiText.replaceAll(RegExp(r'<CMD_SYS_LOC_TRG:[^>]*$'), '');
    uiText = uiText.replaceAll(RegExp(r'<CMD_SYS_CAL_EVT:[^>]*$'), '');
    uiText = uiText.replaceAll(RegExp(r'<CMD_SYS_VAULT_SRCH:[^>]*$'), '');

    final possibleTags = [
      startVideoTag,
      stopVideoTag,
      '<CMD_SYS_LOC_TRG:',
      '<CMD_SYS_CAL_EVT:',
      '<CMD_SYS_VAULT_SRCH:',
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
