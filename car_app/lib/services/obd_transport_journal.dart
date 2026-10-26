import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class ObdJournalCapture {
  final String session;
  final List<Map<String, dynamic>> events = [];
  Future<void> pending = Future.value();
  final Completer<void> stopped = Completer<void>();
  Timer? deadline;
  Timer? tail;
  int sequence = 0, bytes = 0, pendingBytes = 0, persisted = 0, failures = 0;
  int rxBytes = 0;
  int? captureEnd, firstFailed;
  bool closed = false,
      nativeClosed = false,
      writerFailed = false,
      truncated = false;
  String? stopReason, errorCode;
  ObdJournalCapture(this.session);
}

/// Explicit manual-test sessions only. No recording or disk work when inactive.
/// A frozen report capture and the bounded passive tail have separate cutoffs.
class ObdTransportJournal {
  static const channel = MethodChannel('com.myyaris.my_yaris/obd_reports');
  static const schema = 2;
  static const source = String.fromEnvironment(
    'OBD_SOURCE_FINGERPRINT',
    defaultValue: 'not_acquired',
  );
  static const version = String.fromEnvironment(
    'OBD_BUILD_VERSION',
    defaultValue: 'not_acquired',
  );
  final Future<void> Function(Map<String, dynamic>)? sink;
  final bool test;
  final Duration tailWindow, sessionLimit, sinkTimeout;
  final int maxBytes, maxPendingBytes, maxEvents;
  final Stopwatch _clock = Stopwatch()..start();
  ObdJournalCapture? _current, _last;
  int _sessions = 0;

  ObdTransportJournal({
    this.sink,
    this.test = false,
    this.tailWindow = const Duration(seconds: 2),
    this.sessionLimit = const Duration(seconds: 60),
    this.sinkTimeout = const Duration(seconds: 1),
    this.maxBytes = 1024 * 1024,
    this.maxPendingBytes = 512 * 1024,
    this.maxEvents = 4096,
  });

  int get nowUs => _clock.elapsedMicroseconds;
  bool get isRecording => _current != null && !_current!.closed;
  String? get session => _current?.session;
  int get lastSequence => _last?.sequence ?? 0;
  int get storageFailures => _last?.failures ?? 0;

  ObdJournalCapture beginCapture() {
    final old = _current;
    if (old != null && !old.closed) {
      _stop(old, 'next_manual_test');
    }
    final c = ObdJournalCapture(
      '${DateTime.now().toUtc().microsecondsSinceEpoch}${++_sessions}',
    );
    _current = _last = c;
    c.deadline = Timer(sessionLimit, () => _stop(c, 'session_time_limit'));
    _append(c, 'session_start', {
      'journal_schema': schema,
      'source_fingerprint': source,
      'app_build_version': version,
      'observation_layer': 'application_callbacks_not_HCI_or_CAN_capture',
      'hci_capture': 'not_acquired',
      'CAN_bus_capture': 'not_acquired',
      'limits': {
        'bytes': maxBytes,
        'events': maxEvents,
        'pending_bytes': maxPendingBytes,
        'session_ms': sessionLimit.inMilliseconds,
        'passive_tail_ms': tailWindow.inMilliseconds,
      },
    });
    return c;
  }

  Map<String, dynamic>? record(
    String phase, [
    Map<String, dynamic> fields = const {},
  ]) {
    final c = _current;
    if (c == null || c.closed) return null;
    final estimate = utf8.encode(jsonEncode(fields)).length + 256;
    if (estimate > 16 * 1024 ||
        c.bytes + estimate > maxBytes ||
        c.pendingBytes + estimate > maxPendingBytes ||
        c.events.length >= maxEvents) {
      c.truncated = true;
      _stop(c, 'capacity_limit', {
        'first_omitted_phase': phase,
        'first_omitted_length': fields['length'],
        'later_events': 'not_recorded_after_cutoff',
      });
      return null;
    }
    return _append(c, phase, fields);
  }

