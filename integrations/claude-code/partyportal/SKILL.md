---
name: partyportal
description: Share one window of this Mac as a link the user can open on their phone or another computer, to look at it or tap around in it. Use when the user asks to see, check or try a running app, simulator or browser window remotely, or says "send me a link to that window".
---

# Share a window with PartyPortal

PartyPortal turns one window of this Mac into a link. The person who opens it sees only that window and can
click, type and tap in it. Use it to let the user look at something you built without being at the desk.

## Share

Run this in the background and read the first line of stdout:

```bash
~/Applications/PartyPortal.app/Contents/MacOS/partyportal --window "<part of the window title or app name>" --public --print-link --no-open
```

It prints one JSON line when the link is ready (this can take about ten seconds) and then keeps running:

```json
{"type":"link","url":"https://….trycloudflare.com/#t=…","local":"http://127.0.0.1:7374/#t=…","window":"…"}
```

Give the user the `url`. If there is no `url`, the public tunnel is unavailable: say so and offer `local`,
which only works on this Mac.

- Add `--view-only` if the user should watch but not touch.
- The process must stay alive for the link to work. Stop it (SIGTERM) when the user is done.
- Only one copy can run. If it exits at once with "port … is taken", PartyPortal is already running: use its
  panel at http://127.0.0.1:7373 or ask the user to quit it.

## Before you share

- The app needs the Screen Recording and Accessibility permissions. Check with
  `partyportal --check "<window>"`; if one is missing, ask the user to open PartyPortal once and grant it.
- Anyone with the link can see and use that window. Tell the user what you are sharing, and never share a window
  that shows secrets unless they asked for exactly that.
- Menus and dialogs of the shared app are separate windows and will not be visible through the link.
