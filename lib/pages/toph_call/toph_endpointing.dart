// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Adaptive silence-based turn-end endpointing for Toph Call Mode.
///
/// This library provides a pure, unit-testable helper ([shouldEndTurn]) and a
/// stateful [AdaptiveEndpointer] that tracks STT activity timestamps and drives
/// the turn-end decision in [_TophCallPageState].
///
/// Timing constants (tunable):
/// - [kConfirmationWindow] – short delay after a final STT result during which
///   a trailing final from the same utterance can coalesce (800 ms).
/// - [kSilenceThreshold] – how long of silence (no partials / status events)
///   after a final result before the turn is considered ended (1.2 s).
/// - [kMaxTurnDuration] – safety-net cap: if adaptive endpointing never fires,
///   this hard deadline sends anyway (5 s, matching the old fixed timer).

library;

import 'dart:async';

/// The brief window after a final STT result during which a trailing final
/// phrase can coalesce before the silence check fires.
const Duration kConfirmationWindow = Duration(milliseconds: 800);

/// How long continuous silence (no partial results or status transitions)
/// must persist after any final result before the turn ends.
const Duration kSilenceThreshold = Duration(milliseconds: 1200);

/// Absolute safety-net cap: if the adaptive silence check never fires (e.g.
/// platform keeps emitting status events), send after this duration anyway.
const Duration kMaxTurnDuration = Duration(seconds: 5);

/// Returns `true` when a turn should end because silence has persisted for at
/// least [silenceThreshold] since [lastActivity].
///
/// This function is deliberately pure so it can be unit-tested without a
/// Flutter widget tree or real timers.
///
/// Parameters:
/// - [lastActivity] – timestamp of the most-recent STT activity (partial
///   result, final result, or status transition).
/// - [now]          – the current instant (pass [DateTime.now] in production).
/// - [silenceThreshold] – silence duration required to declare turn end.
bool shouldEndTurn({
  required DateTime lastActivity,
  required DateTime now,
  required Duration silenceThreshold,
}) {
  return now.difference(lastActivity) >= silenceThreshold;
}

/// Drives adaptive silence-based turn endpointing for a single STT session.
///
/// Callers notify the endpointer of STT activity via [onActivity] (partial
/// result or status transition) and [onFinalResult]. The endpointer calls
/// [onSend] when it determines the turn has ended, passing the most-recent
/// text. [cancel] stops all pending timers without sending.
///
/// The decision logic:
/// 1. A final result arms a [kConfirmationWindow] timer.
/// 2. While that timer is running, any new activity (partial or status)
///    cancels it and re-arms the timer from the new [lastActivity] once a
///    final result arrives again.
/// 3. When [kConfirmationWindow] elapses without new activity:
///    - If [shouldEndTurn] is satisfied (silence >= [kSilenceThreshold]),
///      [onSend] is called immediately.
///    - Otherwise the timer is re-armed for the remaining silence.
/// 4. A hard [kMaxTurnDuration] safety-net timer is also started on the first
///    final result to guarantee [onSend] is eventually called.
class AdaptiveEndpointer {
  /// Called when the endpointer decides the turn has ended.
  final void Function(String text) onSend;

  AdaptiveEndpointer({required this.onSend});

  // Most-recent text from a final STT result.
  String _pendingText = '';

  // Timestamp of the most-recent STT activity (any kind).
  DateTime? _lastActivity;

  // Short confirmation-window timer (re-armed on each final result / activity).
  Timer? _confirmTimer;

  // Hard safety-net timer (started on first final result, never re-armed).
  Timer? _safetyTimer;

  // Whether a final result has been received in this session.
  bool _hasFinal = false;

  // Guards against double-send.
  bool _sent = false;

  /// Call on every partial result or status transition so the endpointer
  /// knows the user is still active and can extend the deadline.
  void onActivity() {
    _lastActivity = DateTime.now();
    // If we had armed the confirmation timer, cancel it — the user is still
    // active. It will be re-armed when the next final result arrives.
    if (_hasFinal) {
      _confirmTimer?.cancel();
      _confirmTimer = null;
    }
  }

  /// Call when a final STT result arrives with the accumulated [text].
  ///
  /// Arms (or re-arms) the confirmation-window timer. The safety-net timer
  /// is started only on the first final result.
  void onFinalResult(String text) {
    if (_sent) return;
    _pendingText = text;
    _lastActivity = DateTime.now();

    if (!_hasFinal) {
      _hasFinal = true;
      // Safety-net: send at most kMaxTurnDuration after first final result.
      _safetyTimer = Timer(kMaxTurnDuration, _doSend);
    }

    // (Re-)arm the short confirmation window.
    _armConfirmTimer();
  }

  /// Arms the confirmation-window timer. When it fires, check if silence is
  /// sufficient; if not, re-arm for the remaining gap.
  void _armConfirmTimer() {
    _confirmTimer?.cancel();
    _confirmTimer = Timer(kConfirmationWindow, _onConfirmTimerFired);
  }

  void _onConfirmTimerFired() {
    _confirmTimer = null;
    if (_sent) return;
    final last = _lastActivity;
    if (last == null) {
      _doSend();
      return;
    }
    final now = DateTime.now();
    if (shouldEndTurn(
      lastActivity: last,
      now: now,
      silenceThreshold: kSilenceThreshold,
    )) {
      _doSend();
    } else {
      // Silence not yet met — re-arm for the remaining gap.
      final remaining = kSilenceThreshold - now.difference(last);
      _confirmTimer = Timer(
        remaining > Duration.zero ? remaining : Duration.zero,
        _onConfirmTimerFired,
      );
    }
  }

  void _doSend() {
    if (_sent) return;
    _sent = true;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    if (_pendingText.isNotEmpty) {
      onSend(_pendingText);
    }
  }

  /// Cancel all timers without sending (e.g. user pressed "Cancel" or
  /// "Stop & Send" manually).
  void cancel() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _sent = true; // prevent any stale timer callbacks from firing
  }

  /// Whether [onSend] has already been invoked (or [cancel] was called).
  bool get isSent => _sent;
}
