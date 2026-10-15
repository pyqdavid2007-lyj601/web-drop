# web-drop 控制台：后端 / Cloudflare 隧道 / ngrok 隧道 / .env，一个窗口管完。
#
#   pwsh scripts/Control.ps1                      打开菜单（等于双击 start-control.vbs）
#   pwsh scripts/Control.ps1 -Action backend      不开菜单，只起本机后端（Ctrl+C 停止）
#   pwsh scripts/Control.ps1 -Action lan          局域网后端（0.0.0.0，手机同 Wi-Fi 直连）
#   pwsh scripts/Control.ps1 -Action cloudflare   Cloudflare Quick Tunnel（顺带起本机后端）
#   pwsh scripts/Control.ps1 -Action ngrok        ngrok 隧道
#   pwsh scripts/Control.ps1 -Port 8131           临时换端口（只影响这次，不写回 .env）
#
# 端口 / 上传上限 / 分片大小 / ngrok 域名都来自 repo/.env（菜单 5 可改）；端口优先级
# -Port > WEBDROP_PORT > 8130。子进程都在 kill-on-close 的 job object 里，Ctrl+C / 退出 /
# 关窗都能清场；venv 的 python.exe 是 shim（会再拉隐藏子进程），停后端起除了 PID 还要按
# 端口找监听者。应用没有鉴权：隧道链接给谁，谁就能上传 / 下载 / 删除。

param(
  [int]$Port = 0,
  [ValidateSet('menu', 'backend', 'lan', 'cloudflare', 'ngrok')]
  [string]$Action = 'menu'
)

$ErrorActionPreference = 'Stop'

# 被 dot-source（. .\Control.ps1）时只加载函数、不跑菜单，方便单独测 .env 读写。
$script:LibOnly = ($MyInvocation.InvocationName -eq '.')

$script:RepoRoot   = Split-Path -Parent $PSScriptRoot
$script:BackendDir = Join-Path $script:RepoRoot 'backend'
$script:Python     = Join-Path $script:RepoRoot '..\.pyvenv\Scripts\python.exe'
$script:EnvPath    = Join-Path $script:RepoRoot '.env'
$script:FormatPath = Join-Path $PSScriptRoot 'Control.Format.ps1xml'
$script:PortArg    = $Port
$script:NoClear    = ($Action -ne 'menu')
$script:LanAddress = $false

$script:TempDir = [System.IO.Path]::GetTempPath()
$script:LogFile = @{
  backend       = (Join-Path $script:TempDir 'webdrop-backend.log')
  backendErr    = (Join-Path $script:TempDir 'webdrop-backend.log.err')
  cloudflare    = (Join-Path $script:TempDir 'webdrop-cloudflared.log')
  cloudflareErr = (Join-Path $script:TempDir 'webdrop-cloudflared.log.err')
  ngrok         = (Join-Path $script:TempDir 'webdrop-ngrok.log')
  ngrokErr      = (Join-Path $script:TempDir 'webdrop-ngrok.log.err')
}

$script:Services = @{
  Backend = @{ Process = $null; Mode = '' }
  Tunnel  = @{ Process = $null; AgentPid = 0; Kind = ''; Url = ''; Health = '' }
}

$script:Job = [IntPtr]::Zero
$script:ExitCode = 0

# --- 输出 ---------------------------------------------------------------
function Write-WebDropDim  { param([string]$Text) Write-Host $Text -ForegroundColor DarkGray }
function Write-WebDropInfo { param([string]$Text) Write-Host $Text }
function Write-WebDropGood { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-WebDropWarn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-WebDropBad  { param([string]$Text) Write-Host $Text -ForegroundColor Red }

function Write-WebDropTitle {
  param([string]$Text)
  Write-Host ''
  Write-Host ('== ' + $Text + ' ' + ('=' * 58)) -ForegroundColor Cyan
}

function Wait-WebDropEnter {
  Write-Host ''
  [void](Read-Host '按回车继续')
}

function Write-WebDropLogTail {
  param([string]$Path, [int]$Lines = 30)

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-WebDropDim ('  （没有日志文件: ' + $Path + '）')
    return
  }
  $tail = @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue)
  if ($tail.Count -eq 0) {
    Write-WebDropDim ('  （日志是空的: ' + $Path + '）')
    return
  }
  Write-WebDropDim ('  --- ' + $Path + ' 最后 ' + $Lines + ' 行 ---')
  foreach ($line in $tail) { Write-Host ('  ' + $line) }
}

# --- 子进程看守（job object）-------------------------------------------
function Register-WebDropChild {
  param([int]$ProcessId)

  if ($script:Job -eq [IntPtr]::Zero) {
    if (-not ('JobKiller' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class JobKiller
{
    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    public static IntPtr CreateKillOnCloseJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        int size = Marshal.SizeOf(info);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, buffer, false);
            SetInformationJobObject(job, 9, buffer, (uint)size); // JobObjectExtendedLimitInformation
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
        return job;
    }

    public static string Add(IntPtr job, int pid)
    {
        try
        {
            var process = Process.GetProcessById(pid);
            return AssignProcessToJobObject(job, process.Handle) ? null : "AssignProcessToJobObject failed";
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}
'@
    }
    $script:Job = [JobKiller]::CreateKillOnCloseJob()
  }

  $problem = [JobKiller]::Add($script:Job, $ProcessId)
  if ($problem) { Write-WebDropWarn ('  job 绑定失败: ' + $problem + '（关窗 / 强杀时它可能残留，建议用 Ctrl+C 或菜单「0) 退出」）') }
}

# --- repo/.env ----------------------------------------------------------
# 解析规则同 backend/webdrop/settings.py 的 _load_dotenv：KEY=VALUE，# 整行或跟在值后都算注释，值可带引号。

$script:SettingSpec = @(
  [pscustomobject]@{ Key = 'MAX_UPLOAD_FILE_SIZE_MB'; Default = '1024'; Kind = 'int';    Min = 1;    Max = 0;     Values = @();       Rule = '整数，最小 1';       Note = '单个文件上限(MB)，超了返回 413' }
  [pscustomobject]@{ Key = 'UPLOAD_CHUNK_SIZE_MB';    Default = '8';    Kind = 'int';    Min = 1;    Max = 100;   Values = @();       Rule = '整数 1 - 100';       Note = '分片大小(MB)；隧道单请求体上限 100 MB' }
  [pscustomobject]@{ Key = 'WEBDROP_ALLOW_ANY_HOST';  Default = '0';    Kind = 'enum';   Min = 0;    Max = 0;     Values = @('0', '1'); Rule = '0 或 1';          Note = '1 = 接受任意 Host（局域网模式自动开）' }
  [pscustomobject]@{ Key = 'WEBDROP_PORT';            Default = '8130'; Kind = 'int';    Min = 1024; Max = 65535; Values = @();       Rule = '整数 1024 - 65535'; Note = '后端端口；控制台与两条隧道都按它来' }
  [pscustomobject]@{ Key = 'NGROK_STATIC_DOMAIN';     Default = '';     Kind = 'domain'; Min = 0;    Max = 0;     Values = @();       Rule = '域名，或留空';       Note = 'ngrok 固定域名；留空 = 每次随机' }
)

function Get-WebDropEnvTemplate {
  # 和仓库里的 repo/.env 内容一致：.env 被误删时用它重建。
  return @'
# web-drop 配置：只有下面几项可调，没有密钥；改完重启后端生效。
# 一行一个 KEY=VALUE，# 整行或跟在值后都算注释；系统环境变量优先。
# 菜单 5（或双击 start-control.vbs）可以直接改这里的值。

MAX_UPLOAD_FILE_SIZE_MB=1024   # 单文件上限 MB，超了返回 413
UPLOAD_CHUNK_SIZE_MB=8         # 分片大小 MB，别超 100（Cloudflare 单请求体上限）
WEBDROP_ALLOW_ANY_HOST=0       # 1 = ALLOWED_HOSTS ['*']，局域网直连用
WEBDROP_PORT=8130              # 后端端口，控制台与两条隧道都按它来
NGROK_STATIC_DOMAIN=           # ngrok 固定域名，留空 = 每次随机
'@
}

function Get-WebDropEnvMap {
  param([string]$Path = $script:EnvPath)

  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }

  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $text = $line.Trim()
    if ($text -eq '' -or $text.StartsWith('#') -or -not $text.Contains('=')) { continue }
    $parts = $text -split '=', 2
    $key = $parts[0].Trim()
    $value = $parts[1]
    $cut = [regex]::Match($value, '\s+#')
    if ($cut.Success) { $value = $value.Substring(0, $cut.Index) }
    $value = $value.Trim().Trim('"').Trim("'")
    if ($key -ne '') { $map[$key] = $value }
  }

  return $map
}

