# Security

PartyPortal shows one of your windows to someone else and lets them send input to it. This page says what the
design protects against, what it does not, and how to report a problem.

## What it is designed to guarantee

- **Only the shared window is captured.** The capture filter is a single window, so other windows, the desktop
  and notifications are never in the frame.
- **Masked pixels never leave the Mac.** Masks are painted on the host before encoding. If a masked copy of a
  frame cannot be produced, the frame is dropped.
- **Rules are enforced on the host.** Every input message from the guest passes the same checks no matter what
  page sent it: blocked shortcuts, blocked zones, and a hit-test that the shared window is the topmost thing under
  the pointer. Input flows only while that window is in front and the screen is unlocked.
- **The host panel is local.** It listens on `127.0.0.1`, checks the `Host` and `Origin` headers, and is never
  exposed through the tunnel.
- **The link is the key.** The guest's token is 128 random bits in the URL fragment, which browsers do not send
  to servers. A connection without the right token gets no video. Kicking a guest rotates the token.

## What it does not protect against

- **Anything the shared app itself lets the guest do.** PartyPortal does not understand the app: allowed clicks
  and keys can delete a document, buy something, or open a file dialog (which the guest cannot see, but the app
  now has one). The locks are soft rules on input, not a sandbox. Share windows of apps you would hand to that person.
- **The whole app's sound.** Audio is captured per app, not per window.
- **Masks after a resize.** Masks are fractions of the window; a resized window can lay its content out differently.
- **A compromised Mac.** Any local process can talk to the host panel's port.
- **Whoever has the link.** Anyone you forward it to is the guest.

## Supported versions

Only the latest commit on `main`. This is an early prototype.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting:
<https://github.com/inchidev/partyportal/security/advisories/new>

Include what you did, what you expected and what happened, and the macOS and browser versions. You will get an
answer within a few days.
