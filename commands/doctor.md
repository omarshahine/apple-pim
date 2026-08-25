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
5. **TCC authorization** per domain, prompt-free, on both routes. The direct
   route is what a normal terminal gets. The PIMHelper route is what an agent
   shell gets, and it carries its own grant, bound to the helper's bundle and
   signature. Each domain prints one line per route. `auth-status` only reads
   the authorization status and never requests access, so probing through the
   helper cannot raise a dialog. The helper-route probe is skipped, with a
   warning, while a helper is already resident — only one can run at a time.
6. **MCP server artifacts** — `dist/server.js` and node_modules.

## Interpreting results for the user

- Exit 0 = healthy; summarize any warnings briefly.
- **Broken symlink** → the source repo moved or was renamed. Remedy: rebuild
  and reinstall as copies (`setup.sh --install` from the repo), which is
  immune to future renames.
- **Stuck helper** → offer `--fix`, then have the user retry their original
  request.
- **notDetermined on the direct route, helper installed** → normal in an agent
  shell, and not a verdict on its own. Read the helper-route line under it.
- **notDetermined + no helper** → run `scripts/build-helper-app.sh`, then the
  next Calendar/Reminders/Contacts call raises the macOS dialog; tell the
  user to answer it (they have ~2 minutes).
- **helper route not granted** (failure) → calls from an agent shell will block
  on a dialog nobody sees for up to 2 minutes, then wedge the helper. The
  usual cause is a helper rebuild, which re-signs the bundle and drops every
  grant. Have the user make a real Calendar / Reminders / Contacts call from a
  normal terminal and answer the prompt.
- **helper route not yet granted** (warning) → the same missing grant, but the
  direct route works here, so nothing is broken until something calls from an
  embedded shell.
- **helper route denied** → the grant exists and is switched off. System
  Settings > Privacy & Security > the matching section, enable PIMHelper.
- **helper probe inconclusive** → the probe could not reach the helper: one was
  already resident, the launch failed, or it returned nothing. Check the
  Helper processes section, clear a stuck instance with `--fix`, re-run.
- After any fix, verify by calling a real tool (e.g. reminder lists), not
  just by re-running doctor.