  Map<String, dynamic> _append(
    ObdJournalCapture c,
    String phase,
    Map<String, dynamic> fields,
  ) {
    if (phase == 'rx_notification') {
      c.rxBytes += (fields['length'] as int?) ?? 0;
    }
    final event = <String, dynamic>{
      ...fields,
      'session_id': c.session,
      'event_seq': ++c.sequence,
      'mono_us': nowUs,
      'time': DateTime.now().toUtc().toIso8601String(),
      'phase': phase,
      if (phase == 'rx_notification') 'session_rx_bytes': c.rxBytes,
    };
    final line = jsonEncode(event);
    final size = utf8.encode(line).length + 1;
    c.events.add(event);
    c.bytes += size;
    c.pendingBytes += size;
    c.pending = c.pending.then((_) async {
      try {
        if (c.writerFailed) return;
        if (sink != null) {
          await sink!(event).timeout(sinkTimeout);
        } else if (!test) {
          await channel
              .invokeMethod<void>('appendTransport', {
                'session': c.session,
                'sequence': event['event_seq'],
                'event': line,
              })
              .timeout(sinkTimeout);
        }
        c.persisted = event['event_seq'] as int;
      } catch (error) {
        c.failures++;
        c.writerFailed = true;
        c.firstFailed ??= event['event_seq'] as int;
        c.errorCode = error is PlatformException
            ? error.code
            : error.runtimeType.toString();
        _stop(c, 'storage_failure');
      } finally {
        c.pendingBytes -= size;
      }
    });
    return event;
  }

  List<Map<String, dynamic>> endCapture([ObdJournalCapture? capture]) {
    final c = capture ?? _current;
    if (c == null) return const [];
    c.captureEnd = c.sequence;
    final core = List<Map<String, dynamic>>.unmodifiable(c.events);
    if (!c.closed) {
      if (tailWindow == Duration.zero) {
        _stop(c, 'passive_tail_elapsed');
      } else {
        c.tail = Timer(tailWindow, () => _stop(c, 'passive_tail_elapsed'));
      }
    }
    return core;
  }

  void stop([String reason = 'explicit_stop']) {
    final c = _current;
    if (c != null) _stop(c, reason);
  }

  void _stop(
    ObdJournalCapture c,
    String reason, [
    Map<String, dynamic> details = const {},
  ]) {
    if (c.closed) return;
    c.deadline?.cancel();
    c.tail?.cancel();
    c.stopReason = reason;
    if (reason == 'session_time_limit') c.truncated = true;
    _append(c, 'session_stop', {
      'reason': reason,
      'truncated': c.truncated,
      ...details,
    });
    c.closed = true;
    if (identical(_current, c)) _current = null;
    c.pending = c.pending.then((_) async {
      try {
        if (!test) {
          await channel
              .invokeMethod<void>('closeTransport', {'session': c.session})
              .timeout(sinkTimeout);
        }
        c.nativeClosed = true;
      } catch (error) {
        c.failures++;
        c.errorCode = error is PlatformException
            ? error.code
            : error.runtimeType.toString();
      }
    });
    c.stopped.complete();
  }

  Future<void> flush([ObdJournalCapture? capture]) async {
    final c = capture ?? _last;
    if (c == null) return;
    try {
      await c.pending.timeout(const Duration(seconds: 2));
    } catch (_) {
      c.failures++;
      c.errorCode = 'flush_timeout';
      _stop(c, 'flush_timeout');
    }
  }

  Future<List<Map<String, dynamic>>> sealForExport(ObdJournalCapture c) async {
    if (!c.closed) await c.stopped.future.timeout(sessionLimit + tailWindow);
    await flush(c);
    return List<Map<String, dynamic>>.unmodifiable(c.events);
  }

  Map<String, dynamic> statusFor(ObdJournalCapture? c) => c == null
      ? {'recording': false}
      : {
          'journal_schema': schema,
          'session': c.session,
          'sink': test ? 'test' : 'app_private_no_backup',
          'source_fingerprint': source,
          'app_build_version': version,
          'capture_end_event': c.captureEnd,
          'queued_through_event': c.sequence,
          'persisted_through_event': c.persisted,
          'storage_failures': c.failures,
          'first_failed_event': c.firstFailed,
          'error_code': c.errorCode,
          'recording': !c.closed,
          'native_closed_ack': c.nativeClosed,
          'stop_reason': c.stopReason,
          'truncated': c.truncated,
          'retained_event_bytes': c.bytes,
          'pending_bytes': c.pendingBytes,
          'flush_complete':
              c.closed &&
              c.nativeClosed &&
              c.failures == 0 &&
              c.persisted == c.sequence,
          'after_session_stop': 'not_recorded',
        };
  Map<String, dynamic> get storageStatus => statusFor(_last);
}
