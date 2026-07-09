// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/toph_call/markdown_speech_sanitizer.dart';
import 'package:fluffychat/pages/toph_call/toph_tts_policy.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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

  // Speech-to-text state
  final _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  bool _speechSendScheduled = false;
  Timer? _pendingSpeechSendTimer;
  String? _sentRecognizedText;
  String _recognizedText = '';
  String _speechStatusLabel = 'Tap to speak';
  String? _speechError;

  late final FlutterTts _tts;
  bool _isSpeaking = false;

  // Debounced TTS scheduling state — prevents speaking tool calls,
  // system/status messages, and intermediate edited messages.
  final Map<String, Timer> _pendingTtsTimers = {};
  final Map<String, String> _pendingTtsBodies = {};
  final Set<String> _spokenTtsKeys = {};
  final Set<int> _spokenBodyHashes = {};
  static const _ttsStabilizationDelay = Duration(milliseconds: 1800);

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

    _initSpeech();

    _loadTimeline();
  }

  @override
  void dispose() {
    for (final timer in _pendingTtsTimers.values) {
      timer.cancel();
    }
    _pendingTtsTimers.clear();
    _pendingTtsBodies.clear();
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = null;
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

    // Request missing room keys for encrypted history, matching normal chat.
    // Without this, undecryptable events remain EventTypes.Encrypted and are
    // filtered out of the Toph Call text history.
    _timeline?.requestKeys(onlineKeyBackupOnly: false);

    // Record the latest event ID as seen so we can track new messages later.
    if (_timeline != null && _timeline!.events.isNotEmpty) {
      _latestSeenEventId = _timeline!.events.first.eventId;
    }

    if (mounted) setState(() {});
  }

  void _onTimelineUpdate() {
    if (!mounted) return;
    try {
      _speakNewIncoming();
    } catch (_) {
      // Timeline updates must still rebuild the message list even if TTS
      // filtering/scheduling hits an unexpected event shape.
    }
    setState(() {});
  }

  /// Inspects the timeline for new text events from other senders and schedules
  /// them for TTS read-aloud after filtering and edit stabilization.
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
    // Only MessageTypes.Text is speakable — Emote and Notice are excluded.
    final toSpeak = newEvents
        .where(
          (e) =>
              !_isMatrixReplacementEvent(e) &&
              e.senderId != ownUserId &&
              e.type == EventTypes.Message &&
              e.messageType == MessageTypes.Text,
        )
        .toList();

    // Speak in chronological order (oldest first).
    for (final event in toSpeak.reversed) {
      final body = event.calcLocalizedBodyFallback(
        MatrixLocals(L10n.of(context)),
        withSenderNamePrefix: false,
        hideReply: true,
      );
      _scheduleTtsForEvent(event, body);
    }
  }

  bool _isMatrixReplacementEvent(Event event) {
    final relatesTo = event.content['m.relates_to'];
    return relatesTo is Map && relatesTo['rel_type'] == RelationshipTypes.edit;
  }

  /// Schedules [event] with [body] for TTS read-aloud after a stabilization
  /// delay. Cancels any earlier timer for the same event ID. Skips if the
  /// body is non-speakable, empty after sanitization, or already spoken.
  void _scheduleTtsForEvent(Event event, String body) {
    final eventId = event.eventId;

    if (!isSpeakableTophBody(body)) return;

    final sanitized = sanitizeMarkdownForSpeech(body);
    if (sanitized.isEmpty) return;

    final speakKey = '$eventId:${sanitized.hashCode}';
    if (_spokenTtsKeys.contains(speakKey)) return;

    _pendingTtsTimers[eventId]?.cancel();
    _pendingTtsBodies[eventId] = sanitized;

    _pendingTtsTimers[eventId] = Timer(_ttsStabilizationDelay, () {
      if (!mounted) return;

      final latestSanitized = _pendingTtsBodies.remove(eventId);
      _pendingTtsTimers.remove(eventId);
      if (latestSanitized == null || latestSanitized.isEmpty) return;

      final latestKey = '$eventId:${latestSanitized.hashCode}';
      if (_spokenTtsKeys.contains(latestKey)) return;

      // Body-level duplicate suppression.
      final bodyHash = latestSanitized.hashCode;
      if (_spokenBodyHashes.contains(bodyHash)) return;

      // Cap memory growth.
      if (_spokenTtsKeys.length > 200) {
        _spokenTtsKeys.clear();
      }
      if (_spokenBodyHashes.length > 200) {
        _spokenBodyHashes.clear();
      }

      _spokenTtsKeys.add(latestKey);
      _spokenBodyHashes.add(bodyHash);
      _speak(latestSanitized);
    });
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

  /// Replays a visible chat bubble through the same TTS safety policy used for
  /// incoming messages. Tool/status/system chatter stays silent even if tapped.
  Future<void> _replayMessage(String body) async {
    if (!isSpeakableTophBody(body)) return;

    final sanitized = sanitizeMarkdownForSpeech(body);
    if (sanitized.isEmpty) return;

    await _speak(sanitized);
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

  /// Initialize speech recognition and check availability.
  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: (status) {
          if (mounted) {
            setState(() {
              if (status == stt.SpeechToText.listeningStatus) {
                _speechStatusLabel = 'Listening...';
              } else if (status == stt.SpeechToText.notListeningStatus) {
                if (_isListening) {
                  _speechStatusLabel = 'Processing...';
                }
              } else if (status == stt.SpeechToText.doneStatus) {
                _speechStatusLabel = 'Tap to speak';
              }
            });
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _speechError = error.errorMsg;
              _speechStatusLabel = 'Error';
            });
          }
        },
      );
    } catch (_) {
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  /// Start listening for speech and display partial results.
  Future<void> _startListening() async {
    if (!_speechAvailable || _isListening) return;

    setState(() {
      _isListening = true;
      _speechSendScheduled = false;
      _pendingSpeechSendTimer?.cancel();
      _pendingSpeechSendTimer = null;
      _sentRecognizedText = null;
      _recognizedText = '';
      _speechStatusLabel = 'Listening...';
      _speechError = null;
    });

    await _speech.listen(
      onResult: (result) {
        if (mounted) {
          setState(() {
            _recognizedText = result.recognizedWords;
            if (result.finalResult) {
              _speechStatusLabel = 'Processing...';
            }
          });

          if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
            _scheduleRecognizedTextSend(result.recognizedWords.trim());
          }
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        cancelOnError: true,
      ),
    );

    // Do not send here. `listen()` can complete after the final-result
    // callback has already scheduled a send, which caused duplicate Matrix
    // messages. Final results are handled by `_scheduleRecognizedTextSend()`;
    // manual stop is handled by `_stopAndSend()`.
  }

  /// Schedule a send after speech recognition emits a final result.
  ///
  /// `SpeechToText.listen()` returns after listening starts, not after speech
  /// recognition finishes. Without sending from the final-result callback, the
  /// app can display recognized words but never submit them unless the user
  /// finds and taps the stop button manually.
  void _scheduleRecognizedTextSend(String text) {
    if (_speechSendScheduled || _isSending) return;
    _speechSendScheduled = true;

    // Give an explicit manual tap a chance to win. Android STT often emits a
    // final result at the same moment the user presses the visible send button;
    // deferring the automatic send lets the manual path cancel this timer so
    // one utterance cannot go out through both paths.
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = Timer(const Duration(milliseconds: 700), () {
      _pendingSpeechSendTimer = null;
      unawaited(_sendScheduledRecognizedText(text));
    });
  }

  Future<void> _sendScheduledRecognizedText(String text) async {
    if (!mounted || _isSending) return;

    if (_speech.isListening) {
      await _speech.stop();
    }

    if (!mounted) return;
    await _sendRecognizedText(text);
  }

  /// Stop listening and send the final recognized text.
  Future<void> _stopAndSend() async {
    if (!_isListening) return;

    await _speech.stop();

    if (!mounted) return;

    if (_speechSendScheduled) {
      return;
    }

    final text = _recognizedText.trim();
    if (text.isNotEmpty) {
      await _sendRecognizedText(text);
    } else {
      setState(() {
        _speechStatusLabel = 'No speech detected';
        _isListening = false;
      });
    }
  }

  /// Manually send the currently recognized text without allowing the final
  /// speech callback to send the same utterance again.
  Future<void> _manualSendRecognizedText() async {
    final text = _recognizedText.trim();
    if (text.isEmpty || _isSending) return;

    // Manual send wins over any delayed automatic final-result send.
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = null;

    // Reserve this utterance before stopping STT. Some devices emit a final
    // result during stop(); `_speechSendScheduled` blocks that callback from
    // scheduling a second Matrix send for the same button press.
    _speechSendScheduled = true;
    setState(() {
      _isSending = true;
      _isListening = false;
      _speechStatusLabel = 'Sending...';
    });

    if (_speech.isListening) {
      await _speech.stop();
    }

    if (!mounted) return;
    await _sendRecognizedText(text, sendingAlreadyShown: true);
  }

  /// Cancel listening without sending.
  Future<void> _cancelListening() async {
    await _speech.cancel();
    if (mounted) {
      setState(() {
        _isListening = false;
        _speechSendScheduled = false;
        _pendingSpeechSendTimer?.cancel();
        _pendingSpeechSendTimer = null;
        _sentRecognizedText = null;
        _recognizedText = '';
        _speechStatusLabel = 'Tap to speak';
        _speechError = null;
      });
    }
  }

  /// Send recognized text as a Matrix message.
  Future<void> _sendRecognizedText(
    String text, {
    bool sendingAlreadyShown = false,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) return;
    if (_sentRecognizedText == normalizedText) return;

    final room = _room;
    if (room == null) return;

    _sentRecognizedText = normalizedText;
    if (!sendingAlreadyShown) {
      setState(() {
        _isSending = true;
        _isListening = false;
        _speechStatusLabel = 'Sending...';
      });
    }

    try {
      await room.sendTextEvent(normalizedText, parseCommands: false);
      setState(() {
        _recognizedText = '';
        _speechStatusLabel = 'Sent ✓';
      });
      // Reset status after a brief moment
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _speechStatusLabel = 'Tap to speak');
      }
    } catch (_) {
      _sentRecognizedText = null;
      _speechSendScheduled = false;
      if (mounted) {
        setState(() {
          _speechError = 'Failed to send message';
          _speechStatusLabel = 'Error';
        });
      }
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
              ],
            ),
          ),
          // Speech status and recognized text
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Column(
              children: [
                Row(
                  children: [
                    if (_isListening)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        _speechError ?? _speechStatusLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _speechError != null
                              ? Theme.of(context).colorScheme.error
                              : _speechStatusLabel == 'Listening...'
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                    if (_isListening)
                      TextButton(
                        onPressed: _cancelListening,
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
                if (_recognizedText.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _recognizedText,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontStyle: _isListening
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _isSending
                              ? null
                              : _manualSendRecognizedText,
                          icon: const Icon(Icons.send),
                          label: const Text('Send detected words'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
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
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(128),
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
                    // Timeline events are newest-first. With reverse:true,
                    // item 0 renders at the bottom, matching chat behavior.
                    reverse: true,
                    itemBuilder: (context, index) {
                      final event = events[index];
                      final isOwn =
                          event.senderId == Matrix.of(context).client.userID;
                      final senderName = isOwn
                          ? L10n.of(context).you
                          : event.senderFromMemoryOrFallback.calcDisplayname();
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
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => unawaited(_replayMessage(body)),
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
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: isOwn
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      senderName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      body,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          const Divider(height: 1),

          // Large bottom mic control for car-friendly hands-free use.
          SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: SizedBox(
                width: double.infinity,
                height: 72,
                child: FilledButton.icon(
                  onPressed: !_speechAvailable
                      ? null
                      : _isListening
                      ? _stopAndSend
                      : _isSending
                      ? null
                      : _startListening,
                  icon: Icon(
                    !_speechAvailable
                        ? Icons.mic_off
                        : _isListening
                        ? Icons.stop_circle
                        : Icons.mic,
                    size: 34,
                  ),
                  label: Text(
                    !_speechAvailable
                        ? 'Speech unavailable'
                        : _isListening
                        ? 'Stop & Send'
                        : 'Tap to Speak',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _isListening
                        ? Theme.of(context).colorScheme.error
                        : null,
                    foregroundColor: _isListening
                        ? Theme.of(context).colorScheme.onError
                        : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Text input and send row
          SafeArea(
            top: false,
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
