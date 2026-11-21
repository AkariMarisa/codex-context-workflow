# CODEX_CONTEXT_WORKFLOW_V1
function Read-WorkflowHookInput([int]$MaxChars = 65536) {
    # The host sends UTF-8 JSON regardless of the Windows console code page.
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $encoding, $false)
    try {
        $buffer = [char[]]::new(8192)
        $json = [Text.StringBuilder]::new()
        $oversized = $false
        while (($count = $reader.ReadBlock($buffer, 0, $buffer.Length)) -gt 0) {
            if ($oversized -or $json.Length + $count -gt ($MaxChars + 1)) {
                # Drain the pipe without retaining more input or breaking the writer.
                $oversized = $true
                continue
            }
            [void]$json.Append($buffer, 0, $count)
        }
        if ($oversized) { return }
        $value = $json.ToString()
        if ($value.StartsWith([char]0xFEFF)) { $value = $value.Substring(1) }
        if ($value.Length -le $MaxChars) { return $value }
    } finally { $reader.Dispose() }
}

function ConvertTo-WorkflowHookJson($Result) {
    $Result | ConvertTo-Json -Compress -Depth 5 -EscapeHandling EscapeNonAscii
}

function Write-WorkflowHookJson([string]$Json) {
    # Escapes preserve Unicode across code-page hops. Emit exactly one JSON record.
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + "`n")
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}
