// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// TTS speakability policy for Toph Call Mode.
//
// Determines whether a message body is appropriate for text-to-speech
// read-aloud, filtering out tool calls, system/status messages, and
// other non-user-facing content that Hermes may produce.
//
// Kept in a standalone file so the policy can be unit-tested without
// needing Matrix event setup.

/// Returns `true` if [body] is suitable for TTS read-aloud.
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

  // Reject bodies that look like command-output sections (=== header ===).
  final lines = trimmed.split('\n');
  final commandSectionLines = lines
      .where((line) => line.trim().startsWith('===') && line.trim().endsWith('==='))
      .length;
  if (commandSectionLines >= 1) return false;

  // Reject JSON-ish tool payloads.
  final jsonToolish = trimmed.startsWith('{') &&
      lower.contains('"name"') &&
      lower.contains('"arguments"');
  if (jsonToolish) return false;

  return true;
}
