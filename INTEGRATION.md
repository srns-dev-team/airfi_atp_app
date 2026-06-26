# ATP Integration Guide — iOS & Android (Staging)

How to integrate the **Airfi Transport Protocol (ATP)** native Flutter player
and its REST/WebSocket backend into a Flutter app, pointed at the **staging**
server `atp.airfi.in`. Covers the private pub server, platform setup, the full
API surface (every endpoint + method + payload), the live/playback WS protocol,
talkback, and known gotchas.

> Staging only. Server: `https://atp.airfi.in` (REST) / `wss://atp.airfi.in`
> (WebSocket). This is the dedicated ATP stack (EC2 `65.0.92.8`), **not** prod.

---

## 1. The plugin (`airfi_atp_flutter`)

Native zero-copy player: iOS **VideoToolbox**, Android **MediaCodec**, rendered
to a Flutter texture. Distributed via the **Airfi private pub server** — no repo
access needed.

`pubspec.yaml`:

```yaml
dependencies:
  airfi_atp_flutter:
    hosted: https://atp.airfi.in:4443
    version: ^0.1.0
```

Then:

```sh
flutter pub get
```

Public API (exported from `package:airfi_atp_flutter/airfi_atp_flutter.dart`):

| Symbol | Purpose |
|--------|---------|
| `AirfiAtpController` | Opens the ATP WS, feeds the native decoder, exposes stats |
| `AirfiAtpPlayer` | Widget that hosts the native texture for a controller |
| `AtpPacket`, `AtpType` | Binary TLV packet codec (control frames: resync, etc.) |

---

## 2. Platform setup

### iOS

- **Min**: arm64 device (no simulator — VideoToolbox HW decode). Profile/release
  build on device; debug JIT can hit `EXC_BAD_ACCESS` in the native decoder.
- **Signing**: team `MF4TJDK3NM`, bundle `com.airfi.airfiAtpApp` (use your own
  bundle id in a fresh app).
- **Info.plist** (only if you use talkback):
  ```xml
  <key>NSMicrophoneUsageDescription</key>
  <string>Microphone is used for two-way intercom (talkback) with vehicle cameras.</string>
  ```
- **Podfile** (talkback): set `PERMISSION_MICROPHONE=1` macro so the mic prompt
  fires.
- ATS: `wss://`/`https://` to `atp.airfi.in` is TLS — no cleartext exception
  needed.

### Android

- **Manifest permissions**:
  ```xml
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.RECORD_AUDIO"/>   <!-- talkback only -->
  ```
- MediaCodec HW decode — works on real devices; emulator unreliable.
- Live + playback video work on Android. Native intercom is wired on iOS;
  Android talkback uses the ported `TalkbackAudioPlugin.kt` path.

---

## 3. Config & staging endpoints

Defaults already point at staging. Override at build time:

```sh
flutter run --profile \
  --dart-define=ATP_API=https://atp.airfi.in \
  --dart-define=ATP_WS=wss://atp.airfi.in \
  -d <device-id>
```

`Config` URL builders (see `lib/config.dart`):

```dart
// live/playback stream WS  (streamType: 1=sub [live default], 0=main [playback])
//   wss://atp.airfi.in/atp/<live|playback>/<deviceId>/cam<channel>_<sub|main>
Config.streamWsUrl(deviceId: …, channel: 1, streamType: 1, live: true);

// talkback relay WS
//   wss://atp.airfi.in/ws/talkback?deviceId=…&channel=…
Config.talkbackWsUrl(deviceId: …, channel: 1);

// resolve evidence/download URL: absolute S3 stays, relative gets apiBase prefix
Config.resolveMediaUrl(url);
```

**Stream policy**: live = sub (`streamType 1`), playback = main (`streamType 0`).
Matches fleet practice.

---

## 4. REST API

Base: `https://atp.airfi.in`. All POST bodies are JSON
(`content-type: application/json`). Success = HTTP 200; non-200 throws.
Reference client: `lib/api/atp_api.dart`.

