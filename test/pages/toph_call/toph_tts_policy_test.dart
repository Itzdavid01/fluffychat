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

    test('browser_ fragment returns false', () {
      expect(
        isSpeakableTophBody('browser_search completed'),
        isFalse,
      );
      expect(
        isSpeakableTophBody('Result from browser_fetch: ...'),
        isFalse,
      );
    });

    test('multi_tool_use. fragment returns false', () {
      expect(
        isSpeakableTophBody('multi_tool_use.parallel calls initiated'),
        isFalse,
      );
    });

    test('function_call fragment returns false', () {
      expect(
        isSpeakableTophBody('function_call: terminal with args {}'),
        isFalse,
      );
    });

    test('tool_calls (underscore) fragment returns false', () {
      expect(
        isSpeakableTophBody('tool_calls issued: read_file, write_file'),
        isFalse,
      );
    });

    test('service runtime header returns false', () {
      expect(isSpeakableTophBody('Service runtime: 45s'), isFalse);
    });

    test('main processes terminated header returns false', () {
      expect(
        isSpeakableTophBody('Main processes terminated with: code=0'),
        isFalse,
      );
    });

    test('[async delegation fragment returns false', () {
      expect(
        isSpeakableTophBody('[async delegation] task dispatched'),
        isFalse,
      );
    });

    test('long markdown summary with bullets and headings is speakable', () {
      expect(
        isSpeakableTophBody(
          '## Summary\n\n'
          'Here is what I found:\n\n'
          '### Key Points\n'
          '- First item: the build completed successfully\n'
          '- Second item: all tests passed\n'
          '- Third item: no issues detected\n\n'
          '### Next Steps\n'
          '1. Review the changes in detail\n'
          '2. Deploy to staging\n'
          '3. Monitor for errors\n\n'
          'Let me know if you need anything else!',
        ),
        isTrue,
      );
    });

    test('normal prose with the word "parameters" used naturally is speakable', () {
      expect(
        isSpeakableTophBody('The system parameters look good to me.'),
        isTrue,
      );
      expect(
        isSpeakableTophBody(
          'Let me check the parameters for the build function and see what memory usage looks like.',
        ),
        isTrue,
      );
    });

    test('structured parameters payload remains denied', () {
      expect(
        isSpeakableTophBody('parameters: {"command": "pwd"}'),
        isFalse,
      );
      expect(
        isSpeakableTophBody('"arguments": {"path": "lib"}'),
        isFalse,
      );
    });

    test('normal prose with tool-like word in isolation is speakable', () {
      // Words like "tool" by itself should not be denied — only specific
      // tool/status fragments trigger denial.
      expect(
        isSpeakableTophBody('I used a tool to help with this.'),
        isTrue,
      );
    });
  });
}
