# Toph Call Hands-Free Layout Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Redesign Toph Call Mode so it feels like a phone-call/voice interface instead of a normal chat screen with a small mic button.

**Architecture:** Keep the existing Matrix/STT/TTS logic, but reorganize the widget tree around a call-first control surface: large central/bottom mic control, clear state panel, compact transcript, and accessible interrupt/cancel controls. Do not change Matrix transport, TTS filtering, or speech recognition engine in this layout pass.

**Tech Stack:** Flutter/Dart, FluffyChat existing theme/localization, `TophCallPage`, Material widgets, current `speech_to_text` and `flutter_tts` state.

---

## Real-Device Observations

From David's phone testing:

1. The app installs separately and can send messages.
2. Call Mode exists, but feels incomplete.
3. The mic button location is not hands-free / phone-call friendly.
4. Speech detection/send path needed fixes; latest expected behavior is send-once.
5. TTS works, but needs its own separate filtering/edit-stabilization plan.

This plan addresses only observation #2 and #3: **layout and interaction ergonomics**.

---

## Current Layout Problem

Current `TophCallPage` layout is chat-first:

```text
AppBar: Toph Call Mode
Room header with room name + tiny-ish mic button on the right
Speech status text
Recognized text card
Stop speaking button if active
Divider
Large message list
Text input row
Back to chat button
```

The primary voice control is in the **top-right header**:

```dart
IconButton(
  iconSize: 48,
  onPressed: _isSending ? null : _startListening,
  icon: Icon(Icons.mic),
)
```

That is not good for:

- one-handed phone use
- quick tap while walking
- eyes-off interaction
- thumb reach
- call-like mental model

---

## Desired Layout

The screen should prioritize voice state and controls:

```text
┌─────────────────────────────┐
│ Toph Call              Close │
├─────────────────────────────┤
│                             │
│        State label           │
│    Listening / Speaking      │
│                             │
│    Detected words card       │
│    or compact latest reply   │
│                             │
│    [small transcript area]   │
│                             │
├─────────────────────────────┤
│      [ STOP SPEAKING ]       │  only when speaking
│                             │
│         BIG MIC BUTTON       │
│       Tap to speak/stop      │
│                             │
│  Cancel     Type fallback    │
└─────────────────────────────┘
```

The primary control should be reachable in the lower third of the screen.

---

## Design Principles

1. **Voice first, transcript second**
   - The transcript is useful, but it should not dominate the screen.

2. **One obvious action**
   - Idle: big mic says `Tap to speak`.
   - Listening: big stop button says `Stop & send`.
   - Sending: disabled/loading.
   - Speaking: interrupt button is obvious.

3. **Large touch targets**
   - Primary mic/stop button should be roughly 96–128dp diameter.
   - Secondary actions can be smaller but still clear.

4. **State must be visible at a glance**
   - Use large labels and icon/color state, not just tiny status text.

5. **Do not add hands-free automation yet**
   - No auto-listen after TTS completes in this pass.
   - No wake word.
   - No always-listening loop.

6. **Keep text fallback**
   - But move it behind a lower-priority affordance or compact input area.

---

## Task 1: Add a Call State Model Helper

**Objective:** Make the layout derive from one clear visual state instead of scattered booleans.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Add a private enum near `_TophCallPageState`:

```dart
enum _CallVisualState {
  idle,
  listening,
  sending,
  speaking,
  error,
  speechUnavailable,
}
```

Add helper getter:

```dart
_CallVisualState get _callVisualState {
  if (_speechError != null) return _CallVisualState.error;
  if (!_speechAvailable) return _CallVisualState.speechUnavailable;
  if (_isSending) return _CallVisualState.sending;
  if (_isListening) return _CallVisualState.listening;
  if (_isSpeaking) return _CallVisualState.speaking;
  return _CallVisualState.idle;
}
```

Add label/icon helpers:

```dart
String _primaryStateLabel(BuildContext context) {
  switch (_callVisualState) {
    case _CallVisualState.idle:
      return 'Ready';
    case _CallVisualState.listening:
      return 'Listening...';
    case _CallVisualState.sending:
      return 'Sending...';
    case _CallVisualState.speaking:
      return 'Toph is speaking';
    case _CallVisualState.error:
      return _speechError ?? 'Speech error';
    case _CallVisualState.speechUnavailable:
      return 'Speech unavailable';
  }
}
```

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

---

## Task 2: Replace Header Mic with Large Bottom Call Control

**Objective:** Move the mic/stop action from the top-right header to a large bottom-center control.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Remove the mic `IconButton` from the room header row.

Create helper widget:

```dart
Widget _buildPrimaryCallControl(BuildContext context) {
  final state = _callVisualState;

  final bool enabled = state != _CallVisualState.sending &&
      state != _CallVisualState.speechUnavailable;
  final bool isStop = state == _CallVisualState.listening;

  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 120,
        height: 120,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            backgroundColor: isStop
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
          onPressed: !enabled
              ? null
              : isStop
                  ? _stopAndSend
                  : _startListening,
          child: Icon(
            isStop ? Icons.stop : Icons.mic,
            size: 56,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        isStop ? 'Stop & send' : 'Tap to speak',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ],
  );
}
```

