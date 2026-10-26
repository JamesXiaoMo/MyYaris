# Manual OBD diagnostic modules

The diagnostic window now has three independent, explicitly confirmed operations. Opening the window sends no requests. All operations use the same serial ownership, prompt fence, byte journal and restoration path; an incomplete exchange stops the selected module rather than continuing after a timeout.

| Operation | Planned probes | Extra discovery | Scope |
| --- | --- | --- | --- |
| Basic candidate scan | 53: 40 Mode 01 + 13 existing private candidates | Explicit `0100` | The old four Mode 09 probes are excluded. Existing private addresses/layouts remain unverified, including the suspect `7EB` request address. |
| Fuel-specific test (unverified) | 3: `7DF/012F`, `7C0/221022`, `7C0/2129` | None | No VIN, CALID or Mode 09 prerequisite. Each request header requires a real `OK`. |
| Vehicle identifier test (separate) | 4: `0902`, `0904`, `0906`, `090A` | None | Explicit broadcast metadata queries; may return sensitive identifiers and multi-ECU long replies. This module can still fail independently. |

The fuel button does not start polling or populate `fuelLevelLiters`/`fuelLevelPercent`. It exports raw response/source, completion, frame evidence and candidate explanation. Even a complete layout match is evidence of that response, not validation of a physical fuel value or vehicle capability. `012F` is a standard percentage candidate; it is not multiplied by tank capacity. No private candidate is converted to litres.

For `7C0/221022`, the candidate contract is response ECU `7C8`, prefix `62 10 22` and exactly two data bytes. For `7C0/2129`, it is `7C8`, `61 29` and exactly one data byte. Wrong source, echo, length, negative responses, malformed frames and `NO DATA` cannot become a successful candidate match; contradictory sources/layouts reject the exchange. Negative service/NRC and raw data remain available. No Camry or other-model multiplier is applied.

These request/layout candidates were checked against the community-maintained [OBDb Toyota-Yaris fixed definition](https://github.com/OBDb/Toyota-Yaris/blob/034d3db88054f5aba9ccf1bad5a544bdc9944bd3/signalsets/v3/default.json). This is a primary copy of that community definition, not Toyota specification, Car Scanner implementation or vehicle acceptance.

Schema 4 reports state the module, its planned probe count, whether explicit `0100` is used, and its actual scope in both JSON and Markdown. Tested, matched and parsed counts retain their separate meanings. The original 57 probes remain available as 53 basic probes plus the separate four metadata probes, rather than being silently counted as one completed scan.

The application still uses the existing 1400 ms exchange budget and one bounded passive drain before restoration. Missing prompt prevents all later writes. Only ACK-observed original settings are restored and every restore requires `OK`; unknown originals or unconfirmed recovery keep polling suspended. `connected` alone never authorizes a candidate write while the serial channel is unsynchronized. No reset, empty CR, flow-control change, unlock or automatic retry is added.

Write-start journal events additionally record the actual selected write mode and characteristic properties/UUIDs. This adds observation without changing the previous write policy. The observed application stream can establish callback-to-export byte conservation; it cannot prove that earlier BLE/bridge/CAN layers delivered every original byte. A repeated response length alone does not establish a hardware buffer limit. Separating Mode 09 prevents its default inclusion from blocking fuel/basic diagnostics; it does not fix or identify the underlying multi-source transport fault.

Offline acceptance covers module selection/confirmation, exact headers/layouts, `NO DATA`/NRC, no fuel assignments, exclusive transactions, cancellation and late prompts, timeouts, ACK failure, unknown-state suspension and scope serialization. Vehicle support, source-to-request mappings for a single-ECU metadata comparison, and runtime behaviour remain separate acceptance steps. Do not guess a request address from an observed response header.
