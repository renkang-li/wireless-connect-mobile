param(
    [string]$PhoneIp = "",
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

function Convert-IPv4ToUInt32 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip
    )

    try {
        $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
        [array]::Reverse($bytes)
        [BitConverter]::ToUInt32($bytes, 0)
    }
    catch {
        $null
    }
}

function Convert-UInt32ToIPv4 {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$Value
    )

    $bytes = [BitConverter]::GetBytes($Value)
    [array]::Reverse($bytes)
    ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-DefaultRouteInterfaceIndexes {
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -ExpandProperty InterfaceIndex -Unique
}

function Get-ThirdOctetSubnetsFromNetwork {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip,
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength,
        [int]$MaxSubnets = 16
    )

    $singleSubnet = Get-SubnetFromIp -Ip $Ip
    if (-not $singleSubnet) {
        return @()
    }

    if ($PrefixLength -ge 24) {
        return @($singleSubnet)
    }

    if ($PrefixLength -lt 20 -or $PrefixLength -gt 30) {
        return @($singleSubnet)
    }

    $ipValue = Convert-IPv4ToUInt32 -Ip $Ip
    if ($null -eq $ipValue) {
        return @($singleSubnet)
    }

    $hostBits = 32 - $PrefixLength
    $hostMask = [uint32](([uint64]1 -shl $hostBits) - 1)
    $network = [uint32]($ipValue -band [uint32](-bnot $hostMask))
    $broadcast = [uint32]($network + $hostMask)
    if ($broadcast -le ($network + 1)) {
        return @($singleSubnet)
    }

    $startParts = (Convert-UInt32ToIPv4 -Value ([uint32]($network + 1))).Split('.')
    $endParts = (Convert-UInt32ToIPv4 -Value ([uint32]($broadcast - 1))).Split('.')
    if ($startParts.Count -ne 4 -or $endParts.Count -ne 4) {
        return @($singleSubnet)
    }

    if ($startParts[0] -ne $endParts[0] -or $startParts[1] -ne $endParts[1]) {
        return @($singleSubnet)
    }

    $startThird = [int]$startParts[2]
    $endThird = [int]$endParts[2]
    if ($endThird -lt $startThird) {
        return @($singleSubnet)
    }

    $subnetCount = $endThird - $startThird + 1
    if ($subnetCount -gt $MaxSubnets) {
        return @($singleSubnet)
    }

    $results = New-Object 'System.Collections.Generic.List[string]'
    for ($third = $startThird; $third -le $endThird; $third++) {
        $results.Add(('{0}.{1}.{2}' -f $startParts[0], $startParts[1], $third)) | Out-Null
    }

    $results
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

function Get-UsbDeviceSerials {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath
    )

    $lines = & $AdbPath devices
    foreach ($line in $lines) {
        if ($line -match '^(?<serial>\S+)\s+device(?:\s|$)') {
            $serial = $matches.serial
            if (
                $serial -notmatch '^\d{1,3}(?:\.\d{1,3}){3}:\d+$' -and
                $serial -notmatch '^emulator-\d+$'
            ) {
                $serial
            }
        }
    }
}

function Get-WifiIpFromUsbDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [string]$Serial
    )

    try {
        $routeLines = & $AdbPath -s $Serial shell ip route 2>$null
        foreach ($line in $routeLines) {
            if ($line -match '\bdev\s+wlan0\b.*\bsrc\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})\b') {
                return $matches.ip
            }
        }

        $addrLines = & $AdbPath -s $Serial shell ip -f inet addr show wlan0 2>$null
        foreach ($line in $addrLines) {
            if ($line -match '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/') {
                return $matches.ip
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Try-UsbTcpipRecovery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    foreach ($serial in (Get-UsbDeviceSerials -AdbPath $AdbPath)) {
        $ip = Get-WifiIpFromUsbDevice -AdbPath $AdbPath -Serial $serial
        if (-not $ip) {
            continue
        }

        Write-Host "检测到 USB 在线设备 $serial，当前手机 IP $ip，正在开启 adb tcpip $Port ..." -ForegroundColor DarkGray
        & $AdbPath -s $serial tcpip $Port | Out-Null
        Start-Sleep -Seconds 2

        if (Try-AdbConnectTarget -AdbPath $AdbPath -Ip $ip -Port $Port) {
            return $ip
        }
    }

    return $null
}

function Get-ActiveSubnets {
    $subnets = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $defaultRouteIndexes = @(Get-DefaultRouteInterfaceIndexes)

    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^169\.254\.' -and
            $_.IPAddress -notmatch '^127\.' -and
            (
                $defaultRouteIndexes.Count -eq 0 -or
                $defaultRouteIndexes -contains $_.InterfaceIndex
            )
        }

    foreach ($item in $addresses) {
        foreach ($subnet in (Get-ThirdOctetSubnetsFromNetwork -Ip $item.IPAddress -PrefixLength $item.PrefixLength)) {
            if ($seen.Add($subnet)) {
                $subnets.Add($subnet) | Out-Null
            }
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
        [AllowEmptyString()]
        [string]$PreferredIp,
        [Parameter(Mandatory = $true)]
        [string]$AdbPath,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $lastIp = Get-LastIp
    $connectedIps = @(Get-ConnectedTcpIps -AdbPath $AdbPath)
    $knownIps = $connectedIps + @($lastIp, $PreferredIp) |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
        Select-Object -Unique

    foreach ($ip in $knownIps) {
        if (Test-AdbDeviceReady -AdbPath $AdbPath -Ip $ip -Port $Port) {
            return $ip
        }
    }

    $usbRecoveredIp = Try-UsbTcpipRecovery -AdbPath $AdbPath -Port $Port
    if ($usbRecoveredIp) {
        return $usbRecoveredIp
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

            if (
                (Test-TcpPort -Ip $ip -Port $Port) -and
                (Try-AdbConnectTarget -AdbPath $AdbPath -Ip $ip -Port $Port)
            ) {
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
