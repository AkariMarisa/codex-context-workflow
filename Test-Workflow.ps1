[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot ('build/test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$testHome = Join-Path $testRoot 'isolated-codex-home'
$installer = Join-Path $PSScriptRoot 'Install.ps1'
$hookScript = Join-Path $PSScriptRoot 'on-compact.ps1'
$stateScript = Join-Path $PSScriptRoot 'Set-HandoffState.ps1'
$openScript = Join-Path $PSScriptRoot 'Open-Handoff.ps1'
$checks = 0
function Assert-Workflow([bool]$condition, [string]$label) {
    if (-not $condition) { throw ('FAIL: ' + $label) }
    $script:checks++
}
function Invoke-TestHook([hashtable]$data) {
    $json = $data | ConvertTo-Json -Compress
    $hookOutput = $json | & pwsh -NoProfile -NonInteractive -File $hookScript -StateDirectory (Join-Path $testRoot 'state') -DiagnosticsDirectory (Join-Path $testRoot 'diagnostics')
    if ($LASTEXITCODE -ne 0) { throw 'Hook process failed.' }
    return ($hookOutput -join [Environment]::NewLine)
}
$localConfigPath = Join-Path $testRoot '.workflow.local.json'
$localHome = Join-Path $testRoot 'local config home'
$environmentHome = Join-Path $testRoot 'environment-home'
$explicitHome = Join-Path $testRoot 'explicit-home'
[IO.File]::WriteAllText($localConfigPath, (@{ CodexHome = $localHome; InputTokenThreshold = 32100 } | ConvertTo-Json))
$previousCodexHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $null
    & $installer -LocalConfigPath $localConfigPath | Out-Null
    $localHooks = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $localHome 'hooks.json'))) -AsHashtable
    Assert-Workflow ($localHooks.hooks.PostModelRequest[0].hooks[0].command.EndsWith(' -InputTokenThreshold 32100')) 'local configuration selects installation path and threshold'

    $env:CODEX_HOME = $environmentHome
    $validated = @(& $installer -LocalConfigPath $localConfigPath -ValidateOnly)
    Assert-Workflow (($validated -ccontains ('Target CODEX_HOME: ' + $environmentHome)) -and -not [IO.Directory]::Exists($environmentHome)) 'CODEX_HOME takes precedence over the local installation path'
    & $installer -LocalConfigPath $localConfigPath -CodexHome $explicitHome -InputTokenThreshold 54321 | Out-Null
    $explicitHooks = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $explicitHome 'hooks.json'))) -AsHashtable
    Assert-Workflow ($explicitHooks.hooks.PostModelRequest[0].hooks[0].command.EndsWith(' -InputTokenThreshold 54321') -and -not [IO.Directory]::Exists($environmentHome)) 'explicit installation path and threshold take precedence over the environment and local configuration'
} finally {
    $env:CODEX_HOME = $previousCodexHome
}
$unwrittenHome = Join-Path $testRoot 'invalid-config-home'
$invalidConfigs = @(
    @{ Json = '{synthetic-canary'; Error = 'Local configuration must contain valid JSON.' },
    @{ Json = '[{}]'; Error = 'Local configuration must be a JSON object.' },
    @{ Json = '{"synthetic-canary": true}'; Error = 'Local configuration contains an unsupported field.' },
    @{ Json = '{"CodexHome": "one", "CodexHome": "two"}'; Error = 'Local configuration contains a duplicate field.' },
    @{ Json = '{"CodexHome": " "}'; Error = 'Local configuration CodexHome must be a nonempty string.' },
    @{ Json = '{"InputTokenThreshold": "32100"}'; Error = 'Local configuration InputTokenThreshold must be a positive 64-bit JSON integer.' },
    @{ Json = '{"InputTokenThreshold": 1.0}'; Error = 'Local configuration InputTokenThreshold must be a positive 64-bit JSON integer.' },
    @{ Json = '{"InputTokenThreshold": 0}'; Error = 'Local configuration InputTokenThreshold must be a positive 64-bit JSON integer.' },
    @{ Json = '{"InputTokenThreshold": 9223372036854775808}'; Error = 'Local configuration InputTokenThreshold must be a positive 64-bit JSON integer.' }
)
foreach ($invalidConfig in $invalidConfigs) {
    [IO.File]::WriteAllText($localConfigPath, $invalidConfig.Json)
    $rejection = $null
    try { & $installer -LocalConfigPath $localConfigPath -CodexHome $unwrittenHome -InputTokenThreshold 54321 | Out-Null } catch { $rejection = $_.Exception.Message }
    Assert-Workflow ($rejection -ceq $invalidConfig.Error -and -not [IO.Directory]::Exists($unwrittenHome)) ('invalid local configuration rejected before writes with error: ' + $invalidConfig.Error)
}
$rejection = $null
try { & $installer -LocalConfigPath (Join-Path $testRoot 'missing-config.json') -CodexHome $unwrittenHome | Out-Null } catch { $rejection = $_.Exception.Message }
Assert-Workflow ($rejection -ceq 'Local configuration file was not found.' -and -not [IO.Directory]::Exists($unwrittenHome)) 'explicitly requested missing configuration rejected before writes'

