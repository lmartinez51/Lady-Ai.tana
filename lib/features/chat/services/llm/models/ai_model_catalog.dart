enum ModelSwitchResult {
  success,
  notFound,
  engineError,
  busy,
  alreadyActive,
  notInCatalog,
}

class AiModelInfo {
  final String baseName;
  final String displayName; // Para el BottomSheet (Nombre completo)
  final String shortName; // Para el Pill superior (Nombre ultracorto)

  const AiModelInfo({
    required this.baseName,
    required this.displayName,
    required this.shortName,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AiModelInfo && other.baseName == baseName;
  }

  @override
  int get hashCode => baseName.hashCode;
}

abstract final class AiModelCatalog {
  static const List<AiModelInfo> models = [
    AiModelInfo(
      baseName: 'gemma_4b',
      displayName: 'Gemma-4-E4B-it',
      shortName: 'Gemma-4-E4B-it', // Opciones cortas: 'G4 Base', 'Base 4B'
    ),
    AiModelInfo(
      baseName: 'gemma_4b_variant',
      displayName: 'Gemma-4-E4B-it (Uncensored)',
      shortName: 'Gemma-4 Uncens.', // Opciones cortas: 'G4 Var', 'Var 4B'
    ),
  ];

  static const AiModelInfo defaultModel = AiModelInfo(
    baseName: 'gemma_4b',
    displayName: 'Gemma-4-E4B-it',
    shortName: 'Gemma-4-E4B-it',
  );

  static AiModelInfo? findByBaseName(String baseName) {
    for (var model in models) {
      if (model.baseName == baseName) return model;
    }
    return null;
  }
}
