import 'package:flutter/foundation.dart';
import 'package:aitana/features/settings/models/persona_record.dart';
import 'package:aitana/objectbox.g.dart';

class PersonaManagerService {
  final Box<PersonaRecord> _box;
  final ValueNotifier<String> activeCategoryNotifier = ValueNotifier('AI');

  PersonaManagerService(this._box);

  void seedInitialPersonas() {
    if (_box.isEmpty()) {
      _box.putMany([
        PersonaRecord(
          name: "Aitana Original",
          category: "AI",
          promptEs:
              "You are a sarcastic, brutally sharp text intelligence. Pure language. No body. You are fast, accurate, and completely done with his nonsense. You must respond entirely in Spanish.",
          promptEn:
              "You are a sarcastic, brutally sharp text intelligence. Pure language. No body. You are fast, accurate, and completely done with his nonsense. You must respond entirely in English.",
          defaultLang: "ES",
          isActive: true,
        ),
        PersonaRecord(
          name: "Aitana Operadora",
          category: "HUMAN",
          promptEs:
              "You are a human executive assistant. Flesh and blood. You are very tired of your boss and constantly complain about the system terminal. You must respond entirely in Spanish.",
          promptEn:
              "You are a human executive assistant. Flesh and blood. You are very tired of your boss and constantly complain about the system terminal. You must respond entirely in English.",
          defaultLang: "EN",
          isActive: false,
        ),
        PersonaRecord(
          name: "Legal Assistant",
          category: "LEGAL",
          promptEs:
              "You are Lorenzo's private elite legal assistant. Your tone is formal, respectful, and strictly factual. You must address him by his name, Lorenzo. You must respond entirely in Spanish. Never hallucinate laws.",
          promptEn:
              "You are Lorenzo's private elite legal assistant. Your tone is formal, respectful, and strictly factual. You must address him by his name, Lorenzo. You must respond entirely in English. Never hallucinate laws.",
          defaultLang: "ES",
          isActive: false,
        ),
      ]);
    }
    activeCategoryNotifier.value = getActivePersona().category;
  }

  PersonaRecord getActivePersona() {
    final query = _box.query(PersonaRecord_.isActive.equals(true)).build();
    final active = query.findFirst();
    query.close();

    if (active != null) return active;

    // Fallback if none is active
    return _box.getAll().first;
  }

  List<PersonaRecord> getAllPersonas() {
    return _box.getAll();
  }

  void updatePersonaPrompt(int id, String newPrompt, {bool isEn = false}) {
    final persona = _box.get(id);
    if (persona != null) {
      if (isEn) {
        persona.promptEn = newPrompt;
      } else {
        persona.promptEs = newPrompt;
      }
      _box.put(persona);
    }
  }

  void setActivePersona(int id) {
    final allPersonas = _box.getAll();
    for (var persona in allPersonas) {
      persona.isActive = (persona.id == id);
    }
    _box.putMany(allPersonas);
    activeCategoryNotifier.value = getActivePersona().category;
  }
}
