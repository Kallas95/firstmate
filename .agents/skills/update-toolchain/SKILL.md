---
name: update-toolchain
description: >-
  Inventory and safely apply supported stable updates for the local agent toolchain.
  Use when the captain invokes /update-toolchain or asks to update Pi, Claude Code, Codex, Herdr, no-mistakes, quota-axi, Treehouse, Homebrew, or the supporting Firstmate tools.
user-invocable: true
metadata:
  internal: true
---

# update-toolchain

Inventory the local agent toolchain first, then apply only supported stable updates one at a time and verify each result.
This skill updates installed tools, not Firstmate's tracked repository.
Use `/updatefirstmate` for the Firstmate repository and its secondmates.

## Safety boundary

- Never use `--force`, a beta, preview, nightly, or a channel-setting command unless the captain explicitly names that channel or flag.
- Never change `PATH`, a shell profile, a package-manager configuration, a version-manager configuration, credentials, model settings, or an extension configuration.
- Never replace a custom launcher or an executable whose managing installer cannot be established.
- Never stop, restart, kill, hand off, close, delete, reset, or broadly interrupt a running agent, server, workspace, or validation run.
- Do not update a tool when its supported updater says it would disturb live work, or when the tool is known to have active work that its update could affect.
- Treat an unavailable tool, an unknown installer, a failed check, and an unsuccessful update as a recorded result, not a reason to substitute an install method or retry blindly.
- Do not update a project-local Pi package or extension unless the captain explicitly names that project and package.
- Do not use `pi update --force`, `herdr update --handoff`, `herdr channel set`, `no-mistakes update --force`, `no-mistakes update --beta`, or `no-mistakes update --yes`.

An active interactive session usually continues on its already-running executable, but a later invocation can see a new binary.
Preserve that boundary by deferring a potentially disruptive update rather than trying to make a live session reload.

## 1. Build the inventory

Run the read-only inventory before changing anything.
Use `command -v` and `type -a` for each available command, record the resolved executable, and capture its version with the command's documented version flag.
Do not infer ownership from a command name or a directory label.

Inventory these commands when present:

```sh
pi
claude
codex
herdr
no-mistakes
quota-axi
treehouse
gh-axi
chrome-devtools-axi
tasks-axi
lavish-axi
node
npm
brew
```

For every candidate updater, inspect its current help before using it.
Use the installed tool's help as the authority when its documented update interface differs from this skill.

Determine installation ownership without changing it:

```sh
command -v <tool>
type -a <tool>
<tool> --version
brew list --versions <formula-or-cask>
npm prefix -g
npm root -g
npm outdated -g --depth=0 --json
```

Only call a Homebrew or npm update path when the resolved executable belongs to that manager's installed prefix and the manager recognizes the installed package.
A wrapper, symlink, private build, version-manager shim, or executable outside the verified manager prefix is a custom installation unless its own `update` command is documented and succeeds.
Report custom installations without replacing them.

Capture Homebrew's pending set before upgrading it:

```sh
brew outdated --json=v2
brew services list
```

Do not use a stale cache as proof that no update exists.
If a current availability check requires refreshing Homebrew metadata, run `brew update` once before the final `brew outdated --json=v2` inventory and report that the metadata refresh succeeded or failed.

## 2. Check live-work guards

Check these guards before applying their corresponding updates.
A guard failure or an ambiguous result means defer that tool and continue with independent tools.

- For Pi, do not update project-local packages or extensions, and use `pi list` to record the managed global package set.
- For Herdr, use `herdr status server` and `herdr integration status` when available.
  Defer the Herdr binary update when a server or workspace is active or its status cannot be read.
  Do not alter an integration's installation or configuration merely because it is absent or reports a problem.
- For no-mistakes, run `no-mistakes daemon status` and `no-mistakes axi status`.
  Defer the update if any validation run is active, if the daemon state cannot be established, or if the tool reports shared activity that cannot be attributed safely.
  `no-mistakes update` resets its shared daemon, so a quiet current branch alone is not sufficient evidence that another branch or home is idle.
- For Treehouse, use `treehouse status`.
  Defer its update if the pool contains leased or active worktrees, or if the status cannot be read.
- For Homebrew, defer each pending formula that backs an active service reported by `brew services list`.
  Defer a pending cask or formula when its upgrade warns that it will close, stop, restart, or otherwise disrupt a running application or service.

Do not convert a deferred result into a request to terminate work.
Name the protecting condition in the final summary and leave the work untouched.

