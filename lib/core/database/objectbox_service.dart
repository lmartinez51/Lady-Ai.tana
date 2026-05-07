import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:aitana/objectbox.g.dart';
import 'package:aitana/core/domain/entities/chat_session.dart';
import 'package:aitana/features/geofencing/repositories/geofence_repository.dart';
import 'package:aitana/features/settings/models/persona_record.dart';
import 'package:aitana/features/settings/services/persona_manager_service.dart';
import 'package:aitana/features/rag/models/legal_knowledge_chunk.dart';
import 'package:aitana/features/rag/models/legal_document_record.dart';

/// Pairs a retrieved chunk with its in-memory relevance score.
///
/// Returned by [ObjectBoxService.searchLegalContext] so callers can apply
/// a score-threshold gate without needing to re-score the results.
typedef RankedChunk = ({LegalKnowledgeChunk chunk, int score});

class ObjectBoxService {
  // 🌐 EL SINGLETON PRIVADO
  static ObjectBoxService? _instance;

  // 🛡️ EL STORE REAL DE OBJECTBOX
  late final Store _store;

  // 📦 NUESTRA CAJA DE SESIONES
  late final Box<ChatSession> sessionBox;

  // 📦 REPOSITORIO DE GEOCERCAS
  late final GeofenceRepository geofenceRepository;

  // 🎭 GESTOR DE PERSONAS
  late final Box<PersonaRecord> personaBox;
  late final PersonaManagerService personaManager;

  // 📚 RAG: LEGAL KNOWLEDGE
  late final Box<LegalDocumentRecord> legalDocumentBox;
  late final Box<LegalKnowledgeChunk> legalChunkBox;

  /// Cached chunk count — invalidated whenever a document is saved or deleted.
  ///
  /// Avoids hitting ObjectBox on every message just to determine if the legal
  /// library is populated. Gates 0 of the RAG Gatekeeper reads this field.
  int? _cachedChunkCount;

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
    sessionBox = Box<ChatSession>(_store);
    geofenceRepository = GeofenceRepository(_store);
    personaBox = Box<PersonaRecord>(_store);
    personaManager = PersonaManagerService(personaBox);
    personaManager.seedInitialPersonas();
    legalDocumentBox = Box<LegalDocumentRecord>(_store);
    legalChunkBox = Box<LegalKnowledgeChunk>(_store);
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

    // Abrimos el Store real (con fallback de attach para evitar OBX_ERROR 10001)
    late final Store store;
    try {
      store = await openStore(directory: dbPath);
    } catch (e) {
      if (e.toString().contains('10001')) {
        debugPrint(
          '⚠️ [ObjectBox] Store already open (likely by Foreground Service). Attaching...',
        );
        store = Store.attach(getObjectBoxModel(), dbPath);
      } else {
        rethrow;
      }
    }

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

  // ==========================================
  // 📚 OPERACIONES PARA RAG (LEGAL KNOWLEDGE)
  // ==========================================

  Stream<List<LegalDocumentRecord>> watchLegalDocuments() {
    return legalDocumentBox
        .query()
        .order(LegalDocumentRecord_.uploadDate, flags: Order.descending)
        .watch(triggerImmediately: true)
        .map((query) => query.find());
  }

  bool isDocumentExists(String fileName) {
    final query = legalDocumentBox
        .query(LegalDocumentRecord_.fileName.equals(fileName))
        .build();
    final exists = query.findFirst() != null;
    query.close();
    return exists;
  }

  void saveLegalDocumentWithChunks(
    LegalDocumentRecord doc,
    List<LegalKnowledgeChunk> chunks,
  ) {
    _store.runInTransaction(TxMode.write, () {
      legalDocumentBox.put(doc);
      for (var chunk in chunks) {
        chunk.document.target = doc;
      }
      legalChunkBox.putMany(chunks);
    });
    _cachedChunkCount = null; // Invalidate cache after write
  }

  void deleteLegalDocument(int id) {
    _store.runInTransaction(TxMode.write, () {
      final doc = legalDocumentBox.get(id);
      if (doc != null) {
        final chunkIds = doc.chunks.map((c) => c.id).toList();
        legalChunkBox.removeMany(chunkIds);
        legalDocumentBox.remove(id);
      }
    });
    _cachedChunkCount = null; // Invalidate cache after delete
  }

  /// Returns `true` if the legal library contains at least one indexed chunk.
  ///
  /// The count is cached after the first read and invalidated on every write
  /// or delete so subsequent calls are essentially free (no ObjectBox I/O).
  bool get hasLegalKnowledge {
    _cachedChunkCount ??= legalChunkBox.count();
    return (_cachedChunkCount ?? 0) > 0;
  }

