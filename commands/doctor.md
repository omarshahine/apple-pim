---
description: Diagnose the apple-pim install — binaries, helper app, stuck processes, permissions, MCP build
argument-hint: "[--fix]"
allowed-tools:
  - Bash
---

# Apple PIM Doctor

Run the end-to-end install diagnostic and interpret the results for the user.

## Run it

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

With `--fix` (only when the user asked to fix, or after showing them a stuck-helper failure):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --fix
```

## What it checks, in dependency order

1. **Swift CLI binaries** in `~/.local/bin` — flags broken symlinks (the classic
   post-repo-rename failure), missing binaries, and non-executable files.
   A symlinked install gets a dev-mode warning: it breaks if the source repo
   is moved, renamed, or cleaned.
2. **PATH** visibility of `~/.local/bin`.
3. **PIMHelper.app** — presence, dispatcher executability, code signature.
   The signature matters: macOS TCC binds permission grants to it.
4. **Stuck helper processes** — a wedged `pim-helper` (usually an unanswered
   permission dialog) blocks every later call with Launch Services error
   -1712. `--fix` reaps these.
5. **TCC authorization** per domain, prompt-free. `notDetermined` with the
   helper installed is NORMAL for agent shells — calls route through the
   helper, whose grant is separate and invisible to this probe.
6. **MCP server artifacts** — `dist/server.js` and node_modules.

## Interpreting results for the user

- Exit 0 = healthy; summarize any warnings briefly.
- **Broken symlink** → the source repo moved or was renamed. Remedy: rebuild
  and reinstall as copies (`setup.sh --install` from the repo), which is
  immune to future renames.
- **Stuck helper** → offer `--fix`, then have the user retry their original
  request.
- **notDetermined + no helper** → run `scripts/build-helper-app.sh`, then the
  next Calendar/Reminders/Contacts call raises the macOS dialog; tell the
  user to answer it (they have ~2 minutes).
- After any fix, verify by calling a real tool (e.g. reminder lists), not
  just by re-running doctor.
