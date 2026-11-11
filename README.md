# PartyPortal

**A link to one window.**

Pick a window on your Mac, get a link, send it. Whoever opens it in a browser sees that one window and nothing
else, and can use it within the rules you set. Nothing to install on their side.

- **One window only.** The rest of your screen is never captured, so it cannot leak.
- **Masks.** Draw a rectangle over anything private. It is painted over on your Mac before the video is encoded;
  those pixels never leave the machine.
- **Rules for input.** The guest cannot close, minimise, resize or move the window, cannot leave it
  (⌘Tab, Spotlight, Mission Control), and cannot click areas or press shortcuts you block.
  The rules run on your Mac, so a guest who rewrites the page still hits them.
- **In the background.** The guest works in the window while you keep using your Mac: your pointer and the app
  you are in stay yours.
- **Direct and free.** Video, the app's sound and input go peer-to-peer over UDP (WebRTC) when the networks allow.
- **Made for agents too.** One command shares a window and prints the link, so a coding agent can hand you
  its simulator or app window to poke from your phone.

Website: <https://partyportal.inchi.dev>

> **Status: early prototype.** It works on the author's machine and the pieces below are tested, but expect rough
> edges. See [What is tested](#what-is-tested) and [Known gaps](#known-gaps) before relying on it.

## Quick start

Requires macOS 14 or later on Apple Silicon.

```bash
curl -fsSL https://partyportal.inchi.dev/install.sh | bash
```

That downloads the app from the latest release, checks it against the checksum published beside it, puts it in
`~/Applications` and opens it; it also fetches `cloudflared` for the public link. Run it again to update. The app is not signed with an Apple Developer ID yet, so
it comes through Terminal and macOS asks for the permissions again after each update.

PartyPortal opens its window and puts its mark in the menu bar. Close the window and it keeps running there;
the mark's colour says what is going on: plain — nothing shared, blue — a window is shared and nobody has come
yet, yellow — a guest is watching, green — a guest is in control, red — something needs you (a missing
permission, a paused guest). Its menu opens the window, copies the guest's link, disconnects the guest, stops
sharing and quits. The same panel is also at `http://127.0.0.1:7373` for a browser tab or a script.

1. **Permissions.** Grant *Screen Recording* (to show the window) and *Accessibility* (so the guest can move the
   mouse and press keys). macOS asks to relaunch after the first one.
2. **Pick a window.** There is also a built-in test window with a "secret", a dangerous button and a sound button.
3. **Draw masks** on the preview. Each mask can hide its area, block clicks in it, or both.
4. **Open the public link** and send it. Chrome works best: its full-screen mode also captures system keys.

The app is installed to `~/Applications` on purpose. Launched from `~/Documents`, `~/Desktop` or `~/Downloads`,
macOS asks for access to that folder the first time the video encoder starts and the picture freezes until you answer.

The public link uses a [Cloudflare quick tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)
It carries the page and the connection handshake; the media goes direct. The installer downloads
`cloudflared` from Cloudflare's own releases, built for your Mac, into `~/Library/Application Support/PartyPortal`.

## Build from source

Needs Xcode (or the Swift toolchain) and, for the public link, `brew install cloudflared`.

```bash
git clone https://github.com/inchidev/partyportal
cd partyportal
./scripts/build-app.sh
open ~/Applications/PartyPortal.app
```

`scripts/package.sh` makes the archive the installer downloads (`dist/PartyPortal-<arch>.zip` and its checksum);
both files go into a GitHub release.

## For agents and scripts

```bash
~/Applications/PartyPortal.app/Contents/MacOS/partyportal --window "Simulator" --public --print-link --no-open
```

prints one JSON line on stdout once the link is ready and keeps running until you stop it:

```json
{"local":"http://127.0.0.1:7374/#t=…","type":"link","url":"https://….trycloudflare.com/#t=…","window":"iPhone 17"}
```

| Flag | Meaning |
|---|---|
| `--window NAME` | share the first window whose title or app name contains NAME |
| `--public` | open the public link right away |
| `--print-link` | print the link as one JSON line on stdout (the journal goes to stderr) |
| `--view-only` | the guest can watch but not touch |
| `--takeover` | the guest uses your pointer instead of working in the background (works in every app) |
| `--no-open` | do not open the window at start (it stays in the menu bar) |
| `--fake` | synthetic picture and logged input: needs no permissions, good for trying things out and for CI |
| `--dry-input` | real window, but the guest's input is only written to a log |
| `--check NAME` | diagnostics: permissions, and whether clicks can reach that window right now |
| `--rendezvous ORIGIN` | where "Link through llll.gg" opens its portal (default `https://llll.gg`) |
| `--portal URL --portal-key KEY --token T` | no tunnel: the guest's page lives on a portal (`https://…/portal/<id>`), this Mac dials out to it with KEY, and the guest's link is `URL#t=T` |

A portal can also be opened from a link, `partyportal://portal?url=<portal page>&key=<this Mac's key>&t=<guest's key>`;
the app asks before it connects. `node tools/portal-relay.mjs --host-key K --guest-key T` is a local stand-in for one.

Without a Server of your own, the Share page can make the link **through llll.gg** instead of a tunnel: llll.gg
opens a portal for 12 hours (no account), serves the guest page and passes the connection on; the picture goes
straight to the guest when their network allows. `--public` follows the same choice.

The guest page handles touch: one finger is the mouse, two fingers scroll.

A skill for Claude Code lives in [`integrations/claude-code`](integrations/claude-code).

## In the background, or with your pointer

There are two ways for the guest's input to reach the window, and a choice between them in the host panel.

**In the background** is the default. You pick a window, send the link, and carry on with your own work:

- **Input is addressed to the app that owns the window**, not sent through the system pointer. Your pointer does
  not move and the app you are working in stays in front. Clicks, drags, wheel scrolling and keys all go this way.
- **The window moves to a virtual display** while it is shared, because some apps stop drawing when they are
  fully covered. The display touches your screen only at a corner, so your pointer does not wander onto it. Stop
  sharing and the window comes back. A window in full screen stays on its own Space instead.

Nothing is loaded into the shared app, and nothing in it is patched or hooked: it only receives input events,
the same kind it gets from a real mouse and keyboard.

One kind of app does not fit: an app that asks the system where the pointer is, instead of taking the pointer
from the events it receives. There is one pointer per login session and it is yours, so such an app gets the
guest's keyboard but not the guest's mouse. PartyPortal recognises the engines known to behave this way (Unity,
so far), says so in the panel and tells the guest "keyboard only in this app".

**With my pointer** is for those apps, and for a macOS on which the background route is not available: the guest
drives your pointer. It works in every app, but the shared window has to stay in front and you cannot use the Mac
meanwhile.

The background route relies on private macOS interfaces and may break with a system update. The technique is
credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## How it works

```
 your Mac                                                      guest's browser
┌──────────────────────────────────────────────┐              ┌──────────────────────┐
│ ScreenCaptureKit (one window) → masks        │   WebRTC     │ <video> (media track)│
│   → VideoToolbox H.264 ─┐                    │   UDP, P2P   │ Opus → Web Audio     │
│ app audio → Opus ───────┼→ bridge (WebKit) ══╪══════════════╪→ mouse, keys, touch  │
│ CGEvent ← input rules ←─┘                    │              │                      │
└──────────────────────────────────────────────┘              └──────────────────────┘
        └── WebSocket through the tunnel: the page, the handshake, and the fallback path ──┘
```

- **Capture** uses a single-window ScreenCaptureKit filter. Nothing above, below or beside the window reaches the encoder.
- **Masks** are applied to a copy of each frame. If the copy cannot be made, the frame is dropped — an unmasked
  frame is never sent.
- **Input** arrives as small JSON messages and passes `InputPolicy` (shortcuts, zones) and a hit-test that makes
  sure the shared window is the topmost thing under the pointer. Input only flows while that window is in front.
- **Transport.** There is no bundled WebRTC library: the host side uses the one inside WebKit, in a 2×2 pixel
  window in a corner of the screen (it has to count as visible, or macOS pauses it and frames arrive in clumps).
  If a direct connection cannot be made, everything falls back to the WebSocket.
- **Video is a real media track.** The web view decodes the host's H.264 in a worker and hands the frames to
  WebRTC (`VideoTrackGenerator`), which encodes them again with its own congestion control, retransmissions and
  jitter buffer — so packet loss costs sharpness for a moment instead of seconds of delay. The host's own encoder
  then only feeds the web view next door, at a generous bitrate. Masks are painted before that first encoder,
  so the web view never holds an unmasked frame. Where WebKit cannot make a track (older macOS; checked on macOS 26 only) the picture
  travels in a data channel as before; `#track=0` in a guest link forces that, for comparison. Sound and input
  stay in data channels.
- **Relay (optional).** Behind a symmetric NAT — phone hotspots, many mobile carriers — no direct path exists.
  With a [Cloudflare Realtime TURN](https://developers.cloudflare.com/realtime/turn/) key of your own, media goes
  host → relay → guest over UDP instead. Create a TURN Server app in the dashboard and put its two values in
  `~/Library/Application Support/PartyPortal/turn.json` as `{"keyId": "…", "apiToken": "…"}` (or in
  `PP_TURN_KEY_ID` / `PP_TURN_API_TOKEN`). The key stays on your Mac; each guest gets a credential that expires.
- **The guest reports back.** Once a second the page says how many frames it really showed and how late they
  were. On the tunnel and in a data channel the host lowers the bitrate on that; a guest whose picture keeps
  standing still on the UDP path goes back to the tunnel by itself.
- **Two local ports**, both bound to `127.0.0.1`: `7373` for the host panel (checks `Host` and `Origin`, never
  tunnelled) and `7374` for the guest. The guest's key lives in the URL fragment, so the tunnel never sees it.

More detail for people (and agents) working on the code: [AGENTS.md](AGENTS.md).

## What is tested

- Unit tests for the input rules and settings (`swift test`).
- A protocol smoke test without a browser (`node tools/smoke.mjs`): a wrong key gets no video, the right one gets
  a codec config and a keyframe. CI runs both on every push.
- By hand, with pixel checks on the guest's canvas: capture of a real window, masks, blocked clicks and shortcuts,
  resize, full screen and back, closing the window, view-only, kicking the guest, the public link.
- Real input on the test window: clicks land where they were aimed, double and right clicks, keys with modifiers,
  scrolling, a real button press. A click on a window that is behind others brings it forward and still counts.
  Dragging the title bar moves the window and it is put back; the close button and ⌘W do nothing.
- Sound: a 440 Hz tone from the test window arrives with the same frequency and level.
- In the background, with the host's own app in front and the host's pointer untouched throughout: clicks and
  keys in Calculator (7×8 and 99+1); clicks, drags, keys and wheel scrolling (a nested scroller too) on a page in
  Safari, 60 fps once parked and 0 fps while covered; a piece moved by dragging in Chess; a Unity game played by
  keyboard from a full-screen Space; a native MMO client driven by mouse, wheel and keyboard (interface clicks,
  camera rotation and zoom, turning, movement).
- Direct connection on one Mac through the router: 8 Mbps, no frames lost, frames 13 ms late on average.
- Media track on one Mac: same colours as the data-channel path (pixel check), clicks and keys land where aimed
  with the `<video>` on top, 60 fps in → 50–60 fps shown, about 10 ms of buffering; a track that never starts
  sends the guest back to the tunnel within a few seconds.

## Known gaps

- The media track has only been measured with the synthetic test picture so far (same Mac, and through the
  TURN relay over a phone hotspot with 2–3% loss: 50–60 fps and about 0.1 s of buffering where the data channel
  gave 2–7 fps arriving seconds late — at the price of resolution, which WebRTC lowers to fit the link).
  A real window, a real game and a guest on another network are still to be measured.
- On a link that poor WebRTC is cautious: it settled near 0.5 Mbps on a path that carried 2 Mbps of plain UDP.
- Sound still travels in a data channel and is not synchronised with the track's jitter buffer.
- While the Mac's screen is locked, windows do not draw and there is nothing to capture; the web view is also
  slowed down by macOS then.
- One guest at a time. Spectators and passing control between guests are planned.
- Menus, pop-ups and dialogs of the shared app are separate macOS windows: the guest cannot see or click them.
- Sound is the whole app's, not the single window's: share a browser window and the guest hears every tab.
- Masks are stored as fractions of the window. If you resize it, check they still cover what they should.
- In the background there is no guest mouse in apps that read the pointer position from the system instead of
  from events; only Unity is recognised so far, other engines of that kind will simply ignore the guest's mouse.
- With your pointer, the mouse and the focus are shared: you cannot use that Mac for something else, and anything
  that takes the focus away pauses the guest until their next click.
- With strict NAT and no TURN key of your own there is no direct path and the fallback is slower.
- Without a media track (an older macOS), the data channel stalls on packet loss.
- macOS host only. A Windows host is planned.

## Roadmap

1. Agents and developers: phone-friendly guest page, an MCP server, a Homebrew formula, notarised builds.
2. Friends: several viewers, taking turns.
3. Media tracks instead of data channels, a relay for strict networks, a Windows host.

## Security

PartyPortal captures your screen and injects input, so read [SECURITY.md](SECURITY.md) for what it protects
against and what it does not. Please report vulnerabilities privately as described there.

## License

[MIT](LICENSE)
