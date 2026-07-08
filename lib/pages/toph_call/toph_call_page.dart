// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/toph_call/markdown_speech_sanitizer.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

class TophCallPage extends StatefulWidget {
  final String roomId;

  const TophCallPage({super.key, required this.roomId});

  @override
  State<TophCallPage> createState() => _TophCallPageState();
}

class _TophCallPageState extends State<TophCallPage> {
  Timeline? _timeline;
  // Tracks the most recent event ID when the screen opens, so TTS
  // read-aloud can skip old history and only speak new messages.
  String? _latestSeenEventId;
  final TextEditingController _sendController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;

  late final FlutterTts _tts;
  bool _isSpeaking = false;

  Room? get _room => Matrix.of(context).client.getRoomById(widget.roomId);

  @override
  void initState() {
    super.initState();
    _tts = FlutterTts();

    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _isSpeaking = false);
    });

    _loadTimeline();
  }

  @override
  void dispose() {
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _sendController.dispose();
    _scrollController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _loadTimeline() async {
    final room = _room;
    if (room == null) return;

    final matrix = Matrix.of(context);
    await matrix.client.roomsLoading;
    await matrix.client.accountDataLoading;

    try {
      _timeline?.cancelSubscriptions();
      _timeline = await room.getTimeline(
        onUpdate: _onTimelineUpdate,
        onInsert: (_) => _onTimelineUpdate(),
      );
    } catch (e) {
      // If loading by context fails, fall back to simple timeline
      _timeline = await room.getTimeline(
        onUpdate: _onTimelineUpdate,
        onInsert: (_) => _onTimelineUpdate(),
      );
    }

    // Record the latest event ID as seen so we can track new messages later
    if (_timeline != null && _timeline!.events.isNotEmpty) {
      _latestSeenEventId = _timeline!.events.first.eventId;
    }

    if (mounted) setState(() {});
  }

  void _onTimelineUpdate() {
    if (!mounted) return;
    _speakNewIncoming();
    setState(() {});
  }

  /// Inspects the timeline for new text events from other senders and speaks
  /// them aloud via TTS, stopping any current speech first.
  void _speakNewIncoming() {
    final timeline = _timeline;
    if (timeline == null) return;

    final client = Matrix.of(context).client;
    final ownUserId = client.userID;
    if (ownUserId == null) return;

    // Collect events from newest to oldest until we hit the last-seen ID.
    final newEvents = <Event>[];
    for (final event in timeline.events) {
      if (event.eventId == _latestSeenEventId) break;
      newEvents.add(event);
    }

    // Update the marker to the newest event ID so we don't replay these.
    if (timeline.events.isNotEmpty) {
      _latestSeenEventId = timeline.events.first.eventId;
    }

    if (newEvents.isEmpty) return;

    // Filter to text messages from other senders (not our own).
    final toSpeak = newEvents
        .where(
          (e) =>
              e.senderId != ownUserId &&
              e.type == EventTypes.Message &&
              {
                MessageTypes.Text,
                MessageTypes.Emote,
                MessageTypes.Notice,
              }.contains(e.messageType),
        )
        .toList();

    // Speak in chronological order (oldest first).
    for (final event in toSpeak.reversed) {
      final body = event.calcLocalizedBodyFallback(
        MatrixLocals(L10n.of(context)),
        withSenderNamePrefix: false,
        hideReply: true,
      );
      final sanitized = sanitizeMarkdownForSpeech(body);
      if (sanitized.isNotEmpty) {
        _speak(sanitized);
      }
    }
  }

  /// Stops current speech and speaks [text] via TTS.
  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Stops any ongoing TTS playback.
  Future<void> _stopSpeaking() async {
    await _tts.stop();
  }

  List<Event> _visibleTextEvents() {
    final timeline = _timeline;
    if (timeline == null) return [];

    return timeline.events.filterByVisibleInGui().where((event) {
      // Only show text-based messages (not images, files, etc.)
      return event.type == EventTypes.Message &&
          {
            MessageTypes.Text,
            MessageTypes.Emote,
            MessageTypes.Notice,
          }.contains(event.messageType);
    }).toList();
  }

  Future<void> _sendMessage() async {
    final text = _sendController.text.trim();
    if (text.isEmpty || _isSending) return;

    final room = _room;
    if (room == null) return;

    setState(() => _isSending = true);

    try {
      await room.sendTextEvent(text, parseCommands: false);
      _sendController.clear();
    } catch (_) {
      // Silently handle send errors for now
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Toph Call Mode')),
        body: const Center(
          child: Text('Room not found. You may no longer be in this chat.'),
        ),
      );
    }

    final displayName = room.getLocalizedDisplayname();
    final events = _visibleTextEvents();
    final matrixLocals = MatrixLocals(L10n.of(context));

    return Scaffold(
      appBar: AppBar(title: const Text('Toph Call Mode')),
      body: Column(
        children: [
          // Room info header
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.roomId,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Placeholder mic button
                IconButton(
                  iconSize: 48,
                  onPressed: null, // placeholder — not wired to STT yet
                  icon: const Icon(Icons.mic),
                  tooltip: 'Microphone (coming soon)',
                ),
              ],
            ),
          ),
          const Text(
            'Idle',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          if (_isSpeaking)
            TextButton.icon(
              onPressed: _stopSpeaking,
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop Speaking'),
            ),
          const Divider(),

          // Message list
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet. Send a text to start.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withAlpha(128),
                          ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: events.length,
                    // Reverse so newest messages appear at the bottom
                    reverse: true,
                    itemBuilder: (context, index) {
                      final reversedIndex = events.length - 1 - index;
                      final event = events[reversedIndex];
                      final isOwn =
                          event.senderId == Matrix.of(context).client.userID;
                      final senderName = isOwn
                          ? L10n.of(context).you
                          : event.senderFromMemoryOrFallback
                              .calcDisplayname();
                      final body = event.calcLocalizedBodyFallback(
                        matrixLocals,
                        withSenderNamePrefix: false,
                        hideReply: true,
                      );

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Align(
                          alignment: isOwn
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.78,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isOwn
                                  ? Theme.of(context)
                                      .colorScheme
                                      .primaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  isOwn ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                              children: [
                                Text(
                                  senderName,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(
                                  body,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          const Divider(height: 1),

          // Text input and send row
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _sendController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_isSending,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _isSending ? null : _sendMessage,
                    icon: _isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    tooltip: 'Send',
                  ),
                ],
              ),
            ),
          ),

          // Back to chat button
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ElevatedButton.icon(
              onPressed: () => context.go('/rooms/${widget.roomId}'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to chat'),
            ),
          ),
        ],
      ),
    );
  }
}
