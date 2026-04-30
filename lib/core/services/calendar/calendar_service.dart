import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart';

class CalendarService {
  // Singleton pattern for memory persistence
  static final CalendarService _instance = CalendarService._internal();
  factory CalendarService() => _instance;
  CalendarService._internal();

  final DeviceCalendarPlugin _deviceCalendarPlugin = DeviceCalendarPlugin();

  // Cache to avoid redundant native plugin calls
  List<Calendar>? _cachedCalendars;

  /// Internal helper to ensure permissions are granted.
  Future<bool> _ensurePermissions() async {
    var permissionsGranted = await _deviceCalendarPlugin.hasPermissions();
    if (permissionsGranted.isSuccess && !(permissionsGranted.data ?? false)) {
      permissionsGranted = await _deviceCalendarPlugin.requestPermissions();
    }
    return permissionsGranted.isSuccess && (permissionsGranted.data ?? false);
  }

  /// Internal helper to find the best writable calendar based on selection logic.
  Future<Calendar?> _getWritableCalendar() async {
    // Refresh cache if null
    if (_cachedCalendars == null) {
      final result = await _deviceCalendarPlugin.retrieveCalendars();
      if (result.isSuccess && result.data != null) {
        _cachedCalendars = result.data;
      }
    }

    if (_cachedCalendars == null || _cachedCalendars!.isEmpty) return null;

    final writableCalendars = _cachedCalendars!
        .where((c) => c.isReadOnly == false)
        .toList();

    if (writableCalendars.isEmpty) return null;

    // Smart Selection Logic:
    // 1. Prioritize Google Account email (contains '@')
    // 2. Prioritize calendars named "Events"
    // 3. Fallback to the first writable one
    return writableCalendars.firstWhere(
      (c) => c.accountName?.contains('@') == true,
      orElse: () => writableCalendars.firstWhere(
        (c) => c.name?.toLowerCase() == 'events',
        orElse: () => writableCalendars.first,
      ),
    );
  }

  Future<String> addEvent(
    String title,
    DateTime startTime, {
    int? reminderMinutes,
    bool isAllDay = false,
    bool isBirthday = false,
  }) async {
    if (title.trim().isEmpty) {
      return "Error: El título del evento no puede estar vacío.";
    }

    try {
      if (!await _ensurePermissions()) {
        return "Error: Permiso de calendario denegado.";
      }

      final calendar = await _getWritableCalendar();
      if (calendar == null || calendar.id == null) {
        return "Error: No se encontró un calendario donde escribir.";
      }

      final effectiveTitle = isBirthday ? "🎂 $title" : title;
      final effectiveAllDay = isBirthday ? true : isAllDay;
      final endTime = effectiveAllDay
          ? startTime
          : startTime.add(const Duration(hours: 1));

      // 1️⃣ PRIMERO CALCULAMOS LOS TIEMPOS REALES (NUESTRA LÓGICA PERSONALIZADA)
      // 🔔 LÓGICA MAESTRA: "EL EFECTO LORENZO" (Evento de noche, Alarma de día)
      int? effectiveReminder;
      DateTime finalStart = startTime;
      DateTime finalEnd = endTime;
      bool finalAllDay = effectiveAllDay;

      if (isBirthday) {
        // Cumpleaños: Siguen igual (11:00 PM del día anterior)
        effectiveReminder = 60;
      } else if (finalAllDay) {
        // ✅ Tareas "All Day" con el nuevo Hack:
        // Ponemos el evento a las 11:00 PM para que no estorbe visualmente.
        finalStart = DateTime(
          startTime.year,
          startTime.month,
          startTime.day,
          23,
          0,
        );
        finalEnd = finalStart.add(const Duration(minutes: 15));
        finalAllDay = false;

        // Alarma al mediodía: 11:00 PM - 12:00 PM = 11 horas = 660 minutos.
        effectiveReminder = 660;
      } else {
        effectiveReminder = reminderMinutes;
      }

      // 2️⃣ DESPUÉS BUSCAMOS DUPLICADOS USANDO EL "FINAL START" (12:00 PM o 00:00)
      final checkStart = finalStart.subtract(const Duration(minutes: 1));
      final checkEnd = finalStart.add(const Duration(minutes: 1));
      final existingEvents = await _deviceCalendarPlugin.retrieveEvents(
        calendar.id,
        RetrieveEventsParams(startDate: checkStart, endDate: checkEnd),
      );

      if (existingEvents.isSuccess && existingEvents.data != null) {
        final isDuplicate = existingEvents.data!.any(
          (e) =>
              e.title == effectiveTitle &&
              e.start?.millisecondsSinceEpoch ==
                  TZDateTime.from(finalStart, local).millisecondsSinceEpoch,
        );

        if (isDuplicate) {
          return "Aviso: Este evento ya existe en tu calendario.";
        }
      }

      // 3️⃣ FINALMENTE CREAMOS EL EVENTO
      final newEvent = Event(
        calendar.id,
        title: effectiveTitle,
        start: TZDateTime.from(finalStart, local),
        end: TZDateTime.from(finalEnd, local),
        allDay: finalAllDay,
      );

      if (effectiveReminder != null && effectiveReminder != -1) {
        newEvent.reminders = [Reminder(minutes: effectiveReminder)];
      }

      if (isBirthday) {
        newEvent.recurrenceRule = RecurrenceRule(RecurrenceFrequency.Yearly);
      }

      final result = await _deviceCalendarPlugin.createOrUpdateEvent(newEvent);
      if (result?.isSuccess == true) {
        return "Éxito: El evento '$effectiveTitle' ha sido guardado.";
      } else {
        final errorMsg = result?.errors.map((e) => e.errorMessage).join(', ');
        return "Error: ${errorMsg?.isNotEmpty == true ? errorMsg : 'Error desconocido'}";
      }
    } catch (e) {
      return "Excepción: $e";
    }
  }

  /// Extracts today's events for system prompt context.
  Future<List<String>> getTodayEvents() async {
    List<String> formattedEvents = [];

    try {
      if (!await _ensurePermissions()) {
        return ['[Sistema: Sin acceso al calendario nativo]'];
      }

      // Dynamic retrieval to ensure context is fresh
      final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
      if (!calendarsResult.isSuccess || calendarsResult.data == null) {
        return [];
      }

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      final endOfDay = startOfDay.add(const Duration(days: 1));

      // Include all calendars (Read-only + Writable) for full context
      for (var calendar in calendarsResult.data!) {
        if (calendar.id == null) continue;

        final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
          calendar.id,
          RetrieveEventsParams(startDate: startOfDay, endDate: endOfDay),
        );

        if (eventsResult.isSuccess && eventsResult.data != null) {
          for (var event in eventsResult.data!) {
            if (event.title != null) {
              formattedEvents.add(_formatEventString(event));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('🔴 [CalendarService] Error: $e');
    }

    return formattedEvents;
  }

  /// Helper to format event objects into strings for the AI context.
  String _formatEventString(Event event) {
    String timeStr = "Todo el día";
    if (event.start != null && event.allDay != true) {
      final localStart = DateTime.fromMillisecondsSinceEpoch(
        event.start!.millisecondsSinceEpoch,
      ).toLocal();
      timeStr =
          "${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}";
    }
    return "- [$timeStr] ${event.title}";
  }
}
