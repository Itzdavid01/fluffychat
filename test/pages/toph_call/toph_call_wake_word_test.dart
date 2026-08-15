// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/toph_call/toph_call_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchesWakePhrase', () {
    // -------------------------------------------------------------------------
    // Positive — canonical phrases
    // -------------------------------------------------------------------------
    test('returns true for "hey toph" (lower-case)', () {
      expect(matchesWakePhrase('hey toph'), isTrue);
    });

    test('returns true for "ok toph" (lower-case)', () {
      expect(matchesWakePhrase('ok toph'), isTrue);
    });

    test('returns true for "okay toph" (lower-case)', () {
      expect(matchesWakePhrase('okay toph'), isTrue);
    });

    // -------------------------------------------------------------------------
    // Positive — case-insensitive variants
    // -------------------------------------------------------------------------
    test('returns true for "Hey Toph" (title-case)', () {
      expect(matchesWakePhrase('Hey Toph'), isTrue);
    });

    test('returns true for "HEY TOPH" (upper-case)', () {
      expect(matchesWakePhrase('HEY TOPH'), isTrue);
    });

    test('returns true for "OK TOPH" (upper-case)', () {
      expect(matchesWakePhrase('OK TOPH'), isTrue);
    });

    test('returns true for "Okay Toph" (mixed-case)', () {
      expect(matchesWakePhrase('Okay Toph'), isTrue);
    });

    // -------------------------------------------------------------------------
    // Positive — trailing punctuation stripped by ASR
    // -------------------------------------------------------------------------
    test('returns true for "hey toph," (trailing comma)', () {
      expect(matchesWakePhrase('hey toph,'), isTrue);
    });

    test('returns true for "hey toph." (trailing period)', () {
      expect(matchesWakePhrase('hey toph.'), isTrue);
    });

    test('returns true for "hey toph!" (trailing exclamation)', () {
      expect(matchesWakePhrase('hey toph!'), isTrue);
    });

    test('returns true for "ok toph?" (trailing question mark)', () {
      expect(matchesWakePhrase('ok toph?'), isTrue);
    });

    // -------------------------------------------------------------------------
    // Positive — phrase embedded within a longer utterance
    // -------------------------------------------------------------------------
    test('returns true when "hey toph" is embedded in longer text', () {
      expect(matchesWakePhrase('um hey toph are you there'), isTrue);
    });

    test('returns true when "ok toph" appears mid-sentence', () {
      expect(matchesWakePhrase('ok toph what is the time'), isTrue);
    });

    // -------------------------------------------------------------------------
    // Negative — similar but wrong phrases
    // -------------------------------------------------------------------------
    test('returns false for empty string', () {
      expect(matchesWakePhrase(''), isFalse);
    });

    test('returns false for whitespace-only string', () {
      expect(matchesWakePhrase('   '), isFalse);
    });

    test('returns false for unrelated speech', () {
      expect(matchesWakePhrase('hello world'), isFalse);
    });

    test('returns false for "hey" alone', () {
      expect(matchesWakePhrase('hey'), isFalse);
    });

    test('returns false for "toph" alone', () {
      expect(matchesWakePhrase('toph'), isFalse);
    });

    test('returns false for "hey top" (truncated name)', () {
      expect(matchesWakePhrase('hey top'), isFalse);
    });

    test('returns false for "oh toph" (different prefix)', () {
      expect(matchesWakePhrase('oh toph'), isFalse);
    });

    test('returns false for "hi toph" (different prefix)', () {
      expect(matchesWakePhrase('hi toph'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------------
    test('returns true for phrase with leading/trailing whitespace', () {
      expect(matchesWakePhrase('  hey toph  '), isTrue);
    });

    test('returns true for "okay toph," (trailing comma on okay variant)', () {
      expect(matchesWakePhrase('okay toph,'), isTrue);
    });

    test('returns false for a partial match like "heyy toph"', () {
      // "heyy toph" does not contain "hey toph" as a substring.
      expect(matchesWakePhrase('heyy toph'), isFalse);
    });
  });
}
