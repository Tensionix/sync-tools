# Add DATA trust as a fallback, retaining explicit per-host user policies.
function Update-AbkSshProfileTrust {
    param([string]$DataRoot, [string]$SshConfig, [switch]$Check)
    $known = Join-Path $DataRoot 'config\rclone\known_hosts'
    if (-not (Test-Path -LiteralPath $known -PathType Leaf)) { return 'missing-known-hosts' }
    $text = if (Test-Path -LiteralPath $SshConfig) { [IO.File]::ReadAllText($SshConfig) } else { '' }
    $pattern = '(?ms)^# >>> audion-data-trust >>>\r?\n.*?^# <<< audion-data-trust <<<(?:\r?\n)?'
    $text = [regex]::Replace($text, $pattern, '').TrimEnd()
    # Percent tokens are interpreted by ssh; quote spaces and avoid backslash escapes.
    $path = ([IO.Path]::GetFullPath($known)).Replace('\', '/').Replace('%', '%%')
    if ($path -match '["\r\n]') { throw 'Invalid DATA known_hosts path' }
    $block = "# >>> audion-data-trust >>>`r`nHost *`r`n    UserKnownHostsFile `"~/.ssh/known_hosts`" `"~/.ssh/known_hosts2`" `"$path`"`r`n# <<< audion-data-trust <<<`r`n"
    if (-not $Check) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SshConfig) -Force | Out-Null
        [IO.File]::WriteAllText($SshConfig, ($text + "`r`n`r`n" + $block), [Text.UTF8Encoding]::new($false))
    }
    return 'data-trust'
}

function Repair-AbkImportedIdentityPaths {
    param([string]$Text, [string]$SshDirectory)
    return [regex]::Replace($Text, '(?im)^(\s*IdentityFile\s+)(?:"([^"]+)"|([^\r\n#]+))(.*)$', [Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $path = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value.Trim() }
        if ($path.StartsWith('~') -or (Test-Path -LiteralPath $path)) { return $m.Value }
        $candidate = Join-Path $SshDirectory ([IO.Path]::GetFileName($path.Replace('/', '\')))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $m.Groups[1].Value + '"' + $candidate.Replace('\','/') + '"' + $m.Groups[4].Value }
        return $m.Value
    })
}

function Repair-AbkRestoreDataPaths {
    param([string]$DataRoot, [string]$SshDirectory)
    $config = Join-Path $DataRoot 'config\rclone\rclone.conf'
    if (-not (Test-Path -LiteralPath $config)) { return 'rclone.conf missing' }
    $text = [IO.File]::ReadAllText($config)
    $missing = New-Object System.Collections.Generic.List[string]
    $updated = [regex]::Replace($text, '(?im)^([ \t]*(key_file|known_hosts_file)[ \t]*=[ \t]*)([^\r\n]*)(?=\r?$)', [Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $old = $m.Groups[3].Value.Trim()
        if (-not $old -and $m.Groups[2].Value -eq 'key_file') { return $m.Value }
        $candidate = ''
        if ($m.Groups[2].Value -eq 'known_hosts_file') {
            $candidate = Join-Path $DataRoot 'config\rclone\known_hosts'
        } elseif (Test-Path -LiteralPath $old -PathType Leaf) { return $m.Value }
        else {
            $normalized = $old.Replace('/','\')
            $at = $normalized.IndexOf('\Tunnel\', [StringComparison]::OrdinalIgnoreCase)
            if ($at -ge 0) { $candidate = Join-Path $DataRoot $normalized.Substring($at + 1) }
            if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $candidate = Join-Path $SshDirectory ([IO.Path]::GetFileName($normalized))
            }
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $m.Groups[1].Value + $candidate.Replace('\','/') }
        $missing.Add($m.Groups[2].Value)
        return $m.Value
    })
    if ($missing.Count) { throw ('rclone has unresolved restore paths: ' + $missing.Count + '; no config changes written') }
    if ($updated -cne $text) { [IO.File]::WriteAllText($config, $updated, [Text.UTF8Encoding]::new($false)) }
    return 'rclone paths verified'
}
