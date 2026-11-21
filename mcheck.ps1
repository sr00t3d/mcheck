<#
.SYNOPSIS
    mcheck.ps1 — DNSBL / RBL Reputation & Custom Mail Gateway Monitor CLI (PowerShell)

.DESCRIPTION
    Audits IPv4 addresses, domains (A/MX records), local egress public IP, and
    user-managed custom SMTP mail gateways (customGateway) against 16 empirically
    verified active 2026 IPv4 DNSBLs.

    Author  : Percio Castelo (Percio Andrade) <percio@perciocastelo.com.br>
    Website : https://perciocastelo.com.br
    Project : https://perciocastelo.com.br/projetos/en/mcheck.html
    Repo    : https://github.com/sr00t3d/mcheck
    License : Apache-2.0
    Version : 2.1.0

.EXAMPLE
    .\mcheck.ps1 -Ip 1.1.1.1
    .\mcheck.ps1 -Ip 127.0.0.2 -OnlyListed -ExitCode
    .\mcheck.ps1 -MyIp -Output json
    .\mcheck.ps1 -AddGateway relay01.example.com
    .\mcheck.ps1 -CheckGateways -OnlyListed -ExitCode
#>

[CmdletBinding(PositionalBinding = $true)]
param(
    [Parameter(Position = 0)]
    [Alias('i')]
    [string]$Ip,

    [Alias('m')]
    [switch]$MyIp,

    [Alias('g', 'a', 'All')]
    [switch]$CheckGateways,

    [string]$AddGateway,
    [string]$RemoveGateway,
    [switch]$ListGateways,

    [string]$GatewaysFile,
    [string]$RblFile,
    [string]$Resolver,

    [switch]$OnlyListed,
    [switch]$ExitCode,

    [Alias('o')]
    [ValidateSet('table', 'json', 'csv')]
    [string]$Output = 'table',

    [Alias('q')]
    [switch]$Quiet,

    [switch]$NoColor,

    [Alias('V')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'mcheck.ps1'
$ScriptVersion = '2.1.0'
$TimestampUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Verified active 2026 IPv4 DNSBLs (obsolete zones like SORBS/APEWS/Manitu removed)
$DefaultRBLs = @(
    'zen.spamhaus.org',
    'cbl.abuseat.org',
    'b.barracudacentral.org',
    'bl.spamcop.net',
    'psbl.surriel.com',
    'dnsbl-1.uceprotect.net',
    'dnsbl-2.uceprotect.net',
    'dnsbl-3.uceprotect.net',
    'bl.mailspike.net',
    'z.mailspike.net',
    'ips.backscatterer.org',
    'all.s5h.net',
    'bl.0spam.org',
    'rbl.interserver.net',
    'bl.blocklist.de',
    'bl.nordspam.com'
)

if (-not $GatewaysFile) {
    if ($env:APPDATA) {
        $GatewaysFile = Join-Path (Join-Path $env:APPDATA 'mcheck') 'gateways.conf'
    } else {
        $baseCfg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $GatewaysFile = Join-Path (Join-Path $baseCfg 'mcheck') 'gateways.conf'
    }
}

$HasResolveDnsName = [bool](Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)

function Show-Help {
@"
$ScriptName v$ScriptVersion — DNSBL / RBL Reputation & Custom Mail Gateway Monitor CLI (PowerShell)

Usage:
  .\mcheck.ps1 -Ip <ip-or-domain> [options]
  .\mcheck.ps1 -MyIp [options]
  .\mcheck.ps1 -CheckGateways [-GatewaysFile <path>] [options]
  .\mcheck.ps1 -AddGateway <host-or-ip>
  .\mcheck.ps1 -RemoveGateway <host-or-ip>
  .\mcheck.ps1 -ListGateways

Actions:
  -Ip, -i <ip|domain>        Check an IPv4 address or domain (resolves A/MX records) against active DNSBLs
  -MyIp, -m                  Check the current host's public egress IPv4
  -CheckGateways, -g         Check all registered custom gateways against active DNSBLs
  -AddGateway <host|ip>      Register a custom SMTP gateway in gateways.conf
  -RemoveGateway <host|ip>   Remove a custom SMTP gateway from gateways.conf
  -ListGateways              List all registered custom gateways

Options:
  -GatewaysFile <path>       Custom gateways file (default: $GatewaysFile)
  -RblFile <path>            Custom DNSBL list file (one zone per line)
  -Resolver <ip>             Custom DNS resolver IP (Windows Resolve-DnsName)
  -OnlyListed                Show only LISTED / QUERY_BLOCKED / TIMEOUT hits in table output
  -ExitCode                  Exit with code 2 if any IP is LISTED on any DNSBL (ideal for Task Scheduler/NOC)
  -Output, -o <fmt>          Output format: table (default), json, csv
  -Quiet, -q                 Suppress banner header and summary footer
  -NoColor                   Disable colored output
  -Version, -V               Show version and exit
  -Help, -h                  Show this help and exit

Examples:
  .\mcheck.ps1 -Ip 1.1.1.1
  .\mcheck.ps1 -Ip 127.0.0.2 -OnlyListed -ExitCode
  .\mcheck.ps1 -MyIp -Output json
  .\mcheck.ps1 -AddGateway relay01.example.com
  .\mcheck.ps1 -CheckGateways -OnlyListed -ExitCode
"@ | Write-Output
}

function Test-IPv4 {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($Value.Trim(), [ref]$parsed)) {
        return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
    }
    return $false
}

function Get-ReversedIPv4 {
    param([string]$Address)
    $octets = $Address.Trim().Split('.')
    [Array]::Reverse($octets)
    return ($octets -join '.')
}

function Read-LinesFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $items = @()
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line) { $items += $line }
    }
    return $items
}

