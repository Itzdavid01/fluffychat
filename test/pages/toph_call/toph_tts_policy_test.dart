// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/toph_call/toph_tts_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSpeakableTophBody', () {
    test('normal reply returns true', () {
      expect(isSpeakableTophBody('Hello David, how can I help you?'), isTrue);
    });

    test('empty string returns false', () {
      expect(isSpeakableTophBody(''), isFalse);
      expect(isSpeakableTophBody('   '), isFalse);
    });

    test('[System: prefix returns false', () {
      expect(
        isSpeakableTophBody('[System: background task completed]'),
        isFalse,
      );
    });

    test('tool call fragment returns false', () {
      expect(isSpeakableTophBody('Executing tool call: search_files'), isFalse);
      expect(isSpeakableTophBody('Tool call result: found 3 files'), isFalse);
    });

    test('Running as unit: returns false', () {
      expect(isSpeakableTophBody('Running as unit: search_files'), isFalse);
    });

    test('command output section (=== ... ===) returns false', () {
      expect(isSpeakableTophBody('=== build ===\nBuild output here'), isFalse);
    });

    test('JSON tool payload returns false', () {
      expect(
        isSpeakableTophBody(
          '{"name": "search_files", "arguments": {"pattern": "*.dart"}}',
        ),
        isFalse,
      );
    });

    test('ordinary markdown reply returns true', () {
      expect(
        isSpeakableTophBody(
          'Here is the **result**:\n\n- Item 1\n- Item 2\n\nLet me know if you need more!',
        ),
        isTrue,
      );
    });

    test('cronjob response: returns false', () {
      expect(
        isSpeakableTophBody('Cronjob Response: all jobs completed'),
        isFalse,
      );
    });

    test('memory peak: returns false', () {
      expect(isSpeakableTophBody('Memory peak: 256MB'), isFalse);
    });

    test('ad_hoc_verification_ok returns false', () {
      expect(isSpeakableTophBody('Status: AD_HOC_VERIFICATION_OK'), isFalse);
    });

    test('edited tool-call chatter returns false', () {
      expect(
        isSpeakableTophBody(
          'Tool called functions.terminal with parameters {"command": "pwd"}',
        ),
        isFalse,
      );
      expect(
        isSpeakableTophBody('recipient_name: functions.read_file'),
        isFalse,
      );
      expect(
        isSpeakableTophBody('verification_script=/tmp/hermes-verify-abc.py'),
        isFalse,
      );
    });

    test('code fences return false', () {
      expect(
        isSpeakableTophBody('Here is output:\n```dart\nprint("hi");\n```'),
        isFalse,
      );
    });

    test('PASS verification lines return false', () {
      expect(
        isSpeakableTophBody('PASS: thing worked\nPASS: cleanup removed'),
        isFalse,
      );
    });
  });
}
