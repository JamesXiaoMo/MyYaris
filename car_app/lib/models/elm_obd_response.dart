/// Evidence from one serial exchange. A prompt, not a nonempty buffer, completes it.
class ElmReply {
  final String raw;
  final String completion;
  final DateTime time;
  final int elapsedMs;
  final Map<String, dynamic> transport;
  ElmReply(
    this.raw,
    this.completion, {
    DateTime? time,
    this.elapsedMs = 0,
    this.transport = const {},
  }) : time = time ?? DateTime.now();
  bool get complete => completion == 'prompt';
  Map<String, dynamic> toJson() => {
    'raw': raw,
    'completion': completion,
    'time': time.toIso8601String(),
    'elapsed_ms': elapsedMs,
    ...transport,
  };
}

class ObdFrameEvidence {
  final String ecu;
  final String payload;
  final String verdict;
  final int? service;
  final int? nrc;
  final String? structureVerdict;
  final String? transportCompletion;
  const ObdFrameEvidence(
    this.ecu,
    this.payload,
    this.verdict, {
    this.service,
    this.nrc,
    this.structureVerdict,
    this.transportCompletion,
  });
  bool get positive => verdict == 'positive';
  Map<String, dynamic> toJson() => {
    'ecu_header': ecu,
    'payload': payload,
    'verdict': verdict,
    if (service != null) 'negative_service': service,
    if (nrc != null) 'nrc': nrc,
    if (structureVerdict != null) 'structure_verdict': structureVerdict,
    if (transportCompletion != null)
      'transport_completion': transportCompletion,
  };
}

class ObdResponseEvidence {
  final List<ObdFrameEvidence> frames;
  final String reason;
  const ObdResponseEvidence(this.frames, this.reason);
  bool get positive => frames.any((f) => f.positive);
}

class _Assembly {
  final String ecu;
  final int length;
  final List<int> bytes;
  int next;
  _Assembly(this.ecu, this.length, this.bytes, this.next);
}

