# Toph Call TTS Filtering and Edit Stabilization Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Stop Toph Call Mode from reading tool calls, system/status messages, and intermediate edited messages aloud while preserving useful TTS for final assistant replies.

**Architecture:** Add a small TTS policy layer between Matrix timeline updates and `FlutterTts.speak()`. The policy filters out non-speakable messages, waits briefly for edited/updating messages to stabilize, deduplicates by event/body, and only speaks clean final user-facing text.

**Tech Stack:** Flutter/Dart, FluffyChat `Timeline`/`Event`, Matrix message types, `flutter_tts`, existing `sanitizeMarkdownForSpeech()`.

---

## Problem Summary

Real-device testing showed TTS works, but it currently reads too much:

- tool-call/status text
- system messages
- intermediate edited messages
- the same assistant message again when Hermes edits it

Current implementation in `lib/pages/toph_call/toph_call_page.dart`:

```dart
void _speakNewIncoming() {
  ...
  final toSpeak = newEvents
      .where(
        (e) =>
            e.senderId != ownUserId &&
            e.type == EventTypes.Message &&
            {
              MessageTypes.Text,
              MessageTypes.Emote,
              MessageTypes.Notice,
            }.contains(e.messageType),
      )
      .toList();

  for (final event in toSpeak.reversed) {
    final body = event.calcLocalizedBodyFallback(...);
    final sanitized = sanitizeMarkdownForSpeech(body);
    if (sanitized.isNotEmpty) {
      _speak(sanitized);
    }
  }
}
```

Root issue: this treats every new visible non-own text-ish event as speakable immediately. That is wrong for Hermes, because Hermes may expose operational/tool-call content and may update/edit a message before final content is stable.

---

## Desired Behavior

### TTS should speak

- Final user-facing Toph/Hermes replies.
- Only after the message has stopped changing for a short debounce window.
- Only once per final body.

### TTS should not speak

- Tool calls.
- Tool results.
- Gateway/system/status messages.
- Matrix notice messages.
- In-progress edited drafts if a final edit arrives moments later.
- Duplicate body content already spoken.
- David's own messages.

### UI should still show messages

This plan is for **TTS filtering only**. Do not hide messages from the transcript unless a later explicit UX task says so. The transcript can remain honest; the voice layer should be selective.

---

## Design Decisions

### Decision 1 — Filter before sanitizing

Filtering should use the original message body and event metadata where possible. Sanitization is for speech formatting, not policy.

### Decision 2 — Speak only `MessageTypes.Text` for now

Current filter includes `Text`, `Emote`, and `Notice`. For call mode TTS, start stricter:

```dart
event.messageType == MessageTypes.Text
```

This alone drops many system/status messages that arrive as notices.

### Decision 3 — Add content-pattern denylist for Hermes/tool noise

We need pragmatic filters because Hermes operational messages can arrive as regular text.

Initial denylist should reject bodies containing strong markers like:

- `tool_calls`
- `function_call`
- `Tool call`
- `Tool result`
- `Running as unit:`
- `Main processes terminated with:`
- `Service runtime:`
- `Memory peak:`
- `AD_HOC_VERIFICATION_OK`
- `[System:`
- `Cronjob Response:`
- `===` command output section markers
- JSON-ish function payloads such as lines starting with `{` and containing `"name":` / `"arguments":`

Keep this denylist small and obvious. Do not build a full parser yet.

### Decision 4 — Debounce edits before speaking

When a speakable candidate appears, do **not** speak immediately. Schedule it for later:

```text
candidate event/body detected
→ wait 1800ms
→ re-read current visible body for that event if possible
→ if still speakable and body hash unchanged since scheduling
→ speak once
```

Why 1800ms: enough to catch rapid message edits/tool-call updates without making voice feel dead. Tune later from phone testing.

### Decision 5 — Deduplicate by event ID + body hash

Maintain:

```dart
final Map<String, Timer> _pendingTtsTimers = {};
final Set<String> _spokenTtsKeys = {};
```

Key format:

```dart
'$eventId:${body.hashCode}'
```

If the same event/body was already spoken, skip it. If the same event gets a new body, cancel/reschedule its timer.

### Decision 6 — Do not solve “perfect final assistant detection” yet

