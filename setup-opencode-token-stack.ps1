#Requires -Version 5.1
<#
.SYNOPSIS
    Wire token-optimization tooling into OpenCode for personal vibe coding.

.DESCRIPTION
    Default stack (the three worth having):

    Tool          Repo / package                              Stars   Surface
    ------------  -----------------------------------------  ------  --------------------
    crg           tirth8205/code-review-graph                  31898  MCP  serve --auto-watch
    headroom      headroomlabs-ai/headroom (pkg: headroom-ai) 74313  MCP  headroom mcp serve
    repomix       yamadashy/repomix                            28659  MCP  repomix --mcp

    Two of the five >1k-star repos are deliberately left out:

      graphify        DROPPED - crg already is a tree-sitter code graph and stays
                       fresh incrementally, instead of needing `graphify extract .`
                       re-run by hand. graphify's headline 71.5x number comes from a
                       52-file demo corpus, not from a real codebase.
      token-optimizer DROPPED - its own docs list the compression features as NOT
                       ported to OpenCode (bash output compression needs a tool-input
                       mutation hook OpenCode does not expose), so on this platform it
                       is a strict subset of headroom. Also PolyForm-Noncommercial.

    Both remain available: -Include graphify,token-opt

    Installs each Python tool into its own isolated venv and repomix into a local
    npm prefix, then merges the entries into the GLOBAL OpenCode config
    (~/.config/opencode/opencode.jsonc) after backing it up.

    Deliberately does NOT shell out to `code-review-graph install`: that writes a
    project-scoped opencode.jsonc into the current directory, pins an absolute
    python path, and prompts interactively. This script writes the global config.

.PARAMETER Include
    Tool keys to configure: crg, headroom, repomix, graphify, token-opt.
    Defaults to the first three.

.PARAMETER SkipInstall
    Only write the OpenCode config; install nothing.

.PARAMETER DryRun
    Report what would happen and change nothing.

.EXAMPLE
    .\setup-opencode-token-stack.ps1

.EXAMPLE
    .\setup-opencode-token-stack.ps1 -Include crg,headroom

.EXAMPLE
    powershell -ExecutionPolicy Bypass -Command "& '.\setup-opencode-token-stack.ps1' -DryRun"

.NOTES
    Call it with .\ or with -Command. `powershell -File` does not split
    comma-separated values for array parameters.
#>
[CmdletBinding()]
param(
    [ValidateSet('crg', 'headroom', 'repomix', 'graphify', 'token-opt')]
    [string[]] $Include = @('crg', 'headroom', 'repomix'),

    [string] $StackRoot = (Join-Path $env:USERPROFILE '.config\opencode\token-stack'),

    [switch] $SkipInstall,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$ConfigDir    = Join-Path $env:USERPROFILE '.config\opencode'
$ConfigFile   = Join-Path $ConfigDir 'opencode.jsonc'
$VenvRoot     = Join-Path $StackRoot 'venvs'
$NodePrefix   = Join-Path $StackRoot 'node'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "    --  $m" -ForegroundColor DarkGray }
function Write-Bad  { param([string]$m) Write-Host "    !!  $m" -ForegroundColor Red }

function Invoke-Native {
    param([string]$Exe, [string[]]$NativeArgs, [string]$Label)
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @NativeArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$Label failed (exit $code)`n$(($out | ForEach-Object { "$_" }) -join "`n")"
    }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Remove-JsoncComments {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    $inString = $false; $escaped = $false; $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped)        { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            $i++
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq '/' -and ($i + 1) -lt $Text.Length) {
            $next = $Text[$i + 1]
            if ($next -eq '/') {
                while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while ($i -lt $Text.Length -and -not ($Text[$i] -eq '*' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }
        [void]$sb.Append($ch); $i++
    }
    return $sb.ToString()
}

function Read-OpenCodeConfig {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        return [pscustomobject]([ordered]@{ '$schema' = 'https://opencode.ai/config.json' })
    }
    $raw = Get-Content -LiteralPath $ConfigFile -Raw
    $clean = Remove-JsoncComments $raw
    try   { return $clean | ConvertFrom-Json }
    catch {
        $clean = [regex]::Replace($clean, ',(\s*[}\]])', '$1')
        try   { return $clean | ConvertFrom-Json }
        catch { throw "Cannot parse $ConfigFile as JSON/JSONC. Fix it manually, or start opencode with OPENCODE_CONFIG pointing at a valid file. Original error: $($_.Exception.Message)" }
    }
}

function Set-OpenCodeProp {
    param($Target, [string]$Name, $Value)
    if ($Target.PSObject.Properties.Name -contains $Name) { $Target.$Name = $Value }
    else { $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-PythonCommand {
    foreach ($cand in @('python', 'python3', 'py')) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if (-not $c) { continue }
        $ver = (& $c.Source --version 2>&1) -join ''
        if ($ver -match '(\d+)\.(\d+)') {
            if ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10)) {
                return $c.Source
            }
        }
    }
    throw 'No Python >= 3.10 found on PATH. graphify, headroom and code-review-graph all require it.'
}