### Devices

| Method | Path | Body / Query | Response |
|--------|------|--------------|----------|
| GET | `/devices` | — | `{ devices: [ {deviceId, online, ignition, csq, sd, …} ] }` |

### Live

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/camera` | `{deviceId, channel, streamType}` | `{ok: bool}` — starts live publisher |

After `ok`, wait ~1.5s publisher warm-up, then open the live WS (§5).

### Playback (SD card)

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/history/availability/day` | `{deviceId, date:"YYYY-MM-DD", channel}` | `{availability:{slots15m:[…], coveragePercent}, files:[ResourceRecord], …}` |
| POST | `/history/start` | `{deviceId, channel, streamType, startTime, endTime, waitReady:false}` | `{ok: bool}` |

- Times are **device-local** `"YYYY-MM-DD HH:mm:ss"`.
- Use `files` (raw per-file `ResourceRecord`s), **not** the merged `intervals`,
  for the real clip list. Each file carries verbatim start/end that feed
  `/history/start` and `/history/download`.
- `availability` (0x9205) is flaky: device may ignore the first request →
  **retry once** on an empty-but-error-free result. Timeout ~45s.
- `/history/start` timeout ~25s (a switch does ACK-gated 0x9202 STOP + ~3s
  settle server-side). Pass `waitReady:false` — the ATP client opens its own WS
  and doesn't consume the server's HLS readiness wait.
- After `ok`, wait ~3.5s (SD seek) before opening the playback WS.

### Download (server-side async)

| Method | Path | Body / Query | Response |
|--------|------|--------------|----------|
| POST | `/history/download` | `{deviceId, channel, streamType, startTime, endTime, quality, backend?}` | `{downloadJob:{jobId, status, …}}` |
| GET | `/download/jobs` | — | `{jobs:[DownloadJob]}` |
| GET | `/download/status` | `?jobId=…` | `{job: DownloadJob}` |
| POST | `/download/cancel` | `{jobId}` | `{ok: bool}` |

- `quality`: `"full"` (720p) or `"mobile"` (540p). `streamType` default 0 (main).
- `backend` (testing): `"ftp"` = FTP-pull only, `"record"` = bridge/playback
  record only, `""`/`"auto"` = default chain.
- Job is async: poll `/download/status` with `jobId` until terminal. Result URL
  may be absolute S3 or relative — run through `Config.resolveMediaUrl`.

### Alerts / evidence

| Method | Path | Query | Response |
|--------|------|-------|----------|
| GET | `/alerts` | `?deviceId=…&limit=50` | `{alerts:[ {…, evidence:[imageUrl]} ]}` newest-first |

Evidence image URLs may be absolute S3 or relative (`/evidence/file/…`) — resolve
with `Config.resolveMediaUrl`. Staging nginx must proxy `/alerts` + `/evidence/`.