function Get-WebDropSetting {
  param([string]$Key)
  foreach ($spec in $script:SettingSpec) { if ($spec.Key -eq $Key) { return $spec } }
  return $null
}

function Get-WebDropSettingValue {
  param([string]$Key)

  $map = Get-WebDropEnvMap
  if ($map.Contains($Key)) { return [string]$map[$Key] }
  $spec = Get-WebDropSetting $Key
  if ($spec) { return [string]$spec.Default }
  return ''
}

function Test-WebDropSettingValue {
  param($Spec, [string]$Value)

  if ($Spec.Kind -eq 'int') {
    $number = 0L
    if (-not [long]::TryParse($Value, [ref]$number)) { return '必须是整数' }
    if ($number -lt [long]$Spec.Min) { return ('不能小于 ' + $Spec.Min) }
    if ($Spec.Max -gt 0 -and $number -gt [long]$Spec.Max) { return ('不能大于 ' + $Spec.Max) }
    return ''
  }
  if ($Spec.Kind -eq 'enum') {
    if ($Spec.Values -notcontains $Value) { return ('只能是 ' + ($Spec.Values -join ' / ')) }
    return ''
  }
  if ($Spec.Kind -eq 'domain') {
    if ($Value -eq '') { return '' }
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { return '只能填域名（字母 / 数字 / 点 / 横线），或者留空' }
    return ''
  }
  return ''
}

function Set-WebDropEnvValue {
  param(
    [string]$Key,
    [string]$Value,
    [string]$Path = $script:EnvPath
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    [System.IO.File]::WriteAllText($Path, (Get-WebDropEnvTemplate), (New-Object System.Text.UTF8Encoding($false)))
  }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) { [void]$lines.Add($line) }

  # 只动目标那一行：注释、其它键、顺序都原样保留。
  $found = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $head = ($lines[$i] -split '=', 2)[0].Trim().TrimStart([char]0xFEFF)
    if ($head -eq $Key) { $found = $i; break }
  }

  if ($Value -eq '') {
    if ($found -ge 0) { $lines.RemoveAt($found) }
  }
  elseif ($found -ge 0) {
    $line = $lines[$found]
    $prefix = ($line -split '=', 2)[0]
    $rest = $line.Substring($prefix.Length + 1)
    $comment = ''
    $cut = [regex]::Match($rest, '\s+#')
    if ($cut.Success) { $comment = $rest.Substring($cut.Index) }
    $lines[$found] = $prefix.TrimEnd() + '=' + $Value + $comment
  }
  else {
    [void]$lines.Add('')
    [void]$lines.Add($Key + '=' + $Value)
  }

  $newline = [string][char]10
  $crlf = [string][char]13 + [string][char]10
  $text = [string]::Join($newline, $lines.ToArray())
  $text = ($text.Replace($crlf, $newline)) + $newline
  [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- 端口 / 进程 --------------------------------------------------------
function Get-WebDropPort {
  if ($script:PortArg -gt 0) { return $script:PortArg }
  $raw = Get-WebDropSettingValue 'WEBDROP_PORT'
  $number = 0L
  if ([long]::TryParse($raw, [ref]$number) -and $number -ge 1 -and $number -le 65535) { return [int]$number }
  return 8130
}

function Test-LocalPort {
  param([int]$Port)
  $client = New-Object System.Net.Sockets.TcpClient
  try { $client.Connect('127.0.0.1', $Port); return $true }
  catch { return $false }
  finally { $client.Dispose() }
}

function Get-PortOwnerPids {
  param([int]$Port)

  $pids = @()
  try {
    foreach ($owner in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
      $pids += [int]$owner.OwningProcess
    }
  }
  catch { }

  if ($pids.Count -eq 0) {
    foreach ($line in @(& netstat -ano -p tcp)) {
      $fields = @(($line.Trim()) -split ' ' | Where-Object { $_ -ne '' })
      if ($fields.Count -lt 5) { continue }
      if ($fields[3] -ne 'LISTENING') { continue }
      if (-not $fields[1].EndsWith(':' + $Port)) { continue }
      $pids += [int]$fields[4]
    }
  }

  return @($pids | Sort-Object -Unique)
}

function Test-IsRunserverProcess {
  param([int]$ProcessId)
  try {
    $info = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop
    if (-not $info) { return $false }
    $commandLine = [string]$info.CommandLine
    if ($commandLine -eq '') { return $false }
    return ($commandLine.Contains('manage.py') -and $commandLine.Contains('runserver'))
  }
  catch { return $false }
}

function Get-LanAddress {
  if ($script:LanAddress -ne $false) { return [string]$script:LanAddress }

  $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.IPAddress -notmatch '^127\.|^169\.254\.' -and
    $_.InterfaceAlias -notmatch 'vEthernet|VMware|Loopback|Default Switch|Bluetooth|WSL'
  })

  $result = ''
  if ($addresses.Count -gt 0) {
    $preferred = @($addresses | Where-Object { $_.InterfaceAlias -match 'Wi-?Fi|WLAN|Wireless|Ethernet|以太网' })
    if ($preferred.Count -gt 0) { $result = [string]$preferred[0].IPAddress }
    else { $result = [string]$addresses[0].IPAddress }
  }

  $script:LanAddress = $result
  return $result
}

function Find-Cloudflared {
  $command = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $local = Join-Path $script:RepoRoot 'tools\cloudflared.exe'
  if (Test-Path -LiteralPath $local) { return $local }
  return ''
}

function Find-Ngrok {
  $command = Get-Command ngrok -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $local = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ngrok.exe'
  if (Test-Path -LiteralPath $local) { return $local }
  return ''
}

function Set-WebDropClipboard {
  param([string]$Text)
  try { Set-Clipboard -Value $Text; Write-WebDropDim '  （已复制到剪贴板）' }
  catch { Write-WebDropDim '  （剪贴板不可用，手动复制吧）' }
}