A better long-term solution would be Hermes/gateway metadata: mark assistant final messages separately from tool/status messages. That is cleaner, but not required for the next APK. For now, implement client-side policy with conservative filters.

---

## Task 1: Extract TTS Speakability Policy

**Objective:** Move message filtering rules into testable helpers in `TophCallPage` or a small helper file.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`
- Optional create: `lib/pages/toph_call/toph_tts_policy.dart`
- Test if helper file is created: `test/pages/toph_call/toph_tts_policy_test.dart`

**Preferred implementation:** create `toph_tts_policy.dart` so policy can be unit-tested without Matrix event setup.

Add:

```dart
bool isSpeakableTophBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return false;

  final lower = trimmed.toLowerCase();

  final deniedFragments = <String>[
    'tool_calls',
    'function_call',
    'tool call',
    'tool result',
    'running as unit:',
    'main processes terminated with:',
    'service runtime:',
    'memory peak:',
    'ad_hoc_verification_ok',
    '[system:',
    'cronjob response:',
  ];

  if (deniedFragments.any(lower.contains)) return false;

  final lines = trimmed.split('\n');
  final commandSectionLines = lines
      .where((line) => line.trim().startsWith('===') && line.trim().endsWith('==='))
      .length;
  if (commandSectionLines >= 1) return false;

  final jsonToolish = trimmed.startsWith('{') &&
      lower.contains('"name"') &&
      lower.contains('"arguments"');
  if (jsonToolish) return false;

  return true;
}
```

**Tests:**

Create unit tests for:

- normal reply returns true
- empty string false
- `[System:` false
- `Tool call` false
- `Running as unit:` false
- command output section `=== build ===` false
- JSON tool payload false
- ordinary markdown reply true

**Verification:**

```bash
hermes-safe-flutter test test/pages/toph_call/toph_tts_policy_test.dart
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart lib/pages/toph_call/toph_tts_policy.dart
```

---

## Task 2: Restrict TTS Candidate Events

**Objective:** Stop TTS from considering notice/emote/system-style events.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Change the TTS filter from:

```dart
{
  MessageTypes.Text,
  MessageTypes.Emote,
  MessageTypes.Notice,
}.contains(e.messageType)
```

to:

```dart
e.messageType == MessageTypes.Text
```

Then after calculating body:

```dart
if (!isSpeakableTophBody(body)) continue;
```

**Important:** Do not change `_visibleTextEvents()` yet unless David asks to hide tool/status messages from the transcript too.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

---

## Task 3: Add Debounced TTS Scheduling

**Objective:** Prevent TTS from reading intermediate edited/updating messages.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Add state:

```dart
final Map<String, Timer> _pendingTtsTimers = {};
final Map<String, String> _pendingTtsBodies = {};
final Set<String> _spokenTtsKeys = {};
static const _ttsStabilizationDelay = Duration(milliseconds: 1800);
```

Dispose cleanup:

```dart
for (final timer in _pendingTtsTimers.values) {
  timer.cancel();
}
_pendingTtsTimers.clear();
_pendingTtsBodies.clear();
```

Replace direct `_speak(sanitized)` with scheduling:

```dart
_scheduleTtsForEvent(event, body);
```

Add helper:

```dart
void _scheduleTtsForEvent(Event event, String body) {
  final eventId = event.eventId;
  if (eventId == null) return;

  if (!isSpeakableTophBody(body)) return;

  final sanitized = sanitizeMarkdownForSpeech(body);
  if (sanitized.isEmpty) return;

  final speakKey = '$eventId:${sanitized.hashCode}';
  if (_spokenTtsKeys.contains(speakKey)) return;

  _pendingTtsTimers[eventId]?.cancel();
  _pendingTtsBodies[eventId] = sanitized;

  _pendingTtsTimers[eventId] = Timer(_ttsStabilizationDelay, () {
    if (!mounted) return;

    final latestSanitized = _pendingTtsBodies.remove(eventId);
    _pendingTtsTimers.remove(eventId);
    if (latestSanitized == null || latestSanitized.isEmpty) return;

    final latestKey = '$eventId:${latestSanitized.hashCode}';
    if (_spokenTtsKeys.contains(latestKey)) return;

    _spokenTtsKeys.add(latestKey);
    _speak(latestSanitized);
  });
}
```

**Note:** This is intentionally simple. It waits for the *last body seen for that event ID* to settle. If Matrix edits arrive as new event IDs instead of the same event ID, Task 4 handles duplicate body and tool-pattern suppression.

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

---

## Task 4: Add Body-Level Duplicate Suppression

**Objective:** Prevent re-reading the same content when edits or replacement events create different event IDs with the same visible body.

**Files:**

- Modify: `lib/pages/toph_call/toph_call_page.dart`

Add:

```dart
final Set<int> _spokenBodyHashes = {};
```

When scheduling final speech:

```dart
final bodyHash = latestSanitized.hashCode;
if (_spokenBodyHashes.contains(bodyHash)) return;
_spokenBodyHashes.add(bodyHash);
```

Cap memory growth:

```dart
if (_spokenBodyHashes.length > 200) {
  _spokenBodyHashes.clear();
}
if (_spokenTtsKeys.length > 200) {
  _spokenTtsKeys.clear();
}
```

**Verification:**

```bash
hermes-safe-flutter analyze lib/pages/toph_call/toph_call_page.dart
```

---

## Task 5: Build and Serve Updated APK

**Objective:** Produce a testable APK and update the existing LAN HTTP server artifact.

**Files:**

- Output: `build/exports/toph-call-debug-chat.fluffy.tophcall.apk`

Commands:

```bash
export JAVA_HOME="${JAVA_HOME:-/var/home/itzdavid/.local/share/java/jdk-21.0.11+10}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.local/share/flutter/bin:$JAVA_HOME/bin:/var/home/linuxbrew/.linuxbrew/bin:/var/home/linuxbrew/.linuxbrew/sbin:$PATH"
cd /var/home/itzdavid/Projects/fluffychat

hermes-safe-flutter test test/pages/toph_call/toph_tts_policy_test.dart
hermes-safe-flutter analyze
hermes-safe-flutter build apk --debug --no-tree-shake-icons
cp build/app/outputs/flutter-apk/app-debug.apk build/exports/toph-call-debug-chat.fluffy.tophcall.apk
sha256sum build/exports/toph-call-debug-chat.fluffy.tophcall.apk
curl -I --max-time 10 http://127.0.0.1:8899/toph-call-debug-chat.fluffy.tophcall.apk
(cd android && hermes-safe-run -- ./gradlew --stop)
```

Gateway safety verification:

```bash
mainpid=$(systemctl --user show hermes-gateway -p MainPID --value 2>/dev/null || true)
# verify no GradleDaemon/KotlinCompileDaemon Java process shares gateway cgroup
```

Expected:

- tests pass
- analyze passes
- APK builds
- HTTP HEAD returns `200 OK`
- `java_daemons_inside_gateway=0`

---

## Manual Phone Test Script

After installing the new APK:

1. Open Toph Call Mode.
2. Send a normal voice message.
   - Expected: recognized words send.
   - Expected: Toph response is read aloud once.
3. Trigger a message that causes tool use, for example asking for a calculation or file/status check.
   - Expected: tool-call/status text is **not** spoken.
   - Expected: final human-facing answer is spoken.
4. Watch for edits.
   - Expected: TTS waits briefly and does not restart repeatedly on every edit.
5. Confirm transcript remains visible.
   - Expected: messages may still appear in transcript; only speech is filtered.

---

## Out of Scope for This Plan

- Hiding tool calls from the transcript UI.
- Gateway-level metadata changes.
- Hermes-side final-message markers.
- Full call UX redesign / button placement.
- Auto-listen after TTS completes.

Those are separate systems. This plan fixes the current voice-noise problem without broadening scope.

---

## Open Questions for David

1. Should TTS speak only messages from a specific bot/user ID, or any non-David message in the room?
   - Recommendation: eventually specific bot/user ID; for this patch, non-own + policy filter is acceptable.
2. Should the transcript hide tool/status messages too, or only suppress TTS?
   - Recommendation: suppress TTS only for now.
3. Should debounce be 1.8s, 2.5s, or user-configurable?
   - Recommendation: start at 1.8s and adjust from phone testing.

---

## Recommended Next Step

Implement Tasks 1–5 as a focused TTS hygiene patch. Do not combine this with call-screen layout changes. One system, one adjustment.