### Talkback (two-way intercom)

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/talkback/start` | `{deviceId, channel}` | `{ok:true, wsPort}` |
| POST | `/talkback/stop` | `{deviceId, channel}` | `{ok: bool}` (best-effort) |

---

## 5. Live / Playback WS protocol

Open `Config.streamWsUrl(...)` and hand it to an `AirfiAtpController`. The
controller speaks the ATP binary TLV protocol; you don't parse frames yourself.

```dart
final controller = AirfiAtpController(
  wsUrl: Config.streamWsUrl(
    deviceId: deviceId, channel: 1, streamType: 1, live: true),
  reconnectMaxAttempts: 4,                 // gentle — see gotchas
  reconnectDelay: const Duration(seconds: 2),
  onState: (s) { /* 'connecting','max-reconnects','server-bye', … */ },
  onError: (e) { /* … */ },
);
controller.addListener(() {
  final st = controller.stats; // vNaluCount, vNaluKey, keepaliveCount, lastVideoPtsUs
});
controller.start();              // open WS + decode
// AirfiAtpPlayer(controller: controller, fit: BoxFit.contain) in the tree
```

`AirfiAtpController` API:

| Member | Notes |
|--------|-------|
| `start()` | Open WS + decoder. Idempotent. |
| `stop()` | Close WS, free native decoder. |
| `dispose()` | Final teardown. |
| `setMuted(bool)` | Dart-side audio gate (drops AUDIO_FRAME before native). Video unaffected — use for multi-tile grids so only focused tile is audible. |
| `requestResync()` | Ask bridge to replay init + last keyframe (after decode error / freeze). |
| `getNativeDiag()` | Native decode stats map (`codec`, `sessionOK`, `framesOut`, `lastDecodeErr`, …). |
| `stats` | `vNaluCount` (first NALU = media started), `vNaluKey` (IDR count), `keepaliveCount`, `lastVideoPtsUs`. |

Health signals (from `lib/widgets/atp_stream_view.dart` — copy this state machine):

- **No media in 15s grace** → if `keepaliveCount >= 3` (transport alive, long-GOP
  IDR not landed yet) extend grace **once**; else go to **No-signal** + Retry.
- **Had media then PTS frozen >8s** → `requestResync()`. **>20s** → teardown to
  No-signal + Retry.
- `onState == 'max-reconnects'` or `'server-bye'` → teardown (don't keep
  retrying a dead/feedless channel).
- Multi-tile grid: stagger tile boot (e.g. `index × ~900ms`) so the native
  decoders don't init in the same window — simultaneous VT init contends and
  stalls all-but-one tile after the first frame.

---

## 6. Talkback WS protocol

After `POST /talkback/start` returns `wsPort`, connect
`Config.talkbackWsUrl(deviceId, channel)`. Protocol (`lib/talkback/`):

- **Binary frames** = G.711A (a-law) audio, both directions. Uplink: mic PCM →
  a-law, 1024-byte chunks. Downlink: a-law → PCM playback.
- **Text frames** = status JSON.
- Reconnect: linear backoff, **3 tries** (matches server).
- iOS: talkback takes **exclusive** mic ownership — release every live tile's
  audio engine first (`AirfiAtpController.setMuted` / pause), then start the
  talkback engine with the mic tap installed **before** `engine.start()` and
  voice-processing (VPIO) on. Don't run multiple `AVAudioEngine`s fighting the
  mic HAL or uplink silently goes to zero.
- Use standard ITU G.711A. (Inverted/mis-scaled codec was the historical
  "voice not reaching dashcam" bug.)

---

## 7. Staging device matrix (R&D)

| Device | Model | Codec | Notes |
|--------|-------|-------|-------|
| `051080578636` | N6 | HEVC | continuous ref, long-GOP |
| `879082341381` | M09A | H264 | lists playback but rarely streams it |
| `846066476499` | — | — | |
| `813080941753` | — | H264 | |

- Only **N6** reliably streams `0x9201` SD playback. M09A/846 list recordings
  (`0x9205`) but often never stream — device firmware, not a backend bug.
- N6 has a ~3 concurrent stream cap; a 4-up grid may show only 3 channels live.

---

## 8. Gotchas

- **Don't churn controllers.** A feedless channel must go QUIET (dispose), never
  loop upgrade→close→reconnect — that wedges the MDVR's JT1078 slots. Keep
  `reconnectMaxAttempts` low (4) and `reconnectDelay` slow (2s).
- **Profile/release on device** for iOS — debug JIT crashes the native decoder.
- **Times are device-local**, not UTC. Pass `availability` file start/end
  verbatim into start/download.
- **Resolve media URLs** through `Config.resolveMediaUrl` — server returns
  absolute S3 or relative paths depending on the S3-required path.
- **HEVC long-GOP**: first IDR can be seconds out; rely on `keepaliveCount` to
  tell "transport alive, waiting for IDR" from "dead channel".
