# AGENTS.md — working on PartyPortal

Read this before the first edit. What the product does for people is in [README.md](README.md); this file is how
it is put together and how not to break it.

## In two lines

A macOS app shares one window as a link. The host captures and encodes on the Mac, the guest decodes in a browser,
and every rule about what the guest may see or do is enforced on the host.

## Map

```
Sources/partyportal/
  main.swift         flags, app delegate, --check, --mark-preview
  Core.swift         all state: one window, one guest (or a v2 portal's viewers and who controls), host panel API,
                     0.1 s window monitor, bitrate adaptation, what the guest reports back
  Capture.swift      ScreenCaptureKit single-window capture; FakeSource (known picture + tone)
  Masker.swift       masked copy of a frame (no copy → no frame); host preview JPEG on its own queue
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
  Tunnel.swift       cloudflared quick tunnel with its own empty config; the binary is the installer's (Application Support), else Homebrew's
  PortalLink.swift   portal mode: an outbound WebSocket to a portal on an L4 Server; RelayedGuest, a guest behind it
                     (in relay protocol v2, one of several viewers, its frames wrapped with its name)
  Turn.swift         optional TURN relay: mints short-lived Cloudflare credentials from a local key (turn.json, never in the repo or the panel)
Sources/testwin/     a window made for testing (logs events to $TMPDIR/partyportal-testwin.log)
web/guest.html       guest page: media track → <video> over the canvas (or WebCodecs → canvas), Web Audio, mouse/keys/touch → host
web/host.html        host panel: a sidebar and one page at a time; the same page in the app's window and in a browser
web/bridge.html      runs inside the app: WebSocket from Core ↔ WebRTC to the guest (video as a media track from a worker, the rest in data channels)
site/                the landing page (static) and install.sh, the one-line installer it offers
scripts/             build-app.sh builds and installs the app here; package.sh makes the archive install.sh downloads
tools/smoke.mjs      protocol check without a browser (a port, or a portal page URL)
tools/portal-relay.mjs  a local stand-in for a portal and for llll.gg's POST /api/portals (relay protocol v1; v2 with
                     --v2, its SFU faked peer to peer), no dependencies
Tests/               unit tests for InputPolicy and settings
```

## Flows

**Video.** `FrameSource.onFrame` (video queue) → `Core.handleFrame` → masks → `H264Encoder` → `Core.videoFrame`
(encoder thread) → the current sink: the guest's WebSocket, or the bridge's WebSocket when a direct connection is up.
Wire format, binary: `[1][key flag][timestamp, 8 bytes BE, µs][AVCC]` for video, `[2][0][timestamp][Opus packet]`
for audio. The codec config is JSON `{type:"video", codec, description, width, height}` sent before the keyframe.

**Portal on an L4 Server.** The other way to a public link (`--portal URL --portal-key K --token T`, the link
`partyportal://portal?url=…&key=…&t=…` after the host confirms, or `POST /api/portal` on the panel's port from a
second copy). The Server (a Worker with a Durable Object) serves guest.html at `/portal/<id>` and keeps the guest's
WebSocket at `/portal/<id>/ws`; `PortalLink` dials `wss://…/portal/<id>/host`, says `{"t":"host","key":K,"v":1}`,
gets `pp.ready`, then `pp.guest` open/close around one guest whose frames pass verbatim both ways. Each open
guest is a `RelayedGuest`, which Core takes like a local socket (`GuestSocket`): the token check, hello, state,
media and input are unchanged, and the guest key is the token (the portal checks it as well). No tunnel runs and
`/api/token` refuses: the portal owns the link. Closes 4401/4404/4409/4426 (protocol: "Update PartyPortal or this
Server") and 4429 (llll.gg's `relay_limit`) are final, and so is an HTTP 404/410 instead of a socket (the portal is
gone); anything else reconnects (1 s, doubling, 30 s at most) and counts as the guest leaving. `ping`/`pong` every 20 s. When Core closes a guest (bad token, kick), its `bye`
goes first and `{"t":"pp.close"}` follows: the portal closes that guest's socket (4403) and answers `pp.guest`
open:false. A guest's own `pp.` messages are dropped by the portal. Sends never block: in-flight bytes are `pendingBytes`, and more than a few binary sends in flight
reads as a full queue, so the video sink drops and resumes on a keyframe as it does for a local socket. The page
finds its socket next to itself (`<path>/ws`) and shows `pp.wait` as "Waiting for the host" until hello comes.
`pp.ready` may carry `iceServers` (the Server's TURN): while that host connection lasts they replace TurnRelay's
for the bridge's offer and the guest's `hello`, and `hello` goes out at once instead of waiting for TurnRelay
(`PortalLink.cleanIceServers` keeps only stun/turn/turns URLs and string credentials). A frame over 1 MiB is not
sent to a portal at all: Workers refuse it, and llll.gg ends the portal for it.

**Several viewers: relay protocol v2.** `PortalLink` offers `"v":2` in its hello unless the bridge cannot make a
video track (or `PP_PORTAL_V=1`). An L4 Server with a Realtime SFU app answers `{"t":"pp.ready","v":2,"sfu":true}`;
any other answers as v1, and a Server from before v2 closes with 4426, after which the link says v1 to it from then
on (not final). In v2 the portal names each guest (`g`) and wraps every frame: `pp.guest {open, g}`, `pp.from {g,
f}` in, `pp.to {g, f}` / `pp.close {g}` out; `RelayedGuest(g:)` does the wrapping, so Core still sees one
`GuestSocket` per guest. Each one is a *viewer* (`Core.viewers`): its own token check, `hello` with `rtc: null,
sfu: true`, its own `state` (with `ask`, `asked`, `viewers`), and after the check Core sends `pp.admit {g}` — the
Server subscribes a guest to the picture only then. The picture: on `pp.ready` v2 Core asks the bridge for one
publication (`sfu-publish`); the bridge adds the VideoTrackGenerator track with simulcast `f/h/q`
(scaleResolutionDownBy 1/2/4) and the app's sound as an audio track (Opus packets → AudioDecoder → Web Audio →
MediaStreamDestination; `mediaTypesRequiringUserActionForPlayback` is empty for that), sends its offer with every
candidate in it (`sfu-offer` → `pp.sfu.publish`), and applies the SFU's answer (`pp.sfu.answer` → `sfu-answer`). The
video sink is the bridge while a publication is up and someone watches (`updateSfuSink`); `trackMode` is on then.
No binary frame goes to a v2 portal, and a local guest on this Mac's port is refused while v2 is up (the sink is
the bridge). Control: a viewer sends `{t:"control", ask:true}`; the Share page lists viewers (`/api/state`
`viewers`, `sfu`) and the host gives control to one (`POST /api/control {g, on:true}`) or takes it back
(`{on:false}`, also "Take control back" in the menu bar); `POST /api/kick {g}` removes one viewer. Input is
accepted only from `controller`. The guest page plays the SFU's tracks in `<video id="tv">` (so `window.__pp.track`
works, with `track.audio` from the audio receiver), answers `pp.sfu.offer` once with all candidates, and has
`window.__pp.layer('f'|'h'|'q')` and `window.__pp.sfu`. A lost SFU connection reconnects the page's socket, which
makes Core admit it again.