Add it near the bottom of the screen above the text fallback.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

Manual visual check on phone:

- primary mic/stop control is in the lower third
- easy to hit with thumb
- top-right header no longer contains the main mic action

---

## Task 3: Create a State/Preview Panel

**Objective:** Make state and recognized words readable without scanning the chat transcript.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Create helper:

```dart
Widget _buildCallStatusPanel(BuildContext context) {
  return Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            _primaryStateLabel(context),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          if (_recognizedText.isNotEmpty)
            Text(
              _recognizedText,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            Text(
              'Speak naturally. Toph will reply in this room.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
        ],
      ),
    ),
  );
}
```

Keep the `Send detected words` fallback, but move it into the panel only when `_recognizedText.isNotEmpty` and not sending.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

Manual visual check:

- state label is obvious
- recognized words are centered and readable
- no tiny status-only row required

---

## Task 4: Compact the Transcript Area

**Objective:** Keep transcript available but secondary.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Change the body structure to use a smaller transcript container:

```dart
Expanded(
  flex: 2,
  child: _buildCompactTranscript(context, events, matrixLocals),
),
_buildBottomControls(context),
```

A simple first version can keep the existing `ListView.builder`, but wrap it in a card/container and reduce vertical dominance.

Preferred helper:

```dart
Widget _buildCompactTranscript(
  BuildContext context,
  List<Event> events,
  MatrixLocals matrixLocals,
) {
  return Card(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: events.isEmpty
        ? Center(child: Text('Transcript will appear here.'))
        : ListView.builder(... existing message bubble code ...),
  );
}
```

Do not alter message filtering in this layout task.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

---

## Task 5: Make Stop Speaking / Interrupt Prominent

**Objective:** When Toph is speaking, David needs a clear interrupt control.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

In bottom controls, show:

```dart
if (_isSpeaking)
  FilledButton.tonalIcon(
    onPressed: _stopSpeaking,
    icon: const Icon(Icons.volume_off),
    label: const Text('Stop speaking'),
  )
```

Place it above or beside the main mic button, not as a small text button near the top.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

Manual phone test:

- while TTS is speaking, button is visible without scrolling
- tapping it stops TTS

---

## Task 6: Preserve Text Fallback Without Dominating Layout

**Objective:** Keep typed input for debugging and fallback, but don't let it make the screen feel like chat.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Option A: Keep a compact row at bottom under the mic button.

Option B: Put text input behind a `Text fallback` expansion tile.

Recommendation for this pass: **Option A**, because it is less risky.

Use smaller label:

```dart
TextField(
  decoration: const InputDecoration(
    hintText: 'Type fallback…',
    border: OutlineInputBorder(),
    isDense: true,
  ),
)
```

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

Manual phone test:

- text fallback still works
- voice controls remain visually primary

---

## Task 7: Build and Serve Layout Test APK

**Objective:** Produce an APK for David to install and test the new call layout.

Commands:

```bash
export JAVA_HOME="${JAVA_HOME:-/var/home/itzdavid/.local/share/java/jdk-21.0.11+10}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.local/share/flutter/bin:$JAVA_HOME/bin:/var/home/linuxbrew/.linuxbrew/bin:/var/home/linuxbrew/.linuxbrew/sbin:$PATH"
cd /var/home/itzdavid/Projects/fluffychat

hermes-safe-flutter analyze
hermes-safe-flutter build apk --debug --no-tree-shake-icons
cp build/app/outputs/flutter-apk/app-debug.apk build/exports/toph-call-debug-chat.fluffy.tophcall.apk
sha256sum build/exports/toph-call-debug-chat.fluffy.tophcall.apk
curl -I --max-time 10 http://127.0.0.1:8899/toph-call-debug-chat.fluffy.tophcall.apk
(cd android && hermes-safe-run -- ./gradlew --stop)
```

Gateway safety verification:

```bash
# verify java_daemons_inside_gateway=0
```

Expected:

- analyze passes
- APK builds
- LAN HTTP server serves updated artifact
- no Gradle/Kotlin daemon remains in gateway cgroup

---

## Manual Phone Acceptance Test

Install the new APK and test:

1. Open Call Mode.
2. Confirm primary mic button is large and lower on screen.
3. Confirm idle state clearly says ready/tap to speak.
4. Tap mic and speak.
   - Expected: large control changes to stop/send state.
   - Expected: recognized text is readable in status panel.
5. Stop/send or wait for final result.
   - Expected: sends once.
6. Toph replies.
   - Expected: reply TTS works as before.
7. While TTS speaks, tap Stop speaking.
   - Expected: speech stops.
8. Use typed fallback.
   - Expected: message sends, but typed UI feels secondary.

---

## Out of Scope

Do not combine these into this layout pass:

- TTS tool-call filtering/edit stabilization.
- Auto-listen after Toph finishes speaking.
- Wake word.
- Background call persistence.
- Push notifications.
- Icon/app branding changes.
- Transcript hiding/filtering.

Those are separate systems.

---

## Recommended Next Step

Implement this plan after the TTS filtering plan is either completed or intentionally deferred. If David wants immediate UX improvement first, this layout plan can go next because it is mostly widget reorganization and should not touch Matrix/STT/TTS logic.