function Get-WebDropModeLabel {
  param([string]$Mode)
  if ($Mode -eq 'lan') { return '局域网' }
  return '本机'
}

# --- 后端 ---------------------------------------------------------------
function Start-WebDropBackend {
  param([string]$Mode)

  $port = Get-WebDropPort
  $tracked = $script:Services.Backend.Process

  if ($tracked -and -not $tracked.HasExited) {
    if ($script:Services.Backend.Mode -eq $Mode) {
      Write-WebDropWarn ('后端已经在跑（pid ' + $tracked.Id + '，' + (Get-WebDropModeLabel $Mode) + '模式）。')
      return $true
    }
    Write-WebDropDim ('后端现在是 ' + (Get-WebDropModeLabel $script:Services.Backend.Mode) + ' 模式，切到 ' + (Get-WebDropModeLabel $Mode) + ' 模式要重启它。')
    [void](Stop-WebDropBackend -Quiet)
  }

  if (Test-LocalPort $port) {
    $owners = @(Get-PortOwnerPids $port)
    $foreign = 0
    foreach ($ownerPid in $owners) { if (Test-IsRunserverProcess ([int]$ownerPid)) { $foreign = [int]$ownerPid } }
    if ($foreign -gt 0) {
      Write-WebDropWarn ('端口 ' + $port + ' 上已经有一个 manage.py runserver（pid ' + $foreign + '，不是本控制台起的），直接复用。')
      if ($Mode -eq 'lan') { Write-WebDropDim '  注意：那个进程未必绑在 0.0.0.0 上，手机可能连不上；要确保局域网可达，先停掉它再从这里起。' }
      return $true
    }
    Write-WebDropBad ('端口 ' + $port + ' 被别的程序占着（pid ' + ($owners -join ', ') + '）：换个端口，或先关掉它。')
    return $false
  }

  $lanIp = ''
  if ($Mode -eq 'lan') {
    $lanIp = Get-LanAddress
    if ($lanIp -eq '') {
      Write-WebDropBad '找不到局域网 IPv4 地址（没有连上 Wi-Fi / 网线？）。'
      return $false
    }
    $env:WEBDROP_ALLOW_ANY_HOST = '1'
  }
  else {
    Remove-Item Env:\WEBDROP_ALLOW_ANY_HOST -ErrorAction SilentlyContinue
  }

  $bind = '127.0.0.1'
  if ($Mode -eq 'lan') { $bind = '0.0.0.0' }

  Write-WebDropInfo ('启动后端：http://' + $bind + ':' + $port + ' ...')
  Remove-Item -LiteralPath $script:LogFile.backend, $script:LogFile.backendErr -Force -ErrorAction SilentlyContinue

  $process = Start-Process -FilePath $script:Python -ArgumentList @('manage.py', 'runserver', ($bind + ':' + $port), '--noreload') -WorkingDirectory $script:BackendDir -NoNewWindow -PassThru -RedirectStandardOutput $script:LogFile.backend -RedirectStandardError $script:LogFile.backendErr
  Register-WebDropChild $process.Id

  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-LocalPort $port) { $ready = $true; break }
    if ($process.HasExited) { break }
  }
  if (-not $ready) {
    Write-WebDropBad ('后端在 10 秒内没有监听 ' + $port + '。日志尾部：')
    Write-WebDropLogTail $script:LogFile.backend 10
    Write-WebDropLogTail $script:LogFile.backendErr 10
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    return $false
  }

  $script:Services.Backend.Process = $process
  $script:Services.Backend.Mode = $Mode
  Write-WebDropGood ('后端已启动（pid ' + $process.Id + '，' + (Get-WebDropModeLabel $Mode) + '模式）。')

  if ($Mode -eq 'lan') {
    Write-WebDropGood ('  手机（同一 Wi-Fi）打开: http://' + $lanIp + ':' + $port + '/')
    Write-WebDropWarn '  没有鉴权：同一网络里能连到这台机器的人都能上传 / 下载 / 删除'
    Write-WebDropDim '  打不开时：① 先允许 Windows 防火墙弹窗；② 校园 / 酒店 Wi-Fi 常做客户端隔离，那就改用隧道。'
  }
  return $true
}

function Stop-WebDropBackend {
  param([switch]$Quiet)

  $tracked = $script:Services.Backend.Process
  $weStarted = ($null -ne $tracked)
  $stopped = @()

  if ($tracked -and -not $tracked.HasExited) {
    $stopped += [int]$tracked.Id
    Stop-Process -Id $tracked.Id -Force -ErrorAction SilentlyContinue
  }
  $script:Services.Backend.Process = $null
  $script:Services.Backend.Mode = ''

  $port = Get-WebDropPort
  if ($weStarted) {
    # venv 的 python shim 会把真正的服务器留成隐藏子进程：按端口找监听者一起停。
    foreach ($ownerPid in @(Get-PortOwnerPids $port)) {
      if (Test-IsRunserverProcess ([int]$ownerPid)) {
        $stopped += [int]$ownerPid
        Stop-Process -Id ([int]$ownerPid) -Force -ErrorAction SilentlyContinue
      }
    }
  }

  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-LocalPort $port)) { break }
    Start-Sleep -Milliseconds 250
  }

  if (-not $weStarted) {
    if (-not $Quiet) { Write-WebDropDim '后端本来就没在跑（本控制台没启动过它）。' }
    return $true
  }

  if (Test-LocalPort $port) {
    if (-not $Quiet) { Write-WebDropWarn ('端口 ' + $port + ' 还在监听：可能是别的窗口在跑 runserver，本控制台不动它。') }
    return $false
  }

  if (-not $Quiet) {
    if ($stopped.Count -gt 0) { Write-WebDropGood ('已停止后端（pid ' + (($stopped | Sort-Object -Unique) -join ', ') + '）。') }
    else { Write-WebDropGood '后端已停止。' }
  }
  return $true
}

# --- 隧道 ---------------------------------------------------------------
function Get-WebDropTunnelUrl {
  param([string]$Text)

  $index = $Text.IndexOf('https://')
  while ($index -ge 0) {
    $end = $index + 8
    while ($end -lt $Text.Length) {
      $c = $Text[$end]
      $keep = ($c -ge [char]'a' -and $c -le [char]'z') -or ($c -ge [char]'0' -and $c -le [char]'9') -or ($c -eq [char]'-') -or ($c -eq [char]'.')
      if (-not $keep) { break }
      $end++
    }
    $candidate = $Text.Substring($index, $end - $index)
    if ($candidate.EndsWith('.trycloudflare.com')) { return $candidate }
    $index = $Text.IndexOf('https://', $end)
  }
  return ''
}

function Start-WebDropTunnel {
  param([string]$Kind)

  if (Test-WebDropTunnelAlive) {
    Write-WebDropWarn ('已经有一条 ' + $script:Services.Tunnel.Kind + ' 隧道在跑：' + $script:Services.Tunnel.Url)
    return $true
  }

  $port = Get-WebDropPort
  if (Test-LocalPort $port) {
    Write-WebDropDim ('端口 ' + $port + ' 已经在监听，直接复用。')
  }
  else {
    Write-WebDropDim ('端口 ' + $port + ' 还没在监听，先起本机后端。')
    if (-not (Start-WebDropBackend -Mode 'local')) { return $false }
  }

  if ($Kind -eq 'ngrok') { return (Start-WebDropNgrok) }
  return (Start-WebDropCloudflare)
}

