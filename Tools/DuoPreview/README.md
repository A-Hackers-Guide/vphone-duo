# Duo Preview

The iPhone Duo's 3D window without the VM engine around it: the same
`UI/UserInterface/Duo` sources, built with stand-ins for the VM view. It
needs no administrator approval, so it is the quick way to check the model,
the fold, hit-testing and the buttons after a change.

```sh
D=VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/Duo
swiftc -O -swift-version 6 -o /tmp/duo-preview Tools/DuoPreview/*.swift \
  $D/VPhoneDuoView.swift $D/VPhoneDuoModel.swift $D/VPhoneDuoPanelStream.swift \
  $D/VPhoneDuoControlsView.swift $D/VPhoneDuoFeedback.swift
/tmp/duo-preview VPhoneExecutable/VPhoneVirtualization/Resources/DuoModel \
  <a-screenshot.png> <out-dir> <script>
```

Scripts:

| Script | What it does |
| --- | --- |
| `poses` | Renders open, laptop, tent and closed, in both finishes. |
| `look` | The back and edges, both finishes. |
| `clicks` | Clicks a grid over the open phone and prints each touch. |
| `clicks-closed` | The same over the closed phone's outer screen. |
| `buttons` | Clicks every key where it is drawn, from four folds and angles, and prints which key each click pressed. |
| `selftest` | Puts a grid of guest-screen points on the model at five folds and angles, clicks each through the real hit-testing, and checks it comes back as itself (within 0.01). Prints `SELFTEST PASSED` or `FAILED`. |
| `touchdot`, `crease`, `scroll`, `readback` | Checks for the extras and the scroll and readback paths; `scroll` and `readback` need a running Duo. |
| `live` | Drives a running Duo VM through `~/.vphone/machines/duo/vphone.sock`: its live screen on the panels, clicks become touches, keys become HID presses, and the fold goes to the hinge sensor. It taps Settings on the 3D model and checks that iOS opened it. |

Set `DUO_QUIET=1` to leave out the per-touch lines.

`FrameUploadBenchmark.swift.txt` times two ways of putting a frame on the
GPU; rename it to `.swift` and pass it a screenshot to run it.