function Get-NodeCommand {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if (-not $c) { throw 'node not found on PATH. repomix requires it.' }
    return $c.Source
}

function Install-PythonTool {
    param(
        [string]$Key, [string]$VenvDir, [string]$Requirement,
        [string]$EntryPoint, [string[]]$VersionArgs = @('--version')
    )
    $python = Get-PythonCommand
    $venvPy = Join-Path $VenvDir 'Scripts\python.exe'

    if (-not (Test-Path -LiteralPath $venvPy)) {
        Write-Note "creating venv: $VenvDir"
        Invoke-Native $python @('-m', 'venv', $VenvDir) "python -m venv ($Key)" | Out-Null
    }
    Write-Note "pip install $Requirement"
    Invoke-Native $venvPy @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip') "pip upgrade ($Key)" | Out-Null
    Invoke-Native $venvPy @('-m', 'pip', 'install', '--quiet', $Requirement) "pip install $Requirement ($Key)" | Out-Null

    $exe = Join-Path $VenvDir "Scripts\$EntryPoint"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "$Key installed but '$EntryPoint.exe' is missing from $VenvDir\Scripts."
    }
    try   { Invoke-Native $exe $VersionArgs "$EntryPoint probe" | Out-Null; $state = 'installed, entry point launches' }
    catch { $state = 'installed (entry point did not answer a probe)' }
    Write-Ok "$Key  $state"
    return $exe
}

$specs = [ordered]@{}

$specs['graphify'] = @{
    Kind = 'python'; Venv = (Join-Path $VenvRoot 'graphify')
    Requirement = 'graphifyy[mcp]'; EntryPoint = 'graphify-mcp.exe'
    VersionArgs = @('--help'); McpArgs = @('graphify-out\graph.json')
}
$specs['headroom'] = @{
    Kind = 'python'; Venv = (Join-Path $VenvRoot 'headroom')
    Requirement = 'headroom-ai[mcp,proxy]'; EntryPoint = 'headroom.exe'
    McpArgs = @('mcp', 'serve')
}
$specs['crg'] = @{
    Kind = 'python'; Venv = (Join-Path $VenvRoot 'code-review-graph')
    Requirement = 'code-review-graph'; EntryPoint = 'code-review-graph.exe'
    McpKey = 'code-review-graph'; McpArgs = @('serve', '--auto-watch')
}
$specs['repomix'] = @{ Kind = 'node'; McpArgs = @('--mcp') }
$specs['token-opt'] = @{ Kind = 'plugin'; NpmPkg = 'token-optimizer-opencode' }

if (-not (Test-Path -LiteralPath $ConfigDir)) {
    throw "OpenCode config dir not found: $ConfigDir"
}

Write-Step "OpenCode token stack"
Write-Note "config  : $ConfigFile"
Write-Note "stack   : $StackRoot"
Write-Note "tools   : $($Include -join ', ')"

if ($DryRun) { Write-Step 'Dry run: no packages installed, config untouched.' }

$mcpEntries = [ordered]@{}
$pluginSpecs = New-Object System.Collections.Generic.List[string]

foreach ($key in $Include) {
    $spec = $specs[$key]
    Write-Step "[$key]"

    switch ($spec.Kind) {

        'python' {
            $exe = $null
            if (-not $DryRun -and -not $SkipInstall) {
                $exe = Install-PythonTool -Key $key -VenvDir $spec.Venv -Requirement $spec.Requirement -EntryPoint $spec.EntryPoint -VersionArgs $spec.VersionArgs
            }
            elseif (Test-Path -LiteralPath (Join-Path $spec.Venv "Scripts\$($spec.EntryPoint)")) {
                $exe = Join-Path $spec.Venv "Scripts\$($spec.EntryPoint)"
                Write-Note 'existing venv found (SkipInstall)'
            }
            if ($exe) {
                $mcpKey = if ($spec.McpKey) { $spec.McpKey } else { $key }
                $mcpEntries[$mcpKey] = [ordered]@{
                    type = 'local'; command = @($exe) + $spec.McpArgs; enabled = $true
                }
                Write-Ok "mcp.$mcpKey -> $((@($exe) + $spec.McpArgs) -join ' ')"
            }
            else {
                Write-Note "would install $($spec.Requirement) into $($spec.Venv), then register mcp.$(if ($spec.McpKey) { $spec.McpKey } else { $key })"
            }
        }

        'node' {
            $node = Get-NodeCommand
            $bin  = Join-Path $NodePrefix 'node_modules\repomix\bin\repomix.cjs'
            if (-not $DryRun -and -not $SkipInstall) {
                if (-not (Test-Path -LiteralPath $NodePrefix)) {
                    New-Item -ItemType Directory -Force -Path $NodePrefix | Out-Null
                }
                Write-Note 'npm install --prefix <stack> repomix'
                Invoke-Native 'npm' @('install', '--prefix', $NodePrefix, '--no-fund', '--no-audit', 'repomix') 'npm install repomix' | Out-Null
            }
            if (-not (Test-Path -LiteralPath $bin)) {
                Write-Bad 'repomix CLI entry not found; falling back to npx (slower cold start).'
                $mcpEntries[$key] = [ordered]@{
                    type = 'local'; command = @('npx', '-y', 'repomix', '--mcp'); enabled = $true
                }
            }
            else {
                $mcpEntries[$key] = [ordered]@{
                    type = 'local'; command = @($node, $bin) + $spec.McpArgs; enabled = $true
                }
            }
            Write-Ok "mcp.$key -> repomix --mcp"
        }

        'plugin' {
            if (-not $DryRun -and -not $SkipInstall) {
                Write-Note "npm install --prefix <configdir> $($spec.NpmPkg)"
                Invoke-Native 'npm' @('install', '--prefix', $ConfigDir, '--no-fund', '--no-audit', $spec.NpmPkg) "npm install $($spec.NpmPkg)" | Out-Null
            }
            $pluginSpecs.Add($spec.NpmPkg)
            Write-Ok "plugin -> $($spec.NpmPkg)"
        }
    }
}

