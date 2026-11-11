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
- **Background mode (experimental).** The guest works in the window while you keep using your Mac: your pointer
  and the app you are in stay yours.
- **Direct and free.** Video, the app's sound and input go peer-to-peer over UDP (WebRTC) when the networks allow.
- **Made for agents too.** One command shares a window and prints the link, so a coding agent can hand you
  its simulator or app window to poke from your phone.

Website: <https://partyportal.inchi.dev>

> **Status: early prototype.** It works on the author's machine and the pieces below are tested, but expect rough
> edges. See [What is tested](#what-is-tested) and [Known gaps](#known-gaps) before relying on it.

## Quick start

Requires macOS 14 or later and Xcode (or the Swift toolchain). Tested on Apple Silicon.

```bash
git clone https://github.com/inchidev/partyportal
cd partyportal
./scripts/build-app.sh
open ~/Applications/PartyPortal.app
```

The host panel opens at `http://127.0.0.1:7373` and a menu bar item appears.

1. **Permissions.** Grant *Screen Recording* (to show the window) and *Accessibility* (so the guest can move the
   mouse and press keys). macOS asks to relaunch after the first one.
2. **Pick a window.** There is also a built-in test window with a "secret", a dangerous button and a sound button.
3. **Draw masks** on the preview. Each mask can hide its area, block clicks in it, or both.
4. **Open the public link** and send it. Chrome works best: its full-screen mode also captures system keys.

The app is installed to `~/Applications` on purpose. Launched from `~/Documents`, `~/Desktop` or `~/Downloads`,
macOS asks for access to that folder the first time the video encoder starts and the picture freezes until you answer.

The public link uses a [Cloudflare quick tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)
(`brew install cloudflared`). It carries the page and the connection handshake; the media goes direct.

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
| `--background` | start in background mode (same as the switch in the host panel) |
| `--no-open` | do not open the host panel in a browser |
| `--fake` | synthetic picture and logged input: needs no permissions, good for trying things out and for CI |
| `--dry-input` | real window, but the guest's input is only written to a log |
| `--check NAME` | diagnostics: permissions, and whether clicks can reach that window right now |

The guest page handles touch: one finger is the mouse, two fingers scroll.

A skill for Claude Code lives in [`integrations/claude-code`](integrations/claude-code).

## Background mode

Normally the guest drives your pointer, so the shared window has to be in front and you cannot use the Mac
meanwhile. Background mode (a switch in the host panel, experimental) removes both limits:

- **Input is addressed to the app that owns the window**, not sent through the system pointer. Your pointer does
  not move and the app you are working in stays in front.
- **The window moves to a virtual display** while it is shared, because a window that is fully covered stops
  drawing. The display touches your screen only at a corner, so your pointer does not wander onto it. Stop sharing
  and the window comes back. A window that is already in full screen stays on its own Space instead.

Nothing is loaded into the shared app, and nothing in it is patched or hooked: it only receives input events,
the same kind it gets from a real mouse and keyboard.

What that means in practice:

- Apps that take the mouse from the events they receive work: ordinary apps, pages in a browser, and the games
  tried so far that are built that way.
- Apps that ask the system where the pointer is (some game engines do) get the guest's keyboard but not the
  guest's mouse: there is one pointer per login session and it is yours.
- Wheel scrolling does not arrive yet.

Background mode relies on private macOS interfaces and may break with a system update. The technique is credited
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## How it works

```
 your Mac                                                      guest's browser
┌──────────────────────────────────────────────┐              ┌──────────────────────┐
│ ScreenCaptureKit (one window) → masks        │   WebRTC     │ WebCodecs → <canvas> │
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
- Background mode, with the host's own app in front and the host's pointer untouched throughout: clicks and keys
  in Calculator (7×8 and 99+1), clicks, drags and keys on a page in Safari (60 fps once parked, 0 fps while
  covered), a piece moved by dragging in Chess, a Unity game played by keyboard from a full-screen Space, and
  a native MMO client driven by mouse and keyboard (interface clicks, camera and character turning, movement).
- Direct connection on one Mac through the router: 8 Mbps, no frames lost, frames 13 ms late on average.

## Known gaps

- A direct connection between two different networks has not been measured yet.
- One guest at a time. Spectators and passing control between guests are planned.
- Menus, pop-ups and dialogs of the shared app are separate macOS windows: the guest cannot see or click them.
- Sound is the whole app's, not the single window's: share a browser window and the guest hears every tab.
- Masks are stored as fractions of the window. If you resize it, check they still cover what they should.
- Without background mode the mouse and the focus are shared: while the guest is in control you cannot use that
  Mac for something else, and anything that takes the focus away pauses the guest until their next click.
- In background mode: no wheel scrolling yet, and no guest mouse in apps that read the pointer position from the
  system instead of from events.
- With strict NAT on both sides there is no direct path and the fallback is slower. A relay is planned.
- WebRTC data channels can stall for about 0.2 s when a packet is lost.
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
