# mac-tally-lamp

Read `README.md` first for what the app is, then `planning/decided.md` for what is settled and why, and `planning/planned.md` for what is open. This app follows the Mac app recipes in `~/dev/@home/mac-app-recipes.md` unless this file says otherwise.

## Product rules

- The person at the Mac always wins. Their claim never lapses, and taking the screen from an agent works at once.
- Nothing the app shows on its own may take focus. The lamp is a panel that never becomes key or main. Only Settings and Sparkle's windows, which the person opens, may come forward.
- It is cooperative. It never blocks, delays, or kills an agent's input. Enforcement, if it comes, belongs in the agents' own hooks (see `planning/planned.md`).
- The tool answers are read by agents. Each says who has the screen and what the agent should do next. Keep them in `Sources/MacTallyLampMCP/ScreenWords.swift`, with tests.
- Who has the screen lives in memory only. A restart clears it, and the MCP servers connect again at their next call.
- Target the current macOS only. Use the newest APIs and Liquid Glass. Do not add fallbacks for older versions.
- Name things in full. The repo, bundle, executable, and data folder are `mac-tally-lamp`. People see "Tally Lamp".

## How it fits together

- `MacTallyLampCore`: `ScreenClaims` holds the rules for who has the screen and who waits. `LampService` runs them on the main actor and serves them on a Unix socket in the data folder (`LineSocket.swift`). `LampWire.swift` is the message format.
- `MacTallyLampMCP` and the `mac-tally-lamp-mcp` executable: the MCP server an agent starts, over stdio. One copy per agent session, with one socket connection for its life, so the app knows the session has ended when the connection closes.
- `mac-tally-lamp`: the menu bar item, the lamp panel, and Settings.
- The helper from one build may talk to the app from a newer one, since agent sessions outlive app updates. Change the message format only by adding optional fields.

## Working here

- Work in a numbered worktree under `.wt/` (for example `.wt/wt-02`), on a branch. Keep the primary checkout on `main`. `wt switch --create` makes a sibling folder here, so use `git worktree add .wt/wt-02 -b <branch>`.
- Commit and push as you work, and open a pull request early. Never push to `main` directly. Once the repo is in the release poller, a push to `main` ships.
- Merge your own pull requests, squashed, when checks pass and nothing waits on the owner. Hold one for the owner when it needs a product decision that is not in `planning/decided.md`, or something you could not verify that the owner has to try.
- A pull request that changes anything visible includes renders from `scripts/render-previews.sh`, attached with `gh`'s `--attach` flag. For a change to something that exists, show before and after.
- Fixtures, samples, tests, and renders use stand-in people, folders, and projects (`rchen`, `acme-web`, `docs-site`), never real ones.
- A new feature the owner has not settled goes behind a switch in Settings, Experiments, off by default, with its four lines in `planning/decided.md` under Experiments: question, wins when, decide by, and afterward.
- When a decision changes, move it between `planning/decided.md` and `planning/planned.md` in the same pull request. Keep `README.md` short.

## Previews and checks

- `swift build` and `swift test`. The socket tests listen on a socket in the temporary folder, never the real one.
- `scripts/render-previews.sh` draws the lamp and every Settings section, light and dark, to `build/previews`. It shows no window. Glass does not draw offscreen, so the lamp's renders show a plain card in its place.
- The menu bar menu is a real menu and cannot be drawn offscreen. It has no render yet.
- `scripts/render-icon.sh` redraws `Resources/AppIcon.icon` and `docs/icon.png`. Commit what it writes. `--previews <folder>` draws both designs and a contact sheet.
- `scripts/bundle.sh` builds `build/mac-tally-lamp.app` and launches nothing. `--install` moves it to `~/Applications` and launches it, which puts an item in the menu bar: ask the owner first.
- `--data-folder <path>` points the app and the helper at another folder, so a test copy uses its own socket. Pass the same folder to both.
- Running the helper with no app answering makes it start the app around it with `open -g`. That launches the app, so do not call its tools from a bundled helper without asking.

## Signing and releases

- `scripts/bundle.sh` signs with `MAC_TALLY_LAMP_SIGNING_IDENTITY`, then a Developer ID Application certificate, then a `mac-tally-lamp development` certificate, then ad hoc. It signs the helper, then the app. The app asks for no permissions and has no entitlements file.
- `scripts/release.sh --check` changes nothing. `--dry-run` builds the zip and feed into `build/release` and publishes nothing, but signs the feed with the Sparkle key in the Keychain, which may prompt: ask first. Run it without either only when the owner asks.