Write-Step 'Merging OpenCode config'

$cfg = Read-OpenCodeConfig
Set-OpenCodeProp $cfg '$schema' 'https://opencode.ai/config.json'

if ($mcpEntries.Count -gt 0) {
    if (-not ($cfg.PSObject.Properties.Name -contains 'mcp')) {
        Set-OpenCodeProp $cfg 'mcp' ([pscustomobject]@{})
    }
    foreach ($name in $mcpEntries.Keys) {
        Set-OpenCodeProp $cfg.mcp $name $mcpEntries[$name]
    }
}

if ($pluginSpecs.Count -gt 0) {
    $existing = @()
    if ($cfg.PSObject.Properties.Name -contains 'plugin') {
        $existing = @($cfg.plugin | ForEach-Object {
            if ($_ -is [string]) { $_ } else { $_ -join '' }
        })
    }
    foreach ($p in $pluginSpecs) {
        if ($existing -notcontains $p) { $existing += $p }
    }
    Set-OpenCodeProp $cfg 'plugin' $existing
}

$json = ($cfg | ConvertTo-Json -Depth 30)

try { $null = $json | ConvertFrom-Json } catch { throw "Generated config is not valid JSON: $($_.Exception.Message)" }

if ($DryRun) {
    Write-Step 'Dry run: config that would be written'
    Write-Host $json
    return
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$ConfigFile.bak-$stamp"
Copy-Item -LiteralPath $ConfigFile -Destination $backup -ErrorAction SilentlyContinue

[System.IO.File]::WriteAllText($ConfigFile, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "wrote $ConfigFile"
if (Test-Path -LiteralPath $backup) { Write-Note "backup  : $backup" }

Write-Step 'Summary'
Write-Host "    MCP servers : $(if ($mcpEntries.Count) { $mcpEntries.Keys -join ', ' } else { '(none)' })"
Write-Host "    Plugins     : $(if ($pluginSpecs.Count) { $pluginSpecs -join ', ' } else { '(none)' })"
Write-Host "    Config      : $ConfigFile"

Write-Step 'Rationale for the stack'
Write-Note 'crg over graphify : crg updates incrementally per SHA-256, so the graph cannot go stale while you code. Its ~65x median is measured on 6 real repos with pinned SHAs; graphify 71.5x is a 52-file demo corpus.'
Write-Note 'headroom over token-optimizer : headroom is Apache-2.0 and its live-zone compression leaves the KV-cache prefix byte-identical. token-optimizer cannot do its compression on OpenCode (no tool-input mutation hook).'
Write-Note 'repomix is on-demand, not always-on, so it does not conflict with crg. Use it to pack a repo you are not working in, or a remote one.'

Write-Step 'Next steps'
if ($mcpEntries.Keys -contains 'code-review-graph') {
    Write-Host '    1. In each project you code in:  code-review-graph build' -ForegroundColor Yellow
    Write-Host '       (the global mcp entry serves the graph for the opencode cwd)' -ForegroundColor DarkGray
}
if ($mcpEntries.Keys -contains 'graphify') {
    Write-Host '    1b. Per project:  graphify extract .   (produces graphify-out\graph.json)' -ForegroundColor Yellow
}
Write-Host '    2. Restart OpenCode (quit and relaunch) - config is not hot-reloaded.' -ForegroundColor Yellow
Write-Host '    3. Verify:  /mcp  to list connected servers.' -ForegroundColor Yellow
Write-Note 'Optional, per project: `code-review-graph install --platform opencode` adds an OpenCode plugin, file hooks and AGENTS.md injection. Skip it if you rely on the global mcp entry + --auto-watch, it writes a project-scoped opencode.jsonc.'