function Resolve-TargetIPv4s {
    param([string]$Target)
    $clean = $Target.Trim().TrimEnd('.')
    if (Test-IPv4 $clean) { return @($clean) }

    $found = New-Object System.Collections.Generic.List[string]
    if ($HasResolveDnsName) {
        $dnsParams = @{ Name = $clean; Type = 'A'; DnsOnly = $true; ErrorAction = 'SilentlyContinue' }
        if ($Resolver) { $dnsParams['Server'] = $Resolver }
        $recs = Resolve-DnsName @dnsParams
        foreach ($r in $recs) {
            if ($r.PSObject.Properties['IPAddress'] -and (Test-IPv4 $r.IPAddress)) {
                if (-not $found.Contains($r.IPAddress)) { $found.Add($r.IPAddress) }
            }
        }
        if ($found.Count -eq 0) {
            $mxParams = @{ Name = $clean; Type = 'MX'; DnsOnly = $true; ErrorAction = 'SilentlyContinue' }
            if ($Resolver) { $mxParams['Server'] = $Resolver }
            $mxs = Resolve-DnsName @mxParams
            foreach ($mx in $mxs) {
                if ($mx.PSObject.Properties['NameExchange'] -and $mx.NameExchange) {
                    $aParams = @{ Name = $mx.NameExchange; Type = 'A'; DnsOnly = $true; ErrorAction = 'SilentlyContinue' }
                    if ($Resolver) { $aParams['Server'] = $Resolver }
                    foreach ($a in (Resolve-DnsName @aParams)) {
                        if ($a.PSObject.Properties['IPAddress'] -and (Test-IPv4 $a.IPAddress)) {
                            if (-not $found.Contains($a.IPAddress)) { $found.Add($a.IPAddress) }
                        }
                    }
                }
            }
        }
    } else {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($clean)
            foreach ($a in $addrs) {
                if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $s = $a.IPAddressToString
                    if (-not $found.Contains($s)) { $found.Add($s) }
                }
            }
        } catch { }
    }
    return @($found | Sort-Object)
}

function Invoke-RblQuery {
    param([string]$QueryName)
    $ips = @()
    if ($HasResolveDnsName) {
        try {
            $params = @{ Name = $QueryName; Type = 'A'; DnsOnly = $true; NoHostsFile = $true; ErrorAction = 'Stop' }
            if ($Resolver) { $params['Server'] = $Resolver }
            $recs = Resolve-DnsName @params
            foreach ($r in $recs) {
                if ($r.PSObject.Properties['IPAddress'] -and (Test-IPv4 $r.IPAddress)) {
                    $ips += $r.IPAddress
                }
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'timed out|timeout') {
                return @{ State = 'TIMEOUT'; Code = '' }
            }
            return @{ State = 'CLEAN'; Code = '' }
        }
    } else {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($QueryName)
            foreach ($a in $addrs) {
                if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $ips += $a.IPAddressToString
                }
            }
        } catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                return @{ State = 'TIMEOUT'; Code = '' }
            }
            return @{ State = 'CLEAN'; Code = '' }
        } catch {
            return @{ State = 'CLEAN'; Code = '' }
        }
    }

    foreach ($ip in $ips) {
        if ($ip -like '127.255.255.*') {
            return @{ State = 'QUERY_BLOCKED'; Code = $ip }
        }
        if ($ip -like '127.*') {
            return @{ State = 'LISTED'; Code = $ip }
        }
    }
    return @{ State = 'CLEAN'; Code = '' }
}