## 3. Apply updates in a safe order

Apply at most one updater at a time.
Before each update, record the resolved path and version.
After it returns, resolve the command again, capture the new version, and run its documented lightweight health command or `--help`.
Stop only that tool's path when verification fails, then continue with unrelated tools.

### Pi, model catalogs, and managed extensions

Use Pi's own stable updater for a Pi installation that reports the `update` command.
Refresh catalogs separately because it is an independent, non-configuration-changing operation:

```sh
pi update --models
```

Update Pi itself without forcing a reinstall:

```sh
pi update --self
```

Update only globally managed, unpinned Pi packages after recording `pi list`:

```sh
pi update --extensions --no-approve
```

Do not use `pi update --all` because separate operations make partial failure and verification attributable.
Pi skips pinned package versions and git refs by design.
Report those pins as intentionally unchanged instead of moving them to a different ref.
Do not approve project-local settings or update a project-local package in this skill's ordinary path.

Verify with:

```sh
pi --version
pi update --models
pi list
```

### Claude Code and Codex

Use each CLI's documented stable updater when the resolved executable is not confirmed to be Homebrew-managed:

```sh
claude update
codex update
```

When the resolved executable is confirmed to be Homebrew-managed, update it only through the single Homebrew formula operation in the Homebrew section.
Do not run both updater paths for the same executable.
Do not opt into a preview or alternate release channel.

Verify with:

```sh
claude --version
claude --help
codex --version
codex --help
```

### Herdr and integrations

Only when the Herdr live-work guard is clear, use its stable updater with no lifecycle handoff:

```sh
herdr update
```

Do not change Herdr's update channel.
Do not install, uninstall, reconfigure, or restart an integration as part of an update sweep.
Verify the binary and report each installed integration's post-update status:

```sh
herdr --version
herdr integration status
```

### no-mistakes

Only when the shared-work guard is clear, use the official stable update without bypass flags:

```sh
no-mistakes update
```

The updater may reset the daemon only after the guard proves it is safe.
Verify both the client and daemon after the update:

```sh
no-mistakes --version
no-mistakes daemon status
```

If the update requires an interactive safety confirmation that cannot be answered from the explicit request to update the toolchain, defer it and report the exact confirmation needed.

### quota-axi and Treehouse

Use each tool's supported availability check before its update when available:

```sh
quota-axi update --check
quota-axi update
treehouse update
```

Run `treehouse update` only after its live-work guard is clear.
Verify with:

```sh
quota-axi --version
quota-axi --help
treehouse --version
treehouse status
```

### Supporting npm tools

Treat `gh-axi`, `chrome-devtools-axi`, `tasks-axi`, and `lavish-axi` as independent packages.
For a package confirmed to be installed in npm's active global prefix, update that one named package with npm's supported global command:

```sh
npm update -g <package>
```

Do not use a broad `npm update -g` because it can alter unrelated global packages and custom launchers.
Verify the resulting executable through its own version or help command.
If the package is Homebrew-managed, leave it to the one corresponding Homebrew operation instead.

### Homebrew

After the final `brew outdated --json=v2` inventory, process only the listed, non-deferred formulae and casks one at a time:

```sh
brew upgrade <formula-or-cask>
```

Use a named package rather than a bare `brew upgrade` so every result has an owner and a partial failure does not hide subsequent work.
Before each operation, confirm that its item is still listed as outdated.
After it, check the named item with `brew info <formula-or-cask>` and refresh the remaining pending list.
Do not use greedy cask options unless the captain explicitly requests them.

## 4. Handle outcomes and report

Classify every inventoried item exactly once:

- `current` - no supported update was available.
- `updated and verified` - the updater completed and the resolved executable passed its post-update check.
- `deferred to protect active work` - the stated guard prevented a potentially disruptive update.
- `unavailable` - the command or manager is not installed.
- `custom or unsupported installation` - the executable's update owner could not be safely established.
- `failed` - the documented check, update, or verification failed, with its concise error.

Do not claim an update succeeded merely because the updater exited zero.
A changed resolved path, an unchanged version when an update was expected, or a failed health check is a verification failure.
Do not retry the same failing updater automatically.

End with a concise summary that lists updated tools and their verified versions, deferred tools and the work they protect, unavailable or custom tools, and every failure that needs attention.
State separately whether Homebrew still has pending packages.
If all applicable tools are current, say so without implying that unavailable or deferred tools were updated.