function Start-WebDropCloudflare {
  $exe = Find-Cloudflared
  if ($exe -eq '') {
    Write-WebDropBad '找不到 cloudflared，没法建隧道。'
    Write-WebDropDim '  安装:  winget install --id Cloudflare.cloudflared'
    Write-WebDropDim '  或者把 cloudflared-windows-amd64.exe 放到 tools\cloudflared.exe'
    Write-WebDropDim '  下载页: https://github.com/cloudflare/cloudflared/releases/latest'
    return $false
  }

  $port = Get-WebDropPort
  Write-WebDropInfo ('启动 Cloudflare Quick Tunnel -> http://127.0.0.1:' + $port + ' ...')
  Remove-Item -LiteralPath $script:LogFile.cloudflare, $script:LogFile.cloudflareErr -Force -ErrorAction SilentlyContinue

  $process = Start-Process -FilePath $exe -ArgumentList @('tunnel', '--no-autoupdate', '--url', ('http://127.0.0.1:' + $port)) -NoNewWindow -PassThru -RedirectStandardOutput $script:LogFile.cloudflare -RedirectStandardError $script:LogFile.cloudflareErr
  Register-WebDropChild $process.Id

  $url = ''
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $script:LogFile.cloudflareErr) {
      $url = Get-WebDropTunnelUrl ([string](Get-Content -Raw -ErrorAction SilentlyContinue $script:LogFile.cloudflareErr))
      if ($url -ne '') { break }
    }
    if ($process.HasExited) { break }
  }

  if ($url -eq '') {
    Write-WebDropBad '隧道在 60 秒内没有给出公网地址。日志尾部：'
    Write-WebDropLogTail $script:LogFile.cloudflareErr 20
    Write-WebDropLogTail $script:LogFile.cloudflare 20
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    return $false
  }

  $script:Services.Tunnel.Process = $process
  $script:Services.Tunnel.Kind = 'cloudflare'
  $script:Services.Tunnel.Url = $url
  Write-WebDropGood ('公网地址: ' + $url)

  Write-WebDropDim '自检公网可达性 ...'
  $domain = ([uri]$url).Host
  $script:Services.Tunnel.Health = Test-CloudflarePublicUrl -Url $url -Domain $domain
  Write-WebDropGood ('  公网自检: /api/health/ -> ' + $script:Services.Tunnel.Health)
  Write-WebDropWarn '  没有鉴权：拿到这个链接的人都能上传 / 下载 / 删除'
  Set-WebDropClipboard $url
  return $true
}

function Start-WebDropNgrok {
  $exe = Find-Ngrok
  if ($exe -eq '') {
    Write-WebDropBad '找不到 ngrok，没法建隧道。'
    Write-WebDropDim '  安装:  winget install --id Ngrok.Ngrok'
    Write-WebDropDim '  然后:  ngrok config add-authtoken <你的 token>（免费账号在 ngrok 后台拿）'
    return $false
  }

  $port = Get-WebDropPort
  $domain = Get-WebDropSettingValue 'NGROK_STATIC_DOMAIN'
  $arguments = @('http', ('http://127.0.0.1:' + $port), '--log=stdout')
  if ($domain -ne '') { $arguments += ('--url=' + $domain) }

  # 先记下已经存在的 agent：失败清场时不能把别人窗口里的 ngrok 一起杀了。
  $preExistingAgent = Find-NgrokAgentPid

  # 已有指向同一上游的 ngrok（别处开的窗口，或上次被强杀留下的）就接管：再起一条会去抢同一域名撞 ERR_NGROK_334。
  foreach ($existing in @(Get-NgrokApiTunnels)) {
    if ([string]$existing.Addr -notmatch (':' + $port + '$')) { continue }
    $script:Services.Tunnel.Process = $null
    $script:Services.Tunnel.AgentPid = [int]$existing.Pid
    $script:Services.Tunnel.Kind = 'ngrok'
    $script:Services.Tunnel.Url = $existing.Url
    Write-WebDropWarn ('已有 ngrok 指向同一个上游（pid ' + $existing.Pid + '），直接接管：' + $existing.Url)
    Write-WebDropDim '  它是别的窗口（或上次被强杀的控制台）留下的；要停就在这个菜单里选 2)。'
    $script:Services.Tunnel.Health = Test-WebDropHealth -Url $existing.Url -Attempts 3
    Write-WebDropGood ('  公网自检: /api/health/ -> ' + $script:Services.Tunnel.Health)
    Set-WebDropClipboard $existing.Url
    return $true
  }

  Write-WebDropInfo ('启动 ngrok -> http://127.0.0.1:' + $port + ' ...')
  Remove-Item -LiteralPath $script:LogFile.ngrok, $script:LogFile.ngrokErr -Force -ErrorAction SilentlyContinue

  $process = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $script:LogFile.ngrok -RedirectStandardError $script:LogFile.ngrokErr
  Register-WebDropChild $process.Id

  $url = ''
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    foreach ($apiPort in @(4040, 4041)) {
      try {
        $tunnels = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $apiPort + '/api/tunnels') -TimeoutSec 3
        foreach ($tunnel in @($tunnels.tunnels)) {
          if ([string]$tunnel.public_url -like 'https://*') { $url = [string]$tunnel.public_url; break }
        }
      }
      catch { }
      if ($url -ne '') { break }
    }
    if ($url -ne '') { break }
    # WindowsApps 别名起的 ngrok 壳会秒退，真正的 agent 还在跑；壳和 agent 都没了才算失败。
    if ($process.HasExited -and (Find-NgrokAgentPid -ExcludePid $preExistingAgent) -le 0) { break }
  }

  if ($url -eq '') {
    Write-WebDropBad 'ngrok 没能给出公网地址（30 秒）。日志尾部：'
    Write-WebDropLogTail $script:LogFile.ngrok 20
    Write-WebDropLogTail $script:LogFile.ngrokErr 20
    $logText = ''
    if (Test-Path -LiteralPath $script:LogFile.ngrok) { $logText = [string](Get-Content -Raw -ErrorAction SilentlyContinue $script:LogFile.ngrok) }
    if ($logText -match 'ERR_NGROK_334|is already online') { Write-WebDropWarn '  已经有另一个 ngrok 占着同一个域名，先把它（那个窗口）关掉再试。' }
    elseif ($logText -match 'ERR_NGROK_4018|authentication failed') { Write-WebDropWarn '  需要 authtoken：ngrok config add-authtoken <token>' }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    $strayAgent = Find-NgrokAgentPid
    if ($strayAgent -gt 0 -and $strayAgent -ne $preExistingAgent) { Stop-Process -Id $strayAgent -Force -ErrorAction SilentlyContinue }
    return $false
  }

  $script:Services.Tunnel.Process = $process
  $script:Services.Tunnel.Kind = 'ngrok'
  $script:Services.Tunnel.Url = $url
  Write-WebDropGood ('公网地址: ' + $url)

  # WindowsApps 别名起的 ngrok 会先退壳，真正在跑的是本地 API 端口 4040/4041 的主人；只按壳的 PID 既看不出活着也停不掉。
  $agentPid = Find-NgrokAgentPid -ExcludePid $preExistingAgent
  if ($agentPid -gt 0) {
    $script:Services.Tunnel.AgentPid = $agentPid
    Register-WebDropChild $agentPid
  }

  Write-WebDropDim '自检公网可达性 ...'
  $script:Services.Tunnel.Health = Test-WebDropHealth -Url $url -Attempts 3
  Write-WebDropGood ('  公网自检: /api/health/ -> ' + $script:Services.Tunnel.Health)
  Write-WebDropWarn '  手机浏览器首次打开会看到 ngrok 的确认页，点一下继续就行（API / 静态资源不受影响）'
  Write-WebDropWarn '  没有鉴权：拿到这个链接的人都能上传 / 下载 / 删除'
  Set-WebDropClipboard $url
  return $true
}

