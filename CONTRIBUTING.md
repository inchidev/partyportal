# Contributing

Thanks for looking. The project is young, so the most useful things right now are bug reports with exact steps,
and small focused pull requests.

## Build and test

```bash
swift build                      # debug build
swift test                       # unit tests for the input rules and settings
.build/debug/partyportal --fake  # synthetic picture, logged input: needs no permissions
node tools/smoke.mjs 7374 <token from the link>
./scripts/build-app.sh           # signed PartyPortal.app in ~/Applications
```

`--fake` is the fastest loop: it serves a known picture (four coloured quadrants and a white "secret" box) and a
440 Hz tone, and writes what the guest's input would have done to a log. Check video by reading pixels from the
guest's canvas, not by eye: a black frame and no frame look the same.

[AGENTS.md](AGENTS.md) has the map of the code and the traps already stepped on.

## Ground rules

- Comments say why, not what. No dependencies unless there is no other way: the host has none today.
- Anything that decides what a guest may see or do needs a test, and must fail closed.
- User-visible text is short and plain.
- By contributing you agree that your work is released under the MIT license.
