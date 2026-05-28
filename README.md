# Aitana

Aitana is an advanced, privacy-first AI assistant built with Flutter and powered by local Large Language Models (LLMs) using LiteRT on Android. Aitana is designed to be a highly capable on-device assistant with zero reliance on cloud LLM APIs for its core reasoning, ensuring maximum privacy and offline capability.

## Key Features

- **Local LLM Inference**: Runs Google's **Gemma-4-E4B-it** models directly on-device using LiteRT, with support for hot-swapping between the standard assistant and the **Gemma-4-E4B-it-Uncensored** variant.
- **Advanced Context Management**: Multi-model prompt routing architecture that dynamically injects calendar, time, and persistent memory context into the prompt while maintaining distinct personas.
- **Intent Interceptor Architecture**: Pre-processes user inputs using regular expressions (with robust support for Spanish enclitic pronouns) to inject system hints and optimize LLM reasoning.
- **Calendar & Task Management**: Parses secure `<CMD_SYS_CAL_EVT>` tags from LLM responses to trigger native Android calendar and alarm APIs via MethodChannels.
- **Tool Gating & Injection Security**: Implements a "Smart System Terminal Protocol" that prevents unauthorized or hallucinated tool calls by arming the response parser only when specific system hints are present in the context.
- **Hybrid Geofencing System**: Total synchronization between native Android Geofencing APIs and local ObjectBox persistence. Features a robust two-way handshake, background event processing, idempotency guards, and **Reboot Survival** (automatic restoration of OS geofences on device startup) plus **Auto-Wake** logic for background surveillance.
- **OOM Blocking Architecture ("The Armor")**: A state-of-the-art UI blocking mechanism that prevents Out of Memory (OOM) crashes by freezing interactions and displaying system lock overlays during high-RAM LLM operations.
- **Contextual Actions**: Implements a premium, glassmorphic long-press contextual menu for chat messages to facilitate actions like copying text.
- **Persistent Foreground Services**: Implements a robust background task lifecycle using `flutter_foreground_task` to maintain surveillance capabilities and system-level monitoring even when the app is in the background.
- **Legal RAG (Retrieval-Augmented Generation)**: High-performance offline document library with intelligent PDF extraction and **Strategy-based Semantic Chunking**. Uses a hierarchical authority model and specialized parsers for different legal document types (Laws, Jurisprudence, etc.) to inject context directly into LLM prompts.
- **Speculative Decoding (MTP)**: Optimized LiteRT inference using Multi-Token Prediction for **Gemma-4-E4B-it** models, significantly reducing latency on supported hardware while maintaining precision.
- **Persona Management Architecture**: A sophisticated system that allows dynamic switching between distinct AI identities (e.g., Legal Advisor, Technical Architect). Each persona carries its own system prompt, language preferences, and tool access rules. Enforced by a single-active-persona invariant (`_enforceSingleActivePersona`) that self-repairs database corruption on startup and after every `setActivePersona()` call.
- **Voice Cold-Start Activation**: On app cold-start triggered by a voice command, the native `checkWakeSource` MethodChannel is queried immediately. If positive, the engine forces the AI persona and sets `isWokenByVoiceOnStartup`, ensuring the assistant responds contextually from the very first frame.
- **Resilient Engine Startup**: `initModel()` is now wrapped in a 30-second timeout safety net. If the native LiteRT engine hangs (e.g., OOM before allocation, corrupted model file), the app launches in a graceful degraded mode instead of hanging on a blank screen.
- **Readiness Earcon & Speech Gate**: On recording start, the app fires a native Android `ToneGenerator` beep (via `playReadinessEarcon` MethodChannel) to give the user a clear audio cue that the microphone is live. The VAD speech gate is then dynamically computed from the earcon duration plus a configurable tail buffer, replacing the old static `_vadPreRollMs` constant. A `WavStartTrimmer` service post-processes the raw WAV file to strip the earcon artifact before sending audio to the LLM pipeline.
- **Same-AI Persona Fallback**: When a voice wake event occurs but the active persona is already AI, the reactive `_onPersonaCategoryChanged` notifier is never fired. A dedicated fallback path now explicitly calls `_syncPersonaRuntimeAndMaybeGreet` via the `nexus-same-ai` source, ensuring the greeting is always dispatched regardless of whether a persona category change occurred.
- **Multimodal Personal Vault**: A secure, local-first repository for user images and documents. It features a high-contrast, agnostic data extraction pipeline where images are parsed into a strict flat JSON containing the `"key_identifiers"` key. This captures distinct alphanumeric tracking numbers, serial codes, invoice IDs, proper nouns, and quantities across any image type. These identifiers are indexed and matched using a high-precision **Hybrid Search Engine** that combines a custom lexical scoring system (exact and token-based field matching) with vector ranking scores against the local HNSW vector database for maximum recall of alphanumeric strings and semantic visuals.
- **Clean Architecture**: Built on solid principles with a feature-driven design, ensuring separation of concerns between UI, domain logic, and native platform integrations.

