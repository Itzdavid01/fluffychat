// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/toph_call/markdown_speech_sanitizer.dart';
import 'package:fluffychat/pages/toph_call/toph_endpointing.dart';
import 'package:fluffychat/pages/toph_call/toph_tts_policy.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Returns `true` when Toph should immediately stop speaking because the user
/// has started talking (barge-in).
///
/// Barge-in is triggered when Toph is currently speaking AND the speech
/// recogniser signals that the user is actively talking — either because the
/// platform emitted a `listening` status, or because a non-empty partial
/// recognition result arrived while the status event had not yet fired.
///
/// Parameters:
/// - [isSpeaking]       – `_isSpeaking` flag (TTS engine is playing).
/// - [isListening]      – `true` when the STT status callback reported
///                        `SpeechToText.listeningStatus`.
/// - [hasPartialSpeech] – `true` when a non-final STT result contains
///                        non-empty `recognizedWords`.
bool shouldBargeIn({
  required bool isSpeaking,
  required bool isListening,
  required bool hasPartialSpeech,
}) {
  return isSpeaking && (isListening || hasPartialSpeech);
}

/// Returns `true` when [text] contains a recognised wake phrase.
///
/// Accepted phrases (case-insensitive, trailing punctuation stripped):
/// - "hey toph" / "hey toph,"
/// - "ok toph"  / "okay toph"
///
/// The check is deliberately kept as a simple substring scan so it works on
/// continuous partial-result streams without needing word boundaries.
bool matchesWakePhrase(String text) {
  // Normalise: lower-case and strip leading/trailing whitespace.
  final normalised = text.toLowerCase().trim();
  // Remove trailing punctuation characters that ASR commonly appends.
  final stripped = normalised.replaceAll(RegExp(r'[.,!?]+$'), '').trim();

  // Accept both the exact phrase and a version without trailing punctuation.
  for (final candidate in [normalised, stripped]) {
    if (candidate.contains('hey toph') || candidate.contains('ok toph') || candidate.contains('okay toph')) {
      return true;
    }
  }
  return false;
}

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
  // Active endpointer for the current STT session; null between sessions.
  AdaptiveEndpointer? _endpointer;
  // Safety-net timer — kept so dispose() can cancel it on widget teardown.
  // The endpointer owns the real confirm timer; this mirrors kMaxTurnDuration.
  Timer? _pendingSpeechSendTimer;
  String? _sentRecognizedText;
  String _recognizedText = '';
  String _speechStatusLabel = 'Tap to speak';
  String? _speechError;

  // Wake-word state — opt-in, defaults to OFF.
  // When true a low-effort keyword listen runs in the background.
  bool _wakeWordEnabled = false;
  // True while the background keyword listen is active.
  bool _isWakeListening = false;


  late final FlutterTts _tts;
  bool _isSpeaking = false;

  // Audio focus / session management.
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesChangedSubscription;

  // Debounced TTS scheduling state — prevents speaking tool calls,
  // system/status messages, and intermediate edited messages.
  final Map<String, Timer> _pendingTtsTimers = {};
  final Map<String, String> _pendingTtsBodies = {};
  final Set<String> _spokenTtsKeys = {};
  final Set<String> _spokenBodyTexts = {};

  // Sequential TTS queue so multi-message assistant responses are spoken
  // one after another without each new event interrupting the prior utterance.
  final List<String> _ttsQueue = [];
  bool _ttsQueuePlaying = false;

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
      if (mounted) {
        setState(() => _isSpeaking = false);
        _advanceTtsQueue();
      }
    });
    _tts.setErrorHandler((_) {
      if (mounted) {
        setState(() => _isSpeaking = false);
        // On error, skip the current utterance and try the next queued item.
        _advanceTtsQueue();
      }
    });

    _initSpeech();

    _configureAudioSession();

    _loadTimeline();
  }

  @override
  void dispose() {
    for (final timer in _pendingTtsTimers.values) {
      timer.cancel();
    }
    _pendingTtsTimers.clear();
    _pendingTtsBodies.clear();
    _ttsQueue.clear();
    _ttsQueuePlaying = false;
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = null;
    _endpointer?.cancel();
    _endpointer = null;
    _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
    _devicesChangedSubscription?.cancel();
    _devicesChangedSubscription = null;
    unawaited(_session?.setActive(false));
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _sendController.dispose();
    _scrollController.dispose();
    // Stop the keyword listen if active so the mic is released on page exit.
    if (_isWakeListening) {
      _isWakeListening = false;
      unawaited(_speech.cancel());
    }
    _tts.stop();
    super.dispose();
  }

  /// Configures [AudioSession] for hands-free voice use, requests audio focus,
  /// and subscribes to interruption / device-change events.
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _session = session;

      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions(0x2c), // defaultToSpeaker | allowBluetooth | allowBluetoothA2dp
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidWillPauseWhenDucked: false,
        ),
      );

      // Request audio focus so TTS ducks other media instead of mixing.
      unawaited(session.setActive(true));

      // Handle audio interruptions (e.g. incoming phone call).
      _interruptionSubscription =
          session.interruptionEventStream.listen((event) {
        try {
          if (!mounted) return;
          if (event.begin) {
            // An interruption started — stop TTS and STT.
            unawaited(_stopSpeaking());
            if (_isListening) {
              unawaited(_speech.cancel());
              if (mounted) {
                setState(() {
                  _isListening = false;
                  _speechStatusLabel = 'Tap to speak';
                });
              }
            }
          }
          // When the interruption ends (.begin == false), do NOT auto-resume;
          // the user can tap to talk again.
        } catch (e, st) {
          debugPrint('Toph Call audio interruption handler error: $e\n$st');
        }
      });

      // Handle device changes (e.g. headset unplugged) — stop TTS to avoid
      // audio routing surprises.
      _devicesChangedSubscription =
          session.devicesChangedEventStream.listen((event) {
        try {
          if (!mounted) return;
          if (event.devicesRemoved.isNotEmpty) {
            unawaited(_stopSpeaking());
          }
        } catch (e, st) {
          debugPrint('Toph Call audio device change handler error: $e\n$st');
        }
      });
    } catch (e, st) {
      debugPrint('Toph Call audio session configuration failed: $e\n$st');
    }
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
    // Use the newest non-own event as the marker so it stays valid if the
    // user's own optimistic local echo is later replaced with a different
    // server-confirmed eventId (which would orphan a marker on an own event).
    if (_timeline != null && _timeline!.events.isNotEmpty) {
      final ownUserId = matrix.client.userID;
      for (final event in _timeline!.events) {
        if (event.senderId != ownUserId) {
          _latestSeenEventId = event.eventId;
          break;
        }
      }
      // Fallback: if every event is our own, use the newest anyway.
      _latestSeenEventId ??= _timeline!.events.first.eventId;
    }

    if (mounted) setState(() {});
  }

  void _onTimelineUpdate() {
    if (!mounted) return;
    try {
      _speakNewIncoming();
    } catch (error, stackTrace) {
      // Timeline updates must still rebuild the message list even if TTS
      // filtering/scheduling hits an unexpected event shape.
      debugPrint('Toph Call TTS scheduling failed: $error\n$stackTrace');
    } finally {
      if (mounted) setState(() {});
    }
  }

  /// Inspects the timeline for new text events from other senders and schedules
  /// them for TTS read-aloud after filtering and edit stabilization.
  ///
  /// Event-ordering invariant: timeline.events is newest-first. The marker
  /// [_latestSeenEventId] must always point to an event that will remain
  /// present in the timeline. Setting the marker to our own event is unsafe
  /// because the Matrix SDK may replace a local echo's temporary eventId
  /// with the server-assigned ID, orphaning the marker and causing every
  /// subsequent [_speakNewIncoming] to re-collect (and re-speak) all history.
  ///
  /// Therefore the marker is only advanced to non-own speakable events.
  /// Own sends are re-scanned on each update (harmless extra work) rather
  /// than risk a stale marker that replays old assistant messages.
  void _speakNewIncoming() {
    final timeline = _timeline;
    if (timeline == null) return;

    final client = Matrix.of(context).client;
    final ownUserId = client.userID;
    if (ownUserId == null) return;

    // Collect events from newest to oldest until we hit the last-seen ID.
    final newEvents = <Event>[];
    var foundMarker = false;
    for (final event in timeline.events) {
      if (event.eventId == _latestSeenEventId) {
        foundMarker = true;
        break;
      }
      newEvents.add(event);
    }

    // Safety net: if the marker event was not found — e.g. because an
    // optimistic local echo was replaced with a confirmed event carrying a
    // different eventId, or the marked event was redacted/removed — reset
    // the marker to the newest event so we don't re-collect the entire
    // timeline on every future update.
    //
    // Stale marker recovery: when the prior marker was orphaned (non-null
    // but no longer present in the timeline), the loop above collected the
    // entire timeline into newEvents. We must return immediately after
    // resetting the marker — otherwise the all-history batch is scheduled
    // for TTS, which replays old assistant messages once (the exact bug
    // this recovery path exists to prevent). The next timeline update will
    // use the freshly-reset marker and collect only genuinely new events.
    //
    // This also handles the edge case where _latestSeenEventId is null
    // (e.g. an update fires during _loadTimeline before the marker is set):
    // we reset-and-return without speaking, and _loadTimeline later sets
    // the correct initial marker.
    if (!foundMarker && timeline.events.isNotEmpty) {
      _latestSeenEventId = timeline.events.first.eventId;
      return;
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

    // Advance the marker only to events we actually speak.  newEvents is
    // newest-first (same order as timeline.events) so toSpeak.first is the
    // newest speakable event.  When toSpeak is empty (all new events are our
    // own) the marker is left unchanged so it never lands on an own event
    // whose eventId could later be replaced by the server.
    if (toSpeak.isNotEmpty) {
      _latestSeenEventId = toSpeak.first.eventId;
    }

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

  /// Returns `true` when [event] is a raw Matrix replacement/edit event
  /// (rel_type == 'm.replace'). These events arrive as standalone messages
  /// but should never be read aloud — the SDK surfaces the updated content
  /// through the original event's body instead.
  bool _isMatrixReplacementEvent(Event event) {
    return event.relationshipType == RelationshipTypes.edit;
  }

  /// Schedules [event] with [body] for TTS read-aloud after a stabilization
  /// delay. Cancels any earlier timer for the same event ID. The speakability
  /// policy is checked after the delay so Matrix edits that settle into a
  /// human-facing final body are judged by their final text, not an
  /// intermediate body.
  void _scheduleTtsForEvent(Event event, String body) {
    final eventId = event.eventId;

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

      if (!isSpeakableTophBody(latestSanitized)) return;

      final latestKey = '$eventId:${latestSanitized.hashCode}';
      if (_spokenTtsKeys.contains(latestKey)) return;

      // Body-level duplicate suppression. Store exact text, not hashCode, so a
      // rare hash collision cannot silence a distinct assistant response.
      if (_spokenBodyTexts.contains(latestSanitized)) return;

      // Cap memory growth.
      if (_spokenTtsKeys.length > 200) {
        debugPrint('Toph Call TTS key cache exceeded 200 entries; clearing.');
        _spokenTtsKeys.clear();
      }
      if (_spokenBodyTexts.length > 200) {
        debugPrint('Toph Call TTS body cache exceeded 200 entries; clearing.');
        _spokenBodyTexts.clear();
      }

      _spokenTtsKeys.add(latestKey);
      _spokenBodyTexts.add(latestSanitized);
      _enqueueTts(latestSanitized);
    });
  }

  /// Appends [text] to the TTS queue and starts playback if idle.
  /// Duplicate suppression is handled by the caller before enqueuing.
  void _enqueueTts(String text) {
    if (text.isEmpty) return;
    _ttsQueue.add(text);
    if (!_ttsQueuePlaying) {
      _advanceTtsQueue();
    }
  }

  /// Plays the next item from the TTS queue, if any.
  /// Called automatically by the TTS completion/error handlers.
  void _advanceTtsQueue() {
    if (!mounted) return;
    if (_ttsQueue.isEmpty) {
      _ttsQueuePlaying = false;
      return;
    }
    _ttsQueuePlaying = true;
    final next = _ttsQueue.removeAt(0);
    unawaited(_speakInternal(next));
  }

  /// Speaks [text] via TTS without stopping any prior utterance.
  /// This is called only by [_advanceTtsQueue] when the queue is empty,
  /// so there is never a playing utterance to interrupt.
  Future<void> _speakInternal(String text) async {
    try {
      await _tts.speak(text);
    } catch (error, stackTrace) {
      debugPrint('Toph Call TTS speak failed: $error\n$stackTrace');
      if (mounted) setState(() => _isSpeaking = false);
      // Advance even on error so the queue does not stall.
      _advanceTtsQueue();
    }
  }

  /// Stops any ongoing TTS playback and clears the pending queue.
  Future<void> _stopSpeaking() async {
    _ttsQueue.clear();
    _ttsQueuePlaying = false;
    await _tts.stop();
  }

  /// Speaks [text] immediately, interrupting any ongoing TTS or queued
  /// auto-playback. This is the dedicated replay path for tap-to-speak and
  /// is kept separate from [_speakInternal] / [_advanceTtsQueue] so that
  /// replay is not affected by queue state, completion-handler timing, or
  /// platform-level races between stop() and speak().
  Future<void> _speakNow(String text) async {
    if (text.isEmpty) return;

    // Stop queued auto-playback from restarting after our interrupt.
    _ttsQueue.clear();
    _ttsQueuePlaying = false;

    // Stop any in-progress TTS.  Must be awaited so the engine is quiet
    // before we start the new utterance.  Wrapped in try/catch because
    // some platforms throw when stop() is called with nothing playing.
    try {
      await _tts.stop();
    } catch (_) {
      // Ignore — the engine may not have been speaking.
    }

    // Yield the microtask queue so any TTS completion/error callbacks
    // enqueued by stop() can drain before we issue a new speak().
    // Without this, a stale callback may fire mid-speak and confuse
    // queue state (though the queue is already empty so the effect is
    // limited to a spurious _advanceTtsQueue no-op).
    await Future<void>.delayed(const Duration(milliseconds: 80));

    if (!mounted) return;

    // Speak directly.  Do NOT route through _speakInternal / _advanceTtsQueue
    // because those are designed for sequential queue playback.  Replay is a
    // one-shot interrupt and must not risk re-entering the queue machinery.
    try {
      await _tts.speak(text);
    } catch (error, stackTrace) {
      debugPrint('Toph Call TTS replay failed: $error\n$stackTrace');
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  /// Replays a visible chat bubble through the same TTS safety policy used for
  /// incoming messages. Tool/status/system chatter stays silent even if tapped.
  ///
  /// Sanitizes markdown BEFORE checking speakability so that code fences and
  /// other markup don't cause the policy to reject a message that would be
  /// speakable once the markup is stripped (matching _scheduleTtsForEvent).
  Future<void> _replayMessage(String body) async {
    final sanitized = sanitizeMarkdownForSpeech(body);
    if (sanitized.isEmpty) return;

    if (!isSpeakableTophBody(sanitized)) return;

    await _speakNow(sanitized);
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
          // Barge-in: the instant the microphone transitions to active
          // listening while Toph is speaking, stop TTS fire-and-forget.
          if (shouldBargeIn(
            isSpeaking: _isSpeaking,
            isListening: status == stt.SpeechToText.listeningStatus,
            hasPartialSpeech: false,
          )) {
            unawaited(_stopSpeaking());
          }

          // Adaptive endpointing: every status transition counts as activity
          // so an ongoing recognition session keeps extending the deadline.
          _endpointer?.onActivity();

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
          _endpointer?.cancel();
          _endpointer = null;
          if (mounted) {
            setState(() {
              _speechError = error.errorMsg;
              _speechStatusLabel = 'Error';
              // Reset listening state on error so the mic button recovers.
              _isListening = false;
              _pendingSpeechSendTimer?.cancel();
              _pendingSpeechSendTimer = null;
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

    // Cancel any leftover endpointer from a previous session.
    _endpointer?.cancel();
    _endpointer = null;

    setState(() {
      _isListening = true;
      _pendingSpeechSendTimer?.cancel();
      _pendingSpeechSendTimer = null;
      _sentRecognizedText = null;
      _recognizedText = '';
      _speechStatusLabel = 'Listening...';
      _speechError = null;
    });

    // Create an endpointer for this session. Its onSend callback fires on the
    // Dart microtask/timer thread — use _sendScheduledRecognizedText which is
    // already safe to call from a Timer context.
    _endpointer = AdaptiveEndpointer(
      onSend: (text) => unawaited(_sendScheduledRecognizedText(text)),
    );

    try {
      await _speech.listen(
        onResult: (result) {
          if (mounted) {
            // Barge-in guard: if a non-final partial result with words arrives
            // while Toph is still speaking, stop TTS immediately so the user
            // is not talked over.  Empty or final-only results (no active
            // voice) do not trigger barge-in.
            if (shouldBargeIn(
              isSpeaking: _isSpeaking,
              isListening: false,
              hasPartialSpeech:
                  !result.finalResult &&
                  result.recognizedWords.trim().isNotEmpty,
            )) {
              unawaited(_stopSpeaking());
            }

            setState(() {
              _recognizedText = result.recognizedWords;
              if (result.finalResult) {
                _speechStatusLabel = 'Processing...';
              }
            });

            if (result.finalResult &&
                result.recognizedWords.trim().isNotEmpty) {
              // Adaptive endpointing: hand the final text to the endpointer.
              // It will call onSend after silence is detected or the safety-net
              // timer fires, whichever comes first.
              _endpointer?.onFinalResult(result.recognizedWords.trim());
            } else if (!result.finalResult &&
                result.recognizedWords.trim().isNotEmpty) {
              // Partial result — extend the silence deadline.
              _endpointer?.onActivity();
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
    } catch (error, stackTrace) {
      debugPrint('Toph Call speech listen failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _isListening = false;
          _speechError = 'Failed to start listening';
          _speechStatusLabel = 'Error';
        });
      }
      return;
    }

    // The listen() call may return without error even when the platform
    // failed to start. Verify that listening actually began.
    if (mounted && !_speech.isListening) {
      setState(() {
        _isListening = false;
        _speechError = 'Microphone unavailable';
        _speechStatusLabel = 'Tap to speak';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Wake-word ("Hey Toph") — optional always-listening keyword mode
  // ---------------------------------------------------------------------------

  /// Starts a low-effort background keyword listen.
  ///
  /// Uses a long [listenFor] window (15 min) with a short [pauseFor] (500 ms)
  /// so the STT engine continuously streams partial results. Each partial is
  /// scanned by [matchesWakePhrase]; if found the keyword listen is cancelled
  /// and a normal command listen is started.
  ///
  /// IMPORTANT: results from the keyword listen MUST NOT reach
  /// [AdaptiveEndpointer] or [_sendRecognizedText]. The [onResult] callback
  /// below only calls [matchesWakePhrase] and never updates [_recognizedText]
  /// or feeds [_endpointer].
  Future<void> _startWakeWordListen() async {
    if (!_speechAvailable || _isListening || _isWakeListening) return;

    if (mounted) setState(() => _isWakeListening = true);

    try {
      await _speech.listen(
        onResult: (result) {
          // Keyword-scan path — deliberately isolated from normal send path.
          // Do NOT update _recognizedText or feed _endpointer here.
          if (!mounted || !_wakeWordEnabled) return;

          final words = result.recognizedWords;
          if (words.isEmpty) return;

          if (matchesWakePhrase(words)) {
            // Wake phrase detected — stop keyword listen and acknowledge.
            _isWakeListening = false;
            unawaited(_speech.cancel());

            // Brief TTS acknowledgment, then start a normal command listen.
            // Use a micro-delay so cancel() can settle before speak + listen.
            Future<void>.delayed(const Duration(milliseconds: 150), () async {
              if (!mounted || !_wakeWordEnabled) return;
              // Acknowledge via TTS — short, non-intrusive.
              await _tts.speak('Yes?');
              // Small buffer so the TTS engine hands back audio focus before
              // the STT engine requests it again.
              await Future<void>.delayed(const Duration(milliseconds: 300));
              if (!mounted || !_wakeWordEnabled) return;
              await _startListening();
            });
          }
        },
        listenOptions: stt.SpeechListenOptions(
          // Very long window keeps the session alive in the background.
          listenFor: const Duration(minutes: 15),
          // Short pauseFor means partial results flow continuously.
          pauseFor: const Duration(milliseconds: 500),
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Toph Call wake-word listen failed: $error\n$stackTrace');
      if (mounted) setState(() => _isWakeListening = false);
    }
  }

  /// Stops the background keyword listen (no-op when not active).
  Future<void> _stopWakeWordListen() async {
    if (!_isWakeListening) return;
    _isWakeListening = false;
    try {
      await _speech.cancel();
    } catch (error, stackTrace) {
      debugPrint('Toph Call wake-word stop failed: $error\n$stackTrace');
    }
    if (mounted) setState(() {});
  }

  /// Toggles wake-word mode on or off and updates state.
  Future<void> _toggleWakeWord({required bool enabled}) async {
    if (enabled == _wakeWordEnabled) return;
    setState(() => _wakeWordEnabled = enabled);

    if (enabled) {
      // Start keyword listen unless a normal command listen is already running.
      if (!_isListening) {
        await _startWakeWordListen();
      }
    } else {
      // User turned off wake-word — stop keyword listen and return to idle.
      await _stopWakeWordListen();
    }
  }


  /// Shared send handler invoked by [AdaptiveEndpointer.onSend] (adaptive
  /// silence endpointing) and by the explicit "Stop & Send" path.
  ///
  /// Stops the STT engine if still running, then delegates to
  /// [_sendRecognizedText] which owns the idempotency guard and Matrix send.
  Future<void> _sendScheduledRecognizedText(String text) async {
    if (!mounted || _isSending) return;

    if (_speech.isListening) {
      await _speech.stop();
    }

    if (!mounted) return;
    await _sendRecognizedText(text);
    // Send completed — clear the flag so future listen sessions don't start
    // with a stale pending state.
  }

  /// Stop listening and send the final recognized text.
  Future<void> _stopAndSend() async {
    if (!_isListening) return;

    // Explicit Stop & Send wins over the adaptive endpointer.
    // Cancel the endpointer so its timer cannot fire concurrently with our
    // manual send.
    _endpointer?.cancel();
    _endpointer = null;
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = null;

    await _speech.stop();

    if (!mounted) return;

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

    // Manual send wins over any adaptive endpointing or pending timer.
    _endpointer?.cancel();
    _endpointer = null;
    _pendingSpeechSendTimer?.cancel();
    _pendingSpeechSendTimer = null;

    // The endpointer is already cancelled above. Set _isSending=true before
    // stopping STT so that any final-result callback emitted during stop()
    // finds _isSending true and returns early without scheduling a send.
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
    _endpointer?.cancel();
    _endpointer = null;
    await _speech.cancel();
    if (mounted) {
      setState(() {
        _isListening = false;
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
    if (room == null) {
      if (mounted) {
        setState(() {
          _speechError = 'Room no longer available';
          _speechStatusLabel = 'Error';
          _isListening = false;
          _isSending = false;
        });
      }
      return;
    }

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
                // Wake-word toggle — opt-in, off by default.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Hey Toph',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Switch(
                      value: _wakeWordEnabled,
                      onChanged: _speechAvailable
                          ? (v) => unawaited(_toggleWakeWord(enabled: v))
                          : null,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
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
                // Wake-word active indicator
                if (_isWakeListening && !_isListening)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.hearing,
                          size: 14,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Listening for "Hey Toph"…',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.secondary,
                              ),
                        ),
                      ],
                    ),
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
                              child: Semantics(
                                label: 'Replay message from $senderName',
                                button: true,
                                child: Container(
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.of(context).size.width *
                                            0.78,
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