function Test-WebDropTunnelAlive {
  $tunnel = $script:Services.Tunnel
  if ($tunnel.Process -and -not $tunnel.Process.HasExited) { return $true }
  if ($tunnel.AgentPid -gt 0 -and (Get-Process -Id $tunnel.AgentPid -ErrorAction SilentlyContinue)) { return $true }
  return $false
}

function Get-NgrokAgent {
  # ngrok 的本地 API（4040/4041）占用者就是真正的 agent 进程。
  foreach ($apiPort in @(4040, 4041)) {
    foreach ($ownerPid in @(Get-PortOwnerPids $apiPort)) {
      try {
        $info = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ownerPid) -ErrorAction Stop
        if ($info -and ([string]$info.CommandLine).Contains('ngrok')) {
          return [pscustomobject]@{ Pid = [int]$ownerPid; ApiPort = $apiPort }
        }
      }
      catch { }
    }
  }
  return $null
}

function Find-NgrokAgentPid {
  param([int]$ExcludePid = 0)
  $agent = Get-NgrokAgent
  if ($agent -and $agent.Pid -ne $ExcludePid) { return [int]$agent.Pid }
  return 0
}

function Get-NgrokApiTunnels {
  # 本地已经在跑的 ngrok 隧道：pid / 公网地址 / 上游地址。
  $agent = Get-NgrokAgent
  if (-not $agent) { return @() }
  $list = @()
  try {
    $tunnels = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $agent.ApiPort + '/api/tunnels') -TimeoutSec 3
    foreach ($tunnel in @($tunnels.tunnels)) {
      if ([string]$tunnel.public_url -notlike 'https://*') { continue }
      $list += [pscustomobject]@{ Pid = [int]$agent.Pid; Url = [string]$tunnel.public_url; Addr = [string]$tunnel.config.addr }
    }
  }
  catch { }
  return $list
}

function Stop-WebDropTunnel {
  param([switch]$Quiet)
  $kind = $script:Services.Tunnel.Kind
  $process = $script:Services.Tunnel.Process
  $agentPid = $script:Services.Tunnel.AgentPid
  $ids = @()

  if ($process -and -not $process.HasExited) {
    $ids += [int]$process.Id
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  if ($agentPid -gt 0) {
    if (Get-Process -Id $agentPid -ErrorAction SilentlyContinue) { $ids += [int]$agentPid }
    Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
  }

  $script:Services.Tunnel.Process = $null
  $script:Services.Tunnel.AgentPid = 0
  $script:Services.Tunnel.Kind = ''
  $script:Services.Tunnel.Url = ''
  $script:Services.Tunnel.Health = ''

  if ($Quiet) { return $true }
  if ($ids.Count -gt 0) { Write-WebDropGood ('已停止 ' + $kind + ' 隧道（pid ' + (($ids | Sort-Object -Unique) -join ', ') + '）。') }
  elseif ($kind -ne '') { Write-WebDropDim ('隧道（' + $kind + '）进程已经退出了。') }
  else { Write-WebDropDim '隧道本来就没在跑。' }
  return $true
}

function Test-WebDropHealth {
  param([string]$Url, [int]$Attempts = 3)

  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      $body = [string](Invoke-WebRequest -Uri ($Url + '/api/health/') -UseBasicParsing -TimeoutSec 15).Content
      if ($body.Contains('ok')) { return 'ok' }
    }
    catch { }
    Start-Sleep -Seconds 2
  }
  return '未能自检'
}

function Test-CloudflarePublicUrl {
  param([string]$Url, [string]$Domain)

  $health = Test-WebDropHealth -Url $Url -Attempts 2
  if ($health -eq 'ok') { return 'ok' }

  foreach ($dns in @('1.1.1.1', '8.8.8.8')) {
    $resolved = ''
    foreach ($answer in @(Resolve-DnsName $Domain -Server $dns -Type A -ErrorAction SilentlyContinue)) {
      if ($answer.IPAddress) { $resolved = [string]$answer.IPAddress; break }
    }
    if ($resolved -eq '') { continue }
    $code = & curl.exe -sS -m 20 --resolve ($Domain + ':443:' + $resolved) -o NUL -w '%{http_code}' ($Url + '/api/health/')
    if ($code -eq '200') {
      Write-WebDropWarn ('  本机 DNS 不解析这个域名（用 ' + $dns + ' 验证过公网可达）')
      Write-WebDropDim ('  本机自测: curl --resolve ' + $Domain + ':443:' + $resolved + ' ' + $Url + '/')
      Write-WebDropWarn '  刚建的隧道域名，本机解析器往往要几分钟才生效（负缓存），手机在同一网络也一样'
      Write-WebDropWarn '  手机上等几分钟再刷新，或把手机 DNS 换成 1.1.1.1，或改用「后端 · 局域网」模式'
      return ('ok（经 ' + $dns + ' 验证）')
    }
  }
  return '未能自检（本机网络可能拦截），让对方打开链接确认'
}

# --- 表格行（交给 Control.Format.ps1xml 渲染）---------------------------
function New-WebDropServiceRow {
  param([string]$Name, [string]$State, [string]$ProcessId, [string]$Address, [string]$Note)
  $row = [pscustomobject]@{ Name = $Name; State = $State; Pid = $ProcessId; Address = $Address; Note = $Note }
  $row.PSObject.TypeNames.Insert(0, 'WebDrop.Service')
  return $row
}

function New-WebDropSettingRow {
  param([int]$No, [string]$Key, [string]$Effective, [string]$Source, [string]$Default, [string]$Note)
  $row = [pscustomobject]@{ No = $No; Key = $Key; Effective = $Effective; Source = $Source; Default = $Default; Note = $Note }
  $row.PSObject.TypeNames.Insert(0, 'WebDrop.Setting')
  return $row
}

function Format-WebDropCell {
  param([string]$Value)
  if ($Value -eq '') { return '-' }
  return $Value
}

