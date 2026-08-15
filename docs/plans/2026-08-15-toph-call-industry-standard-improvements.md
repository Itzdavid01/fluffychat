# Toph Call — 5 Industry-Standard Improvements

Date: 2026-08-15
Branch: `feat/3229-toph-hands-free-call-mode` (rebased onto upstream 2.9.0)
Owner: Toph (orchestrating), Agy (executing code phases)

## Context

The FluffyChat fork is now current with upstream `main` (2.9.0). The Toph Call
hands-free mode (`lib/pages/toph_call/`) works but lacks five capabilities that
are table stakes in hands-free voice UX (Alexa / Google Assistant / Siri /
CarPlay / Android Auto). This plan adds them, one Agy phase each, then verifies.

## Baseline (verified green before any phase)

- `flutter analyze lib/pages/toph_call/ lib/config/routes.dart lib/widgets/chat_settings_popup_menu.dart` → No issues.
- `flutter test test/pages/toph_call/` → 39 passed.

## The 5 improvements

### Phase 1 — Barge-in (user speech interrupts TTS)
Today the assistant talks over the user. Industry standard: the moment the user
starts speaking, TTS stops and the queue clears, and the mic takes priority.
- On `SpeechToText` status becoming `listening` (or first partial result with
  real content) while `_isSpeaking`, call `_stopSpeaking()` (clears queue +
  stops TTS) before continuing.
- Do NOT restart queued auto-playback after a barge-in interrupt.
- Add unit tests for the barge-in predicate + queue-clearing path.
Files: `lib/pages/toph_call/toph_call_page.dart` (+ test).

### Phase 2 — Audio focus & ducking
Today TTS plays at full volume over music and ignores phone-call interruptions.
Add `audio_session` and configure a `speech`/`voiceCall` configuration:
- Request audio focus when entering the call page; release in `dispose`.
- Duck other audio during TTS playback (Android audio focus `GAIN_TRANSIENT_MAY_DUCK`
  semantics), route to the speech output.
- Handle interruption events (phone call, another app claiming focus) by stopping
  TTS + listening cleanly.
Files: `pubspec.yaml` (+ `audio_session`), `toph_call_page.dart` (focus lifecycle).

### Phase 3 — Adaptive endpointing (silence-based turn end)
Today turn end is a fixed 5-second timer, so short replies fire late and
hesitations fire early. Use `speech_to_text` status + `pauseFor` semantics:
- End the turn on definitive silence (`status == notListening` after a final
  result) rather than only on the fixed timer.
- Keep the auto-send timer as a safety net, but let a genuine end-of-speech
  shorten the wait; never send while the user is clearly still speaking
  (partial results still flowing).
- Add tests for the endpointing decision helper (extract pure logic).
Files: `toph_call_page.dart` (+ extracted helper + test).

### Phase 4 — Wake word ("Hey Toph")
The mode still requires a tap. Add an opt-in always-listening mode (default off)
that scans partial results for "hey toph" and then starts a command listen.
- A toggle in the call UI; when on, run a low-effort continuous listen and
  scan partial results (case-insensitive) for the phrase.
- On detection: chime/ack, stop the keyword listen, start a normal command listen.
- Tap-to-talk remains the default and fallback.
Files: `toph_call_page.dart` (+ helper + test for keyword matching).

### Phase 5 — Lifecycle resilience
Backgrounding the app or rotating mid-call can leak TTS or drop state. Add
`WidgetsBindingObserver`:
- On `AppLifecycleState.paused/inactive`: stop TTS, clear the queue, stop
  listening, cancel pending auto-send.
- On `resumed`: re-arm the timeline marker and listening affordance without
  replaying already-spoken history.
- Ensure `dispose` releases audio focus and cancels timers.
Files: `toph_call_page.dart` (+ test where feasible).

## Execution protocol

1. One `agy -p` invocation per phase, in order, on the feature branch working
   tree (working dir = repo root).
2. After EACH phase: `flutter analyze` (targeted) + `flutter test test/pages/toph_call/`.
   A phase that fails gates must be fixed (retry with Agy or manual) before the
   next phase starts.
3. Agy prompt per phase is self-contained: file paths, current behavior, desired
   behavior, acceptance criteria, and "run tests with full path" instructions.
4. Do NOT push. All work stays local on the feature branch.
5. Report per-phase: diff scope, analyze result, test result.

## Model

`agy --model 'Claude Sonnet 4.6 (Thinking)'` for code phases; `--print-timeout`
raised to `15m`; `--dangerously-skip-permissions` for autonomous edits.
