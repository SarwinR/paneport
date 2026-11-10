# Contributing

Thanks for helping! Bug reports, measurements from different setups and pull requests are
all welcome.

## Reporting a problem

Please include:

- Mac model, chip and macOS version
- On the PC: Windows version, the browser and its version (or the Windows app's version),
  the graphics card(s), and which card each monitor is plugged into
- Wired or Wi-Fi
- The delay figures: press **S** on a streamed screen, or copy them from the Mac app
- Logs, if relevant: in Console.app, filter on the subsystem `local.paneport`

## Building and testing

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first for how the parts fit together.

### Mac app

Needs macOS 13+ and Swift 5.9+ (the Xcode Command Line Tools are enough to build).

```sh
swift build          # debug build
./make-app.sh        # standalone app in build/, signed with a local identity
swift test           # unit tests; needs the full Xcode app, which includes XCTest
```

Running from Xcode or Terminal gives the Screen Recording permission to Xcode or Terminal
rather than to Paneport; `./make-app.sh` builds a standalone app instead.

### Browser page

Needs Node 18+ for the tests.

```sh
node --test Tests/receiver/*.test.js
PANEPORT_RECEIVER_DIR=Sources/Paneport/Resources/receiver swift run
```

With `PANEPORT_RECEIVER_DIR` set, the Mac app serves the page from that folder, so edits show
up on the next page load without rebuilding.

### Windows app

Needs Windows 10 or 11 and Rust (<https://rustup.rs>).

```sh
cd windows
cargo build --release
cargo test
cargo fmt
```

The protocol tests also run on macOS and Linux:
`rustc --edition 2021 --test windows/src/protocol.rs && ./protocol`.

To include your build in the Mac app, copy `PaneportReceiver.exe` to `windows/dist/` before
running `./make-app.sh`.

### Continuous integration

Every push and pull request builds and tests all three parts on GitHub Actions
(`.github/workflows/ci.yml`), so you can rely on CI for the parts you can't build locally.

## Releasing

Push a tag such as `v0.4.0`. The release workflow builds the Windows app, builds the Mac app
with the Windows app inside it, and publishes both on a GitHub release.

## Guidelines

- **Style:** follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
  and `cargo fmt`. Indentation is set in `.editorconfig`: four spaces in Swift and Rust, two
  in JavaScript and HTML.
- **Keep logic testable:** put calculations and parsing in plain functions or types (like
  `DisplayLayout`, `WireProtocol`, `PointerMath`, `protocol.rs`) with tests, and keep system
  APIs at the edges.
- **Threading:** state in a type's doc comment which queue, actor or thread it runs on, and
  keep its mutable state there.
- **Settings:** new fields need defaults and `decodeIfPresent`, so existing settings still load.
- **Protocol changes:** update [docs/PROTOCOL.md](docs/PROTOCOL.md) and all three
  implementations with tests in the same pull request, and raise the protocol version if
  older viewers would break.
- **User-facing text:** plain, specific language. Errors say what happened and what to do.
- **Pull requests:** one change per pull request, with a short description of what and why,
  and before-and-after delay figures for performance changes. CI must pass.

By contributing, you agree that your contributions are licensed under the project's
[GPL-3.0 license](LICENSE).
