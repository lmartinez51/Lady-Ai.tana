import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:aitana/objectbox.g.dart';
import 'package:aitana/core/domain/entities/chat_session.dart';
import 'package:aitana/features/geofencing/repositories/geofence_repository.dart';

class ObjectBoxService {
  // 🌐 EL SINGLETON PRIVADO
  static ObjectBoxService? _instance;

  // 🛡️ EL STORE REAL DE OBJECTBOX
  late final Store _store;

  // 📦 NUESTRA CAJA DE SESIONES
  late final Box<ChatSession> sessionBox;

  // 📦 REPOSITORIO DE GEOCERCAS
  late final GeofenceRepository geofenceRepository;

  // 🛡️ GETTER PÚBLICO SEGURO
  static ObjectBoxService get instance {
    if (_instance == null) {
      throw Exception(
        "ObjectBoxService no ha sido inicializado. Llama a create() en el main.",
      );
    }
    return _instance!;
  }

  // Constructor privado
  ObjectBoxService._create(this._store) {
    // Vinculamos la caja al iniciar
    sessionBox         = Box<ChatSession>(_store);
    geofenceRepository = GeofenceRepository(_store);
  }

  /// Create an instance of ObjectBoxService to use throughout the app.
  static Future<void> create() async {
    // Patrón Idempotente: Si ya se inicializó, no hacemos nada y salimos.
    if (_instance != null) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docsDir.path, "aitana_core_v1");

    // Ensure directory exists
    final dir = Directory(dbPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Abrimos el Store real
    final store = await openStore(directory: dbPath);

    _instance = ObjectBoxService._create(store);
  }

  // Reemplaza el void close() actual por esto:
  static void closeStore() {
    if (_instance != null) {
      _instance!._store.close(); // Cerramos el store físico
      _instance = null; // ¡Crucial para evitar el deadlock al reabrir!
      debugPrint("📦 ObjectBox cerrado y singleton liberado de forma segura.");
    }
  }

  // ==========================================
  // 🛠️ OPERACIONES CRUD PARA EL HISTORIAL
  // ==========================================

  // 1. Guardar o actualizar una sesión
  int saveSession(ChatSession session) {
    session.updatedAt = DateTime.now();
    return sessionBox.put(
      session,
    ); // put() inserta si id es 0, o actualiza si ya existe
  }

  // 2. Obtener todas las sesiones (ordenadas por fecha descendente)
  List<ChatSession> getAllSessions() {
    return sessionBox
        .query()
        .order(ChatSession_.updatedAt, flags: Order.descending)
        .build()
        .find();
  }

  // 3. Obtener una sesión por ID
  ChatSession? getSession(int id) {
    return sessionBox.get(id);
  }

  // 4. Eliminar una sesión
  bool deleteSession(int id) {
    return sessionBox.remove(id);
  }

  /// Returns all sessions sorted so that pinned entries always appear first.
  ///
  /// ObjectBox's Dart query builder does not support composite ORDER BY
  /// (e.g. `isPinned DESC, updatedAt DESC`) in a single query. We work around
  /// this by running two separate queries—one for pinned, one for unpinned—
  /// each sorted by [updatedAt] descending, and then concatenating the results.
  List<ChatSession> getAllSessionsSorted() {
    final pinned = sessionBox
        .query(ChatSession_.isPinned.equals(true))
        .order(ChatSession_.updatedAt, flags: Order.descending)
        .build()
        .find();

    final unpinned = sessionBox
        .query(ChatSession_.isPinned.equals(false))
        .order(ChatSession_.updatedAt, flags: Order.descending)
        .build()
        .find();

    return [...pinned, ...unpinned];
  }

  /// Persists [session] without modifying its [updatedAt] timestamp.
  ///
  /// Unlike [saveSession], this method is intended for metadata-only changes
  /// (pin toggle, title rename) where mutating the "last updated" date would
  /// produce incorrect sort order.
  int updateSession(ChatSession session) {
    return sessionBox.put(session);
  }
}