**A link through llll.gg** (no Server of your own; ADR 0014 case 3). "Open public access" (`POST /api/tunnel`
on, or `--public`) follows `settings.publicLink`: "tunnel" is cloudflared as before; "rendezvous" posts to
`<--rendezvous>/api/portals` (default `https://llll.gg`, no account, no body), gets
`{portalId, url, guestUrl, hostLink, expiresAt}` and joins `hostLink` like a `partyportal://` link but without asking
— the host started it. The portal's page must be on the rendezvous' own host (or under it). The portal lives 12 h;
when it has stopped, "Open a new link" makes another. The Share page has the switch ("Link through llll.gg /
Through a tunnel"); unset, `Settings.defaultPublicLink` decides.

**Direct connection.** The guest gets `hello` with ICE servers and sends an offer over the WebSocket; Core relays
it to the bridge page, which answers. The offer carries three data channels — `ctl` (guest input, pings), `audio`
(unreliable) and `video` — and a transceiver that offers to receive a video track. When the channels are open the
bridge says `open` (with `track: true|false`) and Core switches the sink to the bridge. Anything fails → back to
the WebSocket. `hello` waits for `TurnRelay.servers` (a moment; four seconds at worst), so a guest's first seconds
are always on the WebSocket.

**Video as a media track** (the normal case: wherever WebKit has `VideoTrackGenerator`; checked on macOS 26 only). The bridge posts every frame from Core to a worker,
which decodes it (WebCodecs) and writes it to a `VideoTrackGenerator`; that track sits in the guest's
transceiver and WebRTC encodes it again with its own congestion control, retransmissions and jitter buffer.
So there are two encoders: ours feeds the bridge next door at `Core.localKbps` (well above the target, and never
squeezed while `trackMode` is on), WebRTC's sends to the guest under `settings.video.kbps` as a ceiling
(`capBitrate`) with a start bitrate munged into the offer. The guest plays the track in `<video id="tv">` laid
over the canvas; the canvas keeps taking the input. Masks are painted before our encoder, so the bridge never
holds an unmasked frame.

**Video in a data channel** (the fallback: an older WebKit, or `#track=0`). Frames are split into 60 KB pieces, first
byte 1 marks the last piece; the codec config travels on the same channel as text, so it arrives before its
keyframe. The bridge drops frames when the channel's buffer fills and asks Core to `squeeze`.

**Relay.** `Turn.swift` reads a Cloudflare TURN key from `turn.json` beside the config (or the environment) and
mints a credential that expires; both peers get it in their ICE servers. No key → STUN only. The relay is one more
ICE candidate, not a mode: a direct path wins when there is one.

**What the guest reports.** Once a second the page sends `stat` (frames shown, lateness or frozen milliseconds,
frames skipped). On the WebSocket and in a data channel Core lowers the bitrate on it — behind the tunnel our
socket never backs up, so this is the only signal. The page also judges its own UDP path over six seconds and
goes back to the WebSocket for the rest of the visit (`rtc-off`, `why: slow`) when the picture keeps standing still.

**The host's app.** `HostWindow` is a web view on the panel's own address; `Core.showPanel` opens it (the bare
binary falls back to the browser). Closing the window switches the app to `.accessory`: it stays as `StatusIcon`,
which reads `Core.stateJSON()` once a second and picks a `PortalMood`. A second launch finds the ports taken,
posts `/api/show` to the running copy and exits.

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
- The panel is one page at a time behind a sidebar (Share, Masks, Control, Quality, Journal; `#name` in the
  address). Share is the main screen — a window and a link — and nothing else goes on it; a new setting belongs
  on the page it is about, or on a new one.
- The menu bar mark cannot be screenshotted from a script: `partyportal --mark-preview out.png` draws every
  state on a light and a dark strip. The window's page is web/host.html — look at it in a browser at the panel's
  address. Both pages share one palette (Discord-like) and one rule: controls in a row have one height
  (48 px in the guest's tray, 32 px in the panel, 24 px for the small ones).
- Portal mode without L4: `node tools/portal-relay.mjs --host-key hk --guest-key gk` (port 8787, id `test`;
  `POST /portal/test/end` ends it with 4404), then `partyportal --fake --no-open --portal
  http://127.0.0.1:8787/portal/test --portal-key hk --token gk` (plain http only for 127.0.0.1) and
  `node tools/smoke.mjs http://127.0.0.1:8787/portal/test gk`. A guest refused by the portal sees 4401; smoke
  prints the `ice` the guest's `hello` carried. The stand-in also takes `--ice servers.json` (sent in `pp.ready`),
  `--limit-bytes N` (4429 like llll.gg), `--version 2` (4426), and answers `POST /api/portals` like llll.gg, with
  portals at `/p/<id>`: `partyportal --fake --rendezvous http://127.0.0.1:8787`, pick "Link through 127.0.0.1" on
  the Share page (or `POST /api/settings {"share":{"via":"rendezvous"}}`) and open public access.
- Several viewers without an L4 Server: `node tools/portal-relay.mjs --host-key hk --guest-key gk --v2` fakes the
  SFU. Its `pp.ready` carries `"p2p":true`, so the bridge publishes once per admitted viewer (`g` in `pp.sfu.publish`
  and `pp.sfu.answer`) and the stand-in passes each offer and answer between the bridge and that guest page: a real
  WebRTC path per viewer, but no simulcast layers (`pp.sfu.layer` is refused) and none of the SFU's own calls —
  those are tested only in L4 (`tests/unit/portal.test.ts`). `node tools/smoke.mjs http://127.0.0.1:8787/portal/test
  gk 2` checks two viewers at once (each gets hello with `sfu`, its state and an SFU offer with a video section).
  Then open the guest link in two tabs: one asks, the host gives it control, the other's input never reaches the
  input log. `bridgeDiag.simulcastProbe` in `/api/state` says whether this WebKit puts `a=simulcast:send f;h;q`
  in an offer.
- Testing must be silent when someone may be asleep nearby: `--fake` plays a tone. Give the test copy a scratch
  `--config` with `video.audio` false and mute every guest tab (`__pp.mute(true)`).
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

- **Nothing slow on the video queue.** The panel's preview was once rendered there with Core Image; one render
  deadlocked and every frame after it waited behind it — the guest saw a frozen picture while the journal looked
  fine. The preview has its own queue now, one request at a time.
- **Do not restart the app while `/api/state` shows a guest.** People test live without saying so. Rebuilding
  the bundle under a running copy is harmless (pages are read from disk per request; ⌘R reloads the panel).
- **A copy killed while stuck can keep its ports** until its process finally exits (seen once, for an hour).
  `--admin-port` and `--guest-port` start another one beside it.
- **A guest's `host` candidate is not "the same network"**: with IPv6 it is their public address anywhere.
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
- **A second copy must not half-start.** If the ports are taken, it asks the running copy to show its window (or
  hands it the portal) and exits. That is also why a `--portal` connects only half a second after start: a copy
  that dialled the portal first would push the running one out of it with a final 4409.
- **A v2 subscription waits for the Mac.** The Server subscribes a viewer to the picture only after `pp.admit`, so
  a guest the Mac refuses never receives a frame; keep it that way when changing who is admitted.
- **The SFU wants one offer and one answer.** The bridge and the guest page wait for ICE gathering to finish and
  send the whole SDP; there is no trickling of candidates through a v2 portal.
- **A link must not move the host to someone else's portal unasked.** `partyportal://portal?…` always asks the
  host first (a sheet with the portal's address); only a local process or the panel may switch without asking.

## Do not

- Do not load code into, hook or patch the shared app. Input from outside and system-level arrangements only.
- Do not add a dependency to the host without a very good reason.
- Do not weaken a rule to make a test pass: a guest-facing check that cannot decide must refuse.
- Do not put secrets, tokens or personal names in the repository, logs or examples.
  The TURN key lives in `turn.json` outside the repository and never appears in `/api/state` or the panel.
- Do not use servers of other projects for PartyPortal. A managed Cloudflare service, or ask first.
