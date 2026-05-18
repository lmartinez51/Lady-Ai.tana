import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/features/notifications/models/auto_pilot_contact.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AutoPilotWhitelistService {
  static const MethodChannel _channel = MethodChannel(NativeChannels.autoPilot);

  static List<AutoPilotContact> getContacts() {
    final contacts = ObjectBoxService.instance.autoPilotContactBox.getAll();
    contacts.sort(
      (a, b) =>
          a.contactName.toLowerCase().compareTo(b.contactName.toLowerCase()),
    );
    return contacts;
  }

  static Stream<List<AutoPilotContact>> watchContacts() {
    return ObjectBoxService.instance.autoPilotContactBox
        .query()
        .watch(triggerImmediately: true)
        .map((query) {
          final contacts = query.find();
          contacts.sort(
            (a, b) => a.contactName.toLowerCase().compareTo(
              b.contactName.toLowerCase(),
            ),
          );
          return contacts;
        });
  }

  static Future<bool> requestContactsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestContactsPermission') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[AutoPilotWhitelist] Permission error: ${e.message}');
      return false;
    }
  }

  static Future<List<String>> getDeviceContactNames() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getDeviceContactNames',
      );
      return (raw ?? const [])
          .whereType<String>()
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toList();
    } on PlatformException catch (e) {
      debugPrint('[AutoPilotWhitelist] Contact fetch error: ${e.message}');
      return const [];
    }
  }

  static Future<AutoPilotContact> addOrActivateContact(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('Contact name cannot be empty.');
    }

    final box = ObjectBoxService.instance.autoPilotContactBox;
    final normalized = _normalize(cleanName);
    AutoPilotContact? existing;
    for (final contact in box.getAll()) {
      if (_normalize(contact.contactName) == normalized) {
        existing = contact;
        break;
      }
    }

    if (existing != null) {
      existing.isActive = true;
      box.put(existing);
      await syncActiveWhitelist();
      return existing;
    }

    final contact = AutoPilotContact(contactName: cleanName);
    final id = box.put(contact);
    contact.id = id;
    await syncActiveWhitelist();
    return contact;
  }

  static Future<void> setContactActive(
    AutoPilotContact contact,
    bool isActive,
  ) async {
    contact.isActive = isActive;
    ObjectBoxService.instance.autoPilotContactBox.put(contact);
    await syncActiveWhitelist();
  }

  static Future<void> deleteContact(int id) async {
    ObjectBoxService.instance.autoPilotContactBox.remove(id);
    await syncActiveWhitelist();
  }

  static List<String> getActiveContactNames() {
    return ObjectBoxService.instance.autoPilotContactBox
        .getAll()
        .where((contact) => contact.isActive)
        .map((contact) => contact.contactName)
        .toList();
  }

  static Future<void> syncActiveWhitelist() async {
    final activeNames = getActiveContactNames();
    try {
      await _channel.invokeMethod<bool>('setActiveWhitelist', activeNames);
      debugPrint(
        '[AutoPilotWhitelist] Synced ${activeNames.length} active contacts.',
      );
    } on PlatformException catch (e) {
      debugPrint('[AutoPilotWhitelist] Sync error: ${e.message}');
    }
    await LocalLlmService.syncAutoPilotConfig(
      reason: 'whitelist_sync',
      activeWhitelistOverride: activeNames,
    );
  }

  static String normalizeForUi(String value) => _normalize(value);

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .trim();
  }
}
