# OBD notification evidence and bounded recovery

This implementation fixes reproducible receiver/reporting failures; it does not establish the cause of any vehicle-side missing bytes or validate a fuel PID. The 1400 ms scan budget remains unchanged. The original 57 probes are now split into explicit [manual diagnostic modules](obd-diagnostic-modules.md), with Mode 09 excluded from the default basic path. No CFC/CAF policy, retry, reset, empty-CR interrupt, single-source mapping, or adaptive extension is introduced.

## Receive boundaries and writes

The first `>` completes exactly one exchange. Anything after it, including notifications delivered during the write/protection interval, is quarantined. Non-whitespace trailing bytes require a new prompt before a later command can be written. Old bytes/prompts cannot satisfy another PID. Non-ASCII bytes are preserved with Latin-1 in text and exact hexadecimal in the byte journal; malformed input is rejected rather than converted into valid data.

A timed-out native write is still pending until its actual future settles: Dart `Future.timeout` does not cancel it. A prompt alone cannot release this pending-write fence. Serial ownership continues to exclude manual commands and whole polling sequences during a scan.

## Evidence and local storage

Each BLE callback records its original bytes, length, notification sequence, transaction ID, wall time and monotonic microseconds. Exchanges record their start/deadline, write start/completion, first/last RX, byte/notification counts, prompt time and actual elapsed duration. MTU is observed from the negotiated result and MTU stream; unavailable values remain null.

An ordered native worker writes JSONL to `noBackupFilesDir/obd_transport_sessions/<session>/part_*.jsonl`, with no network/backend dependency. It does not block the BLE callback on disk I/O. Disk errors and bounded-flush failures are reported; a queued event is not called persisted until the native sink acknowledges it. These files can contain VIN/CALID and remain private, excluded from backups. No automatic upload/share is added.

Schema 3 introduced the byte journal; schema 4 additionally identifies the selected module and exact planned range. JSON reports include a frozen `transport_events` capture and `transport_storage` status. Markdown serializes the same event maps, plus JSON-escaped response strings so CR/LF remain unambiguous. Post-timeout fragments are captured even without a later prompt; the bounded passive late-data window continues after the core report cutoff (see the current session/export policy below). Late bytes are not attached to a different request. User-triggered copy/save/share retains the sensitive-data confirmation.

## Restoration and failure classification

There is one passive synchronization decision per scan restoration, bounded to 500 ms. Its elapsed time is separate from zero-wait, unsent restore entries. Other unsynchronized exchanges report the actual time spent waiting. With no prompt, no follow-up command is sent. A late prompt can permit restoration only when the native write has settled and no trailing fragment remains.

Only ACK-observed original Header, display and formatting settings are restored, and every actual restore requires `OK`. Unknown originals are recorded `unknown_original_not_restored`; no broadcast/ATH0/CAF1 fallback is described as original-state restoration. Missing original settings, missing synchronization or failed ACK keeps polling suspended. A completed probe list with unconfirmed restoration is `completed_restore_unconfirmed`. The debug dialog exposes the suspension and storage status. Cancellation/disconnection cannot make the finally block invent ACKs.

The parser validates classic-CAN frame size and optional DLC rather than dropping arbitrary nibbles. Damaged/truncated envelopes retain unknown origin. The supported 11-bit OBD header family is `700–7FF`, plus recognized 29-bit OBD headers; this is not a generic CAN monitor. It does not infer an ECU from a `030` damaged line. Duplicate/missing/out-of-order CF or a malformed stream cannot produce a matched success. Structure verdict and transport completion are retained independently, including during timeout.

## Validation and vehicle boundary

Offline tests use the actual service writer/receiver, with arbitrary byte splits, CR/LF and prompt boundaries, trailing bytes, multiple ECUs, missing/duplicate/out-of-order CF, late prompts, continuing promptless fragments, cancellation/disconnection, failed restore ACK, pending native writes, real gate timing, byte conservation, storage failure and JSON/Markdown equivalence. Native journal compilation is checked by the Android release build; on-device journal persistence still needs explicit runtime acceptance.

Vehicle installation is a separate operation from vehicle communication acceptance. No build, passing fake transport test or successful installation proves that the original multi-ECU `0904` will complete on this adapter. Fuel candidates remain unverified; this change neither assigns fuel litres nor enables fuel polling. Fuel-specific diagnostics should be separate from VIN/CALID acquisition.

Detailed logging is now restricted to bounded manual-test sessions, with full native JSONL included in sensitive-confirmed export bundles. See [diagnostic log bundles](obd-diagnostic-log-bundle.md) for lifecycle, durability, rotation and incomplete-export semantics; this supersedes the earlier always-on journal/export description.
