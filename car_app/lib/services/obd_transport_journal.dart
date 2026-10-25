import 'dart:convert';
import 'package:flutter/services.dart';

/// Ordered local-only byte journal. RX callbacks never wait for disk or networking.
/// The native sink is app-private/no-backup; report capture is a frozen subset.
class ObdTransportJournal {
  static const channel = MethodChannel('com.myyaris.my_yaris/obd_reports');
  final Future<void> Function(Map<String, dynamic>)? sink;
  final bool test;
  final Stopwatch _clock = Stopwatch()..start();
  final String session = DateTime.now()
      .toUtc()
      .microsecondsSinceEpoch
      .toString();
  Future<void> _pending = Future.value();
  List<Map<String, dynamic>>? _capture;
  int _sequence = 0;
  int storageFailures = 0;
  int _persistedSequence = 0;

  ObdTransportJournal({this.sink, this.test = false});

  int get nowUs => _clock.elapsedMicroseconds;
  int get lastSequence => _sequence;
  void beginCapture() => _capture = [];
  List<Map<String, dynamic>> endCapture() {
    final result = List<Map<String, dynamic>>.unmodifiable(_capture ?? []);
    _capture = null;
    return result;
  }

  Map<String, dynamic> record(
    String phase, [
    Map<String, dynamic> fields = const {},
  ]) {
    final event = <String, dynamic>{
      'event_seq': ++_sequence,
      'mono_us': nowUs,
      'time': DateTime.now().toUtc().toIso8601String(),
      'phase': phase,
      ...fields,
    };
    _capture?.add(event);
    _pending = _pending
        .then((_) async {
          if (sink != null) {
            await sink!(event);
          } else if (!test) {
            await channel.invokeMethod<void>('appendTransport', {
              'session': session,
              'event': jsonEncode(event),
            });
          }
          _persistedSequence = event['event_seq'] as int;
        })
        .catchError((Object error) {
          // Retain the in-memory evidence; never label an unsuccessful disk write saved.
          storageFailures++;
        });
    return event;
  }

  Future<void> flush() async {
    try {
      // Wait for the captured prefix, not an endlessly extending live stream.
      await _pending.timeout(const Duration(seconds: 2));
    } catch (_) {
      storageFailures++;
    }
  }

  Map<String, dynamic> get storageStatus => {
    'session': session,
    'sink': test ? 'test' : 'app_private_no_backup',
    'storage_failures': storageFailures,
    'persisted_through_event': storageFailures == 0 ? _persistedSequence : null,
    'queued_through_event': lastSequence,
  };
}
