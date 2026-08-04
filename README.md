# Kero

A native terminal workspace for macOS.

![preview](https://kero.sh/kero-screenshot.png)

## Features

- Swift + libghostty by default, with an optional Alacritty backend
- Native design
- Split panes
- Git intergration
- Group by projects
- File tree
- Agent activity in the sidebar

## Agent activity in the sidebar

A project row can show what its coding agent is doing, so you can leave several
running and see which one wants you:

| Row | Meaning |
| --- | --- |
| Orange folder with a question badge | An agent is blocked — a permission prompt, or waiting for your input |
| Green filled folder | An agent finished and you have not looked at it yet |
| Cyan folder with a gear badge | An agent has been working for at least 30 seconds |

Focusing the project's tab clears the mark. A blocked agent outranks a finished
one, so a project with both reads as blocked.

### Claude Code

Kero exports `KERO_SESSION_ID` and `KERO_STATE_DIR` into every terminal it
opens, and both are inherited by anything you run there. Point Claude Code's
hooks at [`scripts/kero-claude-hook.sh`](scripts/kero-claude-hook.sh) in
`~/.claude/settings.json`, using the absolute path to your checkout:

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh PermissionRequest" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh Notification" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh UserPromptSubmit" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh PreToolUse" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh Stop" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "/path/to/kero/scripts/kero-claude-hook.sh SessionEnd" }] }
    ]
  }
}
```

The script does nothing outside a Kero terminal, so the same settings file is
safe to keep when you run Claude Code elsewhere.

### Other tools

Any script can mark its project from inside a Kero terminal:

```sh
kero +attention "deploy finished"
```

This is the weakest signal Kero shows — it fills the folder icon without
changing its color, and anything an agent reports about the session takes
precedence over it.

## Download

https://kero.sh

Or with Homebrew:

```sh
brew install egoist/tap/kero
```

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3
