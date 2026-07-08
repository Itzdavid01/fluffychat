// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Strips markdown syntax from [input] to produce natural-sounding speech
/// text for a TTS engine.
///
/// Transformations applied:
/// - Fenced code blocks (```...```) are replaced with "code block omitted".
/// - Inline code (`...`) has its backticks removed.
/// - Bold (**...**) and italic (*...*) markers are removed.
/// - Links `[text](url)` are replaced with just "text".
/// - Images `![alt](url)` are removed entirely.
/// - Headers (# ...) have their # markers removed.
/// - Blockquotes (> ...) have their > markers removed.
/// - Horizontal rules (---, ***, ___) are removed.
/// - HTML tags are stripped.
/// - Excess whitespace is collapsed.
String sanitizeMarkdownForSpeech(String input) {
  if (input.isEmpty) return input;

  var text = input;

  // 1. Remove fenced code blocks (```...```) — replace with a short note.
  //    Match triple-backtick blocks, optionally with a language tag.
  text = text.replaceAll(
    RegExp(r'```[\s\S]*?```', multiLine: true),
    ' code block omitted ',
  );

  // 2. Remove inline code (`...`) — unwrap the backticks.
  text = text.replaceAllMapped(
    RegExp(r'`([^`]+)`'),
    (m) => m.group(1)!,
  );

  // 3. Remove images: ![alt](url) — completely removed.
  text = text.replaceAll(
    RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
    '',
  );

  // 4. Replace links: [text](url) → text
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1)!,
  );

  // 5. Remove bold markers: **text** or __text__
  text = text.replaceAllMapped(
    RegExp(r'\*\*([^*]+)\*\*'),
    (m) => m.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'__([^_]+)__'),
    (m) => m.group(1)!,
  );

  // 6. Remove italic markers: *text* or _text_ (but not when part of a list marker like "* " at line start)
  text = text.replaceAllMapped(
    RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'),
    (m) => m.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'(?<!_)_([^_]+)_(?!_)'),
    (m) => m.group(1)!,
  );

  // 7. Remove header markers (# at line start)
  text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');

  // 8. Remove blockquote markers (> at line start)
  text = text.replaceAll(RegExp(r'^>\s?', multiLine: true), '');

  // 9. Remove horizontal rules (lines of only ---, ***, ___, or spaces/dashes)
  text = text.replaceAll(RegExp(r'^[\s]*[-*_]{3,}[\s]*$', multiLine: true), '');

  // 10. Remove HTML tags
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');

  // 11. Collapse multiple spaces/newlines into single spaces for natural speech flow.
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  return text;
}
