# Third-party notices

PartyPortal has no third-party dependencies: nothing here is linked, bundled or copied wholesale.
Two techniques in background mode were learnt from other open-source projects, and credit is due.

## cua-driver

The recipe for delivering mouse events to a window that is not in front — posting through SkyLight's
`SLEventPostToPid`, stamping each event with the window it is for, leading a press with a mouse-moved event,
the window-location stamp and its macOS 27 difference — follows cua-driver's macOS input layer.
`Sources/partyportal/Input.swift` (`BackgroundInput`) is a fresh Swift implementation of that recipe.

- Project: <https://github.com/trycua/cua> (`libs/cua-driver`)
- License: MIT, Copyright (c) 2026 Cua AI, Inc.

## yabai

The 248-byte "this window is key" record sent with `SLPSPostEventRecordTo` (focus without raising) comes from
yabai, by way of cua-driver, which credits it the same way.

- Project: <https://github.com/koekeishiya/yabai>
- License: MIT, Copyright (c) 2019 Åsmund Vikane

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of
the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
