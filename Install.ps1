[CmdletBinding()]
param(
    [string]$CodexHome = $env:CODEX_HOME,
    [ValidateRange(1, [long]::MaxValue)][long]$InputTokenThreshold = 200000,
    [switch]$ValidateOnly,
    [ValidateNotNullOrEmpty()][string]$LocalConfigPath = (Join-Path $PSScriptRoot '.workflow.local.json')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run with PowerShell 7 (pwsh).' }
$localConfigJson = $null
try {
    $localConfigFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LocalConfigPath)
    $localConfigJson = [IO.File]::ReadAllText($localConfigFile)
} catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
    if ($PSBoundParameters.ContainsKey('LocalConfigPath')) { throw 'Local configuration file was not found.' }
} catch {
    throw 'Local configuration file could not be read.'
}
if ($null -ne $localConfigJson) {
    try {
        $localConfig = [System.Text.Json.JsonDocument]::Parse($localConfigJson)
    } catch {
        throw 'Local configuration must contain valid JSON.'
    }
    try {
        if ($localConfig.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'Local configuration must be a JSON object.'
        }
        $fields = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $localCodexHome = $null
        [long]$localInputTokenThreshold = 0
        foreach ($property in $localConfig.RootElement.EnumerateObject()) {
            if (-not $fields.Add($property.Name)) { throw 'Local configuration contains a duplicate field.' }
            switch -CaseSensitive ($property.Name) {
                'CodexHome' {
                    if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                        [string]::IsNullOrWhiteSpace($property.Value.GetString())) {
                        throw 'Local configuration CodexHome must be a nonempty string.'
                    }
                    $localCodexHome = $property.Value.GetString()
                }
                'InputTokenThreshold' {
                    if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
                        -not $property.Value.TryGetInt64([ref]$localInputTokenThreshold) -or
                        $localInputTokenThreshold -lt 1) {
                        throw 'Local configuration InputTokenThreshold must be a positive 64-bit JSON integer.'
                    }
                }
                default { throw 'Local configuration contains an unsupported field.' }
            }
        }
    } finally {
        $localConfig.Dispose()
    }
    if (-not $PSBoundParameters.ContainsKey('CodexHome') -and -not $CodexHome -and $localCodexHome) {
        $CodexHome = $localCodexHome
    }
    if (-not $PSBoundParameters.ContainsKey('InputTokenThreshold') -and $localInputTokenThreshold) {
        $InputTokenThreshold = $localInputTokenThreshold
    }
}
if (-not $CodexHome) { $CodexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
try {
    $targetRoot = [IO.Path]::GetFullPath($CodexHome)
} catch {
    throw 'The selected CODEX_HOME is not a valid path.'
}
if ([IO.File]::Exists((Join-Path $targetRoot 'AGENTS.override.md'))) {
    throw 'AGENTS.override.md exists and takes precedence. Merge the supplied rule there manually; no files changed.'
}
$rule = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'global-rules.md')).TrimEnd()
$marker = 'CODEX_CONTEXT_WORKFLOW_V1'
$startMarker = '<!-- BEGIN CODEX_CONTEXT_WORKFLOW_V1 -->'
$endMarker = '<!-- END CODEX_CONTEXT_WORKFLOW_V1 -->'
if (-not $rule.Contains($startMarker) -or -not $rule.Contains($endMarker)) { throw 'Rule source markers missing.' }
$globalPath = Join-Path $targetRoot 'AGENTS.md'
$oldGlobal = if ([IO.File]::Exists($globalPath)) { [IO.File]::ReadAllText($globalPath) } else { '' }
if ($oldGlobal.Contains($startMarker) -or $oldGlobal.Contains($endMarker)) {
    $pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ([regex]::Matches($oldGlobal, [regex]::Escape($startMarker)).Count -ne 1 -or
        [regex]::Matches($oldGlobal, [regex]::Escape($endMarker)).Count -ne 1 -or
        [regex]::Matches($oldGlobal, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline).Count -ne 1) {
        throw 'Existing managed rule markers are malformed; no files changed.'
    }
    $replacement = [Text.RegularExpressions.MatchEvaluator]{ param($match) $rule }
    $newGlobal = [regex]::Replace($oldGlobal, $pattern, $replacement, [Text.RegularExpressions.RegexOptions]::Singleline)
} else {
    $separator = if ($oldGlobal.Length -gt 0) { [Environment]::NewLine + [Environment]::NewLine } else { '' }
    $newGlobal = $oldGlobal + $separator + $rule + [Environment]::NewLine
}
$managedFiles = [ordered]@{
    agents = @('context-worker.toml', 'context-scan.toml', 'context-implement.toml', 'context-visual.toml', 'context-review.toml')
    'context-workflow' = @('Workflow-State.ps1', 'Workflow-HookIO.ps1', 'Workflow-Diagnostics.ps1',
        'Set-HandoffState.ps1', 'Open-Handoff.ps1', 'New-HandoffPrompt.ps1', 'Get-WorkflowDiagnostics.ps1',
        'on-compact.ps1', 'on-model-request.ps1', 'on-stop.ps1')
}
$writes = @(@{ Path = $globalPath; Content = $newGlobal })
foreach ($directory in $managedFiles.Keys) {
    foreach ($file in $managedFiles[$directory]) {
        $destination = Join-Path $targetRoot "$directory/$file"
        if ([IO.File]::Exists($destination) -and -not ([IO.File]::ReadAllText($destination)).Contains($marker)) {
            throw "Destination lacks the workflow ownership marker: $destination. No files changed."
        }
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file))
        if (-not $source.Contains($marker)) { throw "Missing ownership marker in $file. No files changed." }
        $writes += @{ Path = $destination; Content = $source }
    }
}
$hooksPath = Join-Path $targetRoot 'hooks.json'
$hooksDocument = if ([IO.File]::Exists($hooksPath)) {
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($hooksPath)) -AsHashtable
} else { @{} }
if ($hooksDocument -isnot [Collections.IDictionary]) { throw 'hooks.json must be a JSON object; no files changed.' }
if (-not $hooksDocument.ContainsKey('hooks')) { $hooksDocument.hooks = @{} }
if ($hooksDocument.hooks -isnot [Collections.IDictionary]) { throw 'hooks must be an object; no files changed.' }
$definitions = @(
    @{ Event = 'SessionStart'; Script = 'on-compact.ps1'; Label = 'Codex context handoff'; Matcher = '^compact$' },
    @{ Event = 'PostModelRequest'; Script = 'on-model-request.ps1'; Label = 'Codex context handoff observation' },
    @{ Event = 'Stop'; Label = 'Codex context handoff stop'; Retired = $true }
)
foreach ($definition in $definitions) {
    $groups = @()
    $existingHandler = $null
    $existingGroup = $null
    foreach ($group in @($hooksDocument.hooks[$definition.Event])) {
        if ($null -eq $group) { continue }
        if ($group -isnot [Collections.IDictionary] -or -not $group.ContainsKey('hooks')) { throw 'Invalid hook group; no files changed.' }
        foreach ($candidate in @($group.hooks)) {
            if ($candidate.statusMessage -eq $definition.Label -and -not $existingHandler) { $existingHandler = $candidate; $existingGroup = $group }
        }
        $handlers = @($group.hooks | Where-Object { $_.statusMessage -ne $definition.Label })
        if ($handlers.Count -gt 0) { $group.hooks = $handlers; $groups += ,$group }
    }
    if ($definition.Retired) {
        if ($existingHandler) {
            if ($groups.Count -gt 0) { $hooksDocument.hooks[$definition.Event] = $groups }
            else { [void]$hooksDocument.hooks.Remove($definition.Event) }
        }
        continue
    }
    $scriptPath = Join-Path $targetRoot ('context-workflow/' + $definition.Script)
    $command = 'pwsh -NoProfile -NonInteractive -File "' + $scriptPath + '"'
    if ($definition.Event -eq 'PostModelRequest') { $command += ' -InputTokenThreshold ' + $InputTokenThreshold.ToString([Globalization.CultureInfo]::InvariantCulture) }
    $handler = [ordered]@{ type = 'command'; command = $command; commandWindows = $command; timeout = 5; async = $false; statusMessage = $definition.Label }
    # Only SessionStart supports additional context. PostModelRequest is diagnostic-only.
    if ($definition.Event -eq 'SessionStart') { $handler.additionalContextLimit = 4096 }
    # Preserve user control/trust metadata. A stored hash is never recomputed: the
    # host must reject stale trust after a definition change and request review.
    if ($existingHandler) {
        foreach ($field in $existingHandler.Keys) {
            if (-not $handler.Contains($field) -and $field -ne 'additionalContextLimit') { $handler[$field] = $existingHandler[$field] }
        }
    }
    $newGroup = [ordered]@{ hooks = @($handler) }
    if ($existingGroup) {
        foreach ($field in $existingGroup.Keys) {
            if ($field -notin @('hooks','matcher')) { $newGroup[$field] = $existingGroup[$field] }
        }
    }
    if ($definition.Matcher) { $newGroup.matcher = $definition.Matcher }
    $groups += ,$newGroup
    $hooksDocument.hooks[$definition.Event] = $groups
}
# Install the helpers and target scripts before publishing the hook definitions.
$writes += @{ Path = $hooksPath; Content = ($hooksDocument | ConvertTo-Json -Depth 100) }
# All validation is complete before any destination mutation.
if ($ValidateOnly) {
    Write-Output 'VALIDATED: rule/worker/hook and destination merge checked; no destination files written.'
    Write-Output ('Target CODEX_HOME: ' + $targetRoot)
    return
}
$changed = @($writes | Where-Object { -not [IO.File]::Exists($_.Path) -or [IO.File]::ReadAllText($_.Path) -cne $_.Content })
if ($changed.Count -eq 0) { Write-Output 'UNCHANGED: workflow already installed; no new backup or write.'; return }
$backupRoot = Join-Path $targetRoot ('context-workflow/backups/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
foreach ($item in $changed) {
    if ([IO.File]::Exists($item.Path)) {
        $relative = [IO.Path]::GetRelativePath($targetRoot, $item.Path)
        $backup = Join-Path $backupRoot $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup)) | Out-Null
        [IO.File]::Copy($item.Path, $backup, $false)
    }
}
foreach ($item in $changed) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Path)) | Out-Null
    [IO.File]::WriteAllText($item.Path, $item.Content, [Text.UTF8Encoding]::new($false))
}
Write-Output ('INSTALLED: ' + $changed.Count + ' managed files; existing unrelated instructions/hooks preserved.')
Write-Output ('Backup directory: ' + $backupRoot)
Write-Output 'config.toml, models, permissions, credentials and existing goals were not changed.'
Write-Output 'Start a new Codex session, open /hooks, review and trust all changed/new Codex context handoff hooks; existing trust is not bypassed.'
Write-Output 'Global instructions guide delegation; verify a real spawn uses no inherited conversation history.'
