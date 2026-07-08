# Toph Hands-Free Call Mode Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add an Android-first hands-free voice mode to David's FluffyChat fork for talking with Toph/Hermes in a dedicated Matrix room.

**Architecture:** Extend FluffyChat rather than rebuilding Matrix. The call mode is a new room-scoped UI: STT produces text, text is sent via the existing Matrix room, incoming Toph text is sanitized and spoken via TTS. No audio is sent over the network and no new backend is introduced.

**Tech Stack:** Flutter 3.44.1, FluffyChat fork, `matrix` Dart SDK, `go_router`, Android debug APK, `flutter_tts` for TTS, `speech_to_text` for MVP STT.

---

## Pre-flight Findings

- Fork: `https://github.com/Itzdavid01/fluffychat`
- Branch: `feat/3229-toph-hands-free-call-mode`
- Issue: `https://github.com/Itzdavid01/fluffychat/issues/3229`
- Stock debug APK builds after:
  - reducing Gradle JVM heap from `-Xmx4608m` to `-Xmx2048m`
  - limiting Gradle workers to `2`
  - installing Rust Android targets: `armv7-linux-androideabi`, `aarch64-linux-android`, `i686-linux-android`, `x86_64-linux-android`
- Verified artifact: `build/app/outputs/flutter-apk/app-debug.apk` (~268 MB)

## Existing Code Insertion Points

- Routes live in `lib/config/routes.dart`.
- Chat room route is `/rooms/:roomid` at `lib/config/routes.dart:376-491`.
- Existing chat page resolves a room from `Matrix.of(context).client.getRoomById(roomId)` in `lib/pages/chat/chat.dart:55-89`.
- Existing timeline loading pattern uses `room.getTimeline(onUpdate: ..., onInsert: ...)` in `lib/pages/chat/chat.dart:517-546`.
- Existing text-send pattern uses `room.sendTextEvent(...)` in `lib/pages/chat/chat.dart:636-680`.
- Existing chat popup menu is `lib/widgets/chat_settings_popup_menu.dart`.

## System Guardrails

- Keep this personal AGPL fork AGPL-compliant.
- Android-first only.
- No new public services.
- Do not implement real VoIP.
- Do not introduce always-listening mic behavior in the first pass.
- Prefer hardcoded/minimal MVP configuration before adding a settings system.

---

## Task 1: Build Environment Stabilization Commit

**Objective:** Preserve the build fixes needed for David's Bluefin workstation.

**Files:**
- Modify: `android/gradle.properties`

**Steps:**
1. Confirm `android/gradle.properties` contains:
   ```properties
   org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
   org.gradle.workers.max=2
   ```
2. Run:
   ```bash
   export PATH="$HOME/.cargo/bin:$HOME/.local/share/flutter/bin:/var/home/linuxbrew/.linuxbrew/bin:$PATH"
   flutter build apk --debug --no-pub --no-tree-shake-icons
   ```
3. Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.
4. Commit:
   ```bash
   git add android/gradle.properties docs/plans/2026-07-08-toph-hands-free-call-mode.md
   git commit -m "chore: stabilize local Android debug build"
   git push -u origin HEAD
   ```

---

## Task 2: Add Call Mode Route and Placeholder Screen

**Objective:** Add a reachable call-mode shell for a single Matrix room, without STT/TTS yet.

**Files:**
- Create: `lib/pages/toph_call/toph_call_page.dart`
- Modify: `lib/config/routes.dart`
- Modify: `lib/widgets/chat_settings_popup_menu.dart`

**Implementation notes:**
- Route should be nested under a room: `/rooms/:roomid/toph-call`.
- New page should accept `roomId` and resolve `Room` via `Matrix.of(context).client.getRoomById(roomId)`, mirroring `ChatPage`.
- If room is missing, show a simple error scaffold.
- Placeholder UI should include:
  - app bar title: `Toph Call Mode`
  - room display name/id
  - large center mic placeholder button
  - status text: `Idle`
  - button: `Back to chat`

**Route sketch:**
```dart
GoRoute(
  path: 'toph-call',
  pageBuilder: (context, state) => defaultPageBuilder(
    context,
    state,
    TophCallPage(roomId: state.pathParameters['roomid']!),
  ),
  redirect: loggedOutRedirect,
),
```

**Menu sketch:**
- Add enum value `tophCall` to `ChatPopupMenuActions`.
- Add popup item with `Icons.record_voice_over_outlined` and text `Toph Call Mode`.
- On select: `context.go('/rooms/${widget.room.id}/toph-call');`

