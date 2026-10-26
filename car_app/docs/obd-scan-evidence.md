# OBD scan evidence and review boundary

The original fixed 57 candidates are now split into 53 basic probes (40 Mode 01 and 13 private) and four explicit, separate Mode 09 metadata probes. A separate manual three-candidate fuel test is also available. Only the basic module adds explicit `0100` discovery; neither fuel nor metadata requires it. No module enumerates every ECU or every supported PID. See [manual diagnostic modules](obd-diagnostic-modules.md) for the exact ranges and schema 4 fields. A historical count such as 35 responses is an observation of a particular request set, not the vehicle's complete capability.

The private address/DID mappings and formulas are unverified on this vehicle. In particular, `7EB` is a suspect request address; this change neither substitutes an invented address nor claims private support. Private matched responses remain candidate evidence without decoded engineering values. Fuel percentage is not converted into litres.

## Response evidence

The serial queue records raw replies without truncation, timestamps, elapsed time, and an explicit completion state. Only a prompt completes an exchange. Timeout, interrupted fragments, no data, adapter statuses, wrong service/PID/DID, short/invalid messages and negative service/NRC responses remain evidence. `7F` is negative only as the first byte of a correctly formed negative payload, not when it occurs inside data.

The display parser accepts headerless, spaced/compact, CAN single/multiple frames and ELM numbered multiline responses with a declared total length. CAN assemblies are isolated by received header. Unknown origin stays `unknown`. Ambiguous, missing or out-of-order fragments are rejected rather than combined across ECUs. Legacy dashboard decoders use the same matched payload selection. Unframed fragments without a total length are no longer decoded.

Counts are tested probes, matched responses, and parsed standard values. ECU discovery lists only headers actually observed on valid responses. A matched private echo plus data does not validate its expected layout or physical interpretation.

## Transactions and recovery

Scan reserves the serial channel before draining a whole in-flight polling sequence or earlier manual exchange. New manual commands and single-shot verification are rejected while a transaction owns it. Polling cannot enter the scan sequence. Every probe sets an explicit request header and requires `OK`; a failed header switch cannot be reported as a sent PID.

The current scan profile requires protocol 6/A6 (11-bit CAN, 500 kbit/s). `ATDP`/`ATDPN` are queries; scan does not silently change the protocol. It acknowledges `ATH1` and `CAF1`, then restores ACK-observed header, display and formatting in `finally`. Unknown prior settings are recorded as unknown and are not replaced with broadcast/ATH0/CAF1 fallbacks; missing original state keeps polling suspended. CFC and receive filters are untouched.

No diagnostic write is automatically retried. Commands have bounded timeouts (maximum five seconds, scan 1.4 seconds) and a 25 ms adapter protection interval. A missing prompt fences later writes. Cancellation interrupts only scan-owned exchanges; a late prompt drains the old reply before restoration. Late replies are retained separately in trace. Restoration makes one passive synchronization decision, bounded to 500 ms, before any settings are restored; skipped writes are distinguished from that measured wait. Disconnect or missing/failed restore ACK is recorded truthfully and polling remains suspended until a new connection handshake or a successfully recovered scan.

## Export and sensitivity

The car debug dialog exposes save and system-share for full JSON plus Markdown, including all successful and failed probes and transaction/recovery trace. Copy, save and share require a sensitivity notice that mentions VIN and vehicle identifiers. Native export writes to App-private `noBackupFilesDir/obd_reports`; Android backup does not include this directory. Only an explicit share copies the two files to a narrow cache FileProvider with a temporary read grant. No export path calls the backend or uploads to Git. The dialog's full report preview includes the same notice. Old shared cache copies expire on the next share after 24 hours; saved private reports remain until App data is removed.

## Evidence sources

- [ELM Electronics ELM327DSL](https://elmelectronics.com/wp-content/uploads/2020/05/ELM327DSL.pdf), pp. 14, 16, 44–46, 48–50: formatting, independent CFC flow control, default/explicit receive filters, header display and multiline framing. Absence of an explicit CRA command is not evidence of default rejection.
- [CSS Electronics PID reference](https://www.csselectronics.com/pages/obd2-pid-table-on-board-diagnostics-j1979): standard data lengths and engineering scales. Added scan formatting reuses `0104: A*100/255` and `010F: A-40`; no private formula is newly validated.

Offline Flutter tests exercise the actual service serial queue through a fake BLE writer/notification path, response parser, report serialization, and dialog export through a mocked native channel. APK compilation checks the native exporter. Vehicle responses, on-device sharing and installation are separate acceptance steps: do not infer them from passing offline tests or a successful build.

After parent review and authorized in-place installation, the smallest controlled vehicle acceptance should start with a confirmed parked vehicle, explicit standard verification, a small known standard response capture and a cancellation/recovery check. Review JSON/Markdown and actual restore ACKs before considering a full candidate scan. Do not use this change to claim CarScanner parameter parity.

The schema 3 byte journal, prompt-tail quarantine, pending-write fence, stricter envelope validation and offline acceptance are described in [OBD transport recovery](obd-transport-recovery.md). Unknown fuel candidates remain unverified.

Schema 4 modules keep the existing byte-journal/recovery guarantees. Moving metadata out of the default basic path does not permit writes after an incomplete exchange or validate fuel support.