function Get-WebDropServiceRows {
  $port = Get-WebDropPort
  $rows = New-Object System.Collections.Generic.List[object]

  $state = '未启动'
  $processId = '-'
  $address = '127.0.0.1:' + $port
  $note = '本机模式（隧道用）'
  $tracked = $script:Services.Backend.Process
  if ($tracked -and -not $tracked.HasExited) {
    $state = '运行中'
    $processId = [string]$tracked.Id
    if ($script:Services.Backend.Mode -eq 'lan') {
      $address = '0.0.0.0:' + $port
      $note = '局域网模式（手机同 Wi-Fi）'
    }
    else { $note = '本控制台启动' }
  }
  elseif ($tracked -and $tracked.HasExited) {
    $state = '已退出'
    $note = '进程退出了，看日志尾部'
  }
  elseif (Test-LocalPort $port) {
    $state = '运行中'
    $processId = (@(Get-PortOwnerPids $port) -join ',')
    $note = '不是本控制台起的（退出时不动它）'
  }
  $rows.Add((New-WebDropServiceRow 'backend' $state $processId $address $note))

  $tunnel = $script:Services.Tunnel
  foreach ($kind in @('cloudflare', 'ngrok')) {
    $label = 'Cloudflare Quick Tunnel（随机域名）'
    if ($kind -eq 'ngrok') { $label = 'ngrok 隧道（可固定域名）' }
    # 接管的隧道只有 AgentPid、没有 Process，所以认 Kind，不认进程对象。
    if ($tunnel.Kind -eq $kind) {
      if (Test-WebDropTunnelAlive) {
        $pidText = '-'
        if ($tunnel.Process -and -not $tunnel.Process.HasExited) { $pidText = [string]$tunnel.Process.Id }
        elseif ($tunnel.AgentPid -gt 0) { $pidText = [string]$tunnel.AgentPid }
        $rows.Add((New-WebDropServiceRow $kind '运行中' $pidText ('-> 127.0.0.1:' + $port) $label))
      }
      else {
        $rows.Add((New-WebDropServiceRow $kind '已退出' '-' '-' $label))
      }
    }
    else {
      $rows.Add((New-WebDropServiceRow $kind '未启动' '-' '-' $label))
    }
  }

  return $rows
}

function Get-WebDropSettingRows {
  $map = Get-WebDropEnvMap
  $rows = New-Object System.Collections.Generic.List[object]
  $known = @()
  $number = 0

  foreach ($spec in $script:SettingSpec) {
    $number++
    $known += $spec.Key
    $source = 'default'
    $value = [string]$spec.Default
    if ($map.Contains($spec.Key)) { $source = 'file'; $value = [string]$map[$spec.Key] }
    $note = $spec.Note   # 规则留给「改值」时再显示，不然这一列在 120 列里会被截断
    $problem = Test-WebDropSettingValue -Spec $spec -Value $value
    if ($problem -ne '') { $note = '当前值无效：' + $problem + ' | ' + $note }
    $rows.Add((New-WebDropSettingRow $number $spec.Key (Format-WebDropCell $value) $source (Format-WebDropCell ([string]$spec.Default)) $note))
  }

  foreach ($key in @($map.Keys)) {
    if ($known -contains $key) { continue }
    $number++
    $rows.Add((New-WebDropSettingRow $number $key (Format-WebDropCell ([string]$map[$key])) 'file' '-' '自定义键（原样保留、不校验；留空即删除）'))
  }

  return $rows
}

# --- 画面 ---------------------------------------------------------------
function Write-WebDropTable {
  param($Rows, [int]$Width = 0)

  # 必须显式 Out-String：同一个输出流里连着渲染两种表时（状态表 + 配置表），实时格式器
  # 会对第二种表退回默认列表视图；显式格式化才走 Format.ps1xml，顺带把中日韩列宽算对。
  if ($Width -le 0) {
    $Width = 120
    try {
      $buffer = [int]$Host.UI.RawUI.BufferSize.Width
      if ($buffer -gt 0) { $Width = $buffer - 1 }
    }
    catch { }
    if ($Width -lt 90) { $Width = 90 }
    elseif ($Width -gt 200) { $Width = 200 }
  }

  $text = [string]($Rows | Out-String -Width $Width)
  if ($text.Trim() -eq '') { return }
  Write-Host $text.TrimEnd()
}

function Show-WebDropHeader {
  if (-not $script:NoClear) { try { Clear-Host } catch { } }

  $portText = '端口 ' + (Get-WebDropPort)
  if ($script:PortArg -gt 0) { $portText = $portText + '（-Port 临时覆盖）' }

  Write-Host 'web-drop 控制台' -ForegroundColor Cyan -NoNewline
  Write-Host ('    ' + $portText + ' · 配置 ' + $script:EnvPath) -ForegroundColor DarkGray
  Write-Host ('-' * 76) -ForegroundColor DarkCyan
  Write-WebDropTable (Get-WebDropServiceRows)
  if ($script:Services.Tunnel.Url) { Write-Host ('公网地址: ' + $script:Services.Tunnel.Url) -ForegroundColor Green }
  $lanIp = Get-LanAddress
  if ($lanIp -ne '') { Write-WebDropDim ('局域网地址: http://' + $lanIp + ':' + (Get-WebDropPort) + '/') }
  Write-Host ('-' * 76) -ForegroundColor DarkCyan
}

function Write-WebDropTool {
  param([string]$Name, [string]$Path, [string]$Install)
  if ($Path -ne '') { Write-WebDropGood ('  ' + $Name + ': ' + $Path) }
  else { Write-WebDropWarn ('  ' + $Name + ': 没找到。安装：' + $Install) }
}

function Show-WebDropEnvFile {
  Write-WebDropTitle ('repo/.env 全文（' + $script:EnvPath + '）')
  if (-not (Test-Path -LiteralPath $script:EnvPath)) {
    Write-WebDropWarn '  文件不存在（保存任意一项时会用内置模板重建）。'
    return
  }
  $lines = @([System.IO.File]::ReadAllLines($script:EnvPath))
  $number = 0
  foreach ($line in $lines) {
    $number++
    Write-Host ('  ' + ([string]$number).PadLeft(3) + '  ' + $line)
  }
}

function Edit-WebDropSetting {
  param($Row)

  Write-Host ''
  Write-WebDropInfo ('  ' + $Row.Key + ' = ' + $Row.Effective + '    默认 ' + $Row.Default)
  $spec = Get-WebDropSetting $Row.Key
  if ($spec) { Write-WebDropDim ('  规则：' + $spec.Rule + '；输入留空 = 删掉这个键、回落默认值') }
  else { Write-WebDropDim '  规则：自定义键不校验；输入留空 = 删掉这个键' }

  $value = Read-Host '新值'
  if ($null -eq $value) { return }
  $value = $value.Trim()

  if ($spec) {
    $problem = Test-WebDropSettingValue -Spec $spec -Value $value
    if ($problem -ne '') {
      Write-WebDropBad ('  没写入：' + $problem)
      Start-Sleep -Seconds 2
      return
    }
  }

  $modeBefore = $script:Services.Backend.Mode
  try {
    Set-WebDropEnvValue -Key $Row.Key -Value $value
  }
  catch {
    Write-WebDropBad ('  写入 .env 失败：' + $_.Exception.Message)
    Start-Sleep -Seconds 2
    return
  }

  if ($value -eq '') { Write-WebDropGood ('  已删除 ' + $Row.Key + '（回落默认值）') }
  else { Write-WebDropGood ('  已写入 ' + $Row.Key + '=' + $value) }
  Write-WebDropDim '  改完要重启后端才生效。'

  $tracked = $script:Services.Backend.Process
  if ($tracked -and -not $tracked.HasExited) {
    $restart = Read-Host '  后端正在跑，现在重启它让配置生效？(y/N)'
    if ($restart -and $restart.Trim().ToLower() -eq 'y') {
      [void](Stop-WebDropBackend -Quiet)
      if ($modeBefore -eq '') { $modeBefore = 'local' }
      [void](Start-WebDropBackend -Mode $modeBefore)
    }
  }
  Start-Sleep -Milliseconds 600
}