**Verification:**
```bash
flutter analyze
flutter build apk --debug --no-pub --no-tree-shake-icons
```
Expected: analyze has no new errors; debug APK builds.

---

## Task 3: Room Timeline and Text-Only Loop

**Objective:** Make call mode useful before audio by sending text to and reading fresh replies from the target room.

**Files:**
- Modify: `lib/pages/toph_call/toph_call_page.dart`

**Implementation notes:**
- Load timeline with `room.getTimeline(onUpdate: ...)` following `ChatController._getTimeline`.
- Display recent visible text messages simply; avoid duplicating full chat bubble complexity.
- Add a temporary text field and send button.
- Send via `room.sendTextEvent(text, parseCommands: false)`.
- Track latest spoken/read event id in memory so old events do not replay when opening the screen.

**Verification:**
```bash
flutter analyze
flutter build apk --debug --no-pub --no-tree-shake-icons
```
Manual later: log in, open a room, enter Toph Call Mode, send a text message.

---

## Task 4: TTS Read-Aloud

**Objective:** Speak fresh Toph/Hermes replies in the call-mode room.

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/pages/toph_call/toph_call_page.dart`
- Create: `lib/pages/toph_call/markdown_speech_sanitizer.dart`
- Create test if test harness is straightforward: `test/pages/toph_call/markdown_speech_sanitizer_test.dart`

**Dependency:**
```yaml
flutter_tts: ^4.2.3
```

**Behavior:**
- Speak only fresh incoming text events from other senders.
- Do not speak David's own messages.
- Strip markdown syntax before speaking:
  - code blocks removed or summarized as `code block omitted`
  - inline code unwrapped
  - bold/italic markers removed
  - links spoken as link text where possible
- Add Stop Speaking button.
- Stop current speech before speaking a newer reply.

**Verification:**
```bash
flutter pub get
flutter analyze
flutter test test/pages/toph_call/markdown_speech_sanitizer_test.dart
flutter build apk --debug --no-pub --no-tree-shake-icons
```

---

## Task 5: Speech Input MVP

**Objective:** Convert David's speech to text and send it as a Matrix message.

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/pages/toph_call/toph_call_page.dart`
- Modify: `android/app/src/main/AndroidManifest.xml` if RECORD_AUDIO permission is not already present.

**Dependency:**
```yaml
speech_to_text: ^7.3.0
```

**Behavior:**
- Request microphone permission through plugin flow.
- Big Start Listening / Stop Listening button.
- Display partial recognized text.
- Send final recognized text via `room.sendTextEvent(finalText, parseCommands: false)`.
- Graceful states: unavailable, listening, processing, no speech, error.

**Verification:**
```bash
flutter pub get
flutter analyze
flutter build apk --debug --no-pub --no-tree-shake-icons
```
Manual device verification required for microphone recognition.

---

## Task 6: Conversation Mode Polish

**Objective:** Make the flow feel hands-free without creating an always-listening privacy problem.

**Files:**
- Modify: `lib/pages/toph_call/toph_call_page.dart`

**Behavior:**
- Toggle: `Conversation Mode`.
- When enabled:
  - listen for one utterance
  - send it
  - wait while Toph responds
  - speak reply
  - re-arm listening after TTS completes
- Add maximum listen timeout.
- Add prominent Exit Call button.
- Add state labels: Idle, Listening, Sending, Waiting for Toph, Speaking, Error.

**Verification:**
```bash
flutter analyze
flutter build apk --debug --no-pub --no-tree-shake-icons
```
Manual device verification required.

---

## Final Acceptance

- [ ] `flutter analyze` passes with no new issues.
- [ ] `flutter build apk --debug --no-pub --no-tree-shake-icons` builds.
- [ ] APK installs on Android device.
- [ ] From a Matrix room, `Toph Call Mode` opens.
- [ ] Voice input sends recognized text into the Matrix room.
- [ ] Toph/Hermes replies are spoken aloud.
- [ ] Old messages are not replayed on open.
- [ ] Other rooms do not trigger TTS.
- [ ] Manual Stop/Exit controls work.

## Known Risks

- `speech_to_text` may depend on Android/Google recognizer availability. If poor, replace with Vosk later.
- TTS voice quality depends on installed Android voices.
- Timeline filtering must avoid replaying history.
- Build is memory-sensitive on this 7 GB RAM system; keep Gradle heap conservative.
- FluffyChat upstream is large; avoid broad refactors.