  /// Ruthless Nuke: Clears ObjectBox collections and purges physical PDF files to prevent "zombies".
  Future<void> nukeDatabase() async {
    final docs = legalDocumentBox.getAll();

    _store.runInTransaction(TxMode.write, () {
      personaBox.removeAll();
      legalDocumentBox.removeAll();
      legalChunkBox.removeAll();
    });
    _cachedChunkCount = 0;

    try {
      final appDir = await getApplicationDocumentsDirectory();

      // 1. Wipe the designated legal documents folder if it exists
      final legalDir = Directory(p.join(appDir.path, 'legal_docs'));
      if (await legalDir.exists()) {
        await legalDir.delete(recursive: true);
      }

      // 2. Iterate and destroy any zombie PDF files directly in the root directory
      for (final doc in docs) {
        final file = File(p.join(appDir.path, doc.fileName));
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error purging physical zombie documents: $e');
    }
  }

  Future<void> insertLegalChunks(List<LegalKnowledgeChunk> chunks) async {
    legalChunkBox.putMany(chunks);
  }

  List<RankedChunk> searchLegalContext(String queryKeywords, {int limit = 5}) {
    // ── Step 1: Normalize the raw query (mirrors the chunker's normalization) ─
    String normalized = queryKeywords.toLowerCase();
    normalized = normalized.replaceAll(RegExp(r'[áàäâã]'), 'a');
    normalized = normalized.replaceAll(RegExp(r'[éèëê]'), 'e');
    normalized = normalized.replaceAll(RegExp(r'[íìïî]'), 'i');
    normalized = normalized.replaceAll(RegExp(r'[óòöôõ]'), 'o');
    normalized = normalized.replaceAll(RegExp(r'[úùüû]'), 'u');
    normalized = normalized.replaceAll(RegExp(r'[ñ]'), 'n');
    normalized = normalized.replaceAll(RegExp(r'[^\w\s]'), '');

    // ── Preprocessing: Normalize Legal Ordinals ─────────────────────────────
    // Convert written suffixes like "4to", "4vo" into the official "4o".
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(\d+)(to|vo|no|mo|avo)\b'),
      (match) => '${match.group(1)}o',
    );
    // Convert standalone digits following "articulo" or "art" into ordinals.
    // E.g. "articulo 4" -> "articulo 4o". Lookahead ensures no double 'o'.
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b(articulo|art)\s+(\d+)(?!o)\b'),
      (match) => '${match.group(1)} ${match.group(2)}o',
    );
    // ────────────────────────────────────────────────────────────────────────

    // ── Step 2: Unique keyword set & Stop Words filter ──
    final stopWords = {
      'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas', 'de', 'del',
      'a', 'ante', 'con', 'para', 'por', 'segun', 'sin', 'sobre', 'en', 'y', 'o',
      'que', 'dame', 'resumen', 'muestrame', 'ley', 'amparo', 'codigo', 'civil',
      'penal', 'constitucion'
    };

    final keywords = normalized
        .split(RegExp(r'\s+'))
        .where((k) => k.length >= 2 && !stopWords.contains(k))
        .toSet();
    if (keywords.isEmpty) return [];

    // ── Step 3: Build OR condition — match ANY chunk containing ANY keyword ─
    Condition<LegalKnowledgeChunk>? condition;
    for (final keyword in keywords) {
      final containsCondition = LegalKnowledgeChunk_.searchableText.contains(
        keyword,
        caseSensitive: false,
      );
      condition = condition == null
          ? containsCondition
          : condition.or(containsCondition);
    }

    if (condition == null) return [];

    // ── Step 4: Fetch all OR-matching candidates from ObjectBox ───────────
    final query = legalChunkBox.query(condition).build();
    final candidates = query.find();
    query.close();

    if (candidates.isEmpty) return [];

    // ── Step 5 & 6: Weighted scoring ───────────────────────────────────────
    //
    // finalScore = rawScore × authorityWeight
    //
    // This ensures a chunk from a ley (weight 3) with 2 keyword hits (score 6)
    // outranks a doctrina chunk (weight 1) with 5 keyword hits (score 5).
    final scored = candidates.map((chunk) {
      final text = chunk.searchableText;
      final rawScore = keywords.fold<int>(
        0,
        (count, kw) => text.contains(kw) ? count + 1 : count,
      );
      final finalScore = rawScore * chunk.authorityWeight;
      return (chunk: chunk, score: finalScore);
    }).toList()..sort((a, b) => b.score.compareTo(a.score));

    // ── Step 7: Dynamic Diversity Filter (Max-Per-Document Throttling) ─────
    final uniqueDocCount = scored
        .map((r) => r.chunk.document.targetId)
        .toSet()
        .length;

    final effectiveMaxPerDoc = uniqueDocCount == 1
        ? limit
        : (limit / uniqueDocCount).ceil().clamp(2, 4);

    final Map<int, int> docChunkCounts = {};
    final List<RankedChunk> diverseResults = [];

    for (final ranked in scored) {
      if (diverseResults.length >= limit) break;

      final docId = ranked.chunk.document.targetId;
      final currentCount = docChunkCounts[docId] ?? 0;

      if (currentCount < effectiveMaxPerDoc) {
        docChunkCounts[docId] = currentCount + 1;
        diverseResults.add(ranked);
      }
    }

    // ── Step 8: Quality Floor ──────────────────────────────────────────────
    final qualityFiltered = diverseResults.where((r) => r.score >= 2).toList();

    debugPrint('=== RAG RANKING DIAGNOSTICS ===');
    for (var i = 0; i < qualityFiltered.length; i++) {
      final chunk = qualityFiltered[i].chunk;
      final docTitle = chunk.document.target?.fileName ?? 'Unknown';
      debugPrint(
        '#$i | Score: ${qualityFiltered[i].score} | Doc: $docTitle | Weight: ${chunk.authorityWeight}',
      );
    }
    debugPrint('===============================');

    // ── Step 9: Return top-N filtered RankedChunk records (score exposed) ──
    return qualityFiltered;
  }
}
