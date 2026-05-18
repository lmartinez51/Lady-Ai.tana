import 'dart:convert';
import 'dart:io';

import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/chat/services/llm/prompts/prompt_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AitanaConfigBridge {
  static const MethodChannel _channel = MethodChannel(NativeChannels.aiCore);

  static Future<void> syncAutoPilotConfig({
    required String reason,
    required String modelBaseName,
    required String languageCode,
    List<String>? activeWhitelistOverride,
  }) async {
    final configPath = await _channel.invokeMethod<String>(
      'getAitanaConfigPath',
    );
    if (configPath == null || configPath.isEmpty) {
      throw StateError('Native config path is unavailable.');
    }

    final modelPath = await _channel.invokeMethod<String>(
      'resolveModelPathForConfig',
      {'modelName': modelBaseName},
    );
    if (modelPath == null || modelPath.isEmpty) {
      throw StateError('Native model path is unavailable.');
    }

    final modelFile = File(modelPath);
    if (!modelFile.existsSync()) {
      throw StateError('Resolved model file does not exist: $modelPath');
    }

    final activePersona = ObjectBoxService.instance.personaManager
        .getActivePersona();
    final activeWhitelist = List<String>.from(
      activeWhitelistOverride ?? _readActiveWhitelistFromObjectBox(),
    );
    activeWhitelist.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final systemPrompt = PromptManager.buildAutoReplySystemPromptForConfig(
      languageCode: languageCode,
    );

    final payload = <String, dynamic>{
      'schema_version': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'sync_reason': reason,
      'model': {
        'base_name': modelBaseName,
        'absolute_path': modelPath,
      },
      'whatsapp_operator': {
        'language': languageCode,
        'persona_name': activePersona.name,
        'persona_category': activePersona.category,
        'system_prompt': systemPrompt,
      },
      'whitelist': activeWhitelist,
      'whitelist_normalized': activeWhitelist.map(_normalize).toList(),
    };

    await _atomicWriteJson(configPath, payload);
    debugPrint(
      '[AitanaConfigBridge] Synced aitana_config.json '
      '($reason, ${activeWhitelist.length} contacts).',
    );
  }

  static List<String> _readActiveWhitelistFromObjectBox() {
    return ObjectBoxService.instance.autoPilotContactBox
        .getAll()
        .where((contact) => contact.isActive)
        .map((contact) => contact.contactName.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  static Future<void> _atomicWriteJson(
    String configPath,
    Map<String, dynamic> payload,
  ) async {
    final target = File(configPath);
    final parent = target.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    final tmp = File('$configPath.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    await tmp.writeAsString('${encoder.convert(payload)}\n', flush: true);

    try {
      await tmp.rename(configPath);
    } on FileSystemException {
      if (target.existsSync()) {
        await target.delete();
      }
      await tmp.rename(configPath);
    }
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .trim();
  }
}