/// Parses ELM display envelopes only; does not implement bus transport/flow control.
class ElmObdParser {
  static const dataLengths = <String, int>{
    '00': 4,
    '20': 4,
    '40': 4,
    '60': 4,
    '80': 4,
    'A0': 4,
    'C0': 4,
    'E0': 4,
    '04': 1,
    '05': 1,
    '06': 1,
    '07': 1,
    '0A': 1,
    '0B': 1,
    '0C': 2,
    '0D': 1,
    '0E': 1,
    '0F': 1,
    '10': 2,
    '11': 1,
    '12': 1,
    '13': 1,
    '14': 2,
    '15': 2,
    '1C': 1,
    '1F': 2,
    '21': 2,
    '2E': 1,
    '2F': 1,
    '30': 1,
    '31': 2,
    '32': 2,
    '33': 1,
    '34': 4,
    '3C': 2,
    '3D': 2,
    '42': 2,
    '43': 2,
    '44': 2,
    '45': 1,
    '46': 1,
    '47': 1,
    '49': 1,
    '4A': 1,
    '4C': 1,
    '5C': 1,
    '5E': 2,
    'A6': 4,
  };
  static String hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  static ObdResponseEvidence classify(ElmReply reply, String command) {
    final cmd = command.replaceAll(' ', '').toUpperCase();
    final expected = RegExp(r'^(01|09|21|22)[0-9A-F]+$').hasMatch(cmd)
        ? (int.parse(cmd.substring(0, 2), radix: 16) + 0x40)
                  .toRadixString(16)
                  .toUpperCase() +
              cmd.substring(2)
        : null;
    final frames = <ObdFrameEvidence>[];
    final pending = <String, _Assembly>{};
    _Assembly? numbered;
    int? numberedLength;
    bool ambiguousUnknown = false;
    void emit(String ecu, List<int> bytes, [String? failure]) {
      final payload = hex(bytes);
      var verdict = failure ?? 'wrong_service_or_pid';
      int? service, nrc;
      if (failure == null && bytes.length == 3 && bytes[0] == 0x7F) {
        service = bytes[1];
        nrc = bytes[2];
        verdict = cmd.startsWith(hex([service]))
            ? 'negative_response'
            : 'wrong_negative_service';
      } else if (failure == null &&
          expected != null &&
          payload.startsWith(expected)) {
        final int? size;
        if (cmd.startsWith('01')) {
          size = dataLengths[cmd.substring(2)];
        } else if (cmd.startsWith('09')) {
          size = {'02': 18, '04': 17, '06': 5, '0A': 21}[cmd.substring(2)];
        } else {
          // Private layout/expected length is unknown: echo plus data is evidence only.
          size = 1;
        }
        verdict = size == null
            ? 'unknown_length'
            : bytes.length < expected.length ~/ 2 + size
            ? 'short_payload'
            : 'positive';
        if (verdict == 'positive' &&
            cmd.startsWith('01') &&
            bytes.length != expected.length ~/ 2 + size!) {
          verdict = 'unexpected_payload_length';
        }
        if (verdict == 'positive' && cmd.startsWith('09')) {
          final width = {
            '02': 17,
            '04': 16,
            '06': 4,
            '0A': 20,
          }[cmd.substring(2)]!;
          if (bytes[2] == 0 ||
              bytes.length != 3 + bytes[2] * width ||
              (cmd == '0902' && bytes[2] != 1)) {
            verdict = 'unexpected_record_length';
          }
        }
      }
      final structure = verdict;
      if (!reply.complete) verdict = reply.completion;
      frames.add(
        ObdFrameEvidence(
          ecu,
          payload,
          verdict,
          service: service,
          nrc: nrc,
          structureVerdict: structure,
          transportCompletion: reply.completion,
        ),
      );
    }

    void finishNumbered() {
      final a = numbered;
      if (a != null) {
        emit(
          a.ecu,
          a.bytes,
          a.bytes.length == a.length ? null : 'incomplete_multiframe',
        );
      }
      numbered = null;
    }

    for (var line
        in reply.raw
            .toUpperCase()
            .replaceAll('>', '\n')
            .split(RegExp(r'[\r\n]+'))) {
      line = line.trim();
      if (line.isEmpty || line.replaceAll(' ', '') == cmd) continue;
      // SEARCHING is an adapter event, never data; a later real reply may follow.
      if (line.startsWith('SEARCHING...')) {
        frames.add(const ObdFrameEvidence('unknown', '', 'adapter_searching'));
        line = line.substring(12).trim();
        if (line.isEmpty) continue;
      }
      if (!RegExp(r'^[0-9A-F :]+$').hasMatch(line)) {
        final status = line == 'NO DATA'
            ? 'no_data'
            : line == 'STOPPED'
            ? 'adapter_stopped'
            : 'adapter_status';
        frames.add(
          ObdFrameEvidence(
            'unknown',
            line,
            reply.complete ? status : reply.completion,
          ),
        );
        continue;
      }
      final indexed = RegExp(r'^([0-9A-F]+):\s*([0-9A-F ]+)$').firstMatch(line);
      if (indexed != null) {
        final index = int.parse(indexed[1]!, radix: 16);
        final h = indexed[2]!.replaceAll(' ', '');
        if (h.length.isOdd) {
          frames.add(ObdFrameEvidence('unknown', line, 'invalid_hex'));
          continue;
        }
        final b = [
          for (var i = 0; i < h.length; i += 2)
            int.parse(h.substring(i, i + 2), radix: 16),
        ];
        if (numbered != null &&
            index == numbered!.next &&
            numbered!.bytes.length < numbered!.length) {
          numbered!.bytes.addAll(b);
          numbered!.next = (numbered!.next + 1) & 15;
        } else if (index == 0) {
          finishNumbered();
          numbered = _Assembly('unknown', numberedLength ?? -1, b, 1);
          numberedLength = null;
        } else {
          finishNumbered();
          emit('unknown', b, 'orphan_or_out_of_order_frame');
        }
        continue;
      }
      if (RegExp(r'^[0-9A-F]{3}$').hasMatch(line)) {
        finishNumbered();
        numberedLength = int.parse(line, radix: 16);
        continue;
      }
      finishNumbered();
      var ecu = 'unknown';
      var h = line.replaceAll(' ', '');
      final header = RegExp(
        r'^([0-9A-F]{3}|18D[AB][0-9A-F]{4})\s+(.+)$',
      ).firstMatch(line);
      if (header != null) {
        ecu = header[1]!;
        h = header[2]!.replaceAll(' ', '');
      } else if (h.startsWith('18DA') && h.length > 10) {
        ecu = h.substring(0, 8);
        h = h.substring(8);
      } else if (h.startsWith('7') && h.length >= 7) {
        ecu = h.substring(0, 3);
        h = h.substring(3);
      }
      void rejectEnvelope(String reason) {
        // A guessed header on an invalid line is not an observed ECU identity.
        frames.add(
          ObdFrameEvidence(
            'unknown',
            line,
            reason,
            structureVerdict: reason,
            transportCompletion: reply.completion,
          ),
        );
      }

      if (ecu != 'unknown') {
        final id = int.tryParse(ecu, radix: 16);
        if (ecu.length == 3 && (id == null || id < 0x700 || id > 0x7FF)) {
          rejectEnvelope('unsupported_obd_header');
          continue;
        }
        // Accept a DLC nibble only when it agrees exactly with the byte count.
        if (h.length.isOdd) {
          final dlc = int.tryParse(h[0], radix: 16);
          if (dlc == null || dlc < 1 || dlc > 8 || (h.length - 1) ~/ 2 != dlc) {
            rejectEnvelope('invalid_dlc_or_truncated_frame');
            continue;
          }
          h = h.substring(1);
        }
        if (h.isEmpty || h.length > 16) {
          rejectEnvelope('invalid_can_frame_length');
          continue;
        }
      }
      if (h.length.isOdd || h.isEmpty || !RegExp(r'^[0-9A-F]+$').hasMatch(h)) {
        rejectEnvelope('invalid_hex');
        continue;
      }
      final b = [
        for (var i = 0; i < h.length; i += 2)
          int.parse(h.substring(i, i + 2), radix: 16),
      ];
      final type = b[0] >> 4;
      if (ecu != 'unknown' && type > 2) {
        rejectEnvelope('unexpected_pci');
        continue;
      }
      if (type == 0) {
        final old = pending.remove(ecu);
        if (old != null) emit(ecu, old.bytes, 'incomplete_multiframe');
        final len = b[0];
        if (ecu != 'unknown' && (len == 0 || len > 7 || b.length < len + 1)) {
          rejectEnvelope('short_frame');
          continue;
        }
        emit(
          ecu,
          b.skip(1).take(len).toList(),
          len == 0 || len > 7 || b.length < len + 1 ? 'short_frame' : null,
        );
      } else if (type == 1 && b.length >= 2) {
        final declared = ((b[0] & 15) << 8) | b[1];
        if (b.length != 8 || declared <= 7) {
          rejectEnvelope('invalid_first_frame');
          continue;
        }
        final old = pending.remove(ecu);
        if (old != null) {
          emit(ecu, old.bytes, 'ambiguous_or_incomplete_multiframe');
          if (ecu == 'unknown') ambiguousUnknown = true;
        }
        pending[ecu] = _Assembly(
          ecu,
          ((b[0] & 15) << 8) | b[1],
          b.skip(2).toList(),
          1,
        );
      } else if (type == 2) {
        final a = pending[ecu];
        if (a == null || (b[0] & 15) != a.next) {
          emit(ecu, b, 'orphan_or_out_of_order_frame');
          final old = pending.remove(ecu);
          if (old != null) emit(ecu, old.bytes, 'incomplete_multiframe');
        } else if (b.length < 2 ||
            b.length > 8 ||
            b.length - 1 < (a.length - a.bytes.length).clamp(0, 7)) {
          pending.remove(ecu);
          rejectEnvelope('short_consecutive_frame');
        } else {
          a.bytes.addAll(b.skip(1));
          a.next = (a.next + 1) & 15;
          if (a.bytes.length >= a.length) {
            emit(
              ecu,
              a.bytes.take(a.length).toList(),
              ecu == 'unknown' && ambiguousUnknown ? 'ambiguous_origin' : null,
            );
            pending.remove(ecu);
          }
        }
      } else {
        emit(ecu, b);
      }
    }
    finishNumbered();
    for (final a in pending.values) {
      emit(a.ecu, a.bytes, 'incomplete_multiframe');
    }
    if (frames.isEmpty) {
      frames.add(
        ObdFrameEvidence(
          'unknown',
          '',
          reply.complete ? 'empty_response' : reply.completion,
        ),
      );
    }
    if (frames.any(
      (f) => const [
        'adapter_status',
        'adapter_stopped',
        'no_data',
      ].contains(f.verdict),
    )) {
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        if (f.positive) {
          frames[i] = ObdFrameEvidence(
            f.ecu,
            f.payload,
            'adapter_failure_with_payload',
          );
        }
      }
    }
    final damaged = frames.any(
      (f) => !const {
        'positive',
        'negative_response',
        'wrong_negative_service',
        'wrong_service_or_pid',
        'adapter_searching',
        'no_data',
      }.contains(f.structureVerdict ?? f.verdict),
    );
    if (damaged) {
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        if (f.positive) {
          frames[i] = ObdFrameEvidence(
            f.ecu,
            f.payload,
            'malformed_exchange',
            structureVerdict: f.structureVerdict,
            transportCompletion: reply.completion,
          );
        }
      }
    }
    final positive = frames.any((f) => f.positive);
    return ObdResponseEvidence(
      frames,
      positive
          ? 'matched_response'
          : frames.map((f) => f.verdict).toSet().join(', '),
    );
  }
}
