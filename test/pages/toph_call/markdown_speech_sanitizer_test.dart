// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/toph_call/markdown_speech_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeMarkdownForSpeech', () {
    test('returns empty string unchanged', () {
      expect(sanitizeMarkdownForSpeech(''), '');
    });

    test('plain text passes through', () {
      const input = 'Hello, how are you today?';
      expect(sanitizeMarkdownForSpeech(input), input);
    });

    test('strips bold markers', () {
      expect(
        sanitizeMarkdownForSpeech('This is **very important** indeed.'),
        'This is very important indeed.',
      );
    });

    test('strips italic markers', () {
      expect(
        sanitizeMarkdownForSpeech('I am *so* excited!'),
        'I am so excited!',
      );
    });

    test('replaces links with link text', () {
      expect(
        sanitizeMarkdownForSpeech(
          'Check out [this link](https://example.com) for more.',
        ),
        'Check out this link for more.',
      );
    });

    test('removes images entirely', () {
      expect(
        sanitizeMarkdownForSpeech(
          'Look at this ![cat picture](https://example.com/cat.jpg).',
        ),
        'Look at this .',
      );
    });

    test('replaces fenced code blocks with placeholder', () {
      expect(
        sanitizeMarkdownForSpeech(
          'Here is code:\n```dart\nvoid main() {\n  print("hello");\n}\n```\nEnd.',
        ),
        'Here is code: code block omitted End.',
      );
    });

    test('unwraps inline code', () {
      expect(
        sanitizeMarkdownForSpeech('Use the `flutter_tts` package.'),
        'Use the flutter_tts package.',
      );
    });

    test('strips header markers', () {
      expect(
        sanitizeMarkdownForSpeech('## Section Title\nSome content here.'),
        'Section Title Some content here.',
      );
    });

    test('strips blockquote markers', () {
      expect(
        sanitizeMarkdownForSpeech('> This is a quote\n> more quote'),
        'This is a quote more quote',
      );
    });

    test('removes horizontal rules', () {
      expect(
        sanitizeMarkdownForSpeech('Before\n---\nAfter'),
        'Before After',
      );
    });

    test('strips HTML tags', () {
      expect(
        sanitizeMarkdownForSpeech('Click <strong>here</strong> now.'),
        'Click here now.',
      );
    });

    test('collapses excess whitespace', () {
      expect(
        sanitizeMarkdownForSpeech('Hello   \n\n\n   world'),
        'Hello world',
      );
    });

    test('handles combined markdown', () {
      const input = '''
## Hello

This is a **bold** and *italic* message with `code`.

> A blockquote here.

Check [the docs](https://example.com).

```python
print("hello world")
```

End of message.
''';
      final result = sanitizeMarkdownForSpeech(input);
      expect(
        result,
        'Hello This is a bold and italic message with code. A blockquote here. '
        'Check the docs. code block omitted End of message.',
      );
    });
  });
}