## Tech Stack

- **Frontend**: Flutter & Dart
- **Backend / Platform**: Android (Kotlin)
- **Local AI**: LiteRT (TensorFlow Lite for Runtimes) powering a specialized twin-model local pipeline. It utilizes **Gemma-4** for core reasoning and vision tasks, and **`embeddinggemma-300m.tflite`** as the dedicated local embedding model for the 768-dimension semantic vector layout.
- **Persistence**: ObjectBox (Fast Edge Database for Dart & Kotlin)

## Project Structure

- `lib/features/chat/`: Core chat interface, specialized LLM sub-services (`PromptManager`, `ToolParser`), input components, and audio utilities (`WavStartTrimmer`).
- `lib/features/rag/`: Document ingestion, PDF processing with Syncfusion, and semantic text chunking logic.
- `lib/features/settings/`: Core persona management and application-wide configuration services.
- `lib/features/vault/`: Multimodal storage layer, HNSW vector search implementation, and image analysis models.
- `lib/core/theme/`: Shared styling, including the `SystemLockOverlay` ("Armor").
- `lib/core/ui/`: Centralized UI utility components, including `AppSnackBars` — a unified snackbar factory providing consistent success, warning, and error feedback across all screens.
- `lib/core/constants/`: Centralized native communication channels and shared identifiers.
- `android/app/src/main/kotlin/...`: Native Android implementation for LiteRT tools, GeofenceBroadcastReceiver, and MethodChannel bridges.

## Getting Started

### Prerequisites
- Flutter SDK (latest stable)
- Android Studio with NDK installed (for LiteRT and ObjectBox bindings)
- A physical Android device with substantial RAM (recommended 8GB+) for running the Gemma models locally.

### Installation

1. **Clone the repository:**
   ```bash
   git clone <repository_url> aitana
   cd aitana
   ```

2. **Fetch dependencies:**
   ```bash
   flutter pub get
   ```

3. **Model Setup:**
   Ensure the necessary LiteRT model files are placed in the appropriate assets or device storage directory as expected by the `LocalLlmService`. 
   *Note:* Local `.tflite` binary models (such as `embeddinggemma-300m.tflite`) are excluded from Git version control via `.gitignore` due to size constraints and must be seeded manually into the appropriate assets framework directory before running the app.

4. **Run the app:**
   ```bash
   flutter run
   ```

## Architecture Notes
- **Modular Service Layer**: Business logic for prompt construction (`PromptManager`) and tag parsing (`ToolParser`) is decoupled from the inference orchestration, adhering to SRP.
- **Secure Tool Gating**: Uses an `IntentInterceptor` to identify user requests for hardware or system tools and injects specific authorizations into the prompt. The `ToolParser` is dynamically armed for each turn, ensuring that the LLM cannot trigger events unless explicitly authorized by the preceding system hint.
- **Unified MoE Model Routing**: `PersonaThemeRouter.getModelBaseName()` is the single source of truth for mapping a persona category to its target model base name, used both at startup (in `main.dart`) and at runtime during persona switches.
- **Holy Grail UI Pattern**: Chat history uses an optimized `ListView.builder` with `reverse: true`, ensuring $O(1)$ visual updates and native keyboard interaction without list cloning.
- **Geofencing State**: Geofence metadata is managed locally via ObjectBox to ensure consistency with Android's system-level geofence triggers, surviving device reboots and app restarts.
- **Strategy-Based RAG Chunking**: Implements a `ChunkingStrategy` factory pattern that handles structural integrity (articles/chapters/rubros) differently based on the document type, ensuring high-fidelity retrieval for Mexican legal texts.
- **Hardware-Accelerated Inference**: Leverages GPU-bound LiteRT execution with Speculative Decoding to provide a responsive, local-first AI experience on modern mobile hardware.
- **Multimodal Semantic Storage & Hybrid Retrieval**: The Personal Vault uses on-device image analysis and text extraction to build a semantic map of the user's data. Search queries are resolved using a twin-path hybrid retrieval process: a semantic vector search against the local HNSW index combined with a weighted, tokenized lexical matching engine over visual descriptions, OCR texts, and extracted key identifiers. Results are prioritized via a unified ranking score to handle both conceptual and exact alphanumeric queries.

## Testing & Compatibility

The application, including its core LiteRT local LLM inference engine and native geofencing services, has been actively tested and verified on the following hardware:

- **Google Pixel 10 Pro**: Fully verified for model hot-swapping, concurrent tool execution, and background geofence processing.
