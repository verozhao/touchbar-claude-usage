# Claude Touch Bar

A MacBook Pro Touch Bar companion for [Claude Code](https://code.claude.com). It shows, at a glance:

- **5h**: current 5-hour session usage and time until it resets
- **Week**: weekly limit across all models
- **Fable** (or whichever model has a scoped weekly limit): weekly per-model usage
- **Context**: how much of the active session's context window is used, plus its size
- **Approve / Deny / Terminal** buttons whenever Claude Code asks for tool permission

Everything lives in a "system modal" Touch Bar (the same private API Pock and MTMR use). The macOS Control Strip (brightness, volume, mute, Siri) stays on the right; turn off "Keep Control Strip Visible" in the menu to take the whole bar. A small `C 25%` button is added to the Control Strip to toggle the bar, and a menu-bar item mirrors the numbers and offers the same Approve / Deny actions.

Idle, next to the Control Strip:

![idle](docs/idle.png)

A permission prompt (gauges yield to the buttons when space is tight; at full width the 5h and Context gauges stay):

![prompt](docs/prompt.png)
![prompt, full width](docs/prompt-full.png)

## How it works

```
claude.ai usage API ──(OAuth token from Keychain)──▶ ClaudeTouchBar.app ◀── ~/.claude/touchbar/status/*.json
                                                        │      ▲                       (statusLine wrapper: context %, model, cost)
                                                        ▼      │
                                      ~/.claude/touchbar/responses/  requests/
                                                        ▲      │
                                                        └──────┘
                          scripts/claude-touchbar-permission-hook.sh  (Claude Code PermissionRequest hook)
```

- **Usage limits** come from the same endpoint the `/usage` screen uses, authenticated with the OAuth token Claude Code keeps in the login keychain (`Claude Code-credentials`). The app reads it via `/usr/bin/security`; macOS asks once, click **Always Allow**. Polled every 3 min with a Claude Code User-Agent (the endpoint throttles other clients).
- **Context** comes from Claude Code's `statusLine` JSON. `install.sh` swaps in a wrapper that saves each payload to `~/.claude/touchbar/status/<session>.json` and then runs your original status line command unchanged. The most recently updated session is shown; the menu lists all of them.
- **Permission prompts** use a `PermissionRequest` hook. The hook writes a request file, the Touch Bar shows the tool and command, and your tap writes the answer back. The hook then returns `allow` or `deny` to Claude Code; **Deny** also interrupts the turn, like answering "No" in the terminal. Tap **Terminal** (or wait 60 s) and the hook steps aside so the normal terminal prompt appears. The hook stays out of the way when the app is not running, when its heartbeat is stale (lid closed, display asleep), over SSH, and for dialog tools such as `AskUserQuestion` or `ExitPlanMode` (add more via `passthrough_tools` in the config).
- **Touch Bar mode.** A modal bar and the system Control Strip can only share the panel in the "App Controls with Control Strip" mode, so `install.sh` switches *System Settings → Keyboard → Touch Bar shows* to that (your previous choice is remembered and restored by `uninstall.sh`).

## Install

Requirements: macOS 12+, a Mac with a Touch Bar, Xcode Command Line Tools (`xcode-select --install`), Claude Code logged in with a claude.ai subscription.

```bash
git clone https://github.com/verozhao/touchbar-claude-usage.git
cd touchbar-claude-usage
./install.sh
```

`install.sh` builds the app with `swiftc` (no Xcode project), copies it to `~/Applications`, installs the hook scripts to `~/.claude/touchbar/bin`, adds the `PermissionRequest` and `SessionEnd` hooks and the status line wrapper to `~/.claude/settings.json` (a timestamped backup is written next to it), switches the Touch Bar mode, and registers a LaunchAgent so it starts at login. Restart any running Claude Code sessions so they pick up the hook.

Remove everything with `./uninstall.sh` (add `--purge` to delete `~/.claude/touchbar` too).

## Configure

`~/.claude/touchbar/config.json` (also editable from the menu bar item):

| key | default | meaning |
|-----|---------|---------|
| `wait_seconds` | 60 | how long the hook waits for a tap before handing back to the terminal |
| `refresh_seconds` | 180 | usage API poll interval (the endpoint rate-limits below about 180 s; minimum 120) |
| `keep_control_strip` | true | keep brightness/volume/Siri visible on the right |
| `auto_present` | true | bring the bar back when you switch apps (unless you closed it) |
| `sound` | false | play a sound when a permission prompt arrives |
| `show_tray` | true | the `C 25%` button in the Control Strip |
| `passthrough_tools` | `[]` | extra tool names the hook should leave to the terminal |

## Development

```bash
./build.sh                                   # → build/ClaudeTouchBar.app
CLAUDE_TOUCHBAR_DIR=/tmp/tb build/ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar   # run against a scratch data dir
CLAUDE_TOUCHBAR_SNAPSHOT=/tmp/bar.png CLAUDE_TOUCHBAR_SNAPSHOT_STATE=prompt \
  build/ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar                              # render the layout to a PNG, no Touch Bar needed
```

Simulate a prompt without Claude Code (with the app running):

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git push"},"tool_use_id":"t1"}' | bash scripts/claude-touchbar-permission-hook.sh
```

Logs: `~/.claude/touchbar/app.log`.

## Caveats

- The system-modal Touch Bar and Control Strip tray item use private AppKit/DFRFoundation API. It works on macOS 12 to 13 (tested on 13.5). Apple could break it in a future release.
- While the hook is waiting, Claude Code shows "Approve or deny on the Touch Bar…" instead of the prompt. Tap **Terminal** to answer there instead. Pressing Esc in the terminal during the wait cancels the whole turn.
- The keychain read goes through `/usr/bin/security`. If macOS asks and you click Always Allow, that grant applies to any process using the `security` tool, not only this app.
- 2016 to 2019 MacBook Pros have no physical Esc key. this bar does not add one (this was built on a 2020 model). Hide the bar with the `C` button when you need the virtual Esc.
- Usage numbers depend on the OAuth token Claude Code refreshes. If Claude Code has not run for a long time the token expires and the bar shows "token expired" until you run `claude` again.
