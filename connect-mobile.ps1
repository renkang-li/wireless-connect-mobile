param(
    [string]$PhoneIp = "192.168.47.110",
    [int]$Port = 5555
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $ScriptRoot "connect-mobile.last-ip.txt"

function Find-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "找不到命令: $Name"
    }

    $command.Source
}

function Get-LastIp {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }

    $value = Get-Content -LiteralPath $StateFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $value) {
        return $null
    }

    $value.Trim()
}

function Save-LastIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip
    )

    Set-Content -LiteralPath $StateFile -Value $Ip -Encoding utf8
}

function Add-CandidateIp {
    param(
        [System.Collections.Generic.List[string]]$List,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [string]$Ip
    )

    if (-not $List -or -not $Seen -or [string]::IsNullOrWhiteSpace($Ip)) {
        return
    }

    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        return
    }

    if ($Seen.Add($Ip)) {
        $List.Add($Ip) | Out-Null
    }
}

function Get-ConnectedTcpIps {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath
    )

    $lines = & $AdbPath devices
    foreach ($line in $lines) {
        if ($line -match '^(?<ip>\d{1,3}(?:\.\d{1,3}){3}):\d+\s+device$') {
            $matches.ip
        }
    }
}

function Get-ActiveSubnets {
    $subnets = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^169\.254\.' -and
            $_.IPAddress -notmatch '^127\.' -and
            $_.PrefixLength -ge 24
        }

    foreach ($item in $addresses) {
        $parts = $item.IPAddress.Split('.')
        if ($parts.Count -ne 4) {
            continue
        }

        $subnet = '{0}.{1}.{2}' -f $parts[0], $parts[1], $parts[2]
        if ($seen.Add($subnet)) {
            $subnets.Add($subnet) | Out-Null
        }
    }

    $subnets
}

function Get-ArpIps {
    param(
        [string[]]$Subnets
    )

    $results = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $Subnets -or $Subnets.Count -eq 0) {
        return $results
    }

    $lines = arp -a

    foreach ($line in $lines) {
        foreach ($subnet in $Subnets) {
            $pattern = '^\s*{0}\.(?<host>\d{{1,3}})\s+' -f [regex]::Escape($subnet)
            if ($line -match $pattern) {
                $ip = '{0}.{1}' -f $subnet, $matches.host
                if ($seen.Add($ip)) {
                    $results.Add($ip) | Out-Null
                }
            }
        }
    }

    $results
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [int]$TimeoutMs = 180
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($async -and $async.AsyncWaitHandle) {
            $async.AsyncWaitHandle.Close()
        }
        $client.Close()
    }
}

function Test-AdbDeviceReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [string]$Ip,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $target = '{0}:{1}' -f $Ip, $Port
    $pattern = '^{0}\s+device$' -f [regex]::Escape($target)
    $lines = & $AdbPath devices
    [bool]($lines | Where-Object { $_ -match $pattern })
}

function Try-AdbConnectTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [string]$Ip,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        return $false
    }

    $target = '{0}:{1}' -f $Ip, $Port
    & $AdbPath connect $target | Out-Null
    Start-Sleep -Milliseconds 300
    Test-AdbDeviceReady -AdbPath $AdbPath -Ip $Ip -Port $Port
}

function Get-SubnetFromIp {
    param(
        [string]$Ip
    )

    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        return $null
    }

    $parts = $Ip.Split('.')
    if ($parts.Count -ne 4) {
        return $null
    }

    '{0}.{1}.{2}' -f $parts[0], $parts[1], $parts[2]
}

function Find-ReachablePhoneIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferredIp,
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $lastIp = Get-LastIp
    $connectedIps = @(Get-ConnectedTcpIps -AdbPath $AdbPath)
    $knownIps = @($PreferredIp, $lastIp) + $connectedIps |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
        Select-Object -Unique

    foreach ($ip in $knownIps) {
        if (Test-AdbDeviceReady -AdbPath $AdbPath -Ip $ip -Port $Port) {
            return $ip
        }
    }

    foreach ($ip in $knownIps) {
        if (Try-AdbConnectTarget -AdbPath $AdbPath -Ip $ip -Port $Port) {
            return $ip
        }
    }

    $subnets = @(Get-ActiveSubnets) + @(
        Get-SubnetFromIp -Ip $PreferredIp
        Get-SubnetFromIp -Ip $lastIp
    ) |
        Where-Object { $_ } |
        Select-Object -Unique

    foreach ($ip in (Get-ArpIps -Subnets $subnets | Select-Object -Unique)) {
        if (Try-AdbConnectTarget -AdbPath $AdbPath -Ip $ip -Port $Port) {
            return $ip
        }
    }

    foreach ($subnet in $subnets) {
        Write-Host "正在扫描网段 $subnet.0/24 ..." -ForegroundColor DarkGray
        for ($octet = 1; $octet -le 254; $octet++) {
            $ip = '{0}.{1}' -f $subnet, $octet
            if ($knownIps -contains $ip) {
                continue
            }

            if (Test-TcpPort -Ip $ip -Port $Port) {
                return $ip
            }
        }
    }

    return $null
}

try {
    $adb = Find-RequiredCommand -Name "adb"
    $scrcpy = Find-RequiredCommand -Name "scrcpy"
    $resolvedIp = Find-ReachablePhoneIp -PreferredIp $PhoneIp -AdbPath $adb -Port $Port
    if (-not $resolvedIp) {
        throw "没找到开启 adb tcpip 的手机。先确认手机和电脑在同一个 Wi-Fi，下次如果手机重启了，需要重新插 USB 执行一次 adb tcpip 5555。"
    }

    $target = '{0}:{1}' -f $resolvedIp, $Port
    $targetPattern = '^{0}\s+device$' -f [regex]::Escape($target)

    Write-Host "正在连接手机 $target ..." -ForegroundColor Cyan
    $connectOutput = & $adb connect $target 2>&1
    foreach ($line in $connectOutput) {
        Write-Host $line
    }

    Start-Sleep -Seconds 1

    $deviceLines = & $adb devices
    $isReady = $deviceLines | Where-Object { $_ -match $targetPattern }

    if (-not $isReady) {
        Write-Host ""
        Write-Host "没有看到可用设备 $target。" -ForegroundColor Yellow
        Write-Host "如果手机刚重启，通常需要重新插 USB 执行一次 adb tcpip 5555。" -ForegroundColor Yellow
        Read-Host "按回车退出"
        exit 1
    }

    Write-Host ""
    Write-Host "连接成功，正在启动 scrcpy ..." -ForegroundColor Green
    Save-LastIp -Ip $resolvedIp
    & $scrcpy -s $target
}
catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}
