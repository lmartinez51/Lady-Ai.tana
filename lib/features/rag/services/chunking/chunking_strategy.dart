abstract class ChunkingStrategy {
  /// Returns true if the paragraph marks a structural boundary in the document.
  bool isBoundary(String paragraph);

  /// Returns the chapter-level context if the paragraph is a chapter boundary.
  /// Should return null or empty if not applicable.
  String? extractChapterContext(String paragraph);

  /// Returns the section-level context (e.g., Article, Section, Rubro) if applicable.
  /// Should return null or empty if not applicable.
  String? extractSectionContext(String paragraph);
}
