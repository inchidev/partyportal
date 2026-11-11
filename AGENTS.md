# AGENTS.md — working on PartyPortal

Read this before the first edit. What the product does for people is in [README.md](README.md); this file is how
it is put together and how not to break it.

## In two lines

A macOS app shares one window as a link. The host captures and encodes on the Mac, the guest decodes in a browser,
and every rule about what the guest may see or do is enforced on the host.

## Map

```
Sources/partyportal/
  main.swift         flags, menu bar item, --check
  Core.swift         all state: one window, one guest, host panel API, 0.1 s window monitor, bitrate adaptation
  Capture.swift      ScreenCaptureKit single-window capture; FakeSource (known picture + tone)
  Masker.swift       masked copy of a frame (no copy → no frame); host preview JPEG
  Encoder.swift      VideoToolbox H.264, no B-frames, AVCC + avcC out
  Audio.swift        app audio → Opus, 20 ms packets, silence is not sent
  Server.swift       HTTP + WebSocket on Network.framework, no dependencies
  Input.swift        InputController (rules, what is held) → RealInput (CGEvent), BackgroundInput (events addressed
                     to the app, no pointer or focus involved) or DryInput (log)
  InputPolicy.swift  pure functions: shortcuts, zones; browser key → macOS key table
  AX.swift           Accessibility: window buttons, focus, frame, "what is under the pointer"
  VirtualDisplay.swift  a software-only monitor (CGVirtualDisplay) the shared window is parked on in background mode
  Bridge.swift       the WebRTC peer: web/bridge.html in a 2×2 px WebKit window
  HostApp.swift      the Mac app around the core: window with the panel (a web view on web/host.html), menu bar mark that changes colour, main menu
  Tunnel.swift       cloudflared quick tunnel with its own empty config
  Turn.swift         optional TURN relay: mints short-lived Cloudflare credentials from a local key (turn.json, never in the repo or the panel)
Sources/testwin/     a window made for testing (logs events to $TMPDIR/partyportal-testwin.log)
web/guest.html       guest page: media track → <video> over the canvas (or WebCodecs → canvas), Web Audio, mouse/keys/touch → host
web/host.html        host panel
web/bridge.html      runs inside the app: WebSocket from Core ↔ WebRTC to the guest (video as a media track from a worker, the rest in data channels)
site/                the landing page (static)
tools/smoke.mjs      protocol check without a browser
Tests/               unit tests for InputPolicy and settings
```

## Flows

**Video.** `FrameSource.onFrame` (video queue) → `Core.handleFrame` → masks → `H264Encoder` → `Core.videoFrame`
(encoder thread) → the current sink: the guest's WebSocket, or the bridge's WebSocket when a direct connection is up.
Wire format, binary: `[1][key flag][timestamp, 8 bytes BE, µs][AVCC]` for video, `[2][0][timestamp][Opus packet]`
for audio. The codec config is JSON `{type:"video", codec, description, width, height}` sent before the keyframe.

**Direct connection.** The guest gets `hello` with ICE servers and sends an offer over the WebSocket; Core relays
it to the bridge page, which answers. Three data channels: `video` (reliable, frames split into 60 KB pieces,
first byte 1 marks the last piece, config travels on the same channel as text), `audio` (unreliable), `ctl`
(guest input, pings). When all three are open the bridge says `open` and Core switches the sink. Anything fails →
back to the WebSocket.

**Input.** Guest JSON (`m` move, `r` relative move, `d`/`u` button, `w` wheel, `k` key, `control`, `release`) →
`Core.guestCommand` → `InputController.handle` → policy → backend. `RealInput.pauseReason` decides whether input
may flow at all (accessibility, lock screen, window in front).

**Background or takeover.** `settings.background.mode` picks the backend. "background" is the default:
`BackgroundInput` posts events to the app's pid through SkyLight with the window id stamped on them, so nothing
is paused by focus and `pauseReason` stays nil. "takeover" is `RealInput`, the host's own pointer; it is also what
you get when the SkyLight calls are missing. `AppCompat` names engines known to read the pointer from the system
(the guest is then told "keyboard only").
If `park` is on, `Core.park` creates a `VirtualDisplay`, moves it so it touches the main screen at a corner only,
and moves the window there with Accessibility; `unpark` reverses it. Both can be switched while sharing
(`switchBackground`). A full-screen window is left on its own Space.

**Threads.** Everything in Core runs on the main queue; frames on `videoQ`; the few values both touch are behind
`Core.lock`. A `generation` counter makes frames from a stopped source harmless.

## Checking your work

```bash
swift test
.build/debug/partyportal --fake --no-open --token t        # then: node tools/smoke.mjs 7374 t
PP_FAKE_NOISE=1 .build/debug/partyportal --fake            # full-bitrate stream for transport measurements
.build/debug/partyportal --dry-input --window "PartyPortal Test"   # real capture, logged input
```

- Verify video by pixels: in `--fake` the quadrants are (200,40,40), (40,160,60), (40,80,200), (220,180,40) and
  the white box is at x 0.55–0.90, y 0.10–0.22. The guest page exposes `window.__pp` (state, fps, audio counters,
  `late` = how far behind the best case frames arrive, `trace` for per-frame timing).
