# Aitana

Aitana is an advanced, privacy-first AI assistant built with Flutter and powered by local Large Language Models (LLMs) using LiteRT on Android. Aitana is designed to be a highly capable on-device assistant with zero reliance on cloud LLM APIs for its core reasoning, ensuring maximum privacy and offline capability.

## Key Features

- **Local LLM Inference**: Runs Google's Gemma models directly on-device using LiteRT, with support for hot-swapping between different model variants (e.g., standard assistant vs. "Real Assistant" persona).
- **Advanced Context Management**: Multi-model prompt routing architecture that dynamically injects calendar, time, and persistent memory context into the prompt while maintaining distinct personas.
- **Intent Interceptor Architecture**: Pre-processes user inputs using regular expressions (with robust support for Spanish enclitic pronouns) to inject system hints and optimize LLM reasoning.
- **Calendar & Task Management**: Parses secure `<CMD_SYS_CAL_EVT>` tags from LLM responses to trigger native Android calendar and alarm APIs via MethodChannels.
- **Tool Gating & Injection Security**: Implements a "Smart System Terminal Protocol" that prevents unauthorized or hallucinated tool calls by arming the response parser only when specific system hints are present in the context.
- **Hybrid Geofencing System**: Total synchronization between native Android Geofencing APIs and local ObjectBox persistence. Features a robust two-way handshake, background event processing, idempotency guards, and interactive developer controls.
- **OOM Blocking Architecture ("The Armor")**: A state-of-the-art UI blocking mechanism that prevents Out of Memory (OOM) crashes by freezing interactions and displaying system lock overlays during high-RAM LLM operations.
- **Persistent Foreground Services**: Implements a robust background task lifecycle using `flutter_foreground_task` to maintain surveillance capabilities and system-level monitoring even when the app is in the background.
- **Hacker-Themed DevTools**: An advanced, actionable developer dashboard accessible via long-press triggers, featuring geofence logs, API inspectors, and a "Kill Switch" for the surveillance engine.
- **Clean Architecture**: Built on solid principles with a feature-driven design, ensuring separation of concerns between UI, domain logic, and native platform integrations.

## Tech Stack

- **Frontend**: Flutter & Dart
- **Backend / Platform**: Android (Kotlin)
- **Local AI**: LiteRT (TensorFlow Lite for Runtimes)
- **Persistence**: ObjectBox (Fast Edge Database for Dart & Kotlin)

## Project Structure

- `lib/features/chat/`: Core chat interface, specialized LLM sub-services (`PromptManager`, `ToolParser`), and input components.
- `lib/core/theme/`: Shared styling, including the `SystemLockOverlay` ("Armor").
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

4. **Run the app:**
   ```bash
   flutter run
   ```

## Architecture Notes
- **Modular Service Layer**: Business logic for prompt construction (`PromptManager`) and tag parsing (`ToolParser`) is decoupled from the inference orchestration, adhering to SRP.
- **Secure Tool Gating**: Uses an `IntentInterceptor` to identify user requests for hardware or system tools and injects specific authorizations into the prompt. The `ToolParser` is dynamically armed for each turn, ensuring that the LLM cannot trigger events unless explicitly authorized by the preceding system hint.
- **Holy Grail UI Pattern**: Chat history uses an optimized `ListView.builder` with `reverse: true`, ensuring $O(1)$ visual updates and native keyboard interaction without list cloning.
- **Geofencing State**: Geofence metadata is managed locally via ObjectBox to ensure consistency with Android's system-level geofence triggers, surviving device reboots and app restarts.

## Testing & Compatibility

The application, including its core LiteRT local LLM inference engine and native geofencing services, has been actively tested and verified on the following hardware:

- **Google Pixel 10 Pro**: Fully verified for model hot-swapping, concurrent tool execution, and background geofence processing.
