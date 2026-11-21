# Codex Context Workflow

[中文](README.md) · English

A set of rules and PowerShell scripts for development work that spans multiple Codex sessions. It lets the main session delegate a batch of work to an isolated subagent and use a single summary to pick up where it left off. Small changes still stay in the main session.

## Install

Requires PowerShell 7. Run these commands from the repository directory.

```powershell
pwsh -NoProfile -File ./Install.ps1 -ValidateOnly
pwsh -NoProfile -File ./Install.ps1
```

The first command checks the configuration and prints the installation path. The installer adds a marked block to `AGENTS.md`, registers two hooks in `hooks.json`, and installs five subagent roles and their helper scripts. It keeps existing rules and other hooks and backs up files before changing them. Installation stops if it finds `AGENTS.override.md` or an existing role file or script with the same name and no project ownership marker.

Start a new Codex session, then review and trust both hooks under `/hooks` in the CLI or **Settings → Hooks** in the desktop app.

### Use a different installation path

The default is `~/.codex`. The installer checks `-CodexHome` first, then the `CODEX_HOME` environment variable, then `CodexHome` in the local config.

To save machine-specific settings, copy the [example config](.workflow.local.example.json) to `.workflow.local.json` next to the installer. Use `-LocalConfigPath` to point to a different file. Both fields are optional.

## How it works

- **For longer tasks**, the main session can split investigation, implementation, and verification into batches. It records the scope and pass criteria before each batch and runs checks at the end. Subagents work in isolated sessions, with one writer at a time by default. See the `context-*.toml` files for the roles. Your model and reasoning settings still apply to the main session.
- **As context grows**, `PostModelRequest` quietly samples input size. If a handoff is still unprepared, `SessionStart` prompts the main session to consider one on the second compaction. The main session also weighs what it would take to finish the current batch, how much work remains, and how much context a new session would need to reload.
- **When a new session makes sense**, the main session updates a single summary with what it delivered, what it checked, what remains, and the next step. The new session reads the summary, applicable rules, and handoff state before continuing within the verified scope.

The default threshold is 200,000 input tokens in a single request, including cached input. Set `-InputTokenThreshold` or the JSON field of the same name to change it. The command-line option takes precedence.

The main session follows the [workflow rules](global-rules.md) when batching work, delegating, or deciding to switch sessions. Isolated delegation and new-session creation depend on the tools exposed by your Codex host.

## What happens during a handoff

1. The main session records `Prepare` with [`Set-HandoffState.ps1`](Set-HandoffState.ps1). It verifies that the old goal is inactive, all writers have stopped, and the ownership and status of process handles are known. The first two lines of the summary declare the continuation mode and authorized scope. See the [global rules](global-rules.md) for the format.
2. If the host exposes a native creation tool, the main session records `BeginCreate`, calls the tool once, and saves the returned session ID with `RecordCreated`. If the outcome is unclear, it checks the original call to avoid creating a duplicate session.
3. If the host has no native creation tool, the state is still `prepared`, and native creation has never been attempted, the main session generates a prompt with [`New-HandoffPrompt.ps1`](New-HandoffPrompt.ps1) and `-ManualTarget`. Run `/new` in the same CLI, use the same working directory, and paste the prompt. The new session verifies the handoff before running `RegisterManual`.
4. Once the new session has read the summary, it uses the registered ID to run `Confirm`. This acknowledges receipt. Continuing implementation still requires explicit authorization in the summary that remains in effect.

If the new session already exists and the host cannot switch to it in the current window, exit the CLI and run `codex resume <new-session-id>` in the same terminal. [`Open-Handoff.ps1`](Open-Handoff.ps1) prints that command.

## Troubleshoot hooks

Both hooks log timings, outcomes, and skip reasons by default under `context-workflow/diagnostics/` in the installation directory. The logs keep up to three 1 MiB files locally. They use hashed session IDs and omit chat content, paths, and token counts.

Run this command from the installed `context-workflow/` directory.

```powershell
./Get-WorkflowDiagnostics.ps1 -SessionId '<actual-session-id>' -Last 30
```

Omit `-SessionId` to see records across sessions. If a start record has no matching finish, the retained logs only establish that the finish record is missing. Check the host logs or `/warnings` in the CLI for more context.

## Run the tests

```powershell
pwsh -NoProfile -File ./Test-Workflow.ps1
```

The tests use an isolated configuration directory under `build/` and cover installation, hook output, diagnostics, and handoff state. Verify live session creation, CLI behavior, and subagent isolation in the target host.

[License](LICENSE)