- In track mode read `window.__pp.track` instead (fps, kbps, `freeze` ms, lost %, size, jitter buffer ms) and
  `bridgeDiag.track` in `/api/state` for the sender's side (encoder fps, size, `limit`, WebRTC's `budget`).
  Take pixels from the `<video id="tv">`, not the canvas — the canvas is stale while a track plays.
- The menu bar mark cannot be screenshotted from a script: `partyportal --mark-preview out.png` draws every
  state on a light and a dark strip. The window's page is web/host.html — look at it in a browser at the panel's
  address. Both pages share one palette (Discord-like) and one rule: controls in a row have one height
  (48 px in the guest's tray, 32 px in the panel, 24 px for the small ones).
- Transport knobs: `#relay=1` in a guest link forces the TURN relay, `#track=0` forces the data channel;
  `PP_ICE=local` drops STUN and TURN (same-network path only), `PP_FIXED_KBPS=1` stops bitrate adaptation,
  `PP_FAKE_FULL_FPS=1` lets the test picture run at the configured rate instead of 30.
- `PP_FAKE_NOISE` is incompressible on purpose: at low bitrates VideoToolbox drops to a few fps by itself and
  WebRTC shrinks the picture. Read neither as transport loss.
- The test window answers signals: `SIGUSR1` resize, `SIGUSR2` close, `SIGHUP` toggle full screen, `SIGALRM`
  toggle a −48 dB tone (inaudible, easy to measure).
- A child process started from a terminal inherits that terminal's Screen Recording permission, not Accessibility.
  Without Accessibility, use `--dry-input`.

## Traps already stepped on

- **A locked screen breaks measurements.** Windows stop drawing (ScreenCaptureKit delivers nothing) and macOS
  slows the bridge page down (pauses of ~200 ms show up as `inGap` and as freezes at the guest). Only `--fake`
  is worth running then, and its freeze counts are inflated.
- **Data channels are not a media transport.** SCTP reads loss as congestion: at 2–3% loss on a phone hotspot the
  video channel carried under 1 Mbps, seconds late, where the same path held 2 Mbps of plain UDP. That is why
  video moved to a media track; keep sound and input small enough not to care.
- **WebKit hides the Mac's LAN address** behind a `.local` name the guest's browser may not resolve (seen on a
  phone hotspot: no same-network path at all). `Bridge.swift` switches that filtering off.
- **The bridge window must be visible.** A WebKit page that is hidden, off screen or covered is paused for about
  220 ms out of every 330; frames then arrive in clumps, up to 230 ms late. Hence the 2×2 px window in a screen
  corner, on every Space including full-screen ones. Private WebKit switches for this were tried and do nothing.
- **Do not run the app from `~/Documents`, `~/Desktop` or `~/Downloads`.** VideoToolbox scans the folders around
  the bundle when the first encoder is created, macOS shows a folder-access prompt, and the video queue blocks
  until it is answered. `build-app.sh` installs to `~/Applications`.
- **Full screen is not a closed window.** While a window animates into or out of full screen it disappears from
  the window list for a moment, and the capture may stop. Core waits, and restarts the capture if the window lives.
- **Never send the original frame when masks exist.** Masks go on a copy from our own pool; ScreenCaptureKit's
  buffers are not modified. `hideRects` is set before the encoder exists.
- **Clicks need a hit-test, not just coordinates.** Other windows, alerts and menus can sit over the shared window.
  Transparent full-display overlays of other apps are ignored; everything else in front blocks the click.
- **Never reach into the shared app.** No injected libraries, no hooks, no patching, whatever it would fix. A shim
  inside a game was tried (it did give the guest a pointer of their own) and was removed on principle.
- **A background window spends its first click on becoming key.** `BackgroundInput` sends a key-window record and
  a primer press just outside the window's corner first; without them the first click is lost.
- **A wheel event's window-location stamp is window-local on every macOS**, unlike a click's (a screen point before
  macOS 27). With a screen point the event reaches the app and then finds no view under it. It also wants the
  window owner's connection in field 52 and must be posted once: posted twice it arrives as one event of double size.
- **`CGEvent.postToPid` is not enough for the mouse.** Keys arrive, clicks do not; the SkyLight call does both.
- **An init called through a C function pointer returns an owned object.** Declare it `Unmanaged` and take the
  retained value, or the object leaks; that is how a virtual display once outlived the share that made it.
- **Our own window moves are not the guest's.** Parking and unparking set `ownMoveUntil` so the frame guard does
  not drag the window back to a display that no longer exists.
- **The config must arrive before its keyframe.** That is why it travels on the video channel in direct mode.
- **Browsers on macOS swallow key-up while ⌘ is held.** The host releases every held key when ⌘ goes up.
- **stdout is for `--print-link` only.** The journal goes to stderr.
- **A second copy must not half-start.** If the ports are taken, it exits (and opens the running copy's panel).

## Do not

- Do not load code into, hook or patch the shared app. Input from outside and system-level arrangements only.
- Do not add a dependency to the host without a very good reason.
- Do not weaken a rule to make a test pass: a guest-facing check that cannot decide must refuse.
- Do not put secrets, tokens or personal names in the repository, logs or examples.
