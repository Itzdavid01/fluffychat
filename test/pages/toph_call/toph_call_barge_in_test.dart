// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/toph_call/toph_call_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldBargeIn', () {
    test('returns true when speaking and STT transitions to listening', () {
      expect(
        shouldBargeIn(
          isSpeaking: true,
          isListening: true,
          hasPartialSpeech: false,
        ),
        isTrue,
      );
    });

    test('returns true when speaking and partial speech arrives', () {
      expect(
        shouldBargeIn(
          isSpeaking: true,
          isListening: false,
          hasPartialSpeech: true,
        ),
        isTrue,
      );
    });

    test('returns true when speaking and both listening and partial speech', () {
      expect(
        shouldBargeIn(
          isSpeaking: true,
          isListening: true,
          hasPartialSpeech: true,
        ),
        isTrue,
      );
    });

    test('returns false when not speaking (even if listening)', () {
      expect(
        shouldBargeIn(
          isSpeaking: false,
          isListening: true,
          hasPartialSpeech: false,
        ),
        isFalse,
      );
    });

    test('returns false when not speaking (even with partial speech)', () {
      expect(
        shouldBargeIn(
          isSpeaking: false,
          isListening: false,
          hasPartialSpeech: true,
        ),
        isFalse,
      );
    });

    test(
      'returns false when speaking but neither listening nor partial speech',
      () {
        expect(
          shouldBargeIn(
            isSpeaking: true,
            isListening: false,
            hasPartialSpeech: false,
          ),
          isFalse,
        );
      },
    );

    test('returns false when all flags are false', () {
      expect(
        shouldBargeIn(
          isSpeaking: false,
          isListening: false,
          hasPartialSpeech: false,
        ),
        isFalse,
      );
    });
  });
}
