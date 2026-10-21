# iPhone and vehicle music playback

The music player has an explicit **本机 / 车机** output choice. The home controls, favorites,
queue browser, search and player transport use the selected output. Local playback streams one
NetEase song at a time through the configured backend; it does not import files or download the
whole playlist. The native iOS bridge uses AVPlayer, an exclusive playback audio session and
background audio. An interruption or lost audio route pauses playback. App opening and reconnects
never start playback.

## Transfer protocol

- Phone to car: copy the immutable queue into the car scope, prepare the selected song silently at
  its position, await the car's applied ACK, pause the phone, then request car resume. A car must
  advertise both `queue_v2` and `handoff_v1`; older cars cannot safely honor silent preparation.
- Car to phone: copy the car's exact versioned queue to a private phone session, prepare the phone
  silently, pause the car, await its applied ACK and fresh paused status, then start the phone if
  the source was playing. A paused source stays paused. Changed song/queue or failed import stops
  the transfer with an explicit message.
- Each transfer step has a stable command ID. Unknown results remain pending confirmation; retries
  reuse that ID. Cancellation never automatically resumes a source that might overlap an uncertain
  remote start. The phone refuses sound until the unresolved remote result has been checked.
- ACK and engine play receipts are execution evidence. Native time-control events and fresh car
  status drive actual playback presentation; neither proves audible output in the vehicle.

Default, list loop and shuffle use the complete verified Owner favorite snapshot, with strict
versioned pagination. Heart uses authentic upstream intelligence and bounded continuation. A failed
heart request leaves the previous queue intact. Search singles stop on completion; explicitly
choosing loop/shuffle returns to the complete favorite playlist. Transfer preserves song, source,
queue contents, cursor, position, mode and play/pause intent. Shuffle order is rebuilt around the
preserved cursor on the destination.

## Isolation and checks

Phone actual state never uses vehicle WS/status patches. Server scopes derive from the authenticated
account and an opaque phone session; local routes do not mutate car actual/pending state. Only an
applied car ACK promotes a prepared car queue. Account, origin, device and NetEase account changes
invalidate phone work and clear media; late HTTP/native completions cannot revive it. Owner changes
also fence in-flight server queue creation. Authenticated media headers go only to the canonical
same-origin HTTPS backend stream. Account metadata caches retain their existing isolation rules.

Run backend `pytest`, both Flutter suites and analysis, Android debug build and iOS Release build.
The local playback tests exercise the real HTTP adapter, WS consumer, MethodChannel and player UI
against isolated fakes; the car tests use the real sync/controller/player pipeline with fake audio.
Device installation, audio routes, background execution and audible bidirectional transfer still
require separate device verification. Install matching mobile and car builds together before using
phone-to-car handoff.