function Get-PublicIPv4 {
    foreach ($ep in @('https://api.ipify.org', 'https://ifconfig.me')) {
        try {
            $resp = (Invoke-RestMethod -Uri $ep -TimeoutSec 6 -UseBasicParsing).ToString().Trim()
            if (Test-IPv4 $resp) { return $resp }
        } catch { }
    }
    throw 'Could not obtain public IPv4.'
}

function Write-ColorLine {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if ($NoColor -or $env:NO_COLOR -or $Output -ne 'table') {
        Write-Output $Text
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

# Handle immediate flags
if ($Help) { Show-Help; exit 0 }
if ($Version) { Write-Output "$ScriptName $ScriptVersion"; exit 0 }

if ($AddGateway) {
    $gw = $AddGateway.Trim()
    $dir = Split-Path -Parent $GatewaysFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $existing = @(Read-LinesFile $GatewaysFile)
    if ($existing -contains $gw) {
        Write-Output "[!] Gateway already registered: $gw ($GatewaysFile)"
        exit 0
    }
    Add-Content -LiteralPath $GatewaysFile -Value $gw -Encoding UTF8
    Write-Output "[OK] Added custom gateway: $gw -> $GatewaysFile"
    exit 0
}

if ($RemoveGateway) {
    $gw = $RemoveGateway.Trim()
    if (-not (Test-Path -LiteralPath $GatewaysFile)) {
        Write-Error "[ERR] Gateways file not found: $GatewaysFile"
        exit 1
    }
    $lines = @(Get-Content -LiteralPath $GatewaysFile -Encoding UTF8)
    $kept = @($lines | Where-Object { $_.Trim() -ine $gw })
    if ($kept.Count -eq $lines.Count) {
        Write-Output "[!] Gateway not found: $gw ($GatewaysFile)"
        exit 0
    }
    Set-Content -LiteralPath $GatewaysFile -Value $kept -Encoding UTF8
    Write-Output "[OK] Removed custom gateway: $gw (from $GatewaysFile)"
    exit 0
}

if ($ListGateways) {
    if (-not (Test-Path -LiteralPath $GatewaysFile)) {
        Write-Output "[!] No custom gateways registered yet ($GatewaysFile)."
        Write-Output "    Add one with: .\mcheck.ps1 -AddGateway relay01.example.com"
        exit 0
    }
    $gws = @(Read-LinesFile $GatewaysFile)
    if ($gws.Count -eq 0) {
        Write-Output "[!] Gateways file is empty ($GatewaysFile)."
        exit 0
    }
    Write-Output "Custom Gateways ($GatewaysFile):"
    for ($idx = 0; $idx -lt $gws.Count; $idx++) {
        Write-Output ("  {0,2}. {1}" -f ($idx + 1), $gws[$idx])
    }
    exit 0
}

if (-not $Ip -and -not $MyIp -and -not $CheckGateways) {
    Show-Help
    exit 1
}

# Load RBL list
$RBLs = $DefaultRBLs
if ($RblFile) {
    $loaded = @(Read-LinesFile $RblFile)
    if ($loaded.Count -eq 0) {
        Write-Error "[ERR] Failed to load RBL list from $RblFile"
        exit 1
    }
    $RBLs = $loaded
}

# Resolve targets
$Targets = @()
if ($Ip) {
    $resolved = @(Resolve-TargetIPv4s $Ip)
    if ($resolved.Count -eq 0) {
        Write-Error "[ERR] Could not resolve IPv4 for $Ip"
        exit 1
    }
    foreach ($addr in $resolved) { $Targets += @{ Label = $Ip; IP = $addr } }
} elseif ($MyIp) {
    $pub = Get-PublicIPv4
    $Targets += @{ Label = 'self'; IP = $pub }
} elseif ($CheckGateways) {
    $gws = @(Read-LinesFile $GatewaysFile)
    if ($gws.Count -eq 0) {
        Write-Error "[ERR] No custom gateways found at $GatewaysFile. Register with: .\mcheck.ps1 -AddGateway <host|ip>"
        exit 1
    }
    foreach ($gw in $gws) {
        $resolved = @(Resolve-TargetIPv4s $gw)
        if ($resolved.Count -eq 0) {
            Write-Warning "Could not resolve gateway: $gw"
            continue
        }
        foreach ($addr in $resolved) { $Targets += @{ Label = $gw; IP = $addr } }
    }
}

# Run DNSBL audit
$Results = New-Object System.Collections.Generic.List[object]
$CleanCount = 0
$ListedCount = 0
$BlockedCount = 0
$TimeoutCount = 0

foreach ($t in $Targets) {
    $rev = Get-ReversedIPv4 $t.IP
    foreach ($rbl in $RBLs) {
        $q = "$rev.$rbl"
        $res = Invoke-RblQuery $q
        switch ($res.State) {
            'CLEAN'         { $CleanCount++ }
            'LISTED'        { $ListedCount++ }
            'QUERY_BLOCKED' { $BlockedCount++ }
            'TIMEOUT'       { $TimeoutCount++ }
        }
        $Results.Add([PSCustomObject]@{
            target = $t.Label
            ip     = $t.IP
            rbl    = $rbl
            state  = $res.State
            code   = $res.Code
        })
    }
}

$TotalChecks = $Results.Count

# Render output
switch ($Output) {
    'json' {
        $payload = [PSCustomObject]@{
            tool          = $ScriptName
            version       = $ScriptVersion
            timestamp     = $TimestampUtc
            rbls_checked  = $RBLs.Count
            total_checks  = $TotalChecks
            clean         = $CleanCount
            listed        = $ListedCount
            query_blocked = $BlockedCount
            timeouts      = $TimeoutCount
            results       = $Results
        }
        $payload | ConvertTo-Json -Depth 5 | Write-Output
    }
    'csv' {
        Write-Output 'target,ip,rbl,state,return_code'
        foreach ($r in $Results) {
            if ($OnlyListed -and $r.state -eq 'CLEAN') { continue }
            $vals = @($r.target, $r.ip, $r.rbl, $r.state, $r.code) | ForEach-Object { '"' + ([string]$_ -replace '"', '""') + '"' }
            Write-Output ($vals -join ',')
        }
    }
    default {
        if (-not $Quiet) {
            Write-ColorLine ('=' * 80) ([ConsoleColor]::Cyan)
            Write-Output (" {0} v{1} | DNSBL Reputation Audit ({2} RBLs) | {3}" -f $ScriptName, $ScriptVersion, $RBLs.Count, $TimestampUtc)
            Write-ColorLine ('=' * 80) ([ConsoleColor]::Cyan)
            Write-Output ("{0,-22} {1,-15} {2,-26} {3,-14} {4}" -f 'TARGET', 'IP', 'DNSBL', 'STATE', 'CODE')
            Write-Output ("{0,-22} {1,-15} {2,-26} {3,-14} {4}" -f ('-' * 22), ('-' * 15), ('-' * 26), ('-' * 14), ('-' * 15))
        }
        foreach ($r in $Results) {
            if ($OnlyListed -and $r.state -eq 'CLEAN') { continue }
            $codeDisp = if ($r.code) { $r.code } else { '-' }
            $line = "{0,-22} {1,-15} {2,-26} {3,-14} {4}" -f $r.target, $r.ip, $r.rbl, $r.state, $codeDisp
            $col = switch ($r.state) {
                'CLEAN'         { [ConsoleColor]::Green }
                'LISTED'        { [ConsoleColor]::Red }
                'QUERY_BLOCKED' { [ConsoleColor]::Yellow }
                'TIMEOUT'       { [ConsoleColor]::Yellow }
                default         { [ConsoleColor]::Gray }
            }
            Write-ColorLine $line $col
        }
        if (-not $Quiet) {
            Write-Output ''
            Write-Output ("Summary: {0} checks | {1} CLEAN | {2} LISTED | {3} QUERY_BLOCKED | {4} TIMEOUT" -f $TotalChecks, $CleanCount, $ListedCount, $BlockedCount, $TimeoutCount)
        }
    }
}

if ($ExitCode -and $ListedCount -gt 0) {
    exit 2
}
exit 0