function Show-WebDropEnvMenu {
  while ($true) {
    Show-WebDropHeader
    Write-WebDropTitle ('编辑 .env（' + $script:EnvPath + '）')
    Write-WebDropTable (Get-WebDropSettingRows)
    Write-Host ''
    Write-WebDropDim '  输入序号改值；值留空 = 恢复默认；v = 看全文；0 = 返回'
    $answer = Read-Host '选择'
    if ($null -eq $answer) { continue }
    $choice = $answer.Trim().ToLower()

    if ($choice -eq '0' -or $choice -eq 'q') { return }
    if ($choice -eq '') { continue }
    if ($choice -eq 'v') { Show-WebDropEnvFile; Wait-WebDropEnter; continue }

    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number)) {
      Write-WebDropWarn ('  没有这一项: ' + $answer)
      Start-Sleep -Milliseconds 800
      continue
    }

    $rows = @(Get-WebDropSettingRows)
    if ($number -lt 1 -or $number -gt $rows.Count) {
      Write-WebDropWarn ('  序号超出范围：1 - ' + $rows.Count)
      Start-Sleep -Milliseconds 800
      continue
    }
    Edit-WebDropSetting $rows[$number - 1]
  }
}

function Show-WebDropDiagnostics {
  Show-WebDropHeader
  Write-WebDropTitle '状态'
  Write-WebDropTable (Get-WebDropServiceRows)
  if ($script:Services.Tunnel.Url) {
    Write-WebDropGood ('  公网地址: ' + $script:Services.Tunnel.Url)
    if ($script:Services.Tunnel.Health) { Write-WebDropDim ('  上次自检: /api/health/ -> ' + $script:Services.Tunnel.Health) }
  }
  $lanIp = Get-LanAddress
  if ($lanIp -ne '') { Write-WebDropDim ('  局域网地址: http://' + $lanIp + ':' + (Get-WebDropPort) + '/') }

  Write-WebDropTitle '配置（repo/.env）'
  Write-WebDropTable (Get-WebDropSettingRows)

  Write-WebDropTitle '工具'
  Write-WebDropTool 'cloudflared' (Find-Cloudflared) 'winget install --id Cloudflare.cloudflared'
  Write-WebDropTool 'ngrok' (Find-Ngrok) 'winget install --id Ngrok.Ngrok'

  Write-WebDropTitle '后端日志尾部'
  Write-WebDropLogTail $script:LogFile.backendErr 6
  Wait-WebDropEnter
}

function Open-WebDropBackendPage {
  param([string]$Mode)

  $port = Get-WebDropPort
  $target = 'http://127.0.0.1:' + $port + '/'
  if ($Mode -eq 'lan') {
    $lanIp = Get-LanAddress
    if ($lanIp -eq '') { Write-WebDropBad '  找不到局域网 IPv4 地址。'; return }
    $target = 'http://' + $lanIp + ':' + $port + '/'
    Write-WebDropGood ('  局域网地址: ' + $target)
  }
  Set-WebDropClipboard $target
  try { Start-Process $target } catch { Write-WebDropWarn ('  打不开浏览器：' + $_.Exception.Message) }
}

function Invoke-WebDropFrontendBuild {
  $buildScript = Join-Path $PSScriptRoot 'build_frontend.ps1'
  Show-WebDropHeader
  Write-WebDropTitle '构建前端'
  if (-not (Test-Path -LiteralPath $buildScript)) {
    Write-WebDropBad ('  找不到 ' + $buildScript)
    Wait-WebDropEnter
    return
  }
  Write-WebDropDim '  转调 scripts\build_frontend.ps1（ts2dart -> ngdart -> dart2js），要几分钟。'
  try { & $buildScript }
  catch { Write-WebDropBad ('  构建失败：' + $_.Exception.Message) }
  Wait-WebDropEnter
}

# --- 菜单 ---------------------------------------------------------------
function Show-WebDropBackendMenu {
  param([string]$Mode)

  while ($true) {
    Show-WebDropHeader
    Write-WebDropTitle ('后端 · ' + (Get-WebDropModeLabel $Mode) + '（端口 ' + (Get-WebDropPort) + '）')
    Write-Host '  1) 启动    2) 停止    3) 重启'
    if ($Mode -eq 'lan') { Write-Host '  4) 显示局域网地址    5) 看日志尾部    0) 返回' }
    else { Write-Host '  4) 在浏览器打开      5) 看日志尾部    0) 返回' }
    Write-Host ''
    $answer = Read-Host '选择'
    if ($null -eq $answer) { continue }
    $choice = $answer.Trim().ToLower()

    if ($choice -eq '1') { [void](Start-WebDropBackend -Mode $Mode); Wait-WebDropEnter }
    elseif ($choice -eq '2') { [void](Stop-WebDropBackend); Wait-WebDropEnter }
    elseif ($choice -eq '3') { [void](Stop-WebDropBackend -Quiet); [void](Start-WebDropBackend -Mode $Mode); Wait-WebDropEnter }
    elseif ($choice -eq '4') { Open-WebDropBackendPage -Mode $Mode; Wait-WebDropEnter }
    elseif ($choice -eq '5') {
      Write-WebDropLogTail $script:LogFile.backend 30
      Write-WebDropLogTail $script:LogFile.backendErr 20
      Wait-WebDropEnter
    }
    elseif ($choice -eq '0' -or $choice -eq 'q') { return }
    elseif ($choice -eq '') { continue }
    else {
      Write-WebDropWarn ('  没有这一项: ' + $answer)
      Start-Sleep -Milliseconds 800
    }
  }
}

