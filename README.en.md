# CodexBar

[한국어](README.md)

CodexBar is a personal macOS menu-bar app for checking the remaining Codex quota across multiple ChatGPT accounts. It shows the primary account's remaining quota in the menu bar (for example, `C 41%`), offers a quick comparison on hover, and opens a full usage panel on click.

Finder and the Desktop use a dedicated app icon: a blue Codex symbol with bold `Codex Bar` text below it.

> Screenshot placeholder: capture the menu-bar item and popover after the first launch and add them here.

## Homebrew installation and remote updates

The release ZIP and Homebrew Cask currently support Apple Silicon Macs running macOS Sonoma (14) or later. `codexbar` is already used by another app, so this project's Cask token is `codexbar-for-mac`.

```zsh
brew tap kunzatt/codex-bar-for-mac https://github.com/kunzatt/codex-bar-for-Mac.git
brew trust --cask kunzatt/codex-bar-for-mac/codexbar-for-mac
brew install --cask codexbar-for-mac
```

After that one-time setup, use only `brew install --cask codexbar-for-mac` and `brew upgrade --cask codexbar-for-mac`.

After a new version has been published as a GitHub Release, update it remotely with:

```zsh
brew update
brew upgrade --cask codexbar-for-mac
```

To remove the app and its locally managed login profiles:

```zsh
brew uninstall --zap --cask codexbar-for-mac
```

To prepare a release, bump `CFBundleShortVersionString`, then create the GitHub Release ZIP and its SHA-256 checksum:

```zsh
./scripts/package-release.sh
```

Put the generated checksum in `Casks/codexbar-for-mac.rb`, then upload the ZIP to the `v<version>` GitHub Release with the same version.

## Requirements

- Release ZIP/Homebrew Cask: Apple Silicon Mac running macOS Sonoma (14) or later
- Building from source: Apple Silicon or Intel Mac running macOS Sonoma (14) or later, with full Xcode (recommended) or Swift 6 command-line tools
- The ChatGPT app or Codex CLI. The default discovery path is `/Applications/ChatGPT.app/Contents/Resources/codex`.
- A Codex account on a ChatGPT Pro or Pro Lite plan

CodexBar does not use OpenAI Platform API keys, web scraping, or unofficial REST endpoints. It only calls local `codex app-server --stdio` processes.

## Build and run

With Xcode installed, open [CodexBar.xcodeproj](CodexBar.xcodeproj/project.pbxproj) and run the `CodexBar` scheme. The application is configured as an `LSUIElement`, so it appears only in the menu bar and has no Dock icon.

You can also build from Terminal:

```zsh
cd CodexBar
./scripts/build.sh
```

Create an application bundle that can run without a Terminal window:

```zsh
cd CodexBar
./scripts/package-app.sh
open dist/CodexBar.app
```

Move `dist/CodexBar.app` to `/Applications` to launch it through Finder or Spotlight. Do not run the app from Terminal and Finder at the same time, or the menu-bar item will appear twice.

To replace an app installed at one location, quit it first and run:

```zsh
cd CodexBar
./scripts/install-or-update.sh "$HOME/Applications/CodexBar.app"
```

The script moves the prior bundle to Trash, so it can be recovered if necessary. To keep using a different location, pass that path instead. For example, update a Desktop install with `./scripts/install-or-update.sh "$HOME/Desktop/CodexBar.app"`.

Without full Xcode, the build script falls back to Swift Package Manager. This verifies that the source compiles; launching the menu-bar UI still requires a macOS GUI session.

## Tests

Run the framework-free unit-test runner with:

```zsh
cd CodexBar
./scripts/test.sh
```

The tests cover JSONL response and notification decoding, multiple quota buckets, primary and secondary windows, null payloads, `Int64` token totals, malformed JSONL recovery, duration formatting, backoff, metadata persistence, and log redaction. They do not read authentication files or perform an account login.

## Add the first account

1. Click `C --` in the menu bar and choose **Add account**.
2. Choose an alias and select **Start Device Code Login**.
3. In the browser, sign in to the desired ChatGPT Pro or Pro Lite account and enter the displayed device code.
4. When the login-complete notification appears, CodexBar reloads the account, plan, and quota data.

Repeat this process for each additional account. Each account has a separate `CODEX_HOME` and `codex app-server` process, so authentication never mixes between profiles.

To use the default Codex login in `~/.codex`, choose **Register default ~/.codex** in Settings. That profile is marked as external; CodexBar does not delete that directory or its authentication files.

## Primary account and refreshes

- Select an account row in the full panel, or use the star in Settings, to set the primary account.
- The menu-bar item prefers the primary account's `codex` bucket. If unavailable, it uses the first available bucket.
- Rate limits refresh every 30 seconds per account; token totals refresh every two minutes.
- When a request fails, the latest valid value remains visible and retries back off from 30 to 60, 120, and 300 seconds. All accounts refresh immediately after the Mac wakes from sleep.

## Data and security

Account metadata created by the app is stored here:

```text
~/Library/Application Support/CodexBar/
├── accounts.json
└── Accounts/<account-uuid>/codex-home/
```

The application-support directory and each account directory are kept at `0700`; metadata and generated `auth.json` are kept at `0600` where possible. `accounts.json` stores only the alias, UUID, local path, and enabled/primary-account settings.

CodexBar never reads or parses the contents of `auth.json`. It does not store tokens, cookies, API keys, prompts, or conversations. stderr is drained only to prevent a blocked process and is not persisted; visible error messages are kept generic so credentials are not exposed.

## Known limitations

- `codex app-server` is experimental in the Codex CLI. A CLI update may change response schemas, so raw JSON is isolated at the `ProtocolMapper` boundary.
- Version 1 covers ChatGPT Codex usage only. API costs, other plan-specific optimisations, automatic account switching, and automatic reset-credit spending are out of scope.
- Device-code login and menu-bar hover behavior need a GUI session and a signed-in account to test.

## Troubleshooting

**Codex executable cannot be found**

Select the `codex` executable in Settings. The ChatGPT app usually bundles it at `/Applications/ChatGPT.app/Contents/Resources/codex`.

**Login has expired**

Add the account again from the popover. For an external `~/.codex` profile, complete your normal Codex CLI login first, then refresh CodexBar.

**No usage is displayed**

Check that the Codex CLI is current and verify the executable path in Settings. An account can be registered even when plan or quota data is unavailable; in that case the app preserves `C --` and the latest generic error state.

**Removing the app and authentication files**

For an app-managed profile, choose **Log out and delete local profile** in Settings to remove only that account's UUID folder. External profiles, including `~/.codex`, are removed from the list only. Deleting the app does not remove authentication files; remove `~/Library/Application Support/CodexBar` manually only if you intentionally want to erase app-managed data.
