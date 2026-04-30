/// Holds the user-configurable sampler parameters for a single inference
/// session. This object is created in the UI layer, stored by
/// [LocalLlmService], and serialized into the flat [Map] that the
/// MethodChannel bridge consumes on the Kotlin side.
///
/// [enableThinking] is a **Dart-side-only** flag – it is NOT read by the
/// native engine. Instead, the Dart layer uses it to conditionally append
/// the Gemma 4 control token `<|think|>` to the system prompt before
/// dispatching the MethodChannel call.
class LlmInferenceParams {
  /// Controls the randomness of the output distribution.
  /// Range: 0.0 (deterministic) → 2.0 (very random). Default: 0.4.
  final double temperature;

  /// Limits the candidate token pool to the top-K most likely tokens.
  /// Range: 1 → 100. Default: 30.
  final int topK;

  /// Nucleus sampling threshold. Only tokens whose cumulative probability
  /// reaches [topP] are considered. Range: 0.0 → 1.0. Default: 0.85.
  final double topP;

  /// When `true`, the Dart layer injects `<|think|>` at the end of the
  /// system prompt, activating Gemma 4's internal reasoning channel.
  /// The native engine never sees this flag directly.
  final bool enableThinking;

  const LlmInferenceParams({
    this.temperature = 0.45,
    this.topK = 40,
    this.topP = 0.90,
    this.enableThinking = false,
  });

  /// Serializes this object into a flat [Map<String, dynamic>] suitable
  /// for merging into a MethodChannel payload via the spread operator.
  ///
  /// Example:
  /// ```dart
  /// await _channel.invokeMethod('sendMessage', {
  ///   'prompt': prompt,
  ///   ..._currentParams.toMap(),
  /// });
  /// ```
  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'top_k': topK,
    'top_p': topP,
    // enable_thinking is included for logging/debugging on the Kotlin side,
    // but the native handler intentionally ignores it.
    'enable_thinking': enableThinking,
  };

  @override
  String toString() =>
      'LlmInferenceParams(temp=$temperature, topK=$topK, topP=$topP, '
      'thinking=$enableThinking)';
}
