// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/pages/toph_call/toph_endpointing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // shouldEndTurn — pure function tests (no timers, no device)
  // ---------------------------------------------------------------------------
  group('shouldEndTurn', () {
    test('returns true when elapsed silence equals threshold', () {
      final base = DateTime(2024, 1, 1, 12, 0, 0);
      expect(
        shouldEndTurn(
          lastActivity: base,
          now: base.add(const Duration(milliseconds: 1200)),
          silenceThreshold: const Duration(milliseconds: 1200),
        ),
        isTrue,
      );
    });

    test('returns true when elapsed silence exceeds threshold', () {
      final base = DateTime(2024, 1, 1, 12, 0, 0);
      expect(
        shouldEndTurn(
          lastActivity: base,
          now: base.add(const Duration(seconds: 5)),
          silenceThreshold: kSilenceThreshold,
        ),
        isTrue,
      );
    });

    test('returns false when elapsed silence is below threshold', () {
      final base = DateTime(2024, 1, 1, 12, 0, 0);
      expect(
        shouldEndTurn(
          lastActivity: base,
          now: base.add(const Duration(milliseconds: 500)),
          silenceThreshold: kSilenceThreshold,
        ),
        isFalse,
      );
    });

    test('returns false when elapsed silence is just below threshold', () {
      final base = DateTime(2024, 1, 1, 12, 0, 0);
      expect(
        shouldEndTurn(
          lastActivity: base,
          now: base.add(const Duration(milliseconds: 1199)),
          silenceThreshold: kSilenceThreshold,
        ),
        isFalse,
      );
    });

    test('returns false when now equals lastActivity (zero silence)', () {
      final base = DateTime(2024, 1, 1, 12, 0, 0);
      expect(
        shouldEndTurn(
          lastActivity: base,
          now: base,
          silenceThreshold: kSilenceThreshold,
        ),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // AdaptiveEndpointer — timer-based behavioural tests (real async Dart timers)
  // ---------------------------------------------------------------------------
  group('AdaptiveEndpointer', () {
    test(
      'turn ends when silence exceeds threshold after a final result',
      () async {
        final completer = Completer<String>();
        final endpointer = AdaptiveEndpointer(
          onSend: completer.complete,
        );

        endpointer.onFinalResult('hello world');

        final sent = await completer.future.timeout(
          kConfirmationWindow + kSilenceThreshold + const Duration(milliseconds: 500),
        );
        expect(sent, equals('hello world'));
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'turn does NOT end while partial results keep arriving',
      () async {
        String? sent;
        final endpointer = AdaptiveEndpointer(
          onSend: (text) => sent = text,
        );

        endpointer.onFinalResult('first');

        // Simulate repeated partial-result activity cancelling the window.
        // Fire onActivity several times spaced 300 ms apart — each one
        // resets the deadline so it can't fire within the confirmation window.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          endpointer.onActivity();
        }

        // At this point the endpointer has no final result re-scheduled
        // after the last onActivity (no new onFinalResult), so sent must
        // still be null — the turn is still ongoing.
        expect(sent, isNull);

        endpointer.cancel();
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'a late partial result cancels a pending send; next final arms fresh window',
      () async {
        final calls = <String>[];
        final completer = Completer<void>();
        final endpointer = AdaptiveEndpointer(onSend: (text) {
          calls.add(text);
          if (!completer.isCompleted) completer.complete();
        });

        // Arm the endpointer with a first final result.
        endpointer.onFinalResult('first phrase');

        // Before the confirmation window fires, a partial arrives —
        // this cancels the pending timer.
        await Future<void>.delayed(kConfirmationWindow ~/ 2);
        endpointer.onActivity();

        // Now a second final result arrives (accumulated text).
        endpointer.onFinalResult('first phrase second phrase');

        // Wait for the adaptive window to elapse.
        await completer.future.timeout(
          kConfirmationWindow + kSilenceThreshold + const Duration(milliseconds: 500),
        );

        // onSend must have been called exactly once with the latest text.
        expect(calls.length, equals(1));
        expect(calls.first, equals('first phrase second phrase'));
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'short silence (< confirmation window) does not end the turn prematurely',
      () async {
        String? sent;
        final endpointer = AdaptiveEndpointer(
          onSend: (text) => sent = text,
        );

        endpointer.onFinalResult('hello');

        // Wait just below the confirmation window — nothing should fire.
        await Future<void>.delayed(
          kConfirmationWindow - const Duration(milliseconds: 50),
        );

        // Turn should NOT have ended yet.
        expect(sent, isNull);

        endpointer.cancel();
      },
      timeout: const Timeout(Duration(seconds: 3)),
    );

    test('cancel prevents onSend from being called', () async {
      String? sent;
      final endpointer = AdaptiveEndpointer(
        onSend: (text) => sent = text,
      );

      endpointer.onFinalResult('should not send');
      endpointer.cancel();

      // Wait well past all possible windows.
      await Future<void>.delayed(
        kMaxTurnDuration + const Duration(milliseconds: 200),
      );

      expect(sent, isNull);
    }, timeout: const Timeout(Duration(seconds: 8)));

    test('isSent is false before cancel and true after', () {
      final endpointer = AdaptiveEndpointer(onSend: (_) {});
      expect(endpointer.isSent, isFalse);
      endpointer.cancel();
      expect(endpointer.isSent, isTrue);
    });

    test(
      'safety-net timer fires eventually even without further activity',
      () async {
        final completer = Completer<String>();
        final endpointer = AdaptiveEndpointer(
          onSend: completer.complete,
        );

        endpointer.onFinalResult('safety net text');

        // Wait for the safety net duration plus a buffer.
        final sent = await completer.future.timeout(
          kMaxTurnDuration + const Duration(milliseconds: 500),
        );
        expect(sent, equals('safety net text'));
      },
      timeout: const Timeout(Duration(seconds: 8)),
    );
  });
}