# Keep the existing checks and nested suites independent of any personal configuration.
[IO.File]::WriteAllText($localConfigPath, '{}')
$PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
$PSDefaultParameterValues['Install.ps1:LocalConfigPath'] = $localConfigPath
& $installer -CodexHome $testHome -ValidateOnly | Out-Null
Assert-Workflow (-not [IO.Directory]::Exists($testHome)) 'ValidateOnly does not create target'
[IO.Directory]::CreateDirectory($testHome) | Out-Null
$originalRule = '# 原有全局说明' + [Environment]::NewLine + '保留其他用户规则。'
[IO.File]::WriteAllText((Join-Path $testHome 'AGENTS.md'), $originalRule)
$config = '# synthetic configuration only' + [Environment]::NewLine + '[agents]' + [Environment]::NewLine + 'enabled = true'
[IO.File]::WriteAllText((Join-Path $testHome 'config.toml'), $config)
$originalHooks = @{
    description = 'synthetic user hooks'
    enabled = $true
    trusted_hash = 'synthetic-document-trust'
    hooks = @{
        SessionStart = @(@{ matcher = '^startup$'; hooks = @(@{ type = 'command'; command = 'echo SYNTHETIC_START'; timeout = 1 }) })
        Stop = @(@{ hooks = @(
            @{ type = 'command'; command = 'echo SYNTHETIC_STOP'; enabled = $false; trusted_hash = 'synthetic-handler-trust' }
            @{ type = 'command'; command = ('pwsh -NoProfile -NonInteractive -File "' + (Join-Path $testHome 'context-workflow/on-stop.ps1') + '"'); statusMessage = 'Codex context handoff stop' }
        ) })
    }
}
[IO.File]::WriteAllText((Join-Path $testHome 'hooks.json'), ($originalHooks | ConvertTo-Json -Depth 10))
& $installer -CodexHome $testHome | Out-Null
$globalPath = Join-Path $testHome 'AGENTS.md'
$global = [IO.File]::ReadAllText($globalPath)
Assert-Workflow ($global.StartsWith($originalRule)) 'original global instructions preserved'
Assert-Workflow ($global.Contains('fork_turns')) 'explicit clean context instruction installed'
Assert-Workflow ($global.Contains('ReadPressure') -and $global.Contains('任务包')) 'phase-first pressure decision installed'
Assert-Workflow ([IO.File]::ReadAllText((Join-Path $testHome 'config.toml')) -ceq $config) 'config model and permissions untouched'
Assert-Workflow ([IO.File]::Exists((Join-Path $testHome 'agents/context-worker.toml'))) 'worker profile installed'
foreach ($agent in @('context-scan','context-implement','context-visual','context-review')) {
    $file = "$agent.toml"
    Assert-Workflow ([IO.File]::ReadAllText((Join-Path $testHome "agents/$file")) -ceq [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file))) "installed model profile matches $file"
}
Assert-Workflow ([IO.File]::Exists((Join-Path $testHome 'context-workflow/on-compact.ps1'))) 'hook script installed'
Assert-Workflow ([IO.File]::Exists((Join-Path $testHome 'context-workflow/Set-HandoffState.ps1')) -and [IO.File]::Exists((Join-Path $testHome 'context-workflow/Open-Handoff.ps1'))) 'handoff helpers installed'
$installedHooks = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $testHome 'hooks.json'))) -AsHashtable
Assert-Workflow (@($installedHooks.hooks.Stop).Count -eq 1 -and @($installedHooks.hooks.Stop[0].hooks).Count -eq 1) 'retired managed Stop removed and unrelated Stop preserved'
Assert-Workflow ($installedHooks.enabled -and $installedHooks.trusted_hash -eq 'synthetic-document-trust' -and $installedHooks.hooks.Stop[0].hooks[0].enabled -eq $false -and $installedHooks.hooks.Stop[0].hooks[0].trusted_hash -eq 'synthetic-handler-trust') 'unrelated document and handler trust fields preserved'
Assert-Workflow ($installedHooks.hooks.PostModelRequest[0].hooks[0].command.Contains('-InputTokenThreshold 200000') -and -not $installedHooks.hooks.PostModelRequest[0].hooks[0].Contains('additionalContextLimit')) 'observer installed with threshold and without unsupported context fields'
Assert-Workflow (@($installedHooks.hooks.SessionStart).Count -eq 2) 'existing start handler preserved alongside managed handler'
$managed = @($installedHooks.hooks.SessionStart | Where-Object { $_.matcher -eq '^compact$' })
Assert-Workflow ($managed.Count -eq 1 -and $managed[0].hooks[0].command.Contains('on-compact.ps1')) 'one compact-only hook with quoted destination'
Assert-Workflow ($managed[0].hooks[0].additionalContextLimit -eq 4096) 'pending protocol context limit upgraded'
$beforeHash = (Get-FileHash -LiteralPath (Join-Path $testHome 'hooks.json')).Hash
$beforeBackups = @(Get-ChildItem -LiteralPath (Join-Path $testHome 'context-workflow/backups') -Directory).Count
$repeat = & $installer -CodexHome $testHome
Assert-Workflow (($repeat -join '').Contains('UNCHANGED')) 'repeat install reports no mutation'
Assert-Workflow ((Get-FileHash -LiteralPath (Join-Path $testHome 'hooks.json')).Hash -eq $beforeHash) 'repeat preserves exact hooks file'
Assert-Workflow (@(Get-ChildItem -LiteralPath (Join-Path $testHome 'context-workflow/backups') -Directory).Count -eq $beforeBackups) 'repeat creates no backup'
$backedGlobal = Get-ChildItem -LiteralPath (Join-Path $testHome 'context-workflow/backups') -Recurse -File -Filter AGENTS.md
Assert-Workflow ($backedGlobal.Count -eq 1 -and [IO.File]::ReadAllText($backedGlobal.FullName) -ceq $originalRule) 'original rules backed up exactly'
$conflictHome = Join-Path $testRoot 'override-conflict'
[IO.Directory]::CreateDirectory($conflictHome) | Out-Null
[IO.File]::WriteAllText((Join-Path $conflictHome 'AGENTS.override.md'), '# untouched override')
$rejected = $false
try { & $installer -CodexHome $conflictHome | Out-Null } catch { $rejected = $true }
Assert-Workflow ($rejected -and -not [IO.File]::Exists((Join-Path $conflictHome 'AGENTS.md'))) 'override conflict rejected before writes'
$eventData = @{ hook_event_name = 'SessionStart'; source = 'compact'; session_id = 'synthetic-session-one' }
$first = Invoke-TestHook $eventData
Assert-Workflow ([string]::IsNullOrWhiteSpace($first)) 'first compact silent'
$second = Invoke-TestHook $eventData
$notification = ConvertFrom-Json -InputObject $second -AsHashtable
Assert-Workflow ($notification.continue -eq $true) 'reminder never blocks task'
Assert-Workflow ($notification.hookSpecificOutput.hookEventName -eq 'SessionStart') 'valid hook output envelope'
Assert-Workflow ($notification.hookSpecificOutput.additionalContext.Length -lt 4096) 'reminder fits installed context limit'
Assert-Workflow (-not $notification.systemMessage -and $notification.hookSpecificOutput.additionalContext.Contains('ReadPressure')) 'context pressure yields one advisory without a UI reminder'
$third = Invoke-TestHook $eventData
Assert-Workflow ([string]::IsNullOrWhiteSpace($third)) 'pressure advisory does not repeat'
$other = Invoke-TestHook @{ hook_event_name = 'SessionStart'; source = 'compact'; session_id = 'synthetic-session-two' }
Assert-Workflow ([string]::IsNullOrWhiteSpace($other)) 'new session counter isolated'
$startup = Invoke-TestHook @{ hook_event_name = 'SessionStart'; source = 'startup'; session_id = 'synthetic-session-two' }
Assert-Workflow ([string]::IsNullOrWhiteSpace($startup)) 'startup is not counted as compaction'
$child = Invoke-TestHook @{ hook_event_name = 'SessionStart'; source = 'compact'; session_id = 'synthetic-session-two'; agent_id = 'synthetic-child' }
Assert-Workflow ([string]::IsNullOrWhiteSpace($child)) 'explicit subagent not counted against root'
$invalid = Invoke-TestHook @{ hook_event_name = 'SessionStart'; source = 'compact'; session_id = '../escape' }
Assert-Workflow ([string]::IsNullOrWhiteSpace($invalid)) 'invalid session path rejected'
$states = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -File -Filter '*.json')
Assert-Workflow ($states.Count -eq 2) 'only valid independent sessions persisted'
foreach ($state in $states) {
    $content = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($state.FullName)) -AsHashtable
    Assert-Workflow ($content.protocol_version -eq 2 -and -not $content.handoff_pending -and -not $content.ContainsKey('session_id')) 'compaction leaves handoff uncommitted with no raw session id'
}
$legacyId = 'synthetic-legacy'
$legacyKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($legacyId))).ToLowerInvariant()
$legacyPath = Join-Path $testRoot ('state/' + $legacyKey + '.json')
[IO.File]::WriteAllText($legacyPath, '{"compactions":7,"reminder_emitted":true}')
$upgraded = ConvertFrom-Json (Invoke-TestHook @{ hook_event_name='SessionStart'; source='compact'; session_id=$legacyId }) -AsHashtable
Assert-Workflow ($upgraded.hookSpecificOutput.additionalContext.Contains('ReadPressure') -and -not $upgraded.systemMessage) 'legacy reminder becomes an advisory without preparing handoff'
$summary = Join-Path $testRoot 'synthetic-summary.md'
[IO.File]::WriteAllText($summary, '# Synthetic summary only; no real task or goal.')
$argsState = @{ SessionId=$legacyId; StateDirectory=(Join-Path $testRoot 'state') }
& $stateScript @argsState -Action Prepare -SummaryPath $summary | Out-Null
$rejected = $false
try { & $stateScript @argsState -Action BeginCreate | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'unsafe creation cannot be marked started'
& $stateScript @argsState -Action BeginCreate -OldGoalInactive -WritersStopped -HandlesVerified | Out-Null
$rejected=$false
try { & $stateScript @argsState -Action BeginCreate -OldGoalInactive -WritersStopped -HandlesVerified | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'creating cannot be retried'
& $stateScript @argsState -Action MarkUncertain | Out-Null
$rejected=$false
try { & $stateScript @argsState -Action RecordCreated -ThreadId $legacyId | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'target cannot equal source session'
$rejected=$false
try { & $stateScript @argsState -Action Prepare -SummaryPath $summary | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'timeout cannot reset the creation guard'
& $stateScript @argsState -Action RecordCreated -ThreadId 'synthetic-thread-1' | Out-Null
$rejected=$false
try { & $stateScript @argsState -Action Confirm -ThreadId 'synthetic-thread-1' | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'created alone does not confirm summary read'
$pending = ConvertFrom-Json (Invoke-TestHook @{ hook_event_name='SessionStart'; source='compact'; session_id=$legacyId }) -AsHashtable
Assert-Workflow ([bool]$pending.hookSpecificOutput.additionalContext) 'created but unconfirmed remains pending'
& $stateScript @argsState -Action Confirm -ThreadId 'synthetic-thread-1' -NewSessionReadSummary | Out-Null
$rejected=$false
try { & $stateScript @argsState -Action Prepare -SummaryPath $summary | Out-Null } catch { $rejected=$true }
Assert-Workflow $rejected 'confirmed cannot roll back to a second creation'
$confirmed = Invoke-TestHook @{ hook_event_name='SessionStart'; source='compact'; session_id=$legacyId }
Assert-Workflow ([string]::IsNullOrWhiteSpace($confirmed)) 'confirmed handoff no longer prompts'

$manualArgs = @{ SessionId = 'synthetic-manual'; StateDirectory = $argsState.StateDirectory }
$manualKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manualArgs.SessionId))).ToLowerInvariant()
$manualState = Join-Path $manualArgs.StateDirectory "$manualKey.json"
$safetyFlags = @{ OldGoalInactive=$true; WritersStopped=$true; HandlesVerified=$true }
& $stateScript @manualArgs -Action Prepare -SummaryPath $summary | Out-Null
$beforeManual = [IO.File]::ReadAllText($manualState)
$rejected = $false
try { & $stateScript @manualArgs -Action RegisterManual -SummaryPath $summary -ThreadId 'manual-target' | Out-Null } catch { $rejected = $true }
Assert-Workflow ($rejected -and [IO.File]::ReadAllText($manualState) -ceq $beforeManual) 'manual registration requires safety evidence'
$rejected = $false
try { & $stateScript @manualArgs @safetyFlags -Action RegisterManual -SummaryPath $summary -ThreadId $manualArgs.SessionId | Out-Null } catch { $rejected = $true }
Assert-Workflow $rejected 'source cannot register itself as the manual target'
$rejected = $false
try { & $stateScript @manualArgs @safetyFlags -Action RegisterManual -SummaryPath ($summary + '.other') -ThreadId 'manual-target' | Out-Null } catch { $rejected = $true }
Assert-Workflow $rejected 'manual target binds to the prepared summary'
& $stateScript @manualArgs @safetyFlags -Action RegisterManual -SummaryPath $summary -ThreadId 'manual-target' | Out-Null
$registered = [IO.File]::ReadAllText($manualState) | ConvertFrom-Json -AsHashtable
Assert-Workflow ($registered.handoff_status -eq 'created' -and $registered.handoff_pending -and $registered.creation_mode -eq 'manual' -and $registered.new_thread_id -eq 'manual-target') 'manual target remains pending until the read receipt'
$rejected = $false
try { & $stateScript @manualArgs -Action Confirm -ThreadId 'another-target' -NewSessionReadSummary | Out-Null } catch { $rejected = $true }
Assert-Workflow $rejected 'a different session cannot confirm the manual target'
& $stateScript @manualArgs -Action Confirm -ThreadId 'manual-target' -NewSessionReadSummary | Out-Null
$registered = [IO.File]::ReadAllText($manualState) | ConvertFrom-Json -AsHashtable
Assert-Workflow ($registered.handoff_status -eq 'confirmed' -and -not $registered.handoff_pending) 'matching manual read receipt completes handoff'
$uncertainArgs = @{ SessionId = 'synthetic-manual-uncertain'; StateDirectory = $argsState.StateDirectory }
& $stateScript @uncertainArgs -Action Prepare -SummaryPath $summary | Out-Null
& $stateScript @uncertainArgs @safetyFlags -Action BeginCreate | Out-Null
& $stateScript @uncertainArgs -Action MarkUncertain | Out-Null
$rejected = $false
try { & $stateScript @uncertainArgs @safetyFlags -Action RegisterManual -SummaryPath $summary -ThreadId 'second-target' | Out-Null } catch { $rejected = $true }
Assert-Workflow $rejected 'manual path cannot replace an uncertain creation'
# Exercise both source and installed legacy entrypoints. Any attempted launch fails
# before reaching the OS; AST checks below also reject indirect execution APIs.
$script:clientLaunchAttempts = 0
function Start-Process { $script:clientLaunchAttempts++; throw 'Unexpected client launch.' }
function codex { $script:clientLaunchAttempts++; throw 'Unexpected Codex client launch.' }
try {
    foreach ($helper in @($openScript, (Join-Path $testHome 'context-workflow/Open-Handoff.ps1'))) {
        foreach ($options in @(@{}, @{ Open=$true }, @{ Open=$false })) {
            $hint = @(& $helper -ThreadId 'synthetic-thread-1' @options)
            Assert-Workflow ($hint[-1] -ceq 'codex resume synthetic-thread-1' -and ($hint -join ' ').Contains('Exit the current Codex CLI')) 'default and legacy Open only provide exact CLI resume instruction'
            Assert-Workflow (-not ($hint -join ' ').Contains('codex://')) 'resume instruction contains no desktop deep link'
        }
        foreach ($badId in @('', '../escape','abc?x=1','abc/def','abc";calc','abc%0a', "abc`n", "abc`r`n", 'abc def', '-option', ('a' * 129))) {
            foreach ($options in @(@{}, @{ Open=$true })) {
                $rejected=$false
                try { & $helper -ThreadId $badId @options | Out-Null } catch { $rejected=$true }
                Assert-Workflow $rejected 'unsafe CLI resume id rejected for default and legacy Open'
            }
        }
        $maxId = 'a' * 128
        Assert-Workflow ((@(& $helper -ThreadId $maxId))[-1] -ceq ('codex resume ' + $maxId)) 'maximum valid resume id preserved exactly'
    }
    Assert-Workflow ($script:clientLaunchAttempts -eq 0) 'all helper entrypoints leave process launch functions untouched'
} finally {
    Remove-Item Function:Start-Process
    Remove-Item Function:codex
}
$badRoot = Join-Path $testRoot 'bad-state'
[IO.Directory]::CreateDirectory($badRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $badRoot ($legacyKey + '.json')), '{"compactions":-1,"reminder_emitted":true}')
$bad = (@{ hook_event_name='SessionStart'; source='compact'; session_id=$legacyId } | ConvertTo-Json -Compress) | & pwsh -NoProfile -NonInteractive -File $hookScript -StateDirectory $badRoot -DiagnosticsDirectory (Join-Path $testRoot 'diagnostics')
Assert-Workflow ((ConvertFrom-Json ($bad -join '')).continue -eq $true) 'corrupt state fails open without blocking model summary'
& $stateScript -SessionId 'manual-handoff' -StateDirectory (Join-Path $testRoot 'state') -Action Prepare -SummaryPath $summary | Out-Null
$manual = ConvertFrom-Json (Invoke-TestHook @{ hook_event_name='SessionStart'; source='compact'; session_id='manual-handoff' }) -AsHashtable
Assert-Workflow ($manual.hookSpecificOutput.additionalContext.Contains('次数：1；')) 'manual prepare at first compact does not claim two compactions'
& (Join-Path $PSScriptRoot 'Test-Proactive.ps1') -TestRoot $testRoot -TestHome $testHome
& (Join-Path $PSScriptRoot 'Test-Diagnostics.ps1')
# Validate the actual shared create/race-resume prompt, not mirrored prose.
$promptScript = Join-Path $testHome 'context-workflow/New-HandoffPrompt.ps1'
Assert-Workflow ([IO.File]::ReadAllText($promptScript) -ceq [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-HandoffPrompt.ps1'))) 'installed canonical prompt matches source'
$promptArgs = @{ SummaryPath=$summary; SessionId=$legacyId; StatePath=$legacyPath; ContinuationMode='ResumeAuthorized' }
$stateBefore = [IO.File]::ReadAllText($legacyPath)
foreach ($mode in @('ReadOnly','Paused','NeedsDecision','ResumeAuthorized')) {
    [IO.File]::WriteAllText($summary, "Handoff-ContinuationMode: $mode`nHandoff-AuthorizedScope: synthetic implementation only")
    $prompt = & $promptScript @promptArgs
    $expectedMode = if ($mode -eq 'ResumeAuthorized') { 'ResumeAuthorized' } else { 'ReadOnly' }
    Assert-Workflow ($prompt.Contains("ContinuationMode: $expectedMode") -and [Text.Encoding]::UTF8.GetByteCount($prompt) -le 1000) 'effective prompt preserves explicit authority or restrictive mode within byte limit'
}
Assert-Workflow ($prompt.Contains('without asking again') -and $prompt.Contains('if confirmed do not Confirm again') -and $prompt.Contains('If creating/uncertain') -and $prompt.Contains('Never resume/create/migrate goals')) 'authorized create/race prompt keeps safety gates and continues without repeat approval/Confirm'
# Manually pasted prompts are not subject to the native creation tool's limit.
$manualByteLimit = 4096
$manualPrompt = & $promptScript @promptArgs -ManualTarget -MaxUtf8Bytes $manualByteLimit
Assert-Workflow ($manualPrompt.Contains('RegisterManual') -and $manualPrompt.Contains('exact summary path') -and $manualPrompt.Contains('If creating/uncertain') -and [Text.Encoding]::UTF8.GetByteCount($manualPrompt) -le $manualByteLimit) 'manual prompt includes recovery gates within configured byte limit'
foreach ($content in @('# missing fields', 'Handoff-ContinuationMode: ResumeAuthorized', "Handoff-ContinuationMode: ResumeAuthorized`nHandoff-AuthorizedScope: ", "Handoff-ContinuationMode: ResumeAuthorized`nHandoff-ContinuationMode: Paused`nHandoff-AuthorizedScope: synthetic", ('# Example only' + "`n" + '```text' + "`nHandoff-ContinuationMode: ResumeAuthorized`nHandoff-AuthorizedScope: example`n" + '```'))) {
    [IO.File]::WriteAllText($summary, $content)
    Assert-Workflow ((& $promptScript @promptArgs).Contains('ContinuationMode: ReadOnly')) 'missing scope/mode or conflicting modes fall back to read-only'
}
[IO.File]::WriteAllText($summary, "Handoff-ContinuationMode: ResumeAuthorized`nHandoff-AuthorizedScope: synthetic")
$defaultArgs = $promptArgs.Clone(); $defaultArgs.Remove('ContinuationMode')
Assert-Workflow ((& $promptScript @defaultArgs).Contains('ContinuationMode: ReadOnly')) 'default generator request never infers continuation'
$rejected=$false; $partial=@()
try { $partial = @(& $promptScript @promptArgs -MaxUtf8Bytes 100) } catch { $rejected=$true }
Assert-Workflow ($rejected -and $partial.Count -eq 0) 'overlong prompt rejected without truncation or output'
Assert-Workflow ([IO.File]::ReadAllText($legacyPath) -ceq $stateBefore) 'prompt creation/resume never mutates confirmed state'
# Managed helper upgrade gets backup and ValidateOnly/ownership protection.
$promptOriginal=[IO.File]::ReadAllText($promptScript)
[IO.File]::WriteAllText($promptScript, $promptOriginal + "`n# synthetic old managed version")
$promptOld=[IO.File]::ReadAllText($promptScript)
& $installer -CodexHome $testHome -ValidateOnly | Out-Null
Assert-Workflow ([IO.File]::ReadAllText($promptScript) -ceq $promptOld) 'ValidateOnly leaves existing prompt helper untouched'
& $installer -CodexHome $testHome | Out-Null
$promptBackups=@(Get-ChildItem -LiteralPath (Join-Path $testHome 'context-workflow/backups') -Recurse -Filter New-HandoffPrompt.ps1)
Assert-Workflow ($promptBackups.Count -eq 1 -and [IO.File]::ReadAllText($promptBackups[0].FullName) -ceq $promptOld -and [IO.File]::ReadAllText($promptScript) -ceq $promptOriginal) 'managed prompt upgrade backed up and installed exactly'
Assert-Workflow ((@(& $installer -CodexHome $testHome) -join '').Contains('UNCHANGED')) 'prompt helper upgrade remains idempotent'
[IO.File]::WriteAllText($promptScript, '# synthetic unowned helper')
$rejected=$false
try { & $installer -CodexHome $testHome -ValidateOnly | Out-Null } catch { $rejected=$true }
Assert-Workflow ($rejected -and [IO.File]::ReadAllText($promptScript) -ceq '# synthetic unowned helper') 'unowned prompt helper rejected before writes'
[IO.File]::WriteAllText($promptScript, $promptOriginal)
foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $parseTokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$parseTokens,[ref]$parseErrors)
    Assert-Workflow ($parseErrors.Count -eq 0) ('AST parses: ' + $scriptFile.Name)
    if ($scriptFile.Name -in @('on-compact.ps1','on-model-request.ps1','on-stop.ps1','Workflow-State.ps1','Workflow-Diagnostics.ps1','Get-WorkflowDiagnostics.ps1','Set-HandoffState.ps1','Open-Handoff.ps1','New-HandoffPrompt.ps1')) {
        $dangerous=$ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '(?i)(Start-Process|Stop-Process|create_thread|update_goal|Invoke-RestMethod|Invoke-WebRequest)' },$true)
        Assert-Workflow ($dangerous.Count -eq 0) ('state/hook cannot create sessions, stop processes or call external APIs: ' + $scriptFile.Name)
    }
}
$openTokens=$null; $openErrors=$null
$openAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $testHome 'context-workflow/Open-Handoff.ps1'),[ref]$openTokens,[ref]$openErrors)
$openCommands=$openAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] },$true)
Assert-Workflow (@($openCommands | Where-Object { $_.GetCommandName() -ne 'Write-Output' }).Count -eq 0) 'installed helper only invokes Write-Output; no shell or indirect process launch'
Assert-Workflow ($openAst.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] },$true).Count -eq 0) 'installed helper has no process launch via method calls'
Write-Output ('PASS: ' + $checks + ' checks; isolated installation/state migration/retry guards/CLI resume without client launch/AST; no real session created, goal changed, UI opened or process stopped by tests.')
Write-Output ('Retained synthetic fixtures: ' + $testRoot)

$proactiveResults = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $testRoot 'proactive-results.json')))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'build/validation-latest.txt'), ('PASS: legacy checks=' + $checks + '; proactive checks=' + $proactiveResults.checks + '; synthetic only; native acceptance not run.' + [Environment]::NewLine + 'Fixtures: ' + $testRoot + [Environment]::NewLine + $proactiveResults.timing + [Environment]::NewLine + 'No active test process handles remain.'))
