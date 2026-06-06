# AirFi ATP App

Clean, minimal Flutter client for the **Airfi Transport Protocol (ATP)** —
sub-500ms live video, SD playback, and two-way intercom over the ATP staging
server (`atp.airfi.in`). Built fresh on the native `airfi_atp_flutter` plugin
(VideoToolbox / MediaCodec, zero-copy texture) instead of patching the legacy
fleet app's native-HLS path.

## Screens

- **Device list** (`screens/device_list_screen.dart`) — `GET /devices`, status
  per device (online / ignition / CSQ / SD). Pull to refresh.
- **Device** (`screens/device_screen.dart`) — tabs:
  - **Live** — CAM 1-4 selector, ATP sub-stream video, listen toggle, **intercom**
    push-to-talk, fullscreen.
  - **Playback** (`screens/playback_tab.dart`) — day availability (`/history/availability/day`)
    with coverage bar + tappable intervals, From/To range, ATP main-stream playback.
- **Fullscreen** (`screens/fullscreen_screen.dart`) — landscape single channel.

## Building blocks

- `widgets/atp_stream_view.dart` — self-contained ATP surface. Triggers the
  session (`/camera` live · `/history/start` playback), waits for publisher
  warm-up, opens the ATP WS, renders the native player, re-boots on param change,
  one 15s no-frame auto-retry, connecting/error overlays.
- `api/atp_api.dart` — REST client (`/devices`, `/camera`, `/history/start`,
  `/history/availability/day`, `/talkback/start`, `/talkback/stop`).
- `config.dart` — server base + WS URL builders. Override at build time:
  `--dart-define=ATP_API=… --dart-define=ATP_WS=…`.

## Intercom (talkback)

Two-way G.711A over the server's `/ws/talkback` relay.

- `talkback/talkback_controller.dart` — orchestration: mic permission →
  **release all live ATP tile audio** (`AirfiAtpController.pauseAllAudio`) →
  `/talkback/start` → relay WS → mic uplink (a-law, 1024-byte chunks) + downlink
  playback.
- `talkback/talkback_ws_service.dart` · `talkback_audio_service.dart` ·
  `g711a_codec.dart`.
- iOS native: `ios/Runner/TalkbackAudioPlugin.swift` (channel
  `com.airfi.talkback/audio`), registered in `AppDelegate.swift`.

### Why audio is exclusive while talking

The legacy app ran **three** `AVAudioEngine`s (ATP alaw player, ATP aac player,
talkback) that fought over the mic HAL — the app→device uplink silently went to
zero. Here, talkback takes **exclusive** ownership: every live tile's audio
engine is released first, and the talkback engine installs its mic tap **before**
`engine.start()` (input + output HAL arm together) with voice-processing (VPIO)
enabled. The tap runs continuously; an `isRecording` flag gates forwarding, so
toggling talk never restarts the engine (no route churn, no dead tap). Native
diagnostics are routed through Dart (`tbDiag`) since `NSLog` doesn't surface in
`flutter run`.

## Run

```sh
flutter run --profile -d <iphone-id>          # ATP staging by default
# custom server:
flutter run --profile --dart-define=ATP_API=https://atp.airfi.in \
                      --dart-define=ATP_WS=wss://atp.airfi.in -d <iphone-id>
```

iOS only is wired for native intercom (mic plugin). Live/playback video works on
Android too (MediaCodec). Profile/release recommended on device — debug JIT can
hit `EXC_BAD_ACCESS` in the native decoder.

## R&D devices on staging

`051080578636` (N6, HEVC, continuous ref) · `879082341381` (M09A, H264) ·
`846066476499` · `813080941753` (H264).
