import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/elm_obd_response.dart';

ObdResponseEvidence parse(
  String raw,
  String cmd, {
  String completion = 'prompt',
}) => ElmObdParser.classify(ElmReply(raw, completion), cmd);
void main() {
  test('legal 7F data versus service-scoped NRC', () {
    expect(parse('410D7F\r>', '010D').positive, isTrue);
    final r = parse('7E8 03 7F 01 12 00 00 00 00\r>', '010D');
    expect(r.positive, isFalse);
    expect(r.frames.single.service, 1);
    expect(r.frames.single.nrc, 0x12);
    expect(r.reason, 'negative_response');
    expect(parse('7F2212>', '010D').reason, 'wrong_negative_service');
  });
  test('echo, service, PID/DID and length are mandatory', () {
    for (final raw in [
      '010D\r>',
      '410C1234>',
      '490D7F>',
      '410D>',
      '410C12>',
      '410D1234>',
      '62102511>',
      '610411>',
    ]) {
      expect(
        parse(raw, raw.startsWith('62') ? '221024' : '010D').positive,
        isFalse,
        reason: raw,
      );
    }
    expect(parse('6210247F>', '221024').positive, isTrue);
    expect(parse('61117F>', '2111').positive, isTrue);
    expect(parse('4104FF>', '0104').positive, isTrue);
  });
  test('adapter status and incomplete replies fail closed', () {
    for (final raw in [
      'SEARCHING...',
      'STOPPED',
      'NO DATA',
      'UNABLE TO CONNECT',
      '?',
      'BAD HEX',
    ]) {
      expect(parse(raw, '010D').positive, isFalse, reason: raw);
    }
    expect(parse('410D7F', '010D', completion: 'timeout').positive, isFalse);
    expect(parse('SEARCHING...\r410D7F\r>', '010D').positive, isTrue);
    expect(
      parse('SEARCHING...410D7F\r>', '010D').frames.first.verdict,
      'adapter_searching',
    );
  });
  test('ATH0/ATH1 and ATS0/spaces; no ECU matching inside payload', () {
    for (final raw in [
      '41 0D 7F>',
      '410D7F>',
      '7E8 03 41 0D 7F 00 00 00 00>',
      '7E803410D7F00000000>',
      '7E8 8 03 41 0D 7F 00 00 00 00>',
    ]) {
      expect(parse(raw, '010D').positive, isTrue, reason: raw);
    }
    expect(parse('41 0C 7E A0>', '010C').frames.single.ecu, 'unknown');
    expect(
      parse(
        '7E8 03 41 0D 01\r7EA 03 41 0D 02>',
        '010D',
      ).frames.map((f) => f.ecu),
      ['7E8', '7EA'],
    );
    expect(parse('7E8 02 41 0C\r7EA 02 1F 40>', '010C').positive, isFalse);
  });
  test('ELM numbered VIN length and order, unknown origin', () {
    const vin =
        '014\r0: 49 02 01 31 44 34\r1: 47 50 30 30 52 35 35\r2: 42 31 32 33 34 35 36\r>';
    final r = parse(vin, '0902');
    expect(r.positive, isTrue);
    expect(r.frames.single.ecu, 'unknown');
    expect(r.frames.single.payload.length, 40);
    expect(parse(vin.replaceFirst('1:', '3:'), '0902').positive, isFalse);
    expect(parse(vin.replaceFirst('014', '015'), '0902').positive, isFalse);
    expect(
      parse(vin.replaceFirst('2: 42 31 32 33 34 35 36', ''), '0902').positive,
      isFalse,
    );
  });
  test('interleaved CAN multiframe replies stay per ECU', () {
    final r = parse(
      '7E8 10 0A 62 10 24 01 02 03\r7EA 10 0A 62 10 24 AA BB CC\r7EA 21 DD EE FF 7F 00 00 00\r7E8 21 04 05 06 07 00 00 00\r>',
      '221024',
    );
    expect(r.frames.map((f) => f.payload), [
      '621024AABBCCDDEEFF7F',
      '62102401020304050607',
    ]);
    expect(r.frames.every((f) => f.positive), isTrue);
    expect(
      parse(
        '7E8 10 0A 62 10 24 01 02 03\r7EA 21 04 05 06 07\r>',
        '221024',
      ).positive,
      isFalse,
    );
    expect(
      parse(
        '7E8 10 0A 62 10 24 01 02 03\r7E8 22 04 05 06 07\r>',
        '221024',
      ).positive,
      isFalse,
    );
  });
  test('malformed data and unknown command fail closed', () {
    expect(parse('7E8 03410D1>', '010D').positive, isFalse);
    expect(parse('OK>', 'ATSH7DF').positive, isFalse);
    expect(parse('410DFF>', '1234').positive, isFalse);
  });
  test('Mode 09 record lengths and private echo-only replies fail closed', () {
    expect(parse('49060112345678>', '0906').positive, isTrue);
    expect(parse('490601123456>', '0906').positive, isFalse);
    expect(parse('49060212345678>', '0906').positive, isFalse);
    expect(parse('621024>', '221024').positive, isFalse);
    expect(parse('6111>', '2111').positive, isFalse);
  });
  test('standard support bitmaps require four data bytes', () {
    for (final pid in ['00', '20', '40', '60']) {
      expect(parse('41${pid}7F000001>', '01$pid').positive, isTrue);
      expect(parse('41${pid}7F0000>', '01$pid').positive, isFalse);
    }
  });
  test('STOPPED with payload is still an interrupted adapter response', () {
    expect(parse('410D7F\rSTOPPED>', '010D').positive, isFalse);
  });
  test('ELM numbered long reply sequence wraps F to 0', () {
    final chunks = <String>[
      '62 10 24 01 02 03',
      ...List.filled(16, '04 05 06 07 08 09 0A'),
    ];
    final lines = List.generate(
      chunks.length,
      (i) => '${(i & 15).toRadixString(16)}: ${chunks[i]}',
    ).join('\r');
    final raw = '076\r$lines\r>';
    expect(parse(raw, '221024').positive, isTrue);
    expect(parse(raw, '221024').frames.single.payload.length, 236);
  });
}