function Show-WebDropTunnelMenu {
  param([string]$Kind)

  $label = 'Cloudflare Quick Tunnel'
  if ($Kind -eq 'ngrok') { $label = 'ngrok 隧道' }

  while ($true) {
    Show-WebDropHeader
    Write-WebDropTitle ($label + '（上游 127.0.0.1:' + (Get-WebDropPort) + '）')
    if ($Kind -eq 'ngrok') {
      $domain = Get-WebDropSettingValue 'NGROK_STATIC_DOMAIN'
      if ($domain -ne '') { Write-WebDropDim ('  固定域名: ' + $domain) }
      else { Write-WebDropDim '  域名: 每次随机（想固定就在「编辑 .env」里填 NGROK_STATIC_DOMAIN）' }
    }
    else {
      Write-WebDropDim '  域名: 每次随机，形如 https://xxxx.trycloudflare.com'
    }
    Write-Host '  1) 启动    2) 停止    3) 重启'
    Write-Host '  4) 复制 / 打开公网地址    5) 公网自检 /api/health/'
    Write-Host '  6) 看日志尾部              0) 返回'
    Write-Host ''
    $answer = Read-Host '选择'
    if ($null -eq $answer) { continue }
    $choice = $answer.Trim().ToLower()

    if ($choice -eq '1') { [void](Start-WebDropTunnel -Kind $Kind); Wait-WebDropEnter }
    elseif ($choice -eq '2') { [void](Stop-WebDropTunnel); Wait-WebDropEnter }
    elseif ($choice -eq '3') { [void](Stop-WebDropTunnel); [void](Start-WebDropTunnel -Kind $Kind); Wait-WebDropEnter }
    elseif ($choice -eq '4') {
      $url = $script:Services.Tunnel.Url
      if (-not $url) { Write-WebDropWarn '  还没有公网地址（先启动隧道）。' }
      else {
        Set-WebDropClipboard $url
        try { Start-Process $url } catch { Write-WebDropWarn ('  打不开浏览器：' + $_.Exception.Message) }
      }
      Wait-WebDropEnter
    }
    elseif ($choice -eq '5') {
      $url = $script:Services.Tunnel.Url
      if (-not $url) { Write-WebDropWarn '  还没有公网地址（先启动隧道）。' }
      elseif ($Kind -eq 'ngrok') {
        $script:Services.Tunnel.Health = Test-WebDropHealth -Url $url -Attempts 3
        Write-WebDropGood ('  /api/health/ -> ' + $script:Services.Tunnel.Health)
      }
      else {
        $domain = ([uri]$url).Host
        $script:Services.Tunnel.Health = Test-CloudflarePublicUrl -Url $url -Domain $domain
        Write-WebDropGood ('  /api/health/ -> ' + $script:Services.Tunnel.Health)
      }
      Wait-WebDropEnter
    }
    elseif ($choice -eq '6') {
      if ($Kind -eq 'ngrok') {
        Write-WebDropLogTail $script:LogFile.ngrok 30
        Write-WebDropLogTail $script:LogFile.ngrokErr 20
      }
      else {
        Write-WebDropLogTail $script:LogFile.cloudflareErr 30
        Write-WebDropLogTail $script:LogFile.cloudflare 20
      }
      Wait-WebDropEnter
    }
    elseif ($choice -eq '0' -or $choice -eq 'q') { return }
    elseif ($choice -eq '') { continue }
    else {
      Write-WebDropWarn ('  没有这一项: ' + $answer)
      Start-Sleep -Milliseconds 800
    }
  }
}

function Show-WebDropMenu {
  while ($true) {
    Show-WebDropHeader
    Write-Host '  1) 后端 · 本机 (127.0.0.1)          2) 后端 · 局域网 (0.0.0.0，手机直连)'
    Write-Host '  3) Cloudflare 隧道                   4) ngrok 隧道'
    Write-Host '  5) 编辑 .env                         6) 状态 / 诊断'
    Write-Host '  7) 构建前端                          0) 退出（停掉本控制台起的服务）'
    Write-Host ''
    $answer = Read-Host '选择'
    if ($null -eq $answer) { continue }
    $choice = $answer.Trim().ToLower()

    if ($choice -eq '1') { Show-WebDropBackendMenu -Mode 'local' }
    elseif ($choice -eq '2') { Show-WebDropBackendMenu -Mode 'lan' }
    elseif ($choice -eq '3') { Show-WebDropTunnelMenu -Kind 'cloudflare' }
    elseif ($choice -eq '4') { Show-WebDropTunnelMenu -Kind 'ngrok' }
    elseif ($choice -eq '5') { Show-WebDropEnvMenu }
    elseif ($choice -eq '6') { Show-WebDropDiagnostics }
    elseif ($choice -eq '7') { Invoke-WebDropFrontendBuild }
    elseif ($choice -eq '0' -or $choice -eq 'q') { return }
    elseif ($choice -eq '') { continue }
    else {
      Write-WebDropWarn ('  没有这一项: ' + $answer)
      Start-Sleep -Milliseconds 800
    }
  }
}

# --- 清场 / 无菜单模式 --------------------------------------------------
function Stop-WebDropAll {
  try {
    $kind = $script:Services.Tunnel.Kind
    [void](Stop-WebDropTunnel -Quiet)
    if ($kind -ne '') { Write-WebDropDim ('已停止隧道 ' + $kind + '。') }
  }
  catch { }
  $script:Services.Tunnel.Process = $null
  $script:Services.Tunnel.AgentPid = 0
  $script:Services.Tunnel.Kind = ''
  $script:Services.Tunnel.Url = ''

  try { [void](Stop-WebDropBackend -Quiet) }
  catch { }

  Remove-Item -LiteralPath $script:LogFile.backend, $script:LogFile.backendErr, $script:LogFile.cloudflare, $script:LogFile.cloudflareErr, $script:LogFile.ngrok, $script:LogFile.ngrokErr -Force -ErrorAction SilentlyContinue
}

function Wait-WebDropProcesses {
  $port = Get-WebDropPort
  while ($true) {
    $alive = $false
    $backend = $script:Services.Backend.Process
    if ($backend -and -not $backend.HasExited) { $alive = $true }
    if (Test-WebDropTunnelAlive) { $alive = $true }
    if (-not $alive -and -not (Test-LocalPort $port)) { return }
    Start-Sleep -Milliseconds 500
  }
}

function Invoke-WebDropAction {
  param([string]$Name)

  if ($Name -eq 'backend' -or $Name -eq 'lan') {
    $mode = 'local'
    if ($Name -eq 'lan') { $mode = 'lan' }
    if (-not (Start-WebDropBackend -Mode $mode)) { $script:ExitCode = 1; return }
    Write-Host ''
    if ($mode -eq 'lan') {
      Write-WebDropGood ('  手机（同一 Wi-Fi）打开: http://' + (Get-LanAddress) + ':' + (Get-WebDropPort) + '/')
      Write-WebDropWarn '  没有鉴权：同一网络里能连到这台机器的人都能上传 / 下载 / 删除'
      Write-WebDropDim '  打不开时：先允许防火墙弹窗；校园 / 酒店 Wi-Fi 可能做了客户端隔离。'
    }
    else {
      Write-WebDropGood ('  本机打开: http://127.0.0.1:' + (Get-WebDropPort) + '/')
    }
  }
  else {
    if (-not (Start-WebDropTunnel -Kind $Name)) { $script:ExitCode = 1; return }
    Write-Host ''
    Write-WebDropGood ('  公网地址: ' + $script:Services.Tunnel.Url)
    Write-WebDropWarn '  没有鉴权：拿到这个链接的人都能上传 / 下载 / 删除'
  }

  Write-Host ''
  Write-WebDropDim '按 Ctrl+C 停止（直接关掉窗口也一样）。'
  Wait-WebDropProcesses
}

# --- 入口 ---------------------------------------------------------------
if ($script:LibOnly) { return }

try {
  if (-not (Test-Path -LiteralPath $script:Python)) {
    throw ('找不到虚拟环境的 python：' + $script:Python + '（见 README「快速开始」）')
  }

  if (Test-Path -LiteralPath $script:FormatPath) {
    try { Update-FormatData -PrependPath $script:FormatPath }
    catch { Write-WebDropWarn ('格式文件没加载成功（表格会用默认样式）：' + $_.Exception.Message) }
  }

  if ($Action -eq 'menu') {
    Show-WebDropMenu
  }
  else {
    Invoke-WebDropAction $Action
  }
}
catch {
  Write-Host ''
  Write-WebDropBad ('出错：' + $_.Exception.Message)
  if ($Action -eq 'menu') { Wait-WebDropEnter }
  $script:ExitCode = 1
}
finally {
  Stop-WebDropAll
  Write-WebDropDim '清理完成，端口已释放。'
}

exit $script:ExitCode
