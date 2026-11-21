# Isolated behavioral tests of installed hooks; no native session/goal/UI operations.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$TestHome)
$ErrorActionPreference = 'Stop'
$script:proactiveChecks = 0
$samples = [Collections.Generic.List[double]]::new()
$stateRoot = Join-Path $TestRoot 'proactive-state'
$installed = Join-Path $TestHome 'context-workflow'
function Assert-Proactive([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:proactiveChecks++
}
function Get-TestStatePath([string]$Id) {
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Id))).ToLowerInvariant()
    Join-Path $stateRoot ($hash + '.json')
}
function Read-TestState([string]$Id) { ConvertFrom-Json ([IO.File]::ReadAllText((Get-TestStatePath $Id))) -AsHashtable }
function Invoke-Proactive([string]$Script, $Data, [long]$Threshold = 200000) {
    $json = if ($Data -is [string]) { $Data } else { $Data | ConvertTo-Json -Depth 10 -Compress }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $installed $Script),'-StateDirectory',$stateRoot)
    if ($Script -eq 'on-model-request.ps1') { $arguments += @('-InputTokenThreshold', $Threshold) }
    $output = $json | & pwsh @arguments
    $samples.Add($watch.Elapsed.TotalMilliseconds)
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic hook failed.' }
    $output -join [Environment]::NewLine
}
function New-UsageEvent([string]$Id, $Tokens) { @{ hook_event_name='PostModelRequest'; session_id=$Id; status='completed'; token_usage=@{ input_tokens=$Tokens } } }
function Read-TestPressure([string]$Id) {
    $json = & (Join-Path $installed 'Set-HandoffState.ps1') -SessionId $Id -StateDirectory $stateRoot -Action ReadPressure
    ConvertFrom-Json $json -AsHashtable
}
function Test-PressureSampleAbsent($State) {
    -not ($State.ContainsKey('request_input_tokens') -or $State.ContainsKey('input_token_threshold') -or $State.ContainsKey('trigger_reason'))
}
$id = 'synthetic-proactive'
$pressure = Read-TestPressure $id
Assert-Proactive ($pressure.request_pressure -eq 'unknown' -and $pressure.compactions -eq 0 -and (Test-PressureSampleAbsent $pressure) -and -not [IO.Directory]::Exists($stateRoot)) 'missing state has unknown pressure and read creates no directory'
$coldStop = Invoke-Proactive 'on-stop.ps1' @{hook_event_name='Stop';session_id=$id;stop_hook_active=$false}
Assert-Proactive ([string]::IsNullOrWhiteSpace($coldStop) -and -not [IO.Directory]::Exists($stateRoot)) 'compatibility Stop is silent and creates no state directory'
1..2 | ForEach-Object { Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 199999) | Out-Null }
Assert-Proactive (-not [IO.Directory]::Exists($stateRoot)) 'below threshold requests do not accumulate or touch state directory'
$output = Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 200000)
$state = Read-TestState $id
Assert-Proactive ([string]::IsNullOrWhiteSpace($output) -and $state.handoff_pending -eq $false -and $state.request_input_tokens -eq 200000 -and $state.input_token_threshold -eq 200000 -and $state.compactions -eq 0) 'boundary silently records pressure without requesting handoff'
Assert-Proactive ($state.Count -eq 8 -and $state.trigger_reason -eq 'single_request_input_tokens') 'only minimal pressure fields persisted'
$hash = (Get-FileHash (Get-TestStatePath $id)).Hash
$time = [IO.File]::GetLastWriteTimeUtc((Get-TestStatePath $id))
$pressure = Read-TestPressure $id
Assert-Proactive ($pressure.request_pressure -eq 'elevated' -and $pressure.compactions -eq 0 -and $pressure.request_input_tokens -eq 200000 -and $pressure.input_token_threshold -eq 200000) 'pressure read exposes the first elevated sample and compact count'
Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 250000) | Out-Null
Assert-Proactive ((Get-FileHash (Get-TestStatePath $id)).Hash -eq $hash -and [IO.File]::GetLastWriteTimeUtc((Get-TestStatePath $id)) -eq $time) 'pressure reads and repeated elevated observations do not rewrite state'
Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 199999) | Out-Null
$state = Read-TestState $id
$pressure = Read-TestPressure $id
Assert-Proactive ($state.handoff_pending -eq $false -and (Test-PressureSampleAbsent $state) -and $pressure.request_pressure -eq 'unknown' -and (Test-PressureSampleAbsent $pressure)) 'later below-threshold observation clears the elevated sample'
Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 250000) | Out-Null
Assert-Proactive ((Read-TestPressure $id).request_input_tokens -eq 250000) 'new elevated regime retains a new first sample'
Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent 'custom-threshold' 41) 42 | Out-Null
Assert-Proactive (-not [IO.File]::Exists((Get-TestStatePath 'custom-threshold'))) 'custom threshold lower boundary'
Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent 'custom-threshold' 42) 42 | Out-Null
Assert-Proactive ((Read-TestState 'custom-threshold').input_token_threshold -eq 42) 'custom threshold boundary'
$cases = @(
    @{ hook_event_name='PostModelRequest'; session_id='bad'; status='completed' },
    @{ hook_event_name='PostModelRequest'; session_id='bad'; status='completed'; token_usage=$null },
    @{ hook_event_name='PostModelRequest'; session_id='bad'; status='failed'; token_usage=@{input_tokens=999999}; error='SYNTHETIC_PRIVATE_ERROR' },
    @{ hook_event_name='PostModelRequest'; session_id='bad'; status='completed'; total_token_usage=@{input_tokens=999999} },
    @{ hook_event_name='PostModelRequest'; session_id='bad'; status='completed'; token_usage=@{inputTokens=999999} },
    (New-UsageEvent 'bad' '200000'), (New-UsageEvent 'bad' 200000.5), (New-UsageEvent 'bad' -1), (New-UsageEvent 'bad' $true),
    (New-UsageEvent '../bad' 999999), '{invalid-json'
)
$child = New-UsageEvent 'bad' 999999; $child.agent_id='synthetic-child'; $cases += $child
$child = New-UsageEvent 'bad' 999999; $child.agent_type='worker'; $cases += $child
foreach ($case in $cases) {
    $output = Invoke-Proactive 'on-model-request.ps1' $case
    Assert-Proactive ([string]::IsNullOrWhiteSpace($output) -and -not [IO.File]::Exists((Get-TestStatePath 'bad'))) 'invalid or unavailable root usage is ignored silently'
}
$stop = @{hook_event_name='Stop';session_id=$id;stop_hook_active=$true}
$beforeStop = [IO.File]::ReadAllText((Get-TestStatePath $id))
Assert-Proactive ([string]::IsNullOrWhiteSpace((Invoke-Proactive 'on-stop.ps1' $stop))) 'active compatibility Stop is silent'
$stop.stop_hook_active=$false
Assert-Proactive ([string]::IsNullOrWhiteSpace((Invoke-Proactive 'on-stop.ps1' $stop)) -and [IO.File]::ReadAllText((Get-TestStatePath $id)) -ceq $beforeStop) 'ordinary compatibility Stop is silent and does not modify pressure state'
$compact = @{hook_event_name='SessionStart'; source='compact'; session_id=$id}
Assert-Proactive ([string]::IsNullOrWhiteSpace((Invoke-Proactive 'on-compact.ps1' $compact))) 'first unprepared compact is silent even under prior elevated pressure'
$state = Read-TestState $id
$pressure = Read-TestPressure $id
Assert-Proactive ($state.handoff_pending -eq $false -and (Test-PressureSampleAbsent $state) -and $pressure.compactions -eq 1 -and $pressure.request_pressure -eq 'unknown' -and (Test-PressureSampleAbsent $pressure)) 'compact clears the elevated sample and updates the pressure count'
$notice = ConvertFrom-Json (Invoke-Proactive 'on-compact.ps1' $compact) -AsHashtable
Assert-Proactive ($notice.continue -eq $true -and $notice.hookSpecificOutput.additionalContext -and -not $notice.ContainsKey('systemMessage') -and (Read-TestState $id).handoff_pending -eq $false) 'second unprepared compact gives only a model advisory without pending state'
Assert-Proactive ([string]::IsNullOrWhiteSpace((Invoke-Proactive 'on-compact.ps1' $compact)) -and (Read-TestPressure $id).compactions -eq 3 -and (Read-TestState $id).handoff_pending -eq $false) 'later unprepared compact only advances the count'
$summary = Join-Path $TestRoot 'synthetic-proactive-summary.md'
[IO.File]::WriteAllText($summary, '# Synthetic summary')
& (Join-Path $installed 'Set-HandoffState.ps1') -SessionId $id -StateDirectory $stateRoot -Action Prepare -SummaryPath $summary | Out-Null
$reminder = ConvertFrom-Json (Invoke-Proactive 'on-compact.ps1' $compact) -AsHashtable
Assert-Proactive ($reminder.continue -eq $true -and $reminder.hookSpecificOutput.additionalContext -and $reminder.systemMessage -and (Read-TestState $id).handoff_pending -and (Read-TestState $id).summary_path -eq $summary) 'compact keeps the prepared handoff and displays its first notification'
$reminder = ConvertFrom-Json (Invoke-Proactive 'on-compact.ps1' $compact) -AsHashtable
Assert-Proactive ($reminder.continue -eq $true -and $reminder.hookSpecificOutput.additionalContext -and -not $reminder.ContainsKey('systemMessage')) 'later pending compact supplies context without repeating the UI notification'
$beforeStop = [IO.File]::ReadAllText((Get-TestStatePath $id))
Assert-Proactive ([string]::IsNullOrWhiteSpace((Invoke-Proactive 'on-stop.ps1' $stop)) -and [IO.File]::ReadAllText((Get-TestStatePath $id)) -ceq $beforeStop) 'compatibility Stop leaves a prepared handoff untouched'
foreach ($status in @('requested','prepared','creating','uncertain','created','confirmed')) {
    $testId = 'status-' + $status
    $seed = @{compactions=4;reminder_emitted=$true;protocol_version=2;handoff_pending=($status -ne 'confirmed');handoff_status=$status;custom_field='preserve'}
    if ($status -eq 'created') { $seed.new_thread_id = 'synthetic-existing-target' }
    if ($status -eq 'requested') { $seed.stop_continuation_requested = $true }
    [IO.File]::WriteAllText((Get-TestStatePath $testId), ($seed | ConvertTo-Json -Compress))
    $statePath = Get-TestStatePath $testId
    $previous = [IO.File]::ReadAllText($statePath)
    Read-TestPressure $testId | Out-Null
    Assert-Proactive ([IO.File]::ReadAllText($statePath) -ceq $previous) "read leaves existing $status state untouched"
    Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $testId 999999) | Out-Null
    $state = Read-TestState $testId
    Assert-Proactive ($state.custom_field -eq 'preserve' -and $state.handoff_status -eq $status -and $state.handoff_pending -eq ($status -notin @('requested','confirmed'))) "next write clears legacy requested pending and preserves $status lifecycle fields"
    if ($status -eq 'created') {
        $reminder = ConvertFrom-Json (Invoke-Proactive 'on-compact.ps1' @{hook_event_name='SessionStart';source='compact';session_id=$testId}) -AsHashtable
        Assert-Proactive ($reminder.continue -eq $true -and $reminder.hookSpecificOutput.additionalContext -and -not $reminder.ContainsKey('systemMessage') -and (Read-TestState $testId).new_thread_id -eq $seed.new_thread_id) 'pending created compact keeps the recorded target and gives only a notification'
    }
}
# Hold the same lock used by all scripts, proving hooks and manual state share exclusion.
$lockPath = [IO.Path]::ChangeExtension((Get-TestStatePath $id), '.lock')
$held = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $before = [IO.File]::ReadAllText((Get-TestStatePath $id))
    $lockSampleIndex = $samples.Count
    $output = Invoke-Proactive 'on-model-request.ps1' (New-UsageEvent $id 999999)
    Assert-Proactive ([string]::IsNullOrWhiteSpace($output) -and [IO.File]::ReadAllText((Get-TestStatePath $id)) -ceq $before) 'observer fails open under shared exclusive lock without state loss'
    $rejected=$false
    try { & (Join-Path $installed 'Set-HandoffState.ps1') -SessionId $id -StateDirectory $stateRoot -Action Prepare -SummaryPath $summary | Out-Null } catch { $rejected=$true }
    Assert-Proactive $rejected 'manual helper uses same lock'
} finally { $held.Dispose() }
# Existing managed controls/trust metadata survive; old hashes are never minted.
$hooksPath = Join-Path $TestHome 'hooks.json'
$seedHooks = ConvertFrom-Json ([IO.File]::ReadAllText($hooksPath)) -AsHashtable
$seedHooks.hooks.PostModelRequest[0].hooks[0].enabled = $false
$seedHooks.hooks.PostModelRequest[0].hooks[0].trusted_hash = 'synthetic-stale-managed-hash'
$legacyStopCommand = 'pwsh -NoProfile -NonInteractive -File "' + (Join-Path $installed 'on-stop.ps1') + '"'
$seedHooks.hooks.Stop[0].hooks += @{ type='command'; command=$legacyStopCommand; async=$true; statusMessage='Codex context handoff stop' }
$seedHooks.hooks.Stop += @{ hooks=@(@{ type='command'; command=$legacyStopCommand; statusMessage='Codex context handoff stop' }) }
[IO.File]::WriteAllText($hooksPath, ($seedHooks | ConvertTo-Json -Depth 100))
# An upgrade/configuration change preserves unrelated trust but never mints managed trust.
& (Join-Path $PSScriptRoot 'Install.ps1') -CodexHome $TestHome -InputTokenThreshold 12345 | Out-Null
$hooks = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $TestHome 'hooks.json'))) -AsHashtable
$managed = $hooks.hooks.PostModelRequest[0].hooks[0]
$stopHandlers = @($hooks.hooks.Stop | ForEach-Object { $_.hooks })
Assert-Proactive (@($hooks.hooks.Stop).Count -eq 1 -and $stopHandlers.Count -eq 1 -and $stopHandlers[0].command -eq 'echo SYNTHETIC_STOP') 'upgrade removes only managed Stop handlers and drops their empty groups'
Assert-Proactive ($managed.command.Contains('-InputTokenThreshold 12345') -and $managed.trusted_hash -eq 'synthetic-stale-managed-hash' -and $managed.enabled -eq $false -and $hooks.hooks.Stop[0].hooks[0].trusted_hash -eq 'synthetic-handler-trust') 'configurable installer preserves user disabled/trust fields without minting new hash'
$repeat = & (Join-Path $PSScriptRoot 'Install.ps1') -CodexHome $TestHome -InputTokenThreshold 12345
Assert-Proactive (($repeat -join '').Contains('UNCHANGED')) 'custom threshold installation idempotent'

$normalSamples = @(for ($index=0; $index -lt $samples.Count; $index++) { if ($index -ne $lockSampleIndex) { $samples[$index] } })
$script:proactiveTiming = 'Synthetic pwsh normal-event wall time ms: min=' + [math]::Round(($normalSamples | Measure-Object -Minimum).Minimum) + '; max=' + [math]::Round(($normalSamples | Measure-Object -Maximum).Maximum) + '; intentional 1s lock-timeout event ms=' + [math]::Round($samples[$lockSampleIndex]) + '; no model overhead measured.'
Write-Output ('PASS: proactive checks=' + $script:proactiveChecks + '; ' + $script:proactiveTiming)

@{ checks=$script:proactiveChecks; timing=$script:proactiveTiming } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $TestRoot 'proactive-results.json')
