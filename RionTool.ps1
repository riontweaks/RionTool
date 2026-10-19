[CmdletBinding()]
param(
    [switch]$Elevated,
    [switch]$Cleanup
)
 
$ErrorActionPreference = 'Stop'
 
trap {
    $logDir = Join-Path $env:ProgramData 'RionTool'
    try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }
    $text = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace
    try { Add-Content -Path (Join-Path $logDir 'error.log') -Value $text -Encoding UTF8 } catch { }
    Write-Host ("Rion Tool stopped: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Details written to {0}" -f (Join-Path $logDir 'error.log')) -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    break
}
 
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
 
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps64) { Start-Process -FilePath $ps64 -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"{1}' -f $PSCommandPath,$(if ($Cleanup) { ' -Cleanup' } else { '' })); return }
}
if (-not (Test-IsAdmin)) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $script:PowerShellExe
        $psi.Verb      = 'runas'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Elevated{1}' -f $PSCommandPath,$(if ($Cleanup) { ' -Cleanup' } else { '' })
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host 'Rion Tool needs Administrator rights. Elevation was cancelled.' -ForegroundColor Yellow
    }
    return
}
 
$Host.UI.RawUI.WindowTitle = 'Rion Tool'
 
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
 
$script:Build     = '2026-10-19.2'
$script:DataDir   = Join-Path $env:ProgramData 'RionTool'
$script:LogPath   = Join-Path $script:DataDir 'rion.log'
$script:BackupDir = Join-Path $script:DataDir 'backups'
$script:InstanceMutex = New-Object System.Threading.Mutex($false,'Local\RionToolSingleInstance')
if (-not $script:InstanceMutex.WaitOne(0)) { [System.Windows.MessageBox]::Show('Rion Tool is already open. Use the window that is already running, so two copies do not overwrite each other''s undo records.','Rion Tool','OK','Information') | Out-Null; return }
if (-not (Test-Path $script:BackupDir)) { New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null }
 
$script:Env = [ordered]@{
    OsName      = 'Windows'
    Build       = 0
    Cpu         = 'Unknown CPU'
    CpuVendor   = 'Unknown'
    RamBytes    = 0
    RamNominalGB = 0
    Gpus        = @()
    GpuVendors  = @()
    SvcThreshold = 0
    IsLaptop    = $false
    CpuHybrid   = $false
    CpuX3D      = $false
    HasHdd      = $false
}

$script:ServiceBackups = @{}

$script:JournalPath = Join-Path $script:DataDir 'journal.json'
$script:Journal = @{}
function Read-Journal {
    try {
        if (-not (Test-Path -LiteralPath $script:JournalPath)) { return }
        $raw = Get-Content -LiteralPath $script:JournalPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) {
            $clean = @($p.Value | Where-Object { $_.kind -ne 'regValue' -or ([string]$_.path -match '^(HKLM:|HKCU:|HKCR:|HKU:|Registry::|Microsoft\.PowerShell\.Core\\Registry::)' -and [string]$_.name -ne '') })
            if ($clean.Count) { $script:Journal[$p.Name] = $clean }
        }
    } catch { Write-Log ("Could not read saved original values: {0}" -f $_.Exception.Message) 'Warn' }
}
$script:RetiredTweaks = @('feat.search.webview2','svc.bg.appr','adv.prio.background','cpu.powerthrottling','feat.gaming.fse','app.chrome.extensions','app.edge.extensions','app.brave.extensions','app.firefox.extensions','svc.dev.hotkey','svc.dev.hdhotkey','svc.vendor.oem','startup.xbox','startup.phonelink','startup.copilot','startup.teams','svc.feat.kiosk','svc.net.snmp','svc.legacy.unused','svc.net.wcn','svc.dev.perception','svc.feat.cellulartime','svc.net.peer','svc.bg.retaildemo','task.retaildemo','task.mobilebroadband','svc.dev.mixedreality','svc.bg.insider','net.dnsnegative','mem.pagingexec','net.wifi.txpower','adv.devices.gswavetable','adv.devices.speakerwifi','adv.devices.kerneldebug','adv.devices.ndis','app.chrome.hwaccel','app.edge.hwaccel','app.brave.hwaccel','app.firefox.hwaccel','feat.notify.off','svc.feat.themes','feat.opt.pdf','svc.feat.seclogon','svc.net.radio','svc.net.ipsec','input.mouse.onetoone','boot.chkdsk','priv.hosts.telemetry','net.qos.nla')
$script:MergedTweaks = [ordered]@{ 'gpu.nv.telemetry'='task.gpu.nv.reports'; 'svc.net.workschool'='svc.feat.account'; 'app.steam.startup'='startup.steam'; 'app.discord.startup'='startup.discord'; 'app.epic.startup'='startup.epic'; 'app.battlenet.startup'='startup.battlenet'; 'app.ea.startup'='startup.ea'; 'app.ubisoft.startup'='startup.ubisoft'; 'app.riot.startup'='startup.riot'; 'adv.prio.sep'='adv.prio.sep26'; 'cpu.epp'='cpu.ppm.perfepp'; 'feat.ai.copilotlegacy'='feat.ai.copilotall'; 'task.featureusage'='task.tel.flighting'; 'svc.xbox.dvr'='sec.gamedvr'; 'svc.feat.location'='net.wifi.location'; 'svc.feat.fax'='feat.opt.fax'; 'svc.feat.workfolders'='feat.opt.workfolders'; 'task.workfolders'='feat.opt.workfolders'; 'svc.vendor.asus'='vendor.asus'; 'net.wifi.mimo'='net.wifi.powersave'; 'net.wifi.uapsd'='net.wifi.powersave' }
function Invoke-RetiredTweakCleanup {
    if (-not (Test-IsAdmin)) { return }
    $changed = $false
    try { if (Get-ScheduledTask -TaskPath '\RionTool\' -TaskName 'Weekly cleanup' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskPath '\RionTool\' -TaskName 'Weekly cleanup' -Confirm:$false -ErrorAction Stop; Remove-Item -LiteralPath (Join-Path $script:DataDir 'RionTool.ps1') -Force -ErrorAction SilentlyContinue; Write-Log 'Removed the weekly cleanup task (that feature was removed from Rion Tool).' 'Info' } } catch { }
    foreach ($old in @($script:MergedTweaks.Keys)) {
        if (-not $script:Journal.ContainsKey($old)) { continue }
        $target = [string]$script:MergedTweaks[$old]
        if ($script:TweakIndex -and $script:TweakIndex.ContainsKey($target)) {
            $list = [System.Collections.ArrayList]@($(if ($script:Journal.ContainsKey($target)) { @($script:Journal[$target]) } else { @() }))
            foreach ($r in @($script:Journal[$old])) { $k = Get-RecordKey $r; if (-not @($list | Where-Object { (Get-RecordKey $_) -eq $k }).Count) { [void]$list.Add($r) } }
            $script:Journal[$target] = @($list)
            [void]$script:Journal.Remove($old)
            Write-Log ("Merged the undo records of the removed duplicate {0} into {1}." -f $old,$target) 'Info'
        } else {
            try { Invoke-Action @{ kind='restoreRecords'; id=$old }; Write-Log ("Restored the original values changed by the removed tweak {0}." -f $old) 'Info' }
            catch { Write-Log ("Could not fully restore the removed tweak {0}: {1}" -f $old,$_.Exception.Message) 'Warn' }
        }
        $changed = $true
    }
    try {
        $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if ((Test-Path -LiteralPath $hostsFile) -and ((Get-Content -LiteralPath $hostsFile -Raw) -match '# RionTool-telemetry-start')) { Invoke-Action @{ kind='hostsBlock'; enable=$false }; Write-Log 'Removed the Rion Tool telemetry block from the hosts file (that tweak was removed).' 'Info' }
    } catch { }
    foreach ($id in $script:RetiredTweaks) {
        if (-not $script:Journal.ContainsKey($id)) { continue }
        try { Invoke-Action @{ kind='restoreRecords'; id=$id }; Write-Log ("Restored the original values changed by the removed tweak {0}." -f $id) 'Info' }
        catch { Write-Log ("Could not fully restore the removed tweak {0}: {1}" -f $id,$_.Exception.Message) 'Warn' }
        $changed = $true
    }
    if ($script:Journal.ContainsKey('feat.privacy.appperms')) {
        $records = @($script:Journal['feat.privacy.appperms'])
        $mic = @($records | Where-Object { $_.kind -eq 'regValue' -and $_.name -eq 'LetAppsAccessMicrophone' })
        $micDone = $true
        foreach ($r in $mic) {
            try { Restore-OriginalRecord $r; Write-Log 'Store apps can use the microphone again (the microphone block was removed from Rion Tool).' 'Info' } catch { $micDone = $false; Write-Log ("Could not restore microphone access: {0}" -f $_.Exception.Message) 'Warn' }
        }
        if ($mic.Count -and $micDone) {
            $rest = @($records | Where-Object { -not ($_.kind -eq 'regValue' -and $_.name -eq 'LetAppsAccessMicrophone') })
            if ($rest.Count) { $script:Journal['feat.privacy.appperms'] = $rest } else { $script:Journal.Remove('feat.privacy.appperms') }
            $changed = $true
        }
    }
    if ($changed) { [void](Save-Journal) }
}

function Save-Journal {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        $tmp = $script:JournalPath + '.tmp'
        $script:Journal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:JournalPath -Force -ErrorAction Stop
        return $true
    } catch { Write-Log ("Could not save original values: {0}" -f $_.Exception.Message) 'Warn'; return $false }
}
function Get-RecordKey { param($Record) if ($Record.scheme) { return ("{0}|{1}|{2}|{3}" -f $Record.kind,$Record.path,$Record.name,$Record.scheme) }; return ("{0}|{1}|{2}" -f $Record.kind,$Record.path,$Record.name) }
function Get-ActiveSchemeGuid { return [regex]::Match((@(& powercfg.exe /getactivescheme 2>$null) -join ' '),'[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value.ToLowerInvariant() }
function Get-AmdDisplayKeys {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    return @(Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | Where-Object { $pv = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue; ([string]$pv.ProviderName + ' ' + [string]$pv.DriverDesc) -match '(?i)\bAMD\b|Radeon|\bATI\b|Advanced Micro Devices' } | ForEach-Object { $_.PSPath })
}
function Get-RegValueRecord {
    param([string]$Path,[string]$Name)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.GetValueNames() -notcontains $Name) { return @{ kind='regValue'; path=$Path; name=$Name; existed=$false } }
        return @{ kind='regValue'; path=$Path; name=$Name; existed=$true; type=[string]$item.GetValueKind($Name); value=$item.GetValue($Name,$null,'DoNotExpandEnvironmentNames') }
    } catch { return @{ kind='regValue'; path=$Path; name=$Name; existed=$false } }
}
function Get-OriginalRecords {
    param($Action)
    $records = @()
    switch ($Action.kind) {
        { $_ -in 'registry','registryDel' } { $records += Get-RegValueRecord -Path $Action.path -Name $Action.name }
        'runkey' {
            $e = Get-RunKeyEntry $Action.name
            if ($e) { $records += Get-RegValueRecord -Path $e.Approved -Name $Action.name }
        }
        'service' {
            foreach ($serviceName in (Resolve-ServiceNames $Action.name)) {
                $start = Get-ServiceStartValue $serviceName
                if ($null -ne $start) { $records += @{ kind='svcStart'; name=$serviceName; start=$start } }
            }
        }
        { $_ -in 'taskFolder','task','taskNamePattern' } {
            foreach ($tk in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                $match = switch ($Action.kind) {
                    'taskFolder' { $tk.TaskPath -like ("{0}*" -f $Action.path) }
                    'task'       { $tk.TaskPath -eq $Action.path -and $tk.TaskName -eq $Action.name }
                    default      { $taskName = $tk.TaskName; [bool]@($Action.patterns | Where-Object { $taskName -like $_ }).Count }
                }
                if ($match) { $records += @{ kind='taskState'; path=$tk.TaskPath; name=$tk.TaskName; enabled=($tk.State -ne 'Disabled') } }
            }
        }
        'mpPreference' {
            try { $records += @{ kind='mpPref'; path='defender'; name=[string]$Action.name; value=[int](Get-MpPreference -ErrorAction Stop).($Action.name) } } catch { }
        }
        'netadapter' {
            foreach ($ad in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
                $records += @{ kind='netState'; name=$ad.Name; enabled=($ad.AdminStatus -eq 'Up') }
            }
        }
        'nagle' {
            foreach ($key in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)) {
                foreach ($valueName in 'TcpAckFrequency','TCPNoDelay') { $records += Get-RegValueRecord -Path $key.PSPath -Name $valueName }
            }
        }
        { $_ -in 'netAdvancedProperty','netAdvancedPropertyMax' } {
            foreach ($property in @(Get-MatchingNetProperties $Action)) {
                $records += @{ kind='netAdvProp'; path=$property.Name; name=$property.DisplayName; value=[string]$property.DisplayValue }
            }
        }
        'netRssProfile' {
            foreach ($rss in @(Get-NetAdapterRss -ErrorAction SilentlyContinue)) {
                $records += @{ kind='netRssCfg'; path=$rss.Name; name='rss'; profile=[string]$rss.Profile; base=[int]$rss.BaseProcessorNumber; queues=[int]$rss.NumberOfReceiveQueues }
            }
        }
        'bcdedit' {
            if ([string]$Action.args -match '^/deletevalue\s+(\S+)$') { $records += Get-BcdValueRecord $Matches[1] }
        }
        'optionalFeature' {
            $features = Get-OptionalFeatureStates
            foreach ($n in @($Action.names)) { if ($features.ContainsKey($n) -and $features[$n] -in 1,2) { $records += @{ kind='featureState'; path='optional'; name=$n; enabled=($features[$n] -eq 1) } } }
        }
        'appxStartup' { foreach ($item in @(Get-AppxStartupStates $Action.families)) { $records += Get-RegValueRecord -Path $item.Path -Name 'State' } }
        'dropdownState' { $records += @(Get-DropdownRecords $Action.id) }
        'powerSetting' { $r = Get-PowerIndexRecord $Action.setting $Action.sub; if ($r) { $r.scheme = Get-ActiveSchemeGuid; $records += $r } }
        { $_ -in 'coreparking','setCoreParking' } { $r = Get-PowerIndexRecord 'CPMINCORES'; if ($r) { $r.scheme = Get-ActiveSchemeGuid; $records += $r } }
        'svchost' { $records += Get-RegValueRecord -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' }
        'amdUlps' { foreach ($k in @(Get-AmdDisplayKeys)) { $records += Get-RegValueRecord -Path $k -Name 'EnableUlps' } }
        'netPower' {
            $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            foreach ($pm in @(Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue | Where-Object { $physical -contains $_.Name })) { $records += @{ kind='netPowerState'; path=$pm.Name; name='wake'; magic=[string]$pm.WakeOnMagicPacket; pattern=[string]$pm.WakeOnPattern } }
        }
        'netRss' { foreach ($r in @(Get-NetAdapterRss -ErrorAction SilentlyContinue)) { $records += @{ kind='netRssState'; path=$r.Name; name='rss'; enabled=[bool]$r.Enabled } } }
        'netRsc' { foreach ($r in @(Get-NetAdapterRsc -ErrorAction SilentlyContinue)) { $records += @{ kind='netRscState'; path=$r.Name; name='rsc'; v4=[bool]$r.IPv4Enabled; v6=[bool]$r.IPv6Enabled } } }
        'netbios' { foreach ($c in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction SilentlyContinue)) { $records += @{ kind='netbiosState'; path=[string]$c.SettingID; name=[string]$c.Description; value=[int]$c.TcpipNetbiosOptions } } }
        'teredo' { try { $tc = Get-NetTeredoConfiguration -ErrorAction Stop; $records += @{ kind='teredoState'; path='teredo'; name='type'; value=[string]$tc.Type } } catch { } }
        'usbPower' {
            try { foreach ($d in @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop)) { $records += @{ kind='usbPowerState'; path=[string]$d.InstanceName; name='enable'; enabled=[bool]$d.Enable } } } catch { }
        }
        'mmagent' { try { $m = Get-MMAgent -ErrorAction Stop; $records += @{ kind='mmAgent'; path='mmagent'; name=[string]$Action.feature; enabled=[bool]$m.($Action.feature) } } catch { } }
        'runkeyAll' { foreach ($e in @(Get-StartupEntries)) { $records += Get-RegValueRecord -Path $e.Approved -Name $e.Name } }
        'dxGlobal' { $records += Get-RegValueRecord -Path $script:DxPrefsPath -Name 'DirectXUserGlobalSettings' }
        'dxApp' { $records += Get-RegValueRecord -Path $script:DxPrefsPath -Name ([string]$Action.exe) }
        'qosGame' { $qn = 'Rion DSCP ' + [IO.Path]::GetFileNameWithoutExtension([string]$Action.exe); $records += @{ kind='qosPolicy'; path='qos'; name=$qn; exe=[string]$Action.exe; existed=[bool](Get-NetQosPolicy -Name $qn -ErrorAction SilentlyContinue) } }
        'powerMode' { $records += @{ kind='powerOverlay'; path='overlay'; name='ac'; value=(Get-ActivePowerOverlay) } }
        'throttleApp' { $state = Test-ThrottleExempt ([string]$Action.exe); if ($null -ne $state) { $records += @{ kind='throttleApp'; path='powerthrottling'; name=[string]$Action.exe; exempt=[bool]$state } } }
        'msiMode' { foreach ($t in @(Get-MsiTargets | Where-Object { -not $Action.instance -or $_.InstanceId -eq $Action.instance })) { $records += Get-RegValueRecord -Path $t.Path -Name 'MSISupported' } }
    }
    return @($records)
}
function Get-BcdValueRecord {
    param([string]$Name)
    $value = $null
    try {
        foreach ($line in @(& bcdedit.exe /enum '{current}' 2>$null)) {
            if ($line -match ('^\s*{0}\s+(\S.*?)\s*$' -f [regex]::Escape($Name))) { $value = $Matches[1]; break }
        }
    } catch { }
    return @{ kind='bcdValue'; path='{current}'; name=$Name; existed=($null -ne $value); value=$value }
}
function Get-PowerIndexRecord {
    param([string]$Alias,[string]$Sub = 'SUB_PROCESSOR')
    if ($script:PowerIndexCache) {
        $hit = $script:PowerIndexCache[$Alias.ToUpperInvariant()]; if (-not $hit) { $hit = $script:PowerIndexCache[$Alias.ToLowerInvariant()] }
        if ($hit -and $null -ne $hit.ac) { return @{ kind='powerIndex'; path=$Sub; name=$Alias; ac=[int]$hit.ac; dc=[int]$hit.dc } }
    }
    try {
        $hex = @([regex]::Matches((@(& powercfg.exe /qh SCHEME_CURRENT $Sub $Alias 2>$null) -join "`n"),'0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
        if ($hex.Count -ge 2) { return @{ kind='powerIndex'; path=$Sub; name=$Alias; ac=[Convert]::ToInt32($hex[-2],16); dc=[Convert]::ToInt32($hex[-1],16) } }
    } catch { }
    return $null
}
function Get-PowerDefaultIndex {
    param([string]$Sub,[string]$Setting)
    $scheme = [regex]::Match((@(& powercfg.exe /getactivescheme 2>$null) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value
    if (-not $scheme) { return $null }
    foreach ($p in @("HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes\$scheme\$Sub\$Setting","HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$Sub\$Setting\DefaultPowerSchemeValues\$scheme")) {
        $item = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
        if ($item -and $null -ne $item.ACSettingIndex -and $null -ne $item.DCSettingIndex) { return @{ ac=[int]$item.ACSettingIndex; dc=[int]$item.DCSettingIndex } }
    }
    return $null
}
$script:PowerApiSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class RionPowrProf {
    [DllImport("powrprof.dll")] static extern uint PowerEnumerate(IntPtr root, IntPtr scheme, IntPtr sub, uint access, uint index, byte[] buf, ref uint size);
    [DllImport("powrprof.dll")] static extern uint PowerReadFriendlyName(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, byte[] buf, ref uint size);
    [DllImport("powrprof.dll")] static extern uint PowerReadDescription(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, byte[] buf, ref uint size);
    [DllImport("powrprof.dll")] static extern uint PowerWriteFriendlyName(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, byte[] buf, uint size);
    [DllImport("powrprof.dll")] static extern uint PowerWriteDescription(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, byte[] buf, uint size);
    [DllImport("powrprof.dll")] static extern uint PowerReadPossibleFriendlyName(IntPtr root, IntPtr sub, IntPtr setting, uint index, byte[] buf, ref uint size);
    [DllImport("powrprof.dll")] static extern uint PowerReadValueUnitsSpecifier(IntPtr root, IntPtr sub, IntPtr setting, byte[] buf, ref uint size);
    [DllImport("powrprof.dll")] static extern uint PowerReadValueMin(IntPtr root, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerReadValueMax(IntPtr root, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerReadValueIncrement(IntPtr root, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerReadSettingAttributes(IntPtr sub, IntPtr setting);
    [DllImport("powrprof.dll")] static extern uint PowerWriteSettingAttributes(IntPtr sub, IntPtr setting, uint attr);
    [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, uint v);
    [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, IntPtr scheme, IntPtr sub, IntPtr setting, uint v);
    [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr active);
    [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, IntPtr scheme);
    [DllImport("powrprof.dll")] static extern uint PowerReadACDefaultIndex(IntPtr root, IntPtr personality, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerReadDCDefaultIndex(IntPtr root, IntPtr personality, IntPtr sub, IntPtr setting, out uint v);
    [DllImport("powrprof.dll")] static extern uint PowerGetEffectiveOverlayScheme(out Guid g);
    [DllImport("powrprof.dll")] static extern uint PowerSetActiveOverlayScheme(Guid g);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    delegate uint StrReader(byte[] buf, ref uint size);
    public static long[] DefaultValues(string personality, string sub, string setting) {
        IntPtr s = G(personality), u = G(sub), t = G(setting);
        try {
            uint ac, dc;
            if (PowerReadACDefaultIndex(IntPtr.Zero, s, u, t, out ac) != 0) { return null; }
            if (PowerReadDCDefaultIndex(IntPtr.Zero, s, u, t, out dc) != 0) { return null; }
            return new long[] { ac, dc };
        } finally { F(s, u, t); }
    }
    public static string Overlay() {
        Guid g;
        if (PowerGetEffectiveOverlayScheme(out g) != 0) { return null; }
        return g.ToString();
    }
    public static uint SetOverlay(string g) { return PowerSetActiveOverlayScheme(new Guid(g)); }
    static IntPtr G(string g) {
        if (String.IsNullOrEmpty(g)) { return IntPtr.Zero; }
        IntPtr p = Marshal.AllocHGlobal(16);
        Marshal.Copy(new Guid(g).ToByteArray(), 0, p, 16);
        return p;
    }
    static void F(params IntPtr[] ps) { foreach (IntPtr p in ps) { if (p != IntPtr.Zero) { Marshal.FreeHGlobal(p); } } }
    static byte[] W(string s) { return Encoding.Unicode.GetBytes((s ?? "") + "\0"); }
    static string S(StrReader r) {
        uint n = 0;
        r(null, ref n);
        if (n == 0) { return null; }
        byte[] b = new byte[n];
        if (r(b, ref n) != 0) { return null; }
        return Encoding.Unicode.GetString(b, 0, (int)n).TrimEnd('\0').Trim();
    }
    public static string[] Enumerate(string scheme, string sub, uint access) {
        List<string> r = new List<string>();
        IntPtr s = G(scheme), u = G(sub);
        try {
            for (uint i = 0; i < 4096; i++) {
                byte[] b = new byte[16]; uint n = 16;
                if (PowerEnumerate(IntPtr.Zero, s, u, access, i, b, ref n) != 0) { break; }
                r.Add(new Guid(b).ToString());
            }
        } finally { F(s, u); }
        return r.ToArray();
    }
    public static string Name(string scheme, string sub, string setting) {
        IntPtr s = G(scheme), u = G(sub), t = G(setting);
        try { return S(delegate(byte[] b, ref uint n) { return PowerReadFriendlyName(IntPtr.Zero, s, u, t, b, ref n); }); } finally { F(s, u, t); }
    }
    public static string Description(string scheme, string sub, string setting) {
        IntPtr s = G(scheme), u = G(sub), t = G(setting);
        try { return S(delegate(byte[] b, ref uint n) { return PowerReadDescription(IntPtr.Zero, s, u, t, b, ref n); }); } finally { F(s, u, t); }
    }
    public static uint SetName(string scheme, string text) {
        IntPtr s = G(scheme); byte[] b = W(text);
        try { return PowerWriteFriendlyName(IntPtr.Zero, s, IntPtr.Zero, IntPtr.Zero, b, (uint)b.Length); } finally { F(s); }
    }
    public static uint SetDescription(string scheme, string text) {
        IntPtr s = G(scheme); byte[] b = W(text);
        try { return PowerWriteDescription(IntPtr.Zero, s, IntPtr.Zero, IntPtr.Zero, b, (uint)b.Length); } finally { F(s); }
    }
    public static string[] Options(string sub, string setting) {
        List<string> r = new List<string>();
        IntPtr u = G(sub), t = G(setting);
        try {
            for (uint i = 0; i < 256; i++) {
                uint idx = i;
                string v = S(delegate(byte[] b, ref uint n) { return PowerReadPossibleFriendlyName(IntPtr.Zero, u, t, idx, b, ref n); });
                if (v == null) { break; }
                r.Add(v);
            }
        } finally { F(u, t); }
        return r.ToArray();
    }
    public static long[] Range(string sub, string setting) {
        IntPtr u = G(sub), t = G(setting);
        try {
            uint mn, mx, inc;
            if (PowerReadValueMin(IntPtr.Zero, u, t, out mn) != 0) { return null; }
            if (PowerReadValueMax(IntPtr.Zero, u, t, out mx) != 0) { return null; }
            if (PowerReadValueIncrement(IntPtr.Zero, u, t, out inc) != 0 || inc == 0) { inc = 1; }
            return new long[] { mn, mx, inc };
        } finally { F(u, t); }
    }
    public static string Units(string sub, string setting) {
        IntPtr u = G(sub), t = G(setting);
        try { return S(delegate(byte[] b, ref uint n) { return PowerReadValueUnitsSpecifier(IntPtr.Zero, u, t, b, ref n); }); } finally { F(u, t); }
    }
    public static long Attributes(string sub, string setting) {
        IntPtr u = G(sub), t = G(setting);
        try { return PowerReadSettingAttributes(u, t); } finally { F(u, t); }
    }
    public static uint SetAttributes(string sub, string setting, uint attr) {
        IntPtr u = G(sub), t = G(setting);
        try { return PowerWriteSettingAttributes(u, t, attr); } finally { F(u, t); }
    }
    public static long[] Values(string scheme, string sub, string setting) {
        IntPtr s = G(scheme), u = G(sub), t = G(setting);
        try {
            uint ac, dc;
            long a = PowerReadACValueIndex(IntPtr.Zero, s, u, t, out ac) == 0 ? (long)ac : -1;
            long d = PowerReadDCValueIndex(IntPtr.Zero, s, u, t, out dc) == 0 ? (long)dc : -1;
            return new long[] { a, d };
        } finally { F(s, u, t); }
    }
    public static uint WriteValue(string scheme, string sub, string setting, bool ac, uint v) {
        IntPtr s = G(scheme), u = G(sub), t = G(setting);
        try { return ac ? PowerWriteACValueIndex(IntPtr.Zero, s, u, t, v) : PowerWriteDCValueIndex(IntPtr.Zero, s, u, t, v); } finally { F(s, u, t); }
    }
    public static string ActiveScheme() {
        IntPtr p;
        if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0) { return null; }
        try { byte[] b = new byte[16]; Marshal.Copy(p, b, 0, 16); return new Guid(b).ToString(); } finally { LocalFree(p); }
    }
    public static uint SetActive(string scheme) {
        IntPtr s = G(scheme);
        try { return PowerSetActiveScheme(IntPtr.Zero, s); } finally { F(s); }
    }
}
'@
$script:PowerApiReady = $false
$script:PowerNoSubgroup = 'fea3413e-7e05-4911-9a71-700331f1c294'
$script:PowerGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:PowerJournalPath = Join-Path $script:DataDir 'powerplan-journal.json'
$script:PowerJournal = @{}
$script:PowerCatalog = $null
$script:PowerTemplates = [ordered]@{
    'Balanced'             = '381b4222-f694-41f0-9685-ff5bb260df2e'
    'High performance'     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    'Power saver'          = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    'Ultimate Performance' = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
}
$script:RionPlanName = "Rion's power plan"
$script:RionPlanDescription = 'True performance.'

function Initialize-PowerApi {
    if ($script:PowerApiReady) { return $true }
    if (-not ('RionPowrProf' -as [type])) {
        try { Add-Type -TypeDefinition $script:PowerApiSource -ErrorAction Stop }
        catch { Write-Log ("Power plan API could not load: {0}" -f $_.Exception.Message) 'Error'; return $false }
    }
    $script:PowerApiReady = $true
    return $true
}

function Invoke-PowerCfg {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode=$proc.ExitCode; Output=$out.Trim(); Error=(($err + ' ' + $(if ($proc.ExitCode -ne 0) { $out } else { '' })).Trim()) }
}

function ConvertTo-PowerUInt {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int]) { return [long][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value),0) }
    return [long]$Value
}

function Read-PowerJournal {
    $script:PowerJournal = @{}
    try {
        if (-not (Test-Path -LiteralPath $script:PowerJournalPath)) { return }
        $raw = Get-Content -LiteralPath $script:PowerJournalPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $script:PowerJournal[$p.Name] = $p.Value }
    } catch { Write-Log ("Could not read the power plan journal: {0}" -f $_.Exception.Message) 'Warn' }
}

function Save-PowerJournal {
    try { $script:PowerJournal | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:PowerJournalPath -Encoding UTF8 }
    catch { Write-Log ("Could not save the power plan journal: {0}" -f $_.Exception.Message) 'Warn' }
}

function Get-PowerPlans {
    if (-not (Initialize-PowerApi)) { return @() }
    $active = [RionPowrProf]::ActiveScheme()
    foreach ($g in [RionPowrProf]::Enumerate($null,$null,16)) {
        [pscustomobject]@{ Guid=$g; Name=[string][RionPowrProf]::Name($g,$null,$null); Description=[string][RionPowrProf]::Description($g,$null,$null); Active=($g -eq $active) }
    }
}

function Find-PowerPlan {
    param([string]$Name)
    return (@(Get-PowerPlans) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Set-PowerPlanText {
    param([string]$Guid,[string]$Name,[string]$Description,[switch]$NoJournal)
    if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
    if (-not $Name.Trim()) { throw 'A power plan needs a name.' }
    $jk = "text|$Guid"
    $existing = $script:PowerJournal[$jk]
    if (-not $NoJournal -and -not ($existing -and $existing.name)) {
        $script:PowerJournal[$jk] = @{ name=[string][RionPowrProf]::Name($Guid,$null,$null); description=[string][RionPowrProf]::Description($Guid,$null,$null); created=[bool]($existing -and $existing.created) }
        Save-PowerJournal
    }
    [void][RionPowrProf]::SetName($Guid,$Name)
    [void][RionPowrProf]::SetDescription($Guid,$Description)
    if ([string][RionPowrProf]::Name($Guid,$null,$null) -cne $Name -or [string][RionPowrProf]::Description($Guid,$null,$null) -cne $Description.Trim()) {
        [void](Invoke-PowerCfg @('-changename',$Guid,$Name,$Description))
    }
    $readName = [string][RionPowrProf]::Name($Guid,$null,$null)
    if ($readName -cne $Name) { throw ("Windows kept the name '{0}' instead of '{1}'." -f $readName,$Name) }
    if ([string][RionPowrProf]::Description($Guid,$null,$null) -cne $Description.Trim()) { throw 'Windows did not save the new description.' }
}

function Copy-PowerPlan {
    param([string]$SourceGuid,[string]$Name,[string]$Description)
    $r = Invoke-PowerCfg @('-duplicatescheme',$SourceGuid)
    $g = [regex]::Match($r.Output,$script:PowerGuidPattern).Value
    if ($r.ExitCode -ne 0 -or -not $g) { return $null }
    $script:PowerJournal["source|$g"] = $SourceGuid
    $script:PowerJournal["text|$g"] = @{ created=$true }
    Save-PowerJournal
    if ($Name) { Set-PowerPlanText -Guid $g -Name $Name -Description $Description -NoJournal }
    return $g
}

function Set-ActivePowerPlan {
    param([string]$Guid)
    if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
    if ([RionPowrProf]::SetActive($Guid) -ne 0) { [void](Invoke-PowerCfg @('-setactive',$Guid)) }
    if ([RionPowrProf]::ActiveScheme() -ne $Guid) { throw ("Windows did not switch to power plan {0}." -f $Guid) }
}

function Install-RionPowerPlan {
    if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
    $plan = Find-PowerPlan $script:RionPlanName
    $guid = if ($plan) { [string]$plan.Guid } else { $null }
    if ($guid) {
        if ([string]$plan.Description -cne $script:RionPlanDescription) { Set-PowerPlanText -Guid $guid -Name $script:RionPlanName -Description $script:RionPlanDescription -NoJournal }
    } else {
        $sources = @($script:PowerTemplates['Ultimate Performance'],$script:PowerTemplates['High performance'],[RionPowrProf]::ActiveScheme()) | Where-Object { $_ } | Select-Object -Unique
        foreach ($src in $sources) {
            $guid = Copy-PowerPlan -SourceGuid $src -Name $script:RionPlanName -Description $script:RionPlanDescription
            if ($guid) {
                if ($src -ne $script:PowerTemplates['Ultimate Performance']) { Write-Log ("The Ultimate Performance template is not available on this PC (Modern Standby systems hide it), so Rion's power plan was copied from '{0}'." -f [RionPowrProf]::Name($src,$null,$null)) 'Warn' }
                break
            }
        }
    }
    if (-not $guid) { throw 'Windows refused to create a new power plan.' }
    Set-ActivePowerPlan $guid
    $check = [string][RionPowrProf]::Name($guid,$null,$null)
    if ($check -cne $script:RionPlanName) { throw ("The plan was created but Windows shows it as '{0}'." -f $check) }
    Write-Log ("{0} is active and named correctly ({1})." -f $script:RionPlanName,$guid) 'Success'
    return $guid
}

function Get-PowerSettingCatalog {
    param([switch]$Refresh)
    if ($script:PowerCatalog -and -not $Refresh) { return $script:PowerCatalog }
    if (-not (Initialize-PowerApi)) { return @() }
    $scheme = [RionPowrProf]::ActiveScheme()
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $pairs = New-Object System.Collections.Generic.List[object]
    $subs = @($script:PowerNoSubgroup) + @([RionPowrProf]::Enumerate($scheme,$null,17) | Where-Object { $_ -ne $script:PowerNoSubgroup })
    foreach ($sub in $subs) { foreach ($set in [RionPowrProf]::Enumerate($scheme,$sub,18)) { $pairs.Add(@($sub,$set,'api')) } }
    $regRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Power\PowerSettings')
    if ($regRoot) {
        try {
            foreach ($top in $regRoot.GetSubKeyNames()) {
                if ($top -notmatch ('^' + $script:PowerGuidPattern + '$')) { continue }
                $k = $regRoot.OpenSubKey($top)
                if (-not $k) { continue }
                $kids = @($k.GetSubKeyNames())
                $children = @($kids | Where-Object { $_ -match ('^' + $script:PowerGuidPattern + '$') })
                $isSetting = ($null -ne $k.GetValue('ValueMax')) -or ($kids -contains 'DefaultPowerSchemeValues') -or @($kids | Where-Object { $_ -match '^\d+$' }).Count
                $k.Close()
                if ($children.Count) { foreach ($c in $children) { $pairs.Add(@($top.ToLower(),$c.ToLower(),'registry')) } }
                elseif ($isSetting) { $pairs.Add(@($script:PowerNoSubgroup,$top.ToLower(),'registry')) }
            }
        } finally { $regRoot.Close() }
    }
    $subNames = @{}
    foreach ($pair in $pairs) {
        $sub = [string]$pair[0]; $set = [string]$pair[1]
        if ($seen.ContainsKey("$sub|$set")) { continue }
        $seen["$sub|$set"] = $true
        if (-not $subNames.ContainsKey($sub)) {
            $sn = if ($sub -eq $script:PowerNoSubgroup) { 'General' } else { [string][RionPowrProf]::Name($null,$sub,$null) }
            $subNames[$sub] = @{ Name=$(if ($sn) { $sn } else { "Unnamed subgroup $sub" }); Attr=$(if ($sub -eq $script:PowerNoSubgroup) { 0 } else { [RionPowrProf]::Attributes($sub,$null) }) }
        }
        $subAttr = $subNames[$sub].Attr
        $name = [string][RionPowrProf]::Name($null,$sub,$set)
        if (-not $name) { $name = "Unnamed setting $set" }
        $range = [RionPowrProf]::Range($sub,$set)
        $options = if ($range) { @() } else { @([RionPowrProf]::Options($sub,$set)) }
        $attr = [RionPowrProf]::Attributes($sub,$set)
        $list.Add([pscustomobject]@{
            Sub=$sub; SubName=$subNames[$sub].Name; Guid=$set; Name=$name; Source=$pair[2]
            Description=[string][RionPowrProf]::Description($null,$sub,$set)
            Attributes=$attr; SubAttributes=$subAttr; Hidden=[bool](($attr -band 1) -or ($subAttr -band 1))
            Min=$(if ($range) { $range[0] } else { $null }); Max=$(if ($range) { $range[1] } else { $null }); Increment=$(if ($range) { $range[2] } else { 1 })
            Units=$(if ($range) { [string][RionPowrProf]::Units($sub,$set) } else { '' })
            Options=$options
        })
    }
    $script:PowerCatalog = $list.ToArray()
    return $script:PowerCatalog
}

function Get-PowerPlanBase {
    param([string]$Plan)
    if ($Plan -in @($script:PowerTemplates.Values)) { return $Plan }
    $src = [string]$script:PowerJournal["source|$Plan"]
    $hops = 0
    while ($src -and $src -notin @($script:PowerTemplates.Values) -and $hops -lt 8) { $src = [string]$script:PowerJournal["source|$src"]; $hops++ }
    if ($src -in @($script:PowerTemplates.Values)) { return $src }
    $p = [RionPowrProf]::Values($Plan,$script:PowerNoSubgroup,'245d8541-3943-4422-b025-13a784f679b7')
    switch ([int]$p[0]) { 0 { return $script:PowerTemplates['Power saver'] } 1 { return $script:PowerTemplates['High performance'] } default { return $script:PowerTemplates['Balanced'] } }
}

function Get-PowerSettingDefault {
    param([string]$Base,[string]$Sub,[string]$Setting)
    $root = 'SYSTEM\CurrentControlSet\Control\Power'
    $setKey = if ($Sub -eq $script:PowerNoSubgroup) { "$root\PowerSettings\$Setting" } else { "$root\PowerSettings\$Sub\$Setting" }
    $userKey = if ($Sub -eq $script:PowerNoSubgroup) { "$root\User\Default\PowerSchemes\$Base\$Setting" } else { "$root\User\Default\PowerSchemes\$Base\$Sub\$Setting" }
    foreach ($k in @($userKey,"$setKey\DefaultPowerSchemeValues\$Base")) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($k)
        if (-not $key) { continue }
        try {
            $ac = $key.GetValue('ACSettingIndex'); $dc = $key.GetValue('DCSettingIndex')
            if ($null -ne $ac -and $null -ne $dc) { return @((ConvertTo-PowerUInt $ac),(ConvertTo-PowerUInt $dc)) }
        } finally { $key.Close() }
    }
    $api = [RionPowrProf]::DefaultValues($Base,$Sub,$Setting)
    if ($api) { return @($api[0],$api[1]) }
    return $null
}

$script:PowerModes = [ordered]@{
    'Best power efficiency' = '961cc777-2547-4f9d-8174-7d86181b8a7a'
    'Balanced'              = '00000000-0000-0000-0000-000000000000'
    'Best performance'      = 'ded574b5-45a0-4f42-8737-46345c09c238'
}

function Set-PowerMode {
    param([string]$Guid)
    if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
    $cur = [RionPowrProf]::Overlay()
    if (-not $script:PowerJournal.ContainsKey('overlay')) { $script:PowerJournal['overlay'] = $cur; Save-PowerJournal }
    if ([RionPowrProf]::SetOverlay($Guid) -ne 0 -or [RionPowrProf]::Overlay() -ne $Guid) { throw 'Windows did not accept the new power mode.' }
}

function Set-PowerSettingValue {
    param([string]$Plan,[string]$Sub,[string]$Setting,[long]$Ac,[long]$Dc,[switch]$NoJournal)
    $cur = [RionPowrProf]::Values($Plan,$Sub,$Setting)
    $jk = "value|$Plan|$Sub|$Setting"
    if (-not $NoJournal -and -not $script:PowerJournal.ContainsKey($jk)) { $script:PowerJournal[$jk] = @{ ac=$cur[0]; dc=$cur[1] } }
    foreach ($side in @(@{ ac=$true; want=$Ac; have=$cur[0]; flag='-setacvalueindex' },@{ ac=$false; want=$Dc; have=$cur[1]; flag='-setdcvalueindex' })) {
        if ($side.want -lt 0 -or $side.want -eq $side.have) { continue }
        if ([RionPowrProf]::WriteValue($Plan,$Sub,$Setting,$side.ac,[uint32]$side.want) -ne 0) {
            $r = Invoke-PowerCfg @($side.flag,$Plan,$Sub,$Setting,[string]$side.want)
            if ($r.ExitCode -ne 0) { return $r.Error }
        }
    }
    $after = [RionPowrProf]::Values($Plan,$Sub,$Setting)
    if (($Ac -ge 0 -and $after[0] -ne $Ac) -or ($Dc -ge 0 -and $after[1] -ne $Dc)) { return 'Windows did not keep the new value.' }
    return $null
}

function Update-ActivePowerPlan {
    param([string]$Plan)
    if ([RionPowrProf]::ActiveScheme() -eq $Plan) { [void][RionPowrProf]::SetActive($Plan) }
}

function Restore-PowerPlanChanges {
    param([string]$Plan)
    $failed = 0; $restored = 0
    foreach ($k in @($script:PowerJournal.Keys | Where-Object { $_ -like "value|$Plan|*" })) {
        $parts = $k -split '\|'
        $v = $script:PowerJournal[$k]
        $err = Set-PowerSettingValue -Plan $Plan -Sub $parts[2] -Setting $parts[3] -Ac ([long]$v.ac) -Dc ([long]$v.dc) -NoJournal
        if ($err) { $failed++ } else { $restored++; $script:PowerJournal.Remove($k) }
    }
    $tk = "text|$Plan"
    if ($script:PowerJournal.ContainsKey($tk) -and $script:PowerJournal[$tk].name) {
        try { Set-PowerPlanText -Guid $Plan -Name ([string]$script:PowerJournal[$tk].name) -Description ([string]$script:PowerJournal[$tk].description) -NoJournal; $script:PowerJournal.Remove($tk) } catch { $failed++ }
    }
    Save-PowerJournal
    Update-ActivePowerPlan $Plan
    return @{ Restored=$restored; Failed=$failed }
}

function Set-PowerSettingsVisibility {
    param([bool]$Show)
    $changed = 0
    $targets = @{}
    foreach ($d in @(Get-PowerSettingCatalog)) {
        $targets["$($d.Sub)|$($d.Guid)"] = @{ Sub=$d.Sub; Setting=$d.Guid }
        if ($d.Sub -ne $script:PowerNoSubgroup) { $targets["$($d.Sub)|"] = @{ Sub=$d.Sub; Setting=$null } }
    }
    foreach ($key in $targets.Keys) {
        $t = $targets[$key]
        $jk = "attr|$key"
        if ($Show) {
            $attr = [RionPowrProf]::Attributes($t.Sub,$t.Setting)
            if (-not ($attr -band 1)) { continue }
            if (-not $script:PowerJournal.ContainsKey($jk)) { $script:PowerJournal[$jk] = $attr }
            if ([RionPowrProf]::SetAttributes($t.Sub,$t.Setting,[uint32](($attr -band 0xFFFFFFFE) -bor 2)) -eq 0) { $changed++ }
        } elseif ($script:PowerJournal.ContainsKey($jk)) {
            if ([RionPowrProf]::SetAttributes($t.Sub,$t.Setting,[uint32]$script:PowerJournal[$jk]) -eq 0) { $changed++; $script:PowerJournal.Remove($jk) }
        }
    }
    Save-PowerJournal
    [void](Get-PowerSettingCatalog -Refresh)
    return $changed
}

$script:DxPrefsPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
function Get-DxGlobalSetting {
    param([string]$Name)
    $raw = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    foreach ($pair in ($raw -split ';')) { $kv = $pair -split '=',2; if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $Name) { return $kv[1].Trim() } }
    return $null
}
function Set-DxGlobalSetting {
    param([string]$Name,$Value)
    $raw = [string](Get-ItemProperty -LiteralPath $script:DxPrefsPath -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    $pairs = @($raw -split ';' | Where-Object { $_.Trim() -and ($_ -split '=',2)[0].Trim() -ne $Name })
    if ($null -ne $Value) { $pairs += ('{0}={1}' -f $Name,$Value) }
    if ($pairs.Count) { Set-RegValue -Path $script:DxPrefsPath -Name 'DirectXUserGlobalSettings' -Value ((($pairs | ForEach-Object { $_.Trim() }) -join ';') + ';') -Type String }
    else { Remove-RegValue -Path $script:DxPrefsPath -Name 'DirectXUserGlobalSettings' }
}
function Get-RecognizedGames {
    $games = @()
    $winDir = $env:SystemRoot
    foreach ($k in @(Get-ChildItem 'HKCU:\System\GameConfigStore\Children' -ErrorAction SilentlyContinue)) {
        $exe = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name 'MatchedExeFullPath' -ErrorAction SilentlyContinue).MatchedExeFullPath
        if (-not $exe -or $exe -notmatch '(?i)\.exe$' -or $exe.StartsWith($winDir,[StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        if (@($games | Where-Object { $_.Path -eq $exe }).Count) { continue }
        $games += @{ Path=$exe; Name=[IO.Path]::GetFileName($exe) }
    }
    $known = @()
    try {
        $ri = Get-Content -LiteralPath (Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $vl = [string]$ri.product_install_full_path.'valorant.live'
        if ($vl) { $known += (Join-Path (Split-Path $vl) 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') }
    } catch { }
    foreach ($root in @("$env:ProgramFiles\Riot Games",'C:\Riot Games')) { $known += (Join-Path $root 'VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') }
    foreach ($root in @("$env:ProgramFiles\Epic Games","${env:ProgramFiles(x86)}\Epic Games")) { $known += (Join-Path $root 'Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe') }
    foreach ($exe in $known) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        if (@($games | Where-Object { $_.Path -eq $exe }).Count) { continue }
        $games += @{ Path=$exe; Name=[IO.Path]::GetFileName($exe) }
    }
    return $games
}
function Get-DxAppSetting {
    param([string]$Exe,[string]$Name)
    $raw = [string](Get-ItemProperty -LiteralPath $script:DxPrefsPath -Name $Exe -ErrorAction SilentlyContinue).$Exe
    foreach ($pair in ($raw -split ';')) { $kv = $pair -split '=',2; if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $Name) { return $kv[1].Trim() } }
    return $null
}
function Set-DxAppSetting {
    param([string]$Exe,[string]$Name,$Value)
    $raw = [string](Get-ItemProperty -LiteralPath $script:DxPrefsPath -Name $Exe -ErrorAction SilentlyContinue).$Exe
    $pairs = @($raw -split ';' | Where-Object { $_.Trim() -and ($_ -split '=',2)[0].Trim() -ne $Name })
    if ($null -ne $Value) { $pairs += ('{0}={1}' -f $Name,$Value) }
    if ($pairs.Count) { Set-RegValue -Path $script:DxPrefsPath -Name $Exe -Value ((($pairs | ForEach-Object { $_.Trim() }) -join ';') + ';') -Type String }
    else { Remove-RegValue -Path $script:DxPrefsPath -Name $Exe }
}
function Get-ThrottleExemptions {
    if ($null -ne $script:ThrottleExemptCache) { return $script:ThrottleExemptCache }
    $r = Invoke-PowerCfg @('/powerthrottling','list')
    $script:ThrottleExemptCache = if ($r.ExitCode -eq 0) { [string]$r.Output } else { $null }
    return $script:ThrottleExemptCache
}
function Test-ThrottleExempt {
    param([string]$Exe)
    $list = Get-ThrottleExemptions
    if ($null -eq $list) { return $null }
    return ($list.IndexOf($Exe,[StringComparison]::OrdinalIgnoreCase) -ge 0)
}
function Get-ActivePowerOverlay {
    $v = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActiveOverlayAcPowerScheme' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
    if (-not $v) { return '00000000-0000-0000-0000-000000000000' }
    return $v.ToLowerInvariant()
}
function Get-RatedMemorySpeed {
    param([string]$PartNumber)
    $p = ([string]$PartNumber).Trim().ToUpperInvariant()
    foreach ($m in [regex]::Matches($p,'(?<!\d)(\d{4})(?!\d)')) { $n = [int]$m.Groups[1].Value; if ($n -ge 2133 -and $n -le 9600) { return $n } }
    if ($p -match '^KF[345](\d{2})[A-Z]') { $n = [int]$Matches[1] * 100; if ($n -ge 2133 -and $n -le 9600) { return $n } }
    if ($p -match '^KVR(\d{2})[A-Z]') { $n = [int]$Matches[1] * 100; if ($n -ge 2133 -and $n -le 9600) { return $n } }
    if ($p -match '^CT\d+G(\d{2})C\d{2}') { $n = [int]$Matches[1] * 100; if ($n -ge 2133 -and $n -le 9600) { return $n } }
    if ($p -match '^BL\w*G[45]D(\d{2})') { $n = [int]$Matches[1] * 100; if ($n -ge 2133 -and $n -le 9600) { return $n } }
    return $null
}
function Get-MemoryConfigReport {
    $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if (-not $sticks.Count) { return $null }
    $issues = @()
    $configured = [int](@($sticks | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Measure-Object -Minimum).Minimum)
    $type = [int]$sticks[0].SMBIOSMemoryType
    $ddr = switch ($type) { 34 { 'DDR5' } 26 { 'DDR4' } 24 { 'DDR3' } default { 'RAM' } }
    $rated = @($sticks | ForEach-Object { Get-RatedMemorySpeed ([string]$_.PartNumber) } | Where-Object { $_ } | Measure-Object -Minimum).Minimum
    $totalGB = [math]::Round((@($sticks | Measure-Object -Property Capacity -Sum).Sum)/1GB)
    $channels = @($sticks | ForEach-Object { $t = ('{0} {1}' -f $_.BankLabel,$_.DeviceLocator); if ($t -match '(?i)CHANNEL\s*([A-H])') { $Matches[1].ToUpperInvariant() } elseif ($t -match '(?i)Channel([A-H])') { $Matches[1].ToUpperInvariant() } } | Select-Object -Unique)
    if ($sticks.Count -eq 1) { $issues += ('Only one memory stick is installed, so the memory runs in single-channel mode with half the bandwidth. Add a matching second stick (or use a two-stick kit) in the slots your board manual marks for two modules, usually A2 and B2.') }
    elseif ($channels.Count -eq 1 -and $sticks.Count -ge 2) { $issues += ('All memory sticks sit in the same channel ({0}), so they run single-channel. Move them to the slots your board manual marks for two modules, usually A2 and B2.' -f $channels[0]) }
    if ($rated -and $configured -and $configured -lt ([int]$rated - 100)) { $issues += ('The memory is rated for {0} MT/s but runs at {1} MT/s: EXPO (AMD) or XMP (Intel) is off in BIOS. Turn on the EXPO/XMP profile.' -f $rated,$configured) }
    elseif (-not $rated -and (($type -eq 34 -and $configured -le 4800) -or ($type -eq 26 -and $configured -le 2666))) { $issues += ('The memory runs at {0} MT/s, the {1} default. If your kit is rated faster (see the sticker or box), turn on EXPO/XMP in BIOS.' -f $configured,$ddr) }
    $summary = '{0} GB {1}, {2} stick(s), {3} MT/s' -f $totalGB,$ddr,$sticks.Count,$configured
    if ($rated) { $summary += (', rated {0} MT/s' -f $rated) }
    return @{ Summary=$summary; Issues=$issues }
}
function Get-GamesOnHdd {
    $hits = @()
    foreach ($g in @(Get-RecognizedGames)) {
        try {
            $letter = $g.Path.Substring(0,1)
            $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
            if ($pd -and [string]$pd.MediaType -eq 'HDD') { $hits += ('{0} ({1}:)' -f $g.Name,$letter) }
        } catch { }
    }
    return $hits
}
function Get-MsiIrqMap {
    $map = @{}
    try {
        foreach ($r in @(Get-WmiObject Win32_PnPAllocatedResource -ErrorAction Stop | Where-Object { $_.Antecedent -like '*Win32_IRQResource*' })) {
            if ($r.Antecedent -notmatch 'IRQNumber=(\d+)') { continue }
            $n = [int64]$Matches[1]; if ($n -gt 2147483647) { $n = $n - 4294967296 }
            if ($r.Dependent -notmatch 'DeviceID="(.+)"') { continue }
            $id = ($Matches[1] -replace '\\\\','\').ToUpperInvariant()
            if (-not $map.ContainsKey($id)) { $map[$id] = @() }
            $map[$id] += $n
        }
    } catch { }
    return $map
}
function Get-MsiTargets {
    param([switch]$WithMode)
    $targets = @()
    $nicIds = @()
    try { $nicIds = @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object { ([string]$_.PnPDeviceID).ToUpperInvariant() }) } catch { }
    $devices = @()
    for ($try = 0; $try -lt 3 -and -not $devices.Count; $try++) { try { $devices = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display' OR PNPClass='Net'" -ErrorAction Stop | Where-Object { [string]$_.PNPDeviceID -like 'PCI\*' -and $_.ConfigManagerErrorCode -eq 0 -and ($_.PNPClass -eq 'Display' -or $nicIds -contains ([string]$_.PNPDeviceID).ToUpperInvariant()) }) } catch { Start-Sleep -Milliseconds 150 } }
    if (-not $devices.Count) { return $targets }
    $support = @{}
    for ($try = 0; $try -lt 3 -and -not $support.Count; $try++) {
        try { foreach ($pr in @(Get-PnpDeviceProperty -InstanceId @($devices | ForEach-Object { [string]$_.PNPDeviceID }) -KeyName 'DEVPKEY_PciDevice_InterruptSupport' -ErrorAction Stop)) { if ($null -ne $pr.Data) { $support[([string]$pr.InstanceId).ToUpperInvariant()] = [int]$pr.Data } } } catch { Start-Sleep -Milliseconds 150 }
    }
    $irqMap = if ($WithMode) { Get-MsiIrqMap } else { @{} }
    foreach ($dev in $devices) {
        $id = [string]$dev.PNPDeviceID
        $driverSvc = ''
        try { $driverSvc = [string](Get-RegValueFast ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id) 'Service').Value } catch { }
        if (-not $driverSvc -or $driverSvc -match '(?i)^BasicDisplay$|^BasicRender$') { continue }
        $sup = $support[$id.ToUpperInvariant()]
        if ($null -eq $sup -or -not ($sup -band 6)) { continue }
        $mode = ''
        if ($WithMode) {
            $irqs = @($irqMap[$id.ToUpperInvariant()])
            $mode = if (-not $irqs.Count) { 'mode unknown' } elseif (@($irqs | Where-Object { $_ -lt 0 }).Count) { 'MSI in use' } else { 'line-based in use' }
        }
        $targets += @{ Name=[string]$dev.Name; Class=[string]$dev.PNPClass; InstanceId=$id; Driver=$driverSvc; Mode=$mode; Path=('HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties' -f $id) }
    }
    return $targets
}function Get-DnsRecords {
    $records = @()
    foreach ($ad in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $servers = @()
        foreach ($stack in 'Tcpip','Tcpip6') {
            try {
                $ns = [string](Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters\Interfaces\{1}" -f $stack,$ad.InterfaceGuid) -Name NameServer -ErrorAction Stop).NameServer
                $servers += @($ns -split '[,\s]+' | Where-Object { $_ })
            } catch { }
        }
        $records += @{ kind='dnsServers'; path=[string]$ad.InterfaceGuid; name=[string]$ad.ifIndex; servers=@($servers) }
    }
    return $records
}
function Get-DropdownRecords {
    param([string]$Id)
    $records = @()
    switch ($Id) {
        { $_ -in 'net.dns','net.doh' } { $records += Get-DnsRecords }
        'net.autotune' {
            try { $records += @{ kind='tcpAutoTune'; path='global'; name='autotuninglevel'; value=[string](Get-NetTCPSetting -SettingName Internet -ErrorAction Stop).AutoTuningLevelLocal } } catch { }
        }
        'net.qos.bandwidth' { $records += Get-RegValueRecord -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DOPercentageMaxBackgroundBandwidth' }
        'gpu.hags' { $records += Get-RegValueRecord -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' }
        'gpu.gamemode' { foreach ($n in 'AutoGameModeEnabled','AllowAutoGameMode') { $records += Get-RegValueRecord -Path 'HKCU:\Software\Microsoft\GameBar' -Name $n } }
        'cpu.plan' {
            $active = [regex]::Match((@(& powercfg.exe /getactivescheme 2>$null) -join ' '),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
            if ($active.Success) { $records += @{ kind='powerScheme'; path='active'; name='scheme'; guid=$active.Value } }
        }
        'cpu.boost' { $r = Get-PowerIndexRecord 'PERFBOOSTMODE'; if ($r) { $records += $r } }
        'sec.vbs' {
            $deviceGuard = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
            foreach ($n in 'EnableVirtualizationBasedSecurity','RequirePlatformSecurityFeatures','Locked') { $records += Get-RegValueRecord -Path $deviceGuard -Name $n }
            foreach ($n in 'Enabled','Locked','WasEnabledBy') { $records += Get-RegValueRecord -Path "$deviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name $n }
            foreach ($n in 'hypervisorlaunchtype','vsmlaunchtype') { $records += Get-BcdValueRecord $n }
        }
    }
    return @($records)
}
function Test-RecordAtTarget {
    param($Record,$Action)
    switch ($Action.kind) {
        'mpPreference' { return ($Record.kind -eq 'mpPref' -and [int]$Record.value -eq [int]$Action.value) }
        'service' { return ($Record.kind -eq 'svcStart' -and [int]$Record.start -eq [int]$script:StartMap[[string]$Action.start]) }
        'registry' {
            if ($Record.kind -ne 'regValue' -or -not $Record.existed) { return $false }
            $current = if ($Record.value -is [array]) { @($Record.value) -join "`n" } else { [string]$Record.value }
            $target = if ($Action.value -is [array]) { @($Action.value) -join "`n" } else { [string]$Action.value }
            return ($current -eq $target)
        }
        'registryDel' { return ($Record.kind -eq 'regValue' -and -not $Record.existed) }
        'optionalFeature' { return ($Record.kind -eq 'featureState' -and [bool]$Record.enabled -eq [bool]$Action.enable) }
        'appxStartup' { return ($Record.kind -eq 'regValue' -and $Record.existed -and $(if ($Action.enable) { [int]$Record.value -eq 2 } else { [int]$Record.value -ne 2 })) }
        'powerSetting' { return ($Record.kind -eq 'powerIndex' -and [int]$Record.ac -eq [int]$Action.value -and ($Action.acOnly -or [int]$Record.dc -eq [int]$Action.value)) }
        'mmagent' { return ($Record.kind -eq 'mmAgent' -and [bool]$Record.enabled -eq [bool]$Action.enable) }
        'dxGlobal' { return ((Get-DxGlobalSetting $Action.name) -eq [string]$Action.value) }
        'dxApp' { return ((Get-DxAppSetting ([string]$Action.exe) $Action.name) -eq [string]$Action.value) }
        'qosGame' { return ($Record.kind -eq 'qosPolicy' -and [bool]$Record.existed -eq [bool]$Action.enable) }
        'powerMode' { return ($Record.kind -eq 'powerOverlay' -and [string]$Record.value -eq ([string]$Action.guid).ToLowerInvariant()) }
        'throttleApp' { return ($Record.kind -eq 'throttleApp' -and [bool]$Record.exempt -eq [bool]$Action.exempt) }
        'msiMode' { return ($Record.kind -eq 'regValue' -and $Record.existed -and [string]$Record.value -eq '1') }
    }
    return $false
}
function Save-OriginalRecords {
    param([string]$Id,$Actions)
    $script:SvcStartCache = $null; $script:PowerIndexCache = $null; $script:NetPropCache = $null
    $changed = $false
    foreach ($action in @($Actions)) {
        foreach ($record in @(Get-OriginalRecords $action)) {
            if (Test-RecordAtTarget $record $action) { $record = $record.Clone(); $record['untouched'] = $true }
            if (-not $script:Journal.ContainsKey($Id)) { $script:Journal[$Id] = @() }
            $list = [System.Collections.ArrayList]@($script:Journal[$Id])
            $key = Get-RecordKey $record
            $existing = @($list | Where-Object { (Get-RecordKey $_) -eq $key }) | Select-Object -First 1
            if (-not $existing) {
                [void]$list.Add($record)
                $script:Journal[$Id] = @($list)
                $changed = $true
            } elseif ($existing.untouched -and -not $record['untouched']) {
                $list[$list.IndexOf($existing)] = $record
                $script:Journal[$Id] = @($list)
                $changed = $true
            }
        }
    }
    if ($changed -and -not (Save-Journal)) { throw 'The original values could not be saved, so this setting was not changed (it could not be undone otherwise).' }
}
function Clear-Journal {
    param([string]$Id)
    if ($script:Journal.ContainsKey($Id)) { [void]$script:Journal.Remove($Id); [void](Save-Journal) }
}
function Restore-OriginalRecord {
    param($Record)
    switch ($Record.kind) {
        'regValue' {
            if (-not $Record.existed) { Remove-RegValue -Path $Record.path -Name $Record.name; return }
            $value = switch ([string]$Record.type) {
                'DWord'  { [int]$Record.value }
                'QWord'  { [long]$Record.value }
                'Binary' { [byte[]]@($Record.value) }
                default  { $Record.value }
            }
            Set-RegValue -Path $Record.path -Name $Record.name -Value $value -Type ([string]$Record.type)
        }
        'svcStart' {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Record.name)"
            if (Test-Path -LiteralPath $key) {
                Set-ServiceStartNow -Name $Record.name -Start ([int]$Record.start)
            }
        }
        'taskState' {
            if ($Record.enabled) { Enable-ScheduledTask -TaskPath $Record.path -TaskName $Record.name -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $Record.path -TaskName $Record.name -ErrorAction Stop | Out-Null }
        }
        'netState' {
            if (Get-NetAdapter -Name $Record.name -ErrorAction SilentlyContinue) {
                if ($Record.enabled) { Enable-NetAdapter -Name $Record.name -Confirm:$false -ErrorAction Stop }
                else { Disable-NetAdapter -Name $Record.name -Confirm:$false -ErrorAction Stop }
            }
        }
        'netAdvProp' {
            if (Get-NetAdapter -Name $Record.path -ErrorAction SilentlyContinue) {
                Set-NetAdapterAdvancedProperty -Name $Record.path -DisplayName $Record.name -DisplayValue ([string]$Record.value) -NoRestart -ErrorAction Stop
            }
        }
        'netRssCfg' {
            if (Get-NetAdapter -Name $Record.path -ErrorAction SilentlyContinue) {
                Set-NetAdapterRss -Name $Record.path -Profile ([string]$Record.profile) -BaseProcessorNumber ([uint16]$Record.base) -NumberOfReceiveQueues ([uint32]$Record.queues) -ErrorAction Stop
            }
        }
        'bcdValue' {
            if ($Record.existed) { $out = & bcdedit.exe /set $Record.path $Record.name ([string]$Record.value) 2>&1 }
            else { $out = & bcdedit.exe /deletevalue $Record.path $Record.name 2>&1 }
            if ($Record.existed -and $LASTEXITCODE -ne 0) { throw ("bcdedit could not restore {0}={1}: {2}" -f $Record.name,$Record.value,((@($out) -join ' ').Trim())) }
        }
        'powerIndex' {
            $sch = if ($Record.scheme) { [string]$Record.scheme } else { 'SCHEME_CURRENT' }
            & powercfg.exe -setacvalueindex $sch $Record.path $Record.name ([int]$Record.ac) 2>$null
            if ($LASTEXITCODE -ne 0) { throw ("Power plan {0} could not take {1} back (it may have been deleted)." -f $sch,$Record.name) }
            & powercfg.exe -setdcvalueindex $sch $Record.path $Record.name ([int]$Record.dc) 2>$null
            if ($sch -eq 'SCHEME_CURRENT' -or $sch -eq (Get-ActiveSchemeGuid)) { & powercfg.exe -S $sch 2>$null }
        }
        'netPowerState' { if (Get-NetAdapter -Name $Record.path -ErrorAction SilentlyContinue) { $args2 = @{ Name=$Record.path; ErrorAction='Stop' }; if ([string]$Record.magic -in 'Enabled','Disabled') { $args2.WakeOnMagicPacket = [string]$Record.magic }; if ([string]$Record.pattern -in 'Enabled','Disabled') { $args2.WakeOnPattern = [string]$Record.pattern }; Set-NetAdapterPowerManagement @args2 } }
        'netRssState' { if (Get-NetAdapter -Name $Record.path -ErrorAction SilentlyContinue) { Set-NetAdapterRss -Name $Record.path -Enabled ([bool]$Record.enabled) -ErrorAction Stop } }
        'netRscState' { if (Get-NetAdapter -Name $Record.path -ErrorAction SilentlyContinue) { Set-NetAdapterRsc -Name $Record.path -IPv4Enabled ([bool]$Record.v4) -IPv6Enabled ([bool]$Record.v6) -ErrorAction Stop } }
        'netbiosState' { $c = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { [string]$_.SettingID -eq [string]$Record.path } | Select-Object -First 1; if ($c) { Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions=[uint32]$Record.value } -ErrorAction Stop | Out-Null } }
        'teredoState' { if ([string]$Record.value) { Set-NetTeredoConfiguration -Type ([string]$Record.value) -ErrorAction Stop } }
        'usbPowerState' { foreach ($d in @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { [string]$_.InstanceName -eq [string]$Record.path })) { Set-CimInstance -InputObject $d -Property @{ Enable=[bool]$Record.enabled } -ErrorAction Stop } }
        'featureState' { Invoke-Action @{ kind='optionalFeature'; names=@($Record.name); enable=[bool]$Record.enabled } }
        'throttleApp' { Invoke-Action @{ kind='throttleApp'; exe=[string]$Record.name; exempt=[bool]$Record.exempt } }
        'qosPolicy' { Invoke-Action @{ kind='qosGame'; exe=[string]$Record.exe; enable=[bool]$Record.existed } }
        'powerOverlay' { Invoke-Action @{ kind='powerMode'; guid=[string]$Record.value } }
        'mpPref' { Invoke-Action @{ kind='mpPreference'; name=[string]$Record.name; value=[int]$Record.value } }
        'mmAgent' { Invoke-Action @{ kind='mmagent'; feature=[string]$Record.name; enable=[bool]$Record.enabled } }
        'powerScheme' { & powercfg.exe -S ([string]$Record.guid) 2>$null; if ($LASTEXITCODE -ne 0) { throw ("Power plan {0} is no longer available." -f $Record.guid) } }
        'tcpAutoTune' { & netsh.exe int tcp set global ("autotuninglevel={0}" -f ([string]$Record.value).ToLowerInvariant()) | Out-Null }
        'dnsServers' {
            $ad = Get-NetAdapter -InterfaceIndex ([int]$Record.name) -ErrorAction SilentlyContinue
            if ($ad -and [string]$ad.InterfaceGuid -eq [string]$Record.path) {
                Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop
                $servers = @($Record.servers | Where-Object { $_ })
                if ($servers.Count) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $servers -ErrorAction Stop }
            }
        }
    }
}
function Get-RevertActions {
    param($Tweak)
    if ($script:Journal.ContainsKey($Tweak.Id)) {
        $records = @($script:Journal[$Tweak.Id])
        $defaults = foreach ($a in @($Tweak.Revert)) {
            $covered = switch ($a.kind) {
                'service' { ([string]$a.name -notmatch '[*?]') -and [bool]@($records | Where-Object { $_.kind -eq 'svcStart' -and $_.name -eq $a.name }).Count }
                { $_ -in 'registry','registryDel' } { [bool]@($records | Where-Object { $_.kind -eq 'regValue' -and $_.path -eq $a.path -and $_.name -eq $a.name }).Count }
                'powerSetting' { [bool]@($records | Where-Object { $_.kind -eq 'powerIndex' -and $_.path -eq $a.sub -and $_.name -eq $a.setting }).Count }
                'dxGlobal' { [bool]@($records | Where-Object { $_.kind -eq 'regValue' -and $_.name -eq 'DirectXUserGlobalSettings' }).Count }
                'dxApp' { [bool]@($records | Where-Object { $_.kind -eq 'regValue' -and $_.name -eq [string]$a.exe }).Count }
                'qosGame' { [bool]@($records | Where-Object { $_.kind -eq 'qosPolicy' -and $_.exe -eq [string]$a.exe }).Count }
                'throttleApp' { [bool]@($records | Where-Object { $_.kind -eq 'throttleApp' -and $_.name -eq [string]$a.exe }).Count }
                'mpPreference' { [bool]@($records | Where-Object { $_.kind -eq 'mpPref' -and $_.name -eq $a.name }).Count }
                'eventLog' { $false }
                default { $true }
            }
            if (-not $covered) { $a }
        }
        return (@($defaults) + @(@{ kind='restoreRecords'; id=$Tweak.Id }))
    }
    if (@($Tweak.Revert).Count) { return @($Tweak.Revert) }
    $derived = foreach ($a in @($Tweak.Apply)) {
        switch ($a.kind) {
            { $_ -in 'netAdvancedProperty','netAdvancedPropertyMax' } { @{ kind='netAdvancedPropertyReset'; name=$a.name; names=$a.names; keywords=$a.keywords; namePattern=$a.namePattern } }
            'runkey'                 { @{ kind='runkey'; name=$a.name; enable=$true } }
            'netRssProfile'          { @{ kind='netAdvancedPropertyReset'; keywords=@('*RSSProfile','*RssBaseProcNumber','*NumRssQueues') } }
        }
    }
    return @($derived)
}
function Get-RevertLabel {
    param([string]$Label)
    $pairs = @(@('Disable ','Re-enable '),@('Turn off ','Turn on '),@('Stop ','Start '),@('Pause ','Resume '),@('Block ','Allow '),@('Remove ','Restore '),@('Hide ','Show '),@('Uninstall ','Reinstall '))
    foreach ($pair in $pairs) {
        if ($Label.StartsWith($pair[0], [StringComparison]::OrdinalIgnoreCase)) { return ($pair[1] + $Label.Substring($pair[0].Length)) }
    }
    return ("Undo: {0}" -f $Label)
}
function Get-DisplayLabel {
    param($Tweak,[bool]$TargetApplied)
    if ($TargetApplied) { return $Tweak.Label }
    return (Get-RevertLabel $Tweak.Label)
}
$script:LiveStateKinds = @('registry','service','serviceAny','taskAny','taskAnyName','taskAnyNamePattern','appx','anyPath','appJsonSetting','svchost','netadapter','runkey','runkeyAny','optionalFeature','appxStartup')
function Update-AppliedFromJournal {
    foreach ($t in $script:Tweaks) {
        $d = $script:Detection[$t.Id]
        if (-not $d -or $t.Type -ne 'toggle') { continue }
        $journaled = $script:Journal.ContainsKey($t.Id)
        $kind = if ($t.Detect) { [string]$t.Detect.kind } else { '' }
        if ($kind -in 'runkey','runkeyAny') {
            if (-not $d.Present -and $journaled) { $d.Present = $true; $d.Reason = ''; $d.Applied = $true }
            continue
        }
        if (-not $d.Present) { continue }
        $readback = Test-TweakRegistryActionsApplied $t
        if (-not $d.Live -and $null -ne $readback -and ($kind -eq '' -or $kind -eq 'registry')) { $d.Applied = [bool]$readback }
        elseif ($journaled -and -not $d.Live) { $d.Applied = $true }
    }
}
 
$script:Ready   = $false
$script:UiReady = $false
$script:StatusLabel = $null
$script:Window      = $null
 
$script:Rows = @{}
 
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Action','Success','Warn','Error')][string]$Level = 'Info'
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) {
        'Action'  { 'White' }
        'Success' { 'Green' }
        'Warn'    { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $ts, $Message) -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1,-7} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -Encoding UTF8 } catch { }
    if ($script:StatusLabel -and $script:Window) {
        try {
            $script:Window.Dispatcher.Invoke([action]{ $script:StatusLabel.Text = $Message })
        } catch { }
    }
}
 
 
function Get-NominalRamGB {
    param([long]$Bytes)
    if ($Bytes -le 0) { return 0 }
    $tiers = 4,6,8,12,16,24,32,48,64,128
    $gb = $Bytes / 1GB
    $best = $tiers[0]; $bestDiff = [double]::MaxValue
    foreach ($t in $tiers) {
        $d = [math]::Abs($gb - $t)
        if ($d -lt $bestDiff) { $bestDiff = $d; $best = $t }
    }
    return $best
}
 
function Get-SvcThreshold {
    param([int]$NominalGB)
    if ($NominalGB -le 0) { return 0 }
    return [int64]$NominalGB * 1024 * 1024
}
 
function Test-IsLaptop {
    try { if (Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1) { return $true } } catch { }
    try {
        $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
        return [bool]@($types | Where-Object { [int]$_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count
    } catch { return $false }
}

function Test-HybridIntelCpu {
    param([string]$Name)
    return [bool]($Name -match '(1[2-4])th Gen Intel|Core\(TM\) Ultra|Core Ultra|Intel\(R\) Core\(TM\) [3579] \d{3}')
}

function Invoke-Detect {
    $r = [ordered]@{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $build = [int]$cv.CurrentBuildNumber
        $display = $cv.DisplayVersion
        $r.OsName = ('{0} {1}' -f ($os.Caption -replace 'Microsoft ',''), $display).Trim()
        $r.Build  = $build
    } catch { $r.OsName = 'Windows'; $r.Build = 0 }
 
    try {
        $cpuKey = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
        $r.Cpu = ([string]$cpuKey.ProcessorNameString).Trim()
        $r.CpuVendor = switch -Wildcard ([string]$cpuKey.VendorIdentifier) {
            '*AuthenticAMD*' { 'AMD' }
            '*GenuineIntel*' { 'Intel' }
            default          { 'Unknown' }
        }
    } catch { $r.Cpu = 'Unknown CPU'; $r.CpuVendor = 'Unknown' }
    $r.CpuHybrid = Test-HybridIntelCpu -Name $r.Cpu
    $r.CpuX3D    = [bool]($r.Cpu -match 'X3D')
    $r.IsLaptop  = Test-IsLaptop
    $r.HasHdd    = $false
    try { $r.HasHdd = [bool]@(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.MediaType -eq 'HDD' }).Count } catch { }

    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory)
        $bytes = ($sticks | Measure-Object -Property Capacity -Sum).Sum
        if (-not $bytes) { $bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
        $r.RamBytes = [long]$bytes
    } catch { $r.RamBytes = 0 }
    $r.RamNominalGB = Get-NominalRamGB -Bytes $r.RamBytes
    $r.SvcThreshold = Get-SvcThreshold -NominalGB $r.RamNominalGB
 
    $gpus = @()
    try {
        $vcs = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name })
        foreach ($v in $vcs) {
            $vendor = switch -Wildcard ($v.Name) {
                '*NVIDIA*' { 'NVIDIA'; break }
                '*GeForce*'{ 'NVIDIA'; break }
                '*AMD*'    { 'AMD'; break }
                '*Radeon*' { 'AMD'; break }
                '*Intel*'  { 'Intel'; break }
                default    { 'Other' }
            }
            $isMain = [bool]($v.CurrentHorizontalResolution -gt 0)
            $gpus += @{ Name = $v.Name.Trim(); IsMain = $isMain; Vendor = $vendor }
        }
    } catch { }
    $r.Gpus = $gpus
    $r.GpuVendors = @($gpus | ForEach-Object { $_.Vendor } | Sort-Object -Unique)
    return $r
}
 
 
function Set-RegValue {
    param([string]$Path,[string]$Name,$Value,[string]$Type = 'DWord')
    if ($Path -notmatch '^(HKLM:|HKCU:|HKCR:|HKU:|Registry::|Microsoft\.PowerShell\.Core\\Registry::)') { throw ("Refusing to write a registry value to a non-registry path: {0}" -f $Path) }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
 
function Remove-RegValue {
    param([string]$Path,[string]$Name)
    if (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}
 
$script:StartMap = @{ Boot=0; System=1; Automatic=2; Manual=3; Disabled=4 }
 
function Get-ServiceStartValue {
    param([string]$Name)
    if ($script:SvcStartCache) { if ($script:SvcStartCache.ContainsKey($Name)) { return $script:SvcStartCache[$Name] }; return $null }
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $key)) { return $null }
    try { return [int](Get-ItemProperty $key -Name Start -ErrorAction Stop).Start } catch { return $null }
}
 
function Set-ServiceStartNow {
    param([string]$Name,[int]$Start)
    $type = switch ($Start) { 2 {'Automatic'} 3 {'Manual'} 4 {'Disabled'} default { $null } }
    $svcType = 0; try { $svcType = [int](Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Type -ErrorAction Stop).Type } catch { }
    $registryOnly = ($Name -match '_[0-9a-fA-F]{4,}$') -or ($svcType -band 0x0B) -or ($svcType -band 0x40)
    if ($type -and -not $registryOnly) {
        try { Set-Service -Name $Name -StartupType $type -ErrorAction Stop; return }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '(?i)parameter is incorrect|not valid') { Write-Log ("{0} cannot be changed through the service manager; set in the registry instead (applies after a restart)." -f $Name) 'Info' }
            else { Write-Log ("Service manager refused to change {0}: {1}" -f $Name,$msg) 'Warn' }
        }
    }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $Start -Type DWord -ErrorAction Stop
}
function Set-ServiceStart {
    param([string]$Name,[string]$StartType,[switch]$Stop)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $key)) { return $false }
    if(-not $script:ServiceBackups.ContainsKey($Name)){
        try{$script:ServiceBackups[$Name]=[int](Get-ItemProperty $key -Name Start -ErrorAction Stop).Start}catch{}
    }
    Set-ServiceStartNow -Name $Name -Start ([int]$script:StartMap[$StartType])
    if ($Stop -and $script:StartMap[$StartType] -ge 3) {
        try {
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    return $true
}
 
function Resolve-ServiceNames {
    param([string]$Name)
    if ($script:SvcStartCache) {
        if ($Name -match '[*?]') { return @($script:SvcStartCache.Keys | Where-Object { $_ -like $Name } | Sort-Object) }
        if ($script:SvcStartCache.ContainsKey($Name)) { return @($Name) }
        return @()
    }
    if ($Name -match '[*?]') {
        $names = @(Get-Service -Name $Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if ($Name -match '^([A-Za-z0-9]+)_\*$' -and (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($Matches[1])")) { $names = @($Matches[1]) + $names }
        return @($names | Select-Object -Unique)
    }
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name") { return @($Name) }
    return @()
}
function Test-ServiceStartMet {
    param($Current,[int]$Want)
    return ($null -ne $Current -and ([int]$Current -eq $Want -or ($Want -eq 3 -and [int]$Current -eq 4)))
}
function Test-ServiceExists { param([string]$Name) return (@(Resolve-ServiceNames $Name).Count -gt 0) }
 
$script:ProtectedServices = @(
    'WlanSvc','Netman','NlaSvc','netprofm','Dhcp','Dnscache','NdisVirtualBus',
    'BFE','mpssvc','RpcSs','RpcEptMapper','DcomLaunch','PlugPlay','Power',
    'wuauserv','UsoSvc','TrustedInstaller','VSS','swprv','W32Time',
    'WinDefend','SecurityHealthService','wscsvc','TPM','gpsvc','ProfSvc',
    'EventLog','Schedule','CoreMessagingRegistrar','LSM',
    'esifsvc','ipfsvc',
    'TextInputManagementService','TabletInputService','cbdhsvc'
)
 
function Test-Protected {
    param([string]$Kind,[string]$Name)
    if ($Kind -eq 'service') {
        return ($script:ProtectedServices -contains $Name)
    }
    return $false
}
 
 
function New-Tweak {
    param(
        [string]$Id,[string]$Tab,[string]$SubTab,[string]$Group,[string]$Label,
        [ValidateSet('Safe','Moderate','Risky','Protected','Manual')][string]$Risk,
        [ValidateSet('toggle','dropdown','info')][string]$Type = 'toggle',
        [string[]]$Options,
        $Detect,
        [array]$Apply = @(),
        [array]$Revert = @(),
        [string]$ApplyVerb = 'Applying',
        [string]$DoneVerb,
        [string]$Info = '',
        [string]$Note = '',
        [string]$Warn = '',
        $Recommend = $null
    )
    [ordered]@{
        Id=$Id; Tab=$Tab; SubTab=$SubTab; Group=$Group; Label=$Label; Risk=$Risk
        Type=$Type; Options=$Options; Detect=$Detect; Apply=$Apply; Revert=$Revert
        ApplyVerb=$ApplyVerb; DoneVerb=$(if ($DoneVerb) { $DoneVerb } else { $Label }); Info=$Info; Note=$Note; Warn=$Warn; Recommend=$Recommend
    }
}
 
function New-ServiceGroup {
    param(
        [string]$Id,[string]$Tab,[string]$SubTab,[string]$Group,[string]$Label,
        [string]$Risk,[string]$StartType = 'Disabled',[string[]]$Services,
        [string]$RevertType = 'Manual',[string]$Info = '',[string]$DoneVerb,$Recommend = $null
    )
    $apply  = foreach ($s in $Services) { @{kind='service';name=$s;start=$StartType;stop=($StartType -eq 'Disabled');child=$s} }
    $revert = foreach ($s in $Services) { @{kind='service';name=$s;start=$RevertType} }
    New-Tweak -Id $Id -Tab $Tab -SubTab $SubTab -Group $Group -Label $Label -Risk $Risk `
        -Detect @{kind='serviceAny';names=$Services;start=$StartType} -Apply $apply -Revert $revert `
        -DoneVerb $DoneVerb -Info $Info -Recommend $Recommend
}

function New-ServiceTweak {
    param([string]$Id,[string]$Group,[string]$Label,[string]$Risk,[string]$Service,[string]$Info,[string]$RevertType='Manual')
    New-ServiceGroup -Id $Id -Tab 'Tweaks' -SubTab 'Services' -Group $Group -Label $Label -Risk $Risk -Services @($Service) -RevertType $RevertType -Info $Info
}
 
$script:Tweaks = @()
$script:ShellBackgroundApps = @(
    'MicrosoftWindows.Client.CBS_cw5n1h2txyewy','MicrosoftWindows.Client.Core_cw5n1h2txyewy',
    'Microsoft.Windows.Search_cw5n1h2txyewy','Microsoft.Windows.Cortana_cw5n1h2txyewy',
    'Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy','Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy',
    'Microsoft.Windows.InputApp_cw5n1h2txyewy'
)

$script:OsBuild = 0
try { $script:OsBuild = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch { }

$script:Tweaks += New-ServiceGroup -Id 'svc.bg.telemetry' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Pause Windows diagnostic reporting' -Risk 'Safe' -Services @('DiagTrack','dmwappushservice') -Info 'Stops the Connected User Experiences and Telemetry service that uploads diagnostic data. Does not affect Windows Update or security.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.search' -Tab 'Tweaks' -SubTab 'Services' -Group 'Search and caching' -Label 'Stop file catalog indexing' -Risk 'Moderate' -Services @('WSearch') -Info 'Stops background file indexing. Start and taskbar search still find apps and settings, but file results in Start, the taskbar and File Explorer become slow or incomplete because they rely on the index. Limiting the indexed folders is the gentler option.'
$script:Tweaks += (New-Tweak -Id 'svc.bg.do' -Tab 'Tweaks' -SubTab 'Services' -Group 'Updates' -Label 'Set Delivery Optimization to manual' -Risk 'Moderate' -Detect @{kind='service';name='DoSvc';start='Manual'} -Apply @(@{kind='service';name='DoSvc';start='Manual'}) -Revert @(@{kind='service';name='DoSvc';start='Automatic'}) -Info 'Delivery Optimization shares update files with other PCs. Manual keeps updates working but stops the background peer sharing.')
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.sysmain' -Tab 'Tweaks' -SubTab 'Services' -Group 'Search and caching' -Label 'Stop SysMain preloading' -Risk 'Moderate' -Services @('SysMain') -Info 'SysMain (Superfetch) pre-loads apps into RAM. On SSD/NVMe systems the benefit is small and it causes background disk and CPU use. Not offered when a hard disk drive (HDD) is installed: there it noticeably speeds up app launches.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.diag' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Turn off Windows diagnostic helpers' -Risk 'Risky' -Services @('DPS','WdiServiceHost','WdiSystemHost') -Info 'Diagnostic Policy Service and WDI hosts. Disabling them breaks the built-in troubleshooters and some network diagnostics.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.pca' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop compatibility assistant checks' -Risk 'Moderate' -Services @('PcaSvc') -Info 'The assistant that detects apps that fail to install/run and offers compatibility fixes. Rarely needed on modern apps.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.datausage' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop per-app data accounting' -Risk 'Moderate' -Services @('DusmSvc') -Info 'Data Usage service tracks per-app network bytes shown in Settings. Does not affect connectivity.'
$script:Tweaks += New-ServiceTweak -Id 'svc.bg.wallet' -Group 'Background' -Label 'Stop Wallet credential management' -Risk 'Safe' -Service 'WalletService' -Info 'Manages payment credential objects for Wallet. Disable only if you do not use Wallet or related payment apps.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.appupdate' -Tab 'Tweaks' -SubTab 'Services' -Group 'Updates' -Label 'Make browser and Adobe updaters on-demand' -Risk 'Moderate' -StartType 'Manual' -RevertType 'Manual' -Services @('edgeupdate','edgeupdatem','GoogleUpdaterInternalService','GoogleUpdaterService','AdobeARMservice') -Info 'Changes installed browser and Adobe updater services to Manual. Apps can still update when launched; updater service names vary by version.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.peruser' -Tab 'Tweaks' -SubTab 'Services' -Group 'Background apps' -Label 'Set session sync helpers to on-demand' -Risk 'Moderate' -StartType 'Manual' -RevertType 'Manual' -Services @('OneSyncSvc','OneSyncSvc_*','CDPUserSvc','CDPUserSvc_*','UserDataSvc','UserDataSvc_*','UnistoreSvc','UnistoreSvc_*','PimIndexMaintenanceSvc','PimIndexMaintenanceSvc_*','MessagingService','MessagingService_*') -Info 'Sets installed per-user sync, connected-device, contacts, calendar, and messaging services to Manual. Windows creates per-user service instances for sessions; this does not promise a fixed process count.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.mediaqos' -Tab 'Tweaks' -SubTab 'Services' -Group 'Media sharing' -Label 'Turn off media sharing and QoS helpers' -Risk 'Moderate' -Services @('WMPNetworkSvc','QWAVE') -Info 'Stops Windows Media Player network sharing and Quality Windows Audio Video Experience services when installed. Does not disable Windows audio playback; network media sharing and QoS reservation features may stop.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.servicing' -Tab 'Tweaks' -SubTab 'Services' -Group 'Updates' -Label 'Stop update repair helpers' -Risk 'Risky' -Services @('WaaSMedicSvc','uhssvc') -Info 'Disables detected Windows Update health/remediation helpers. Windows servicing may repair or re-enable them; this can prevent updates and troubleshooting. The regular Windows Update fix remains in Security.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.25h2' -Tab 'Tweaks' -SubTab 'Services' -Group 'Background apps' -Label 'Turn off newer per-user background helpers' -Risk 'Moderate' -Services @('UdkUserSvc','UdkUserSvc_*','AarSvc','AarSvc_*') -Info 'Disables detected User Data Access and Agent Activation Runtime per-user services. These service names vary by build; disabling can affect AI, voice, contacts, and user-data features.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.legacy' -Tab 'Tweaks' -SubTab 'Services' -Group 'Legacy components' -Label 'Remove obsolete network service components' -Risk 'Moderate' -Services @('NetDDE','NetDDEdsdm','NetTcpPortSharing','TlntSvr') -Info 'Disables optional legacy NetDDE, .NET TCP port sharing, and Telnet services only when installed. Do not use if a legacy application or Telnet server depends on them.'
$script:Tweaks += New-ServiceTweak -Id 'svc.bg.appraisal' -Group 'Background' -Label 'Stop installed app inventory checks' -Risk 'Safe' -Service 'InventorySvc' -Info 'Stops the Application Inventory service when present. Compatibility and app inventory reporting may be delayed; Windows Update and Defender services are left alone.'
 
$script:Tweaks += New-ServiceGroup -Id 'svc.net.rdp' -Tab 'Tweaks' -SubTab 'Services' -Group 'Remote access' -Label 'Reject remote desktop connections' -Risk 'Moderate' -Services @('TermService','UmRdpService','SessionEnv') -Info 'Stops this PC from accepting incoming Remote Desktop connections. Outgoing RDP (connecting to other PCs) still works.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.remotereg' -Tab 'Tweaks' -SubTab 'Services' -Group 'Remote access' -Label 'Close remote registry access' -Risk 'Safe' -Services @('RemoteRegistry') -Info 'Allows editing this PC''s registry from another machine. Off by default on most systems; safe to keep disabled.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.share' -Tab 'Tweaks' -SubTab 'Services' -Group 'Discovery and sharing' -Label 'Stop hosting shared folders and printers' -Risk 'Moderate' -Services @('LanmanServer') -Info 'Stops this PC from hosting shared folders/printers. You can still access shares on other PCs.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.iphlp' -Tab 'Tweaks' -SubTab 'Services' -Group 'VPN and tunnels' -Label 'Turn off IP transition support' -Risk 'Risky' -Services @('iphlpsvc') -Info 'IP Helper provides IPv6 transition tunnels (Teredo/6to4) and some VPN features. Disable only if you do not rely on them.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.ncb' -Tab 'Tweaks' -SubTab 'Services' -Group 'Background apps' -Label 'Pause background Store app networking' -Risk 'Moderate' -Services @('NcbService') -Info 'Lets Store apps receive background network events. Disabling can stop live tiles / app notifications that need a connection.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.vpn' -Tab 'Tweaks' -SubTab 'Services' -Group 'VPN and tunnels' -Label 'Turn off Windows SSTP VPN support' -Risk 'Moderate' -Services @('SstpSvc') -Info 'Secure Socket Tunneling Protocol for Windows'' built-in VPN. Third-party VPN clients are unaffected.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.discovery' -Tab 'Tweaks' -SubTab 'Services' -Group 'Discovery and sharing' -Label 'Stop device discovery and UPnP' -Risk 'Moderate' -Services @('FDResPub','fdPHost','SSDPSRV','upnphost') -Info 'Stops network discovery and UPnP discovery. This PC may no longer appear in Network or discover network devices. Games and the Xbox app that open router ports through Windows UPnP can end up with Strict NAT, and casting can stop finding devices.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.hotspot' -Tab 'Tweaks' -SubTab 'Services' -Group 'Mobile and radio' -Label 'Stop mobile broadband and hotspot services' -Risk 'Safe' -Services @('icssvc','WwanSvc') -Info 'Internet Connection Sharing and mobile broadband services. Disabling breaks Mobile Hotspot and cellular broadband.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.wirelessdisplay' -Tab 'Tweaks' -SubTab 'Services' -Group 'Discovery and sharing' -Label 'Turn off Miracast receiver support' -Risk 'Moderate' -Services @('WFDSConMgrSvc','WfdHost') -Info 'Wireless Display / Miracast connection services when installed. Disabling prevents projecting to wireless displays.'
$script:Tweaks += New-ServiceTweak -Id 'svc.net.webdav' -Group 'Network' -Label 'Stop WebDAV file access' -Risk 'Moderate' -Service 'WebClient' -Info 'Windows WebClient enables WebDAV folders and applications. Disable only if you do not use WebDAV-based cloud or workplace file locations.'
 
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.payments' -Tab 'Tweaks' -SubTab 'Services' -Group 'Payments and phone' -Label 'Turn off NFC payments and app telephony' -Risk 'Safe' -Services @('SEMgrSvc','PhoneSvc') -Info 'NFC/Wallet payment manager and the Phone (telephony for Store apps) service.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.hypervhost' -Tab 'Tweaks' -SubTab 'Services' -Group 'Virtualization' -Label 'Stop Hyper-V host components' -Risk 'Moderate' -Services @('vmms','vmcompute','HvHost','hns') -Info 'Hyper-V management, compute, host, and networking services when installed. Disabling can break Hyper-V, WSL2, Windows Sandbox, containers, or Docker; select individual services in Apply.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.hyperv' -Tab 'Tweaks' -SubTab 'Services' -Group 'Virtualization' -Label 'Turn off virtual machine guest helpers' -Risk 'Safe' -Services @('vmicheartbeat','vmicvss','vmicshutdown','vmicrdv','vmictimesync','vmickvpexchange','vmicguestinterface') -Info 'These only do anything when this PC is running as a Hyper-V virtual machine. Safe to disable on a normal desktop.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.storagespaces' -Tab 'Tweaks' -SubTab 'Services' -Group 'Storage and backup' -Label 'Stop Storage Spaces management' -Risk 'Moderate' -Services @('smphost') -Info 'Storage Spaces SMP host. Disable only if you do not use a Storage Spaces pool.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.backup' -Tab 'Tweaks' -SubTab 'Services' -Group 'Storage and backup' -Label 'Stop built-in backup engines' -Risk 'Moderate' -Services @('SDRSVC','wbengine') -Info 'Windows Backup and block-level backup engine. Disable only if you use another backup tool and do not use Windows Backup.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.hello' -Tab 'Tweaks' -SubTab 'Services' -Group 'Accounts and sign-in' -Label 'Turn off PIN and biometric sign-in support' -Risk 'Risky' -Services @('NgcSvc','NgcCtnrSvc','WbioSrvc') -Info 'Windows Hello PIN, key container and face/fingerprint services.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.bitlocker' -Tab 'Tweaks' -SubTab 'Services' -Group 'Storage and backup' -Label 'Stop drive encryption service support' -Risk 'Risky' -Services @('BDESVC','EFS') -Info 'BitLocker drive encryption and Encrypting File System support. Disable only if you do not use either feature.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.crossdevice' -Tab 'Tweaks' -SubTab 'Services' -Group 'Accounts and sign-in' -Label 'Move continuity services to on-demand' -Risk 'Moderate' -StartType 'Manual' -RevertType 'Manual' -Services @('CDPSvc','DevicesFlowUserSvc') -Info 'Cross-device and device flow services start only when an app needs them, instead of running in the background.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.voice' -Tab 'Tweaks' -SubTab 'Services' -Group 'Cloud and AI' -Label 'Turn off voice wake service' -Risk 'Moderate' -Services @('NaturalAuthentication') -Info 'Windows voice activation service when present. Disabling can stop voice wake and assistant activation.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.mail' -Tab 'Tweaks' -SubTab 'Services' -Group 'Mail and sync' -Label 'Stop mail, calendar, and contacts sync' -Risk 'Moderate' -Services @('OneSyncSvc','OneSyncSvc_*','UserDataSvc','UserDataSvc_*','UnistoreSvc','UnistoreSvc_*','PimIndexMaintenanceSvc','PimIndexMaintenanceSvc_*') -Info 'Per-user mail, contacts, calendar, and structured user-data services. Disabling can break sync and apps that use these services; choose individual instances in Apply.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.ai' -Tab 'Tweaks' -SubTab 'Services' -Group 'Cloud and AI' -Label 'Set activation runtime services to on-demand' -Risk 'Moderate' -StartType 'Manual' -RevertType 'Manual' -Services @('AarSvc','AarSvc_*') -Info 'Sets installed Agent Activation Runtime user services to Manual. Windows or apps may start them on demand; this may affect voice activation or AI features.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.phishing' -Tab 'Tweaks' -SubTab 'Services' -Group 'Security and protection' -Label 'Turn off web threat defense services' -Risk 'Risky' -Services @('webthreatdefusersvc','webthreatdefusersvc_*') -Info 'Windows web threat defense user service. Disabling weakens SmartScreen and phishing protections.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.account' -Tab 'Tweaks' -SubTab 'Services' -Group 'Accounts and sign-in' -Label 'Stop Microsoft account sign-in support' -Risk 'Risky' -Services @('wlidsvc') -Info 'Microsoft Account Sign-in Assistant (wlidsvc), which every Microsoft account sign-in on this PC goes through.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.notifications' -Tab 'Tweaks' -SubTab 'Services' -Group 'Shell and visuals' -Label 'Turn off Windows push notifications' -Risk 'Moderate' -Services @('WpnService','WpnUserService','WpnUserService_*') -Info 'Windows Push Notifications System and per-user services. Disabling suppresses many app and system toast notifications; the Windows Security notification icon and protection remain separate.'
$script:Tweaks += New-ServiceTweak -Id 'svc.feat.timezone' -Group 'Time and family' -Label 'Stop automatic time-zone updates' -Risk 'Safe' -Service 'tzautoupdate' -Info 'Stops Windows from changing the time zone automatically based on location. The clock continues to run; set the time zone manually when travelling.'
$script:Tweaks += New-ServiceTweak -Id 'svc.feat.family' -Group 'Time and family' -Label 'Turn off Family Safety monitoring' -Risk 'Risky' -Service 'WpcMonSvc' -Info 'Windows Parental Controls monitoring service. Disabling can stop Family Safety limits and reporting for this device.'
$script:Tweaks += (New-Tweak -Id 'feat.net.wifi' -Tab 'Tweaks' -SubTab 'Services' -Group 'Network adapters (optional)' -Label 'Disable Wi-Fi adapters (optional)' -Risk 'Risky' -Detect @{kind='netadapter';type='wifi'} -Apply @(@{kind='netadapter';type='wifi';enable=$false}) -Revert @(@{kind='netadapter';type='wifi';enable=$true}) -ApplyVerb 'Disabling' -DoneVerb 'Disabled Wi-Fi adapters' -Info 'Optional, off by default. Disables every Wi-Fi adapter on this PC and asks you to confirm first. Wi-Fi is protected from every other tweak. Re-enable here or in Fixes > Re-enable network adapters.')
$script:Tweaks += (New-Tweak -Id 'feat.net.eth' -Tab 'Tweaks' -SubTab 'Services' -Group 'Network adapters (optional)' -Label 'Disable Ethernet adapters (optional)' -Risk 'Risky' -Detect @{kind='netadapter';type='ethernet'} -Apply @(@{kind='netadapter';type='ethernet';enable=$false}) -Revert @(@{kind='netadapter';type='ethernet';enable=$true}) -ApplyVerb 'Disabling' -DoneVerb 'Disabled Ethernet adapters' -Info 'Optional, off by default. Disables every wired Ethernet adapter and asks you to confirm first. Ethernet is protected from every other tweak. Re-enable here or in Fixes > Re-enable network adapters.')
 
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.sensors' -Tab 'Tweaks' -SubTab 'Services' -Group 'Sensors and mixed reality' -Label 'Turn off motion and ambient sensor helpers' -Risk 'Safe' -Services @('SensorService','SensrSvc') -Info 'Ambient-light / orientation sensor services. Safe to disable on a desktop with no sensors.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.smartcard' -Tab 'Tweaks' -SubTab 'Services' -Group 'Security and protection' -Label 'Stop smart-card reader support' -Risk 'Safe' -Services @('SCardSvr','ScDeviceEnum','CertPropSvc') -Info 'Smart card reader services. Safe to disable if you do not sign in with a smart card.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.print' -Tab 'Tweaks' -SubTab 'Services' -Group 'Printing' -Label 'Choose printer services to pause' -Risk 'Moderate' -Services @('Spooler','PrintNotify','PrintWorkflowUserSvc','PrintWorkflowUserSvc_*') -Info 'Choose installed print services individually in Apply: Print Spooler stops printing, while Printer Extensions and Notifications or Print Workflow services affect printer dialogs and app print workflows.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.webcam' -Tab 'Tweaks' -SubTab 'Services' -Group 'Cameras and scanners' -Label 'Turn off camera and scanner support' -Risk 'Risky' -Services @('FrameServer','FrameServerMonitor','stisvc') -Info 'Windows Camera Frame Server and still-image (scanner) service. Disabling stops all webcam/scanner use until re-enabled.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.bluetooth' -Tab 'Tweaks' -SubTab 'Services' -Group 'Bluetooth' -Label 'Stop Bluetooth radio services' -Risk 'Risky' -Services @('bthserv','BTAGService','BluetoothUserService') -Info 'Turns off all Bluetooth. Risky: you lose Bluetooth mice, keyboards, headsets and controllers until re-enabled.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.pairing' -Tab 'Tweaks' -SubTab 'Services' -Group 'Pairing and portable devices' -Label 'Turn off pairing and portable-device setup' -Risk 'Risky' -Services @('DeviceAssociationService','DeviceInstall','WPDBusEnum') -Info 'Device association, device installation, and portable-device enumeration. With Device Install Service off, newly plugged-in USB devices and drivers can fail to install; pairing and phone/media transfer can also stop. Choose individual services in Apply.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.nahimic' -Tab 'Tweaks' -SubTab 'Services' -Group 'Audio' -Label 'Stop Nahimic audio effects support' -Risk 'Moderate' -Services @('NahimicService') -Info 'Optional Nahimic audio effects and companion service, installed with some motherboard/audio drivers. Disabling removes those effects.'
$script:Tweaks += New-ServiceTweak -Id 'svc.dev.adaptivebrightness' -Group 'Devices' -Label 'Stop sensor-driven screen dimming' -Risk 'Moderate' -Service 'SensorService' -Info 'Stops sensor based ambient-light changes when Sensor Service is installed. Adaptive brightness controls may stop working on laptops and tablets.'

$script:Tweaks += New-ServiceGroup -Id 'svc.vendor.intel' -Tab 'Tweaks' -SubTab 'Services' -Group 'Vendor utilities' -Label 'Stop optional Intel telemetry helpers' -Risk 'Moderate' -Services @('Intel(R) System Usage Report Service','IntelSURQC','jhi_service') -Info 'Optional Intel telemetry and utility helper services. Do not disable chipset, storage, or network driver services.'
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.nv.container' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop NVIDIA app background container' -Risk 'Moderate' -Services @('NvContainerLocalSystem','NvContainerNetworkService') -RevertType 'Automatic' -Info 'NVIDIA LocalSystem/NetworkService containers used by the NVIDIA app and GeForce Experience. Stopping them turns off the NVIDIA overlay, Instant Replay/recording, in-app driver downloads and game optimization. The driver, G-SYNC and NVIDIA Control Panel keep working.'
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.nv.telemetry' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop NVIDIA telemetry container' -Risk 'Safe' -Services @('NvTelemetryContainer') -RevertType 'Automatic' -Info 'NVIDIA telemetry service installed by older drivers. Only usage reporting stops.'
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.nv.frameview' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop NVIDIA FrameView SDK service' -Risk 'Safe' -Services @('FvSvc') -RevertType 'Automatic' -Info 'FvSvc (nvfvsdksvc_x64.exe) feeds frame-rate, frame-time and power statistics to FrameView and the NVIDIA app performance overlay. Games and the driver are unaffected; only those statistics stop.'
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.amd.crashdefender' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop AMD Crash Defender service' -Risk 'Moderate' -Services @('AMD Crash Defender Service','amdfendrsr') -RevertType 'Automatic' -Info 'User-mode part of AMD Crash Defender (amdfendrsr.exe). It captures GPU driver crash data for AMD bug reports. With it stopped, Windows still recovers from a driver timeout and logs it, but AMD Software cannot collect a crash report, so a crash is harder to diagnose. The Crash Defender kernel driver is never touched.'
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.amd.uep' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop AMD User Experience Program' -Risk 'Safe' -Services @('AUEPLauncher','AUEPMaster') -RevertType 'Automatic' -Info 'AMD User Experience Program data collection services. Only usage reporting to AMD stops.'
$script:Tweaks += New-ServiceGroup -Id 'svc.vendor.audio' -Tab 'Tweaks' -SubTab 'Services' -Group 'Audio' -Label 'Pause audio enhancement companions' -Risk 'Moderate' -Services @('RtkAudioUniversalService','RtkAudUService','A-Volute.Nahimic') -Info 'Audio vendor companion services for control panels, jack detection, and sound enhancements. Core audio can remain while enhancements stop.'
$script:Tweaks += New-ServiceGroup -Id 'svc.vendor.intellms' -Tab 'Tweaks' -SubTab 'Services' -Group 'Vendor utilities' -Label 'Stop Intel AMT local management service' -Risk 'Safe' -Services @('LMS') -RevertType 'Automatic' -Info 'Intel Management and Security Application Local Management Service (LMS.exe), part of the Intel Management Engine software. It only serves Intel AMT / vPro remote management, which home PCs do not use. The Management Engine driver and firmware keep working.'
$script:Tweaks += New-ServiceGroup -Id 'svc.vendor.inteldsa' -Tab 'Tweaks' -SubTab 'Services' -Group 'Vendor utilities' -Label 'Stop Intel driver assistant and energy reporting' -Risk 'Safe' -Services @('DSAService','DSAUpdateService','ESRV_SVC_QUEENCREEK','SystemUsageReportSvc_QUEENCREEK') -Recommend $false -Info 'Intel Driver and Support Assistant (scans for Intel driver updates and keeps a local web service running) and the Energy Server / System Usage Report services that collect power and usage data for Intel. Drivers keep working; check for Intel driver updates yourself.'

$script:VendorSoftwareProfiles = @(
    @{ Id='asus';     Name='ASUS';          Company='ASUSTeK|^ASUS';                       Path='\\ASUS\\|\\ASUSTeK|\\ArmouryDevice\\|\\ArmouryCrate|\\ROG Live Service\\|\\LightingService\\|\\AsusUpdateCheck\.exe|\\AsusCertService|\\MyASUS'; Info='Armoury Crate, Aura lighting, ASUS update checks, MyASUS and ROG helper services.'; Laptop='On ASUS laptops these services also run Fn hotkeys, battery charge limit and fan modes.' }
    @{ Id='msi';      Name='MSI';           Company='Micro-Star|^MSI\b';                    Path='\\MSI\\|\\Micro-Star|\\MSI Center\\|\\Dragon Center\\|\\MSIService\.exe|\\SCM\\SCM\.exe|\\muachost\.exe|\\Mystic'; Info='MSI Center, Mystic Light, MSI SDK/ActiveX helpers, the MSI driver utility installer host (MSISW_Host) and update services.'; Laptop='On MSI laptops MSI Center also runs Fn hotkeys, battery charge limit and fan modes.' }
    @{ Id='gigabyte'; Name='GIGABYTE';      Company='GIGA-BYTE|GIGABYTE';                   Path='\\GIGABYTE\\|\\GigabyteUpdateService\.exe|\\AORUS|\\EasyTune|\\GBTECService'; Info='GIGABYTE Control Center, EasyTune engine, RGB Fusion, AORUS display helpers and the GIGABYTE update service.'; Laptop='On GIGABYTE and AORUS laptops these services also run Fn hotkeys and fan modes.' }
    @{ Id='asrock';   Name='ASRock';        Company='ASRock';                               Path='\\ASRock'; Info='ASRock Motherboard Utility, Polychrome RGB, APP Shop / Live Update and App Charger helpers.'; Laptop='' }
    @{ Id='biostar';  Name='BIOSTAR';       Company='BIOSTAR';                              Path='\\BIOSTAR|\\Racing GT'; Info='BIOSTAR Racing GT, VIVID LED and update helpers.'; Laptop='' }
    @{ Id='lenovo';   Name='Lenovo';        Company='^Lenovo';                              Path='\\Lenovo\\|\\LenovoVantage|ImController|\\Legion Zone|LZService'; Info='Lenovo Vantage, ImController plugin host, Legion Zone, Lenovo hotkey and UDC helpers.'; Laptop='On Lenovo laptops Vantage and ImController also run battery conservation mode, Fn hotkeys and fan modes.' }
    @{ Id='dell';     Name='Dell';          Company='^Dell';                                Path='\\Dell\\|\\Alienware|SupportAssist'; Info='Dell SupportAssist, Dell Update, Alienware Command Center, Digital Delivery and data vault helpers.'; Laptop='On Dell and Alienware laptops these services also run power and thermal modes and BIOS update delivery.' }
    @{ Id='hp';       Name='HP';            Company='^HP Inc|^HP Development|Hewlett';      Path='\\HP\\|\\HPCommRecovery|\\OMEN|\\HP Wolf'; Info='HP Support Assistant, OMEN Gaming Hub, HP analytics, app helper and system event helpers. Printer and scanner services are left alone.'; Laptop='On HP and OMEN laptops these services also run hotkeys, fan modes and battery health manager.' }
    @{ Id='acer';     Name='Acer';          Company='^Acer';                                Path='\\Acer\\|\\PredatorSense|\\NitroSense|\\AcerCare'; Info='Acer Care Center, PredatorSense / NitroSense and Acer update helpers.'; Laptop='On Acer laptops PredatorSense / NitroSense also run fan modes and keyboard lighting.' }
    @{ Id='killer';   Name='Killer Networking'; Company='Rivet Networks|Killer';            Path='\\Killer|\\Rivet'; Info='Killer Network Service, Analytics, Dynamic Bandwidth Management and Smart AP Selection. They reorder and shape network traffic and can interfere with games and anti-cheat; the Killer network driver keeps working without them.'; Laptop=''; DriverStore=$true }
    @{ Id='nahimic';  Name='Nahimic / A-Volute'; Company='A-Volute|Nahimic';               Path='\\Nahimic|\\A-Volute|\\SonicStudio|\\SonicSuite'; Info='Nahimic and Sonic Studio audio effect services and their launcher tasks, bundled with many MSI, ASUS, Dell and Lenovo audio drivers. Sound keeps working without the effects.'; Laptop=''; DriverStore=$true }
)

function Get-BoardInstallerHint {
    param([string]$Maker)
    switch -Regex ($Maker) {
        '(?i)ASUS'        { return 'BIOS Advanced Mode (F7) > Tool > ASUS Armoury Crate > Download & Install ARMOURY CRATE app = Disabled (MyASUS on laptops uses the same switch where offered).' }
        '(?i)Micro-Star|MSI' { return 'BIOS Settings > Advanced (or Boot) > MSI Driver Utility Installer = Disabled.' }
        '(?i)GIGA-?BYTE'  { return 'BIOS Settings > IO Ports > GIGABYTE Utilities Downloader Configuration > Downloader = Disabled.' }
        '(?i)ASRock'      { return 'BIOS Tool > Auto Driver Installer = Disabled.' }
        '(?i)BIOSTAR'     { return 'Look for an auto driver or utility installer option under the BIOS Advanced or Tool menu and disable it.' }
        default           { return '' }
    }
}

function Get-FileCompanyName {
    param([string]$Path)
    if (-not $Path) { return '' }
    if ($script:FileCompanyCache.ContainsKey($Path)) { return $script:FileCompanyCache[$Path] }
    $company = ''
    try { if (Test-Path -LiteralPath $Path -PathType Leaf) { $company = [string][System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName } } catch { }
    $script:FileCompanyCache[$Path] = $company
    return $company
}

function Get-ExecutablePath {
    param([string]$CommandLine)
    if (-not $CommandLine) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"',1); if ($end -gt 1) { return $c.Substring(1,$end-1) } }
    if ($c -match '^(.+?\.exe)(\s|$)') { return $Matches[1] }
    return $c
}

function Get-VendorSoftware {
    $script:FileCompanyCache = @{}
    $result = @{}
    foreach ($p in $script:VendorSoftwareProfiles) { $result[$p.Id] = @{ Services=New-Object System.Collections.ArrayList; Tasks=New-Object System.Collections.ArrayList } }
    $winDir = [regex]::Escape($env:SystemRoot)
    $services = @()
    try {
        $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services')
        foreach ($n in $root.GetSubKeyNames()) {
            $k = $root.OpenSubKey($n)
            if (-not $k) { continue }
            try {
                $type = $k.GetValue('Type'); $image = [string]$k.GetValue('ImagePath')
                if ($null -ne $type -and ([int]$type -band 0x30) -and -not ([int]$type -band 0x0F) -and $image) { $services += [pscustomobject]@{ Name=$n; PathName=$image } }
            } finally { $k.Close() }
        }
        $root.Close()
    } catch { }
    foreach ($s in $services) {
        $exe = Get-ExecutablePath ([string]$s.PathName)
        if (-not $exe -or [string]$s.Name -match '(?i)print|spool|scan|^WinDefend$|^vg[ck]$') { continue }
        $inDriverStore = $exe -match '(?i)\\DriverStore\\'
        $company = Get-FileCompanyName $exe
        if ($company -match '(?i)^Microsoft' -and $exe -match ('(?i)^' + $winDir)) { continue }
        foreach ($p in $script:VendorSoftwareProfiles) {
            if ($inDriverStore -and -not $p.DriverStore) { continue }
            if ($exe -match ('(?i)' + $p.Path) -or ($company -and $company -match ('(?i)' + $p.Company))) { [void]$result[$p.Id].Services.Add([string]$s.Name); break }
        }
    }
    $tasks = New-Object System.Collections.ArrayList
    try {
        $sched = New-Object -ComObject Schedule.Service
        $sched.Connect()
        $stack = New-Object System.Collections.Stack
        $stack.Push($sched.GetFolder('\'))
        while ($stack.Count) {
            $folder = $stack.Pop()
            $taskPath = if ($folder.Path -eq '\') { '\' } else { $folder.Path + '\' }
            foreach ($job in @($folder.GetTasks(1))) {
                $cmds = @(); foreach ($act in @($job.Definition.Actions)) { if ($act.Type -eq 0 -and $act.Path) { $cmds += [string]$act.Path } }
                [void]$tasks.Add([pscustomobject]@{ TaskPath=$taskPath; TaskName=[string]$job.Name; Commands=$cmds })
            }
            foreach ($sub in @($folder.GetFolders(0))) { if ($sub.Path -ne '\Microsoft') { $stack.Push($sub) } }
        }
    } catch { }
    foreach ($tk in $tasks) {
        $exes = @($tk.Commands | ForEach-Object { Get-ExecutablePath $_ })
        $where = ('{0}{1}' -f $tk.TaskPath,$tk.TaskName)
        foreach ($p in $script:VendorSoftwareProfiles) {
            $hit = ($where -match ('(?i)^\\(' + [regex]::Escape($p.Name) + ')\\'))
            foreach ($exe in $exes) {
                if ($hit) { break }
                if ($exe -match '(?i)\\DriverStore\\' -and -not $p.DriverStore) { continue }
                $company = Get-FileCompanyName $exe
                if ($exe -match ('(?i)' + $p.Path) -or ($company -and $company -match ('(?i)' + $p.Company))) { $hit = $true }
            }
            if ($hit) { [void]$result[$p.Id].Tasks.Add(@{ Path=[string]$tk.TaskPath; Name=[string]$tk.TaskName }); break }
        }
    }
    return $result
}

$script:VendorSoftware = Get-VendorSoftware
foreach ($p in $script:VendorSoftwareProfiles) {
    $found = $script:VendorSoftware[$p.Id]
    if (($found.Services.Count + $found.Tasks.Count) -eq 0) { continue }
    $svcNames = @($found.Services | Select-Object -Unique)
    $apply = @(); $revert = @()
    foreach ($s in $svcNames) { $apply += @{kind='service';name=$s;start='Disabled';stop=$true;child=$s}; $revert += @{kind='service';name=$s;start='Manual'} }
    foreach ($tk in $found.Tasks) { $apply += @{kind='task';path=$tk.Path;name=$tk.Name;enable=$false}; $revert += @{kind='task';path=$tk.Path;name=$tk.Name;enable=$true} }
    $list = @()
    if ($svcNames.Count) { $list += ('services: ' + ($svcNames -join ', ')) }
    if ($found.Tasks.Count) { $list += ('scheduled tasks: ' + (@($found.Tasks | ForEach-Object { $_.Name }) -join ', ')) }
    $info = ('{0} Found on this PC by file publisher and install folder: {1}. Disabling stops their RGB lighting control, software fan curves, overlays and vendor update checks; BIOS fan curves and the drivers themselves keep working. Choose individual entries in Apply. Unticking restores each service start type and task state exactly as it was.' -f $p.Info,($list -join '; '))
    if ($p.Laptop) { $info = $info + ' ' + $p.Laptop }
    $script:Tweaks += (New-Tweak -Id ('vendor.' + $p.Id) -Tab 'Tweaks' -SubTab 'Services' -Group 'Board and PC maker software' -Label ('Pause {0} background software' -f $p.Name) -Risk 'Moderate' -Recommend $false -Detect @{kind='vendorSoftware';services=$svcNames;tasks=@($found.Tasks | ForEach-Object { $_.Path + $_.Name })} -Apply $apply -Revert $revert -Info $info)
}
 
$script:Tweaks += (New-Tweak -Id 'task.telemetry' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable telemetry tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Customer Experience Improvement Program\','\Microsoft\Windows\Feedback\Siuf\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Customer Experience Improvement Program\'},@{kind='taskFolder';path='\Microsoft\Windows\Feedback\Siuf\'},@{kind='taskFolder';path='\Microsoft\Windows\Autochk\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Customer Experience Improvement Program\';enable=$true},@{kind='taskFolder';path='\Microsoft\Windows\Feedback\Siuf\';enable=$true},@{kind='taskFolder';path='\Microsoft\Windows\Autochk\';enable=$true}) -Info 'Disables the CEIP, feedback (Siuf) and autochk proxy scheduled tasks that collect and upload usage data.')
$script:Tweaks += (New-Tweak -Id 'task.compat' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable compatibility scan tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Application Experience\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Application Experience\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Application Experience\';enable=$true}) -Info 'Application Experience tasks (Compatibility Appraiser, ProgramDataUpdater, StartupAppTask) that scan installed apps for the compatibility telemetry database.')
$script:Tweaks += (New-Tweak -Id 'task.sync' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Disable settings sync tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\SettingSync\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\SettingSync\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\SettingSync\';enable=$true}) -Info 'Scheduled tasks that sync input, mouse, pen, touchpad and theme settings to your Microsoft account.')
$script:Tweaks += (New-Tweak -Id 'task.diag' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable diagnostic tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\DiskDiagnostic\','\Microsoft\Windows\Windows Error Reporting\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\DiskDiagnostic\'},@{kind='taskFolder';path='\Microsoft\Windows\Windows Error Reporting\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\DiskDiagnostic\';enable=$true},@{kind='taskFolder';path='\Microsoft\Windows\Windows Error Reporting\';enable=$true}) -Info 'Disk diagnostic data collector and Windows Error Reporting queue tasks.')
$script:Tweaks += (New-Tweak -Id 'task.memdiag' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Maintenance' -Label 'Pause scheduled memory checks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\MemoryDiagnostic\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\MemoryDiagnostic\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\MemoryDiagnostic\';enable=$true}) -Info 'Disables only scheduled Windows Memory Diagnostic tasks. It does not disable memory testing you launch yourself; schedule a manual check if you suspect RAM errors.')
$script:Tweaks += (New-Tweak -Id 'task.updatenotification' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable update notification manager' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('UpdateNotificationMgr*','USO_UxBroker_Display*')} -Apply @(@{kind='taskNamePattern';patterns=@('UpdateNotificationMgr*','USO_UxBroker_Display*')}) -Revert @(@{kind='taskNamePattern';patterns=@('UpdateNotificationMgr*','USO_UxBroker_Display*');enable=$true}) -Info 'Disables only matching Update Notification Manager / user-experience broker tasks when installed. Windows Update scans and servicing tasks are not included; update notifications may be reduced.' )
$script:Tweaks += (New-Tweak -Id 'task.residentlogon' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sign-in' -Label 'Disable resident logon tasks' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('User_Feed_Synchronization*','UserTask-Roam*')} -Apply @(@{kind='taskNamePattern';patterns=@('User_Feed_Synchronization*','UserTask-Roam*')}) -Revert @(@{kind='taskNamePattern';patterns=@('User_Feed_Synchronization*','UserTask-Roam*');enable=$true}) -Info 'Disables detected user feed/settings roam logon tasks only. This may stop RSS/feed or settings synchronization for the current Windows user.' )
$script:Tweaks += (New-Tweak -Id 'task.maps' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Cloud apps' -Label 'Disable unused feature tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Maps\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Maps\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Maps\';enable=$true}) -Info 'Maps data check/download tasks for the Windows Maps app.')
$script:Tweaks += (New-Tweak -Id 'task.maintenance' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Maintenance' -Label 'Disable background maintenance tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Maintenance\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Maintenance\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Maintenance\';enable=$true}) -Info 'Windows automatic maintenance scheduling. Disabling can defer cleanup and maintenance work.')
$script:Tweaks += (New-Tweak -Id 'task.print' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Backup and printing' -Label 'Disable printing tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Printing\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Printing\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Printing\';enable=$true}) -Info 'Printing folder tasks, including print queue cleanup/diagnostics where available. Does not disable the Print Spooler service.')
$script:Tweaks += (New-Tweak -Id 'task.dotnet' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Maintenance' -Label 'Disable .NET precompile tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\.NET Framework\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\.NET Framework\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\.NET Framework\';enable=$true}) -Info 'Stops scheduled .NET optimization tasks. Apps may take longer to launch after framework updates.')
$script:Tweaks += (New-Tweak -Id 'task.backup' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Backup and printing' -Label 'Disable Windows Backup tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Windows Backup\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Windows Backup\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Windows Backup\';enable=$true}) -Info 'Windows Backup scheduled tasks. Keep enabled if you use Windows Backup.')
$script:Tweaks += (New-Tweak -Id 'task.cloudexperience' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Disable CloudExperienceHost object task' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\CloudExperienceHost\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\CloudExperienceHost\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\CloudExperienceHost\';enable=$true}) -Info 'CloudExperienceHost tasks used for account and first-run experiences. Disabling may affect setup or account onboarding.')
$script:Tweaks += (New-Tweak -Id 'task.workplace' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Disable Workplace Join tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Workplace Join\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Workplace Join\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Workplace Join\';enable=$true}) -Info 'Workplace Join registration tasks. Disable only on personal PCs not joined to a work/school organization.')
$script:Tweaks += (New-Tweak -Id 'task.edgeupdate' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable Edge update tasks' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('MicrosoftEdgeUpdateTaskMachine*')} -Apply @(@{kind='taskNamePattern';patterns=@('MicrosoftEdgeUpdateTaskMachine*')},@{kind='taskFolder';path='\Microsoft\EdgeUpdate\'}) -Revert @(@{kind='taskNamePattern';patterns=@('MicrosoftEdgeUpdateTaskMachine*');enable=$true},@{kind='taskFolder';path='\Microsoft\EdgeUpdate\';enable=$true}) -Info 'Microsoft Edge scheduled update tasks. Disabling can leave the browser outdated; prefer manual updates if turned off.')
$script:Tweaks += (New-Tweak -Id 'task.onedrive' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Cloud apps' -Label 'Disable OneDrive tasks' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\OneDrive\')} -Apply @(@{kind='taskFolder';path='\Microsoft\OneDrive\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\OneDrive\';enable=$true}) -Info 'OneDrive scheduled sync/update tasks. Files already synced remain on disk; future sync may stop.')
$script:Tweaks += (New-Tweak -Id 'task.office' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable Office telemetry tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Office\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Office\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Office\';enable=$true}) -Info 'Office background telemetry tasks when present. Office update tasks may share this folder, so inspect individual entries in Apply.')
$script:Tweaks += (New-Tweak -Id 'task.googleupdate' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable Google updater tasks' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('GoogleUpdateTaskMachineCore','GoogleUpdateTaskMachineUA')} -Apply @(@{kind='taskNamePattern';patterns=@('GoogleUpdateTaskMachineCore','GoogleUpdateTaskMachineUA')}) -Revert @(@{kind='taskNamePattern';patterns=@('GoogleUpdateTaskMachineCore','GoogleUpdateTaskMachineUA');enable=$true}) -Info 'Disables Google machine update tasks when installed. Chrome and other Google apps will need manual updates.')
$script:Tweaks += (New-Tweak -Id 'task.adobeupdate' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable Adobe Acrobat update task' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('Adobe Acrobat Update Task')} -Apply @(@{kind='taskNamePattern';patterns=@('Adobe Acrobat Update Task')}) -Revert @(@{kind='taskNamePattern';patterns=@('Adobe Acrobat Update Task');enable=$true}) -Info 'Disables the Acrobat updater task when present. Acrobat will need manual updates.')
$script:Tweaks += (New-Tweak -Id 'task.deviceinfo' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Hardware' -Label 'Disable unused hardware tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Device Information\','\Microsoft\Windows\Bluetooth\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Device Information\'},@{kind='taskFolder';path='\Microsoft\Windows\Bluetooth\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Device Information\';enable=$true},@{kind='taskFolder';path='\Microsoft\Windows\Bluetooth\';enable=$true}) -Info 'Device information and Bluetooth maintenance tasks. Disabling can delay device inventory or Bluetooth maintenance.')
 
$script:Tweaks += (New-Tweak -Id 'startup.onedrive' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Windows and Microsoft' -Label 'Disable OneDrive startup' -Risk 'Moderate' -Detect @{kind='runkey';name='OneDrive'} -Apply @(@{kind='runkey';name='OneDrive';remove=$true}) -Revert @() -Info 'Removes OneDrive from startup. Files already synced stay on disk; OneDrive can still be opened manually.')
$script:Tweaks += (New-Tweak -Id 'app.edge.background' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Stop Edge background apps and preloading' -Risk 'Safe' -Detect @{kind='anyPath';paths=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='StartupBoostEnabled';value=0;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='BackgroundModeEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='StartupBoostEnabled'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='BackgroundModeEnabled'}) -Info 'Stops Edge from keeping processes running after you close it and from preloading at sign-in.')
$script:Tweaks += (New-Tweak -Id 'startup.steam' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable Steam startup' -Risk 'Safe' -Detect @{kind='runkey';name='Steam'} -Apply @(@{kind='runkey';name='Steam';remove=$true}) -Revert @() -Info 'Stops Steam from starting with Windows. Steam and games remain available when launched manually.')
$script:Tweaks += (New-Tweak -Id 'startup.epic' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable Epic Games startup' -Risk 'Safe' -Detect @{kind='runkey';name='EpicGamesLauncher'} -Apply @(@{kind='runkey';name='EpicGamesLauncher';remove=$true}) -Revert @() -Info 'Stops Epic Games Launcher from starting with Windows. Epic games remain available when launched manually.')
$script:Tweaks += (New-Tweak -Id 'startup.battlenet' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable Battle.net startup' -Risk 'Safe' -Detect @{kind='runkey';name='Battle.net'} -Apply @(@{kind='runkey';name='Battle.net';remove=$true}) -Revert @() -Info 'Stops Battle.net from starting with Windows. Blizzard games remain available when launched manually.')
$script:Tweaks += (New-Tweak -Id 'startup.ea' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable EA app startup' -Risk 'Safe' -Detect @{kind='runkey';name='EADesktop'} -Apply @(@{kind='runkey';name='EADesktop';remove=$true}) -Revert @() -Info 'Stops the EA app from starting with Windows. EA games remain available when launched manually.')
$script:Tweaks += (New-Tweak -Id 'startup.ubisoft' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable Ubisoft Connect startup' -Risk 'Safe' -Detect @{kind='runkey';name='Uplay'} -Apply @(@{kind='runkey';name='Uplay';remove=$true}) -Revert @() -Info 'Stops Ubisoft Connect from starting with Windows. Ubisoft games remain available when launched manually.')
$script:Tweaks += (New-Tweak -Id 'task.office.telemetry' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Turn off Microsoft Office telemetry' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('OfficeTelemetryAgent*')} -Apply @(@{kind='taskNamePattern';patterns=@('OfficeTelemetryAgent*')},@{kind='registry';path='HKCU:\Software\Policies\Microsoft\office\16.0\common';name='qmenable';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Policies\Microsoft\office\16.0\common';name='sendcustomerdata';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Office\Common\ClientTelemetry';name='DisableTelemetry';value=1;type='DWord'}) -Revert @(@{kind='taskNamePattern';patterns=@('OfficeTelemetryAgent*');enable=$true},@{kind='registryDel';path='HKCU:\Software\Policies\Microsoft\office\16.0\common';name='qmenable'},@{kind='registryDel';path='HKCU:\Software\Policies\Microsoft\office\16.0\common';name='sendcustomerdata'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Office\Common\ClientTelemetry';name='DisableTelemetry'}) -Info 'Only shown when Microsoft Office is installed. Disables the Office telemetry agent tasks that run at sign-in and on a schedule, and turns off the Office customer experience program and client telemetry upload. Office, its updates and activation keep working.')
$script:Tweaks += (New-Tweak -Id 'task.gpu.nv.reports' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable NVIDIA crash and telemetry report tasks' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('NvTmRep*','NvTmMon*')} -Apply @(@{kind='taskNamePattern';patterns=@('NvTmRep*','NvTmMon*')}) -Revert @(@{kind='taskNamePattern';patterns=@('NvTmRep*','NvTmMon*');enable=$true}) -Info 'NVIDIA crash-report and telemetry upload tasks. The driver keeps working; NVIDIA just stops receiving these reports.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.nv.updates' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable NVIDIA driver and app update checks' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('NvDriverUpdateCheckDaily*','NVIDIA GeForce Experience SelfUpdate*','NvNodeLauncher*')} -Apply @(@{kind='taskNamePattern';patterns=@('NvDriverUpdateCheckDaily*','NVIDIA GeForce Experience SelfUpdate*','NvNodeLauncher*')}) -Revert @(@{kind='taskNamePattern';patterns=@('NvDriverUpdateCheckDaily*','NVIDIA GeForce Experience SelfUpdate*','NvNodeLauncher*');enable=$true}) -Info 'Daily NVIDIA driver/app update checks. You will need to check for driver updates yourself in the NVIDIA app or on nvidia.com.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.nv.profiles' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable NVIDIA game profile updater' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('NvProfileUpdaterDaily*','NvProfileUpdaterOnLogon*')} -Apply @(@{kind='taskNamePattern';patterns=@('NvProfileUpdaterDaily*','NvProfileUpdaterOnLogon*')}) -Revert @(@{kind='taskNamePattern';patterns=@('NvProfileUpdaterDaily*','NvProfileUpdaterOnLogon*');enable=$true}) -Info 'Downloads updated per-game driver profiles between driver releases. New driver installs still bring the latest profiles.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.amd.software' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable AMD Software at sign-in' -Risk 'Moderate' -Detect @{kind='taskAnyNamePattern';patterns=@('StartCN','StartCNBM')} -Apply @(@{kind='taskNamePattern';patterns=@('StartCN','StartCNBM')}) -Revert @(@{kind='taskNamePattern';patterns=@('StartCN','StartCNBM');enable=$true}) -Info 'Starts AMD Software: Adrenalin Edition at sign-in. With it off, the in-game overlay, hotkeys and tray icon load only after you open AMD Software yourself.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.amd.cpumetrics' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable AMD Software CPU metrics server' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('AMDRyzenMasterSDKTask')} -Apply @(@{kind='taskNamePattern';patterns=@('AMDRyzenMasterSDKTask')}) -Revert @(@{kind='taskNamePattern';patterns=@('AMDRyzenMasterSDKTask');enable=$true}) -Info 'AMDRyzenMasterSDKTask starts cpumetricsserver.exe at sign-in. It uses the Ryzen Master monitoring SDK that AMD Software installs with the graphics driver to feed CPU clock, temperature and usage to the AMD Software performance overlay. With it off, the overlay shows GPU metrics only.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.amd.dvr'-Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable AMD recording at sign-in' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('StartDVR')} -Apply @(@{kind='taskNamePattern';patterns=@('StartDVR')}) -Revert @(@{kind='taskNamePattern';patterns=@('StartDVR');enable=$true}) -Info 'Starts AMD ReLive recording and Instant Replay at sign-in. Leave it on if you record gameplay with AMD Software.' )
$script:Tweaks += (New-Tweak -Id 'task.gpu.amd.updates' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'GPU software' -Label 'Disable AMD update and telemetry tasks' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('AMDAutoUpdate*','AMDLinkUpdate*','ModifyLinkUpdate*','AMDInstallLauncher*','AMDInstallUEP*')} -Apply @(@{kind='taskNamePattern';patterns=@('AMDAutoUpdate*','AMDLinkUpdate*','ModifyLinkUpdate*','AMDInstallLauncher*','AMDInstallUEP*')}) -Revert @(@{kind='taskNamePattern';patterns=@('AMDAutoUpdate*','AMDLinkUpdate*','ModifyLinkUpdate*','AMDInstallLauncher*','AMDInstallUEP*');enable=$true}) -Info 'AMD software update checks and User Experience Program install tasks. You will need to check for driver updates yourself in AMD Software.' )
$script:Tweaks += (New-Tweak -Id 'startup.nvidia' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable NVIDIA app startup' -Risk 'Safe' -Detect @{kind='runkey';name='NvBackend'} -Apply @(@{kind='runkey';name='NvBackend';remove=$true}) -Revert @() -Info 'Disables the NVIDIA companion/tray startup entry when present. The graphics driver remains installed and active.')
$script:Tweaks += (New-Tweak -Id 'startup.realtek' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable Realtek Audio Console startup' -Risk 'Moderate' -Detect @{kind='runkey';name='RtkAudUService'} -Apply @(@{kind='runkey';name='RtkAudUService';remove=$true}) -Revert @() -Info 'Stops the Realtek audio console companion from launching at sign-in. Basic audio continues; console enhancements may not load until opened.')
$script:Tweaks += (New-Tweak -Id 'startup.razer' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable Razer Synapse startup' -Risk 'Moderate' -Detect @{kind='runkey';name='Razer Synapse'} -Apply @(@{kind='runkey';name='Razer Synapse';remove=$true}) -Revert @() -Info 'Stops Razer Synapse from launching at sign-in. Device profiles/macros may require Synapse running.')
$script:Tweaks += (New-Tweak -Id 'startup.logitech' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable Logitech G HUB startup' -Risk 'Moderate' -Detect @{kind='runkey';name='lghub'} -Apply @(@{kind='runkey';name='lghub';remove=$true}) -Revert @() -Info 'Stops Logitech G HUB from launching at sign-in. Device profiles/macros may not load until G HUB starts.')
$script:Tweaks += (New-Tweak -Id 'startup.corsair' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable Corsair iCUE startup' -Risk 'Moderate' -Detect @{kind='runkey';name='Corsair'} -Apply @(@{kind='runkey';name='Corsair';remove=$true}) -Revert @() -Info 'Stops Corsair iCUE from launching at sign-in. Lighting and hardware profiles may not load until iCUE starts.')
$script:Tweaks += (New-Tweak -Id 'startup.steelseries' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable SteelSeries GG startup' -Risk 'Moderate' -Detect @{kind='runkey';name='SteelSeriesGG'} -Apply @(@{kind='runkey';name='SteelSeriesGG';remove=$true}) -Revert @() -Info 'Stops SteelSeries GG from launching at sign-in. Sonar and peripheral features may not load until it starts.')
$script:Tweaks += (New-Tweak -Id 'startup.asus' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable ASUS Armoury Crate startup' -Risk 'Moderate' -Detect @{kind='runkey';name='ArmouryCrate'} -Apply @(@{kind='runkey';name='ArmouryCrate';remove=$true}) -Revert @() -Info 'Stops Armoury Crate from launching at sign-in. Fan, lighting, or board profiles may not load until started.')
$script:Tweaks += (New-Tweak -Id 'startup.msi' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable MSI Center startup' -Risk 'Moderate' -Detect @{kind='runkey';name='MSI Center'} -Apply @(@{kind='runkey';name='MSI Center';remove=$true}) -Revert @() -Info 'Stops MSI Center from launching at sign-in. Device profiles and update notifications may not load until started.')
$script:Tweaks += (New-Tweak -Id 'startup.gigabyte' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Peripheral software' -Label 'Disable Gigabyte Control Center startup' -Risk 'Moderate' -Detect @{kind='runkey';name='GCC'} -Apply @(@{kind='runkey';name='GCC';remove=$true}) -Revert @() -Info 'Stops Gigabyte Control Center from launching at sign-in. Board and device profiles may not load until started.')
$script:Tweaks += (New-Tweak -Id 'startup.all' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Windows and Microsoft' -Label 'Disable all startup apps' -Risk 'Safe' -Detect @{kind='runkeyAll'} -Apply @(@{kind='runkeyAll';enable=$false},@{kind='appxStartup';families=@('*');enable=$false}) -Revert @(@{kind='runkeyAll';enable=$true},@{kind='appxStartup';families=@('*');enable=$true}) -Info 'Turns off every app that starts with Windows: the Run entries (Task Manager > Startup apps) and Store-app startup tasks. Anti-cheat (Riot Vanguard, FACEIT, EasyAntiCheat, BattlEye) and Windows Security stay on. Unticking turns each one back to how it was.' -Warn 'Apps you rely on at sign-in (Discord, Steam, audio or RGB software, cloud sync) no longer start until you open them; re-enable single apps in Task Manager > Startup apps.')
$script:Tweaks += (New-Tweak -Id 'startup.discord' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Chat and creative apps' -Label 'Disable Discord startup' -Risk 'Safe' -Detect @{kind='runkey';name='Discord'} -Apply @(@{kind='runkey';name='Discord';remove=$true}) -Revert @() -Info 'Stops Discord from launching at sign-in. Discord remains available when opened manually.')
$script:Tweaks += (New-Tweak -Id 'startup.riot' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Game launchers' -Label 'Disable Riot Client startup' -Risk 'Safe' -Detect @{kind='runkey';name='RiotClient'} -Apply @(@{kind='runkey';name='RiotClient';remove=$true}) -Revert @() -Info 'Stops Riot Client from launching at sign-in. Riot games can still be launched manually.')
$script:Tweaks += (New-Tweak -Id 'startup.adobe' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Chat and creative apps' -Label 'Disable Adobe Creative Cloud startup' -Risk 'Moderate' -Detect @{kind='runkey';name='Adobe Creative Cloud'} -Apply @(@{kind='runkey';name='Adobe Creative Cloud';remove=$true}) -Revert @() -Info 'Stops Creative Cloud desktop from launching at sign-in. Cloud sync and update notifications wait until it is opened.')
$script:Tweaks += (New-Tweak -Id 'startup.wallpaper' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Chat and creative apps' -Label 'Disable Wallpaper Engine and Rainmeter startup' -Risk 'Safe' -Detect @{kind='runkeyAny';names=@('Wallpaper Engine','Rainmeter')} -Apply @(@{kind='runkey';name='Wallpaper Engine';remove=$true},@{kind='runkey';name='Rainmeter';remove=$true}) -Revert @() -Info 'Stops installed Wallpaper Engine and/or Rainmeter startup entries; wallpaper effects remain inactive until the app is launched.')
$script:Tweaks += (New-Tweak -Id 'startup.securitytray' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Windows and Microsoft' -Label 'Hide Windows Security tray icon' -Risk 'Moderate' -Detect @{kind='runkey';name='SecurityHealth'} -Apply @(@{kind='runkey';name='SecurityHealth';remove=$true}) -Revert @() -Info 'Hides the Windows Security notification icon at sign-in. Defender and Windows Security protections continue running.')
 
$script:Tweaks += New-ServiceGroup -Id 'svc.ai.fabric' -Tab 'Tweaks' -SubTab 'Services' -Group 'Cloud and AI' -Label 'Stop the Windows AI Fabric service' -Risk 'Moderate' -Services @('WSAIFabricSvc') -Info 'Windows AI Fabric (WSAIFabricSvc, 24H2 and later, mainly Copilot+ PCs) hosts local AI models for Recall, Click to Do and other on-device AI features. Its WorkloadsSessionHost workers can hold several GB of RAM. Those AI features stop working while it is off.'
$script:Tweaks += New-ServiceGroup -Id 'svc.xbox.live' -Tab 'Tweaks' -SubTab 'Services' -Group 'Xbox and gaming' -Label 'Stop Xbox Live and accessory services' -Risk 'Risky' -Services @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc') -Info 'Xbox Live sign-in, cloud saves, Xbox networking and Xbox accessory management. Game Pass, Microsoft Store games, cloud saves and Xbox controller configuration stop working until these are restored.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.wer' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop Windows Error Reporting service' -Risk 'Moderate' -Services @('WerSvc') -Info 'Collects and sends crash and hang reports to Microsoft. Apps still crash and log events normally; reports are no longer queued or uploaded.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.diaghub' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop diagnostic collectors and troubleshooters' -Risk 'Moderate' -Services @('diagsvc','diagnosticshub.standardcollector.service','TroubleshootingSvc') -Info 'Diagnostic Execution, Diagnostics Hub collector (used by Visual Studio profiling) and Recommended Troubleshooting services. Automatic troubleshooter recommendations stop.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.trkwks' -Tab 'Tweaks' -SubTab 'Services' -Group 'Background' -Label 'Stop distributed link tracking' -Risk 'Safe' -RevertType 'Automatic' -Services @('TrkWks') -Info 'Keeps shortcuts pointing at NTFS files that move between computers on a domain network. Not needed on a home PC.'
$script:Tweaks += New-ServiceGroup -Id 'svc.bg.cloudbackup' -Tab 'Tweaks' -SubTab 'Services' -Group 'Storage and backup' -Label 'Stop Windows Backup cloud sync helper' -Risk 'Moderate' -Recommend $false -Services @('CloudBackupRestoreSvc','CloudBackupRestoreSvc_*') -Info 'Cloud Backup and Restore (24H2 and later) backs up apps and settings to your Microsoft account for the Windows Backup app. Settings no longer back up or restore while it is off.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.ics' -Tab 'Tweaks' -SubTab 'Services' -Group 'Mobile and radio' -Label 'Stop Internet Connection Sharing' -Risk 'Moderate' -Recommend $false -Services @('SharedAccess') -Info 'Shares this PC''s connection with other devices, and is used by Mobile hotspot. Your own Wi-Fi and Ethernet are not affected.'
$script:Tweaks += New-ServiceGroup -Id 'svc.net.winrm' -Tab 'Tweaks' -SubTab 'Services' -Group 'Remote access' -Label 'Close Windows Remote Management' -Risk 'Safe' -Services @('WinRM') -Info 'WinRM accepts PowerShell remoting and remote management commands. Not used on a personal PC.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.autoplay' -Tab 'Tweaks' -SubTab 'Services' -Group 'Shell and visuals' -Label 'Stop AutoPlay device detection' -Risk 'Moderate' -Recommend $false -RevertType 'Automatic' -Services @('ShellHWDetection') -Info 'Shell Hardware Detection shows AutoPlay prompts for USB drives, phones and discs. Drives still appear in File Explorer.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.language' -Tab 'Tweaks' -SubTab 'Services' -Group 'Background' -Label 'Stop language pack provisioning' -Risk 'Moderate' -Recommend $false -Services @('LxpSvc') -Info 'Language Experience Service installs and updates display languages. Adding a new Windows language will fail while it is off.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.printbroker' -Tab 'Tweaks' -SubTab 'Services' -Group 'Printing' -Label 'Stop newer print and scan brokers' -Risk 'Moderate' -Recommend $false -Services @('PrintDeviceConfigurationService','PrintScanBrokerService') -Info 'Print device configuration and the print/scan broker added in Windows 11 24H2. Leave them on if you print or scan.'
$script:Tweaks += New-ServiceGroup -Id 'svc.dev.penuser' -Tab 'Tweaks' -SubTab 'Services' -Group 'Input devices' -Label 'Stop pen button actions' -Risk 'Safe' -Services @('PenService','PenService_*') -Info 'Per-user Pen Service that runs the action for a pen''s tail button. Not needed without a pen.'
$script:Tweaks += New-ServiceGroup -Id 'svc.media.npsm' -Tab 'Tweaks' -SubTab 'Services' -Group 'Media sharing' -Label 'Stop Now Playing media sessions' -Risk 'Moderate' -Recommend $false -Services @('NPSMSvc','NPSMSvc_*') -Info 'Now Playing Session Manager drives the media controls in Quick Settings and the volume flyout. Those controls disappear while it is off.'
$script:Tweaks += New-ServiceGroup -Id 'svc.feat.wsl9p' -Tab 'Tweaks' -SubTab 'Services' -Group 'Virtualization' -Label 'Stop WSL file sharing helper' -Risk 'Moderate' -Recommend $false -Services @('P9RdrService','P9RdrService_*') -Info 'Plan 9 Redirector lets Windows open files inside WSL distributions. Leave it on if you use WSL.'

$script:Tweaks += (New-Tweak -Id 'task.sustainability' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable energy sustainability reporting tasks' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Sustainability\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Sustainability\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Sustainability\';enable=$true}) -Info 'Sustainability tasks added in 24H2 (power grid forecast and energy telemetry). Energy recommendations in Settings may stop updating.')
$script:Tweaks += (New-Tweak -Id 'task.powerdiag' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable power efficiency diagnostics task' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Power Efficiency Diagnostics\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Power Efficiency Diagnostics\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Power Efficiency Diagnostics\';enable=$true}) -Info 'Periodically analyses power settings and reports energy-efficiency problems.')
$script:Tweaks += (New-Tweak -Id 'task.nettrace' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable network information gathering task' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\NetTrace\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\NetTrace\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\NetTrace\';enable=$true}) -Info 'GatherNetworkInfo collects network configuration for the Customer Experience Improvement Program. Networking is not affected.')
$script:Tweaks += (New-Tweak -Id 'task.diagnosis' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable scheduled troubleshooting scans' -Risk 'Moderate' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Diagnosis\','\Microsoft\Windows\WDI\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Diagnosis\'},@{kind='taskFolder';path='\Microsoft\Windows\WDI\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Diagnosis\';enable=$true},@{kind='taskFolder';path='\Microsoft\Windows\WDI\';enable=$true}) -Info 'Scheduled diagnosis and recommended-troubleshooting scans. You can still run troubleshooters yourself from Settings.')
$script:Tweaks += (New-Tweak -Id 'task.speech' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Cloud apps' -Label 'Disable speech model download task' -Risk 'Moderate' -Recommend $false -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Speech\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Speech\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Speech\';enable=$true}) -Info 'Downloads updated speech recognition models. Voice typing and voice access keep their current models.')
$script:Tweaks += (New-Tweak -Id 'task.location' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Cloud apps' -Label 'Disable location notification tasks' -Risk 'Moderate' -Recommend $false -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Location\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Location\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Location\';enable=$true}) -Info 'Location notification and dialog tasks. Apps that use location may stop showing their location-in-use prompts.')
$script:Tweaks += (New-Tweak -Id 'task.familysafety' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Disable Family Safety tasks' -Risk 'Moderate' -Recommend $false -Detect @{kind='taskAnyNamePattern';patterns=@('FamilySafetyMonitor*','FamilySafetyRefreshTask*')} -Apply @(@{kind='taskNamePattern';patterns=@('FamilySafetyMonitor*','FamilySafetyRefreshTask*')}) -Revert @(@{kind='taskNamePattern';patterns=@('FamilySafetyMonitor*','FamilySafetyRefreshTask*');enable=$true}) -Info 'Microsoft Family Safety monitoring and policy refresh. Family screen-time limits and reports stop for this PC.')
$script:Tweaks += (New-Tweak -Id 'task.cloudrestore' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Backup and printing' -Label 'Disable Windows Backup cloud restore tasks' -Risk 'Moderate' -Recommend $false -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\CloudRestore\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\CloudRestore\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\CloudRestore\';enable=$true}) -Info 'Backup and restore tasks used by the Windows Backup app (24H2 and later).')
$script:Tweaks += (New-Tweak -Id 'task.helloface' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Maintenance' -Label 'Disable Windows Hello face cleanup task' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\HelloFace\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\HelloFace\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\HelloFace\';enable=$true}) -Info 'Removes the Hello face feature package on PCs without an IR camera. Face sign-in itself is not affected.')
$script:Tweaks += (New-Tweak -Id 'task.mediasharing' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Maintenance' -Label 'Disable media library sharing task' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Windows Media Sharing\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Windows Media Sharing\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Windows Media Sharing\';enable=$true}) -Info 'Updates the shared media library for Windows Media Player network sharing.')
$script:Tweaks += (New-Tweak -Id 'task.devicesetup' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Hardware' -Label 'Disable device metadata refresh task' -Risk 'Moderate' -Recommend $false -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\Device Setup\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\Device Setup\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\Device Setup\';enable=$true}) -Info 'Downloads device names and icons for Devices and Printers. Drivers still install normally.')
$script:Tweaks += (New-Tweak -Id 'task.languagesync' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Disable language settings sync task' -Risk 'Safe' -Detect @{kind='taskAny';paths=@('\Microsoft\Windows\International\')} -Apply @(@{kind='taskFolder';path='\Microsoft\Windows\International\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\Windows\International\';enable=$true}) -Info 'Synchronizes language and keyboard settings with your Microsoft account.')
$script:Tweaks += (New-Tweak -Id 'task.xblgamesave' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Cloud apps' -Label 'Disable Xbox cloud save sync task' -Risk 'Risky' -Detect @{kind='taskAny';paths=@('\Microsoft\XblGameSave\')} -Apply @(@{kind='taskFolder';path='\Microsoft\XblGameSave\'}) -Revert @(@{kind='taskFolder';path='\Microsoft\XblGameSave\';enable=$true}) -Info 'Background sync of Xbox and PC Game Pass cloud saves. Saves may not upload until it is re-enabled.')
$script:Tweaks += (New-Tweak -Id 'task.braveupdate' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable Brave updater tasks' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('BraveSoftwareUpdateTaskMachine*')} -Apply @(@{kind='taskNamePattern';patterns=@('BraveSoftwareUpdateTaskMachine*')}) -Revert @(@{kind='taskNamePattern';patterns=@('BraveSoftwareUpdateTaskMachine*');enable=$true}) -Info 'Brave still updates itself when you open its About page.')
$script:Tweaks += (New-Tweak -Id 'task.operaupdate' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Updaters' -Label 'Disable Opera updater tasks' -Risk 'Safe' -Detect @{kind='taskAnyNamePattern';patterns=@('Opera*scheduled Autoupdate*')} -Apply @(@{kind='taskNamePattern';patterns=@('Opera*scheduled Autoupdate*')}) -Revert @(@{kind='taskNamePattern';patterns=@('Opera*scheduled Autoupdate*');enable=$true}) -Info 'Opera and Opera GX scheduled update checks. Opera still updates when it is running.')

$script:Tweaks += (New-Tweak -Id 'startup.pkg.teams' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable new Teams startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('MSTeams_8wekyb3d8bbwe')} -Apply @(@{kind='appxStartup';families=@('MSTeams_8wekyb3d8bbwe')}) -Revert @(@{kind='appxStartup';families=@('MSTeams_8wekyb3d8bbwe');enable=$true}) -Info 'Stops the new Microsoft Teams app from starting at sign-in.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.phonelink' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable Phone Link app startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('Microsoft.YourPhone_8wekyb3d8bbwe')} -Apply @(@{kind='appxStartup';families=@('Microsoft.YourPhone_8wekyb3d8bbwe')}) -Revert @(@{kind='appxStartup';families=@('Microsoft.YourPhone_8wekyb3d8bbwe');enable=$true}) -Info 'Stops Phone Link from starting at sign-in. It still opens from Start.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.copilot' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable Copilot app startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('Microsoft.Copilot_8wekyb3d8bbwe')} -Apply @(@{kind='appxStartup';families=@('Microsoft.Copilot_8wekyb3d8bbwe')}) -Revert @(@{kind='appxStartup';families=@('Microsoft.Copilot_8wekyb3d8bbwe');enable=$true}) -Info 'Stops the Copilot app from starting at sign-in.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.xbox' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable Xbox app startup task' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('Microsoft.GamingApp_8wekyb3d8bbwe')} -Apply @(@{kind='appxStartup';families=@('Microsoft.GamingApp_8wekyb3d8bbwe')}) -Revert @(@{kind='appxStartup';families=@('Microsoft.GamingApp_8wekyb3d8bbwe');enable=$true}) -Info 'Stops the Xbox app from starting at sign-in. Game Pass games still launch normally.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.whatsapp' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable WhatsApp startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('5319275A.WhatsAppDesktop_cv1g1gvanyjgm')} -Apply @(@{kind='appxStartup';families=@('5319275A.WhatsAppDesktop_cv1g1gvanyjgm')}) -Revert @(@{kind='appxStartup';families=@('5319275A.WhatsAppDesktop_cv1g1gvanyjgm');enable=$true}) -Info 'Stops WhatsApp from starting at sign-in. Messages arrive when you open it.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.spotify' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable Spotify (Store) startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('SpotifyAB.SpotifyMusic_zpdnekdrzrea0')} -Apply @(@{kind='appxStartup';families=@('SpotifyAB.SpotifyMusic_zpdnekdrzrea0')}) -Revert @(@{kind='appxStartup';families=@('SpotifyAB.SpotifyMusic_zpdnekdrzrea0');enable=$true}) -Info 'Stops the Microsoft Store version of Spotify from starting at sign-in.')
$script:Tweaks += (New-Tweak -Id 'startup.pkg.outlook' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Store app startup' -Label 'Disable new Outlook startup' -Risk 'Safe' -Detect @{kind='appxStartup';families=@('Microsoft.OutlookForWindows_8wekyb3d8bbwe')} -Apply @(@{kind='appxStartup';families=@('Microsoft.OutlookForWindows_8wekyb3d8bbwe')}) -Revert @(@{kind='appxStartup';families=@('Microsoft.OutlookForWindows_8wekyb3d8bbwe');enable=$true}) -Info 'Stops the new Outlook app from starting at sign-in.')

$script:Tweaks += (New-Tweak -Id 'feat.ai.recallavail' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Remove Recall from this PC' -Risk 'Moderate' -Recommend $true -Detect @{kind='appxPattern';pattern='*Client.AIX*';minBuild=26100} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='AllowRecallEnablement';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='AllowRecallEnablement'}) -Info 'AllowRecallEnablement policy (24H2 and later, Copilot+ PCs). Recall becomes unavailable and Windows removes its components after a restart. Unticking makes Recall available again; Windows downloads it back.')
$script:Tweaks += (New-Tweak -Id 'feat.ai.settingsagent' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off the AI agent in Settings search' -Risk 'Safe' -Recommend $true -Detect @{kind='registry';minBuild=26100} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableSettingsAgent';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableSettingsAgent'}) -Info 'DisableSettingsAgent policy. Settings search goes back to plain keyword search instead of the on-device AI agent (Copilot+ PCs).')
$script:Tweaks += (New-Tweak -Id 'feat.ai.paint' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off AI features in Paint' -Risk 'Safe' -Recommend $true -Detect @{kind='appx';name='Microsoft.Paint'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableCocreator';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableGenerativeFill';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableImageCreator';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableCocreator'},@{kind='registryDel';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableGenerativeFill'},@{kind='registryDel';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint';name='DisableImageCreator'}) -Info 'Paint policies (22H2 and later) that remove Cocreator, Generative fill and Image Creator. Normal drawing tools are unchanged.')
$script:Tweaks += (New-Tweak -Id 'feat.ai.notepad' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off AI features in Notepad' -Risk 'Safe' -Recommend $true -Detect @{kind='appx';name='Microsoft.WindowsNotepad'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\WindowsNotepad';name='DisableAIFeatures';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\WindowsNotepad';name='DisableAIFeatures'}) -Info 'Notepad AI policy (Notepad 11.2503 and later): removes Copilot rewrite, summarize and write features from Notepad.')
$script:Tweaks += (New-Tweak -Id 'feat.ai.edge' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off the Copilot sidebar in Edge' -Risk 'Safe' -Recommend $true -Detect @{kind='anyPath';paths=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='HubsSidebarEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='HubsSidebarEnabled'}) -Info 'Edge HubsSidebarEnabled policy: hides the Edge sidebar and its Copilot pane.')

$script:Tweaks += (New-Tweak -Id 'feat.shell.searchhighlights' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off search highlights' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';name='EnableDynamicContentInWSB';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';name='EnableDynamicContentInWSB'}) -Info 'Removes the daily illustrations and trending content in the search box and search home.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.startrecs' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off tips and app promotions in Start' -Risk 'Safe' -Recommend $true -Detect @{kind='registry';minBuild=22621} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_IrisRecommendations';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_IrisRecommendations'}) -Info 'Same as Settings > Personalization > Start > Show recommendations for tips, shortcuts, new apps, and more.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.startaccount' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off account notifications in Start' -Risk 'Safe' -Recommend $true -Detect @{kind='registry';minBuild=22621} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_AccountNotifications';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_AccountNotifications'}) -Info 'Hides Microsoft account and backup prompts on the Start menu profile button.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.trackprogs' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Stop tracking app launches' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_TrackProgs';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Start_TrackProgs'}) -Info 'Windows stops recording which apps you open. The Most used list in Start goes empty.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.syncads' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off OneDrive and Microsoft 365 ads in File Explorer' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='ShowSyncProviderNotifications';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='ShowSyncProviderNotifications'}) -Info 'Same as File Explorer Options > View > Show sync provider notifications.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.ink' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off Windows Ink Workspace' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace';name='AllowWindowsInkWorkspace';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace';name='AllowWindowsInkWorkspace'}) -Info 'Removes the pen workspace and its taskbar menu. Pen input keeps working in apps.')

$script:Tweaks += (New-Tweak -Id 'feat.game.nexus' -Tab 'Tweaks' -SubTab 'Features' -Group 'Gaming' -Label 'Stop the controller Xbox button opening Game Bar' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\GameBar';name='UseNexusForGameBarEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\GameBar';name='UseNexusForGameBarEnabled'}) -Info 'Same as Settings > Gaming > Game Bar > Open Game Bar using this button on a controller.')

$script:Tweaks += (New-Tweak -Id 'feat.input.stickykeys' -Tab 'Tweaks' -SubTab 'Features' -Group 'Input and accessibility' -Label 'Turn off Sticky, Filter and Toggle Keys shortcuts' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Control Panel\Accessibility\StickyKeys';name='Flags';value='506';type='String'},@{kind='registry';path='HKCU:\Control Panel\Accessibility\Keyboard Response';name='Flags';value='122';type='String'},@{kind='registry';path='HKCU:\Control Panel\Accessibility\ToggleKeys';name='Flags';value='58';type='String'}) -Revert @(@{kind='registry';path='HKCU:\Control Panel\Accessibility\StickyKeys';name='Flags';value='510';type='String'},@{kind='registry';path='HKCU:\Control Panel\Accessibility\Keyboard Response';name='Flags';value='126';type='String'},@{kind='registry';path='HKCU:\Control Panel\Accessibility\ToggleKeys';name='Flags';value='62';type='String'}) -Info 'Stops pressing Shift five times, holding right Shift, or holding Num Lock from opening accessibility prompts mid-game. The features stay available in Settings. Takes effect after signing out.')
$script:Tweaks += (New-Tweak -Id 'feat.input.mouseaccel' -Tab 'Tweaks' -SubTab 'Features' -Group 'Input and accessibility' -Label 'Turn off Enhance pointer precision' -Risk 'Moderate' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseSpeed';value='0';type='String'},@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseThreshold1';value='0';type='String'},@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseThreshold2';value='0';type='String'}) -Revert @(@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseSpeed';value='1';type='String'},@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseThreshold1';value='6';type='String'},@{kind='registry';path='HKCU:\Control Panel\Mouse';name='MouseThreshold2';value='10';type='String'}) -Info 'Removes Windows mouse acceleration so cursor movement matches hand movement 1:1. Games using raw input are unaffected. Takes effect after signing out.')

$script:Tweaks += (New-Tweak -Id 'feat.cloud.phonelink' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Turn off phone to PC linking' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableMmx';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableMmx'}) -Info 'Allow Phone-PC linking policy. Phone Link and Start menu phone companion stop connecting to your phone.')
$script:Tweaks += (New-Tweak -Id 'feat.cloud.settingsync' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Turn off settings sync to your Microsoft account' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync';name='DisableSettingSync';value=2;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync';name='DisableSettingSyncUserOverride';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync';name='DisableSettingSync'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync';name='DisableSettingSyncUserOverride'}) -Info 'Do not sync policy. Theme, passwords and language preferences stop syncing between your PCs.')
$script:Tweaks += (New-Tweak -Id 'feat.cloud.onedrive' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Turn off OneDrive file sync' -Risk 'Risky' -Recommend $false -Detect @{kind='anyPath';paths=@("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe","$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe","${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive';name='DisableFileSyncNGSC';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive';name='DisableFileSyncNGSC'}) -Info 'Prevent the usage of OneDrive for file storage policy. OneDrive stops syncing; files that exist only online become unavailable until it is turned back on.')

$script:Tweaks += (New-Tweak -Id 'feat.privacy.settingsads' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Turn off suggested content in Settings' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338393Enabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-353694Enabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-353696Enabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338393Enabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-353694Enabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-353696Enabled'}) -Info 'Same as Settings > Privacy and security > General > Show me suggested content in the Settings app.')
$script:Tweaks += (New-Tweak -Id 'feat.privacy.tips' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Turn off tips and suggestions notifications' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338389Enabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-310093Enabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338389Enabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-310093Enabled'}) -Info 'Stops "Get tips and suggestions when using Windows" notifications and the post-update Windows welcome experience.')
$script:Tweaks += (New-Tweak -Id 'feat.privacy.silentapps' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Stop automatic installs of suggested apps' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SilentInstalledAppsEnabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='PreInstalledAppsEnabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='PreInstalledAppsEverEnabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='OemPreInstalledAppsEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SilentInstalledAppsEnabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='PreInstalledAppsEnabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='PreInstalledAppsEverEnabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='OemPreInstalledAppsEnabled'}) -Info 'Stops Windows and the PC maker from silently installing promoted Store apps and games (the ones that reappear in Start after debloating) for this user.')
$script:Tweaks += (New-Tweak -Id 'feat.privacy.speech' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Turn off online speech recognition' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';name='HasAccepted';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';name='HasAccepted'}) -Info 'Same as Settings > Privacy and security > Speech. Voice typing uses only on-device recognition, which is less accurate.')
$script:Tweaks += (New-Tweak -Id 'feat.privacy.langlist' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Hide your language list from websites' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Control Panel\International\User Profile';name='HttpAcceptLanguageOptOut';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Control Panel\International\User Profile';name='HttpAcceptLanguageOptOut'}) -Info 'Same as Settings > Privacy and security > General > Let websites show me locally relevant content by accessing my language list.')

$script:Tweaks += (New-Tweak -Id 'feat.sys.faststartup' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Turn off Fast startup' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power';name='HiberbootEnabled';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power';name='HiberbootEnabled';value=1;type='DWord'}) -Info 'Shut down then performs a full kernel restart, so driver and BIOS changes always apply. Cold boots take a few seconds longer.')

$script:Tweaks += (New-Tweak -Id 'feat.opt.smb1' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove SMB 1.0 file sharing' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('SMB1Protocol')} -Apply @(@{kind='optionalFeature';names=@('SMB1Protocol')}) -Revert @(@{kind='optionalFeature';names=@('SMB1Protocol');enable=$true}) -Info 'Obsolete, insecure file-sharing protocol (off by default since Windows 10 1709). Only very old NAS drives need it. Restart required.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.psv2' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove the PowerShell 2.0 engine' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('MicrosoftWindowsPowerShellV2Root','MicrosoftWindowsPowerShellV2')} -Apply @(@{kind='optionalFeature';names=@('MicrosoftWindowsPowerShellV2Root','MicrosoftWindowsPowerShellV2')}) -Revert @(@{kind='optionalFeature';names=@('MicrosoftWindowsPowerShellV2Root','MicrosoftWindowsPowerShellV2');enable=$true}) -Info 'Legacy PowerShell 2.0 (removed by Microsoft in 24H2/25H2). Current PowerShell is unaffected.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.workfolders' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Work Folders client' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('WorkFolders-Client')} -Apply @(@{kind='optionalFeature';names=@('WorkFolders-Client')}) -Revert @(@{kind='optionalFeature';names=@('WorkFolders-Client');enable=$true}) -Info 'Company file-server sync client. Restart required.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.xps' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove XPS Document Writer' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('Printing-XPSServices-Features')} -Apply @(@{kind='optionalFeature';names=@('Printing-XPSServices-Features')}) -Revert @(@{kind='optionalFeature';names=@('Printing-XPSServices-Features');enable=$true}) -Info 'Removes the XPS printer. Microsoft Print to PDF is not affected.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.fax' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Windows Fax and Scan' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('FaxServicesClientPackage')} -Apply @(@{kind='optionalFeature';names=@('FaxServicesClientPackage')}) -Revert @(@{kind='optionalFeature';names=@('FaxServicesClientPackage');enable=$true}) -Info 'Fax client. Scanning with your scanner''s own app or Windows Scan is unaffected.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.ie' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Internet Explorer 11' -Risk 'Safe' -Recommend $true -Detect @{kind='optionalFeature';names=@('Internet-Explorer-Optional-amd64')} -Apply @(@{kind='optionalFeature';names=@('Internet-Explorer-Optional-amd64')}) -Revert @(@{kind='optionalFeature';names=@('Internet-Explorer-Optional-amd64');enable=$true}) -Info 'Retired browser left on older builds. Edge IE mode is unaffected.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.internetprint' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Internet Printing Client' -Risk 'Moderate' -Recommend $false -Detect @{kind='optionalFeature';names=@('Printing-Foundation-InternetPrinting-Client')} -Apply @(@{kind='optionalFeature';names=@('Printing-Foundation-InternetPrinting-Client')}) -Revert @(@{kind='optionalFeature';names=@('Printing-Foundation-InternetPrinting-Client');enable=$true}) -Info 'Printing to printers shared over HTTP (IPP). Leave it on if you print to a network printer by URL.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.smbdirect' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove SMB Direct' -Risk 'Safe' -Recommend $false -Detect @{kind='optionalFeature';names=@('SmbDirect')} -Apply @(@{kind='optionalFeature';names=@('SmbDirect')}) -Revert @(@{kind='optionalFeature';names=@('SmbDirect');enable=$true}) -Info 'SMB over RDMA network cards (server hardware). Normal file sharing is unaffected.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.media' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove legacy Windows Media Player' -Risk 'Risky' -Recommend $false -Detect @{kind='optionalFeature';names=@('MediaPlayback','WindowsMediaPlayer')} -Apply @(@{kind='optionalFeature';names=@('WindowsMediaPlayer','MediaPlayback')}) -Revert @(@{kind='optionalFeature';names=@('MediaPlayback','WindowsMediaPlayer');enable=$true}) -Info 'Media Features: legacy Windows Media Player and its components. Some older apps and game launchers that embed it can fail.')
$script:Tweaks += (New-Tweak -Id 'feat.opt.hypervisor' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Hyper-V, WSL and Windows Sandbox' -Risk 'Risky' -Recommend $false -Detect @{kind='optionalFeature';names=@('Microsoft-Hyper-V-All','VirtualMachinePlatform','HypervisorPlatform','Microsoft-Windows-Subsystem-Linux','Containers-DisposableClientVM')} -Apply @(@{kind='optionalFeature';names=@('Containers-DisposableClientVM','Microsoft-Windows-Subsystem-Linux','HypervisorPlatform','VirtualMachinePlatform','Microsoft-Hyper-V-All')}) -Revert @(@{kind='optionalFeature';names=@('Microsoft-Hyper-V-All','VirtualMachinePlatform','HypervisorPlatform','Microsoft-Windows-Subsystem-Linux','Containers-DisposableClientVM');enable=$true}) -Info 'Turns off the hypervisor-based features. WSL, Docker, Windows Sandbox, Android emulators and virtual machines stop working. Memory Integrity (Core isolation) is separate and is set on the Security tab. Restart required.')
 
$script:BrowserPaths = @{
    Edge=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
    Chrome=@("${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    Firefox=@("${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe","$env:ProgramFiles\Mozilla Firefox\firefox.exe","$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe")
    Brave=@("${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe","$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe")
    Opera=@("$env:LOCALAPPDATA\Programs\Opera\opera.exe","$env:LOCALAPPDATA\Programs\Opera GX\opera.exe","$env:ProgramFiles\Opera\launcher.exe","${env:ProgramFiles(x86)}\Opera\launcher.exe")
}
$discordSettings = Join-Path $env:APPDATA 'discord\settings.json'
$discordPaths = @("$env:LOCALAPPDATA\Discord\Update.exe","$env:LOCALAPPDATA\Discord\app-*\Discord.exe")
$script:Tweaks += (New-Tweak -Id 'app.discord.hwaccel' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Discord' -Label 'Turn off Discord GPU rendering' -Risk 'Safe' -Detect @{kind='appJsonSetting';paths=$discordPaths;configPath=$discordSettings;name='enableHardwareAcceleration';value=$false} -Apply @(@{kind='appJson';path=$discordSettings;name='enableHardwareAcceleration';value=$false}) -Revert @(@{kind='appJsonDel';path=$discordSettings;name='enableHardwareAcceleration'}) -Info 'Writes a per-user Discord settings.json preference. Close and reopen Discord for the change to take effect; removing the preference restores the app default.')
$script:Tweaks += (New-Tweak -Id 'app.chrome.bg' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Disable Chrome background mode' -Risk 'Safe' -Detect @{kind='anyPath';paths=@("${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Google\Chrome';name='BackgroundModeEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Google\Chrome';name='BackgroundModeEnabled'}) -Info 'Stops Chrome from keeping background processes running after all windows are closed.')
$script:Tweaks += (New-Tweak -Id 'app.edge.sleep' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Enable Edge sleeping tabs' -Risk 'Safe' -Detect @{kind='anyPath';paths=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='SleepingTabsEnabled';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Edge';name='SleepingTabsEnabled'}) -Info 'Enables Edge sleeping tabs through policy when Edge is installed. Sleeping tabs reduce background CPU and memory use for inactive tabs.')
$script:Tweaks += (New-Tweak -Id 'app.chrome.memory' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Enable Chrome Memory Saver' -Risk 'Safe' -Detect @{kind='anyPath';paths=@("${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Google\Chrome';name='HighEfficiencyModeEnabled';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Google\Chrome';name='HighEfficiencyModeEnabled'}) -Info 'Enables Chrome Memory Saver with a managed policy when Chrome is installed. Chrome may reload inactive tabs when you return to them.')
$script:Tweaks += (New-Tweak -Id 'app.brave.bg' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Stop Brave background apps' -Risk 'Safe' -Detect @{kind='anyPath';paths=$script:BrowserPaths.Brave} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';name='BackgroundModeEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';name='BackgroundModeEnabled'}) -Info 'Uses the Chromium BackgroundModeEnabled policy under Brave policy root to stop background apps after all windows close.')
$script:Tweaks += (New-Tweak -Id 'app.firefox.backgroundupdate' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Use manual Firefox updates' -Risk 'Moderate' -Detect @{kind='anyPath';paths=$script:BrowserPaths.Firefox} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Mozilla\Firefox';name='ManualAppUpdateOnly';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Mozilla\Firefox';name='ManualAppUpdateOnly'}) -Info 'Uses Mozilla ManualAppUpdateOnly policy. Firefox checks for updates when you open About Firefox but does not automatically download or prompt for them; check regularly and install security updates manually.')
$ffai = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
$ffaiApply = @(
    @{kind='registry';path="$ffai\GenerativeAI";name='Enabled';value=0;type='DWord'}, @{kind='registry';path="$ffai\GenerativeAI";name='Chatbot';value=0;type='DWord'},
    @{kind='registry';path="$ffai\GenerativeAI";name='LinkPreviews';value=0;type='DWord'}, @{kind='registry';path="$ffai\GenerativeAI";name='TabGroups';value=0;type='DWord'}
) + @(foreach ($f in 'SidebarChatbot','LinkPreviewKeyPoints','SmartTabGroups','SmartWindow','PDFAltText') { @{kind='registry';path="$ffai\AIControls\$f";name='Value';value='blocked';type='String'} })
$script:Tweaks += (New-Tweak -Id 'app.firefox.ai' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Browsers' -Label 'Turn off Firefox AI features' -Risk 'Safe' -Detect @{kind='anyPath';paths=$script:BrowserPaths.Firefox} -Apply $ffaiApply -Revert @($ffaiApply | ForEach-Object { @{kind='registryDel';path=$_.path;name=$_.name} }) -Info 'Uses the Mozilla GenerativeAI policy (Firefox 144 and later) and the AI controls policy (Firefox 149 and later) to remove the sidebar AI chatbot, AI key points in link previews, AI tab group suggestions, AI window arrangement and AI alt text in PDFs. Blocking also deletes on-device AI models Firefox already downloaded. Page translation stays available. Restart Firefox to apply.')
$script:Tweaks += (New-Tweak -Id 'app.spotify.startup' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Spotify' -Label 'Disable Spotify startup' -Risk 'Safe' -Detect @{kind='runkey';name='Spotify'} -Apply @(@{kind='runkey';name='Spotify';remove=$true}) -Revert @() -Info 'Stops Spotify from launching at sign-in. Spotify can still be opened manually.')
$script:Tweaks += (New-Tweak -Id 'app.store.updates' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Microsoft Store' -Label 'Disable Store automatic app updates' -Risk 'Moderate' -Detect @{kind='appx';name='Microsoft.WindowsStore'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore';name='AutoDownload';value=2;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore';name='AutoDownload'}) -Info 'Sets the Windows Store policy to stop automatic app updates. Store apps can become outdated; use the Store Library to update them manually.' )
 
$script:Tweaks += (New-Tweak -Id 'net.dns' -Tab 'Networking' -SubTab '' -Group 'DNS and name resolution' -Label 'DNS server' -Risk 'Safe' -Type 'dropdown' -Options @('Default (DHCP)','Cloudflare (1.1.1.1)','Google (8.8.8.8)') -Detect $null -Info 'Sets a public DNS resolver on active adapters. Default returns to automatic (DHCP-provided) DNS.')
$script:Tweaks += (New-Tweak -Id 'net.rss' -Tab 'Networking' -SubTab '' -Group 'Queues and buffers' -Label 'Enable Receive Side Scaling (RSS)' -Risk 'Safe' -Detect @{kind='netFeature';name='rss'} -Apply @(@{kind='netRss';enable=$true}) -Revert @(@{kind='netRss';enable=$false}) -Info 'RSS distributes network receive processing across CPU cores on supported adapters. This is usually enabled by default; this toggle restores it if a driver setting disabled it. Verify support in the NIC driver.' )
$script:Tweaks += (New-Tweak -Id 'net.intmod' -Tab 'Networking' -SubTab '' -Group 'Queues and buffers' -Label 'Turn off interrupt moderation' -Risk 'Moderate' -Detect @{kind='netProperty';name='Interrupt Moderation';keywords=@('*InterruptModeration')} -Apply @(@{kind='netAdvancedProperty';name='Interrupt Moderation';keywords=@('*InterruptModeration');regValue='0';value='Disabled';valuePattern='^(Off|Disabled)$'}) -Info 'Intel, Realtek and Killer Ethernet adapters wait a moment to bundle incoming packets into one interrupt. Off hands each packet to Windows right away, saving tens to a few hundred microseconds per packet. That is small next to internet ping, so the gain shows most in LAN play and high tick-rate games.' -Warn 'Many more interrupts: CPU load rises during big downloads, and throughput on 2.5 Gbit and faster links can drop.')
$script:Tweaks += (New-Tweak -Id 'net.eee' -Tab 'Networking' -SubTab '' -Group 'Power saving' -Label 'Disable Energy-Efficient Ethernet' -Risk 'Safe' -Detect @{kind='netProperty';names=@('Energy-Efficient Ethernet','Energy Efficient Ethernet');keywords=@('*EEE','EEELinkAdvertisement')} -Apply @(@{kind='netAdvancedProperty';names=@('Energy-Efficient Ethernet','Energy Efficient Ethernet');keywords=@('*EEE','EEELinkAdvertisement');value='Disabled';valuePattern='^(Off|Disabled)$'}) -Info 'Disables adapter low-power Ethernet mode only when the installed driver exposes this property (matched by its *EEE keyword, so Intel I225/I226 and Realtek spellings both work). Turning it off removes the wake-up delay of the link and is a known fix for I225-V/I226-V dropouts. It increases idle power draw, so on laptops leave it on unless you have dropouts.' )
$script:Tweaks += (New-Tweak -Id 'net.wake' -Tab 'Networking' -SubTab '' -Group 'Power saving' -Label 'Disable wake on LAN and PME' -Risk 'Safe' -Detect @{kind='netFeature';name='wake'} -Apply @(@{kind='netPower';value='Disabled'}) -Revert @(@{kind='netPower';value='Enabled'}) -Info 'Prevents supported Ethernet adapters from waking the PC for a magic packet or pattern. Wake-on-LAN will stop working.' )
$script:Tweaks += (New-Tweak -Id 'net.wifi.band' -Tab 'Networking' -SubTab '' -Group 'Wi-Fi' -Label 'Prefer the 5 GHz band' -Risk 'Safe' -Detect @{kind='netProperty';name='Preferred Band';keywords=@('PreferredBand','RoamingPreferredBandType','StaPreferredBand')} -Apply @(@{kind='netAdvancedProperty';name='Preferred Band';keywords=@('PreferredBand','RoamingPreferredBandType','StaPreferredBand');value='Prefer 5GHz band';valuePattern='Prefer\s*5\s*G'}) -Info 'Asks a supported Wi-Fi adapter to prefer 5 GHz. This does not improve a weak 5 GHz signal and may reduce range compared with 2.4 GHz.' )
$script:Tweaks += (New-Tweak -Id 'net.wifi.roaming' -Tab 'Networking' -SubTab '' -Group 'Wi-Fi' -Label 'Set roaming aggressiveness to lowest' -Risk 'Moderate' -Detect @{kind='netProperty';name='Roaming Aggressiveness';keywords=@('RoamAggressiveness','RoamNeedIndicateTh','roamPolicy')} -Apply @(@{kind='netAdvancedProperty';name='Roaming Aggressiveness';keywords=@('RoamAggressiveness','RoamNeedIndicateTh','roamPolicy');value='1. Lowest';valuePattern='Lowest$'}) -Info 'Stops Intel, MediaTek, Qualcomm and Killer Wi-Fi adapters from scanning for a better access point while the signal is still fine. Each scan briefly leaves your channel, which shows up as ping spikes in games. Realtek adapters already default to their lowest level.' -Warn 'With several access points or mesh Wi-Fi, a laptop carried around stays on a weaker access point longer before switching.')
$script:Tweaks += (New-Tweak -Id 'net.teredo' -Tab 'Networking' -SubTab '' -Group 'Tunnels' -Label 'Disable Teredo tunneling' -Risk 'Moderate' -Detect $null -Apply @(@{kind='teredo';enable=$false}) -Revert @(@{kind='teredo';enable=$true}) -Info 'Disables the Teredo IPv6 tunnel. Xbox party chat, multiplayer, or other NAT traversal scenarios may rely on Teredo.' )
$script:Tweaks += (New-Tweak -Id 'net.autotune' -Tab 'Networking' -SubTab '' -Group 'TCP and UDP' -Label 'Receive window auto-tuning' -Risk 'Safe' -Type 'dropdown' -Options @('Default','Normal','Disabled') -Detect $null -Info 'Windows auto-tuning adapts the TCP receive window for throughput. Normal is the Windows default. Disabling may reduce performance on high-latency links; use for diagnosis only.' )
$script:Tweaks += (New-Tweak -Id 'net.green' -Tab 'Networking' -SubTab '' -Group 'Power saving' -Label 'Disable Ethernet idle power saving' -Risk 'Safe' -Detect @{kind='netPropertyAny';names=@('Green Ethernet','Advanced EEE','System Idle Power Saver');keywords=@('EnableGreenEthernet','AdvancedEEE','PowerSavingMode','SipsEnabled','*IdleRestriction')} -Apply @(@{kind='netAdvancedProperty';names=@('Green Ethernet');keywords=@('EnableGreenEthernet');regValue='0';value='Disabled';valuePattern='^(Off|Disabled)$'},@{kind='netAdvancedProperty';names=@('Advanced EEE');keywords=@('AdvancedEEE');regValue='0';value='Disabled';valuePattern='^(Off|Disabled)$'},@{kind='netAdvancedProperty';keywords=@('PowerSavingMode');regValue='0';value='Disabled';valuePattern='^(Off|Disabled)$'},@{kind='netAdvancedProperty';names=@('System Idle Power Saver');keywords=@('SipsEnabled');regValue='0';value='Disabled';valuePattern='^(Off|Disabled)$'},@{kind='netAdvancedProperty';keywords=@('*IdleRestriction');regValue='1';value='Enabled';valuePattern='^(On|Enabled)$'}) -Info 'Turns off the vendor idle power modes that let the Ethernet link or chip doze between packets: Realtek and Killer Green Ethernet, Advanced EEE and Power Saving Mode, Intel System Idle Power Saver, and idle power-down (Idle Power Down Restriction on). Waking from these adds delay to the first packets and is a common cause of ping spikes and link drops. Only settings your adapter has are changed; the standard EEE setting is its own row.' -Warn 'The adapter uses slightly more power while idle; on a laptop on battery that costs a little battery life.')
$script:Tweaks += (New-Tweak -Id 'net.qos.peer' -Tab 'Networking' -SubTab '' -Group 'Delivery Optimization' -Label 'Disable Delivery Optimization peer sharing' -Risk 'Safe' -Detect @{kind='service';name='DoSvc'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';name='DODownloadMode';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';name='DODownloadMode'}) -Info 'Stops peer-to-peer sharing for Delivery Optimization while allowing downloads from Microsoft. Use the policy to keep app and Windows downloads from uploading to other PCs.' )
$script:Tweaks += (New-Tweak -Id 'net.qos.bandwidth' -Tab 'Networking' -SubTab '' -Group 'Delivery Optimization' -Label 'Background download bandwidth cap' -Risk 'Safe' -Type 'dropdown' -Options @('Default','25%','50%','75%') -Detect @{kind='service';name='DoSvc'} -Info 'Sets the Delivery Optimization background download percentage policy. Default removes the policy override; the cap can slow Store and update downloads.' )
$script:Tweaks += (New-Tweak -Id 'net.wifi.location' -Tab 'Networking' -SubTab '' -Group 'Wi-Fi' -Label 'Turn off location' -Risk 'Moderate' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors';name='DisableLocation'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors';name='DisableLocation';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors';name='DisableLocation'}) -Info 'Disables Windows location access by policy. Apps that use location may stop receiving location data; the change can affect the whole PC.' )
$script:Tweaks += (New-Tweak -Id 'net.netbios' -Tab 'Networking' -SubTab '' -Group 'DNS and name resolution' -Label 'Disable NetBIOS over TCP/IP' -Risk 'Moderate' -Detect @{kind='netadapterPhysical'} -Apply @(@{kind='netbios';value=2}) -Revert @(@{kind='netbios';value=0}) -Info 'Disables NetBIOS name services on IP-enabled adapters. Legacy network discovery and older file shares that require NetBIOS may stop working.' )
$script:Tweaks += (New-Tweak -Id 'net.llmnr' -Tab 'Networking' -SubTab '' -Group 'DNS and name resolution' -Label 'Disable LLMNR' -Risk 'Safe' -Detect @{kind='netadapterPhysical'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient';name='EnableMulticast';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient';name='EnableMulticast'}) -Info 'Disables Link-Local Multicast Name Resolution, reducing local name-query fallback. Devices that rely on LLMNR rather than DNS may no longer resolve by name.' )
$script:Tweaks += (New-Tweak -Id 'net.multihomed' -Tab 'Networking' -SubTab '' -Group 'DNS and name resolution' -Label 'Disable smart multi-homed name resolution' -Risk 'Moderate' -Detect @{kind='netadapterPhysical'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient';name='DisableSmartNameResolution';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient';name='DisableSmartNameResolution'}) -Info 'Stops Windows from sending parallel DNS queries across multiple networks. VPN and multi-homed PCs may resolve names more slowly or differently.' )
$script:Tweaks += (New-Tweak -Id 'net.doh' -Tab 'Networking' -SubTab '' -Group 'DNS and name resolution' -Label 'DNS over HTTPS' -Risk 'Safe' -Type 'dropdown' -Options @('Default','Cloudflare','Google') -Detect @{kind='netCmdlet';name='Add-DnsClientDohServerAddress'} -Info 'Registers a supported DNS-over-HTTPS resolver and assigns its addresses to active physical adapters. Default resets adapter DNS to DHCP; custom VPN and enterprise DNS settings may be replaced.' )
 
$script:Tweaks += (New-Tweak -Id 'gpu.hags' -Tab 'GPU' -SubTab '' -Group 'Common' -Label 'Hardware-accelerated GPU scheduling' -Risk 'Moderate' -Type 'dropdown' -Options @('Default','On','Off') -Detect @{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';name='HwSchMode'} -Info 'HAGS lets the GPU manage its own scheduling. Required for DLSS Frame Generation, and Windows needs it for the hardware flip queue that works with MPO to cut latency and CPU wake-ups. Off can free about 1 GB of VRAM on 8 GB cards. Keep On for Windows 11 with a current GPU. On=2, Off=1. Reboot required.')
$mpoDwm = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
$mpoGfx = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$mpoApply = if ($script:OsBuild -ge 26200) {
    @(@{kind='registry';path=$mpoGfx;name='DisableOverlays';value=1;type='DWord'})
} elseif ($script:OsBuild -ge 26100) {
    @(@{kind='registry';path=$mpoDwm;name='OverlayTestMode';value=5;type='DWord'},@{kind='registry';path=$mpoDwm;name='OverlayMinFPS';value=0;type='DWord'})
} else {
    @(@{kind='registry';path=$mpoDwm;name='OverlayTestMode';value=5;type='DWord'})
}
$mpoRevert = @($mpoApply | ForEach-Object { @{kind='registryDel';path=$_.path;name=$_.name} })
$mpoKeys = (@($mpoApply | ForEach-Object { '{0} = {1}' -f $_.name,$_.value }) -join ' and ')
$script:Tweaks += (New-Tweak -Id 'gpu.mpo' -Tab 'GPU' -SubTab '' -Group 'Common' -Label 'Disable Multi-Plane Overlay (MPO)' -Risk 'Moderate' -Recommend $false -Detect $null -Apply $mpoApply -Revert $mpoRevert -Info ("Sets {0} for this Windows build (OverlayTestMode up to 23H2, plus OverlayMinFPS on 24H2, GraphicsDrivers DisableOverlays on 25H2 and later). Only for confirmed MPO flicker, brief black screens or desktop stutter, usually with G-SYNC/FreeSync. MPO is what keeps games in Independent Flip when overlays or notifications appear, and it saves power in video playback, so leave it on otherwise. Try the lighter frame-rate switching fix first. Reboot required." -f $mpoKeys) -Note 'Can cause screen flicker in some games. If you get flicker, stutters, FPS drops or any other issue, untick this and Apply to re-enable MPO.')
if ($script:OsBuild -ge 26200) { $mpoRow = @($script:Tweaks | Where-Object { $_.Id -eq 'gpu.mpo' })[0]; $mpoRow.Risk = 'Risky'; $mpoRow.Warn = 'On this Windows build the only remaining switch (GraphicsDrivers DisableOverlays) turns off every hardware overlay plane, not just MPO: windowed and borderless games are composited by the desktop on every frame, which can cost a large share of FPS at high frame rates and breaks Discord, Steam and RTSS overlays. Use only to stop confirmed MPO flicker.' }
$script:Tweaks += (New-Tweak -Id 'gpu.mpo.minfps' -Tab 'GPU' -SubTab '' -Group 'Common' -Label 'Stop MPO frame-rate switching (lighter MPO fix)' -Risk 'Moderate' -Recommend $false -Detect $null -Apply @(@{kind='registry';path=$mpoDwm;name='OverlayMinFPS';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path=$mpoDwm;name='OverlayMinFPS'}) -Info 'Sets HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayMinFPS = 0 so Windows stops moving apps on and off overlay planes based on their frame rate. Keeps MPO on; try this first for browser, Discord or desktop stutter and flicker on variable-refresh displays. Reboot required.')
$script:Tweaks += (New-Tweak -Id 'gpu.gamemode' -Tab 'GPU' -SubTab '' -Group 'Windows' -Label 'Windows Game Mode' -Risk 'Safe' -Type 'dropdown' -Options @('Default','On','Off') -Detect @{kind='registry';path='HKCU:\Software\Microsoft\GameBar';name='AutoGameModeEnabled'} -Info 'Game Mode limits background update/notification interruptions during games. It is normally safe to leave enabled; results vary by workload and Windows build.')
$script:Tweaks += (New-Tweak -Id 'gpu.amd.ulps' -Tab 'GPU' -SubTab '' -Group 'AMD' -Label 'Disable ULPS (AMD)' -Risk 'Moderate' -Detect @{kind='vendor';value='AMD'} -Apply @(@{kind='amdUlps';enable=$false}) -Revert @(@{kind='amdUlps';enable=$true}) -Info 'Ultra Low Power State can cause downclock stutter on multi-GPU/high-refresh setups. Applies to detected AMD Radeon adapters only.')
$script:Tweaks += (New-Tweak -Id 'gpu.msi' -Tab 'GPU' -SubTab '' -Group 'Interrupts' -Label 'Turn on MSI mode for the graphics card and network adapters' -Risk 'Moderate' -Detect @{kind='msiCapable'} -Apply @(@{kind='msiMode';enable=$true}) -Revert @(@{kind='msiMode';enable=$false}) -Info 'Sets MSISupported=1 for each graphics card and physical Ethernet/Wi-Fi adapter whose hardware supports MSI or MSI-X. Line-based interrupts can be shared, so every sharing driver must check whether the interrupt was its own; MSI gives each device its own interrupt. The status shows the mode each device really uses. AMD, Intel, Realtek, MediaTek and recent NVIDIA drivers already use MSI, so nothing changes for them. Interrupt priority is not changed (Windows treats it only as a hint), and storage and USB controllers are left alone because a wrong mode on the boot drive controller can stop Windows from starting. Pick devices in Apply. Restart required.' -Note 'Restart required')
$script:Tweaks += (New-Tweak -Id 'gpu.vrr.windowed' -Tab 'GPU' -SubTab '' -Group 'Windows' -Label 'Turn off variable refresh rate for windowed games' -Risk 'Safe' -Recommend $false -Detect @{kind='osBuild';min=22000;reason='Needs Windows 11'} -Apply @(@{kind='dxGlobal';name='VRROptimizeEnable';value='0'}) -Revert @(@{kind='dxGlobal';name='VRROptimizeEnable';value=$null}) -Info 'The Settings > Display > Graphics "Variable refresh rate" switch. A fix, not a speed-up: use it only if borderless or windowed games flicker or stutter on a FreeSync / G-SYNC monitor. Fullscreen games are not affected.' -Warn 'FreeSync / G-SYNC stops working in borderless and windowed games that do not support it on their own.')
$script:Tweaks += (New-Tweak -Id 'gpu.windowed' -Tab 'GPU' -SubTab '' -Group 'Windows' -Label 'Optimizations for windowed games' -Risk 'Safe' -Detect @{kind='osBuild';min=22000;reason='Needs Windows 11'} -Apply @(@{kind='dxGlobal';name='SwapEffectUpgradeEnable';value='1'}) -Revert @(@{kind='dxGlobal';name='SwapEffectUpgradeEnable';value=$null}) -Info 'The Settings > Display > Graphics switch. Lets DirectX 10/11 games in windowed or borderless mode use the flip presentation model, which lowers latency and enables VRR. Unticking restores the previous setting.')
$script:RecognizedGames = @(Get-RecognizedGames)
$gameList = (@($script:RecognizedGames | ForEach-Object { $_.Name }) -join ', ')
$gpuGameApply = @($script:RecognizedGames | ForEach-Object { @{kind='dxApp';exe=$_.Path;name='GpuPreference';value='2'} })
$gpuGameRevert = @($script:RecognizedGames | ForEach-Object { @{kind='dxApp';exe=$_.Path;name='GpuPreference';value=$null} })
$script:Tweaks += (New-Tweak -Id 'gpu.games.highperf' -Tab 'GPU' -SubTab '' -Group 'Games' -Label 'Run recognised games on the high-performance GPU' -Risk 'Safe' -Detect @{kind='recognizedGames';multiGpu=$true} -Apply $gpuGameApply -Revert $gpuGameRevert -Info ('Sets Settings > System > Display > Graphics > [game] > High performance for every game Windows has recognised ({0}). On a PC with two graphics adapters (a laptop, or a desktop with the CPU graphics still enabled), a game left on "Let Windows decide" can start on the integrated GPU and run at a fraction of the frame rate. The preference is added next to the game''s other graphics settings, which are kept. Only shown when two graphics adapters are present. Games that pick their adapter themselves ignore it; restart the game to apply. Unticking restores each game''s previous setting.' -f $(if ($gameList) { $gameList } else { 'none yet' })))
($script:Tweaks | Where-Object { $_.Id -eq 'gpu.games.highperf' }).Warn = 'On laptops the games always use the dedicated GPU, so battery drains faster while they run, even in menus.'
$throttleApply = @($script:RecognizedGames | ForEach-Object { @{kind='throttleApp';exe=$_.Path;exempt=$true} })
$throttleRevert = @($script:RecognizedGames | ForEach-Object { @{kind='throttleApp';exe=$_.Path;exempt=$false} })
$script:Tweaks += (New-Tweak -Id 'cpu.games.nothrottle' -Tab 'CPU' -SubTab '' -Group 'Scheduling' -Label 'Exempt recognised games from background power throttling' -Risk 'Safe' -Detect @{kind='recognizedGames'} -Apply $throttleApply -Revert $throttleRevert -Info ('Uses the built-in powercfg /powerthrottling disable /path command for each game Windows has recognised ({0}). Windows puts apps it considers in the background (minimised, hidden or not in focus) on efficiency mode (EcoQoS): lower clocks and, on hybrid CPUs, the efficiency cores. That can hit a game while you look at a second monitor, a stream or Discord. Only these games are exempted; power throttling stays on for everything else. A focused game is never throttled, so in-game FPS while it has focus does not change. Unticking resets each game to the Windows default.' -f $(if ($gameList) { $gameList } else { 'none yet' })))
($script:Tweaks | Where-Object { $_.Id -eq 'cpu.games.nothrottle' }).Warn = 'On laptops, a game left running in the background keeps full power and drains the battery faster.'
$script:Tweaks += (New-Tweak -Id 'cpu.powermode.best' -Tab 'CPU' -SubTab '' -Group 'Power' -Label 'Power mode: Best performance (plugged in)' -Risk 'Safe' -Detect @{kind='balancedPlan'} -Apply @(@{kind='powerMode';guid='ded574b5-45a0-4f42-8737-46345c09c238'}) -Revert @(@{kind='powerMode';guid='00000000-0000-0000-0000-000000000000'}) -Info 'Sets Settings > Power mode to Best performance while the Balanced plan is active. This is the supported way to make Balanced favour performance: energy preference and boost lean towards speed, while idle states and the Balanced scheduling that Ryzen X3D and Intel hybrid CPUs rely on stay in charge. Only shown on the Balanced plan. Unticking restores your previous mode.')
($script:Tweaks | Where-Object { $_.Id -eq 'cpu.powermode.best' }).Warn = 'The CPU uses more power and runs warmer at light loads; on laptops this shortens battery life and makes fans louder.'
$script:Tweaks += (New-Tweak -Id 'adv.svchost' -Tab 'Advanced' -SubTab '' -Group 'Processes' -Label 'Group service host (svchost) processes' -Risk 'Safe' -Detect @{kind='svchost'} -Apply @(@{kind='svchost'}) -Revert @(@{kind='registryDel';path='HKLM:\SYSTEM\CurrentControlSet\Control';name='SvcHostSplitThresholdInKB'}) -Info 'Sets SvcHostSplitThresholdInKB to the installed memory size. On PCs with more than 3.5 GB of RAM Windows normally runs most services in their own svchost.exe process; with this set, related services share processes again, so Task Manager shows far fewer svchost entries and a little memory is saved. Frame rate is not affected either way. Restart required. Unticking returns to the Windows default.' -Warn 'Services that share a process also share its fate: if one of them crashes, the others in that process restart with it.')
$ifeoBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$bgPrio = @(@('SearchIndexer.exe',1,0),@('SearchProtocolHost.exe',1,0),@('SearchFilterHost.exe',1,0),@('CompatTelRunner.exe',1,0),@('TrustedInstaller.exe',5,1),@('TiWorker.exe',5,1))
$bgApply = @(foreach ($b in $bgPrio) { @{kind='registry';path=("{0}\{1}\PerfOptions" -f $ifeoBase,$b[0]);name='CpuPriorityClass';value=$b[1];type='DWord'}; @{kind='registry';path=("{0}\{1}\PerfOptions" -f $ifeoBase,$b[0]);name='IoPriority';value=$b[2];type='DWord'} })
$script:Tweaks += (New-Tweak -Id 'adv.prio.ifeo' -Tab 'Advanced' -SubTab '' -Group 'Processes' -Label 'Lower the priority of background Windows processes' -Risk 'Safe' -Detect @{kind='registry'} -Apply $bgApply -Revert @($bgApply | ForEach-Object { @{kind='registryDel';path=$_.path;name=$_.name} }) -Info 'Makes these processes always start at low priority: the search indexer, its helpers and the compatibility telemetry runner at Idle CPU and very low disk priority, and Windows Modules Installer (TrustedInstaller, TiWorker) at Below normal CPU and low disk priority. They then only use CPU and disk time a game is not using. Unticking restores the previous values.' -Warn 'Search indexing, update installation and DISM/SFC repairs take somewhat longer while the PC is busy.')
$script:Tweaks += (New-Tweak -Id 'net.wifi.powersave' -Tab 'Networking' -SubTab '' -Group 'Wi-Fi' -Label 'Turn off Wi-Fi adapter power saving' -Risk 'Safe' -Detect @{kind='netPropertyAny';names=@('Power Saving','MIMO Power Save Mode','U-APSD Support','U-APSD support');keywords=@('LowPowerEnable','MIMOPowerSaveMode','UAPSDSupport','uAPSDSupport','bLeisurePs','sleepMode','MPC')} -Apply @(@{kind='netAdvancedProperty';name='Power Saving';keywords=@('LowPowerEnable');regValue='0';value='Disabled';valuePattern='^Disabled$'},@{kind='netAdvancedProperty';name='MIMO Power Save Mode';keywords=@('MIMOPowerSaveMode');value='No SMPS';valuePattern='No SMPS'},@{kind='netAdvancedProperty';name='U-APSD Support';keywords=@('UAPSDSupport','uAPSDSupport');regValue='0';value='Disabled';valuePattern='^Disabled$'},@{kind='netAdvancedProperty';keywords=@('bLeisurePs');regValue='0';value='Disabled';valuePattern='(?i)disable'},@{kind='netAdvancedProperty';keywords=@('sleepMode');regValue='0';value='Off';valuePattern='^Off$'},@{kind='netAdvancedProperty';keywords=@('MPC');regValue='0';value='Disabled';valuePattern='^Disabled$'}) -Info 'Turns off the Wi-Fi power-save features your adapter has: MediaTek Power Saving, Intel MIMO power save (No SMPS keeps every antenna active) and U-APSD, Realtek Leisure Power Save, Qualcomm/Killer Power Save Mode and Broadcom Minimum Power Consumption. In power save the adapter sleeps between beacons and packets wait for it to wake, which shows up as ping spikes. Unticking restores the previous values.' -Warn 'The Wi-Fi adapter draws a little more power; on laptops on battery that shortens battery life slightly.')
$qosApply = @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS';name='Do not use NLA';value='1';type='String'}) + @($script:RecognizedGames | ForEach-Object { @{kind='qosGame';exe=$_.Path;enable=$true} })
$qosRevert = @(@{kind='registryDel';path='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS';name='Do not use NLA'}) + @($script:RecognizedGames | ForEach-Object { @{kind='qosGame';exe=$_.Path;enable=$false} })
$script:Tweaks += (New-Tweak -Id 'net.qos.games' -Tab 'Networking' -SubTab '' -Group 'QoS and MTU' -Label 'Tag recognised games'' traffic as high priority (DSCP 46)' -Risk 'Safe' -Detect @{kind='recognizedGames'} -Apply $qosApply -Revert $qosRevert -Info ('Creates a Windows policy-based QoS rule for each game Windows has recognised ({0}) that marks its packets with DSCP 46 (Expedited Forwarding), and sets the "Do not use NLA" value Windows needs before QoS policies apply on a home (non-domain) network. Windows ignores DSCP values that apps set themselves; only these policies can mark traffic. On Wi-Fi, DSCP 46 maps to the voice queue (WMM), which gets airtime first when the network is busy; on a wired connection it only helps if your router prioritises DSCP (SQM / smart queue or gaming QoS). It does not change ping on an idle connection. Unticking removes the rules.' -f $(if ($gameList) { $gameList } else { 'none yet' })))
$script:Tweaks += (New-Tweak -Id 'pwr.pcie.aspm' -Tab 'Advanced' -SubTab '' -Group 'Power and adapters' -Label 'Turn off PCIe link power saving (ASPM)' -Risk 'Moderate' -Detect @{kind='powerSettingPresent';sub='501a4d13-42af-4429-9fd1-a8218c268e20';setting='ee12f906-d277-404b-b6da-e5fa1a576df5'} -Apply @(@{kind='powerSetting';sub='501a4d13-42af-4429-9fd1-a8218c268e20';setting='ee12f906-d277-404b-b6da-e5fa1a576df5';value=0;label='PCIe ASPM'}) -Revert @(@{kind='powerSetting';sub='501a4d13-42af-4429-9fd1-a8218c268e20';setting='ee12f906-d277-404b-b6da-e5fa1a576df5';value='Default';label='PCIe ASPM'}) -Info 'Sets PCI Express Link State Power Management to Off in the active power plan, plugged in and on battery. ASPM puts GPU, NVMe and network links into low-power states between transfers; Off avoids the wake-up delay and uses a few more watts at idle. Unticking restores the previous values, or the plan default.')
$script:Tweaks += (New-Tweak -Id 'pwr.usb.suspend' -Tab 'Advanced' -SubTab '' -Group 'Power and adapters' -Label 'Turn off USB selective suspend' -Risk 'Moderate' -Detect @{kind='powerSettingPresent';sub='2a737441-1930-4402-8d77-b2bebba308a3';setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'} -Apply @(@{kind='powerSetting';sub='2a737441-1930-4402-8d77-b2bebba308a3';setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226';value=0;label='USB selective suspend'}) -Revert @(@{kind='powerSetting';sub='2a737441-1930-4402-8d77-b2bebba308a3';setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226';value='Default';label='USB selective suspend'}) -Info 'Stops Windows from suspending idle USB devices in the active power plan, which avoids wake-up delays and dropouts on mice, audio interfaces and controllers. Laptops use a little more battery. Unticking restores the previous values, or the plan default.')
$script:Tweaks += (New-Tweak -Id 'gpu.intel.todo' -Tab 'GPU' -SubTab '' -Group 'Intel' -Label 'Disable Intel Graphics Software at sign-in' -Risk 'Safe' -Detect @{kind='runkey';name='IntelGraphicsSoftware'} -Apply @(@{kind='runkey';name='IntelGraphicsSoftware';remove=$true}) -Revert @() -Info 'Removes Intel Graphics Software from startup. The driver still loads; only the tray companion is stopped.')
 
$script:Tweaks += (New-Tweak -Id 'cpu.plan' -Tab 'CPU' -SubTab '' -Group 'Power' -Label 'Power plan' -Risk 'Safe' -Type 'dropdown' -Options @('Balanced','High performance','Ultimate Performance',"Rion's power plan") -Detect $null -Info 'Selects the active Windows power plan. Balanced with Windows Power mode set to Best performance is the best general choice; AMD Ryzen X3D and Intel hybrid CPUs rely on Balanced for core parking and scheduling. Ultimate Performance keeps cores from idling, raises idle power and gives no measurable gain; avoid it on laptops. Rion''s power plan creates a copy of Ultimate Performance named "Rion''s power plan".')
$script:Tweaks += (New-Tweak -Id 'cpu.parking' -Tab 'CPU' -SubTab '' -Group 'Scheduling' -Label 'Disable CPU core parking' -Risk 'Moderate' -Detect @{kind='coreParkingAllowed'} -Apply @(@{kind='coreparking';park=$false}) -Revert @(@{kind='coreparking';park=$true}) -Info 'Core parking powers down idle cores. Disabling keeps all cores available, which can help bursty workloads on a desktop with one type of core, but raises idle power. Not offered on laptops, Ryzen X3D (parking steers games onto the 3D V-Cache die) or Intel hybrid CPUs such as 12th-14th gen and Core Ultra (parking and Thread Director keep games on the P-cores). Applied to the active power plan.')
$script:Tweaks += (New-Tweak -Id 'cpu.boost' -Tab 'CPU' -SubTab '' -Group 'Power' -Label 'Processor boost mode' -Risk 'Moderate' -Type 'dropdown' -Options @('Default','Enabled','Aggressive','Disabled') -Detect $null -Info 'Configures the active power plan CPU boost policy with powercfg PERFBOOSTMODE. Aggressive can increase heat and power use; Disabled reduces peak performance. Default leaves policy unchanged.' )
 
$script:Tweaks += (New-Tweak -Id 'adv.bcd.timers' -Tab 'Advanced' -SubTab '' -Group 'Timers' -Label 'Remove BCD timer overrides' -Risk 'Safe' -Detect $null -Apply @(@{kind='bcdedit';args='/deletevalue useplatformclock';ignore=$true},@{kind='bcdedit';args='/deletevalue useplatformtick';ignore=$true},@{kind='bcdedit';args='/deletevalue disabledynamictick';ignore=$true},@{kind='bcdedit';args='/deletevalue tscsyncpolicy';ignore=$true}) -Revert @() -Info 'Deletes useplatformclock / useplatformtick / disabledynamictick / tscsyncpolicy. These overrides force HPET or change timer behaviour and are linked to input lag and stutter, with no measured gain on invariant-TSC CPUs. The correct state is no override. Values that are not set are left alone; if BitLocker is on it is suspended for one restart first.')
$script:Tweaks += (New-Tweak -Id 'adv.boot.menu' -Tab 'Advanced' -SubTab '' -Group 'Boot' -Label 'Set legacy boot menu and 3s timeout' -Risk 'Safe' -Detect $null -Apply @(@{kind='bcdedit';args='/set {current} bootmenupolicy legacy'},@{kind='bcdedit';args='/timeout 3'}) -Revert @(@{kind='bcdedit';args='/set {current} bootmenupolicy standard'}) -Info 'Uses the text boot menu and a 3-second timeout. Cosmetic/boot-speed preference; does not affect performance in Windows.')
$script:Tweaks += (New-Tweak -Id 'adv.devices.rdpredirect' -Tab 'Advanced' -SubTab '' -Group 'Virtual and debug adapters' -Label 'Disable Remote Desktop device redirection' -Risk 'Moderate' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services';name='fDisableCdm'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services';name='fDisableCdm';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services';name='fDisableCdm'}) -Info 'Disables drive redirection in incoming Remote Desktop sessions by policy. Remote users will not be able to access this PC local drives through RDP.' )
 
$script:Tweaks += (New-Tweak -Id 'sec.defender' -Tab 'Security' -SubTab '' -Group 'Defender' -Label 'Disable Microsoft Defender (requires Tamper Protection off)' -Risk 'Risky' -Detect @{kind='service';name='WinDefend'} -Apply @(@{kind='defender';enable=$false}) -Revert @(@{kind='defender';enable=$true}) -Warn 'Turns off all built-in antivirus: real-time protection, scheduled and on-access scans, cloud submission, the Defender services (WinDefend, WdNisSvc, Sense, MDCoreSvc) and every Windows Defender scheduled task. The PC has no built-in malware protection until re-enabled, and some anti-cheat and apps may refuse to run.' -Info 'Fully turns off Microsoft Defender: real-time, behaviour and on-access protection, scheduled scans, cloud and sample submission, the DisableAntiSpyware/DisableAntiVirus policies, its services (WinDefend, WdNisSvc, Sense, MDCoreSvc) and all its scheduled tasks. Tamper Protection must be off first; the tool opens that page and waits. The ELAM boot drivers stay so Windows still boots. Unticking restores everything.')
$script:Tweaks += (New-Tweak -Id 'sec.updates' -Tab 'Security' -SubTab '' -Group 'Updates' -Label 'Disable Windows Update' -Risk 'Risky' -Detect @{kind='serviceAny';names=@('wuauserv','UsoSvc','WaaSMedicSvc');start='Disabled'} -Apply @(@{kind='update';enable=$false}) -Revert @(@{kind='update';enable=$true}) -Info 'Sets wuauserv/UsoSvc/WaaSMedicSvc to disabled and stops them. Re-enabling restores Automatic/Manual start and starts the services again. You will receive no security updates while disabled.')
$script:Tweaks += (New-Tweak -Id 'sec.vbs' -Tab 'Security' -SubTab '' -Group 'Core isolation' -Label 'Memory Integrity (HVCI)' -Risk 'Moderate' -Type 'dropdown' -Options @('Default','On','Off') -Detect @{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity';name='Enabled'} -Info 'Memory Integrity (HVCI) protects kernel code. Turning it off can reduce security and may prevent Riot Vanguard or other anti-cheat software from running when that protection is required. Rion warns before applying Off. Reboot required.')
$script:Tweaks += (New-Tweak -Id 'sec.encryption.prevent' -Tab 'Security' -SubTab '' -Group 'Encryption' -Label 'Prevent automatic device encryption' -Risk 'Moderate' -Detect @{kind='bitlockerSupported'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\FVE';name='PreventDeviceEncryption';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\FVE';name='PreventDeviceEncryption'}) -Info 'Prevents automatic device encryption provisioning by policy. It does not decrypt a drive that is already encrypted.' )
$script:Tweaks += (New-Tweak -Id 'sec.encryption.decrypt' -Tab 'Security' -SubTab '' -Group 'Encryption' -Label 'Decrypt software BitLocker on the system drive' -Risk 'Risky' -Detect @{kind='bitlockerOn'} -Apply @(@{kind='bitlockerOff'}) -ApplyVerb 'Starting decryption of' -DoneVerb 'Started system-drive decryption' -Info 'Starts manage-bde decryption of the Windows system drive. Decryption runs in the background and can take a long time; recovery protection is reduced. Rion cannot automatically restore encryption because that requires a valid protector and may need the recovery key.' )
$script:Tweaks += (New-Tweak -Id 'sec.widgets' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off Widgets' -Risk 'Safe' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';name='AllowNewsAndInterests'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';name='AllowNewsAndInterests';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh';name='AllowNewsAndInterests'}) -Info 'Disables the Widgets/news feed policy. Widgets will be unavailable until the policy is removed.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.crossresume' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Disable cross-device resume' -Risk 'Safe' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableCdp'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableCdp';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableCdp'}) -Info 'Disables Connected Devices Platform cross-device experiences by policy. Phone Link and cross-device resume features may stop syncing.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.recall' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Disable Recall' -Risk 'Safe' -Detect @{kind='appxPattern';pattern='*Client.AIX*'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableAIDataAnalysis';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableAIDataAnalysis'}) -Info 'Disables Recall snapshot analysis by Windows policy when Recall components are installed. This does not remove Recall data already saved.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.clicktodo' -Tab 'Tweaks' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Disable Click to Do' -Risk 'Safe' -Detect $null -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableClickToDo';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';name='DisableClickToDo'}) -Info 'Turns off Click to Do with the documented WindowsAI DisableClickToDo policy. Click to Do is part of a Windows system package and cannot be uninstalled, so this policy is the supported way to turn it off. It has no effect on PCs without the feature.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.storebackground' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Disable background apps for Store apps' -Risk 'Moderate' -Detect @{kind='appxAny'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsRunInBackground';value=2;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsRunInBackground_ForceAllowTheseApps';value=$script:ShellBackgroundApps;type='MultiString'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsRunInBackground'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsRunInBackground_ForceAllowTheseApps'}) -Info 'Blocks Store apps from running in the background by device policy, while always allowing the Start menu, Search, shell and text-input apps (blocking those makes Start ignore typing until you click the search box). Live tiles, notifications, sync, and background downloads of other Store apps may stop.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.updates.manual' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label 'Set Windows Update to manual' -Risk 'Moderate' -Detect @{kind='serviceAny';names=@('wuauserv','UsoSvc','WaaSMedicSvc');start='Manual'} -Apply @(@{kind='updateManual'}) -Revert @(@{kind='update';enable=$true}) -Info 'Sets Windows Update services to Manual/on-demand startup. Windows may still start them for maintenance; use the separate Disable Windows Update switch only if you accept missing security updates.' )
$script:Tweaks += (New-Tweak -Id 'sec.privacy.cortana' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable Cortana consent' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';name='CortanaConsent'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';name='CortanaConsent';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';name='CortanaConsent'}) -Info 'Turns off Cortana search consent for the current user.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.locktips' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable rotating lock screen and tips' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='RotatingLockScreenEnabled'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='RotatingLockScreenEnabled';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='RotatingLockScreenOverlayEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='RotatingLockScreenEnabled'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='RotatingLockScreenOverlayEnabled'}) -Info 'Stops rotating Spotlight lock-screen photos and its overlay tips for the current user.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.feedback' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Disable feedback prompts' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Siuf\Rules';name='NumberOfSIUFInPeriod'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Siuf\Rules';name='NumberOfSIUFInPeriod';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Siuf\Rules';name='NumberOfSIUFInPeriod'}) -Info 'Stops Windows feedback request prompts for this user.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.inking' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Disable inking and typing harvesting' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Input\TIPC';name='Enabled'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Input\TIPC';name='Enabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Input\TIPC';name='Enabled'}) -Info 'Disables optional typing and inking data collection for the current user. Personalized typing suggestions may be reduced.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.errorreporting' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Disable compatibility and error reporting collection' -Risk 'Moderate' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting';name='Disabled'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting';name='Disabled';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat';name='AITEnable';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting';name='Disabled'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat';name='AITEnable'}) -Info 'Turns off Windows Error Reporting and Application Impact Telemetry by policy. Crash reports and compatibility diagnostics will not be sent.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.cloudcontent' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable cloud content and suggestions' -Risk 'Safe' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';name='DisableWindowsConsumerFeatures'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';name='DisableWindowsConsumerFeatures';value=1;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338388Enabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';name='DisableWindowsConsumerFeatures'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';name='SubscribedContent-338388Enabled'}) -Info 'Disables Windows consumer content suggestions and one tip subscription. Personalized recommendations and some first-run suggestions disappear.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.clipboard' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Disable cloud clipboard upload' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Clipboard';name='EnableCloudClipboard'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Clipboard';name='EnableCloudClipboard';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Clipboard';name='EnableCloudClipboard'}) -Info 'Turns off clipboard sync across devices for this user. Local clipboard use remains available.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.finishsetup' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable Finish setting up your device' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';name='ScoobeSystemSettingEnabled'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';name='ScoobeSystemSettingEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';name='ScoobeSystemSettingEnabled'}) -Info 'Suppresses the Windows post-setup suggestions page for this user.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.adid' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable advertising ID' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';name='Enabled'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';name='Enabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';name='Enabled'}) -Info 'Turns off the advertising ID for this Windows user. Apps can still use their own identifiers.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.tailored' -Tab 'Tweaks' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Disable tailored experiences' -Risk 'Safe' -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';name='TailoredExperiencesWithDiagnosticDataEnabled'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';name='TailoredExperiencesWithDiagnosticDataEnabled';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';name='TailoredExperiencesWithDiagnosticDataEnabled'}) -Info 'Stops Windows from using diagnostic data to personalize tips and recommendations for this user.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.telemetry' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Set diagnostic data to the lowest level' -Risk 'Safe' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='AllowTelemetry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='AllowTelemetry';value=0;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='LimitDiagnosticLogCollection';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='LimitDumpCollection';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='DisableOneSettingsDownloads';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='DoNotShowFeedbackNotifications';value=1;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='AllowDeviceNameInTelemetry';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='AllowTelemetry'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='LimitDiagnosticLogCollection'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='LimitDumpCollection'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='DisableOneSettingsDownloads'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='DoNotShowFeedbackNotifications'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';name='AllowDeviceNameInTelemetry'}) -Info 'AllowTelemetry=0 (Security level; Home and Pro treat it as Required, the lowest they allow), plus the documented policies that limit diagnostic log and dump collection, stop OneSettings downloads, hide feedback prompts and keep the device name out of diagnostic data. Windows Update and Defender keep working.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.privacy.activity' -Tab 'Tweaks' -SubTab 'Features' -Group 'Cloud and cross-device' -Label 'Disable activity history' -Risk 'Safe' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableActivityFeed'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableActivityFeed';value=0;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='PublishUserActivities';value=0;type='DWord'},@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='UploadUserActivities';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='EnableActivityFeed'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='PublishUserActivities'},@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';name='UploadUserActivities'}) -Info 'Stops activity history publication and upload by policy. Timeline and cross-device activity features may be unavailable.'  -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.search.local' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Keep Windows Search on local results' -Risk 'Moderate' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';name='ConnectedSearchUseWeb'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';name='ConnectedSearchUseWeb';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';name='ConnectedSearchUseWeb'}) -Info 'Uses the documented Windows Search policy to prevent web queries and web results in Search. Local files and settings remain searchable; search suggestions from the web are removed.' -Recommend $true)
$script:Tweaks += (New-Tweak -Id 'sec.gamedvr' -Tab 'Tweaks' -SubTab 'Features' -Group 'Gaming' -Label 'Turn off Windows Game DVR recording' -Risk 'Moderate' -Detect @{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';name='AllowGameDVR'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';name='AllowGameDVR';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';name='AllowGameDVR'}) -Info 'Uses the Windows Game Recording and Broadcasting policy to block Game DVR captures. Xbox Game Bar can still open, but recording and broadcasting are unavailable until this policy is removed.' -Recommend $true)

$pnKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$pnPol = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'
$ncKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$wdNot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'
$notifyApply = @(
    @{kind='registry';path=$pnKey;name='ToastEnabled';value=0;type='DWord'},
    @{kind='registry';path=$pnPol;name='NoToastApplicationNotification';value=1;type='DWord'},
    @{kind='registry';path=$pnPol;name='NoToastApplicationNotificationOnLockScreen';value=1;type='DWord'},
    @{kind='registry';path=$pnPol;name='NoCloudApplicationNotification';value=1;type='DWord'},
    @{kind='registry';path=$ncKey;name='NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK';value=0;type='DWord'},
    @{kind='registry';path=$ncKey;name='NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK';value=0;type='DWord'},
    @{kind='registry';path=$wdNot;name='DisableEnhancedNotifications';value=1;type='DWord'}
)

$prioKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
$script:Tweaks += (New-Tweak -Id 'adv.prio.sep26' -Tab 'Advanced' -SubTab '' -Group 'Priorities' -Label 'Foreground priority separation 0x26' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply @(@{kind='registry';path=$prioKey;name='Win32PrioritySeparation';value=38;type='DWord'}) -Revert @(@{kind='registry';path=$prioKey;name='Win32PrioritySeparation';value=2;type='DWord'}) -Info 'Sets Win32PrioritySeparation to 0x26 (38): short, variable quantum with the 3x foreground boost, so the game or app in front gets the longest time slices. Same behaviour as the Windows client default (0x2), written explicitly so other tools cannot leave a fixed-quantum value behind.')

$script:Tweaks += (New-Tweak -Id 'mem.prelaunch' -Tab 'Advanced' -SubTab '' -Group 'Memory' -Label 'Stop Store app pre-launching' -Risk 'Safe' -Recommend $true -Detect @{kind='mmagent'} -Apply @(@{kind='mmagent';feature='ApplicationPreLaunch';enable=$false}) -Revert @(@{kind='mmagent';feature='ApplicationPreLaunch';enable=$true}) -Info 'Disable-MMAgent -ApplicationPreLaunch: Windows stops starting Store apps in the background before you open them, freeing RAM and avoiding surprise GPU wake-ups on laptops. Those apps open a moment slower.')
$script:Tweaks += (New-Tweak -Id 'mem.pagecombining' -Tab 'Advanced' -SubTab '' -Group 'Memory' -Label 'Turn off memory page combining' -Risk 'Moderate' -Detect @{kind='mmagent'} -Apply @(@{kind='mmagent';feature='PageCombining';enable=$false}) -Revert @(@{kind='mmagent';feature='PageCombining';enable=$true}) -Info 'Disable-MMAgent -PageCombining: stops the periodic scan that merges identical memory pages. Saves a little background CPU work but uses slightly more RAM. No measured gaming gain; most useful with plenty of RAM.')
$script:Tweaks += (New-Tweak -Id 'mem.compression' -Tab 'Advanced' -SubTab '' -Group 'Memory' -Label 'Turn off memory compression (32 GB+ RAM)' -Risk 'Moderate' -Detect @{kind='mmagent';minRamGB=32} -Apply @(@{kind='mmagent';feature='MemoryCompression';enable=$false}) -Revert @(@{kind='mmagent';feature='MemoryCompression';enable=$true}) -Info 'Disable-MMAgent -MemoryCompression: Windows stops compressing idle memory, which saves CPU work but means more paging once RAM fills up. Only offered with 32 GB or more; on 8-16 GB it makes stutter worse. Restart required.')

$ppmSub = '54533251-82be-4824-96c1-47b60b740d00'
$ppmKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$ppmSub"
$unhideApply = @(Get-ChildItem -LiteralPath $ppmKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object { @{kind='registry';path=$_.PSPath;name='Attributes';value=2;type='DWord'} })
if ($unhideApply.Count) { $script:Tweaks += (New-Tweak -Id 'cpu.unhide' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Show every processor setting in Power Options' -Risk 'Safe' -Recommend $true -Detect @{kind='registry'} -Apply $unhideApply -Revert @() -Info ('Unhides all {0} processor power management settings (boost mode and policy, energy performance preference, core parking, performance increase/decrease thresholds and policies, idle states, latency hints, efficiency-class settings...) in Control Panel > Power Options > Change advanced power settings, the same list Power Settings Explorer shows. Display only; no value changes.' -f $unhideApply.Count)) }

function New-PpmAction { param([string]$Guid,[int]$Value,[string]$Label) @{kind='powerSetting';sub=$ppmSub;setting=$Guid;value=$Value;label=$Label;acOnly=$true} }
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.responsive' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Faster clock ramp-up when plugged in' -Risk 'Moderate' -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='06cadf0e-64ed-448a-8927-ce7bf90eb35d'} -Apply @(
    (New-PpmAction '06cadf0e-64ed-448a-8927-ce7bf90eb35d' 10 'Performance increase threshold'),
    (New-PpmAction '06cadf0e-64ed-448a-8927-ce7bf90eb35e' 10 'Performance increase threshold (E-cores)'),
    (New-PpmAction '12a0ab44-fe28-4fa9-b3bd-4b64f44960a6' 8 'Performance decrease threshold'),
    (New-PpmAction '12a0ab44-fe28-4fa9-b3bd-4b64f44960a7' 8 'Performance decrease threshold (E-cores)'),
    (New-PpmAction '984cf492-3bed-4488-a8f9-4286c97bf5aa' 1 'Performance increase time'),
    (New-PpmAction '984cf492-3bed-4488-a8f9-4286c97bf5ab' 1 'Performance increase time (E-cores)'),
    (New-PpmAction '465e1f50-b610-473a-ab58-00d1077dc418' 2 'Performance increase policy (Rocket)'),
    (New-PpmAction '465e1f50-b610-473a-ab58-00d1077dc419' 2 'Performance increase policy (Rocket, E-cores)'),
    (New-PpmAction '40fbefc7-2e9d-4d25-a185-0cfd8574bac6' 1 'Performance decrease policy (Single)'),
    (New-PpmAction '40fbefc7-2e9d-4d25-a185-0cfd8574bac7' 1 'Performance decrease policy (Single, E-cores)'),
    (New-PpmAction 'd8edeb9b-95cf-4f95-a73c-b061973693c8' 1 'Performance decrease time'),
    (New-PpmAction 'd8edeb9b-95cf-4f95-a73c-b061973693c9' 1 'Performance decrease time (E-cores)'),
    (New-PpmAction '45bcc044-d885-43e2-8605-ee0ec6e96b59' 100 'Performance boost policy'),
    (New-PpmAction '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' 0 'Energy performance preference (favor performance)'),
    (New-PpmAction '36687f9e-e3a5-4dbf-b1dc-15eb381c6864' 0 'Energy performance preference (E-cores)')
) -Revert @() -Info 'Plugged-in values only (battery untouched): raise clocks at 10% load instead of waiting for higher load, step up immediately (increase time 1, Rocket policy, boost policy 100), favour performance over efficiency (energy performance preference 0 for both core types) and step down one level at a time (Single policy, 8% decrease threshold). On modern CPUs in hardware autonomous mode (Intel Speed Shift, AMD CPPC) the energy performance preference is the main lever, so this still helps there. Unticking restores the previous values. This overlaps with the Energy performance preference row; use one or the other.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.latency' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Full speed on latency-sensitive input' -Risk 'Safe' -Recommend $true -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='619b7505-003b-4e82-b7a6-4dd29c300971'} -Apply @(
    (New-PpmAction '619b7505-003b-4e82-b7a6-4dd29c300971' 100 'Latency sensitivity hint processor performance'),
    (New-PpmAction '619b7505-003b-4e82-b7a6-4dd29c300972' 100 'Latency sensitivity hint processor performance (E-cores)'),
    (New-PpmAction '616cdaa5-695e-4545-97ad-97dc2d1bdd88' 100 'Latency sensitivity hint min unparked cores'),
    (New-PpmAction '616cdaa5-695e-4545-97ad-97dc2d1bdd89' 100 'Latency sensitivity hint min unparked cores (E-cores)')
) -Revert @() -Info 'When Windows flags a latency-sensitive moment (mouse, keyboard, touch input and app launches), use 100% processor performance and keep all cores unparked, plugged in only. Applies only during those hints, so idle power is unchanged.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.throttle' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'No throttle states or duty cycling when plugged in' -Risk 'Moderate' -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb'} -Apply @(
    (New-PpmAction '3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb' 0 'Allow throttle states (Off)'),
    (New-PpmAction '4e4450b3-6179-4e91-b8f1-5bb9938f81a1' 0 'Processor duty cycling (Disabled)')
) -Revert @() -Info 'Stops Windows from using clock-modulation throttle states and duty cycling while plugged in. Thermal protection by the CPU itself is unaffected. Little effect on most modern CPUs, which rarely use these states.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.minstate' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Minimum processor state 100% when plugged in' -Risk 'Moderate' -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='893dee8e-2bef-41e0-89c6-b55d0929964c';desktopOnly=$true} -Apply @(
    (New-PpmAction '893dee8e-2bef-41e0-89c6-b55d0929964c' 100 'Minimum processor state'),
    (New-PpmAction '893dee8e-2bef-41e0-89c6-b55d0929964d' 100 'Minimum processor state (E-cores)')
) -Revert @() -Info 'Keeps the requested clock floor at 100% so the CPU never waits to ramp up. Raises idle power and temperature; boost still depends on cooling. Desktop only.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.idle' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Disable CPU idle states when plugged in' -Risk 'Risky' -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='5d76a2ca-e8c0-402f-a133-2158492d58ad';desktopOnly=$true;notAmdCpu=$true} -Apply @(
    (New-PpmAction '5d76a2ca-e8c0-402f-a133-2158492d58ad' 1 'Processor idle disable')
) -Revert @() -Info 'Forces every core to stay in C0, removing wake-up delay. Much higher idle power and heat, and with Hyper-Threading/SMT enabled it usually lowers single-thread boost, so it often loses FPS. Benchmark before keeping. Desktop only.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.hetero' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Prefer performance cores for short bursty threads (hybrid CPUs)' -Risk 'Moderate' -Recommend $false -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='bae08b81-2d5e-4688-ad6a-13243356654b';hybridOnly=$true} -Warn 'Overrides Intel Thread Director/Windows scheduling: short-running threads are pushed onto performance cores. Can raise heat and, in some games, hurt frame pacing versus the default. Benchmark it.' -Apply @(
    @{kind='powerSetting';sub=$ppmSub;setting='bae08b81-2d5e-4688-ad6a-13243356654b';value=2;label='Heterogeneous short-running thread policy (Prefer performant)'}
) -Revert @(@{kind='powerSetting';sub=$ppmSub;setting='bae08b81-2d5e-4688-ad6a-13243356654b';value='Default';label='Heterogeneous short-running thread policy'}) -Info 'On Intel hybrid CPUs (12th-14th gen and Core Ultra, including the 225H) sets the short-running thread scheduling policy to "Prefer performant processors" (both plugged in and on battery), so brief game and app threads favour the P-cores instead of E-cores. Windows and Thread Director normally place these well on their own, so this is a measure-first tweak that can help or hurt depending on the game. Unticking restores the Windows default.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.perfepp' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Energy performance preference: favour performance (plugged in)' -Risk 'Moderate' -Recommend $false -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='36687f9e-e3a5-4dbf-b1dc-15eb381c6863'} -Apply @(
    (New-PpmAction '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' 0 'Energy performance preference'),
    (New-PpmAction '36687f9e-e3a5-4dbf-b1dc-15eb381c6864' 0 'Energy performance preference (E-cores)')
) -Revert @() -Info 'Sets the processor energy performance preference to 0 (maximum performance) for both core types, plugged in only. On modern CPUs in hardware autonomous mode (Intel Speed Shift, AMD CPPC) this is the single biggest clock-responsiveness lever. Raises power draw and heat. Use this or the Faster clock ramp-up row, not both.')

$script:Tweaks += New-ServiceGroup -Id 'svc.dev.sensordata' -Tab 'Tweaks' -SubTab 'Services' -Group 'Sensors and mixed reality' -Label 'Stop sensor data collection' -Risk 'Safe' -Services @('SensorDataService') -Info 'Sensor Data Service collects data from attached sensors for apps. Not needed on a desktop without sensors; laptops may lose auto-rotate or adaptive features.'

function New-RegRow {
    param([string]$Id,[string]$SubTab,[string]$Group,[string]$Label,[string]$Risk,$Detect,[array]$Values,[string]$Info,[string]$Tab = 'Tweaks',$Recommend = $true)
    if ($Values.Count -gt 0 -and $Values[0] -isnot [array]) { $Values = ,$Values }
    $apply =@($Values | ForEach-Object { @{kind='registry';path=$_[0];name=$_[1];value=$_[2];type=$(if ($_.Count -gt 3) { $_[3] } else { 'DWord' })} })
    $revert = @($apply | ForEach-Object { @{kind='registryDel';path=$_.path;name=$_.name} })
    New-Tweak -Id $Id -Tab $Tab -SubTab $SubTab -Group $Group -Label $Label -Risk $Risk -Recommend $Recommend -Detect $Detect -Apply $apply -Revert $revert -Info $Info
}
$wai = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
$waiU = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'
$cc = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$edgeDetect = @{kind='anyPath';paths=$script:BrowserPaths.Edge}
$script:Tweaks += (New-RegRow -Id 'feat.ai.copilotall' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off and remove Copilot' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot','TurnOffWindowsCopilot',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot','TurnOffWindowsCopilot',1),
    @($wai,'RemoveMicrosoftCopilotApp',1),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','ShowCopilotButton',0)
) -Info 'WindowsAI policies TurnOffWindowsCopilot and RemoveMicrosoftCopilotApp (24H2 and later): Copilot is turned off, its taskbar entry hidden, and Windows uninstalls the Microsoft Copilot app. Microsoft 365 apps are not affected.')
$script:Tweaks += (New-RegRow -Id 'feat.ai.askcopilot' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off Ask Copilot on the taskbar and the Copilot key' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','TaskbarCompanion',0),
    @('HKCU:\Software\Microsoft\Windows\Shell\BrandedKey','BrandedKeyChoiceType','NoneSelected','String')
) -Info 'Removes the Ask Copilot box that can replace taskbar search and stops the Copilot key on newer keyboards from opening Copilot. Normal Windows Search is unchanged.')
$script:Tweaks += (New-RegRow -Id 'feat.ai.agents' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Turn off AI agent connectors and Recall data providers' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @($wai,'ConfigureAgentConnectors',2),
    @($waiU,'DisableRecallDataProviders',1)
) -Info 'WindowsAI policies ConfigureAgentConnectors (force disable) and DisableRecallDataProviders: AI agents cannot connect to apps and services on this PC through agent connectors (MCP), and Recall gets no extra activity details from app providers.')
$script:Tweaks += (New-RegRow -Id 'feat.shell.bingstart' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Turn off Bing web results and Cortana in Start' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Policies\Microsoft\Windows\Explorer','DisableSearchBoxSuggestions',1),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search','BingSearchEnabled',0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search','AllowCortana',0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search','DisableWebSearch',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search','ConnectedSearchUseWeb',0)
) -Info 'Start and taskbar search show only apps, settings and files on this PC: no Bing web results, web suggestions or Cortana. Typing in Start still works normally.')
$script:Tweaks += (New-RegRow -Id 'feat.privacy.spotlight' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Turn off Spotlight and third-party suggestions' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @($cc,'DisableWindowsSpotlightFeatures',1),
    @($cc,'DisableThirdPartySuggestions',1),
    @($cc,'DisableTailoredExperiencesWithDiagnosticData',1),
    @($cc,'DisableSpotlightCollectionOnDesktop',1),
    @($cc,'DisableWindowsSpotlightOnActionCenter',1),
    @($cc,'DisableWindowsSpotlightWindowsWelcomeExperience',1)
) -Info 'CloudContent user policies: no Windows Spotlight lock screen or desktop pictures, no suggested third-party apps, no tailored tips from diagnostic data, no Spotlight prompts in the notification center or post-update welcome pages. Pick your own wallpaper and lock screen picture afterwards.')
$script:Tweaks += (New-RegRow -Id 'feat.privacy.input' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Stop typing, inking and speech personalization' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization','AllowInputPersonalization',0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization','RestrictImplicitTextCollection',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization','RestrictImplicitInkCollection',1),
    @('HKCU:\Software\Microsoft\input\Settings','InsightsEnabled',0)
) -Info 'Windows stops collecting your typing and handwriting to build a personal dictionary and speech model, and turns off typing insights. Spell check and text prediction keep working with the built-in dictionary.')
$script:Tweaks += (New-RegRow -Id 'feat.privacy.findmydevice' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Turn off Find My Device' -Risk 'Moderate' -Detect @{kind='registry'} -Values @(
    ,@('HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice','AllowFindMyDevice',0)
) -Info 'Stops Windows from reporting this PC''s location to your Microsoft account for Find My Device. On a laptop you can no longer locate or lock it remotely if it is lost.')
$script:Tweaks += (New-RegRow -Id 'app.edge.privacy' -SubTab 'Apps' -Group 'Browsers' -Label 'Edge: turn off diagnostics, shopping and recommendations' -Risk 'Safe' -Detect $edgeDetect -Values @(
    @($edge,'DiagnosticData',0),
    @($edge,'PersonalizationReportingEnabled',0),
    @($edge,'UserFeedbackAllowed',0),
    @($edge,'EdgeShoppingAssistantEnabled',0),
    @($edge,'ShowRecommendationsEnabled',0),
    @($edge,'SpotlightExperiencesAndRecommendationsEnabled',0),
    @($edge,'NewTabPageContentEnabled',0),
    @($edge,'ConfigureDoNotTrack',1)
) -Info 'Edge policies: no optional diagnostic data, no browsing-based personalization, no feedback prompts, no shopping assistant or coupon pop-ups, no in-browser recommendations, no MSN news feed on the new tab page, and Do Not Track sent to sites. Restart Edge.')
$script:Tweaks += (New-RegRow -Id 'app.edge.ai' -SubTab 'Apps' -Group 'Browsers' -Label 'Edge: turn off Copilot and AI writing' -Risk 'Safe' -Detect $edgeDetect -Values @(
    @($edge,'CopilotPageContext',0),
    @($edge,'EdgeEntraCopilotPageContext',0),
    @($edge,'Microsoft365CopilotChatIconEnabled',0),
    @($edge,'ComposeInlineEnabled',0),
    @($edge,'GenAILocalFoundationalModelSettings',1)
) -Info 'Edge policies: Copilot cannot read the page you are on, the Microsoft 365 Copilot chat button is hidden, inline AI writing (Compose) is off, and Edge does not download its on-device AI model. Pair with Turn off the Copilot sidebar in Edge.')

$script:Tweaks += (New-RegRow -Id 'feat.privacy.ceip' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Turn off the Customer Experience Improvement Program' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows','CEIPEnable',0),
    @('HKLM:\SOFTWARE\Microsoft\SQMClient\Windows','CEIPEnable',0)
) -Info 'Stops the Customer Experience Improvement Program from collecting and sending usage data to Microsoft. No effect on updates or security.')
$script:Tweaks += (New-RegRow -Id 'feat.privacy.quickaccess' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Stop showing recent files and frequent folders' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer','ShowRecent',0),
    @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer','ShowFrequent',0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','Start_TrackDocs',0)
) -Info 'File Explorer Quick Access and the Start menu stop listing your recently opened files and most-used folders. The files are not touched.')
$script:Tweaks += (New-Tweak -Id 'adv.ui.animations' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Turn off window and taskbar animations' -Risk 'Safe' -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Control Panel\Desktop\WindowMetrics';name='MinAnimate';value='0';type='String'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='TaskbarAnimations';value=0;type='DWord'}) -Info 'Turns off "Animate windows when minimizing and maximizing" and "Animations in the taskbar" (System Properties > Performance Options). Windows open, minimise and restore instantly instead of after a short animation, so the desktop feels faster. In-game FPS does not change. Takes effect after signing out. Unticking restores the previous values.' -Warn 'Purely visual: windows snap open and closed with no motion.')
$script:Tweaks += (New-Tweak -Id 'feat.sys.hibernate' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Turn off hibernation' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Power';name='HibernateEnabled';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Power';name='HibernateEnabled';value=1;type='DWord'}) -Info 'Turns hibernation off after the next restart and frees the space hiberfil.sys takes on the system drive (often 6-25 GB, about 40% of your RAM). Sleep keeps working. Unticking turns hibernation back on.' -Warn 'Hibernate and Fast startup stop working, and a laptop can no longer hibernate when its battery runs low.')
$script:Tweaks += (New-Tweak -Id 'feat.lighting.off' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Turn off Windows Dynamic Lighting' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22631} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Lighting';name='AmbientLightingEnabled';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKCU:\Software\Microsoft\Lighting';name='AmbientLightingEnabled';value=1;type='DWord'}) -Info 'Stops Windows from controlling RGB keyboards, mice and light strips. Use it with iCUE, Armoury Crate, G HUB, SignalRGB or OpenRGB: when Windows and the vendor app both drive the same device, colors flicker or settings do not stick.' -Warn 'Device lighting can no longer be changed in Windows Settings; your RGB app keeps full control.')
$script:Tweaks += (New-Tweak -Id 'feat.taskbar.simple' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Hide Task View and show search as an icon' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22000} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='ShowTaskViewButton';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';name='SearchboxTaskbarMode';value=1;type='DWord'}) -Revert @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='ShowTaskViewButton';value=1;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';name='SearchboxTaskbarMode';value=2;type='DWord'}) -Info 'Removes the Task View button and shrinks the search box to an icon, leaving more room for pinned apps. Win+Tab and Win+S still open both.' -Warn 'Only changes how the taskbar looks.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.startdelay' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Remove the startup app delay' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize';name='StartupDelayInMSec';value=0;type='DWord'},@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize';name='WaitForIdleState';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize';name='StartupDelayInMSec'},@{kind='registryDel';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize';name='WaitForIdleState'}) -Warn 'Startup apps launch immediately instead of a few seconds after sign-in, so the desktop can feel busier and less responsive for the first moments after login.' -Info 'Removes the roughly 10-second delay Windows adds before launching startup apps, and stops Explorer waiting for the PC to go idle first. They open right away at sign-in. Best only once you have trimmed startup apps.')

$script:Tweaks += New-ServiceGroup -Id 'svc.xbox.manual' -Tab 'Tweaks' -SubTab 'Services' -Group 'Xbox and gaming' -Label 'Set Xbox Live services to on-demand (keeps Game Pass)' -Risk 'Moderate' -StartType 'Manual' -RevertType 'Manual' -Services @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc') -Info 'Sets the Xbox Live sign-in, cloud save, networking and accessory services to Manual instead of disabling them: they start when a Game Pass or Store game or the Xbox app needs them, and stay stopped the rest of the time. Use this instead of the "Stop Xbox Live and accessory services" row if you still play Xbox/Game Pass games.'

$script:Tweaks += (New-RegRow -Id 'feat.privacy.appperms' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Block Store apps from camera, location and voice activation' -Risk 'Moderate' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy','LetAppsAccessCamera',2),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy','LetAppsAccessLocation',2),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy','LetAppsActivateWithVoice',2),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy','LetAppsGetDiagnosticInfo',2)
) -Info 'Force-denies Microsoft Store (UWP) apps access to the camera, location, voice activation and other-app diagnostics by policy. Microphone access is left to you in Settings > Privacy. Desktop programs such as OBS, Zoom, Discord and browsers are NOT affected. Store apps like Windows Camera, the Xbox app or UWP Teams lose those permissions until reverted.')
$script:Tweaks[-1].Warn = 'Store (UWP) apps can no longer use the camera, location or voice activation; desktop apps are unaffected. Breaks UWP camera and voice apps until reverted.'

$script:Tweaks += (New-RegRow -Id 'feat.shell.fileext' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Show file name extensions' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    ,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','HideFileExt',0)
) -Info 'File Explorer shows extensions like .exe, .txt and .lnk, so you can tell a real document from a disguised program. Restart Explorer or sign out to apply.')
$script:Tweaks += (New-Tweak -Id 'feat.shell.hiddenfiles' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Show hidden files and folders' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Hidden';value=1;type='DWord'}) -Revert @(@{kind='registry';path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';name='Hidden';value=2;type='DWord'}) -Info 'File Explorer shows hidden files and folders (not protected operating-system files). Handy for cleanup and config files; clutters normal folders, so it is optional.')


$script:Tweaks += (New-RegRow -Id 'cpu.amd.x3dcache' -Tab 'CPU' -SubTab '' -Group 'AMD' -Label 'Prefer the 3D V-Cache CCD for every app (dual-CCD Ryzen X3D)' -Risk 'Moderate' -Recommend $false -Detect @{kind='anyPath';paths=@('HKLM:\SYSTEM\CurrentControlSet\Services\amd3dvcache')} -Values @('HKLM:\SYSTEM\CurrentControlSet\Services\amd3dvcache\Preferences','DefaultType',1) -Info 'Sets the AMD 3D V-Cache Performance Optimizer default (amd3dvcache DefaultType: 0 = frequency CCD, 1 = cache CCD). By default only games Game Bar recognises move to the V-Cache CCD, so missed games run without the extra cache. With cache preferred every app starts on the V-Cache CCD. Needs the AMD chipset driver and BIOS CPPC Dynamic Preferred Cores on Auto or Driver; applies within a few minutes or after a restart.')

$deskCP = 'HKCU:\Control Panel\Desktop'
$respApply = @(
    @{kind='registry';path=$deskCP;name='MenuShowDelay';value='0';type='String'},
    @{kind='registry';path=$deskCP;name='HungAppTimeout';value='2000';type='String'},
    @{kind='registry';path=$deskCP;name='WaitToKillAppTimeout';value='2000';type='String'},
    @{kind='registry';path=$deskCP;name='LowLevelHooksTimeout';value='1000';type='String'},
    @{kind='registry';path=$deskCP;name='AutoEndTasks';value='1';type='String'},
    @{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control';name='WaitToKillServiceTimeout';value='1500';type='String'}
)
$script:Tweaks += (New-Tweak -Id 'adv.resp.timers' -Tab 'Advanced' -SubTab '' -Group 'Responsiveness' -Label 'Faster shutdown and menu response' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply $respApply -Revert @($respApply | ForEach-Object { @{kind='registryDel';path=$_.path;name=$_.name} }) -Warn 'Lowers how long Windows waits for apps and services to close and auto-closes hung apps at shutdown; a slow-saving app or service can be ended before it finishes, so raise the values if you lose unsaved work.' -Info 'Instant menus (MenuShowDelay 0) and shorter close timers: HungAppTimeout 2000, WaitToKillAppTimeout 2000, LowLevelHooksTimeout 1000, WaitToKillServiceTimeout 1500, AutoEndTasks on. Sign out to apply. Unticking restores the Windows defaults.')

$fsCtl = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$script:Tweaks += (New-Tweak -Id 'storage.ntfs' -Tab 'Advanced' -SubTab '' -Group 'Storage' -Label 'NTFS: stop last-access timestamps and 8.3 short names' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path=$fsCtl;name='NtfsDisableLastAccessUpdate';value=1;type='DWord'},@{kind='registry';path=$fsCtl;name='NtfsDisable8dot3NameCreation';value=1;type='DWord'}) -Revert @(@{kind='registryDel';path=$fsCtl;name='NtfsDisableLastAccessUpdate'},@{kind='registry';path=$fsCtl;name='NtfsDisable8dot3NameCreation';value=2;type='DWord'}) -Warn 'Turning off 8.3 short-name creation can break very old 16-bit or legacy installers that depend on short paths; last-access timestamps stop updating, which a few backup tools use.' -Info 'Stops NTFS writing a last-access time on every file read and creating MS-DOS 8.3 short names, cutting small metadata writes. Applies to new files; existing short names stay. Restart to apply.')

$smKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

$script:Tweaks += (New-Tweak -Id 'updates.reserved' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label 'Turn off Reserved Storage (free ~7 GB)' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager';name='ShippedWithReserves'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager';name='ShippedWithReserves';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager';name='ShippedWithReserves';value=1;type='DWord'}) -Warn 'Frees about 7 GB, but feature updates then rely on your own free space and can fail or go slower when the disk is nearly full.' -Info 'Reserved Storage sets aside disk space so updates always have room. Turning it off reclaims roughly 7 GB. It takes effect after the next feature update or a DISM /Online /Set-ReservedStorageState /State:Disabled; unticking re-enables it.')

$script:Tweaks += (New-Tweak -Id 'adv.crash.noreboot' -Tab 'Advanced' -SubTab '' -Group 'Crash and logging' -Label 'Keep blue screens visible (no auto-restart)' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl';name='AutoReboot'} -Apply @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl';name='AutoReboot';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl';name='AutoReboot';value=1;type='DWord'}) -Warn 'After a blue screen the PC stays on the error screen until you restart it by hand, so an unattended machine will not come back on its own.' -Info 'Stops Windows from instantly rebooting on a bugcheck so you can read the stop code and QR. Useful for diagnosing crashes. Unticking restores auto-restart.')

$script:Tweaks += (New-Tweak -Id 'feat.audio.ducking' -Tab 'Tweaks' -SubTab 'Features' -Group 'Background and power' -Label 'Stop audio ducking during calls' -Risk 'Safe' -Recommend $true -Detect @{kind='registry';path='HKCU:\Software\Microsoft\Multimedia\Audio';name='UserDuckingPreference'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\Multimedia\Audio';name='UserDuckingPreference';value=3;type='DWord'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\Multimedia\Audio';name='UserDuckingPreference'}) -Info 'Sets the Sound control panel Communications option to Do nothing, so Windows stops lowering game or music volume when it thinks a call started.')

$envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:Tweaks += (New-Tweak -Id 'feat.privacy.envtel' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Opt out of .NET and PowerShell telemetry' -Risk 'Safe' -Recommend $true -Detect @{kind='registry';path=$envKey;name='DOTNET_CLI_TELEMETRY_OPTOUT'} -Apply @(@{kind='registry';path=$envKey;name='DOTNET_CLI_TELEMETRY_OPTOUT';value='1';type='String'},@{kind='registry';path=$envKey;name='POWERSHELL_TELEMETRY_OPTOUT';value='1';type='String'}) -Revert @(@{kind='registryDel';path=$envKey;name='DOTNET_CLI_TELEMETRY_OPTOUT'},@{kind='registryDel';path=$envKey;name='POWERSHELL_TELEMETRY_OPTOUT'}) -Info 'Sets the system environment variables that turn off usage telemetry in the .NET CLI and PowerShell Core. Takes effect for new sessions after sign-out.')

$mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

$script:Tweaks += (New-Tweak -Id 'gpu.explorerperf' -Tab 'GPU' -SubTab '' -Group 'Windows' -Label 'Run File Explorer on the high-performance GPU (multi-GPU)' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences';name='C:\Windows\explorer.exe';value='GpuPreference=2;';type='String'}) -Revert @(@{kind='registryDel';path='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences';name='C:\Windows\explorer.exe'}) -Warn 'On a laptop this can keep the dedicated GPU awake for File Explorer, using more power and battery; only useful on multi-GPU systems.' -Info 'Assigns File Explorer to the high-performance GPU in the Windows graphics preferences. No effect on single-GPU desktops.')

$script:Tweaks += (New-Tweak -Id 'feat.shell.classicmenu' -Tab 'Tweaks' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Use the classic right-click context menu (Windows 11)' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='classicMenu';enable=$true}) -Revert @(@{kind='classicMenu';enable=$false}) -Info 'Restores the full Windows 10-style right-click menu instead of the trimmed Windows 11 one, so you do not have to click Show more options. File Explorer restarts to apply.')

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$ifeoApply = @(
    @{kind='registry';path="$ifeo\SearchIndexer.exe\PerfOptions";name='CpuPriorityClass';value=5;type='DWord'},
    @{kind='registry';path="$ifeo\SearchProtocolHost.exe\PerfOptions";name='CpuPriorityClass';value=5;type='DWord'},
    @{kind='registry';path="$ifeo\SearchFilterHost.exe\PerfOptions";name='CpuPriorityClass';value=5;type='DWord'}
)


$script:Tweaks += (New-Tweak -Id 'cpu.ppm.maxfreq' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Uncap maximum processor state and frequency (plugged in)' -Risk 'Moderate' -Recommend $false -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='bc5038f7-23e0-4960-96da-33abaf5935ec';desktopOnly=$true} -Apply @(
    (New-PpmAction 'bc5038f7-23e0-4960-96da-33abaf5935ec' 100 'Maximum processor state'),
    (New-PpmAction 'bc5038f7-23e0-4960-96da-33abaf5935ed' 100 'Maximum processor state (E-cores)'),
    (New-PpmAction '75b0ae3f-bce0-45a7-8c89-c9611c25e100' 0 'Maximum processor frequency (no cap)'),
    (New-PpmAction '75b0ae3f-bce0-45a7-8c89-c9611c25e101' 0 'Maximum processor frequency (E-cores, no cap)')
) -Revert @() -Info 'Makes sure the CPU is allowed to reach 100 percent state with no artificial frequency cap, plugged in only. Normally already the case, but some OEM or third-party plans quietly cap it. Desktop only; unticking restores the previous values.')
$script:Tweaks += (New-Tweak -Id 'cpu.ppm.idledepth' -Tab 'CPU' -SubTab '' -Group 'Power plan settings' -Label 'Keep cores in shallow idle for lower wake latency (plugged in)' -Risk 'Moderate' -Recommend $false -Detect @{kind='powerSettingPresent';sub=$ppmSub;setting='7b224883-b3cc-4d79-819f-8374152cbe7c';desktopOnly=$true;notAmdCpu=$true} -Apply @(
    (New-PpmAction '6c2993b0-8f48-481f-bcc6-00dd2742aa06' 0 'Idle threshold scaling (off)'),
    (New-PpmAction '7b224883-b3cc-4d79-819f-8374152cbe7c' 100 'Idle promote threshold'),
    (New-PpmAction '4b92d758-5a24-4851-a470-815d78aee119' 20 'Idle demote threshold')
) -Warn 'Cores sit in lighter power-saving states, so they wake faster but idle power, heat and fan noise rise. A softer version of disabling idle states; measure whether it actually helps your games.' -Info 'Raises the bar for entering deep C-states so cores stay in shallow idle and respond faster, without fully disabling idle states. Plugged in only, desktop only. Unticking restores the previous values.')

$discordPerf = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Discord.exe\PerfOptions'
$script:Tweaks += (New-Tweak -Id 'app.discord.priority' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Discord' -Label 'Lower Discord CPU priority to Below Normal' -Risk 'Moderate' -Recommend $false -Detect @{kind='appInstalled';name='Discord'} -Apply @(@{kind='registry';path=$discordPerf;name='CpuPriorityClass';value=5;type='DWord'}) -Revert @(@{kind='registryDel';path=$discordPerf;name='CpuPriorityClass'}) -Warn 'Discord runs at Below Normal CPU priority so games get the CPU first; Discord itself can feel a touch slower (voice stays fine). Stored via Image File Execution Options and applies the next time Discord starts.' -Info 'Uses Image File Execution Options to run Discord.exe at Below Normal CPU priority, keeping it out of the way of games. Restart Discord to apply. Unticking removes the override.')
$script:Tweaks += New-ServiceGroup -Id 'svc.gpu.amd.extevents' -Tab 'Tweaks' -SubTab 'Services' -Group 'GPU software' -Label 'Stop AMD External Events Utility' -Risk 'Moderate' -RevertType 'Automatic' -Services @('AMD External Events Utility','AMDExternalEventsUtility','atiesrxx') -Info 'AMD External Events Utility (atiesrxx) handles display and power events, Adrenalin hotkeys and the in-game overlay. Stopping it can disable brightness/overlay hotkeys and some event-driven features; the display driver itself keeps working. Only shows on AMD systems.'

$mouseKey = 'HKCU:\Control Panel\Mouse'
$script:Tweaks += (New-Tweak -Id 'input.usb.power' -Tab 'Advanced' -SubTab '' -Group 'Input devices' -Label 'Stop Windows turning off USB and input devices to save power' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='usbPower';enable=$false}) -Revert @(@{kind='usbPower';enable=$true}) -Warn 'Keeps USB, network and input devices powered so they do not drop out (mouse stutter, audio pops, controller disconnects), but uses more power and shortens laptop battery life; re-plugging a device can re-enable its power saving.' -Info 'Clears the "Allow the computer to turn off this device to save power" option on every device that exposes it, using the MSPower_DeviceEnable WMI class. Best on a desktop. Unticking turns device power management back on.')

$diskSub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; $diskIdle = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
$script:Tweaks += (New-Tweak -Id 'pwr.disk.never' -Tab 'Advanced' -SubTab '' -Group 'Power and adapters' -Label 'Never spin down drives when plugged in' -Risk 'Moderate' -Recommend $false -Detect @{kind='powerSettingPresent';sub=$diskSub;setting=$diskIdle;desktopOnly=$true} -Apply @(@{kind='powerSetting';sub=$diskSub;setting=$diskIdle;value=0;label='Turn off hard disk after';acOnly=$true}) -Revert @(@{kind='powerSetting';sub=$diskSub;setting=$diskIdle;value='Default';label='Turn off hard disk after'}) -Warn 'Drives stay powered, so there is no wake-up stall when a sleeping disk is accessed, but idle power use is slightly higher. SSDs are unaffected; this matters for mechanical drives.' -Info 'Sets "Turn off hard disk after" to Never while plugged in, removing the pause when Windows wakes a parked mechanical drive. Desktop only; unticking restores the plan default.')
$script:Tweaks += (New-Tweak -Id 'storage.storagesense' -Tab 'Advanced' -SubTab '' -Group 'Storage' -Label 'Turn off automatic Storage Sense cleanup' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense';name='AllowStorageSenseGlobal';value=0;type='DWord'}) -Revert @(@{kind='registryDel';path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense';name='AllowStorageSenseGlobal'}) -Info 'Stops Storage Sense from automatically deleting temp files and emptying the Recycle Bin on a schedule. Use the Fixes tab cleanup when you want to clean up instead. Unticking restores Windows control.')
$script:Tweaks += (New-Tweak -Id 'svc.feat.ucpd' -Tab 'Tweaks' -SubTab 'Services' -Group 'Accounts and sign-in' -Label 'Allow changing default apps and browser (disable UCPD)' -Risk 'Moderate' -Recommend $false -Detect @{kind='service';name='UCPD'} -Apply @(@{kind='service';name='UCPD';start='Disabled'},@{kind='taskNamePattern';patterns=@('UCPD velocity')}) -Revert @(@{kind='service';name='UCPD';start='Automatic'},@{kind='taskNamePattern';patterns=@('UCPD velocity');enable=$true}) -Warn 'Removes the protection that stops programs from silently hijacking your default browser and file associations.' -Info 'Disables the UserChoice Protection Driver (UCPD) and its re-enable task so you can script default-app and default-browser changes. Restart to apply. Unticking restores it.')
$script:Tweaks += (New-Tweak -Id 'priv.firewall.telemetry' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Block telemetry with firewall rules (optional)' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Apply @(@{kind='firewallBlock';enable=$true;services=@('DiagTrack');programs=@("$env:SystemRoot\System32\CompatTelRunner.exe","$env:SystemRoot\System32\DeviceCensus.exe")}) -Revert @(@{kind='firewallBlock';enable=$false}) -Warn 'Adds outbound Windows Firewall block rules for the telemetry service and its collectors; low risk, but it is an extra layer on top of turning the telemetry service off and is removed cleanly when unticked.' -Info 'Creates outbound-block firewall rules (group "RionTool Telemetry Block") for the Connected User Experiences and Telemetry service (DiagTrack) and the CompatTelRunner / DeviceCensus collectors. Defence-in-depth alongside the telemetry service and task disables. Unticking removes the rules.')
$telemetryHosts = @('vortex.data.microsoft.com','vortex-win.data.microsoft.com','telecommand.telemetry.microsoft.com','watson.telemetry.microsoft.com','watson.ppe.telemetry.microsoft.com','v10.events.data.microsoft.com','v20.events.data.microsoft.com','self.events.data.microsoft.com','us-v10.events.data.microsoft.com','eu-v10.events.data.microsoft.com')

$advKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:Tweaks += (New-RegRow -Id 'feat.explorer.thispc' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Open File Explorer to This PC' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @($advKey,'LaunchTo',1)
) -Info 'File Explorer opens on This PC (drives and folders) instead of Home with recent and cloud files. Unticking returns to Home.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.fullpath' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Show the full folder path in the File Explorer title' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState','FullPath',1)
) -Info 'Shows the complete path of the open folder in the window title and taskbar preview. Takes effect in new Explorer windows.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.foldertype' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Stop automatic folder type discovery' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell','FolderType','NotSpecified','String')
) -Info 'Explorer stops scanning folder contents to guess a Pictures/Music/Videos view, which makes large folders open faster and keeps the same column layout everywhere. Sign out or restart Explorer to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.visual.transparency' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Turn off transparency effects' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize','EnableTransparency',0)
) -Info 'Same as Settings > Personalization > Colors > Transparency effects off. Removes the blurred acrylic/mica behind Start, the taskbar and windows, which costs a little GPU time on low-end and integrated graphics. Unticking turns it back on.')
$script:Tweaks += (New-RegRow -Id 'feat.visual.taskbaranim' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Turn off taskbar animations' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Values @(
    @($advKey,'TaskbarAnimations',0)
) -Info 'Taskbar buttons and thumbnails appear instantly instead of sliding and fading. Purely visual; sign out to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.signin.firstanim' -SubTab 'Features' -Group 'Sign-in and startup' -Label 'Skip the first sign-in animation for new accounts' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @($sysPol,'EnableFirstLogonAnimation',0)
) -Info 'New user accounts go straight to the desktop instead of the "Hi / We are getting things ready" animation. Existing accounts are not affected.')
$script:Tweaks += (New-RegRow -Id 'feat.signin.arso' -SubTab 'Features' -Group 'Sign-in and startup' -Label 'Do not auto sign in to finish updates after a restart' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @($sysPol,'DisableAutomaticRestartSignOn',1)
) -Info 'Turns off Automatic Restart Sign-On (ARSO): after an update restart Windows waits at the sign-in screen instead of signing you in with stored credentials to finish setup and relaunch apps. Better for privacy on shared PCs; update setup finishes after you sign in.')
$script:Tweaks += (New-RegRow -Id 'feat.signin.verbose' -SubTab 'Features' -Group 'Sign-in and startup' -Label 'Show detailed status messages at startup and shutdown' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Values @(
    @($sysPol,'VerboseStatus',1)
) -Info 'Shows what Windows is doing ("Applying computer settings", "Stopping services") instead of only "Please wait", which helps find slow startup or shutdown steps.')
$autoLog = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
$script:Tweaks += (New-Tweak -Id 'priv.autologger.telemetry' -Tab 'Tweaks' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Stop the telemetry trace loggers that start at boot' -Risk 'Safe' -Detect @{kind='registry'} -Apply @(
    @{kind='registry';path="$autoLog\AutoLogger-Diagtrack-Listener";name='Start';value=0;type='DWord'},
    @{kind='registry';path="$autoLog\SQMLogger";name='Start';value=0;type='DWord'}
) -Revert @(
    @{kind='registry';path="$autoLog\AutoLogger-Diagtrack-Listener";name='Start';value=1;type='DWord'},
    @{kind='registry';path="$autoLog\SQMLogger";name='Start';value=1;type='DWord'}
) -Info 'Stops the Diagtrack-Listener and SQMLogger event trace sessions that Windows starts at boot to buffer telemetry for the Connected User Experiences service. Restart to apply; unticking sets them back to start at boot.')
$script:Tweaks += (New-RegRow -Id 'adv.wpbt' -Tab 'Advanced' -SubTab '' -Group 'Security' -Label 'Block firmware-injected programs (WPBT)' -Risk 'Moderate' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager','DisableWpbtExecution',1)
) -Info 'The Windows Platform Binary Table lets a motherboard or laptop BIOS drop a program into Windows at every boot; this is how ASUS Armoury Crate, Lenovo and some OEM updaters reinstall themselves after being removed. Setting DisableWpbtExecution stops Windows from running it. Drivers and normal installers are unaffected. Unticking allows it again.')
($script:Tweaks | Where-Object { $_.Id -eq 'adv.wpbt' }).Warn = 'OEM tools that the BIOS installs on every boot (Armoury Crate, vendor updaters) stop coming back; install them manually if you want them.'
$script:Tweaks += (New-Tweak -Id 'sec.remoteassist' -Tab 'Security' -SubTab '' -Group 'Remote access' -Label 'Turn off Remote Assistance' -Risk 'Safe' -Detect @{kind='registry'} -Apply @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance';name='fAllowToGetHelp';value=0;type='DWord'},@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance';name='fAllowFullControl';value=0;type='DWord'}) -Revert @(@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance';name='fAllowToGetHelp';value=1;type='DWord'},@{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance';name='fAllowFullControl';value=1;type='DWord'}) -Info 'Closes the old Remote Assistance feature (System Properties > Remote), which is allowed by default and lets an invited helper view and control the PC. Quick Assist and Remote Desktop are separate and keep working.' -Warn 'Remote Assistance invitations (msra.exe) from a helper stop working.')
$script:Tweaks += (New-RegRow -Id 'sec.wu.nodrivers' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label 'Do not install drivers through Windows Update' -Risk 'Moderate' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','ExcludeWUDriversInQualityUpdate',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata','PreventDeviceMetadataFromNetwork',1)
) -Info 'Windows Update stops replacing your GPU, chipset and audio drivers with older generic ones, plugging in a new device no longer pulls a driver from Windows Update, and Device Manager stops downloading device icons and info. Security and feature updates still install, and NVIDIA, AMD, Intel and chipset installers work normally. Unticking lets Windows Update offer drivers again.')
$wuNd = $script:Tweaks | Where-Object { $_.Id -eq 'sec.wu.nodrivers' }
$wuNd.Apply = @($wuNd.Apply) + @(@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching';name='SearchOrderConfig';value=0;type='DWord'})
$wuNd.Revert = @($wuNd.Revert) + @(@{kind='registry';path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching';name='SearchOrderConfig';value=1;type='DWord'})
($script:Tweaks | Where-Object { $_.Id -eq 'sec.wu.nodrivers' }).Warn = 'You have to install and update GPU, chipset, Wi-Fi and other drivers yourself from the maker.'
$kbKey = 'HKCU:\Control Panel\Keyboard'
$script:Tweaks += (New-Tweak -Id 'adv.input.keyrepeat' -Tab 'Advanced' -SubTab '' -Group 'Input devices' -Label 'Fastest keyboard repeat delay and rate' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(
    @{kind='registry';path=$kbKey;name='KeyboardDelay';value='0';type='String'},
    @{kind='registry';path=$kbKey;name='KeyboardSpeed';value='31';type='String'}
) -Revert @(
    @{kind='registry';path=$kbKey;name='KeyboardDelay';value='1';type='String'},
    @{kind='registry';path=$kbKey;name='KeyboardSpeed';value='31';type='String'}
) -Info 'Sets the shortest delay before a held key starts repeating and the fastest repeat rate (Control Panel > Keyboard). Makes held movement or menu keys respond sooner; it does not change input latency of single presses. Sign out to apply; unticking restores the Windows defaults.')

$gcs = 'HKCU:\System\GameConfigStore'
$script:Tweaks += (New-RegRow -Id 'feat.gaming.bgrecord' -SubTab 'Features' -Group 'Gaming' -Label 'Turn off Game Bar background recording (record what happened)' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR','AppCaptureEnabled',0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR','AudioCaptureEnabled',0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR','CursorCaptureEnabled',0),
    @($gcs,'GameDVR_Enabled',0)
) -Info 'Same as Settings > Gaming > Captures with background recording off. While it is on, Windows keeps a hardware video-encoder session and a rolling buffer running during games, which costs GPU encoder time and memory. Game Bar itself, screenshots and manual recording keep working.')
$script:Tweaks += (New-RegRow -Id 'priv.appcompat' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Turn off Program Compatibility Assistant, inventory and Steps Recorder' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat','DisablePCA',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat','DisableInventory',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat','DisableUAR',1)
) -Info 'AppCompat policies: the Program Compatibility Assistant stops watching program launches and offering "this program might not have installed correctly", the Inventory Collector stops sending app and driver inventory, and Steps Recorder is disabled. DisableEngine is deliberately NOT set, because the application compatibility engine applies the shims that old installers and games need.')
$script:Tweaks += (New-RegRow -Id 'priv.wer.extra' -SubTab 'Features' -Group 'Telemetry and feedback' -Label 'Do not send extra data with error reports (crash dumps kept)' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting','DontSendAdditionalData',1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting','AutoApproveOSDumps',0)
) -Info 'Windows Error Reporting stops attaching extra files and memory data to reports and no longer auto-approves sending OS crash dumps. Unlike disabling WER entirely (which stops minidumps), local crash dumps and Reliability Monitor keep working, so blue screens can still be diagnosed.')
$script:Tweaks += (New-RegRow -Id 'adv.crash.details' -Tab 'Advanced' -SubTab '' -Group 'Crash and logging' -Label 'Show technical details on blue screens' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl','DisplayParameters',1)
) -Info 'The blue screen shows the stop code parameters and the driver name instead of only a QR code, so you can see which driver crashed without opening the dump. Restart to apply.')
$script:Tweaks += (New-Tweak -Id 'adv.sleepstudy' -Tab 'Advanced' -SubTab '' -Group 'Crash and logging' -Label 'Turn off Sleep Study and power diagnostics logging' -Risk 'Safe' -Recommend $false -Detect @{kind='taskAnyName';names=@('AnalyzeSystem');desktopOnly=$true} -Apply @(
    @{kind='eventLog';names=@('Microsoft-Windows-SleepStudy/Diagnostic','Microsoft-Windows-Kernel-Processor-Power/Diagnostic','Microsoft-Windows-UserModePowerService/Diagnostic');enable=$false},
    @{kind='task';path='\Microsoft\Windows\Power Efficiency Diagnostics\';name='AnalyzeSystem';enable=$false},
    @{kind='registry';path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power';name='SleepStudyDisabled';value=1;type='DWord'}
) -Revert @(
    @{kind='registryDel';path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power';name='SleepStudyDisabled'},
    @{kind='eventLog';names=@('Microsoft-Windows-SleepStudy/Diagnostic','Microsoft-Windows-Kernel-Processor-Power/Diagnostic','Microsoft-Windows-UserModePowerService/Diagnostic');enable=$true},
    @{kind='task';path='\Microsoft\Windows\Power Efficiency Diagnostics\';name='AnalyzeSystem';enable=$true}
) -Info 'Stops the three diagnostic event logs that record every idle and power-state change for Sleep Study, and the Power Efficiency Diagnostics task that analyses them. On a desktop this removes constant background logging; powercfg /sleepstudy and the battery report lose that history. Desktop only.')
$script:Tweaks += (New-RegRow -Id 'app.store.archiving' -SubTab 'Apps' -Group 'Microsoft Store' -Label 'Stop Windows from archiving Store apps you rarely use' -Risk 'Safe' -Detect @{kind='registry';minBuild=22000} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx','AllowAutomaticAppArchiving',0)
) -Info 'Windows 11 removes the program files of Store apps you have not opened for a while (keeping your data) and downloads them again the next time you start them, which breaks offline use and makes the first launch slow. This policy keeps them installed.')
$script:Tweaks += (New-RegRow -Id 'feat.maint.wake' -SubTab 'Features' -Group 'Background and power' -Label 'Do not wake the PC for automatic maintenance' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Task Scheduler\Maintenance','WakeUp',0)
) -Info 'Stops Windows from waking a sleeping PC in the night to run automatic maintenance (defrag/TRIM, updates, diagnostics). Maintenance still runs while the PC is on and idle, so TRIM and updates are not lost.')
$script:Tweaks += (New-RegRow -Id 'net.smb.throttle' -Tab 'Networking' -SubTab '' -Group 'File sharing (SMB)' -Label 'Turn off SMB client bandwidth throttling' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters','DisableBandwidthThrottling',1)
) -Info 'Microsoft''s SMB performance tuning guidance: the SMB client otherwise throttles large file transfers on high-latency or slow-looking links. Turning the throttle off speeds up copies to and from a NAS or another PC over the network. Has no effect on games or internet traffic.')
$script:Tweaks += (New-RegRow -Id 'storage.longpaths' -Tab 'Advanced' -SubTab '' -Group 'Storage' -Label 'Allow file paths longer than 260 characters' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem','LongPathsEnabled',1)
) -Info 'Lets apps that support long paths (PowerShell 7, Git, Python, Node, modern installers, many game mod tools) work with deep folders instead of failing with "path too long". Explorer itself still has some limits.')
$kbHkcu = 'HKCU:\Control Panel\Keyboard'
$kbLogon = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'
$script:Tweaks += (New-Tweak -Id 'adv.input.numlock' -Tab 'Advanced' -SubTab '' -Group 'Input devices' -Label 'Turn on Num Lock at startup and on the sign-in screen' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(
    @{kind='registry';path=$kbHkcu;name='InitialKeyboardIndicators';value='2';type='String'},
    @{kind='registry';path=$kbLogon;name='InitialKeyboardIndicators';value='2';type='String'}
) -Revert @(
    @{kind='registry';path=$kbHkcu;name='InitialKeyboardIndicators';value='0';type='String'},
    @{kind='registry';path=$kbLogon;name='InitialKeyboardIndicators';value='2147483648';type='String'}
) -Info 'Num Lock starts on, so a PIN typed on the number pad works on the sign-in screen. Fast Startup can keep the previous state until a full restart.')
$script:Tweaks += (New-RegRow -Id 'feat.taskbar.endtask' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Add "End task" to the taskbar right-click menu' -Risk 'Safe' -Detect @{kind='registry';minBuild=22631} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings','TaskbarEndTask',1)
) -Info 'Windows 11 23H2+ developer option (Settings > System > For developers > End task): right-clicking a taskbar app shows End task, which kills a frozen game or app instantly without opening Task Manager.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.separate' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Open folder windows in a separate process' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','SeparateProcess',1)
) -Info 'File Explorer windows run in their own explorer.exe process, so a folder that hangs on a network drive or a bad shell extension no longer freezes or crashes the taskbar and Start. Costs roughly 20-40 MB of extra RAM. Sign out to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.visual.jpegquality' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Keep JPEG wallpapers at full quality' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKCU:\Control Panel\Desktop','JPEGImportQuality',100)
) -Info 'Windows re-encodes JPEG wallpapers at about 85 percent quality, which adds visible banding and blocks. 100 keeps them as they are. Re-apply the wallpaper after ticking.')
$script:Tweaks += (New-RegRow -Id 'adv.registry.backup' -Tab 'Advanced' -SubTab '' -Group 'Crash and logging' -Label 'Turn automatic registry backups back on (RegBack)' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager','EnablePeriodicBackup',1)
) -Info 'Since Windows 10 1803 the RegIdleBackup maintenance task no longer copies the registry hives to System32\config\RegBack, so a corrupted registry cannot be restored from them. This brings the copies back (about 100 MB). Needs automatic maintenance to stay on.')
$thumbKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache')
$script:Tweaks += (New-Tweak -Id 'storage.thumbcache' -Tab 'Advanced' -SubTab '' -Group 'Storage' -Label 'Stop automatic maintenance from deleting the thumbnail cache' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Apply @(
    $thumbKeys | ForEach-Object { @{kind='registry';path=$_;name='Autorun';value=0;type='DWord'} }
) -Revert @(
    $thumbKeys | ForEach-Object { @{kind='registry';path=$_;name='Autorun';value=3;type='DWord'} }
) -Info 'Windows maintenance regularly wipes the Explorer thumbnail cache, so folders of photos, videos and game screenshots regenerate every thumbnail again (slow on hard drives and large libraries). Disk Cleanup can still clear it manually. Unticking restores the Windows default (3).')
$script:Tweaks += (New-RegRow -Id 'sec.lsa.ppl' -Tab 'Security' -SubTab '' -Group 'Hardening' -Label 'Turn on LSA protection (credential theft hardening)' -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Values @(
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Lsa','RunAsPPL',2),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Lsa','RunAsPPLBoot',2)
) -Info 'Runs lsass.exe as a protected process so malware cannot read saved passwords and tokens from its memory (Microsoft "Configure added LSA protection"). Value 2 is the variant without a UEFI lock, so it can be turned off again by unticking. Restart to apply; Windows Security > Device security shows it as Local Security Authority protection.')
($script:Tweaks | Where-Object { $_.Id -eq 'sec.lsa.ppl' }).Warn = 'Old unsigned password filters, smart-card or biometric plug-ins that load into LSA stop working; check Event Viewer (CodeIntegrity 3065/3066) after restarting.'
$defEnv = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:Tweaks += (New-RegRow -Id 'sec.def.sandbox' -Tab 'Security' -SubTab '' -Group 'Defender' -Label 'Run Microsoft Defender inside its sandbox' -Risk 'Safe' -Recommend $false -Detect @{kind='registry'} -Values @(
    @($defEnv,'MP_FORCE_USE_SANDBOX','1','String')
) -Info 'Windows switch that makes Defender parse files inside a low-privilege sandbox process, so an exploit in the scanner itself cannot take over the system. Adds a little memory use. Restart to apply; ignored when another antivirus is active.')
$script:Tweaks += (New-Tweak -Id 'sec.def.pua' -Tab 'Security' -SubTab '' -Group 'Defender' -Label 'Block potentially unwanted apps (PUA protection)' -Risk 'Safe' -Recommend $false -Detect @{kind='mpPreference'} -Apply @(
    @{kind='mpPreference';name='PUAProtection';value=1}
) -Revert @(
    @{kind='mpPreference';name='PUAProtection';value=0}
) -Info 'Defender blocks adware, bundleware installers, browser hijackers and similar unwanted software when they download or install (Set-MpPreference -PUAProtection Enabled). Only available while Microsoft Defender is the active antivirus.')
$script:Tweaks += (New-Tweak -Id 'sec.def.netprot' -Tab 'Security' -SubTab '' -Group 'Defender' -Label 'Turn on Defender network protection' -Risk 'Moderate' -Recommend $false -Detect @{kind='mpPreference'} -Apply @(
    @{kind='mpPreference';name='EnableNetworkProtection';value=1}
) -Revert @(
    @{kind='mpPreference';name='EnableNetworkProtection';value=0}
) -Info 'Extends SmartScreen-style blocking of phishing, scam and malware domains to every app, not just Edge (Set-MpPreference -EnableNetworkProtection Enabled). Only available while Microsoft Defender is the active antivirus.')
($script:Tweaks | Where-Object { $_.Id -eq 'sec.def.netprot' }).Warn = 'A misclassified site or game server is blocked for every app until you allow it in Windows Security; some VPN and proxy tools conflict with it.'
$expPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
$script:Tweaks += (New-RegRow -Id 'feat.start.recommended' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Remove the Recommended section from Start' -Risk 'Safe' -Detect @{kind='registry';minBuild=22000} -Values @(
    @($expPol,'HideRecommendedSection',1),
    @('HKCU:\Software\Policies\Microsoft\Windows\Explorer','HideRecommendedSection',1)
) -Info 'Start no longer shows the Recommended area with recent files, newly installed apps and promoted apps, leaving only pinned and All apps. The policy is honoured on Pro, Enterprise and Education; Home editions may ignore it. Sign out to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.start.phonelink' -SubTab 'Features' -Group 'Start, taskbar and search' -Label 'Remove the Phone Link panel from Start' -Risk 'Safe' -Detect @{kind='registry';minBuild=22621} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe','IsEnabled',0)
) -Info 'Turns off the mobile device companion panel that newer Windows 11 builds add beside Start (phone battery, messages, photos). Phone Link itself keeps working when opened.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.aiactions' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Hide AI actions in the File Explorer right-click menu' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @($expPol,'HideAIActionsMenu',1)
) -Info 'Removes the AI actions submenu (visual search, blur background, erase objects, summarize) that newer builds add to the right-click menu of images and documents. Restart Explorer to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.share.dragtray' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Turn off the drag-to-share tray' -Risk 'Safe' -Detect @{kind='registry';minBuild=26200} -Values @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP','DragTrayEnabled',0)
) -Info 'Windows 11 25H2 slides a share tray (Phone Link, mail, apps) down from the top of the screen whenever you drag a file. This stops it, so dragging files between windows works without the popup.')
$script:Tweaks += (New-RegRow -Id 'feat.settings.m365ads' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Hide Microsoft 365 and account promotions in Settings' -Risk 'Safe' -Detect @{kind='registry';minBuild=22000} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableConsumerAccountStateContent',1)
) -Info 'Removes the Microsoft 365, Copilot, OneDrive storage and Game Pass cards that Settings Home and the Accounts page show based on your Microsoft account.')
$script:Tweaks += (New-RegRow -Id 'feat.settings.home' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Hide the Settings Home page' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22000} -Values @(
    @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer','SettingsPageVisibility','hide:home','String')
) -Info 'Settings opens on System instead of the Home page with its recommended settings and account and subscription cards. If an administrator already hides other Settings pages with this value, it is replaced; unticking restores the previous value.')
$osCv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$osDisplay = [string]$osCv.DisplayVersion
if ($osDisplay -match '^\d\dH\d$' -and [string]$osCv.EditionID -notmatch '^Core') {
    $osProduct = if ([int]$osCv.CurrentBuild -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $script:Tweaks += (New-RegRow -Id 'sec.wu.pinversion' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label ('Stay on {0} {1} (block feature upgrades)' -f $osProduct,$osDisplay) -Risk 'Moderate' -Recommend $false -Detect @{kind='registry'} -Values @(
        @($wuPol,'TargetReleaseVersion',1), @($wuPol,'ProductVersion',$osProduct,'String'), @($wuPol,'TargetReleaseVersionInfo',$osDisplay,'String')
    ) -Info ('Sets the Windows Update for Business target version policy (TargetReleaseVersion with ProductVersion and TargetReleaseVersionInfo) to the version installed now, {0} {1}. Monthly security and quality updates keep coming, but Windows does not upgrade to the next yearly version, which is where most new built-in apps, AI features and changed defaults arrive. Pro, Education and Enterprise only. Untick before this version reaches end of servicing, or Windows stops getting security updates. Unticking removes the pin.' -f $osProduct,$osDisplay))
}
$script:Tweaks += (New-RegRow -Id 'sec.wu.asap' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label 'Do not get optional feature updates as soon as they are available' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings','IsContinuousInnovationOptedIn',0)
) -Info 'Turns off "Get the latest updates as soon as they are available" (Settings > Windows Update), so new features that Microsoft enables gradually (often new AI, Copilot and app promotions) wait for the regular monthly release. Security updates are not delayed.')
$script:Tweaks += (New-RegRow -Id 'sec.wu.noreboot' -Tab 'Security' -SubTab '' -Group 'Windows Update' -Label 'Never restart automatically for updates while someone is signed in' -Risk 'Safe' -Detect @{kind='registry'} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU','NoAutoRebootWithLoggedOnUsers',1)
) -Info 'Windows waits for you to restart instead of rebooting in the middle of a game, download or render when updates are installed. Updates still install; restart when it suits you so they finish.')
$chromePol = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$script:Tweaks += (New-RegRow -Id 'app.chrome.ai' -SubTab 'Apps' -Group 'Browsers' -Label 'Chrome: turn off Gemini and AI features' -Risk 'Safe' -Detect @{kind='anyPath';paths=$script:BrowserPaths.Chrome} -Values @(
    @($chromePol,'GeminiSettings',1),
    @($chromePol,'AIModeSettings',1),
    @($chromePol,'GeminiSparkSettings',1),
    @($chromePol,'GenAILocalFoundationalModelSettings',1),
    @($chromePol,'HelpMeWriteSettings',2),
    @($chromePol,'HistorySearchSettings',2),
    @($chromePol,'TabCompareSettings',2),
    @($chromePol,'CreateThemesSettings',2),
    @($chromePol,'DevToolsGenAiSettings',2),
    @($chromePol,'AutofillPredictionSettings',2),
    @($chromePol,'FindAndFillWithGeminiSettings',2),
    @($chromePol,'VoiceTypingSettings',2),
    @($chromePol,'ThirdPartyAiChatSettings',1),
    @($chromePol,'SearchContentSharingSettings',1),
    @($chromePol,'SmartTabSharingSettings',1),
    @($chromePol,'ChromeSuggestionsSettings',1)
) -Info 'Chrome enterprise policies that switch off Gemini in Chrome, AI Mode in the address bar, Help me write, AI history search, tab compare, AI themes, DevTools AI, AI autofill and the on-device model download (several GB). Chrome shows "Managed by your organization" while these are set.')
$bravePol = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$script:Tweaks += (New-RegRow -Id 'app.brave.bloat' -SubTab 'Apps' -Group 'Browsers' -Label 'Brave: turn off Leo AI, crypto wallet, VPN, Rewards, News and Talk' -Risk 'Safe' -Detect @{kind='anyPath';paths=$script:BrowserPaths.Brave} -Values @(
    @($bravePol,'BraveAIChatEnabled',0),
    @($bravePol,'BraveWalletDisabled',1),
    @($bravePol,'BraveVPNDisabled',1),
    @($bravePol,'BraveRewardsDisabled',1),
    @($bravePol,'BraveNewsDisabled',1),
    @($bravePol,'BraveTalkDisabled',1)
) -Info 'Brave policies that remove the Leo AI assistant, the built-in crypto wallet, the paid VPN service and its background components, Brave Rewards ads, the News feed and Talk. Browsing, shields and sync are unchanged.')

$script:Tweaks += New-ServiceGroup -Id 'svc.tel.usagequality' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop usage and quality insights' -Risk 'Safe' -Services @('wuqisvc') -Info 'Microsoft Usage and Quality Insights builds summary statistics of how Windows and apps are used, which Windows uses for automatic self-healing and for optional features such as personalized offers. A working PC does not need it. Unticking returns it to on-demand.'
$script:Tweaks += New-ServiceGroup -Id 'svc.tel.whesvc' -Tab 'Tweaks' -SubTab 'Services' -Group 'Telemetry and diagnostics' -Label 'Stop Windows Health and Optimized Experiences monitoring' -Risk 'Moderate' -Recommend $false -Services @('whesvc') -Info 'Runs a small sandboxed script every few minutes that samples CPU load, power mode, temperatures, battery and brightness to suggest power and performance fixes. On a desktop those suggestions have little value. Unticking returns it to on-demand.'
$whe = @($script:Tweaks | Where-Object { $_.Id -eq 'svc.tel.whesvc' })[0]
foreach ($tn in 'WhesvcToast','ShowFeedbackToast') {
    $whe.Apply = @($whe.Apply) + @(@{kind='task';path='\Microsoft\Windows\PerformanceTrace\';name=$tn;enable=$false})
    $whe.Revert = @($whe.Revert) + @(@{kind='task';path='\Microsoft\Windows\PerformanceTrace\';name=$tn;enable=$true})
}
$flight = '\Microsoft\Windows\Flighting\FeatureConfig\'
$script:Tweaks += (New-Tweak -Id 'task.tel.flighting' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Telemetry and diagnostics' -Label 'Disable feature usage reporting and OneSettings refresh tasks' -Risk 'Safe' -Detect @{kind='taskAnyName';names=@('UsageDataReporting','UsageDataFlushing','UsageDataReceiver','BootstrapUsageDataReporting')} -Apply @(
    'UsageDataReporting','UsageDataFlushing','UsageDataReceiver','BootstrapUsageDataReporting' | ForEach-Object { @{kind='task';path=$flight;name=$_;enable=$false} }
    @{kind='task';path='\Microsoft\Windows\Flighting\OneSettings\';name='RefreshCache';enable=$false}
) -Revert @(
    'UsageDataReporting','UsageDataFlushing','UsageDataReceiver','BootstrapUsageDataReporting' | ForEach-Object { @{kind='task';path=$flight;name=$_;enable=$true} }
    @{kind='task';path='\Microsoft\Windows\Flighting\OneSettings\';name='RefreshCache';enable=$true}
) -Info 'Stops the tasks that collect and upload which Windows features you use, and the task that downloads the OneSettings telemetry and experiment configuration. The ReconcileFeatures and SafeguardsReconciliation tasks are left on, because Windows Update uses them to roll out fixes and to block upgrades that are known to break a device.')
$script:Tweaks += (New-Tweak -Id 'task.nag.accountrecovery' -Tab 'Tweaks' -SubTab 'Startup and tasks' -Group 'Sync and accounts' -Label 'Stop Microsoft account recovery-info reminders' -Risk 'Safe' -Detect @{kind='taskAnyName';names=@('RecoverabilityToastTask')} -Apply @(
    @{kind='task';path='\Microsoft\Windows\AccountHealth\';name='RecoverabilityToastTask';enable=$false}
) -Revert @(
    @{kind='task';path='\Microsoft\Windows\AccountHealth\';name='RecoverabilityToastTask';enable=$true}
) -Info 'Stops the recurring notification asking you to add or confirm recovery information for your Microsoft account. Your account and its recovery options are not changed; you can still manage them in Settings > Accounts.')
($script:Tweaks | Where-Object { $_.Id -eq 'svc.tel.whesvc' }).Warn ='Windows stops suggesting power and performance fixes (for example battery-drain or overheating tips); laptops lose the most.'

$appPriv = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:Tweaks += (New-RegRow -Id 'feat.ai.systemmodels' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Block apps from Windows text and image generation' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @($appPriv,'LetAppsAccessSystemAIModels',2)
) -Info 'Windows privacy policy "Let Windows apps make use of Text and image generation features of Windows" set to Force Deny. Photos, Snipping Tool, Paint, Notepad and other apps can no longer call the built-in on-device AI models (rewrite, describe, generate, erase, relight); the Settings > Privacy page is locked to off. Restart open apps to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.ai.foregroundtext' -SubTab 'Features' -Group 'AI and Copilot' -Label 'Block apps from reading text in the window you are using' -Risk 'Safe' -Detect @{kind='registry';minBuild=26100} -Values @(
    @($appPriv,'LetAppsAccessForegroundText',2)
) -Info 'Windows privacy policy "Let Windows apps access text content from foreground applications" set to Force Deny, so Store apps such as Copilot and AI assistants cannot read the text of the app you are working in. Desktop accessibility tools are not affected.')
$script:Tweaks += (New-Tweak -Id 'app.edge.gameassist' -Tab 'Tweaks' -SubTab 'Apps' -Group 'Microsoft Store' -Label 'Remove the Edge Game Assist Game Bar widget' -Risk 'Safe' -Recommend $false -Detect @{kind='appx';name='Microsoft.Edge.GameAssist'} -Apply @(
    @{kind='appx';name='Microsoft.Edge.GameAssist';provisioned=$true}
) -Revert @() -Info 'Game Assist is a separate Store package that puts an Edge browser panel inside Game Bar and starts Edge processes while you play. Removing it does not affect Edge or Game Bar. To get it back, search for Game Assist in Edge settings or the Game Bar widget store.')
$script:Tweaks += (New-Tweak -Id 'feat.cap.legacy' -Tab 'Tweaks' -SubTab 'Features' -Group 'Windows optional features' -Label 'Remove Math Input Panel, PowerShell ISE and Steps Recorder' -Risk 'Moderate' -Recommend $false -Detect @{kind='capability';names=@('MathRecognizer~','Microsoft.Windows.PowerShell.ISE~','App.StepsRecorder~')} -Apply @(
    @{kind='capability';names=@('MathRecognizer~','Microsoft.Windows.PowerShell.ISE~','App.StepsRecorder~');enable=$false}
) -Revert @(
    @{kind='capability';names=@('MathRecognizer~','Microsoft.Windows.PowerShell.ISE~','App.StepsRecorder~');enable=$true}
) -Info 'Removes three deprecated Windows capabilities: Math Input Panel (handwritten equations), the PowerShell ISE editor (replaced by Windows Terminal and VS Code) and Steps Recorder (retired by Microsoft). Frees disk space and removes their background components. PowerShell itself is not touched.')
($script:Tweaks | Where-Object { $_.Id -eq 'feat.cap.legacy' }).Warn = 'Adding them back downloads them from Windows Update, so it fails while Windows Update is disabled.'
$vsCodePaths = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe","$env:ProgramFiles\Microsoft VS Code\Code.exe")
$script:Tweaks += (New-RegRow -Id 'app.vscode.telemetry' -SubTab 'Apps' -Group 'Developer tools' -Label 'VS Code: turn off telemetry and feedback prompts' -Risk 'Safe' -Detect @{kind='anyPath';paths=$vsCodePaths} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\VSCode','TelemetryLevel','off','String'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\VSCode','EnableFeedback',0)
) -Info 'VS Code enterprise policies TelemetryLevel=off (no crash, error or usage data) and EnableFeedback=false (no issue-reporter surveys). Extensions keep their own telemetry settings. VS Code shows the setting as managed by your organization.')
$script:Tweaks += (New-RegRow -Id 'app.vs.telemetry' -SubTab 'Apps' -Group 'Developer tools' -Label 'Visual Studio: opt out of the Experience Improvement Program' -Risk 'Safe' -Detect @{kind='anyPath';paths=@("$env:ProgramFiles\Microsoft Visual Studio","${env:ProgramFiles(x86)}\Microsoft Visual Studio")} -Values @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM','OptIn',0)
) -Info 'Machine policy that opts every Visual Studio version and the Build Tools out of the Customer Experience Improvement Program (optional usage and error data). Report a Problem still works when you choose to send it.')
$script:Tweaks += (New-RegRow -Id 'feat.privacy.presence' -SubTab 'Features' -Group 'Privacy and ads' -Label 'Block Store apps from presence sensing' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22000} -Values @(
    @($appPriv,'LetAppsAccessHumanPresence',2)
) -Info 'Windows privacy policy "Let Windows apps access presence sensing" set to Force Deny, so Store apps cannot read whether you are sitting at the PC, how far away you are or where you are looking (laptops and monitors with presence sensors). Windows'' own lock-on-leave, wake-on-approach and adaptive dimming keep working because they are controlled separately in Power & battery.')
$vsc = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
$script:Tweaks += (New-RegRow -Id 'app.vscode.ai' -SubTab 'Apps' -Group 'Developer tools' -Label 'VS Code: turn off AI agents, MCP servers and agent plugins' -Risk 'Safe' -Recommend $false -Detect @{kind='anyPath';paths=$vsCodePaths} -Values @(
    @($vsc,'ChatAgentMode',0),
    @($vsc,'ChatMCP','off','String'),
    @($vsc,'ChatAgentExtensionTools',0),
    @($vsc,'BrowserChatTools',0),
    @($vsc,'ChatPluginsEnabled',0),
    @($vsc,'Claude3PIntegration',0),
    @($vsc,'Codex3PIntegration',0),
    @($vsc,'AgentsVoice',0)
) -Info 'VS Code enterprise policies: agent mode off, MCP servers off, extension and browser tools for chat off, agent plugins off, third-party Claude and Codex agent sessions off, voice mode off. Ask and edit chat still work if you use Copilot. The newer Agent Host session type only partly honours the agent-mode policy, so remove the Copilot extensions as well if you want no AI at all.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.gallery' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Hide Gallery in the File Explorer navigation pane' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22621} -Values @(
    @('HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}','System.IsPinnedToNameSpaceTree',0)
) -Info 'Removes Gallery from the left pane of File Explorer. Gallery builds a timeline of every photo and video in your Pictures and OneDrive folders, which is slow on large libraries. Your files are not touched. Restart Explorer to apply.')
$script:Tweaks += (New-RegRow -Id 'feat.explorer.home' -SubTab 'Features' -Group 'Explorer and visuals' -Label 'Hide Home in the File Explorer navigation pane' -Risk 'Safe' -Recommend $false -Detect @{kind='registry';minBuild=22000} -Values @(
    @('HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}','System.IsPinnedToNameSpaceTree',0)
) -Info 'Removes Home (recent files, favorites and Microsoft 365 recommendations) from the left pane. Pair it with "Open File Explorer to This PC" so Explorer does not open on a hidden page. Restart Explorer to apply.')
$script:Tweaks += New-ServiceGroup -Id 'svc.ai.agentbroker' -Tab 'Tweaks' -SubTab 'Services' -Group 'Cloud and AI' -Label 'Stop the AI agent workspace broker' -Risk 'Moderate' -Recommend $false -Services @('IsoEnvBroker') -Info 'The Isolation Environment Broker creates agent user accounts, starts their hidden agent sessions, runs programs inside them and shares your folders with them. It is what Copilot Actions and other agents use for the agent workspace. Disabling it keeps agents from getting a workspace even if the experimental agentic features setting is turned on. Only present on builds that ship agent workspaces. Unticking returns it to on-demand.'
($script:Tweaks | Where-Object { $_.Id -eq 'svc.ai.agentbroker' }).Warn = 'Copilot Actions and any app that runs AI agents in an agent workspace stop working until it is turned back on.'
$bk = @($script:Tweaks | Where-Object { $_.Id -eq 'task.backup' })[0]
if ($bk) { $bk.Detect.paths = @($bk.Detect.paths) + @('\Microsoft\Windows\AppListBackup\'); $bk.Apply = @($bk.Apply) + @(@{kind='taskFolder';path='\Microsoft\Windows\AppListBackup\'}); $bk.Revert = @($bk.Revert) + @(@{kind='taskFolder';path='\Microsoft\Windows\AppListBackup\';enable=$true}) }
$sy = @($script:Tweaks | Where-Object { $_.Id -eq 'task.sync' })[0]
if ($sy) { $sy.Detect.paths = @($sy.Detect.paths) + @('\Microsoft\Windows\ConsentUX\UnifiedConsent\'); $sy.Apply = @($sy.Apply) + @(@{kind='task';path='\Microsoft\Windows\ConsentUX\UnifiedConsent\';name='UnifiedConsentSyncTask';enable=$false}); $sy.Revert = @($sy.Revert) + @(@{kind='task';path='\Microsoft\Windows\ConsentUX\UnifiedConsent\';name='UnifiedConsentSyncTask';enable=$true}) }

function Add-TweakRegistryValues {
    param([string]$Id,[array]$Values)
    $t = @($script:Tweaks | Where-Object { $_.Id -eq $Id })[0]
    if (-not $t) { return }
    if ($Values.Count -gt 0 -and $Values[0] -isnot [array]) { $Values = ,$Values }
    foreach ($v in $Values) {
        $type = if ($v.Count -gt 3) { $v[3] } else { 'DWord' }
        $t.Apply = @($t.Apply) + @(@{kind='registry';path=$v[0];name=$v[1];value=$v[2];type=$type})
        $t.Revert = @($t.Revert) + @(@{kind='registryDel';path=$v[0];name=$v[1]})
    }
}
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Add-TweakRegistryValues 'sec.recall' @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI','TurnOffSavingSnapshots',1))
Add-TweakRegistryValues 'feat.ai.paint' @(@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint','DisableGenerativeErase',1),@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint','DisableRemoveBackground',1))
Add-TweakRegistryValues 'app.edge.ai' @(@($edge,'CopilotCDPPageContext',0),@($edge,'EdgeHistoryAISearchEnabled',0),@($edge,'NewTabPageBingChatEnabled',0))
Add-TweakRegistryValues 'app.edge.privacy' @(@($edge,'TabServicesEnabled',0),@($edge,'AlternateErrorPagesEnabled',0),@($edge,'WalletDonationEnabled',0),@($edge,'DefaultBrowserSettingsCampaignEnabled',0),@($edge,'ShowAcrobatSubscriptionButton',0))
Add-TweakRegistryValues 'feat.privacy.tips' @(@($cdm,'SystemPaneSuggestionsEnabled',0),@($cdm,'SoftLandingEnabled',0),@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested','Enabled',0),@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder','Enabled',0),@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility','OptedIn',0))
Add-TweakRegistryValues 'feat.privacy.settingsads' @(,@($cdm,'SubscribedContent-353698Enabled',0))
Add-TweakRegistryValues 'sec.privacy.locktips' @(,@($cdm,'SubscribedContent-338387Enabled',0))
Add-TweakRegistryValues 'feat.privacy.input' @(@('HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore','HarvestContacts',0),@('HKCU:\Software\Microsoft\Personalization\Settings','AcceptedPrivacyPolicy',0))
Add-TweakRegistryValues 'feat.shell.startaccount' @(,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications','EnableAccountNotifications',0))
Add-TweakRegistryValues 'sec.widgets' @(,@('HKLM:\SOFTWARE\Policies\Microsoft\Dsh','DisableWidgetsOnLockScreen',1))
$nvKey = 'HKLM:\SOFTWARE\NVIDIA Corporation'
$script:Tweaks += (New-RegRow -Id 'gpu.nv.telemetryreg' -Tab 'GPU' -SubTab '' -Group 'NVIDIA' -Label 'Opt out of NVIDIA driver telemetry' -Risk 'Safe' -Detect @{kind='registry';gpuVendor='NVIDIA'} -Values @(
    @("$nvKey\NvControlPanel2\Client",'OptInOrOutPreference',0),
    @("$nvKey\Global\FTS",'EnableRID44231',0),
    @("$nvKey\Global\FTS",'EnableRID64640',0),
    @("$nvKey\Global\FTS",'EnableRID66610',0),
    @('HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup','SendTelemetryData',0)
) -Info 'Opts the NVIDIA Control Panel out of usage data collection and turns off the driver telemetry reporting flags. The NVIDIA telemetry tasks and container are handled by the separate NVIDIA rows. Driver updates and the NVIDIA App keep working; a clean driver reinstall may set the flags again.')

$script:WarnText = @{
    'feat.input.mouseaccel'   = 'Cursor speed changes: slow, precise movements feel faster and quick flicks travel less, so you may need to readjust pointer speed or mouse DPI. Games that use raw input are unaffected.'
    'adv.devices.powersaving' = 'Devices kept awake use more power, and on laptops battery life drops. Unplugging and replugging a device can turn power saving back on.'
    'svc.bg.appupdate'        = 'Browser and Adobe updaters move to on-demand; apps update when you open them instead of in the background, so check for updates yourself.'
    'svc.bg.peruser'          = 'Per-user sync, contacts, calendar and messaging services move to on-demand; mail/notification sync can lag until the app is opened.'
    'svc.feat.ai'             = 'Agent Activation Runtime moves to on-demand; voice activation and some AI features may not start automatically.'
    'adv.devices.rdpredirect' = 'Blocks drive redirection in incoming Remote Desktop sessions; remote users cannot reach this PC''s drives.'
    'sec.encryption.prevent'  = 'Prevents automatic device encryption; it does not decrypt a drive that is already encrypted.'
    'sec.search.local'        = 'Removes web results and web suggestions from Windows Search; local file, app and settings search still works.'
}
foreach ($t in $script:Tweaks) { if ($script:WarnText.ContainsKey($t.Id)) { $t.Warn = $script:WarnText[$t.Id] } }

$script:NotRecommended = @(
    'gpu.mpo','gpu.mpo.minfps','cpu.parking','app.discord.hwaccel','sec.storebackground',
    'net.teredo','net.netbios','net.multihomed',
    'svc.dev.pairing','svc.net.discovery','svc.feat.notifications',
    'svc.vendor.asus','svc.dev.hotkey','svc.dev.hdhotkey',
    'mem.pagecombining','mem.compression','cpu.ppm.minstate','cpu.ppm.idle','startup.all',
    'cpu.ppm.hetero','cpu.ppm.perfepp','feat.privacy.appperms','svc.xbox.manual','feat.shell.hiddenfiles','feat.shell.startdelay'
)
foreach ($t in $script:Tweaks) {
    if ($t.Id -like 'cpu.ppm.*' -and -not @($t.Revert).Count) {
        $t.Revert = @($t.Apply | ForEach-Object { @{kind='powerSetting';sub=$_.sub;setting=$_.setting;value='Default';label=$_.label} })
    }
}
$script:LaptopRisky = @('feat.sys.hibernate','svc.vendor.asus','svc.dev.hotkey','svc.dev.hdhotkey','vendor.asus','vendor.msi','vendor.gigabyte','vendor.lenovo','vendor.dell','vendor.hp','vendor.acer')
$script:BuiltOnLaptop = Test-IsLaptop
if ($script:BuiltOnLaptop) {
    $script:NotRecommended += 'pwr.pcie.aspm','pwr.usb.suspend','feat.privacy.findmydevice','gpu.games.highperf','cpu.games.nothrottle','cpu.powermode.best'
    foreach ($t in $script:Tweaks) { if ($t.Id -in 'pwr.pcie.aspm','pwr.usb.suspend') { foreach ($a in @($t.Apply)) { $a.acOnly = $true }; $t.Info = $t.Info + ' On this laptop only the plugged-in value changes; battery keeps power saving.' } }
}
foreach ($t in $script:Tweaks) {
    if ($script:NotRecommended -contains $t.Id) { $t.Recommend = $false }
    if ($script:BuiltOnLaptop -and $script:LaptopRisky -contains $t.Id) {
        $t.Risk = 'Risky'
        $t.Info = $t.Info + ' On laptops these services also switch performance/fan profiles and Fn keys.'
    }
}
foreach ($t in $script:Tweaks) { if ($t.Id -eq 'svc.bg.sysmain' -and $t.Detect) { $t.Detect.noHdd = $true } }

$script:NotRecommended += 'feat.notify.off','feat.privacy.quickaccess','input.mouse.onetoone','feat.explorer.thispc','feat.opt.fax','feat.opt.ie',
    'svc.feat.location','svc.feat.timezone','svc.dev.smartcard','svc.dev.sensors','svc.dev.penuser','svc.net.hotspot','svc.feat.payments','svc.bg.wallet',
    'task.diag','task.sync','task.languagesync','svc.bg.insider','adv.boot.menu','net.wifi.band','net.wake','svc.feat.account','svc.feat.hello'
foreach ($t in $script:Tweaks) { if ($t.Id -like 'startup.*' -or $t.Id -like 'app.*.startup') { $script:NotRecommended += $t.Id } }
foreach ($t in $script:Tweaks) { if ($script:NotRecommended -contains $t.Id) { $t.Recommend = $false } }
foreach ($t in $script:Tweaks) { if ($t.Id -in 'svc.bg.do','svc.vendor.intel','net.green' -and $null -eq $t.Recommend) { $t.Recommend = $true } }

$msaLoss = 'Signs this PC out of all Microsoft account services: Store and Xbox / Game Pass (installs, sign-in, cloud saves), Outlook, Office sign-in and activation, OneDrive, Teams, Edge sync, Phone Link, Family Safety and Windows Backup. Work or school (Intune / Entra) enrollment stops. You cannot add or switch to a Microsoft account, and Windows sign-in with one only works with the password cached on this PC. Steam, Discord, Chrome and other non-Microsoft logins are unaffected.'
$script:FeatureWarnings = [ordered]@{
    'svc.feat.account'        = $msaLoss
    'svc.feat.hello'          = 'PIN, face and fingerprint sign-in and passkeys saved in Windows Hello stop working. Know your account password first, or you can be locked out of Windows.'
    'svc.feat.bitlocker'      = 'Do not apply while BitLocker or device encryption is on: unlocking other encrypted drives, suspending BitLocker for BIOS updates and backing up the recovery key stop working, and EFS-encrypted files cannot be opened.'
    'svc.feat.backup'         = 'System image backups (Backup and Restore (Windows 7)), wbadmin and the Windows Backup app stop working. Restore points are not affected: they use the Volume Shadow Copy service, which Rion Tool never disables.'
    'sec.updates'             = 'Also stops Store and Xbox / Game Pass installs and updates, Defender definition updates through Windows Update, driver updates and the Check for updates button. Turn it back on before installing apps or a feature update.'
    'svc.bg.telemetry'        = 'Windows Insider Preview builds require diagnostic data, so Insider updates can stop. Work or school managed PCs use dmwappushservice to receive device-management messages.'
    'svc.bg.search'           = 'Outlook (classic) search and searching inside File Explorer folders become slow or incomplete.'
    'task.diag'               = 'Also turns off the Disk Diagnostic resolver, which is how Windows warns you that a drive is reporting a failure (SMART), and stops queued crash reports from being sent. Check drive health with your drive maker''s tool now and then.'
    'svc.feat.timezone'       = 'The time zone no longer follows you when you travel; with a wrong time zone, calendar entries and in-game event timers show the wrong hour.'
    'svc.net.hotspot'         = 'Settings > Mobile hotspot (sharing this PC''s internet with a phone or console) and cellular data on PCs with a SIM stop working.'
    'svc.dev.smartcard'       = 'Smart cards, PIV security keys and virtual smart cards stop working for sign-in and document signing. FIDO2 security keys and passkeys are not affected.'
    'svc.dev.sensors'         = 'Laptops and tablets lose auto-rotate and adaptive brightness.'
    'svc.feat.payments'       = 'NFC tap-to-pay and calls or texts on PCs with a cellular modem stop working.'
    'net.dns'                 = 'While a public DNS is set, names your router provides (router or NAS names), parental-control filtering done by your router, company or school DNS, and hotel or airport Wi-Fi sign-in pages can stop working.'
    'feat.opt.fax'            = 'The Windows Fax and Scan app is removed too; scan with Windows Scan or your scanner maker''s app instead.'
    'feat.opt.ie'             = 'Edge IE mode depends on this feature: sites that a bank, school or government office only supports in IE mode stop opening in IE mode until the feature is turned back on.'
    'feat.privacy.quickaccess'= 'Recent files disappear from File Explorer Home and the Start menu, so reopening a file you just used means browsing to it again.'
    'gpu.amd.ulps'            = 'The second GPU in a multi-GPU desktop or a hybrid laptop no longer powers down when idle, raising idle power use and heat.'
    'sec.wu.nodrivers'        = 'Windows Update no longer offers driver updates, including drivers for hardware you plug in later; get those from the device maker.'
    'svc.feat.crossdevice'    = 'Phone Link, cross-device resume and Nearby sharing wait until the services are started by an app.'
    'svc.net.share'           = 'Other PCs, TVs and consoles can no longer open folders or printers shared from this PC.'
    'task.sync'               = 'Theme, language, keyboard and accessibility settings stop syncing between PCs signed in with the same Microsoft account.'
    'task.languagesync'       = 'Language and keyboard settings stop syncing between PCs signed in with the same Microsoft account.'
    'task.compat'             = 'Windows stops pre-checking installed apps for problems with the next Windows version; feature update setup still runs its own check, so a blocked upgrade is reported later, during setup.'
    'svc.vendor.intellms'     = 'On a work PC managed with Intel vPro / AMT, remote management by IT stops.'
    'svc.bg.pca'              = 'Windows stops offering to rerun old programs and installers with compatibility settings after they fail.'
}
foreach ($t in $script:Tweaks) {
    if (-not $script:FeatureWarnings.Contains($t.Id)) { continue }
    $w = [string]$script:FeatureWarnings[$t.Id]
    $t.Warn = if ([string]$t.Warn) { ([string]$t.Warn).TrimEnd() + ' ' + $w } else { $w }
    if ($t.Risk -eq 'Safe' -and $t.Id -in 'task.diag','svc.feat.location','svc.net.hotspot','svc.dev.smartcard','svc.feat.payments','feat.notify.off','feat.opt.ie','feat.opt.fax','net.dns') { $t.Risk = 'Moderate' }
}
foreach ($t in $script:Tweaks) {
    if ($t.Id -eq 'feat.opt.ie') { $t.Info = 'Removes the Internet Explorer 11 optional feature (the retired standalone browser).' }
    if ($t.Id -eq 'task.maintenance') { $t.Label = 'Disable the WinSAT hardware assessment task'; $t.Risk = 'Safe'; $t.Info = 'The Maintenance task folder holds only WinSAT, which benchmarks the CPU, memory, disk and graphics after hardware changes and stores the scores Windows uses to choose some desktop and media defaults. Windows automatic maintenance itself (updates, drive optimization, Defender scans) is not affected.' }
}

$script:LowerFpsIds = @('gpu.mpo','cpu.ppm.idle','cpu.ppm.idledepth','cpu.parking')
$script:RiskyIds = @('feat.net.wifi','feat.net.eth','svc.dev.print','svc.dev.bluetooth','svc.dev.webcam','svc.dev.pairing','sec.updates','sec.defender','sec.encryption.decrypt','svc.feat.account','svc.feat.hello','feat.opt.hypervisor','feat.cloud.onedrive','svc.feat.notifications','svc.feat.bitlocker','svc.feat.family','gpu.mpo','cpu.ppm.idle','cpu.ppm.idledepth','cpu.parking','net.wifi.location','feat.privacy.appperms')
$script:ModerateIds = @('svc.bg.diag','feat.sys.hibernate','svc.xbox.live','task.xblgamesave','net.intmod','gpu.hags','gpu.msi','gpu.mpo.minfps','gpu.amd.ulps','cpu.boost','cpu.ppm.responsive','cpu.ppm.throttle','cpu.ppm.minstate','cpu.ppm.hetero','cpu.ppm.perfepp','cpu.ppm.maxfreq','cpu.amd.x3dcache','mem.compression','mem.pagecombining','svc.bg.sysmain','pwr.pcie.aspm','pwr.usb.suspend','input.usb.power','sec.vbs','sec.lsa.ppl','sec.wu.pinversion','svc.bg.servicing','net.autotune','feat.opt.media','svc.net.iphlp','svc.feat.phishing','svc.dev.printbroker','task.familysafety')
foreach ($t in $script:Tweaks) {
    if ($t.Type -eq 'info') { continue }
    $t.Risk = if ($script:RiskyIds -contains $t.Id) { 'Risky' } elseif ($script:ModerateIds -contains $t.Id) { 'Moderate' } else { 'Safe' }
    if ($script:BuiltOnLaptop -and $script:LaptopRisky -contains $t.Id) { $t.Risk = 'Risky' }
}
$script:MinimalIds = @('feat.shell.startrecs','feat.shell.startaccount','feat.shell.syncads','feat.privacy.settingsads','feat.privacy.tips','feat.privacy.silentapps','feat.shell.searchhighlights','feat.shell.bingstart','sec.privacy.cloudcontent','sec.privacy.locktips','sec.privacy.finishsetup','feat.settings.m365ads','feat.start.phonelink','task.nag.accountrecovery','sec.privacy.feedback','sec.privacy.adid','sec.privacy.tailored','svc.bg.telemetry','sec.privacy.telemetry','task.telemetry','task.tel.flighting','priv.autologger.telemetry','feat.privacy.ceip','feat.privacy.envtel','svc.tel.usagequality','gpu.nv.telemetryreg','svc.gpu.amd.uep','svc.gpu.nv.telemetry','task.gpu.nv.reports','app.vscode.telemetry','app.vs.telemetry','task.office','priv.wer.extra','feat.ai.agents','sec.recall','sec.clicktodo','feat.ai.settingsagent','feat.explorer.aiactions','feat.gaming.bgrecord','adv.prio.sep26','mem.prelaunch')
$script:RecommendedIds = $script:MinimalIds + @('feat.ai.copilotall','feat.ai.askcopilot','feat.ai.edge','app.edge.ai','app.chrome.ai','app.brave.bloat','app.firefox.ai','feat.ai.paint','feat.ai.notepad','feat.ai.foregroundtext','feat.ai.systemmodels','sec.widgets','sec.crossresume','feat.share.dragtray','sec.privacy.activity','sec.privacy.clipboard','sec.privacy.inking','feat.privacy.input','sec.privacy.cortana','feat.privacy.langlist','feat.privacy.spotlight','priv.appcompat','app.edge.privacy','cpu.powermode.best','gpu.games.highperf','cpu.games.nothrottle','net.wifi.powersave','svc.bg.do','svc.vendor.intel','svc.vendor.inteldsa','net.green','net.eee','feat.maint.wake','app.store.archiving','app.edge.background','app.chrome.bg','app.brave.bg','app.chrome.memory','storage.longpaths','adv.crash.details','feat.signin.arso','sec.wu.asap','sec.wu.noreboot','adv.wpbt','sec.wu.nodrivers','adv.svchost','adv.prio.ifeo','task.gpu.amd.cpumetrics','task.gpu.amd.updates','svc.ai.fabric','feat.shell.fileext','feat.taskbar.endtask','feat.input.mouseaccel','feat.input.stickykeys','feat.audio.ducking','gpu.windowed','feat.shell.classicmenu')
if ($script:BuiltOnLaptop) { $script:RecommendedIds = @($script:RecommendedIds | Where-Object { $_ -notin 'cpu.powermode.best','gpu.games.highperf','cpu.games.nothrottle','net.wifi.powersave','net.green','net.eee' }) }
foreach ($t in $script:Tweaks) { $t.Recommend = ($script:RecommendedIds -contains $t.Id) }
$script:VendorTabMap = @{
    'cpu.amd.x3dcache'=@('AMD','Processor'); 'gpu.amd.ulps'=@('AMD','Graphics driver')
    'svc.gpu.amd.crashdefender'=@('AMD','AMD Software services'); 'svc.gpu.amd.uep'=@('AMD','AMD Software services'); 'svc.gpu.amd.extevents'=@('AMD','AMD Software services')
    'task.gpu.amd.software'=@('AMD','AMD Software startup and tasks'); 'task.gpu.amd.cpumetrics'=@('AMD','AMD Software startup and tasks'); 'task.gpu.amd.dvr'=@('AMD','AMD Software startup and tasks'); 'task.gpu.amd.updates'=@('AMD','AMD Software startup and tasks')
    'gpu.nv.telemetryreg'=@('NVIDIA','Graphics driver')
    'svc.gpu.nv.container'=@('NVIDIA','NVIDIA app services'); 'svc.gpu.nv.telemetry'=@('NVIDIA','NVIDIA app services'); 'svc.gpu.nv.frameview'=@('NVIDIA','NVIDIA app services')
    'task.gpu.nv.reports'=@('NVIDIA','NVIDIA app startup and tasks'); 'task.gpu.nv.updates'=@('NVIDIA','NVIDIA app startup and tasks'); 'task.gpu.nv.profiles'=@('NVIDIA','NVIDIA app startup and tasks'); 'startup.nvidia'=@('NVIDIA','NVIDIA app startup and tasks')
    'svc.vendor.intel'=@('Intel','Intel services'); 'svc.vendor.intellms'=@('Intel','Intel services'); 'svc.vendor.inteldsa'=@('Intel','Intel services'); 'gpu.intel.todo'=@('Intel','Intel Graphics Software')
}
foreach ($t in $script:Tweaks) { $m = $script:VendorTabMap[$t.Id]; if ($m) { $t.Tab = $m[0]; $t.SubTab = ''; $t.Group = $m[1] } }
$script:GuardedServices = @('KeyIso','CryptSvc','VaultSvc','SamSs','ProfSvc','gpsvc','UserManager','TokenBroker','TBS','VSS','swprv','TrustedInstaller','ClipSVC','sppsvc','LicenseManager','AppXSvc','StateRepository','Winmgmt','EventLog','RpcSs','Schedule','BrokerInfrastructure','CoreMessagingRegistrar','Power','PlugPlay','GoogleChromeElevationService','MicrosoftEdgeElevationService','BraveElevationService')
foreach ($t in $script:Tweaks) {
    $blocked = @($t.Apply | Where-Object { $_.kind -eq 'service' -and $script:GuardedServices -contains [string]$_.name })
    if (-not $blocked.Count) { continue }
    $t.Apply = @($t.Apply | Where-Object { -not ($_.kind -eq 'service' -and $script:GuardedServices -contains [string]$_.name) })
    $t.Revert = @($t.Revert | Where-Object { -not ($_.kind -eq 'service' -and $script:GuardedServices -contains [string]$_.name) })
    try { Write-Log ("Left protected services untouched in {0}: {1}" -f $t.Id,(@($blocked | ForEach-Object { $_.name }) -join ', ')) 'Warn' } catch {}
}

$script:AntiCheatGuardPatterns = @(
    '(?i)VulnerableDriverBlocklistEnable',
    '(?i)CI\\Policy|CI\\Config',
    '(?i)IOMMU|VtdEnable|Vtd\b',
    '(?i)DeviceGuard(?!.*HypervisorEnforcedCodeIntegrity).*EnableVirtualizationBasedSecurity',
    '(?i)\\CurrentControlSet\\Control\\CI\b',
    '(?i)TESTSIGNING|nointegritychecks|bootmenupolicy.*test'
)
$script:Tweaks = @($script:Tweaks | Where-Object {
    $t = $_
    if ($t.Id -eq 'sec.vbs') { return $true }
    $bad = $false
    foreach ($a in @($t.Apply)) {
        $probe = ('{0} {1} {2}' -f $a.path,$a.name,$a.args)
        foreach ($pat in $script:AntiCheatGuardPatterns) { if ($probe -match $pat) { $bad = $true } }
    }
    if ($bad) { try { Write-Log ("Blocked a tweak that could disable a security feature or break anti-cheat: {0}" -f $t.Id) 'Warn' } catch {} }
    -not $bad
})

$script:TweakIndex = @{}
foreach ($t in $script:Tweaks) { $script:TweakIndex[$t.Id] = $t }
 
function Test-TweakRegistryActionsApplied {
    param($Tweak)
    $actions = @($Tweak.Apply | Where-Object { $_.kind -in @('registry','registryDel') })
    if (-not $actions.Count) { return $null }
    foreach ($action in $actions) {
        if ($action.kind -eq 'registry') {
            try {
                $rv = Get-RegValueFast $action.path $action.name; if (-not $rv.Exists) { return $false }; $current = $rv.Value
                $currentText = if($current -is [array]){(@($current) -join "`n")}else{[string]$current}
                $targetText = if($action.value -is [array]){(@($action.value) -join "`n")}else{[string]$action.value}
                if ($currentText -ne $targetText) { return $false }
            } catch { return $false }
        } else {
            if ((Get-RegValueFast $action.path $action.name).Exists) { return $false }
        }
    }
    return $true
}

function Suspend-BitLockerForBootChange {
    if ($script:BitLockerSuspended) { return }
    $on = $false
    try { $on = ((Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus -eq 'On') }
    catch {
        try { $on = ((Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop).ProtectionStatus -eq 1) } catch { }
    }
    if (-not $on) { return }
    try { Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null }
    catch { & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 1 | Out-Null }
    $script:BitLockerSuspended = $true
    Write-Log 'BitLocker protection is suspended until the next restart so the boot change does not ask for the recovery key. It turns back on automatically after the restart.' 'Warn'
}

function Get-BcdValue {
    param([string]$Id,[string]$Name)
    try {
        foreach ($line in @(& bcdedit.exe /enum $Id 2>$null)) {
            if ($line -match ('^\s*{0}\s+(\S.*?)\s*$' -f [regex]::Escape($Name))) { return $Matches[1] }
        }
    } catch { }
    return $null
}

function Get-NetPropertyMaxValue {
    param($Property)
    $values = @($Property.ValidDisplayValues | Where-Object { $_ -ne $null -and ([string]$_).Trim() -ne '' })
    if ($values.Count) {
        $numeric = @($values | ForEach-Object { $n = 0.0; if ([double]::TryParse([string]$_,[ref]$n)) { [pscustomobject]@{ Text=[string]$_; Value=$n } } } | Sort-Object Value)
        if ($numeric.Count) { return $numeric[-1].Text }
        return [string]$values[-1]
    }
    if ($null -ne $Property.NumericParameterMaxValue -and [string]$Property.NumericParameterMaxValue -ne '') { return [string]$Property.NumericParameterMaxValue }
    return $null
}

function Get-MatchingNetProperties {
    param($Spec)
    $names = @(@($Spec.names) + @($Spec.name) | Where-Object { $_ })
    $keywords = @(@($Spec.keywords) | Where-Object { $_ })
    $pattern = [string]$Spec.namePattern
    $all = if ($null -ne $script:NetPropCache) { $script:NetPropCache } else { @(Get-NetAdapterAdvancedProperty -AllProperties -ErrorAction SilentlyContinue) }
    return @($all | Where-Object {
        $_.DisplayName -and (($names -contains $_.DisplayName) -or ($keywords -contains $_.RegistryKeyword) -or ($pattern -and $_.DisplayName -match $pattern))
    })
}

function Resolve-NetDisplayValue {
    param($Property,$Spec)
    $valid = @($Property.ValidDisplayValues | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ })
    $want = [string]$Spec.value
    if ($null -ne $Spec.regValue -and $valid.Count) {
        $regs = @($Property.ValidRegistryValues | ForEach-Object { [string]$_ })
        $ri = [array]::IndexOf($regs,[string]$Spec.regValue)
        if ($ri -ge 0 -and $ri -lt $valid.Count) { return $valid[$ri] }
    }
    if (-not $valid.Count) { if ($want) { return $want } else { return $null } }
    if ($want -and ($valid -contains $want)) { return $want }
    if ($Spec.valuePattern) {
        $hit = @($valid | Where-Object { $_ -match [string]$Spec.valuePattern }) | Select-Object -First 1
        if ($hit) { return [string]$hit }
    }
    return $null
}
$script:OptionalFeatureStates = $null
function Get-OptionalFeatureStates {
    if ($null -eq $script:OptionalFeatureStates) {
        $map = @{}
        try { foreach ($f in @(Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop)) { $map[[string]$f.Name] = [int]$f.InstallState } } catch { }
        $script:OptionalFeatureStates = $map
    }
    return $script:OptionalFeatureStates
}

function Get-AppxStartupStates {
    param([string[]]$Families)
    $root = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    foreach ($pkg in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $family = $pkg.PSChildName
        if (-not @($Families | Where-Object { $family -like $_ }).Count) { continue }
        foreach ($task in @(Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue)) {
            $value = $task.GetValue('State')
            if ($null -ne $value) { [pscustomobject]@{ Path=('Registry::{0}' -f $task.Name); Family=$family; Task=$task.PSChildName; State=[int]$value } }
        }
    }
}

function Get-ActionLiveState {
    param($Action)
    $state = $null; $text = ''
    try {
        switch ([string]$Action.kind) {
            'registry' {
                $tv = $Action.value
                if ($tv -is [int] -and $tv -lt 0) { $tv = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$tv),0) }
                $target = if ($tv -is [array]) { @($tv) -join ',' } else { [string]$tv }
                $item = Get-Item -LiteralPath $Action.path -ErrorAction SilentlyContinue
                if ($item -and @($item.GetValueNames()) -contains $Action.name) {
                    $cur = $item.GetValue($Action.name)
                    if ($cur -is [int] -and $cur -lt 0) { $cur = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$cur),0) }
                    $curText = if ($cur -is [array]) { @($cur) -join ',' } else { [string]$cur }
                    $state = ($curText -eq $target)
                    $text = ('{0}\{1}={2} (want {3})' -f $Action.path,$Action.name,$curText,$target)
                } else {
                    $state = $false
                    $text = ('{0}\{1} not set (want {2})' -f $Action.path,$Action.name,$target)
                }
            }
            'registryDel' {
                $item = Get-Item -LiteralPath $Action.path -ErrorAction SilentlyContinue
                $exists = [bool]($item -and @($item.GetValueNames()) -contains $Action.name)
                $state = -not $exists
                $text = ('{0}\{1} {2} (want removed)' -f $Action.path,$Action.name,$(if ($exists) { 'present' } else { 'removed' }))
            }
            'service' {
                $want = switch ([string]$Action.start) { 'Automatic' {2} 'Manual' {3} default {4} }
                $names = @(Resolve-ServiceNames $Action.name)
                if ($names.Count) {
                    $starts = foreach ($n in $names) { @{ Name=$n; Start=(Get-ServiceStartValue $n) } }
                    $state = -not @($starts | Where-Object { -not (Test-ServiceStartMet $_.Start $want) }).Count
                    $text = (@($starts | ForEach-Object { '{0}={1}' -f $_.Name,$_.Start }) -join ',') + (' (want {0})' -f $want)
                }
            }
            'amdUlps' {
                $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                $keys = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })
                $amd = @($keys | Where-Object { ([string]$_.GetValue('ProviderName') -match '(?i)Advanced Micro Devices|\bAMD\b|\bATI\b') -or ([string]$_.GetValue('DriverDesc') -match '(?i)\bAMD\b|Radeon') })
                if ($amd.Count) {
                    $want = [int][bool]$Action.enable
                    $state = -not @($amd | Where-Object { $_.GetValue('EnableUlps') -ne $want }).Count
                    $text = (@($amd | ForEach-Object { $v = $_.GetValue('EnableUlps'); '{0} EnableUlps={1}' -f $_.PSChildName,$(if ($null -eq $v) { 'unset' } else { $v }) }) -join ',') + (' (want {0})' -f $want)
                }
            }
            'nagle' {
                $keys = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | Where-Object { [bool]@(@($_.GetValue('DhcpIPAddress')) + @($_.GetValue('IPAddress')) | Where-Object { $_ -and $_ -ne '0.0.0.0' }).Count })
                if ($keys.Count -and $Action.enable) {
                    $set = @($keys | Where-Object { $_.GetValue('TcpAckFrequency') -eq 1 -and $_.GetValue('TCPNoDelay') -eq 1 })
                    $state = ($set.Count -eq $keys.Count)
                    $text = ('{0} of {1} active interfaces have TcpAckFrequency=1 and TCPNoDelay=1' -f $set.Count,$keys.Count)
                }
            }
            'netRss' {
                $r = @(Get-NetAdapterRss -ErrorAction SilentlyContinue)
                if ($r.Count) { $state = -not @($r | Where-Object { [bool]$_.Enabled -ne [bool]$Action.enable }).Count; $text = (@($r | ForEach-Object { '{0} RSS={1}' -f $_.Name,$_.Enabled }) -join ',') }
            }
            'netRsc' {
                $r = @(Get-NetAdapterRsc -ErrorAction SilentlyContinue)
                if ($r.Count) { $state = -not @($r | Where-Object { [bool]$_.IPv4Enabled -ne [bool]$Action.enable -or [bool]$_.IPv6Enabled -ne [bool]$Action.enable }).Count; $text = (@($r | ForEach-Object { '{0} RSC v4={1} v6={2}' -f $_.Name,$_.IPv4Enabled,$_.IPv6Enabled }) -join ',') }
            }
            'netPower' {
                $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $p = @(Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue | Where-Object { $physical -contains $_.Name })
                if ($p.Count) {
                    $mode = [string]$Action.value
                    $state = -not @($p | Where-Object { ([string]$_.WakeOnMagicPacket -notin $mode,'Unsupported') -or ([string]$_.WakeOnPattern -notin $mode,'Unsupported') }).Count
                    $text = (@($p | ForEach-Object { '{0} magic={1} pattern={2}' -f $_.Name,$_.WakeOnMagicPacket,$_.WakeOnPattern }) -join ',')
                }
            }
            { $_ -in 'netAdvancedProperty','netAdvancedPropertyMax' } {
                $results = foreach ($property in @(Get-MatchingNetProperties $Action)) {
                    $target = if ($Action.kind -eq 'netAdvancedPropertyMax') { Get-NetPropertyMaxValue $property } else { Resolve-NetDisplayValue $property $Action }
                    if ($null -eq $target) { continue }
                    @{ Ok=([string]$property.DisplayValue -eq [string]$target); Text=('{0}: {1}={2} (want {3})' -f $property.Name,$property.DisplayName,$property.DisplayValue,$target) }
                }
                $results = @($results)
                if ($results.Count) {
                    $state = -not @($results | Where-Object { -not $_.Ok }).Count
                    $text = (@($results | ForEach-Object { $_.Text }) -join ',')
                }
            }
            'netRssProfile' {
                $r = @(Get-NetAdapterRss -ErrorAction SilentlyContinue)
                if ($r.Count) {
                    $state = -not @($r | Where-Object { [string]$_.Profile -ne [string]$Action.profile -or [int]$_.BaseProcessorNumber -ne [int]$Action.base -or [int]$_.NumberOfReceiveQueues -ne [int]$Action.queues }).Count
                    $text = (@($r | ForEach-Object { '{0} profile={1} base={2} queues={3}' -f $_.Name,$_.Profile,$_.BaseProcessorNumber,$_.NumberOfReceiveQueues }) -join ',')
                }
            }
            'teredo' {
                $c = Get-NetTeredoConfiguration -ErrorAction Stop
                $state = (([string]$c.Type -eq 'Disabled') -eq (-not [bool]$Action.enable))
                $text = ('Teredo type={0}' -f $c.Type)
            }
            'netbios' {
                $cfg = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop)
                if ($cfg.Count) { $state = -not @($cfg | Where-Object { [int]$_.TcpipNetbiosOptions -ne [int]$Action.value }).Count; $text = (@($cfg | ForEach-Object { '{0} NetBIOS={1}' -f $_.Description,$_.TcpipNetbiosOptions }) -join ',') + (' (want {0})' -f $Action.value) }
            }
            'powerSetting' {
                $r = Get-PowerIndexRecord $Action.setting $Action.sub
                if ($r) { $state = ([int]$r.ac -eq [int]$Action.value -and ($Action.acOnly -or [int]$r.dc -eq [int]$Action.value)); $text = ('{0} ac={1} dc={2} (want {3}{4})' -f $Action.label,$r.ac,$r.dc,$Action.value,$(if ($Action.acOnly) { ' plugged in' } else { '' })) }
                else { $text = ('{0} is not in the active power plan' -f $Action.label) }
            }
            'mmagent' {
                try { $m = Get-MMAgent -ErrorAction Stop; $cur = [bool]$m.($Action.feature); $state = ($cur -eq [bool]$Action.enable); $text = ('{0}={1} (want {2})' -f $Action.feature,$cur,[bool]$Action.enable) } catch { }
            }
            'classicMenu' {
                $exists = Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
                $state = ($exists -eq [bool]$Action.enable)
                $text = ('Classic context menu {0} (want {1})' -f $(if ($exists) { 'on' } else { 'off' }),[bool]$Action.enable)
            }
            'hostsBlock' {
                $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
                $present = (Test-Path -LiteralPath $hosts) -and ((Get-Content -LiteralPath $hosts -Raw -ErrorAction SilentlyContinue) -match 'RionTool-telemetry-start')
                $state = ($present -eq [bool]$Action.enable)
                $text = ('Telemetry hosts block {0}' -f $(if ($present) { 'present' } else { 'absent' }))
            }
            'firewallBlock' {
                $present = $false; $fwk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'); if ($fwk) { try { foreach ($vn in $fwk.GetValueNames()) { if ([string]$fwk.GetValue($vn) -match 'EmbedCtxt=RionTool Telemetry Block') { $present = $true; break } } } finally { $fwk.Close() } }
                $state = ($present -eq [bool]$Action.enable)
                $text = ('Telemetry firewall rules {0}' -f $(if ($present) { 'present' } else { 'absent' }))
            }
            'runkeyAll' {
                $entries = @(Get-StartupEntries)
                if ($entries.Count) {
                    $on = @($entries | Where-Object { -not (Test-StartupEntryDisabled $_) })
                    $state = ($on.Count -eq 0)
                    $text = ('{0} of {1} startup entries still on{2}' -f $on.Count,$entries.Count,$(if ($on.Count) { ': ' + ((@($on | ForEach-Object { $_.Name }) | Select-Object -First 8) -join ', ') } else { '' }))
                }
            }
            'qosGame' {
                $qn = 'Rion DSCP ' + [IO.Path]::GetFileNameWithoutExtension([string]$Action.exe)
                $has = [bool](Get-NetQosPolicy -Name $qn -ErrorAction SilentlyContinue)
                $state = ($has -eq [bool]$Action.enable); $text = ('{0}: DSCP 46 rule {1}' -f [IO.Path]::GetFileName([string]$Action.exe),$(if ($has) { 'present' } else { 'not set' }))
            }
            'powerMode' {
                $v = Get-ActivePowerOverlay
                $state = ($v -eq ([string]$Action.guid).ToLowerInvariant())
                $name = @($script:PowerModes.Keys | Where-Object { $script:PowerModes[$_] -eq $v }) | Select-Object -First 1
                $text = ('Power mode (plugged in): {0}' -f $(if ($name) { $name } else { $v }))
            }
            'dxApp' {
                $v = Get-DxAppSetting ([string]$Action.exe) $Action.name
                $state = ([string]$v -eq [string]$Action.value)
                $text = ('{0}: {1}={2}' -f [IO.Path]::GetFileName([string]$Action.exe),$Action.name,$(if ($null -eq $v) { 'not set (Let Windows decide)' } else { $v }))
            }
            'throttleApp' {
                $v = Test-ThrottleExempt ([string]$Action.exe)
                if ($null -ne $v) { $state = ([bool]$v -eq [bool]$Action.exempt); $text = ('{0}: {1}' -f [IO.Path]::GetFileName([string]$Action.exe),$(if ($v) { 'exempt from power throttling' } else { 'Windows default' })) }
            }
            'dxGlobal' {
                $v = Get-DxGlobalSetting $Action.name
                $state = ([string]$v -eq [string]$Action.value)
                $text = ('DirectXUserGlobalSettings {0}={1} (want {2})' -f $Action.name,$(if ($null -eq $v) { 'not set' } else { $v }),$Action.value)
            }
            'msiMode' {
                $targets = @(Get-MsiTargets -WithMode)
                if ($targets.Count) {
                    $vals = foreach ($t in $targets) { @{ Name=$t.Name; Mode=$t.Mode; Value=(Get-ItemProperty -LiteralPath $t.Path -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported } }
                    $state = -not @($vals | Where-Object { [string]$_.Value -ne '1' }).Count
                    $text = (@($vals | ForEach-Object { '{0}: MSISupported={1}, {2}' -f $_.Name,$(if ($null -eq $_.Value) { 'unset' } else { $_.Value }),$_.Mode }) -join '; ')
                }
            }
            'coreparking' {
                $r = Get-PowerIndexRecord 'CPMINCORES'
                if ($r) { $want = if ($Action.park) { 0 } else { 100 }; $state = ($r.ac -eq $want -and $r.dc -eq $want); $text = ('CPMINCORES ac={0} dc={1} (want {2})' -f $r.ac,$r.dc,$want) }
            }
            'optionalFeature' {
                $features = Get-OptionalFeatureStates
                $found = @($Action.names | Where-Object { $features.ContainsKey($_) -and $features[$_] -in 1,2 })
                if ($found.Count) {
                    $want = if ($Action.enable) { 1 } else { 2 }
                    $state = -not @($found | Where-Object { $features[$_] -ne $want }).Count
                    $text = (@($found | ForEach-Object { '{0}={1}' -f $_,$(if ($features[$_] -eq 1) { 'enabled' } else { 'disabled' }) }) -join ',')
                }
            }
            'appxStartup' {
                $found = @(Get-AppxStartupStates $Action.families | Where-Object { $_.State -in 0,1,2 })
                if ($found.Count) {
                    $state = if ($Action.enable) { -not @($found | Where-Object { $_.State -ne 2 }).Count } else { -not @($found | Where-Object { $_.State -eq 2 }).Count }
                    $text = (@($found | ForEach-Object { '{0}\{1} State={2}' -f $_.Family,$_.Task,$_.State }) -join ',')
                }
            }
            'bcdedit' {
                $bcdArgs = [string]$Action.args
                if ($bcdArgs -match '^/deletevalue\s+(\S+)$') {
                    $v = Get-BcdValue '{current}' $Matches[1]; $state = ($null -eq $v); $text = ('{0}={1}' -f $Matches[1],$(if ($null -eq $v) { 'not set' } else { $v }))
                } elseif ($bcdArgs -match '^/set\s+(\{[^}]+\})\s+(\S+)\s+(\S+)$') {
                    $want = $Matches[3]; $name = $Matches[2]; $v = Get-BcdValue $Matches[1] $name; $state = ([string]$v -ieq $want); $text = ('{0}={1} (want {2})' -f $name,$v,$want)
                } elseif ($bcdArgs -match '^/timeout\s+(\d+)$') {
                    $want = $Matches[1]; $v = Get-BcdValue '{bootmgr}' 'timeout'; $state = ([string]$v -eq $want); $text = ('timeout={0} (want {1})' -f $v,$want)
                }
            }
        }
    } catch { $state = $null; $text = ('Could not read: {0}' -f $_.Exception.Message) }
    return @{ State=$state; Text=$text }
}

function Get-TweakLiveState {
    param($Tweak)
    $states = @(); $texts = @()
    foreach ($a in @($Tweak.Apply)) {
        $r = Get-ActionLiveState $a
        if ($r.Text) { $texts += $r.Text }
        if ($null -ne $r.State) { $states += [bool]$r.State }
    }
    $state = if ($states.Count) { -not ($states -contains $false) } else { $null }
    return @{ State=$state; Text=($texts -join '; ') }
}

function Get-BitLockerState {
    try {
        $sh = New-Object -ComObject Shell.Application
        $v = $sh.NameSpace($env:SystemDrive + '\').Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if ($null -eq $v) { return $null }
        return [int]$v
    } catch { return $null }
}
function Initialize-DetectionCaches {
    $script:SvcStartCache = @{}
    try {
        $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services')
        foreach ($n in $root.GetSubKeyNames()) { $k = $root.OpenSubKey($n); if ($k) { try { $v = $k.GetValue('Start'); if ($null -ne $v) { $script:SvcStartCache[$n] = [int]$v } } finally { $k.Close() } } }
        $root.Close()
    } catch { $script:SvcStartCache = $null }
    $script:PowerIndexCache = @{}
    try {
        $sub = ''; $cur = $null
        foreach ($line in @(& powercfg.exe /qh SCHEME_CURRENT 2>$null)) {
            if ($line -match '^\s*Subgroup GUID:\s*([0-9a-fA-F-]{36})') { $sub = $Matches[1].ToLowerInvariant(); $cur = $null; continue }
            if ($line -match '^\s*Power Setting GUID:\s*([0-9a-fA-F-]{36})') { $cur = @{ guid=$Matches[1].ToLowerInvariant(); sub=$sub; alias=''; ac=$null; dc=$null }; $script:PowerIndexCache[$cur.guid] = $cur; continue }
            if (-not $cur) { if ($line -match '^\s*GUID Alias:\s*(\S+)') { $script:PowerIndexCache['SUBALIAS|' + $Matches[1].ToUpperInvariant()] = $sub }; continue }
            if ($line -match '^\s*GUID Alias:\s*(\S+)') { $cur.alias = $Matches[1].ToUpperInvariant(); $script:PowerIndexCache[$cur.alias] = $cur; continue }
            if ($line -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $cur.ac = [Convert]::ToInt32($Matches[1],16); continue }
            if ($line -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $cur.dc = [Convert]::ToInt32($Matches[1],16) }
        }
        if (-not @($script:PowerIndexCache.Values | Where-Object { $_ -is [hashtable] -and $null -ne $_.ac }).Count) { $script:PowerIndexCache = $null }
    } catch { $script:PowerIndexCache = $null }
    try { $script:NetPropCache = @(Get-NetAdapterAdvancedProperty -AllProperties -ErrorAction Stop) } catch { $script:NetPropCache = $null }
}
function Clear-DetectionCaches { $script:SvcStartCache = $null; $script:PowerIndexCache = $null; $script:NetPropCache = $null }
function Get-RegValueFast {
    param([string]$Path,[string]$Name)
    $hive = $null; $sub = $null
    if ($Path -match '^(?i)(HKLM|HKEY_LOCAL_MACHINE):?\\(.*)$') { $hive = [Microsoft.Win32.Registry]::LocalMachine; $sub = $Matches[2] }
    elseif ($Path -match '^(?i)(HKCU|HKEY_CURRENT_USER):?\\(.*)$') { $hive = [Microsoft.Win32.Registry]::CurrentUser; $sub = $Matches[2] }
    elseif ($Path -match '^(?i)(?:Microsoft\.PowerShell\.Core\\)?Registry::(HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)\\(.*)$') { $hive = if ($Matches[1] -match 'LOCAL') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }; $sub = $Matches[2] }
    if (-not $hive) { try { $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name; return @{ Exists=$true; Value=$v } } catch { return @{ Exists=$false; Value=$null } } }
    $k = $hive.OpenSubKey($sub)
    if (-not $k) { return @{ Exists=$false; Value=$null } }
    try {
        if (@($k.GetValueNames()) -notcontains $Name) { return @{ Exists=$false; Value=$null } }
        return @{ Exists=$true; Value=$k.GetValue($Name,$null,'DoNotExpandEnvironmentNames') }
    } finally { $k.Close() }
}
function Get-TweakDetection {
    param($Tweaks,$Env,$Shared)
    $out = @{}
    $allTasks = @()
    if ($Shared) { $allTasks = @($Shared.Tasks); $script:SvcStartCache = $Shared.Svc; $script:PowerIndexCache = $Shared.Power; $script:NetPropCache = $Shared.Net }
    else { try { $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue } catch { }; Initialize-DetectionCaches }
    $script:OptionalFeatureStates = $null
    $netReason = 'Not supported by this adapter'
    $netSetup = Get-Service -Name 'NetSetupSvc' -ErrorAction SilentlyContinue
    if ($netSetup -and $netSetup.Status -ne 'Running') {
        if ((Get-ServiceStartValue 'NetSetupSvc') -eq 4) { $netReason = 'Network Setup Service is disabled (Fixes > Network)' }
        else { try { Start-Service -Name 'NetSetupSvc' -ErrorAction Stop } catch { } }
    }
 
    foreach ($t in $Tweaks) {
      try {
        $present = $true; $reason = ''; $applied = $false; $statusText = ''
        $d = $t.Detect
        if ($d -and [int]$Env.Build -gt 0 -and (($d.minBuild -and [int]$Env.Build -lt [int]$d.minBuild) -or ($d.maxBuild -and [int]$Env.Build -gt [int]$d.maxBuild))) {
            $out[$t.Id] = @{ Present=$false; Applied=$false; Reason='Not available on this Windows build'; Status=''; Live=$false; Evidence='' }
            continue
        }
        if ($t.Type -eq 'info') {
            if ($d -and $d.kind -eq 'vendor') {
                $hit = if ($d.ContainsKey('cpu') -and $d.cpu) { $Env.CpuVendor -eq $d.value } else { $Env.GpuVendors -contains $d.value }
                $present = [bool]$hit; if (-not $present) { $reason = 'Not detected' }
            } elseif ($d -and $d.kind -eq 'game') {
                $present = [bool](Test-GameInstalled -Name $d.name); if (-not $present) { $reason='Not installed' }
            } elseif ($d -and $d.kind -eq 'anyPath') {
                $present = [bool]@($d.paths | Where-Object { Test-Path $_ }).Count; if (-not $present) { $reason='Not installed' }
            } elseif ($d -and $d.kind -eq 'appInstalled') {
                $present = [bool](Test-InstalledAppName -Name $d.name); if (-not $present) { $reason='Not installed' }
            } elseif ($d -and $d.kind -eq 'service') {
                $present = Test-ServiceExists $d.name; if (-not $present) { $reason='Not present' }
            } elseif ($d -and $d.kind -eq 'serviceAny') {
                $names=@($d.names | ForEach-Object { Resolve-ServiceNames $_ } | Select-Object -Unique); $present=($names.Count -gt 0); if(-not $present){$reason='Not present'}
            } elseif ($d -and $d.kind -eq 'boardVendor') {
                try { $board=Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1; $present=[bool]($board.Manufacturer -and $board.Manufacturer -notmatch '(?i)Microsoft|Virtual|Unknown'); if($present){$statusText=[string]$board.Manufacturer; $biosHint=Get-BoardInstallerHint ([string]$board.Manufacturer); if($biosHint){$statusText=('{0}: {1}' -f $board.Manufacturer,$biosHint)}} } catch { $present=$false }; if(-not $present){$reason='Board utility option not detected'}
            } elseif ($d -and $d.kind -eq 'recognizedGames') {
                $present = [bool]@($t.Apply).Count
                if (-not $present) { $reason = 'Windows has not recognised any installed games yet (launch a game once)' }
                elseif ($d.multiGpu) {
                    $realGpus = @($Env.Gpus | Where-Object { $_.Name -notmatch '(?i)Basic Display|Basic Render|Remote|Virtual|Parsec|Meta Virtual|Mirage' })
                    if ($realGpus.Count -lt 2) { $present = $false; $reason = 'Only one graphics adapter, so there is nothing to choose between' }
                }
            } elseif ($d -and $d.kind -eq 'memoryConfig') {
                $mem = $null; try { $mem = Get-MemoryConfigReport } catch { }
                $present = [bool]$mem
                if (-not $present) { $reason = 'Memory details not available' }
                else { $statusText = if (@($mem.Issues).Count) { ('{0}. {1}' -f $mem.Summary,(@($mem.Issues) -join ' ')) } else { ('{0}. Dual channel at the rated speed: nothing to change.' -f $mem.Summary) } }
            } elseif ($d -and $d.kind -eq 'gamesOnHdd') {
                $hdd = @(); if ($Env.HasHdd) { try { $hdd = @(Get-GamesOnHdd) } catch { } }
                $present = [bool]$hdd.Count
                if (-not $present) { $reason = 'No recognised games are installed on a hard disk drive' }
                else { $statusText = ('Installed on a hard disk drive: {0}.' -f ($hdd -join ', ')) }
            } elseif ($d -and $d.kind -eq 'balancedPlan') {
                $active = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction SilentlyContinue).ActivePowerScheme
                $present = ($active -eq '381b4222-f694-41f0-9685-ff5bb260df2e')
                if (-not $present) { $reason = 'Power mode only applies to the Balanced power plan; Windows ignores it on High performance, Ultimate Performance and custom plans' }
            } elseif ($d -and $d.kind -eq 'igpuDgpu') {
                $igpuPattern = '(?i)Radeon\(TM\) Graphics$|Radeon Graphics$|Radeon\(TM\) \d{3}M|UHD Graphics|Iris|Intel\(R\) Graphics|Arc\(TM\) Graphics$|HD Graphics'
                $igpus = @($Env.Gpus | Where-Object { $_.Name -match $igpuPattern })
                $dgpus = @($Env.Gpus | Where-Object { $_.Name -notmatch $igpuPattern -and $_.Vendor -in 'NVIDIA','AMD','Intel' })
                $present = ($igpus.Count -gt 0 -and $dgpus.Count -gt 0)
                if (-not $present) { $reason = 'No integrated plus dedicated graphics pair detected' }
                else {
                    $mainOnIgpu = [bool]@($igpus | Where-Object { $_.IsMain }).Count -and -not [bool]@($dgpus | Where-Object { $_.IsMain }).Count
                    $statusText = if ($mainOnIgpu -and -not $Env.IsLaptop) { ('Your monitor is connected to the motherboard ({0}). Plug it into the graphics card ({1}) for full game performance.' -f $igpus[0].Name,$dgpus[0].Name) }
                                  elseif ($Env.IsLaptop) { ('Laptop with {0} and {1}: switching between them is normal; keep both enabled.' -f $igpus[0].Name,$dgpus[0].Name) }
                                  else { ('Monitor is on the graphics card ({0}); the integrated {1} is enabled but idle.' -f $dgpus[0].Name,$igpus[0].Name) }
                }
            } elseif ($d -and $d.kind -eq 'missingDrivers') {
                $present = $true
                try {
                    $noDriver = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -eq 28 -and [string]$_.PNPDeviceID -notmatch '^(SWD|ROOT)\\' })
                    if (-not $noDriver.Count) { $statusText = 'Every present device has a driver.' }
                    else {
                        $names = @($noDriver | ForEach-Object { if ($_.Name) { [string]$_.Name } else { [string]$_.PNPDeviceID } } | Select-Object -Unique)
                        $hint = ''
                        if (@($noDriver | Where-Object { [string]$_.PNPDeviceID -match 'VEN_1022|AMDI' }).Count) { $hint = ' AMD chipset parts are missing: install AMD Chipset Software.' }
                        elseif (@($noDriver | Where-Object { [string]$_.PNPDeviceID -match 'VEN_8086|INT[0-9A-F]{4}|INTC' }).Count) { $hint = ' Intel platform parts are missing: install the Intel Chipset INF, MEI and Serial IO drivers.' }
                        $statusText = ('{0} device(s) without a driver: {1}.{2}' -f $names.Count,($names -join ', '),$hint)
                    }
                } catch { $statusText = 'Could not read the device list.' }
            } elseif ($d -and $d.kind -in @('file','path')) {
                $present = Test-Path $d.path; if (-not $present) { $reason='Not installed' }
            } elseif ($d -and $d.kind -eq 'pnpPresent') {
                try { $present=[bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='No detected devices'}
            } elseif ($d -and $d.kind -eq 'ghostPnp') {
                try { $present=[bool](Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Present -eq $false } | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='No ghost devices'}
            } elseif ($d -and $d.kind -eq 'pnpPatternAny') {
                try { $devs=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue); $present=[bool]@($devs | Where-Object { $name=[string]$_.FriendlyName; $d.patterns | Where-Object { $name -like $_ } }).Count } catch { $present=$false }; if(-not $present){$reason='Device not detected'}
            } elseif ($d -and $d.kind -eq 'gpuAudioDevice') {
                try { $present=[bool](Get-PnpDevice -Class 'MEDIA' -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '(?i)NVIDIA|AMD|Radeon|Display Audio|HDMI|DisplayPort|Intel.*Audio' } | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='Display audio not detected'}
            } elseif ($d -and $d.kind -eq 'pnpClassAny') {
                try { $present=[bool](Get-PnpDevice -Class $d.classes -PresentOnly -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='Device class not present'}
            } elseif ($d -and $d.kind -eq 'bitlockerSupported') {
                $present = ($null -ne (Get-BitLockerState)); if(-not $present){$reason='BitLocker is not available for this system drive'}
            } elseif ($d -and $d.kind -eq 'secureBoot') {
                try {
                    $secure=[bool](Confirm-SecureBootUEFI -ErrorAction Stop); $present=$true
                    $tpm=Get-Tpm -ErrorAction SilentlyContinue
                    $statusText=('Secure Boot {0}; TPM {1}' -f $(if($secure){'on'}else{'off'}),$(if($tpm -and $tpm.TpmPresent){'ready'}else{'not ready'}))
                } catch { $present=$false }; if(-not $present){$reason='UEFI Secure Boot status unavailable'}
            } elseif ($d -and $d.kind -eq 'systemProtection') {
                if ($d.name -eq 'SmartScreen') {
                    $present=$true
                    $ss=try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction Stop).SmartScreenEnabled } catch { 'Default' }
                    $uac=try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA -eq 1 } catch { $true }
                    $statusText=('SmartScreen {0}; UAC {1}' -f $ss,$(if($uac){'on'}else{'off'}))
                } elseif ($d.name -eq 'VBS') {
                    try {
                        $dg=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
                        $present=$true
                        $vbs=if($dg.VirtualizationBasedSecurityStatus -eq 2){'running'}elseif($dg.VirtualizationBasedSecurityStatus -eq 1){'enabled'}else{'off'}
                        $hvci=if(@($dg.SecurityServicesRunning) -contains 2){'on'}else{'off'}
                        $statusText=("VBS {0}; Memory Integrity {1}" -f $vbs,$hvci)
                    } catch { $present=$false }
                }
                if(-not $present){$reason='Protection feature not present'}
            }
            $out[$t.Id] = @{ Present=$present; Applied=$false; Reason=$reason; Status=$statusText }
            continue
        }
        if ($null -ne $d) {
            switch ($d.kind) {
                'service'    {
                    $present = Test-ServiceExists $d.name
                    if (-not $present) { $reason='Not present' }
                    else {
                        $expectedStart = switch ([string]$d.start) { 'Automatic' {2} 'Manual' {3} default {4} }
                        $currentStart = Get-ServiceStartValue $d.name
                        $applied = Test-ServiceStartMet $currentStart $expectedStart
                        if ($applied -and [int]$currentStart -ne $expectedStart) { $statusText = 'Disabled (stricter than Manual)' }
                    }
                }
                'serviceAny' {
                    $names=@($d.names | ForEach-Object { Resolve-ServiceNames $_ } | Select-Object -Unique)
                    $present=($names.Count -gt 0)
                    if(-not $present){$reason='Not present'} else {
                        $expectedStart = switch ([string]$d.start) { 'Automatic' {2} 'Manual' {3} default {4} }
                        $done = @($names | Where-Object { Test-ServiceStartMet (Get-ServiceStartValue $_) $expectedStart }).Count
                        $applied = ($done -eq $names.Count)
                        if ($done -gt 0 -and -not $applied) { $statusText = ('{0} of {1} applied' -f $done,$names.Count) }
                    }
                }
                'vendorSoftware' {
                    $vsNames = @($d.services | ForEach-Object { Resolve-ServiceNames $_ } | Select-Object -Unique)
                    $vsTasks = @($allTasks | Where-Object { $d.tasks -contains ($_.TaskPath + $_.TaskName) })
                    $vsTotal = $vsNames.Count + $vsTasks.Count
                    $present = ($vsTotal -gt 0)
                    if (-not $present) { $reason = 'Not installed' } else {
                        $vsDone = @($vsNames | Where-Object { Test-ServiceStartMet (Get-ServiceStartValue $_) 4 }).Count + @($vsTasks | Where-Object { $_.State -eq 'Disabled' }).Count
                        $applied = ($vsDone -eq $vsTotal)
                        if ($vsDone -gt 0 -and -not $applied) { $statusText = ('{0} of {1} applied' -f $vsDone,$vsTotal) }
                    }
                }
                'task'       { $present = [bool]($allTasks | Where-Object { $_.TaskPath -eq $d.path -and $_.TaskName -eq $d.name }); if(-not $present){$reason='Not present'} }
                'taskAny'    { $found=@($allTasks | Where-Object { $p=$_.TaskPath; $d.paths | Where-Object { $p -like "$_*" } }); $present=($found.Count -gt 0); if(-not $present){$reason='Not present'} else { $applied = -not ($found | Where-Object { $_.State -ne 'Disabled' }) } }
                'taskAnyName' { $found=@($allTasks | Where-Object { $d.names -contains $_.TaskName }); $present=($found.Count -gt 0); if(-not $present){$reason='Not present'} else { $applied = -not ($found | Where-Object { $_.State -ne 'Disabled' }) } }
                'taskAnyNamePattern' { $found=@($allTasks | Where-Object { $taskName=$_.TaskName; $d.patterns | Where-Object { $taskName -like $_ } }); $present=($found.Count -gt 0); if(-not $present){$reason='Not present'} else { $applied = -not ($found | Where-Object { $_.State -ne 'Disabled' }) } }
                'appx'       { $present = [bool](Get-AppxPackage -Name $d.name -ErrorAction SilentlyContinue); if(-not $present){$reason='Not present'} else {$state=Test-TweakRegistryActionsApplied $t; if($null -ne $state){$applied=[bool]$state} } }
                'registry'   { $present=$true; $state=Test-TweakRegistryActionsApplied $t; if($null -ne $state){$applied=[bool]$state} }
                'runkey'     { $present = [bool](Get-RunKeyEntry $d.name); if(-not $present){$reason='Not present'} else { $applied = Test-RunKeyDisabled $d.name } }
                'runkeyAny'  { $found=@($d.names | Where-Object { Get-RunKeyEntry $_ }); $present=($found.Count -gt 0); if(-not $present){$reason='Not present'} else { $applied = -not @($found | Where-Object { -not (Test-RunKeyDisabled $_) }).Count } }
                'file'       { $present = Test-Path $d.path; if(-not $present){$reason='Not present'} }
                'path'       { $present = Test-Path $d.path; if(-not $present){$reason='Not present'} }
                'anyPath'    { $present = [bool]@($d.paths | Where-Object { Test-Path $_ }).Count; if(-not $present){$reason='Not present'} else {$state=Test-TweakRegistryActionsApplied $t; if($null -ne $state){$applied=[bool]$state}} }
                'appJsonSetting' {
                    $present=[bool]@($d.paths | Where-Object { Test-Path $_ }).Count
                    if(-not $present){$reason='Not installed'} elseif(Test-Path -LiteralPath $d.configPath){
                        try { $json=Get-Content -LiteralPath $d.configPath -Raw -ErrorAction Stop | ConvertFrom-Json; $property=$json.PSObject.Properties[[string]$d.name]; if($property){$applied=([string]$property.Value -eq [string]$d.value)} } catch { $applied=$false }
                    }
                }
                'appInstalled' { $present=[bool](Test-InstalledAppName -Name $d.name); if(-not $present){$reason='Not installed'} }
                'vendor'     { $hit = if ($d.ContainsKey('cpu') -and $d.cpu) { $Env.CpuVendor -eq $d.value } else { $Env.GpuVendors -contains $d.value }; $present=[bool]$hit; if(-not $present){$reason='Not detected'} }
                'svchost'    { try { $v=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -ErrorAction Stop).SvcHostSplitThresholdInKB; $applied = ($v -ge $Env.SvcThreshold) } catch { $applied=$false } }
                'netadapter' { $ad=@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { if($d.type -eq 'wifi'){ ($_.PhysicalMediaType -match '802\.11|Wireless') -or ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN') } else { ($_.PhysicalMediaType -eq '802.3') -or ($_.Name -match 'Ethernet') -or ($_.InterfaceDescription -match 'Ethernet') } }); $present=($ad.Count -gt 0); if(-not $present){$reason='Not present'} else { $applied = -not @($ad | Where-Object { $_.Status -ne 'Disabled' }) } }
                { $_ -in 'netProperty','netPropertyAny' } { try { $present = [bool]@(Get-MatchingNetProperties $d).Count; if(-not $present){$reason=$netReason} } catch { $present=$false; $reason=$netReason } }
                'netFeature' { try { switch($d.name){ 'rss' {$present=[bool](Get-NetAdapterRss -ErrorAction SilentlyContinue | Select-Object -First 1)} 'rsc' {$present=[bool](Get-NetAdapterRsc -ErrorAction SilentlyContinue | Select-Object -First 1)} 'wake' {$present=[bool](Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue | Select-Object -First 1)} }; if(-not $present){$reason=$netReason} } catch { $present=$false; $reason=$netReason } }
                'netadapterPhysical' { try { $present=[bool](Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object -First 1); if(-not $present){$reason='Not present'} } catch { $present=$false; $reason='Not present' } }
                'unusedNetAdapter' { try { $ad=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue); $present=[bool]@($ad | Where-Object { $_.Status -ne 'Up' }).Count; if(-not $present){$reason='No disconnected physical adapters'} } catch { $present=$false; $reason='Not present' } }
                'netBinding' { try { $present=[bool](Get-NetAdapterBinding -AllBindings -ErrorAction SilentlyContinue | Where-Object { $_.ComponentID -eq $d.component } | Select-Object -First 1); if(-not $present){$reason='Not available on this adapter'} } catch { $present=$false; $reason='Not available on this adapter' } }
                'netCmdlet' { $present=[bool](Get-Command $d.name -ErrorAction SilentlyContinue); if(-not $present){$reason='Not supported by this Windows version'} }
                'appxPattern' { try { $present=[bool](Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $d.pattern } | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='Feature package not installed'} }
                'appxAny' { try { $present=[bool](Get-AppxPackage -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { $present=$false }; if(-not $present){$reason='No Store apps installed'} }
                'bitlockerOn' { $bl = Get-BitLockerState; $present = ($bl -in 1,3,4,5,6); if(-not $present){ $reason = if ($null -eq $bl) { 'BitLocker is not available for this system drive' } else { 'System drive is not encrypted' } } }
                'optionalFeature' { $features=Get-OptionalFeatureStates; $found=@($d.names | Where-Object { $features.ContainsKey($_) -and $features[$_] -in 1,2 }); $present=($found.Count -gt 0); if(-not $present){$reason='Not available on this Windows build'} else { $applied = -not @($found | Where-Object { $features[$_] -ne 2 }).Count } }
                'appxStartup' { $found=@(Get-AppxStartupStates $d.families | Where-Object { $_.State -in 0,1,2 }); $present=($found.Count -gt 0); if(-not $present){$reason='Not installed'} else { $applied = -not @($found | Where-Object { $_.State -eq 2 }).Count } }
                'game' { $present = [bool](Test-GameInstalled -Name $d.name); if(-not $present){$reason='Not installed'} }
                'powerSettingPresent' { $present = [bool](Get-PowerIndexRecord $d.setting $d.sub); if(-not $present){$reason='Not in the active power plan'} }
                'osBuild' { $present = ([int]$Env.Build -ge [int]$d.min); if(-not $present){$reason=[string]$d.reason} }
                'msiCapable' { $present = [bool]@(Get-MsiTargets).Count; if(-not $present){$reason='No MSI-capable PCI controllers found'} }
                'capability' {
                    if ($null -eq $script:CapabilityStates) { try { $script:CapabilityStates = @(Get-WindowsCapability -Online -ErrorAction Stop | Select-Object Name,State) } catch { $script:CapabilityStates = @() } }
                    $found = @($script:CapabilityStates | Where-Object { $capName = $_.Name; @($d.names | Where-Object { $capName -like ($_ + '*') }).Count })
                    $present = [bool]$found.Count
                    if (-not $present) { $reason = 'Not available on this Windows build' } else { $applied = -not @($found | Where-Object { [string]$_.State -eq 'Installed' }).Count }
                }
                'mpPreference' {
                    try {
                        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
                        $present = ([string]$mpStatus.AMRunningMode -eq 'Normal')
                        if (-not $present) { $reason = 'Microsoft Defender is not the active antivirus' }
                        else { $mpPref = Get-MpPreference -ErrorAction Stop; $applied = -not @($t.Apply | Where-Object { $_.kind -eq 'mpPreference' -and [int]$mpPref.($_.name) -ne [int]$_.value }).Count }
                    } catch { $present = $false; $reason = 'Microsoft Defender is not available' }
                }
                'mmagent' { $present = [bool](Get-Command Get-MMAgent -ErrorAction SilentlyContinue); if(-not $present){$reason='Memory Manager agent not available on this Windows edition'} }
                'runkeyAll' { $present = [bool]@(Get-StartupEntries).Count; if(-not $present){$reason='No startup entries found'} }
                'coreParkingAllowed' {
                    $gate = if ($Env.CpuX3D) { 'Ryzen X3D relies on core parking to keep games on the V-Cache die' }
                            elseif ($Env.CpuHybrid) { 'Intel hybrid CPUs rely on core parking to keep games on the P-cores' }
                            elseif ($Env.IsLaptop) { 'Laptops rely on core parking for heat and battery life' }
                            else { '' }
                    if ($gate) {
                        $r = Get-PowerIndexRecord 'CPMINCORES'
                        if ($r -and ([int]$r.ac -eq 100 -or [int]$r.dc -eq 100)) { $statusText = ('Not recommended: {0}. Untick to turn parking back on.' -f $gate) }
                        else { $present = $false; $reason = $gate }
                    }
                }
                default      { }
            }
        }
        $live = $false; $evidence = ''
        if ($present) {
            $detectKind = if ($d) { [string]$d.kind } else { '' }
            $liveState = Get-TweakLiveState $t
            $evidence = [string]$liveState.Text
            if ($detectKind -in 'service','serviceAny','vendorSoftware','taskAny','taskAnyName','taskAnyNamePattern','appJsonSetting','svchost','netadapter','runkey','runkeyAny','optionalFeature','appxStartup') { $live = $true }
            elseif ($detectKind -eq 'runkeyAll') { $applied = [bool]$liveState.State; $live = $true }
            elseif ($null -ne $liveState.State) { $applied = [bool]$liveState.State; $live = $true }
        }
        if ($present -and $d -and $d.noHdd -and $Env.HasHdd) {
            if ($applied) { $statusText = 'Not recommended with a hard disk drive installed. Untick to turn it back on.' }
            else { $present = $false; $reason = 'A hard disk drive is installed: SysMain speeds up app launches from it' }
        }
        if ($present -and $d -and $d.desktopOnly -and $Env.IsLaptop) {
            if ($applied) { $statusText = 'Not recommended on laptops (heat and battery). Untick to restore.' }
            else { $present = $false; $reason = 'Desktop only: on laptops this costs heat and battery life' }
        }
        if ($present -and $d -and $d.minRamGB -and [int]$Env.RamNominalGB -lt [int]$d.minRamGB) {
            if ($applied) { $statusText = ('Needs {0} GB of RAM or more. Untick to restore.' -f $d.minRamGB) }
            else { $present = $false; $reason = ('Needs {0} GB of RAM or more' -f $d.minRamGB) }
        }
        if ($present -and $d -and $d.gpuVendor -and @($Env.GpuVendors).Count -and -not (@($Env.GpuVendors) -contains $d.gpuVendor)) {
            if ($applied) { $statusText = ('For {0} graphics only. Untick to restore.' -f $d.gpuVendor) }
            else { $present = $false; $reason = ('No {0} graphics card detected' -f $d.gpuVendor) }
        }
        if ($present -and $d -and $d.notAmdCpu -and [string]$Env.CpuVendor -eq 'AMD') {
            if ($applied) { $statusText = 'Lowers Ryzen boost: Precision Boost clocks the busy cores highest when idle cores can sleep. Untick to restore.' }
            else { $present = $false; $reason = 'Ryzen CPUs boost highest when idle cores can sleep' }
        }
        if ($present -and $d -and $d.hybridOnly -and -not $Env.CpuHybrid) {
            if ($applied) { $statusText = 'For Intel hybrid CPUs. Untick to restore.' }
            else { $present = $false; $reason = 'Only for Intel hybrid CPUs (P-cores + E-cores)' }
        }
        $out[$t.Id] = @{ Present=$present; Applied=$applied; Reason=$reason; Status=$statusText; Live=$live; Evidence=$evidence }
      } catch {
        $out[$t.Id] = @{ Present=$true; Applied=$false; Reason=''; Status='Could not read current state'; Live=$false; Evidence=('Detection error: {0}' -f $_.Exception.Message) }
      }
    }
    Clear-DetectionCaches
    return $out
}
 
function Get-RunKeyEntry {
    param([string]$Name)
    foreach ($root in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        try { $p = Get-ItemProperty $root -ErrorAction SilentlyContinue; if ($p -and $p.PSObject.Properties.Name -contains $Name) { return @{ Root=$root; Value=$p.$Name; Approved=($root -replace '\\Run$','\Explorer\StartupApproved\Run') } } } catch { }
    }
    return $null
}

function Get-StartupEntries {
    $keep = @('SecurityHealth','Windows Defender','WindowsDefender','Riot Vanguard','FACEIT','EasyAntiCheat','BattlEye')
    $approvedRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ Key='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved="HKCU:\$approvedRoot\Run" },
        @{ Key='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved="HKLM:\$approvedRoot\Run" },
        @{ Key='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved="HKLM:\$approvedRoot\Run32" }
    )
    foreach ($s in $sources) {
        $item = Get-Item -LiteralPath $s.Key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in @($item.GetValueNames())) {
            if (-not $n -or $keep -contains $n) { continue }
            [pscustomobject]@{ Name=$n; Approved=$s.Approved }
        }
    }
    foreach ($f in @(@{ Dir=[Environment]::GetFolderPath('Startup'); Approved="HKCU:\$approvedRoot\StartupFolder" }, @{ Dir=[Environment]::GetFolderPath('CommonStartup'); Approved="HKLM:\$approvedRoot\StartupFolder" })) {
        if (-not $f.Dir) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            [pscustomobject]@{ Name=$file.Name; Approved=$f.Approved }
        }
    }
}

function Test-StartupEntryDisabled {
    param($Entry)
    try {
        $flag = (Get-ItemProperty -LiteralPath $Entry.Approved -Name $Entry.Name -ErrorAction Stop).($Entry.Name)
        return [bool]($flag -and $flag.Length -gt 0 -and ([int]$flag[0] -band 1))
    } catch { return $false }
}

function Test-RunKeyDisabled {
    param([string]$Name)
    $e = Get-RunKeyEntry $Name
    if (-not $e) { return $false }
    try {
        $flag = (Get-ItemProperty -LiteralPath $e.Approved -Name $Name -ErrorAction Stop).$Name
        return [bool]($flag -and $flag.Length -gt 0 -and ([int]$flag[0] -band 1))
    } catch { return $false }
}

function Test-GameInstalled {
    param([string]$Name)
    if ($Name -eq 'CS2') {
        try { if ((Get-ItemProperty 'HKCU:\Software\Valve\Steam\Apps\730' -Name Installed -ErrorAction Stop).Installed -eq 1) { return $true } } catch { }
        $steamRoots = @()
        try {
            $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
            if ($steam) {
                $steamRoots += $steam
                $libraryFile = Join-Path $steam 'steamapps\libraryfolders.vdf'
                if (Test-Path $libraryFile) {
                    $libraryText = Get-Content -LiteralPath $libraryFile -Raw
                    foreach ($match in [regex]::Matches($libraryText,'"path"\s+"([^"]+)"')) {
                        $library = [regex]::Unescape($match.Groups[1].Value)
                        if ($library) { $steamRoots += $library }
                    }
                }
            }
        } catch { }
        foreach ($root in ($steamRoots | Select-Object -Unique)) {
            if (Test-Path (Join-Path $root 'steamapps\appmanifest_730.acf')) { return $true }
        }
    } elseif ($Name -eq 'Fortnite') {
        try { $p=(Get-ItemProperty 'HKCU:\Software\Epic Games\EpicGamesLauncher\AppData\Manifests' -ErrorAction Stop).Fortnite; if($p){return $true} } catch { }
        $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        if (Test-Path $manifestDir) {
            foreach ($manifest in (Get-ChildItem -LiteralPath $manifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
                try {
                    $entry = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                    if ($entry.AppName -eq 'Fortnite' -and $entry.InstallLocation) {
                        $exe = Join-Path ([string]$entry.InstallLocation) 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
                        if (Test-Path $exe) { return $true }
                    }
                } catch { }
            }
        }
        foreach ($root in @("${env:ProgramFiles(x86)}\Epic Games","$env:ProgramFiles\Epic Games")) { if (Test-Path (Join-Path $root 'Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe')) { return $true } }
    } elseif ($Name -eq 'VALORANT') {
        $installsFile = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
        if (Test-Path $installsFile) {
            try {
                $installData = Get-Content -LiteralPath $installsFile -Raw | ConvertFrom-Json
                $valorantExe = [string]$installData.product_install_full_path.'valorant.live'
                if ($valorantExe -and (Test-Path $valorantExe)) { return $true }
            } catch { }
        }
        foreach ($root in @("$env:ProgramFiles\Riot Games","$env:ProgramFiles(x86)\Riot Games",'C:\Riot Games')) {
            if (Test-Path (Join-Path $root 'VALORANT\live\VALORANT.exe')) { return $true }
        }
    }
    return $false
}

function Test-InstalledAppName {
    param([string]$Name)
    try { if (Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$Name*" } | Select-Object -First 1) { return $true } } catch { }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try { if (Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$Name*" } | Select-Object -First 1) { return $true } } catch { }
    }
    return $false
}
 
function Invoke-Action {
    param($Action)
    $script:SvcStartCache = $null; $script:PowerIndexCache = $null; $script:NetPropCache = $null
    switch ($Action.kind) {
        'service' {
            if($Action.start -in @('Boot','System')){Write-Log ("Refused unsafe service start type {0} for {1}" -f $Action.start,$Action.name) 'Warn';return}
            foreach($serviceName in (Resolve-ServiceNames $Action.name)) {
                if (Test-Protected 'service' $serviceName) { Write-Log ("Skipped protected service {0}" -f $serviceName) 'Warn'; continue }
                [void](Set-ServiceStart -Name $serviceName -StartType $Action.start -Stop:([bool]$Action.stop))
            }
        }
        'restoreRecords' {
            $records = @($script:Journal[$Action.id])
            $failed = @()
            for ($i = $records.Count - 1; $i -ge 0; $i--) {
                if ($records[$i].untouched) { continue }
                try { Restore-OriginalRecord $records[$i] }
                catch {
                    Write-Log ("Could not restore {0}: {1}" -f $records[$i].name,$_.Exception.Message) 'Warn'
                    $failed = @($records[$i]) + $failed
                }
            }
            if ($failed.Count) {
                $script:Journal[$Action.id] = @($failed); [void](Save-Journal)
                throw ("{0} original value(s) could not be restored and were kept for another try." -f $failed.Count)
            }
            Clear-Journal $Action.id
        }
        'registry'    { Set-RegValue -Path $Action.path -Name $Action.name -Value $Action.value -Type $Action.type }
        'registryDel' { Remove-RegValue -Path $Action.path -Name $Action.name }
        'appJson' {
            if ($Action.name -eq 'enableHardwareAcceleration' -and (Get-Process -Name 'Discord' -ErrorAction SilentlyContinue)) { throw 'Close Discord before applying this preference so it does not overwrite the setting on exit.' }
            $parent=Split-Path -Parent $Action.path
            if(-not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force | Out-Null}
            if(Test-Path -LiteralPath $Action.path){
                try{$json=Get-Content -LiteralPath $Action.path -Raw -ErrorAction Stop | ConvertFrom-Json}catch{throw "Could not read app settings file: $($Action.path)"}
                if($null -eq $json){$json=[pscustomobject]@{}}
            }else{$json=[pscustomobject]@{}}
            $prop=$json.PSObject.Properties[[string]$Action.name]
            if($prop){$prop.Value=$Action.value}else{$json | Add-Member -NotePropertyName ([string]$Action.name) -NotePropertyValue $Action.value}
            $jsonText=$json | ConvertTo-Json -Depth 30
            [System.IO.File]::WriteAllText($Action.path,$jsonText,[System.Text.UTF8Encoding]::new($false))
        }
        'appJsonDel' {
            if(Test-Path -LiteralPath $Action.path){
                try{$json=Get-Content -LiteralPath $Action.path -Raw -ErrorAction Stop | ConvertFrom-Json}catch{throw "Could not read app settings file: $($Action.path)"}
                if($json){$json.PSObject.Properties.Remove([string]$Action.name); $jsonText=$json | ConvertTo-Json -Depth 30; [System.IO.File]::WriteAllText($Action.path,$jsonText,[System.Text.UTF8Encoding]::new($false))}
            }
        }
        'runkey' {
            $e = Get-RunKeyEntry $Action.name
            if ($e) {
                $flag = if ($Action.enable) { 2 } else { 3 }
                Set-RegValue -Path $e.Approved -Name $Action.name -Value ([byte[]]@($flag,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
            }
        }
        'taskFolder' {
            $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like ("{0}*" -f $Action.path) }
            foreach ($tk in $tasks) {
                try {
                    if ($Action.enable) { Enable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null }
                    else                { Disable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null }
                } catch { }
            }
        }
        'task' {
            try {
                if ($Action.enable) { Enable-ScheduledTask -TaskPath $Action.path -TaskName $Action.name -ErrorAction Stop | Out-Null }
                else                { Disable-ScheduledTask -TaskPath $Action.path -TaskName $Action.name -ErrorAction Stop | Out-Null }
            } catch { }
        }
        'taskNamePattern' {
            $tasks=Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $taskName=$_.TaskName; $Action.patterns | Where-Object { $taskName -like $_ } }
            foreach ($tk in $tasks) {
                try { if ($Action.enable) { Enable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null } else { Disable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null } }
                catch { Write-Log ("Could not change scheduled task {0}{1}." -f $tk.TaskPath,$tk.TaskName) 'Warn' }
            }
        }
        'appx' {
            $packages = @(Get-AppxPackage -Name $Action.name -ErrorAction Stop)
            if (-not $packages.Count) { throw "Store app is no longer installed for this user: $($Action.name)" }
            foreach ($package in $packages) {
                if ($package.Name -eq 'Microsoft.WindowsStore' -and -not [bool]$Action.AllowUnsupportedStoreRemoval) { throw 'Removing the Microsoft Store app is not supported by Microsoft.' }
                if ($package.NonRemovable -or $package.SignatureKind -eq 'System') { throw "Windows marks this package as a system or non-removable app: $($package.Name)" }
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            }
            if ([bool]$Action.provisioned) {
                foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Action.name })) {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null; Write-Log ("Removed the provisioned copy of {0}, so new user accounts do not get it." -f $Action.name) 'Info' }
                    catch { Write-Log ("Could not remove the provisioned copy of {0}: {1}" -f $Action.name,$_.Exception.Message) 'Warn' }
                }
            }
        }
        'optionalFeature' {
            $features = Get-OptionalFeatureStates
            try {
                foreach ($n in @($Action.names | Where-Object { $features.ContainsKey($_) -and $features[$_] -in 1,2 })) {
                    if ($features[$n] -eq $(if ($Action.enable) { 1 } else { 2 })) { continue }
                    $result = if ($Action.enable) { Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop }
                              else { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart -ErrorAction Stop }
                    if ($result -and $result.RestartNeeded) { Write-Log ("{0} finishes changing after a restart." -f $n) 'Warn' }
                }
            } finally { $script:OptionalFeatureStates = $null }
        }
        'appxStartup' {
            foreach ($item in @(Get-AppxStartupStates $Action.families)) {
                if ($Action.enable -and $item.State -eq 1) { Set-RegValue -Path $item.Path -Name 'State' -Value 2 -Type DWord }
                elseif (-not $Action.enable -and $item.State -eq 2) { Set-RegValue -Path $item.Path -Name 'State' -Value 1 -Type DWord }
            }
        }
        'bcdedit' {
            $bcdArgs = [string]$Action.args
            if ($bcdArgs -match '^/deletevalue\s+(\S+)$' -and $null -eq (Get-BcdValue '{current}' $Matches[1])) { return }
            if ($bcdArgs -match '^/set\s+(\{[^}]+\})\s+(\S+)\s+(\S+)$' -and [string](Get-BcdValue $Matches[1] $Matches[2]) -ieq $Matches[3]) { return }
            Suspend-BitLockerForBootChange
            try { Start-Process -FilePath 'bcdedit.exe' -ArgumentList $Action.args -NoNewWindow -Wait -ErrorAction Stop } catch { if (-not $Action.ignore) { throw } }
        }
        'svchost' {
            if ($script:Env.SvcThreshold -gt 0) {
                Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value $script:Env.SvcThreshold -Type DWord
            }
        }
        'netadapter' {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                if ($Action.type -eq 'wifi') { ($_.PhysicalMediaType -match '802\.11|Wireless') -or ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN') }
                else { ($_.PhysicalMediaType -eq '802.3') -or ($_.Name -match 'Ethernet') -or ($_.InterfaceDescription -match 'Ethernet') }
            }
            foreach ($ad in $adapters) {
                try {
                    if ($Action.enable) { Enable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue }
                    else                { Disable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue }
                } catch { }
            }
        }
        'nagle' {
            $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
                if ($Action.enable) { Set-RegValue -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord; Set-RegValue -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord }
                else { Remove-RegValue -Path $_.PSPath -Name 'TcpAckFrequency'; Remove-RegValue -Path $_.PSPath -Name 'TCPNoDelay' }
            }
        }
        'netRss' { Get-NetAdapterRss -ErrorAction SilentlyContinue | ForEach-Object { try { Set-NetAdapterRss -Name $_.Name -Enabled ([bool]$Action.enable) -ErrorAction Stop } catch { } } }
        'netRsc' { Get-NetAdapterRsc -ErrorAction SilentlyContinue | ForEach-Object { try { Set-NetAdapterRsc -Name $_.Name -IPv4Enabled ([bool]$Action.enable) -IPv6Enabled ([bool]$Action.enable) -ErrorAction Stop } catch { } } }
        'netRssProfile' { Get-NetAdapterRss -ErrorAction SilentlyContinue | ForEach-Object { try { Set-NetAdapterRss -Name $_.Name -Profile ([string]$Action.profile) -BaseProcessorNumber ([byte]$Action.base) -NumberOfReceiveQueues ([uint32]$Action.queues) -ErrorAction Stop } catch { Write-Log ("Adapter {0} rejected the requested RSS layout: {1}" -f $_.Name,$_.Exception.Message) 'Warn' } } }
        'netAdvancedProperty' {
            foreach ($property in @(Get-MatchingNetProperties $Action)) {
                $target = Resolve-NetDisplayValue $property $Action
                if ($null -eq $target) { Write-Log ("Adapter {0}: {1} has no choice matching '{2}'; left at {3}." -f $property.Name,$property.DisplayName,$Action.value,$property.DisplayValue) 'Warn'; continue }
                if ([string]$property.DisplayValue -eq $target) { continue }
                try { Set-NetAdapterAdvancedProperty -Name $property.Name -DisplayName $property.DisplayName -DisplayValue $target -NoRestart -ErrorAction Stop }
                catch { Write-Log ("Adapter {0} does not accept {1}={2}" -f $property.Name,$property.DisplayName,$target) 'Warn' }
            }
        }
        'netAdvancedPropertyReset' {
            $props = @(Get-MatchingNetProperties $Action)
            foreach ($property in $props) {
                try { Reset-NetAdapterAdvancedProperty -Name $property.Name -RegistryKeyword $property.RegistryKeyword -NoRestart -ErrorAction Stop }
                catch { Write-Log ("Could not reset {0} on {1} to the driver default." -f $property.DisplayName,$property.Name) 'Warn' }
            }
        }
        'netAdvancedPropertyMax' {
            Get-MatchingNetProperties $Action | ForEach-Object {
                $property = $_
                $target = Get-NetPropertyMaxValue $property
                if ($null -eq $target) { Write-Log ("No maximum value was advertised for {0} on {1}." -f $property.DisplayName,$property.Name) 'Warn'; return }
                try { Set-NetAdapterAdvancedProperty -Name $property.Name -DisplayName $property.DisplayName -DisplayValue $target -NoRestart -ErrorAction Stop }
                catch { Write-Log ("Could not set {0} to its advertised maximum on {1}." -f $property.DisplayName,$property.Name) 'Warn' }
            }
        }
        'netPower' { $mode=[string]$Action.value; Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { try { Set-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket $mode -WakeOnPattern $mode -ErrorAction Stop } catch { } } }
        'netbios' { $value=[uint32]$Action.value; Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction SilentlyContinue | ForEach-Object { try { Invoke-CimMethod -InputObject $_ -MethodName SetTcpipNetbios -Arguments @{TcpipNetbiosOptions=$value} -ErrorAction Stop | Out-Null } catch { Write-Log ("Could not change NetBIOS on adapter {0}." -f $_.Description) 'Warn' } } }
        'dnsDoh' {
            if ($Action.value -eq 'Default') { Invoke-Action @{kind='setDns';servers=$null}; return }
            $servers = if ($Action.value -eq 'Cloudflare') { @('1.1.1.1','1.0.0.1') } else { @('8.8.8.8','8.8.4.4') }
            $template = if ($Action.value -eq 'Cloudflare') { 'https://cloudflare-dns.com/dns-query' } else { 'https://dns.google/dns-query' }
            foreach ($server in $servers) {
                try {
                    $existing = Get-DnsClientDohServerAddress -ServerAddress $server -ErrorAction SilentlyContinue
                    if ($existing) { Set-DnsClientDohServerAddress -ServerAddress $server -DohTemplate $template -AutoUpgrade $true -AllowFallbackToUdp $true -ErrorAction Stop | Out-Null }
                    else { Add-DnsClientDohServerAddress -ServerAddress $server -DohTemplate $template -AutoUpgrade $true -AllowFallbackToUdp $true -ErrorAction Stop | Out-Null }
                } catch { throw ("Could not register DNS-over-HTTPS for {0}: {1}" -f $server,$_.Exception.Message) }
            }
            Invoke-Action @{kind='setDns';servers=$servers}
        }
        'deliveryBandwidth' {
            $path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
            if ($Action.value -eq 'Default') { Remove-RegValue -Path $path -Name 'DOPercentageMaxBackgroundBandwidth' }
            else { $percent=[int]($Action.value -replace '%',''); Set-RegValue -Path $path -Name 'DOPercentageMaxBackgroundBandwidth' -Value $percent -Type 'DWord' }
        }
        'teredo' { if($Action.enable){ & netsh.exe interface teredo set state type=default | Out-Null }else{ & netsh.exe interface teredo set state disabled | Out-Null } }
        'tcpAutoTune' { $value=[string]$Action.value; if($value -eq 'Default'){ $value='normal' }; & netsh.exe int tcp set global autotuninglevel=$value | Out-Null }
        'dnsNegative' { if($Action.value -eq 'Default'){ Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'NegativeCacheTime' } else { Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'NegativeCacheTime' -Value ([int]$Action.value) -Type DWord } }
        'powerValue' { $alias=[string]$Action.alias; $value=[string]$Action.value; if($value -eq 'Default'){ return }; powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR $alias $value 2>$null; powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR $alias $value 2>$null; powercfg -S SCHEME_CURRENT 2>$null }
        'gameMode' { if($Action.value -eq 'Default'){ Remove-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled'; Remove-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' } else { $v=[int]($Action.value -eq 'On'); Set-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value $v -Type DWord; Set-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value $v -Type DWord } }
        'hardwareGpu' { if($Action.value -eq 'Default'){Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'}else{$v=[int]$Action.value;Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value $v -Type DWord} }
        'setDns' { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { try { if($Action.servers){Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $Action.servers -ErrorAction Stop}else{Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction Stop} } catch{} } }
        'setCoreParking' { if($Action.park -eq 'Default'){return}; $min=if([bool]$Action.park){0}else{100}; powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES $min 2>$null; powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES $min 2>$null; powercfg -S SCHEME_CURRENT 2>$null }
        'amdUlps' {
            foreach ($k in @(Get-AmdDisplayKeys)) { Set-RegValue -Path $k -Name 'EnableUlps' -Value ([int][bool]$Action.enable) -Type DWord }
        }
        'powerSetting' {
            if ([string]$Action.value -eq 'Default') {
                $def = Get-PowerDefaultIndex $Action.sub $Action.setting
                if (-not $def) { Write-Log ("{0}: the active power plan has no stored Windows default; left unchanged." -f $Action.label) 'Warn'; return }
                $ac = $def.ac; $dc = $def.dc
            } else { $ac = [int]$Action.value; $dc = [int]$Action.value }
            & powercfg.exe -setacvalueindex SCHEME_CURRENT $Action.sub $Action.setting $ac 2>$null
            if (-not $Action.acOnly -or [string]$Action.value -eq 'Default') { & powercfg.exe -setdcvalueindex SCHEME_CURRENT $Action.sub $Action.setting $dc 2>$null }
            & powercfg.exe -S SCHEME_CURRENT 2>$null
        }
        'mmagent' {
            $feature = @{}; $feature[[string]$Action.feature] = $true
            if ($Action.enable) { Enable-MMAgent @feature -ErrorAction Stop } else { Disable-MMAgent @feature -ErrorAction Stop }
        }
        'runkeyAll' {
            $flag = if ($Action.enable) { 2 } else { 3 }
            foreach ($e in @(Get-StartupEntries)) {
                Set-RegValue -Path $e.Approved -Name $e.Name -Value ([byte[]]@($flag,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
            }
        }
        'usbPower' {
            $want = [bool]$Action.enable
            $done = $false
            try { Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop | ForEach-Object { try { Set-CimInstance -InputObject $_ -Property @{ Enable = $want } -ErrorAction Stop; $done = $true } catch {} } } catch {}
            if (-not $done) { Get-WmiObject -Namespace 'root\wmi' -Class MSPower_DeviceEnable -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Enable = $want; [void]$_.Put() } catch {} } }
        }
        'hostsBlock' {
            $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
            $startMark = '# RionTool-telemetry-start'; $endMark = '# RionTool-telemetry-end'
            $content = if (Test-Path -LiteralPath $hosts) { Get-Content -LiteralPath $hosts -Raw } else { '' }
            $content = [regex]::Replace([string]$content, ("(?s)\r?\n?{0}.*?{1}" -f [regex]::Escape($startMark),[regex]::Escape($endMark)), '')
            if ($Action.enable) {
                $body = (@($Action.domains) | ForEach-Object { "0.0.0.0 $_" }) -join "`r`n"
                $content = $content.TrimEnd() + "`r`n$startMark`r`n$body`r`n$endMark`r`n"
            }
            [IO.File]::WriteAllText($hosts, $content, (New-Object Text.ASCIIEncoding))
            & ipconfig /flushdns | Out-Null
        }
        'firewallBlock' {
            $group = 'RionTool Telemetry Block'
            Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            if ($Action.enable) {
                foreach ($svc in @($Action.services)) { try { New-NetFirewallRule -DisplayName ("Block {0} telemetry" -f $svc) -Group $group -Direction Outbound -Action Block -Service $svc -ErrorAction Stop | Out-Null } catch {} }
                foreach ($prog in @($Action.programs)) { if (Test-Path -LiteralPath $prog) { try { New-NetFirewallRule -DisplayName ("Block {0} telemetry" -f (Split-Path $prog -Leaf)) -Group $group -Direction Outbound -Action Block -Program $prog -ErrorAction Stop | Out-Null } catch {} } }
            }
        }
        'classicMenu' {
            $key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
            if ($Action.enable) {
                $inproc = "$key\InprocServer32"
                if (-not (Test-Path $inproc)) { New-Item -Path $inproc -Force | Out-Null }
                New-ItemProperty -Path $inproc -Name '(default)' -Value '' -PropertyType String -Force | Out-Null
            } elseif (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
            Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        'dxGlobal' { Set-DxGlobalSetting -Name $Action.name -Value $Action.value }
        'qosGame' {
            $qn = 'Rion DSCP ' + [IO.Path]::GetFileNameWithoutExtension([string]$Action.exe)
            $existing = Get-NetQosPolicy -Name $qn -ErrorAction SilentlyContinue
            if ($Action.enable) { if (-not $existing) { New-NetQosPolicy -Name $qn -AppPathNameMatchCondition ([IO.Path]::GetFileName([string]$Action.exe)) -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null }; Write-Log ("DSCP 46 tagging on for {0}" -f [IO.Path]::GetFileName([string]$Action.exe)) 'Info' }
            elseif ($existing) { Remove-NetQosPolicy -Name $qn -Confirm:$false -ErrorAction Stop }
        }
        'dxApp' { Set-DxAppSetting -Exe ([string]$Action.exe) -Name $Action.name -Value $Action.value }
        'powerMode' {
            if (-not (Initialize-PowerApi)) { throw 'The Windows power API is unavailable.' }
            $guid = ([string]$Action.guid).ToLowerInvariant()
            if ([RionPowrProf]::SetOverlay($guid) -ne 0) { throw ('Windows did not accept power mode {0}.' -f $guid) }
            $name = @($script:PowerModes.Keys | Where-Object { $script:PowerModes[$_] -eq $guid }) | Select-Object -First 1
            Write-Log ("Power mode set to {0}." -f $(if ($name) { $name } else { $guid })) 'Info'
        }
        'throttleApp' {
            $verb = if ($Action.exempt) { 'disable' } else { 'reset' }
            $r = Invoke-PowerCfg @('/powerthrottling',$verb,'/path',[string]$Action.exe)
            $script:ThrottleExemptCache = $null
            if ($r.ExitCode -ne 0) { throw ("powercfg /powerthrottling {0} failed for {1}: {2}" -f $verb,$Action.exe,$r.Error) }
            Write-Log ("Power throttling {0} for {1}" -f $(if ($Action.exempt) { 'turned off' } else { 'back to Windows default' }),[IO.Path]::GetFileName([string]$Action.exe)) 'Info'
        }
        'msiMode' {
            if (-not $Action.enable) { Write-Log 'MSI mode: only values Rion Tool changed are restored; devices whose driver turned MSI on are left as the driver set them.' 'Info'; return }
            foreach ($t in @(Get-MsiTargets | Where-Object { -not $Action.instance -or $_.InstanceId -eq $Action.instance })) {
                $was = (Get-ItemProperty -LiteralPath $t.Path -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
                if ([string]$was -eq '1') { Write-Log ("MSI mode already on for {0} ({1}, driver {2}); nothing changed." -f $t.Name,$t.Class,$t.Driver) 'Info'; continue }
                Set-RegValue -Path $t.Path -Name 'MSISupported' -Value 1 -Type DWord
                Write-Log ("MSI mode on for {0} ({1}, driver {2}). Restart to apply." -f $t.Name,$t.Class,$t.Driver) 'Info'
            }
        }
        'coreparking' {
            $min = if ($Action.park) { 0 } else { 100 }
            powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES $min 2>$null
            powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES $min 2>$null
            powercfg -S SCHEME_CURRENT 2>$null
        }
        'defender' {
            $defPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
            $rtp = "$defPol\Real-Time Protection"
            $spynet = "$defPol\Spynet"
            $defSvcStart = [ordered]@{ WinDefend='Automatic'; WdNisSvc='Manual'; Sense='Manual'; MDCoreSvc='Manual'; SecurityHealthService='Manual' }
            $defTaskPath = '\Microsoft\Windows\Windows Defender\'
            if ($Action.enable) {
                foreach ($n in 'DisableAntiSpyware','DisableAntiVirus') { Remove-RegValue -Path $defPol -Name $n }
                foreach ($n in 'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection','DisableScanOnRealtimeEnable','DisableIOAVProtection') { Remove-RegValue -Path $rtp -Name $n }
                foreach ($n in 'SpynetReporting','SubmitSamplesConsent') { Remove-RegValue -Path $spynet -Name $n }
                $refused = @(); foreach ($s in $defSvcStart.Keys) { if (Test-ServiceExists $s) { try { [void](Set-ServiceStart -Name $s -StartType $defSvcStart[$s]) } catch { $refused += $s } } }
                if ($refused.Count) { Write-Log ("Windows protects {0}, so their start type was left as Windows set it; they return to normal once the Defender policies above are removed and the PC restarts." -f ($refused -join ', ')) 'Info' }
                Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like ("{0}*" -f $defTaskPath) } | ForEach-Object { try { Enable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction Stop | Out-Null } catch {} }
                Write-Log 'Microsoft Defender services, scheduled tasks and policies restored to their defaults. Restart to apply. If Defender stays off, open Windows Security and turn Tamper Protection back on, then restart.' 'Warn'
            } else {
                Set-RegValue -Path $defPol -Name 'DisableAntiSpyware' -Value 1 -Type DWord
                Set-RegValue -Path $defPol -Name 'DisableAntiVirus' -Value 1 -Type DWord
                foreach ($n in 'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection','DisableScanOnRealtimeEnable','DisableIOAVProtection') { Set-RegValue -Path $rtp -Name $n -Value 1 -Type DWord }
                Set-RegValue -Path $spynet -Name 'SpynetReporting' -Value 0 -Type DWord
                Set-RegValue -Path $spynet -Name 'SubmitSamplesConsent' -Value 2 -Type DWord
                $refused = @(); foreach ($s in $defSvcStart.Keys) { if (Test-ServiceExists $s) { try { [void](Set-ServiceStart -Name $s -StartType 'Disabled' -Stop) } catch { $refused += $s } } }
                if ($refused.Count) { Write-Log ("Windows 11 protects {0} (access denied even for administrators), so those services keep running. The Defender policies were written; they only take effect while Tamper Protection is off. Fully removing Defender services needs Safe Mode or a third-party antivirus, which registers itself and turns Defender off automatically." -f ($refused -join ', ')) 'Warn' }
                Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like ("{0}*" -f $defTaskPath) } | ForEach-Object { try { Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction Stop | Out-Null } catch {} }
                if ($refused.Count) { Write-Log 'Microsoft Defender policies and scheduled tasks are off; protected services were left running. Restart to apply. With Tamper Protection on, Defender ignores these policies.' 'Warn' }
                else { Write-Log 'Microsoft Defender disabled: real-time protection, scheduled scans, cloud submission, its services and scheduled tasks are off. This needs Tamper Protection turned off first, and leaves the PC without built-in antivirus until you re-enable it. Restart to apply.' 'Warn' }
            }
        }
        'update' {
            $svcs = 'wuauserv','UsoSvc','WaaSMedicSvc'
            if ($Action.enable) { foreach ($s in $svcs) { if (Test-ServiceExists $s) { Set-ServiceStart -Name $s -StartType 'Manual'; try { Start-Service $s -ErrorAction SilentlyContinue } catch{} } } }
            else { foreach ($s in $svcs) { if (Test-ServiceExists $s) { Set-ServiceStart -Name $s -StartType 'Disabled' -Stop } } }
        }
        'updateManual' { foreach ($s in 'wuauserv','UsoSvc','WaaSMedicSvc') { if (Test-ServiceExists $s) { Set-ServiceStart -Name $s -StartType 'Manual' } } }
        'capability' {
            try {
                $caps = @(Get-WindowsCapability -Online -ErrorAction Stop)
                foreach ($prefix in @($Action.names)) {
                    foreach ($cap in @($caps | Where-Object { $_.Name -like ($prefix + '*') })) {
                        if ($Action.enable -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null; Write-Log ("Added {0}." -f $cap.Name) 'Info' }
                        elseif (-not $Action.enable -and $cap.State -eq 'Installed') { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null; Write-Log ("Removed {0}." -f $cap.Name) 'Info' }
                    }
                }
            } finally { $script:CapabilityStates = $null }
        }
        'mpPreference' {
            if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) { throw 'Microsoft Defender cmdlets are not available on this PC.' }
            $mpArgs = @{ $Action.name = [int]$Action.value }
            Set-MpPreference @mpArgs -ErrorAction Stop
            if ([int](Get-MpPreference -ErrorAction Stop).($Action.name) -ne [int]$Action.value) { throw ("Defender did not keep {0}; Tamper Protection or a policy may be blocking it." -f $Action.name) }
        }
        'eventLog' {
            $wevt = Join-Path $env:SystemRoot 'System32\wevtutil.exe'
            foreach ($n in @($Action.names)) {
                $proc = Start-Process -FilePath $wevt -ArgumentList @('sl',('"{0}"' -f $n),('/e:{0}' -f $(if ($Action.enable) { 'true' } else { 'false' })),'/q:true') -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) { Write-Log ("Event log {0} could not be changed (exit {1}); it may not exist on this build." -f $n,$proc.ExitCode) 'Warn' }
            }
        }
        'bitlockerOff' {
            if (-not (Get-Command manage-bde.exe -ErrorAction SilentlyContinue)) { throw 'manage-bde.exe is unavailable on this Windows installation.' }
            $proc=Start-Process -FilePath 'manage-bde.exe' -ArgumentList @('-off',$env:SystemDrive) -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0) { throw "manage-bde returned exit code $($proc.ExitCode)." }
        }
        default { Write-Log ("Unknown action kind: {0}" -f $Action.kind) 'Warn' }
    }
}
 
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rion Tool" Height="720" Width="1080" MinHeight="560" MinWidth="880"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#121318"/>
    <SolidColorBrush x:Key="Panel"   Color="#181A20"/>
    <SolidColorBrush x:Key="Border"  Color="#262A31"/>
    <SolidColorBrush x:Key="Text"    Color="#D7DAE0"/>
    <SolidColorBrush x:Key="SubText" Color="#8A9099"/>
    <SolidColorBrush x:Key="Accent"  Color="#5B7A99"/>
    <SolidColorBrush x:Key="Safe"     Color="#6E8F77"/>
    <SolidColorBrush x:Key="Moderate" Color="#B0893E"/>
    <SolidColorBrush x:Key="Risky"    Color="#C0564B"/>
    <SolidColorBrush x:Key="Muted"    Color="#71767E"/>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource SubText}"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Name="Bd" Padding="{TemplateBinding Padding}" BorderThickness="0,0,0,2" BorderBrush="Transparent">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Text}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#15161A"/>
      <Setter Property="Background" Value="#C8CBD1"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="MinWidth" Value="120"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#15161A"/>
      <Setter Property="Background" Value="#C8CBD1"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Padding" Value="4,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource Panel}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
 
  <Grid Name="Root" Background="{DynamicResource Bg}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
 
    <Grid Grid.Row="0" Margin="12,8,12,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="Rion Tool" Foreground="{DynamicResource Text}" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
        <TextBlock Text="&#xE721;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="{DynamicResource SubText}" VerticalAlignment="Center" Margin="24,0,6,0"/>
        <TextBox Name="SearchBox" Width="300" VerticalAlignment="Center" Padding="6,3" Background="{DynamicResource Panel}" Foreground="{DynamicResource Text}" BorderBrush="{DynamicResource Border}" CaretBrush="{DynamicResource Text}" ToolTip="Type to find any tweak by name or description on every page. Tabs show how many matches they have; clear the box to see everything again."/>
      </StackPanel>
      <TextBlock Name="EnvInfo" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="{DynamicResource SubText}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="12,0,0,0"/>
    </Grid>
 
    <TabControl Name="Tabs" Grid.Row="1" Margin="8,8,8,4" Background="Transparent" BorderThickness="0"/>
 
    <Border Grid.Row="2" Background="{DynamicResource Panel}"/>
    <Border Grid.Row="2" IsHitTestVisible="False">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#2EFFFFFF" Offset="0"/>
          <GradientStop Color="#00FFFFFF" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>
    <Border Grid.Row="2" Background="Transparent" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0" Padding="12,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="0,0,12,0">
          <Button Name="ThemeFooter" Width="32" Height="30" Padding="0" Margin="0,0,10,0" ToolTip="Switch to light mode"/>
          <Button Name="LogoOptimize" Padding="8,2" Cursor="Hand" ToolTip="One-click Gamer max: applies every Safe and Moderate gamer tweak (you review the list first), clears placebo tweaks and cleans junk files. Risky rows, Defender, Windows Update, Xbox, Bluetooth, Wi-Fi and Ethernet are left alone.">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE945;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <TextBlock Text="Rion" FontWeight="Bold" FontSize="13" Foreground="{DynamicResource Text}" VerticalAlignment="Center"/>
              <TextBlock Text="  optimize" FontSize="11" Foreground="{DynamicResource SubText}" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button Name="HealthBtn" Content="PC health: checking..." Margin="12,0,0,0" Padding="10,2" ToolTip="System analysis score. Click to open the full report on the Home tab." IsEnabled="False"/>
        </StackPanel>
        <TextBlock Name="StatusText" Grid.Column="1" VerticalAlignment="Center" Foreground="{DynamicResource SubText}" Text="Starting..." TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <TextBlock Text="Select" Foreground="{DynamicResource SubText}" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <ComboBox Name="PresetCombo" Width="160" Margin="0,0,8,0"/>
          <CheckBox Name="PresetAllPages" Content="All pages" VerticalAlignment="Center" Margin="0,0,14,0" ToolTip="When ticked, the Select choice applies to every page instead of only the page on screen."/>
          <TextBlock Text="View" Foreground="{DynamicResource SubText}" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <CheckBox Name="ViewSafe" Content="Safe" IsChecked="True" Margin="0,0,8,0"/>
          <CheckBox Name="ViewModerate" Content="Moderate" IsChecked="True" Margin="0,0,8,0"/>
          <CheckBox Name="ViewRisky" Content="Risky" IsChecked="True" Margin="0,0,14,0"/>
          <Button Name="RestoreBtn" Content="Restore point" Margin="0,0,8,0"/>
          <Button Name="ApplyBtn" Content="Apply" Background="{DynamicResource Accent}" BorderBrush="{DynamicResource Accent}" Foreground="White"/>
        </StackPanel>
      </Grid>
    </Border>
 
    <Canvas Name="SplashLayer" Grid.RowSpan="3" IsHitTestVisible="False"/>
  </Grid>
</Window>
'@
 
Read-Journal
Invoke-RetiredTweakCleanup
foreach ($strayDir in @((Join-Path $env:SystemRoot 'System32'),$PSScriptRoot,$env:USERPROFILE)) {
    $stray = Join-Path $strayDir 'H'
    try {
        $item = Get-Item -LiteralPath $stray -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -and $item.Length -eq 0) { Remove-Item -LiteralPath $stray -Force -ErrorAction Stop; Write-Log ("Removed an empty file {0} left by an older Rion Tool build." -f $stray) 'Info' }
    } catch { }
}
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
 
$Tabs        = $script:Window.FindName('Tabs')
$EnvInfo     = $script:Window.FindName('EnvInfo')
$script:StatusLabel = $script:Window.FindName('StatusText')
$script:ThemeFooter = $script:Window.FindName('ThemeFooter')
$PresetCombo = $script:Window.FindName('PresetCombo')
$LogoOptimize = $script:Window.FindName('LogoOptimize')
$PresetAllPages = $script:Window.FindName('PresetAllPages')
$script:Window.Title = ('Rion Tool  (build {0})' -f $script:Build)
try { if (Test-Path -LiteralPath $script:LogPath) { Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.previous') -Force } } catch { }
Write-Log ("Rion Tool build {0} from {1}" -f $script:Build,$PSCommandPath) 'Info'
$ViewSafe    = $script:Window.FindName('ViewSafe')
$ViewModerate= $script:Window.FindName('ViewModerate')
$ViewRisky   = $script:Window.FindName('ViewRisky')
$RestoreBtn  = $script:Window.FindName('RestoreBtn')
$ApplyBtn    = $script:Window.FindName('ApplyBtn')
$HealthBtn   = $script:Window.FindName('HealthBtn')
$SearchBox   = $script:Window.FindName('SearchBox')
$SplashLayer = $script:Window.FindName('SplashLayer')
$RootGrid    = $script:Window.FindName('Root')
 
foreach ($b in @($PresetCombo,$RestoreBtn,$ApplyBtn)) { $b.IsEnabled = $false }
$LogoOptimize.Add_Click({ Invoke-OneClickOptimize -Mode 'Gamer max' })
 
$script:DpCache = @{}
function Set-ThemeBrush {
    param($Element,[string]$Property,[string]$Key)
    $ck = $Element.GetType().FullName + '|' + $Property
    $dp = $script:DpCache[$ck]
    if (-not $dp) { $dp = $Element.GetType().GetField($Property + 'Property',[Reflection.BindingFlags]'Public,Static,FlattenHierarchy').GetValue($null); $script:DpCache[$ck] = $dp }
    $Element.SetResourceReference($dp,$Key)
}
function New-RiskBadge {
    param([string]$Risk)
    $brushKey = switch ($Risk) { 'Safe'{'Safe'} 'Moderate'{'Moderate'} 'Risky'{'Risky'} 'Protected'{'Safe'} default{'Muted'} }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Risk
    Set-ThemeBrush $tb 'Foreground' $brushKey
    $tb.FontSize = 11
    $tb.VerticalAlignment = 'Center'
    $tb.Margin = '8,0,0,0'
    return $tb
}
 
function New-InfoIcon {
    param([string]$Info)
    $b = New-Object Windows.Controls.Button
    $b.Width = 18; $b.Height = 18; $b.Padding='0'; $b.Margin = '6,0,0,0'; $b.VerticalAlignment = 'Center'
    $b.Focusable = $false; $b.Cursor = [Windows.Input.Cursors]::Help
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = 'i'; $t.FontSize = 10; $t.FontStyle = 'Italic'
    Set-ThemeBrush $t 'Foreground' 'SubText'
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Content = $t
    $tip = New-Object Windows.Controls.ToolTip
    $tipText = New-Object Windows.Controls.TextBlock
    $tipText.Text = $Info; $tipText.TextWrapping = 'Wrap'; $tipText.MaxWidth = 320
    $tip.Content = $tipText
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($b,0)
    [Windows.Controls.ToolTipService]::SetBetweenShowDelay($b,0)
    [Windows.Controls.ToolTipService]::SetShowDuration($b,60000)
    $b.ToolTip = $tip
    $b.Add_MouseEnter({ $tip.IsOpen = $true }.GetNewClosure())
    $b.Add_MouseLeave({ $tip.IsOpen = $false }.GetNewClosure())
    return $b
}
 
function Get-TweakFeature {
    param($Tweak)
    $f = [string]$Tweak.Label
    $f = [regex]::Replace($f, '(?i)^(stop|turn off|turn on|pause|disable|reject|close|remove|set|make|choose|move|lower|keep|allow|reduce|hide|block)\s+', '')
    $f = [regex]::Replace($f, '(?i)\s+(services|service)$', '')
    if (-not $f) { $f = [string]$Tweak.Label }
    return $f
}

function Test-HvciDisableAction {
    param($Action)
    if (-not $Action -or $Action.kind -ne 'registry') { return $false }
    $path = ([string]$Action.path).TrimEnd('\')
    $name = [string]$Action.name
    $value = [string]$Action.value
    return ($path -match '(?i)DeviceGuard\\Scenarios\\HypervisorEnforcedCodeIntegrity$' -and
        $name -ieq 'Enabled' -and $value -eq '0')
}

function Get-TweakWarning {
    param($Tweak)
    $head = switch ($Tweak.Risk) {
        'Risky'    { 'Risky: this can break features, security or connectivity. Apply it only if you need it and know how to undo it.' }
        'Moderate' { 'Moderate: this changes a Windows default that some apps, devices or features rely on.' }
        default    { 'Safe: low risk, but it still changes how Windows behaves.' }
    }
    $effects = New-Object System.Collections.Generic.List[string]
    if ($Tweak.Warn) { [void]$effects.Add([string]$Tweak.Warn) }
    $pattern = '(?i)(stop|break|cannot|can no longer|no longer|lose|lost|fail|unavailable|disappear|slower|heat|battery|idle power|power draw|security|vulnerab|anti-?cheat|vanguard|faceit|restart|reboot|offline|drop|not work|managed by|outdated|crash|stutter|flicker|\bmay\b|\bmight\b|\bcan\b|only if|leave it on|turn it back on|instead)'
    foreach ($s in @([regex]::Split([string]$Tweak.Info,'(?<=[.!?])\s+'))) { if ($s.Trim() -and $s -match $pattern) { [void]$effects.Add($s.Trim()) } }
    $apply = @($Tweak.Apply)
    $kinds = @($apply | ForEach-Object { [string]$_.kind } | Select-Object -Unique)
    $services = @($apply | Where-Object { $_.kind -eq 'service' })
    if ($services.Count) {
        $disabled = @($services | Where-Object { [string]$_.start -eq 'Disabled' } | ForEach-Object { $_.name })
        $manual = @($services | Where-Object { [string]$_.start -ne 'Disabled' } | ForEach-Object { $_.name })
        if ($disabled.Count) { [void]$effects.Add(('Turns off {0}. Windows features or apps that rely on it stop working until it is turned back on.' -f (Get-TweakFeature $Tweak))) }
        if ($manual.Count) { [void]$effects.Add(('Sets {0} to start only on demand, so the first use can be slightly slower.' -f (Get-TweakFeature $Tweak))) }
    }
    if (@($kinds | Where-Object { $_ -in 'taskFolder','task','taskNamePattern' }).Count) { [void]$effects.Add('Scheduled tasks are disabled, so the maintenance, update checks or reporting they run stop until they are re-enabled.') }
    if (@($apply | Where-Object { $_.kind -eq 'registry' -and [string]$_.path -match '\\Policies\\' }).Count) { [void]$effects.Add('Uses policy settings: Windows Settings and apps may show "Some settings are managed by your organization" and lock the matching switch until this is reverted.') }
    if (@($kinds | Where-Object { $_ -in 'netAdvancedProperty','netAdvancedPropertyMax','netadapter','netRss','netRsc','netbios','teredo','nagle','netPower' }).Count) { [void]$effects.Add('Changes network adapter or TCP/IP settings: the connection can drop for a few seconds and some drivers become unstable. Fixes > Reset adapter tuning to driver defaults undoes adapter changes.') }
    if (@($kinds | Where-Object { $_ -in 'powerSetting','coreparking' }).Count) { [void]$effects.Add('Changes power plan values: more heat, fan noise and power draw, and shorter battery life on laptops. Switching to another power plan does not carry these values over.') }
    if ($kinds -contains 'bcdedit') { [void]$effects.Add('Changes the boot configuration and needs a restart. If BitLocker is on it is suspended for one restart so Windows does not ask for the recovery key.') }
    if ($kinds -contains 'optionalFeature') { [void]$effects.Add('Turns off a Windows feature: apps that depend on it stop working until it is turned back on. Restart required.') }
    if (@($kinds | Where-Object { $_ -in 'runkey','runkeyAll','appxStartup' }).Count) { [void]$effects.Add('Apps no longer start at sign-in: their tray icons, notifications, sync, RGB lighting or device profiles load only after you open them.') }
    if ($kinds -contains 'mmagent') { [void]$effects.Add('Changes Windows memory management, so app launch and paging behaviour change until it is reverted.') }
    if ($kinds -contains 'msiMode') { [void]$effects.Add('Changes the interrupt mode of PCI devices: a controller whose driver does not handle MSI can stop working, and a storage controller can stop Windows from booting. Keep a restore point.') }
    if ($kinds -contains 'defender') { [void]$effects.Add('Turns off Microsoft Defender: no real-time malware protection, and some anti-cheats and apps refuse to run.') }
    if (@($kinds | Where-Object { $_ -in 'update','updateManual' }).Count) { [void]$effects.Add('Stops or delays Windows Update: no security fixes, and Microsoft Store, Xbox and driver installs can fail.') }
    if ($Tweak.Id -eq 'sec.vbs' -or @($apply | Where-Object { Test-HvciDisableAction $_ }).Count) { [void]$effects.Add('Turning Memory Integrity off weakens kernel protection, and Riot Vanguard or FACEIT can refuse to start.') }
    if ($kinds -contains 'appx') { [void]$effects.Add('Removes an app: reinstall it from Microsoft Store or Fixes > Restore all built-in Microsoft apps.') }
    if (-not $effects.Count) { [void]$effects.Add('No known side effects beyond the change described in the info icon.') }
    $list = (@($effects | Select-Object -Unique) | ForEach-Object { '- ' + $_ }) -join "`r`n"
    return ("{0}`r`n`r`nWhat it can affect:`r`n{1}`r`n`r`nUndo: untick it and Apply, or use Fixes > full revert." -f $head,$list)
}

function Get-TweakWarningShort {
    param($Tweak)
    if ($Tweak.Warn) { return [string]$Tweak.Warn }
    $apply = @($Tweak.Apply)
    $kinds = @($apply | ForEach-Object { [string]$_.kind } | Select-Object -Unique)
    $svc = @($apply | Where-Object { $_.kind -eq 'service' -and [string]$_.start -eq 'Disabled' } | ForEach-Object { $_.name })
    if ($kinds -contains 'defender') { return 'Turns off built-in antivirus (real-time, scans, services, tasks); no malware protection until re-enabled.' }
    if (@($kinds | Where-Object { $_ -in 'update','updateManual' }).Count) { return 'Stops or delays Windows Update; no security fixes and Store/Xbox/driver installs can fail.' }
    if ($Tweak.Id -eq 'sec.vbs') { return 'Turning Memory Integrity off weakens kernel security; Vanguard/FACEIT may refuse to run.' }
    if ($svc.Count) { return ('Turns off {0}; features or apps that use it stop until you turn it back on.' -f (Get-TweakFeature $Tweak)) }
    if (@($kinds | Where-Object { $_ -in 'taskFolder','task','taskNamePattern' }).Count) { return 'Disables scheduled tasks; the maintenance, update checks or reporting they run stop until re-enabled.' }
    if (@($kinds | Where-Object { $_ -in 'netAdvancedProperty','netAdvancedPropertyMax','netadapter','netRss','netbios','teredo','netPower' }).Count) { return 'Changes network adapter settings; the connection can drop briefly and some drivers get unstable.' }
    if (@($kinds | Where-Object { $_ -in 'powerSetting','coreparking' }).Count) { return 'Raises heat, fan noise and power draw, and shortens laptop battery life.' }
    if ($kinds -contains 'bcdedit') { return 'Changes boot settings and needs a restart.' }
    if ($kinds -contains 'optionalFeature') { return 'Turns off a Windows feature; apps that need it stop working until re-enabled.' }
    if (@($kinds | Where-Object { $_ -in 'runkey','runkeyAll','appxStartup' }).Count) { return 'App(s) no longer start at sign-in; tray icons, sync and device profiles load only when opened.' }
    if ($kinds -contains 'mmagent') { return 'Changes Windows memory management; app launch and paging behaviour change until reverted.' }
    if ($kinds -contains 'msiMode') { return 'Changes PCI device interrupt mode; a bad driver can stop a device or booting. Keep a restore point.' }
    if ($kinds -contains 'appx') { return 'Removes an app; reinstall from Microsoft Store if needed.' }
    $pattern = '(?i)(stop|break|cannot|no longer|lose|lost|fail|unavailable|disappear|slower|heat|battery|security|anti-?cheat|restart|reboot|drop|not work|managed by|crash|stutter|flicker)'
    foreach ($s in @([regex]::Split([string]$Tweak.Info,'(?<=[.!?])\s+'))) { if ($s.Trim() -and $s -match $pattern) { return $s.Trim() } }
    return ''
}

function New-WarnText {
    param($Tweak,[switch]$Force)
    if (-not $Force -and $Tweak.Risk -notin 'Moderate','Risky' -and -not $Tweak.Warn) { return $null }
    $short = Get-TweakWarningShort $Tweak
    if (-not $short) { return $null }
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $short; $t.TextWrapping = 'Wrap'; $t.FontSize = 11; $t.Margin = '6,2,0,0'
    Set-ThemeBrush $t 'Foreground' 'Risky'
    $tip = New-Object Windows.Controls.ToolTip
    $tipText = New-Object Windows.Controls.TextBlock
    $tipText.Text = Get-TweakWarning $Tweak; $tipText.TextWrapping = 'Wrap'; $tipText.MaxWidth = 360
    $tip.Content = $tipText; $t.ToolTip = $tip
    return $t
}

function New-TweakRow {
    param($Tweak)
    $row = New-Object Windows.Controls.Grid
    $row.Margin = '0,3,0,3'
    foreach ($w in 'Auto','*','Auto','Auto','Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w
        [void]$row.ColumnDefinitions.Add($cd)
    }

    $entry = @{ Tweak=$Tweak; Check=$null; Combo=$null; Status=$null; Touched=$false }
    $warnText = if ($Tweak.Type -ne 'info') { New-WarnText -Tweak $Tweak } else { $null }

    if ($Tweak.Type -eq 'toggle') {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($cb,0)
        [void]$row.Children.Add($cb)
        $entry.Check = $cb
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = $Tweak.Label; Set-ThemeBrush $lbl 'Foreground' 'Text'
        $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '6,0,0,0'; $lbl.TextTrimming='CharacterEllipsis'
        if ($script:LowerFpsIds -contains $Tweak.Id) {
            $lp = New-Object Windows.Controls.StackPanel; $lp.Orientation = 'Horizontal'
            $fpsIcon = New-Object Windows.Controls.TextBlock; $fpsIcon.Text = [string][char]0xE7BA; $fpsIcon.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $fpsIcon.FontSize = 13
            $fpsIcon.Margin = '6,1,0,0'; $fpsIcon.VerticalAlignment = 'Center'; $fpsIcon.ToolTip = 'Can lower FPS. Benchmark before and after, and untick it if your frame rate drops.'
            Set-ThemeBrush $fpsIcon 'Foreground' 'Risky'
            [void]$lp.Children.Add($lbl); [void]$lp.Children.Add($fpsIcon)
            $lbl = $lp
        }
        if ($Tweak.Note -or $warnText) {
            $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,2,0,0'
            $stack = New-Object Windows.Controls.StackPanel
            [void]$stack.Children.Add($lbl)
            if ($Tweak.Note) {
                $note = New-Object Windows.Controls.TextBlock
                $note.Text = $Tweak.Note; Set-ThemeBrush $note 'Foreground' 'SubText'
                $note.FontSize = 11; $note.TextWrapping = 'Wrap'; $note.Margin = '6,2,0,0'
                [void]$stack.Children.Add($note)
            }
            if ($warnText) { [void]$stack.Children.Add($warnText) }
            $lbl = $stack
        }
        [Windows.Controls.Grid]::SetColumn($lbl,1)
        [void]$row.Children.Add($lbl)
    } elseif ($Tweak.Type -eq 'dropdown') {
        $combo = New-Object Windows.Controls.ComboBox
        foreach ($o in $Tweak.Options) { [void]$combo.Items.Add($o) }
        $combo.SelectedIndex = 0
        $combo.HorizontalAlignment='Left'; $combo.Width=130; $combo.VerticalAlignment='Top'
        [Windows.Controls.Grid]::SetColumn($combo,0)
        [void]$row.Children.Add($combo)
        $entry.Combo = $combo
        $combo.Add_SelectionChanged({ $entry.Touched = $true }.GetNewClosure())
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = $Tweak.Label; Set-ThemeBrush $lbl 'Foreground' 'Text'
        $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '8,0,0,0'; $lbl.TextTrimming='CharacterEllipsis'
        if ($warnText) {
            $stack = New-Object Windows.Controls.StackPanel; $stack.Margin='8,0,0,0'
            [void]$stack.Children.Add($lbl); $lbl.Margin='0'; [void]$stack.Children.Add($warnText)
            $lbl = $stack
        }
        [Windows.Controls.Grid]::SetColumn($lbl,1)
        [void]$row.Children.Add($lbl)
    } else {
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = $Tweak.Label; Set-ThemeBrush $lbl 'Foreground' 'SubText'
        $lbl.VerticalAlignment = 'Center'; $lbl.TextWrapping='Wrap'
        [Windows.Controls.Grid]::SetColumn($lbl,1)
        [void]$row.Children.Add($lbl)
    }

    if ($Tweak.Info) {
        $info = New-InfoIcon $Tweak.Info
        $info.VerticalAlignment = 'Top'
        [Windows.Controls.Grid]::SetColumn($info,2)
        [void]$row.Children.Add($info)
    }

    $badge = New-RiskBadge $Tweak.Risk
    $badge.VerticalAlignment = 'Top'
    [Windows.Controls.Grid]::SetColumn($badge,3)
    [void]$row.Children.Add($badge)

    $status = New-Object Windows.Controls.TextBlock
    Set-ThemeBrush $status 'Foreground' 'Muted'; $status.FontSize = 11
    $status.VerticalAlignment = 'Top'; $status.Margin = '10,0,0,0'
    [Windows.Controls.Grid]::SetColumn($status,4)
    [void]$row.Children.Add($status)
    $entry.Status = $status
 
    $entry.Row = $row
    $script:Rows[$Tweak.Id] = $entry
    return $row
}
 
$script:GroupGlyphRules = @(
    @('(?i)profile inspector|graphics driver|nvidia app|amd software|intel graphics','E7F4'),@('(?i)^processor$','E950'),@('(?i)intel services','EC7A'),
    @('(?i)discord|chat','E8F2'),@('(?i)search','E721'),@('(?i)^hardware$','E772'),
    @('(?i)bluetooth','E702'),@('(?i)camera|scanner','E722'),@('(?i)xbox|gaming|game|valorant|fortnite|counter-strike','E7FC'),@('(?i)print','E749'),
    @('(?i)wi-?fi','E701'),@('(?i)\bai\b|copilot','E99A'),@('(?i)spotify|music','E8D6'),@('(?i)audio|media','E767'),@('(?i)microphone|voice|speech','E720'),
    @('(?i)location|time and family','E707'),@('(?i)account|sign-in|sign in','E77B'),@('(?i)mail','E715'),@('(?i)notification','EA8F'),
    @('(?i)privacy|ads','E72E'),@('(?i)encryption|core isolation|hardening','E72E'),@('(?i)defender|security|protection|anti-cheat','EA18'),
    @('(?i)telemetry|diagnostic|feedback|crash|logging','E9D9'),@('(?i)delivery optimization|download','E896'),@('(?i)update|updater','E777'),
    @('(?i)browser','E774'),@('(?i)mobile and radio|radio','EC05'),@('(?i)cross-device|phone','E8EA'),@('(?i)sync','E895'),
    @('(?i)dns|name resolution|tcp|qos|tunnel|vpn|remote|smb|link settings|discovery|sharing|queues|network|router','E968'),
    @('(?i)explorer|visual|shell','E8B7'),@('(?i)start, taskbar','E7C4'),@('(?i)power plan|power and adapters|power saving|power\b|background and power|battery','E945'),
    @('(?i)processor|cpu|scheduling|priorit|processes|responsiveness','E950'),@('(?i)memory','E964'),@('(?i)backup','E7B8'),@('(?i)storage|disk|cleanup|junk','EDA2'),
    @('(?i)ghost|devices|sensors|pairing|virtual and debug','E772'),@('(?i)timer|boot','E916'),@('(?i)input|keyboard|accessibility','E765'),@('(?i)mouse','E962'),
    @('(?i)gpu|display|graphics|interrupts|nvidia|amd|intel','E7F4'),@('(?i)optional features|legacy','EA86'),@('(?i)vendor|maker|peripheral|developer|chipset','EC7A'),
    @('(?i)microsoft store|store app','E719'),@('(?i)microsoft apps','E719'),@('(?i)startup|launcher|chat and creative|cloud apps|windows and microsoft','E768'),
    @('(?i)cloud','E753'),@('(?i)virtualization|hyper-v','E7F8'),@('(?i)repair|reset|undo|fix','E90F'),@('(?i)maintenance|background','E9F5'),
    @('(?i)health|findings|recommendation','E9D9'),@('(?i)automation|shortcut','E8AB')
)
function Get-GroupGlyph {
    param([string]$Group,[string]$Tab)
    if ($Tab -eq 'GPU' -and $Group -match '(?i)^(AMD|Intel|NVIDIA|Common|Windows)$') { return [string][char]0xE7F4 }
    if ($Tab -eq 'CPU' -and $Group -match '(?i)^(AMD|Intel)$') { return [string][char]0xE950 }
    foreach ($r in $script:GroupGlyphRules) { if ($Group -match $r[0]) { return [string][char][Convert]::ToInt32($r[1],16) } }
    return [string][char]0xE713
}
function New-SectionBox {
    param([string]$Title,$Children,$HeaderExtra,[string]$Tab = '')
    $border = New-Object Windows.Controls.Border
    Set-ThemeBrush $border 'Background' 'Panel'
    Set-ThemeBrush $border 'BorderBrush' 'Border'
    $border.BorderThickness = '1'; $border.CornerRadius = '4'
    $border.Padding = '12'; $border.Margin = '6'
    $sp = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.StackPanel; $head.Orientation='Horizontal'; $head.Margin='0,0,0,6'
    $hi = New-Object Windows.Controls.TextBlock; $hi.Text=(Get-GroupGlyph $Title $Tab); $hi.FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets'; $hi.FontSize=15; $hi.Margin='0,1,8,0'; $hi.VerticalAlignment='Center'
    Set-ThemeBrush $hi 'Foreground' 'Accent'
    [void]$head.Children.Add($hi)
    $ht = New-Object Windows.Controls.TextBlock; $ht.Text=$Title; $ht.FontWeight='SemiBold'
    Set-ThemeBrush $ht 'Foreground' 'Text'
    [void]$head.Children.Add($ht)
    if ($HeaderExtra) { [void]$head.Children.Add($HeaderExtra) }
    [void]$sp.Children.Add($head)
    foreach ($c in @($Children)) { [void]$sp.Children.Add($c) }
    $border.Child = $sp
    return $border
}

function New-GroupBox {
    param([string]$Group,[string]$MaxRisk,$Tweaks)
    $mr = $null
    if ($MaxRisk -in @('Safe','Moderate','Risky')) {
        $mr = New-Object Windows.Controls.TextBlock; $mr.Text=("up to {0}" -f $MaxRisk); $mr.Margin='8,0,0,0'
        $mr.VerticalAlignment='Bottom'; $mr.FontSize=11
        Set-ThemeBrush $mr 'Foreground' $MaxRisk
    }
    $rows = foreach ($t in $Tweaks) { New-TweakRow $t }
    return (New-SectionBox -Title $Group -Children $rows -HeaderExtra $mr -Tab ([string]@($Tweaks)[0].Tab))
}
 
$script:RiskRank = @{ 'Safe'=1; 'Moderate'=2; 'Risky'=3; 'Protected'=0; 'Manual'=0 }
 
function New-TwoColumnPanel {
    param($Sections)
    $grid = New-Object Windows.Controls.Grid
    foreach ($i in 0,1) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width='*'; [void]$grid.ColumnDefinitions.Add($cd) }
    $cols = @((New-Object Windows.Controls.StackPanel),(New-Object Windows.Controls.StackPanel))
    $weights = @(0,0)
    for ($i=0; $i -lt 2; $i++) { [Windows.Controls.Grid]::SetColumn($cols[$i],$i); [void]$grid.Children.Add($cols[$i]) }
    foreach ($section in @($Sections)) {
        $target = if ($weights[0] -le $weights[1]) { 0 } else { 1 }
        [void]$cols[$target].Children.Add($section.Box)
        $weights[$target] += [int]$section.Weight + 2
    }
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Padding='4'
    $scroll.Content = $grid
    return $scroll
}

function New-TweakPanel {
    param($Tweaks)
    $sections = foreach ($g in @($Tweaks | Group-Object { $_.Group })) {
        $maxRisk = ($g.Group | Sort-Object { $script:RiskRank[$_.Risk] } -Descending | Select-Object -First 1).Risk
        @{ Box=(New-GroupBox -Group $g.Name -MaxRisk $maxRisk -Tweaks $g.Group); Weight=$g.Count }
    }
    return (New-TwoColumnPanel $sections)
}
 
$script:PageHints = @{
    'Services'='Background services Windows and installed apps run. Turning one off frees memory and CPU time; each row says what stops working.'
    'Startup and tasks'='Apps that start with Windows and scheduled background tasks.'
    'Features'='Windows features, ads, AI, privacy and Explorer settings.'
    'Memory and storage'='Memory manager and disk settings.'
    'Apps'='Settings for browsers, game launchers, Discord, Spotify and other apps.'
    'System'='General Windows behaviour.'
    'Games'='In-game settings for Valorant and Fortnite. Pick values, then click Apply while the game is closed. Every file a setting lives in is updated together, and each save is backed up first.'
    'Networking'='Network adapter, Wi-Fi, DNS and QoS settings. Online games mostly care about Wi-Fi power saving and a stable connection.'
    'GPU'='Graphics settings for games: GPU selection, scheduling, overlays and driver extras.'
    'CPU'='Processor power and scheduling. The Balanced plan with Power mode set to Best performance suits most PCs.'
    'Security'='Windows Security, Defender, encryption and Windows Update.'
    'Advanced'='Lower-level settings: processes, priorities, timers, power for devices and crash behaviour.'
    'AMD'='Settings for AMD processors, Radeon graphics and AMD Software. Only shown on PCs with AMD hardware.'
    'NVIDIA'='Settings for GeForce graphics, the NVIDIA app and NVIDIA Profile Inspector. Only shown on PCs with an NVIDIA GPU.'
    'Intel'='Settings for Intel processors, Intel graphics and Intel helper software. Only shown on PCs with Intel hardware.'
}
function New-HintedPage {
    param([string]$Key,$Content)
    if (-not $script:PageHints.ContainsKey($Key)) { return $Content }
    $dock = New-Object Windows.Controls.DockPanel
    $hint = New-Object Windows.Controls.TextBlock; $hint.Text = $script:PageHints[$Key]; $hint.TextWrapping='Wrap'; $hint.Margin='10,4,10,2'
    Set-ThemeBrush $hint 'Foreground' 'SubText'
    [Windows.Controls.DockPanel]::SetDock($hint,'Top'); [void]$dock.Children.Add($hint); [void]$dock.Children.Add($Content)
    return $dock
}
function Add-Tab {
    param([string]$Header,$Content)
    $Content = New-HintedPage $Header $Content
    $ti = New-Object Windows.Controls.TabItem
    $ti.Header = $Header
    $ti.Content = $Content
    [void]$Tabs.Items.Add($ti)
    return $ti
}
 
$tweaksTweaks = $script:Tweaks | Where-Object { $_.Tab -eq 'Tweaks' }
$innerTabs = New-Object Windows.Controls.TabControl
$innerTabs.Background = 'Transparent'; $innerTabs.BorderThickness = '0'
foreach ($st in @('System','Services','Startup and tasks','Features','Memory and storage','Apps')) {
    $items = @($tweaksTweaks | Where-Object { $_.SubTab -eq $st })
    if (-not $items.Count) { continue }
    $sti = New-Object Windows.Controls.TabItem; $sti.Header=$st; $sti.Content=(New-HintedPage $st (New-TweakPanel $items))
    [void]$innerTabs.Items.Add($sti)
}
Add-Tab 'Tweaks' $innerTabs | Out-Null
 
foreach ($tab in @('Networking','GPU','CPU')) {
    $items = $script:Tweaks | Where-Object { $_.Tab -eq $tab }
    Add-Tab $tab (New-TweakPanel $items) | Out-Null
}
 
$debloatPanel = New-Object Windows.Controls.Grid
$debloatPanel.Margin = '10'
$dRow0 = New-Object Windows.Controls.RowDefinition; $dRow0.Height='Auto'
$dRow1 = New-Object Windows.Controls.RowDefinition; $dRow1.Height='*'
[void]$debloatPanel.RowDefinitions.Add($dRow0); [void]$debloatPanel.RowDefinitions.Add($dRow1)
$dBtns = New-Object Windows.Controls.StackPanel; $dBtns.Orientation='Horizontal'; $dBtns.Margin='0,0,0,10'
$btnAuto = New-Object Windows.Controls.Button; $btnAuto.Content='Auto debloat'; $btnAuto.Margin='0,0,8,0'
$btnScan = New-Object Windows.Controls.Button; $btnScan.Content='Scan again'; $btnScan.Margin='0,0,8,0'
$btnDebApply = New-Object Windows.Controls.Button; $btnDebApply.Content='Apply selection'; $btnDebApply.Margin='0,0,8,0'
$chkProvisioned = New-Object Windows.Controls.CheckBox; $chkProvisioned.Content='Also remove for new user accounts'; $chkProvisioned.IsChecked=$true; $chkProvisioned.VerticalAlignment='Center'; $chkProvisioned.Margin='6,0,0,0'; $chkProvisioned.ToolTip='Windows keeps a provisioned copy of each Store app and installs it for every new user account and during feature updates. Ticked, removing an app also removes that copy so it stays gone. Either way an app can be reinstalled from Microsoft Store.'
foreach ($b in @($btnAuto,$btnScan,$btnDebApply,$chkProvisioned)) { [void]$dBtns.Children.Add($b) }
[Windows.Controls.Grid]::SetRow($dBtns,0); [void]$debloatPanel.Children.Add($dBtns)
$debloatViews = New-Object Windows.Controls.TabControl; $debloatViews.Background='Transparent'; $debloatViews.BorderThickness='0'
$dStoreList = New-Object Windows.Controls.StackPanel
$dProgramList = New-Object Windows.Controls.StackPanel
$dStoreScroll = New-Object Windows.Controls.ScrollViewer; $dStoreScroll.VerticalScrollBarVisibility='Auto'; $dStoreScroll.Content=$dStoreList
$dProgramScroll = New-Object Windows.Controls.ScrollViewer; $dProgramScroll.VerticalScrollBarVisibility='Auto'; $dProgramScroll.Content=$dProgramList
$dStoreTab=New-Object Windows.Controls.TabItem; $dStoreTab.Header='Microsoft apps'; $dStoreTab.Content=$dStoreScroll
$dProgramTab=New-Object Windows.Controls.TabItem; $dProgramTab.Header='Program apps'; $dProgramTab.Content=$dProgramScroll
[void]$debloatViews.Items.Add($dStoreTab); [void]$debloatViews.Items.Add($dProgramTab)
[Windows.Controls.Grid]::SetRow($debloatViews,1); [void]$debloatPanel.Children.Add($debloatViews)
Add-Tab 'Debloat' $debloatPanel | Out-Null
foreach ($b in @($btnAuto,$btnScan,$btnDebApply)) { $b.IsEnabled = $false }
 
foreach ($tab in @('Security','Advanced')) {
    $items = $script:Tweaks | Where-Object { $_.Tab -eq $tab }
    Add-Tab $tab (New-TweakPanel $items) | Out-Null
}
 
$script:AutoDebloatApps = @(
    'Microsoft.BingNews',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.BingWeather',
    'Microsoft.GamingApp',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.MicrosoftStickyNotes',
    'Clipchamp.Clipchamp','Microsoft.3DBuilder','Microsoft.549981C3F5F10','Microsoft.BingFinance','Microsoft.BingFoodAndDrink',
    'Microsoft.BingHealthAndFitness','Microsoft.BingSports','Microsoft.BingTranslator','Microsoft.BingTravel','Microsoft.BingSearch',
    'Microsoft.Getstarted','Microsoft.Messaging','Microsoft.Microsoft3DViewer','Microsoft.MicrosoftJournal','Microsoft.MicrosoftPowerBIForWindows',
    'Microsoft.MixedReality.Portal','Microsoft.NetworkSpeedTest','Microsoft.Office.Sway','Microsoft.OneConnect','Microsoft.PCManager',
    'Microsoft.PowerAutomateDesktop','Microsoft.Print3D','Microsoft.SkypeApp','Microsoft.Todos','Microsoft.Windows.AIHub','Microsoft.Copilot',
    'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.ZuneVideo','MicrosoftCorporationII.MicrosoftFamily','Microsoft.People',
    'microsoft.windowscommunicationsapps','Microsoft.M365Companions','Microsoft.MSPaint'
)
$script:PromotedStoreApps = @(
    '*Netflix*','*ACGMediaPlayer*','*ActiproSoftware*','*AdobePhotoshopExpress*','Amazon.com.Amazon','AmazonVideo.PrimeVideo','*Asphalt8*',
    '*AutodeskSketchBook*','BytedancePte.Ltd.TikTok','*CaesarsSlots*','*COOKINGFEVER*','*CyberLinkMediaSuite*','Disney.37853FC22B2CE','*DisneyMagicKingdoms*',
    '*DrawboardPDF*','*Duolingo*','FACEBOOK.FACEBOOK','Facebook.Instagram','*Facebook.Messenger*','*FarmVille*','*RoyalRevolt*','*Flipboard*','*HiddenCity*',
    'HULULLC.HULUPLUS','*iHeartRadio*','king.com.*','*LinkedInforWindows*','*MarchofEmpires*','*NYTCrossword*','*OneCalendar*','*PandoraMedia*',
    '*PhototasticCollage*','*PicsArt*','*Polarr*','*LiveWallpaper*','*SlingTV*','*TuneInRadio*','*WinZipUniversal*','*Twitter*','*XINGAG.XING*',
    '*ESPN*','*Plex*','*McAfee*','*Norton*','*ExpressVPN*','*Dolby*Access*'
)
$script:NeverAutoRemove = @(
    'Microsoft.WindowsStore','Microsoft.StorePurchaseApp','Microsoft.DesktopAppInstaller','Microsoft.SecHealthUI',
    'Microsoft.WindowsNotepad','Microsoft.WindowsCalculator','Microsoft.WindowsTerminal','Microsoft.Paint',
    'Microsoft.ScreenSketch','Microsoft.Windows.Photos','Microsoft.WindowsCamera','Microsoft.ZuneMusic',
    'Microsoft.WindowsMediaPlayer','Microsoft.WindowsAlarms','Microsoft.WindowsSoundRecorder',
    'Microsoft.Windows.ImmersiveControlPanel','Microsoft.Windows.Settings','Microsoft.MicrosoftEdge.Stable',
    'Microsoft.XboxIdentityProvider','Microsoft.XboxTCUI','Microsoft.Xbox.TCUI','Microsoft.GamingServices',
    'Microsoft.HEIFImageExtension','Microsoft.HEVCVideoExtension','Microsoft.VP9VideoExtensions','Microsoft.WebMediaExtensions',
    'Microsoft.WebpImageExtension','Microsoft.AV1VideoExtension','Microsoft.RawImageExtension','Microsoft.MPEG2VideoExtension',
    'Microsoft.OneDriveSync','Microsoft.WindowsAppRuntime','Microsoft.Windows.DevHome'
)
$script:KeepApps = @(
    'Microsoft.WindowsStore','Microsoft.ScreenSketch','Microsoft.GamingApp',
    'Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay',
    'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay','Microsoft.XboxTCUI',
    'Microsoft.XboxGameCallableUI','Microsoft.Windows.Photos','Microsoft.MicrosoftOfficeHub',
    'Microsoft.ZuneMusic','Microsoft.WindowsNotepad',
    'Microsoft.WindowsCalculator','Microsoft.WindowsTerminal','Microsoft.WindowsCamera',
    'Microsoft.Paint','Microsoft.WindowsAlarms','Microsoft.WindowsSoundRecorder',
    'Microsoft.OneDriveSync','MicrosoftTeams'
)

$script:KeepProgramPatterns = @('Microsoft*','Windows*','Security*','Update*','Driver*','Visual C++*','Microsoft .NET*','*Runtime*','*Redistributable*','*Chipset*')
 
$settingsPanel = New-Object Windows.Controls.StackPanel; $settingsPanel.Margin='16'
$chkRestore = New-Object Windows.Controls.CheckBox; $chkRestore.Content='Create a restore point before applying'; $chkRestore.IsChecked=$true; $chkRestore.Margin='0,0,0,12'
$chkReduce = New-Object Windows.Controls.CheckBox; $chkReduce.Content='Reduce motion (skip theme splash animation)'; $chkReduce.Margin='0,0,0,12'
$openLog = New-Object Windows.Controls.Button; $openLog.Content='Open data folder'; $openLog.HorizontalAlignment='Left'; $openLog.Margin='0,0,0,12'
    [void]$settingsPanel.Children.Add($chkRestore); [void]$settingsPanel.Children.Add($chkReduce); [void]$settingsPanel.Children.Add($openLog)
 
$script:MicrosoftAppCatalog = @(
    @{ Name='Microsoft Store'; ProductId='9WZDNCRFJBMP'; Packages=@('Microsoft.WindowsStore') }
    @{ Name='Snipping Tool'; ProductId='9MZ95KL8MR0L'; Packages=@('Microsoft.ScreenSketch') }
    @{ Name='Xbox app'; ProductId='9MV0B5HZVK9Z'; Packages=@('Microsoft.GamingApp','Microsoft.XboxApp') }
    @{ Name='Xbox Game Bar'; ProductId='9NZKPSTSNW4P'; Packages=@('Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay') }
    @{ Name='Gaming Services'; ProductId='9MWPM2CQNLHN'; Packages=@('Microsoft.GamingServices') }
    @{ Name='Xbox Identity Provider'; ProductId='9WZDNCRD1HKW'; Packages=@('Microsoft.XboxIdentityProvider') }
    @{ Name='Microsoft Photos'; ProductId='9WZDNCRFJBH4'; Packages=@('Microsoft.Windows.Photos') }
    @{ Name='Windows Calculator'; ProductId='9WZDNCRFHVN5'; Packages=@('Microsoft.WindowsCalculator') }
)
$script:ReinstallCatalog = @($script:MicrosoftAppCatalog) + @(
    @{ Name='Notepad'; ProductId='9MSMLRH6LZF3'; Packages=@('Microsoft.WindowsNotepad') }
    @{ Name='Windows Terminal'; ProductId='9N0DX20HK701'; Packages=@('Microsoft.WindowsTerminal') }
    @{ Name='Paint'; ProductId='9PCFS5B6T72H'; Packages=@('Microsoft.Paint') }
    @{ Name='Clock'; ProductId='9WZDNCRFJ3PR'; Packages=@('Microsoft.WindowsAlarms') }
    @{ Name='Camera'; ProductId='9WZDNCRFJBBG'; Packages=@('Microsoft.WindowsCamera') }
    @{ Name='Sound Recorder'; ProductId='9WZDNCRFHWKN'; Packages=@('Microsoft.WindowsSoundRecorder') }
    @{ Name='Media Player'; ProductId='9WZDNCRFJ3PT'; Packages=@('Microsoft.ZuneMusic') }
    @{ Name='Microsoft To Do'; ProductId='9NBLGGH5R558'; Packages=@('Microsoft.Todos') }
    @{ Name='Sticky Notes'; ProductId='9NBLGGH4QGHW'; Packages=@('Microsoft.MicrosoftStickyNotes') }
    @{ Name='MSN Weather'; ProductId='9WZDNCRFJ3Q2'; Packages=@('Microsoft.BingWeather') }
    @{ Name='Clipchamp'; ProductId='9P1J8S7CCWWT'; Packages=@('Clipchamp.Clipchamp') }
    @{ Name='Phone Link'; ProductId='9NMPJ99VJBWV'; Packages=@('Microsoft.YourPhone') }
    @{ Name='Feedback Hub'; ProductId='9NBLGGH4R32N'; Packages=@('Microsoft.WindowsFeedbackHub') }
    @{ Name='Get Help'; ProductId='9PKDZBMV1H3T'; Packages=@('Microsoft.GetHelp') }
    @{ Name='Quick Assist'; ProductId='9P7BP5VNWKX5'; Packages=@('MicrosoftCorporationII.QuickAssist') }
    @{ Name='Outlook (new)'; ProductId='9NRX63209R7B'; Packages=@('Microsoft.OutlookForWindows') }
    @{ Name='HEIF Image Extension'; ProductId='9PMMSR1CGPWG'; Packages=@('Microsoft.HEIFImageExtension') }
    @{ Name='Web Media Extensions'; ProductId='9N5TDP8VCMHS'; Packages=@('Microsoft.WebMediaExtensions') }
    @{ Name='VP9 Video Extensions'; ProductId='9N4D0MSMP0PT'; Packages=@('Microsoft.VP9VideoExtensions') }
    @{ Name='AV1 Video Extension'; ProductId='9MVZQVXJBQ9V'; Packages=@('Microsoft.AV1VideoExtension') }
    @{ Name='WebP Image Extension'; ProductId='9PG2DK419DRG'; Packages=@('Microsoft.WebpImageExtension') }
    @{ Name='Raw Image Extension'; ProductId='9NCTDW2W1BH8'; Packages=@('Microsoft.RawImageExtension') }
)
$script:ReinstallChecks = @()

function Save-RionDownload {
    param([string]$Url,[string]$Path,[string]$Label)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'RionTool'; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    try {
        $total = [long]$resp.ContentLength
        $in = $resp.GetResponseStream(); $out = [IO.File]::Create($Path)
        try {
            $buf = New-Object byte[] 1048576; $done = 0L; $lastPct = -1; $lastMb = -1; $sw = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $in.Read($buf,0,$buf.Length)) -gt 0) {
                $out.Write($buf,0,$n); $done += $n
                $speed = ($done / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds,0.1)
                if ($total -gt 0) {
                    $pct = [int](100 * $done / $total)
                    if ($pct -ne $lastPct) { $lastPct = $pct; try { [Console]::Write(("`r    {0}: {1,3}%  ({2:N1} of {3:N1} MB, {4:N1} MB/s)   " -f $Label,$pct,($done/1MB),($total/1MB),$speed)) } catch { } }
                } elseif ([int]($done / 5MB) -ne $lastMb) { $lastMb = [int]($done / 5MB); try { [Console]::Write(("`r    {0}: {1:N1} MB ({2:N1} MB/s)   " -f $Label,($done/1MB),$speed)) } catch { } }
            }
            try { [Console]::WriteLine() } catch { }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
    Write-Log ('{0} downloaded ({1:N1} MB).' -f $Label,((Get-Item -LiteralPath $Path).Length / 1MB)) 'Info'
}
function Test-WingetExe {
    param([string]$Path)
    if (-not $Path) { return $false }
    try { $v = & $Path --version 2>$null; return ($LASTEXITCODE -eq 0 -and [string]$v -match '\d') } catch { return $false }
}
function Get-RionWingetPath {
    $ProgressPreference = 'SilentlyContinue'
    $candidates = @()
    $candidates += @(Get-Command winget.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')
    try { $candidates += @(& where.exe winget 2>$null) } catch { }
    foreach ($inst in @(@(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) + @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) | Where-Object { $_.InstallLocation } | Sort-Object Version -Descending)) { $candidates += (Join-Path $inst.InstallLocation 'winget.exe') }
    foreach ($c in @($candidates | Where-Object { $_ } | Select-Object -Unique)) { if (Test-WingetExe $c) { return $c } }
    Write-Log ('WinGet did not answer at: {0}' -f ((@($candidates | Where-Object { $_ } | Select-Object -Unique)) -join '; ')) 'Info'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        $installer = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($installer -and $installer.InstallLocation -and (Test-Path (Join-Path $installer.InstallLocation 'winget.exe'))) { Write-Log 'WinGet was registered again from the App Installer already on this PC.' 'Success'; return (Join-Path $installer.InstallLocation 'winget.exe') }
    } catch { }
    $bundle = Join-Path $env:TEMP ("RionTool-AppInstaller-{0}.msixbundle" -f [guid]::NewGuid().ToString('N'))
    try {
        Write-Log 'WinGet is missing; downloading Microsoft App Installer from aka.ms/getwinget (about 120 MB). Progress shows in this window.' 'Action'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Save-RionDownload -Url 'https://aka.ms/getwinget' -Path $bundle -Label 'Microsoft App Installer'
        Write-Log 'Installing Microsoft App Installer (about a minute)...' 'Action'
        try { Add-AppxPackage -Path $bundle -ErrorAction Stop }
        catch {
            Write-Log ('App Installer needs its runtime packages first ({0}); adding them.' -f $_.Exception.Message) 'Action'
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
            foreach ($dep in @(("https://aka.ms/Microsoft.VCLibs.{0}.14.00.Desktop.appx" -f $arch),("https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.{0}.appx" -f $arch))) {
                $depFile = Join-Path $env:TEMP ("RionTool-dep-{0}.appx" -f [guid]::NewGuid().ToString('N'))
                try { Save-RionDownload -Url $dep -Path $depFile -Label (Split-Path $dep -Leaf); Add-AppxPackage -Path $depFile -ErrorAction Stop } catch { Write-Log ('Runtime package {0}: {1}' -f $dep,$_.Exception.Message) 'Info' } finally { Remove-Item -LiteralPath $depFile -Force -ErrorAction SilentlyContinue }
            }
            Add-AppxPackage -Path $bundle -ErrorAction Stop
        }
        $deadline = (Get-Date).AddSeconds(15)
        do {
            $installer = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($installer -and $installer.InstallLocation) {
                $exe = Join-Path $installer.InstallLocation 'winget.exe'
                if (Test-Path $exe) { return $exe }
            }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
    } finally { Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue }
    throw 'Microsoft App Installer was added, but winget.exe is still unavailable. Reboot once and retry the app repair.'
}

function Restore-TemporaryStoreServices {
    param($Snapshot)
    foreach ($item in @($Snapshot | Sort-Object { [array]::IndexOf(@('LicenseManager','AppXSVC','ClipSVC','InstallService','DoSvc','BITS','wuauserv'),$_.Name) })) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($item.Name)"
        if (-not $item.WasRunning) {
            try { Stop-Service -Name $item.Name -ErrorAction Stop }
            catch { Write-Log ("Could not stop temporary Store service {0}; it may still be completing a package operation." -f $item.Name) 'Warn' }
        }
        if (Test-Path $key) {
            try { Set-ServiceStartNow -Name $item.Name -Start ([int]$item.Start) }
            catch { Write-Log ("Could not restore the {0} startup mode after app installation: {1}" -f $item.Name,$_.Exception.Message) 'Warn' }
        }
    }
}

function Start-TemporaryStoreServices {
    $snapshot = @()
    foreach ($name in @('wuauserv','BITS','DoSvc','InstallService','ClipSVC','AppXSVC','LicenseManager')) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        if (-not (Test-Path $key)) { continue }
        $start = Get-ServiceStartValue $name
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $start -or -not $svc) { continue }
        $wasRunning = ($svc.Status -eq 'Running')
        $snapshot += @{ Name=$name; Start=$start; WasRunning=$wasRunning }
        if ($start -eq 4) {
            try { Set-ServiceStartNow -Name $name -Start 3 }
            catch { Restore-TemporaryStoreServices -Snapshot $snapshot; throw ("Could not enable {0} temporarily for app installation: {1}" -f $name,$_.Exception.Message) }
        }
        if (-not $wasRunning) {
            try { Start-Service -Name $name -ErrorAction Stop }
            catch {
                Restore-TemporaryStoreServices -Snapshot $snapshot
                throw ("Could not start {0} for this app download: {1}" -f $name,$_.Exception.Message)
            }
        }
    }
    return ,$snapshot
}

function Install-StoreProduct {
    param([string]$Name,[string]$ProductId)
    $winget = Get-RionWingetPath
    $snapshot = Start-TemporaryStoreServices
    try {
        Write-Log ("Installing {0} ({1}) through WinGet; no Store window will open." -f $Name,$ProductId) 'Action'
        $args = "install --id $ProductId --source msstore --accept-package-agreements --accept-source-agreements --silent --disable-interactivity --force"
        $proc = Start-Process -FilePath $winget -ArgumentList $args -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -notin -1978335189,-1978335135) {
            Write-Log ("WinGet returned {0} for {1}; resetting its sources and trying once more." -f $proc.ExitCode,$Name) 'Warn'
            Start-Process -FilePath $winget -ArgumentList 'source reset --force --disable-interactivity' -Wait -WindowStyle Hidden | Out-Null
            $proc = Start-Process -FilePath $winget -ArgumentList $args -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -notin -1978335189,-1978335135) { throw ("WinGet failed with exit code {0} for {1}." -f $proc.ExitCode,$Name) }
        }
        Write-Log ("WinGet installed {0}. Windows Update startup state will now be restored." -f $Name) 'Success'
    } finally { Restore-TemporaryStoreServices -Snapshot $snapshot }
}

function Repair-StorePackage {
    param($App,[switch]$Reinstall)
    $reRegistered = $false
    $packages = @()
    foreach ($pn in @($App.Packages)) {
        try { $packages += @(Get-AppxPackage -Name $pn -ErrorAction SilentlyContinue) } catch { }
        try { $packages += @(Get-AppxPackage -AllUsers -Name $pn -ErrorAction SilentlyContinue) } catch { }
    }
    $packages = @($packages | Where-Object { $_.InstallLocation } | Sort-Object PackageFullName -Unique)
    foreach ($pkg in $packages) {
        $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (-not (Test-Path $manifest)) { continue }
        try {
            Add-AppxPackage -Path $manifest -Register -DisableDevelopmentMode -ErrorAction Stop
            Write-Log ("Re-registered {0} from local package files." -f $App.Name) 'Success'
            $reRegistered = $true
        } catch { Write-Log ("Local repair failed for {0}: {1}" -f $App.Name,$_.Exception.Message) 'Warn' }
    }
    if (-not $reRegistered -or $Reinstall) {
        if ($Reinstall -and $reRegistered) { Write-Log ("Local registration for {0} succeeded; running WinGet force-install to refresh the package." -f $App.Name) 'Action' }
        Install-StoreProduct -Name $App.Name -ProductId $App.ProductId
    }
}

function Repair-XboxServiceConfiguration {
    foreach ($name in @('GamingServices','GamingServicesNet','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','GameInputSvc')) {
        if (-not (Test-ServiceExists $name)) { continue }
        if ((Get-ServiceStartValue $name) -eq 4) {
            Set-ServiceStartNow -Name $name -Start 3
            Write-Log ("Restored {0} to on-demand startup." -f $name) 'Success'
        }
    }
    $startedHere = @()
    foreach ($name in @('GamingServices','GamingServicesNet')) {
        if (-not (Test-ServiceExists $name)) { continue }
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            try { Start-Service -Name $name -ErrorAction Stop; $startedHere += $name }
            catch { Write-Log ("Could not start {0} during repair: {1}" -f $name,$_.Exception.Message) 'Warn' }
        }
    }
    foreach ($name in @('GamingServicesNet','GamingServices')) {
        if ($startedHere -notcontains $name) { continue }
        try { Stop-Service -Name $name -ErrorAction Stop }
        catch { Write-Log ("Could not return {0} to idle after repair: {1}" -f $name,$_.Exception.Message) 'Warn' }
    }
}

function Repair-XboxSuite {
    Write-Log 'Repairing the Xbox app and related gaming components...' 'Action'
    $apps = @($script:MicrosoftAppCatalog | Where-Object { $_.Name -in @('Xbox app','Xbox Game Bar','Gaming Services','Xbox Identity Provider') })
    $errors = @()
    foreach ($app in $apps) {
        try { Repair-StorePackage -App $app -Reinstall } catch { $errors += ("{0}: {1}" -f $app.Name,$_.Exception.Message); Write-Log $errors[-1] 'Error' }
    }
    foreach ($name in @('Microsoft.Xbox.TCUI','Microsoft.XboxSpeechToTextOverlay')) {
        try {
            $pkg = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($pkg -and $pkg.InstallLocation) {
                $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
                if (Test-Path $manifest) { Add-AppxPackage -Path $manifest -Register -DisableDevelopmentMode -ErrorAction Stop }
            }
        } catch { Write-Log ("Optional Xbox component {0} could not be re-registered: {1}" -f $name,$_.Exception.Message) 'Warn' }
    }
    Repair-XboxServiceConfiguration
    if ($errors.Count) { throw ($errors -join ' | ') }
    Write-Log 'Xbox app, Game Bar, Gaming Services, and Xbox Identity Provider repair completed.' 'Success'
}

function Invoke-GamingRepair {
    $exe = Join-Path $PSScriptRoot 'GamingRepairTool.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $PSScriptRoot 'Tools\GamingRepairTool.exe' }
    if (Test-Path $exe) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $exe
            $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
            if ($sig.Status -eq 'Valid' -and $signer -match 'CN=Microsoft') {
                Write-Log 'Running Microsoft Gaming Repair Tool...' 'Action'
                Start-Process -FilePath $exe -Wait
            } else { Write-Log ("Gaming Repair Tool not trusted (status: {0}, signer: {1}); using package repair." -f $sig.Status,$signer) 'Warn' }
        } catch { Write-Log ("Gaming Repair Tool could not run: {0}; using package repair." -f $_.Exception.Message) 'Warn' }
    }
    Repair-XboxSuite
}

function Restore-MsApps {
    Write-Log 'Restoring Microsoft apps whose package files remain on this PC...' 'Action'
    Get-AppxPackage | Where-Object { $_.Publisher -match 'Microsoft' -and $_.InstallLocation } | ForEach-Object {
        $manifest = Join-Path $_.InstallLocation 'AppxManifest.xml'
        if (Test-Path $manifest) { try { Add-AppxPackage -Path $manifest -Register -DisableDevelopmentMode -ErrorAction Stop } catch { Write-Log ("Could not re-register {0}: {1}" -f $_.Name,$_.Exception.Message) 'Warn' } }
    }
    $errors = @()
    foreach ($app in $script:MicrosoftAppCatalog) {
        try { Repair-StorePackage $app } catch { $errors += ("{0}: {1}" -f $app.Name,$_.Exception.Message); Write-Log $errors[-1] 'Error' }
    }
    Repair-XboxServiceConfiguration
    if ($errors.Count) { throw ($errors -join ' | ') }
    Write-Log 'Microsoft app restoration completed.' 'Success'
}

function Set-HvciEnabledForAntiCheat {
    $bcdedit = Join-Path $env:windir 'System32\bcdedit.exe'
    if (-not (Test-Path $bcdedit)) { throw 'BCDEdit is not available; HVCI was not configured.' }
    foreach ($setting in @('hypervisorlaunchtype','vsmlaunchtype')) {
        $output = & $bcdedit /set '{current}' $setting Auto 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = (@($output) -join ' ').Trim()
            throw ("Could not set {0} to Auto (exit code {1}). {2}" -f $setting,$exitCode,$detail)
        }
    }

    $deviceGuard = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    $hvci = Join-Path $deviceGuard 'Scenarios\HypervisorEnforcedCodeIntegrity'
    Set-RegValue -Path $deviceGuard -Name 'EnableVirtualizationBasedSecurity' -Value 1 -Type 'DWord'
    Set-RegValue -Path $deviceGuard -Name 'RequirePlatformSecurityFeatures' -Value 1 -Type 'DWord'
    Set-RegValue -Path $deviceGuard -Name 'Locked' -Value 0 -Type 'DWord'
    Set-RegValue -Path $hvci -Name 'Enabled' -Value 1 -Type 'DWord'
    Set-RegValue -Path $hvci -Name 'Locked' -Value 0 -Type 'DWord'
    Set-RegValue -Path $hvci -Name 'WasEnabledBy' -Value 2 -Type 'DWord'
    if ($script:Rows.ContainsKey('sec.vbs')) {
        $entry = $script:Rows['sec.vbs']
        if ($entry.Combo) { $entry.Combo.SelectedItem='On' }
        if ($entry.Status) { $entry.Status.Text='Configured On; restart required' }
    }
    Write-Log 'HVCI/VBS is configured to enable at the next boot. Hardware virtualization must also be enabled in UEFI/BIOS.' 'Warn'
}

function Enable-ControlFlowGuard {
    $cmd = Get-Command Set-ProcessMitigation -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'Windows Exploit Protection PowerShell cmdlets are unavailable on this Windows installation.' }
    Set-ProcessMitigation -System -Enable CFG -ErrorAction Stop
    Write-Log 'Enabled system-wide Control Flow Guard. Restart affected apps (or Windows) for the setting to take effect.' 'Warn'
}
 
function Repair-StartSearch {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $item = Get-Item -LiteralPath $pol -ErrorAction SilentlyContinue
    if ($item -and @($item.GetValueNames()) -contains 'LetAppsRunInBackground') {
        $allow = @($item.GetValue('LetAppsRunInBackground_ForceAllowTheseApps')) | Where-Object { $_ }
        Set-RegValue -Path $pol -Name 'LetAppsRunInBackground_ForceAllowTheseApps' -Value ([string[]]@(@($allow) + $script:ShellBackgroundApps | Select-Object -Unique)) -Type MultiString
    }
    Remove-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name 'GlobalUserDisabled'
    Remove-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BackgroundAppGlobalToggle'
    foreach ($s in 'TextInputManagementService','TabletInputService') {
        if ((Test-ServiceExists $s) -and (Get-ServiceStartValue $s) -eq 4) { [void](Set-ServiceStart -Name $s -StartType $(if ($s -eq 'TextInputManagementService') { 'Automatic' } else { 'Manual' })); Start-Service -Name $s -ErrorAction SilentlyContinue }
    }
    Enable-ScheduledTask -TaskPath '\Microsoft\Windows\TextServicesFramework\' -TaskName 'MsCtfMonitor' -ErrorAction SilentlyContinue | Out-Null
    if (-not (Get-Process ctfmon -ErrorAction SilentlyContinue)) { Start-Process "$env:SystemRoot\System32\ctfmon.exe" -ErrorAction SilentlyContinue }
    $wv2Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\1694661260'
    if (Test-Path -LiteralPath $wv2Key) { Remove-Item -LiteralPath $wv2Key -Recurse -Force -ErrorAction SilentlyContinue; Write-Log 'Removed the Windows Search WebView2 override; the search panel uses its normal renderer again after a restart.' 'Success' }
    if ((Test-ServiceExists 'TextInputManagementService') -and (Get-ServiceStartValue 'TextInputManagementService') -ne 2) { Set-ServiceStartNow -Name 'TextInputManagementService' -Start 2; Start-Service -Name 'TextInputManagementService' -ErrorAction SilentlyContinue }
    $ctfTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\TextServicesFramework\' -TaskName 'MsCtfMonitor' -ErrorAction SilentlyContinue
    if (-not $ctfTask -or [string]$ctfTask.State -eq 'Disabled') { Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ctfmon' -Value (Join-Path $env:SystemRoot 'System32\ctfmon.exe') -Type String; Write-Log 'The text input task could not be turned back on, so ctfmon now starts from the Run key at sign-in.' 'Info' }
    foreach ($pn in 'Microsoft.Windows.StartMenuExperienceHost','MicrosoftWindows.Client.CBS','Microsoft.Windows.ShellExperienceHost') {
        foreach ($pk in @(Get-AppxPackage -AllUsers -Name $pn -ErrorAction SilentlyContinue)) {
            $mf = Join-Path ([string]$pk.InstallLocation) 'AppxManifest.xml'
            if (Test-Path -LiteralPath $mf) { try { Add-AppxPackage -DisableDevelopmentMode -Register $mf -ErrorAction Stop } catch { } }
        }
    }
    Get-Process SearchHost,SearchApp,StartMenuExperienceHost,TextInputHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log 'Start and Search can run in the background again and the text input service is running. Press Windows and type to test; sign out once if it still needs a click.' 'Success'
}

$script:ExtraPlaceboValues = @(
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Pattern='^TdrLevel$'; Bad={ param($x) [int]$x -ne 3 }; Default=$null; Sev='warn'; Title='GPU timeout recovery changed'; Why='TdrLevel other than the default turns off or changes GPU hang recovery: a driver hang then freezes or blue-screens the PC instead of recovering in a few seconds.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Pattern='^TdrDelay$'; Bad={ param($x) [int]$x -gt 10 }; Default=$null; Sev='info'; Title='GPU timeout delay raised'; Why='A long TdrDelay only hides a hung GPU for longer before Windows recovers it. Keep it only if a rendering or AI app told you to.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; Pattern='^(TcpWindowSize|GlobalMaxTcpWindowSize)$'; Bad=$null; Default=$null; Sev='warn'; Title='TCP window size forced'; Why='A fixed TCP window overrides receive-window auto-tuning and caps download speed on fast connections. It does nothing for game ping, which runs over UDP.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; Pattern='^Tcp1323Opts$'; Bad={ param($x) [int]$x -eq 0 }; Default=$null; Sev='warn'; Title='TCP window scaling turned off'; Why='Tcp1323Opts=0 turns off TCP window scaling, which limits downloads on fast connections. The Windows default already has it on.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'; Pattern='^(TcpTimedWaitDelay|MaxUserPort|DefaultTTL)$'; Bad=$null; Default=$null; Sev='info'; Title='Old TCP tweak-guide value'; Why='A server-tuning value from old guides. Games use UDP, so it has no effect on ping or FPS.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'; Pattern='^IRPStackSize$'; Bad=$null; Default=$null; Sev='info'; Title='File-sharing tweak-guide value'; Why='IRPStackSize only affects sharing files from this PC over the network. It does nothing for games or internet speed.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Pattern='^IRQ\d+Priority$'; Bad=$null; Default=$null; Sev='info'; Title='IRQ priority tweak-guide value'; Why='IRQ priority values have had no effect since Windows 2000; the interrupt controller ignores them.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Pattern='^(SecondLevelDataCache|NonPagedPoolQuota|PagedPoolQuota)$'; Bad=$null; Default=$null; Sev='info'; Title='Old memory tweak-guide value'; Why='Ignored on 64-bit Windows 10 and 11; the memory manager sizes these itself.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Pattern='^MoveImages$'; Bad={ param($x) [int]$x -eq 0 }; Default=$null; Sev='warn'; Title='Address space randomization turned off'; Why='MoveImages=0 turns off ASLR for programs, which makes malware exploits much easier and gives no measurable FPS gain.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Pattern='^DisableExceptionChainValidation$'; Bad={ param($x) [int]$x -eq 1 }; Default=$null; Sev='warn'; Title='Exception chain protection (SEHOP) turned off'; Why='Turning off SEHOP removes an exploit protection with no measurable FPS gain, and some anti-cheats check it.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Pattern='^(DistributeTimers|ThreadDpcEnable|SerializeTimerExpiration|DpcWatchdogProfileOffset|MaximumSharedReadyQueueSize|DpcTimeout|DpcWatchdogPeriod)$'; Bad=$null; Default=$null; Sev='info'; Title='Undocumented kernel scheduler value'; Why='An undocumented kernel value from latency guides. Windows 11 overrides or ignores most of them, and some raise DPC latency under load. Measured gains are not repeatable.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power'; Pattern='^CsEnabled$'; Bad={ param($x) [int]$x -eq 0 }; Default=$null; Sev='warn'; Title='Modern Standby turned off'; Why='On PCs that only support Modern Standby this removes Sleep entirely; on others it can break wake from sleep. It does not change gaming performance.' }
    @{ Path='HKCU:\Control Panel\Desktop'; Pattern='^ForegroundLockTimeout$'; Bad={ param($x) [int]$x -lt 200000 }; Default=200000; Sev='warn'; Title='Apps can steal focus'; Why='A low ForegroundLockTimeout lets background apps and launchers pull focus away from your game mid-match and minimize it.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'; Pattern='^EnableSuperfetch$'; Bad=$null; Default=$null; Sev='info'; Title='Old Superfetch value'; Why='A Windows Vista/7 value. Windows 10 and 11 ignore it; the SysMain service controls prefetching.' }
    @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Pattern='^NtfsMemoryUsage$'; Bad=$null; Default=$null; Sev='info'; Title='Old NTFS memory value'; Why='Raises NTFS paged pool use for file servers. No effect on game loading on an SSD.' }
)
$script:UsbVendors = @{ '0416'='Winbond / Nuvoton (often an RGB, fan-hub or AIO cooler controller)'; '046D'='Logitech'; '1B1C'='Corsair'; '1532'='Razer'; '0B05'='ASUS'; '1462'='MSI'; '048D'='Integrated Technology Express (motherboard RGB controller)'; '0CF2'='ENE Technology (RGB controller)'; '26CE'='ASRock'; '0951'='HyperX / Kingston'; '1038'='SteelSeries'; '1E71'='NZXT'; '2516'='Cooler Master'; '0C45'='Microdia / Sonix (keyboards, webcams)'; '258A'='Sinowealth (keyboards and mice)'; '1A86'='WCH (USB serial chips)'; '8087'='Intel'; '1022'='AMD'; '045E'='Microsoft'; '054C'='Sony'; '057E'='Nintendo'; '28DE'='Valve'; '31E3'='Wooting' }
function Reset-RionDevice {
    param([string]$InstanceId)
    $pnp = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    Write-Log ('Removing {0} from Windows and detecting it again...' -f $InstanceId) 'Action'
    $r = & $pnp /remove-device $InstanceId 2>&1 | Out-String
    Start-Sleep -Seconds 2
    $null = & $pnp /scan-devices 2>&1
    Start-Sleep -Seconds 3
    $now = Get-CimInstance Win32_PnPEntity -Filter ("PNPDeviceID='{0}'" -f ($InstanceId -replace '\\','\\')) -ErrorAction SilentlyContinue
    if ($now -and [int]$now.ConfigManagerErrorCode -eq 0) { Write-Log 'The device started normally after being detected again.' 'Success' }
    elseif (-not $now) { Write-Log 'The device was removed and has not come back yet. Unplug it and plug it in again, or restart.' 'Warn' }
    else { Write-Log ('The device still reports error code {0}. Unplug it and use a rear USB port, then update its software or firmware from the maker. Output: {1}' -f $now.ConfigManagerErrorCode,$r.Trim()) 'Warn' }
}
function Get-StartSearchProblems {
    $why = @()
    if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\1694661260') { $why += 'the Windows Search WebView2 override is set' }
    $ctfTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\TextServicesFramework\' -TaskName 'MsCtfMonitor' -ErrorAction SilentlyContinue
    $ctfRun = [string](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ctfmon' -ErrorAction SilentlyContinue).ctfmon
    if ($ctfTask -and [string]$ctfTask.State -eq 'Disabled' -and -not $ctfRun) { $why += 'the text input task (MsCtfMonitor) is disabled' }
    if ((Test-ServiceExists 'TextInputManagementService') -and (Get-ServiceStartValue 'TextInputManagementService') -eq 4) { $why += 'the Text Input Management service is disabled' }
    if (-not (Get-Process ctfmon -ErrorAction SilentlyContinue)) { $why += 'ctfmon.exe is not running' }
    $pol = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue
    if ($pol -and [int]$pol.GetValue('LetAppsRunInBackground',0) -eq 2) {
        $allow = @($pol.GetValue('LetAppsRunInBackground_ForceAllowTheseApps'))
        if ($allow -notcontains 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy' -or $allow -notcontains 'Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy') { $why += 'background apps are blocked without an exception for Start and Search' }
    }
    return $why
}
function Repair-WindowsUpdate {
    foreach ($pair in @(@('wuauserv',3),@('UsoSvc',2),@('WaaSMedicSvc',3),@('BITS',3),@('DoSvc',2),@('CryptSvc',2),@('TrustedInstaller',3))) {
        if ((Test-ServiceExists $pair[0]) -and (Get-ServiceStartValue $pair[0]) -eq 4) { try { Set-ServiceStartNow -Name $pair[0] -Start $pair[1]; Write-Log ('{0} turned back on.' -f $pair[0]) 'Success' } catch { Write-Log ('{0}: {1}' -f $pair[0],$_.Exception.Message) 'Warn' } }
    }
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    foreach ($n in 'DisableWindowsUpdateAccess','DoNotConnectToWindowsUpdateInternetLocations','WUServer','WUStatusServer','SetDisableUXWUAccess') { Remove-RegValue -Path $wu -Name $n }
    foreach ($n in 'NoAutoUpdate','UseWUServer') { Remove-RegValue -Path ($wu + '\AU') -Name $n }
    foreach ($tp in '\Microsoft\Windows\WindowsUpdate\','\Microsoft\Windows\UpdateOrchestrator\') { foreach ($tk in @(Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | Where-Object { [string]$_.State -eq 'Disabled' })) { try { Enable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null } catch { } } }
    foreach ($n in 'wuauserv','UsoSvc','BITS') { Start-Service -Name $n -ErrorAction SilentlyContinue }
    Write-Log 'Windows Update is back on: its services, tasks and policies are at the Windows defaults. Your deferral and driver choices are kept.' 'Success'
    Start-Process 'ms-settings:windowsupdate'
}
function Repair-Defender {
    try { Invoke-Action @{ kind='defender'; enable=$true } } catch { Write-Log ('Defender restore: {0}' -f $_.Exception.Message) 'Warn' }
    $wd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    foreach ($n in 'DisableAntiSpyware','DisableAntiVirus','DisableRoutinelyTakingAction') { Remove-RegValue -Path $wd -Name $n }
    foreach ($n in 'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection','DisableScanOnRealtimeEnable','DisableIOAVProtection') { Remove-RegValue -Path ($wd + '\Real-Time Protection') -Name $n }
    foreach ($n in 'SpynetReporting','SubmitSamplesConsent','DisableBlockAtFirstSeen') { Remove-RegValue -Path ($wd + '\Spynet') -Name $n }
    foreach ($tk in @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction SilentlyContinue | Where-Object { [string]$_.State -eq 'Disabled' })) { try { Enable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null } catch { } }
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch { }
    Start-Service -Name 'SecurityHealthService' -ErrorAction SilentlyContinue
    Write-Log 'Microsoft Defender policies were removed and its tasks turned back on. Restart, then check Windows Security; real-time protection comes back on by itself.' 'Success'
    Start-Process 'windowsdefender://threat'
}
function Install-WingetPackage {
    param([string]$Id,[string]$Name)
    $winget = Get-RionWingetPath
    $wgArgs = "install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity"
    Write-Log ('Installing {0} through WinGet...' -f $Name) 'Action'
    $proc = Start-Process -FilePath $winget -ArgumentList $wgArgs -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -notin -1978335189,-1978335135) {
        Start-Process -FilePath $winget -ArgumentList 'source reset --force --disable-interactivity' -Wait -WindowStyle Hidden | Out-Null
        $proc = Start-Process -FilePath $winget -ArgumentList $wgArgs -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -notin -1978335189,-1978335135) { throw ('WinGet could not install {0} (exit code {1}).' -f $Name,$proc.ExitCode) }
    }
    Write-Log ('{0} is installed.' -f $Name) 'Success'
}
function Get-MissingRuntimes {
    $miss = @()
    if ([int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' -Name Installed -ErrorAction SilentlyContinue).Installed -ne 1) { $miss += @{ Id='Microsoft.VCRedist.2015+.x64'; Name='Visual C++ 2015-2022 runtime (64-bit)' } }
    if ([int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86' -Name Installed -ErrorAction SilentlyContinue).Installed -ne 1) { $miss += @{ Id='Microsoft.VCRedist.2015+.x86'; Name='Visual C++ 2015-2022 runtime (32-bit)' } }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\d3dx9_43.dll'))) { $miss += @{ Id='Microsoft.DirectX'; Name='DirectX End-User Runtime (DirectX 9-11 helper files)' } }
    return $miss
}
function Install-GameRuntimes {
    $miss = @(Get-MissingRuntimes)
    if (-not $miss.Count) { Write-Log 'Visual C++ 2015-2022 (64 and 32-bit) and the DirectX End-User Runtime are already installed.' 'Success'; return }
    foreach ($r in $miss) { try { Install-WingetPackage -Id $r.Id -Name $r.Name } catch { Write-Log $_.Exception.Message 'Error' } }
}
function Test-OptionalDevice {
    param($Device)
    $cls = [string]$Device.PNPClass
    $txt = ('{0} {1} {2}' -f [string]$Device.Name,(@($Device.CompatibleID) -join ' '),[string]$Device.PNPDeviceID)
    if ($cls -in 'Bluetooth','Infrared','Modem','Biometric','SmartCardReader','Camera','Image','WPD','Sensor','Printer','Ports','SDHost','MTD') { return $true }
    if ($txt -match '(?i)bluetooth|wireless|wi-?fi|wlan|802\.11|wwan|mobile broadband|\bnfc\b|fingerprint|card reader|sd host|infrared|CC_0280|CC_0D') { return $true }
    if ($cls -eq 'Net' -or $txt -match 'CC_0200') { if (@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }).Count) { return $true } }
    if ($cls -eq 'MEDIA' -and @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 0 }).Count) { return $true }
    return $false
}
function Start-RionAutoruns {
    $exe = @(@('Autoruns64.exe','Autoruns.exe') | ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if (-not $exe) { Write-Log 'Autoruns.exe is not next to Rion Tool. Opening the official Sysinternals download page.' 'Info'; Start-Process 'https://learn.microsoft.com/sysinternals/downloads/autoruns'; return }
    $sig = Get-AuthenticodeSignature -FilePath $exe
    if ($sig.Status -ne 'Valid' -or [string]$sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Autoruns.exe next to Rion Tool is not signed by Microsoft, so it was not started. Download it again from Sysinternals.' }
    Start-Process -FilePath $exe
}
function Invoke-AppReinstall {
    param($Checks)
    $apps = @($Checks | ForEach-Object { $_.Tag })
    if (-not $apps.Count) { return }
    if ([System.Windows.MessageBox]::Show(("Reinstall these Microsoft apps?`r`n`r`n" + (($apps | ForEach-Object { '- ' + $_.Name }) -join "`r`n") + "`r`n`r`nEach one is restored from files on this PC when possible, otherwise downloaded from the Microsoft Store catalog with WinGet. No Store window opens."),'Reinstall apps','OKCancel','Question') -ne 'OK') { return }
    foreach ($app in $apps) { try { Repair-StorePackage -App $app; Write-Log ('Reinstalled {0}.' -f $app.Name) 'Success' } catch { Write-Log ('Could not reinstall {0}: {1}' -f $app.Name,$_.Exception.Message) 'Error' } }
    try { Build-DebloatList -AutoCheck $false -ApplyPreset $false } catch { }
}
function Reset-NetworkTuning {
    $keywords = '*FlowControl','*InterruptModeration','ITR','*LsoV2IPv4','*LsoV2IPv6','*IPChecksumOffloadIPv4','*TCPChecksumOffloadIPv4','*TCPChecksumOffloadIPv6','*UDPChecksumOffloadIPv4','*UDPChecksumOffloadIPv6','*PacketCoalescing','*ReceiveBuffers','*TransmitBuffers','*UsoIPv4','*UsoIPv6','*RscIPv4','*RscIPv6','*RSSProfile','*RssBaseProcNumber','*NumRssQueues'
    Invoke-Action @{ kind='netAdvancedPropertyReset'; keywords=$keywords }
    Get-NetAdapterRss -ErrorAction SilentlyContinue | ForEach-Object { Set-NetAdapterRss -Name $_.Name -Enabled $true -ErrorAction SilentlyContinue }
    Get-NetAdapterRsc -ErrorAction SilentlyContinue | ForEach-Object { Set-NetAdapterRsc -Name $_.Name -IPv4Enabled $true -IPv6Enabled $true -ErrorAction SilentlyContinue }
    Invoke-Action @{ kind='nagle'; enable=$false }
    & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
    & netsh.exe int tcp set global rss=enabled | Out-Null
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log 'Network adapters are back to their driver defaults for offloads, flow control, interrupt moderation, buffers and RSS; Nagle values removed and TCP autotuning set to normal.' 'Success'
}

function Invoke-FullCleanup {
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $skip = 'D3D Shader Cache','DownloadsFolder','Recycle Bin','Previous Installations','Windows ESD installation files','User file versions','Device Driver Packages','System error memory dump files','System error minidump files'
    foreach ($h in @(Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue)) {
        if ($skip -contains $h.PSChildName) { Remove-ItemProperty -LiteralPath $h.PSPath -Name 'StateFlags0777' -ErrorAction SilentlyContinue }
        else { New-ItemProperty -LiteralPath $h.PSPath -Name 'StateFlags0777' -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null }
    }
    $steps = @'
$Host.UI.RawUI.WindowTitle = 'Rion Tool - full cleanup'
Write-Host '[1/7] DISM RestoreHealth' -ForegroundColor Cyan
DISM.exe /Online /Cleanup-Image /RestoreHealth
Write-Host '[2/7] SFC scannow' -ForegroundColor Cyan
sfc.exe /scannow
Write-Host '[3/7] Component store cleanup' -ForegroundColor Cyan
DISM.exe /Online /Cleanup-Image /StartComponentCleanup
Write-Host '[4/7] Temp folders' -ForegroundColor Cyan
foreach ($d in @($env:TEMP, "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\Temp")) { Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host '[5/7] Prefetch is kept (it speeds up app and game launches)' -ForegroundColor Cyan
Write-Host '[6/7] Disk Cleanup (keeps the DirectX shader cache, Downloads, Recycle Bin, previous Windows installs, the Reset this PC image, File History versions, older drivers for rollback and crash dumps)' -ForegroundColor Cyan
Start-Process -FilePath "$env:SystemRoot\System32\cleanmgr.exe" -ArgumentList '/sagerun:777' -Wait
Write-Host '[7/7] DNS cache' -ForegroundColor Cyan
ipconfig.exe /flushdns | Out-Null
Write-Host 'Cleanup finished. Restart Windows if SFC or DISM repaired files.' -ForegroundColor Green
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($steps))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand',$encoded)
    Write-Log 'Full cleanup started in its own window (DISM, SFC, temp, prefetch, Disk Cleanup without the DirectX shader cache). It can take 15-30 minutes.' 'Action'
}

function Remove-WindowsOld {
    $steps = @'
$Host.UI.RawUI.WindowTitle = 'Rion Tool - reclaim space'
Write-Host 'Resetting the component store (removes the ability to uninstall already-installed updates)...' -ForegroundColor Cyan
DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
$old = Join-Path $env:SystemDrive 'Windows.old'
if (Test-Path -LiteralPath $old) {
    Write-Host 'Removing previous Windows installation (Windows.old) via Disk Cleanup...' -ForegroundColor Cyan
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    foreach ($h in Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue) {
        $on = @('Previous Installations','Windows Upgrade Log Files','Update Cleanup','Temporary Setup Files') -contains $h.PSChildName
        New-ItemProperty -LiteralPath $h.PSPath -Name 'StateFlags0765' -Value ([int]$on) -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Start-Process -FilePath "$env:SystemRoot\System32\cleanmgr.exe" -ArgumentList '/sagerun:765' -Wait
} else { Write-Host 'No Windows.old folder present.' -ForegroundColor Green }
Write-Host 'Done. Rolling back to a previous Windows build is no longer possible after this.' -ForegroundColor Green
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($steps))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand',$encoded)
    Write-Log 'Started reclaiming space (component store reset and Windows.old removal) in its own window. This removes the option to uninstall updates or roll back the last Windows upgrade.' 'Warn'
}

function Measure-ComponentStore {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/k','DISM /Online /Cleanup-Image /AnalyzeComponentStore'
    Write-Log 'Opened a component store (WinSxS) analysis. It reports the actual size and whether a cleanup is recommended.' 'Action'
}

function Reset-MmcssDefaults {
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegValue -Path $sp -Name 'NetworkThrottlingIndex' -Value 10 -Type 'DWord'
    Set-RegValue -Path $sp -Name 'SystemResponsiveness' -Value 20 -Type 'DWord'
    Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 -Type 'DWord'
    Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff'
    foreach ($n in 'NoLazyMode','AlwaysOn','LazyModeTimeout') { Remove-RegValue -Path $sp -Name $n }
    $games = "$sp\Tasks\Games"
    Set-RegValue -Path $games -Name 'Affinity' -Value 0 -Type 'DWord'
    Set-RegValue -Path $games -Name 'Background Only' -Value 'False' -Type 'String'
    Set-RegValue -Path $games -Name 'Clock Rate' -Value 10000 -Type 'DWord'
    Set-RegValue -Path $games -Name 'GPU Priority' -Value 8 -Type 'DWord'
    Set-RegValue -Path $games -Name 'Priority' -Value 2 -Type 'DWord'
    Set-RegValue -Path $games -Name 'Scheduling Category' -Value 'Medium' -Type 'String'
    Set-RegValue -Path $games -Name 'SFIO Priority' -Value 'Normal' -Type 'String'
    Write-Log 'CPU scheduling (foreground boost 0x26, EcoQoS on) and multimedia scheduler values reset to Windows defaults. Restart to apply.' 'Success'
}
function Reset-ProcessorPowerDefaults {
    if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
    $sub = '54533251-82be-4824-96c1-47b60b740d00'
    $settings = [ordered]@{
        'Processor idle disable'                    = '5d76a2ca-e8c0-402f-a133-2158492d58ad'
        'Core parking minimum cores'                = '0cc5b647-c1df-4637-891a-dec35c318583'
        'Core parking minimum cores (class 1)'      = '0cc5b647-c1df-4637-891a-dec35c318584'
        'Core parking maximum cores'                = 'ea062031-0e34-4ff1-9b6d-eb1059334028'
        'Core parking maximum cores (class 1)'      = 'ea062031-0e34-4ff1-9b6d-eb1059334029'
        'Minimum processor state'                   = '893dee8e-2bef-41e0-89c6-b55d0929964c'
        'Minimum processor state (class 1)'         = '893dee8e-2bef-41e0-89c6-b55d0929964d'
        'Energy performance preference'             = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
        'Energy performance preference (class 1)'   = '36687f9e-e3a5-4dbf-b1dc-15eb381c6864'
    }
    $plan = [RionPowrProf]::ActiveScheme()
    $base = Get-PowerPlanBase $plan
    $changed = @(); $failed = @()
    foreach ($name in $settings.Keys) {
        $guid = $settings[$name]
        $def = Get-PowerSettingDefault -Base $base -Sub $sub -Setting $guid
        if (-not $def) { continue }
        $cur = [RionPowrProf]::Values($plan,$sub,$guid)
        if ($cur -and $cur[0] -eq $def[0] -and $cur[1] -eq $def[1]) { continue }
        $err = Set-PowerSettingValue -Plan $plan -Sub $sub -Setting $guid -Ac ([long]$def[0]) -Dc ([long]$def[1]) -NoJournal
        if ($err) { $failed += ('{0}: {1}' -f $name,$err) } else { $changed += ('{0} {1}/{2}' -f $name,$def[0],$def[1]) }
    }
    [void][RionPowrProf]::SetActive($plan)
    $planName = [string][RionPowrProf]::Name($plan,$null,$null)
    if ($failed.Count -gt 0) { Write-Log ('Processor power reset on "{0}" could not set: {1}' -f $planName,($failed -join '; ')) 'Error' }
    if ($changed.Count -gt 0) { Write-Log ('Processor power settings on "{0}" reset to the plan defaults (AC/DC): {1}' -f $planName,($changed -join ', ')) 'Success' }
    elseif ($failed.Count -eq 0) { Write-Log ('Processor power settings on "{0}" already match the plan defaults.' -f $planName) 'Success' }
}

function Repair-SignInServices {
    $defaults = [ordered]@{ wlidsvc='Manual'; TokenBroker='Manual'; NgcSvc='Manual'; NgcCtnrSvc='Manual'; KeyIso='Manual'; VaultSvc='Manual'; CryptSvc='Automatic'; GoogleChromeElevationService='Manual'; MicrosoftEdgeElevationService='Manual'; BraveElevationService='Manual' }
    $changed = @()
    foreach ($name in $defaults.Keys) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        if (-not (Test-Path $key)) { continue }
        $want = [int]$script:StartMap[$defaults[$name]]
        $now = Get-ServiceStartValue $name
        if ($null -ne $now -and [int]$now -eq $want) { continue }
        try { [void](Set-ServiceStart -Name $name -StartType $defaults[$name]); $changed += ('{0} -> {1}' -f $name,$defaults[$name]) }
        catch { Write-Log ("Could not restore {0}: {1}" -f $name,$_.Exception.Message) 'Warn' }
    }
    try { Start-Service -Name 'CryptSvc' -ErrorAction SilentlyContinue } catch { }
    if ($changed.Count) { Write-Log ('Sign-in and credential services restored to Windows defaults: {0}. Restart, then sign back in to Microsoft apps. Logins that apps already lost are not brought back.' -f ($changed -join ', ')) 'Success' }
    else { Write-Log 'Sign-in and credential services are already at their Windows defaults.' 'Success' }
}

function Clear-UpdateAndStoreCaches {
    foreach ($svc in 'wuauserv','bits','DoSvc') { try { Stop-Service $svc -Force -ErrorAction SilentlyContinue } catch {} }
    Get-ChildItem -LiteralPath "$env:SystemRoot\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}
    foreach ($svc in 'wuauserv','bits','DoSvc') { try { Start-Service $svc -ErrorAction SilentlyContinue } catch {} }
    Start-Process 'wsreset.exe' -ArgumentList '-i' -ErrorAction SilentlyContinue
    Write-Log 'Cleared the Windows Update download cache and Delivery Optimization cache and started a Microsoft Store cache reset. Store app lists refresh on next open.' 'Success'
}

$script:NpiMinVersion = [version]'3.0.1.14'
$script:NpiReleases = 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases'
$script:NvidiaDir = Join-Path $script:DataDir 'nvidia'
$script:NvidiaStatePath = Join-Path $script:NvidiaDir 'applied.json'
$script:FortniteProfileName = 'Fortnite'
$script:FortniteExe = 'FortniteClient-Win64-Shipping.exe'
$script:NipPerformance = @(
    @{ Id=0x1057EB71; Value=1;  Default=5; Name='Power management mode: Prefer maximum performance' }
    @{ Id=0x007BA09E; Value=1;  Default=0; Name='Maximum pre-rendered frames: 1' }
    @{ Id=0x0005F543; Value=1;  Default=0; Name='Low Latency Mode (control panel state): On' }
    @{ Id=0x00CE2691; Value=20; Default=0; Name='Texture filtering - Quality: High performance' }
    @{ Id=0x00E73211; Value=1;  Default=0; Name='Texture filtering - Anisotropic sample optimization: On' }
    @{ Id=0x0084CD70; Value=1;  Default=0; Name='Texture filtering - Anisotropic filter optimization: On' }
    @{ Id=0x002ECAF2; Value=1;  Default=0; Name='Texture filtering - Trilinear optimization: On' }
    @{ Id=0x0019BB68; Value=1;  Default=0; Name='Texture filtering - Negative LOD bias: Clamp' }
    @{ Id=0x50166C5E; Value=0;  Default=1; Name='CUDA - Force P2 State: Off' }
)
$script:NipFortnitePotato = @(
    @{ Id=0x00738E8F; Value=120; Default=0; Name='Texture filtering - LOD Bias (DX): +15.0' }
    @{ Id=0x00638E8F; Value=0;   Default=1; Name='Texture filtering - Driver Controlled LOD Bias: Off' }
    @{ Id=0x10D48A85; Value=8;   Default=0; Name='Antialiasing - Transparency Supersampling: AA_MODE_REPLAY_MODE_ALL' }
    @{ Id=0x10D2BB16; Value=1;   Default=0; Name='Anisotropic filtering mode: User-defined / Off' }
    @{ Id=0x101E61A9; Value=1;   Default=1; Name='Anisotropic filtering setting: Off (Linear)' }
)

function ConvertTo-NipXml {
    param([array]$Profiles,[switch]$Defaults)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-16"?>')
    [void]$sb.AppendLine('<ArrayOfProfile>')
    foreach ($p in $Profiles) {
        [void]$sb.AppendLine('  <Profile>')
        [void]$sb.AppendLine(('    <ProfileName>{0}</ProfileName>' -f [Security.SecurityElement]::Escape($p.Name)))
        [void]$sb.AppendLine('    <Executeables>')
        foreach ($e in @($p.Exes)) { [void]$sb.AppendLine(('      <string>{0}</string>' -f [Security.SecurityElement]::Escape($e))) }
        [void]$sb.AppendLine('    </Executeables>')
        [void]$sb.AppendLine('    <Settings>')
        foreach ($s in @($p.Settings)) {
            $v = if ($Defaults) { $s.Default } else { $s.Value }
            [void]$sb.AppendLine('      <ProfileSetting>')
            [void]$sb.AppendLine(('        <SettingNameInfo>{0}</SettingNameInfo>' -f [Security.SecurityElement]::Escape($(if ($Defaults) { 'Driver default: ' + ($s.Name -replace ':.*$','') } else { $s.Name }))))
            [void]$sb.AppendLine(('        <SettingID>{0}</SettingID>' -f [uint32]$s.Id))
            [void]$sb.AppendLine(('        <SettingValue>{0}</SettingValue>' -f [uint32]$v))
            [void]$sb.AppendLine('        <ValueType>Dword</ValueType>')
            [void]$sb.AppendLine('      </ProfileSetting>')
        }
        [void]$sb.AppendLine('    </Settings>')
        [void]$sb.AppendLine('  </Profile>')
    }
    [void]$sb.AppendLine('</ArrayOfProfile>')
    return $sb.ToString()
}

function Get-RionNipProfiles {
    param([ValidateSet('Performance','FortnitePotato','Defaults')][string]$Kind)
    $base = @{ Name='Base Profile'; Exes=@(); Settings=$script:NipPerformance }
    $fortnite = @{ Name=$script:FortniteProfileName; Exes=@($script:FortniteExe); Settings=@($script:NipPerformance | Where-Object { $_.Id -ne 0x0005F543 }) + $script:NipFortnitePotato }
    switch ($Kind) {
        'Performance'    { return @($base) }
        'FortnitePotato' { return @($base,$fortnite) }
        'Defaults'       { return @($base,$fortnite) }
    }
}

function Export-RionNipFiles {
    param([string]$Folder = $script:NvidiaDir)
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    $files = [ordered]@{
        Performance    = Join-Path $Folder 'Rion-NVIDIA-Performance.nip'
        FortnitePotato = Join-Path $Folder 'Rion-Fortnite-Potato.nip'
        Defaults       = Join-Path $Folder 'Rion-NVIDIA-Restore-Defaults.nip'
    }
    foreach ($k in @($files.Keys)) {
        $xml = ConvertTo-NipXml -Profiles (Get-RionNipProfiles $k) -Defaults:($k -eq 'Defaults')
        [IO.File]::WriteAllText($files[$k],$xml,[Text.Encoding]::Unicode)
    }
    return $files
}

$script:NvDrsSource = @'
using System;
using System.Runtime.InteropServices;
public static class RionNvDrs {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr lib, string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr QueryInterface(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NoArgs();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionOut(ref IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionIn(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FindApp(IntPtr session, [MarshalAs(UnmanagedType.LPWStr)] string app, ref IntPtr profile, IntPtr appInfo);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ProfileInfo(IntPtr session, IntPtr profile, IntPtr info);
    public static string LastError;
    static T Fn<T>(QueryInterface qi, uint id) where T : class {
        IntPtr p = qi(id);
        return p == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    static IntPtr Zeroed(int size) {
        IntPtr p = Marshal.AllocHGlobal(size);
        Marshal.Copy(new byte[size], 0, p, size);
        return p;
    }
    public static string FindProfileForApp(string exe) {
        LastError = null;
        IntPtr lib = LoadLibrary(IntPtr.Size == 8 ? "nvapi64.dll" : "nvapi.dll");
        if (lib == IntPtr.Zero) { LastError = "nvapi64.dll is not installed (no NVIDIA driver)."; return null; }
        IntPtr qp = GetProcAddress(lib, "nvapi_QueryInterface");
        if (qp == IntPtr.Zero) { LastError = "nvapi_QueryInterface is missing."; return null; }
        QueryInterface qi = (QueryInterface)Marshal.GetDelegateForFunctionPointer(qp, typeof(QueryInterface));
        NoArgs init = Fn<NoArgs>(qi, 0x0150E828);
        SessionOut create = Fn<SessionOut>(qi, 0x0694D52E);
        SessionIn destroy = Fn<SessionIn>(qi, 0xDAD9CFF8);
        SessionIn load = Fn<SessionIn>(qi, 0x375DBD6B);
        FindApp find = Fn<FindApp>(qi, 0xEEE566B2);
        ProfileInfo info = Fn<ProfileInfo>(qi, 0x61CD6FD6);
        if (init == null || create == null || destroy == null || load == null || find == null || info == null) { LastError = "The NVIDIA driver does not expose the profile API."; return null; }
        int r = init();
        if (r != 0) { LastError = "NvAPI_Initialize returned " + r + "."; return null; }
        IntPtr session = IntPtr.Zero;
        r = create(ref session);
        if (r != 0) { LastError = "DRS_CreateSession returned " + r + "."; return null; }
        try {
            r = load(session);
            if (r != 0) { LastError = "DRS_LoadSettings returned " + r + "."; return null; }
            int[][] versions = new int[][] { new int[] { 20492, 4 }, new int[] { 16396, 3 } };
            foreach (int[] v in versions) {
                IntPtr app = Zeroed(v[0]);
                IntPtr profile = IntPtr.Zero;
                try {
                    Marshal.WriteInt32(app, 0, v[0] | (v[1] << 16));
                    r = find(session, exe, ref profile, app);
                } finally { Marshal.FreeHGlobal(app); }
                if (r == -9) { continue; }
                if (r == -166 || r == -163) { return ""; }
                if (r != 0) { LastError = "DRS_FindApplicationByName returned " + r + "."; return null; }
                IntPtr pi = Zeroed(4116);
                try {
                    Marshal.WriteInt32(pi, 0, 4116 | (1 << 16));
                    r = info(session, profile, pi);
                    if (r != 0) { LastError = "DRS_GetProfileInfo returned " + r + "."; return null; }
                    return Marshal.PtrToStringUni(IntPtr.Add(pi, 4));
                } finally { Marshal.FreeHGlobal(pi); }
            }
            LastError = "The driver rejected every application structure version.";
            return null;
        } finally { destroy(session); }
    }
}
'@

function Resolve-NvidiaAppProfile {
    param([string]$Exe)
    if (-not ('RionNvDrs' -as [type])) {
        try { Add-Type -TypeDefinition $script:NvDrsSource -ErrorAction Stop } catch { Write-Log ("NVIDIA profile lookup could not load: {0}" -f $_.Exception.Message) 'Warn'; return $null }
    }
    $name = [RionNvDrs]::FindProfileForApp($Exe)
    if ($null -eq $name) { Write-Log ("Could not ask the NVIDIA driver which profile owns {0}: {1}" -f $Exe,[RionNvDrs]::LastError) 'Warn' }
    return $name
}

function Update-FortniteProfileName {
    $found = Resolve-NvidiaAppProfile $script:FortniteExe
    if ($found) {
        $script:FortniteProfileName = $found
        Write-Log ("The NVIDIA driver keeps {0} in the profile '{1}'; the Fortnite settings go there." -f $script:FortniteExe,$found) 'Info'
        return $true
    }
    if ($found -eq '') {
        $script:FortniteProfileName = 'Fortnite'
        Write-Log ("No NVIDIA driver profile contains {0} yet, so a new 'Fortnite' profile is created for it." -f $script:FortniteExe) 'Info'
        return $true
    }
    return $false
}

function Test-NvidiaGpuPresent {
    if (@($script:Env.GpuVendors) -contains 'NVIDIA') { return $true }
    return [bool](@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|GeForce|Quadro|RTX' }).Count)
}

function Find-NvidiaProfileInspector {
    $roots = @($PSScriptRoot,(Join-Path $script:DataDir 'tools'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'Desktop'),$env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $found = foreach ($r in $roots) { Get-ChildItem -LiteralPath $r -Filter 'nvidiaProfileInspector.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue }
    $best = $found | ForEach-Object {
        $v = [version]'0.0'
        try { $v = [version](($_.VersionInfo.FileVersion -replace '[^\d\.]','').Trim('.')) } catch { }
        [pscustomobject]@{ Path=$_.FullName; Version=$v }
    } | Sort-Object Version -Descending | Select-Object -First 1
    return $best
}

function Get-UsableProfileInspector {
    $npi = Find-NvidiaProfileInspector
    if ($npi -and $npi.Version -ge $script:NpiMinVersion) { return $npi }
    $why = if ($npi) { "Found NVIDIA Profile Inspector {0} at`r`n{1}`r`nbut version {2} or newer is required: older versions only support Replace imports, which reset the global profile and strip apps from game profiles." -f $npi.Version,$npi.Path,$script:NpiMinVersion } else { 'NVIDIA Profile Inspector was not found next to Rion Tool, in Downloads, on the Desktop or in Program Files.' }
    $msg = "{0}`r`n`r`nRion Tool does not download it. Get the latest release (nvidiaProfileInspector.zip) from GitHub and extract it into the Rion Tool folder:`r`n{1}`r`n`r`nOpen the releases page now?" -f $why,$PSScriptRoot
    if ([System.Windows.MessageBox]::Show($msg,'NVIDIA Profile Inspector needed','YesNo','Information') -eq 'Yes') { Start-Process $script:NpiReleases }
    return $null
}

function Backup-NvidiaProfiles {
    param($Npi)
    $dir = Split-Path -Parent $Npi.Path
    $before = @(Get-ChildItem -LiteralPath $dir -Filter 'CustomProfiles_*.nip' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $proc = Start-Process -FilePath $Npi.Path -ArgumentList '-exportCustomized' -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
    $new = Get-ChildItem -LiteralPath $dir -Filter 'CustomProfiles_*.nip' -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $new) { return $null }
    $dest = Join-Path $script:BackupDir $new.Name
    Copy-Item -LiteralPath $new.FullName -Destination $dest -Force
    Remove-Item -LiteralPath $new.FullName -Force -ErrorAction SilentlyContinue
    return $dest
}

function Test-NvidiaNipApplied {
    param($Npi,[string]$Kind)
    $export = Backup-NvidiaProfiles $Npi
    if (-not $export) { return 'Could not read the driver profiles back to verify the import.' }
    try { [xml]$x = [IO.File]::ReadAllText($export) } catch { return 'The verification export could not be parsed.' }
    $problems = @()
    foreach ($p in (Get-RionNipProfiles $Kind)) {
        $node = @($x.ArrayOfProfile.Profile | Where-Object { $_.ProfileName -eq $p.Name }) | Select-Object -First 1
        if (-not $node) { $problems += ("Profile '{0}' is missing from the driver after import." -f $p.Name); continue }
        foreach ($s in $p.Settings) {
            $want = if ($Kind -eq 'Defaults') { [uint32]$s.Default } else { [uint32]$s.Value }
            $got = @($node.Settings.ProfileSetting | Where-Object { [uint32]$_.SettingID -eq [uint32]$s.Id }) | Select-Object -First 1
            if ($Kind -eq 'Defaults' -and -not $got) { continue }
            if (-not $got -or [uint32]$got.SettingValue -ne $want) { $problems += ("{0}: {1} expected {2}, driver has {3}" -f $p.Name,$s.Name,$want,$(if ($got) { $got.SettingValue } else { 'nothing' })) }
        }
    }
    Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue
    return ($problems -join "`r`n")
}

function Invoke-NvidiaNipImport {
    param([ValidateSet('Performance','FortnitePotato','Defaults')][string]$Kind)
    if (-not (Test-NvidiaGpuPresent)) { [System.Windows.MessageBox]::Show('No NVIDIA graphics card was found, so there is nothing for NVIDIA Profile Inspector to change.','NVIDIA profile','OK','Information') | Out-Null; return }
    $npi = Get-UsableProfileInspector
    if (-not $npi) { return }
    if ($Kind -ne 'Performance' -and -not (Update-FortniteProfileName)) {
        if ([System.Windows.MessageBox]::Show(("Rion Tool could not ask the NVIDIA driver which profile holds {0}, so it would have to assume the profile is named '{1}'. If that is wrong, the import of the Fortnite part fails safely and is reported.`r`n`r`nContinue anyway?" -f $script:FortniteExe,$script:FortniteProfileName),'NVIDIA profile','OKCancel','Warning') -ne 'OK') { return }
    }
    $summary = switch ($Kind) {
        'Performance'    { "Merge Rion's performance settings into the NVIDIA global (Base) profile:`r`n- " + (($script:NipPerformance | ForEach-Object { $_.Name }) -join "`r`n- ") + "`r`n`r`nThe GPU stays at boost clocks while any 3D app runs, so idle-in-game power and heat rise. Other global settings are kept." }
        'FortnitePotato' { "Merge the performance settings above into the global profile AND the '" + $script:FortniteProfileName + "' game profile, plus the potato look for Fortnite:`r`n- " + (($script:NipFortnitePotato | ForEach-Object { $_.Name }) -join "`r`n- ") + "`r`n`r`nTextures turn into flat low-detail colours. The driver LOD bias applies to DirectX 11 (use Performance or DirectX 11 rendering mode in Fortnite; DirectX 12 ignores it). This changes only what you see on your PC; check tournament rules before using it competitively." }
        'Defaults'       { 'Set every NVIDIA setting Rion Tool changed (global profile and the Fortnite profile) back to the driver default values. Other settings are not touched.' }
    }
    if ([System.Windows.MessageBox]::Show(("{0}`r`n`r`nYour current customized NVIDIA profiles are exported to the Rion Tool backups folder first. Continue?" -f $summary),'NVIDIA Profile Inspector','OKCancel','Question') -ne 'OK') { return }
    $backup = Backup-NvidiaProfiles $npi
    if ($backup) { Write-Log ("Backed up customized NVIDIA profiles to {0}" -f $backup) 'Info' } else { Write-Log 'No customized NVIDIA profiles to back up (or the export failed); continuing.' 'Warn' }
    $files = Export-RionNipFiles
    $file = $files[$Kind]
    Write-Log ("Importing {0} with NVIDIA Profile Inspector {1} (merge mode)..." -f (Split-Path -Leaf $file),$npi.Version) 'Action'
    $proc = Start-Process -FilePath $npi.Path -ArgumentList @('-silentImport','-mergeImport',('"{0}"' -f $file)) -WorkingDirectory (Split-Path -Parent $npi.Path) -Wait -PassThru
    $problems = Test-NvidiaNipApplied -Npi $npi -Kind $Kind
    if ($problems) { Write-Log ("NVIDIA import incomplete:`r`n{0}" -f $problems) 'Error'; [System.Windows.MessageBox]::Show(("Some settings did not reach the driver:`r`n`r`n{0}`r`n`r`nIf a Fortnite line is listed, the driver may use a different profile name for Fortnite; open Profile Inspector, search Fortnite, and tell Rion the exact profile name." -f $problems),'NVIDIA profile','OK','Warning') | Out-Null; return }
    if ($Kind -eq 'Defaults') { Remove-Item -LiteralPath $script:NvidiaStatePath -Force -ErrorAction SilentlyContinue }
    else { @{ kind=$Kind; at=(Get-Date).ToString('o'); npi=$npi.Path } | ConvertTo-Json | Set-Content -LiteralPath $script:NvidiaStatePath -Encoding UTF8 }
    Write-Log ("NVIDIA settings applied and verified in the driver ({0}). Restart running games to pick them up." -f $Kind) 'Success'
}

$script:CleanupCategories = @(
    @{ Id='usertemp'; Label='Temporary files (your account)'; Default=$true; MinAgeHours=24; Paths={ @($env:TEMP,(Join-Path $env:LOCALAPPDATA 'Temp')) | Select-Object -Unique }; Info='Files apps and installers left in your Temp folder. Files changed in the last 24 hours are kept because a running installer or app may still need them.' }
    @{ Id='wintemp'; Label='Windows temporary files'; Default=$true; MinAgeHours=24; Paths={ @(Join-Path $env:SystemRoot 'Temp') }; Info='Files Windows services and installers left in Windows\Temp. Files changed in the last 24 hours are kept.' }
    @{ Id='wucache'; Label='Windows Update download cache'; Default=$true; MinAgeHours=0; Services=@('wuauserv','bits'); Paths={ @(Join-Path $env:SystemRoot 'SoftwareDistribution\Download') }; Info='Update files Windows already downloaded. Installed updates are not affected; an update that is still pending downloads again. Windows Update and BITS are stopped for the cleanup and returned to their previous state.' }
    @{ Id='docache'; Label='Delivery Optimization cache'; Default=$true; MinAgeHours=0; Special='do'; Paths={ @(Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache') }; Info='Update and Store app pieces kept to share with other PCs. Removed with the built-in Delete-DeliveryOptimizationCache command.' }
    @{ Id='wer'; Label='Error report files'; Default=$true; MinAgeHours=0; Paths={ @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),(Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),(Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp'),(Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER')) }; Info='Crash and hang reports Windows Error Reporting already sent or queued. Event Viewer keeps its own record of each crash.' }
    @{ Id='driverleftovers'; Label='Graphics driver installer leftovers'; Default=$true; MinAgeHours=0; Paths={ @((Join-Path $env:SystemDrive 'AMD'),(Join-Path $env:SystemDrive 'NVIDIA'),(Join-Path $env:ProgramData 'NVIDIA Corporation\Downloader')) }; Info='Driver packages the AMD and NVIDIA installers unpack to C:\AMD and C:\NVIDIA, and old driver downloads kept by the NVIDIA app. Installed drivers are not touched; a driver reinstall downloads or unpacks them again.' }
    @{ Id='logs'; Label='Old Windows setup and servicing logs'; Default=$true; MinAgeHours=336; Paths={ @((Join-Path $env:SystemRoot 'Logs\CBS'),(Join-Path $env:SystemRoot 'Logs\DISM'),(Join-Path $env:SystemRoot 'Logs\MoSetup'),(Join-Path $env:SystemRoot 'Panther\UnattendGC')) }; Info='Component servicing, DISM and setup logs older than 14 days. Recent logs stay for troubleshooting.' }
    @{ Id='launchers'; Label='Game launcher and Discord web caches'; Default=$true; MinAgeHours=0; Paths={
        $sub = 'Cache','Code Cache','GPUCache'
        $roots = @((Join-Path $env:LOCALAPPDATA 'Steam\htmlcache'),(Join-Path $env:LOCALAPPDATA 'Steam\htmlcache\Default'),(Join-Path $env:APPDATA 'discord'),(Join-Path $env:APPDATA 'discordptb'),(Join-Path $env:APPDATA 'discordcanary'))
        $roots += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved') -Directory -Filter 'webcache*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($r in $roots) { foreach ($n in $sub) { Join-Path $r $n } }
        $steam = [string](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($steam) { Join-Path ($steam -replace '/','\') 'appcache\httpcache' }
        Join-Path $env:LOCALAPPDATA 'Battle.net\BrowserCaches'
    }; Info='Web page caches of the Steam, Epic Games and Battle.net launchers and Discord (store pages, images, scripts). Only cache folders are cleared: logins, settings and downloaded games are untouched, and the launchers fill the caches again as you browse. Files in use by a running launcher are skipped.' }
    @{ Id='dumps'; Label='Crash dumps'; Default=$false; MinAgeHours=0; Paths={ @((Join-Path $env:SystemRoot 'Minidump'),(Join-Path $env:SystemRoot 'MEMORY.DMP'),(Join-Path $env:LOCALAPPDATA 'CrashDumps')) }; Info='Memory dumps written when Windows (blue screen) or an app crashed. Keep them while you are still troubleshooting crashes: they are what crash analysis reads.' }
    @{ Id='shader'; Label='DirectX and graphics driver shader caches'; Default=$false; MinAgeHours=0; Paths={ @((Join-Path $env:LOCALAPPDATA 'D3DSCache'),(Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),(Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),(Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),(Join-Path $env:LOCALAPPDATA 'AMD\DxcCache'),(Join-Path $env:LOCALAPPDATA 'AMD\VkCache'),(Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),(Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')) }; Info='Compiled shaders games reuse to avoid stutter. Clear only after a graphics driver update or when a game crashes with shader errors: every game compiles its shaders again, so the first matches stutter.' }
    @{ Id='recycle'; Label='Recycle Bin'; Default=$false; MinAgeHours=0; Special='recycle'; Paths={ @() }; Info='Permanently deletes everything in the Recycle Bin on every drive. Check it for anything you still want first.' }
    @{ Id='dns'; Label='DNS resolver cache'; Default=$true; MinAgeHours=0; Special='dns'; Paths={ @() }; Info='Clears remembered website addresses so the next lookup asks the DNS server again. Fixes sites that moved; nothing is lost.' }
)

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes/1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes/1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-CleanupFiles {
    param([string[]]$Roots,[int]$MinAgeHours = 0)
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $files = New-Object System.Collections.Generic.List[IO.FileInfo]
    foreach ($root in @($Roots | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $root -PathType Leaf) {
            try { $fi = New-Object IO.FileInfo $root; if ($MinAgeHours -eq 0 -or $fi.LastWriteTime -lt $cutoff) { $files.Add($fi) } } catch { }
            continue
        }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootInfo = New-Object IO.DirectoryInfo $root
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $stack = New-Object System.Collections.Stack
        $stack.Push($rootInfo)
        while ($stack.Count) {
            $dir = $stack.Pop()
            try { foreach ($f in $dir.GetFiles()) { if (-not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($MinAgeHours -eq 0 -or $f.LastWriteTime -lt $cutoff)) { $files.Add($f) } } } catch { }
            try { foreach ($sub in $dir.GetDirectories()) { if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub) } } } catch { }
        }
    }
    return ,$files
}

function Get-RecycleBinBytes {
    $total = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($item in @($shell.Namespace(10).Items())) { try { $total += [double]$item.ExtendedProperty('Size') } catch { } }
    } catch { }
    return $total
}

function Measure-CleanupCategory {
    param($Category)
    if ($Category.Special -eq 'recycle') { return (Get-RecycleBinBytes) }
    if ($Category.Special -eq 'dns') { return 0 }
    $files = Get-CleanupFiles -Roots (& $Category.Paths) -MinAgeHours $Category.MinAgeHours
    $sum = 0; foreach ($f in $files) { $sum += $f.Length }
    return $sum
}

function Invoke-CleanupCategory {
    param($Category)
    $freed = 0; $skipped = 0
    switch ($Category.Special) {
        'dns' { try { Clear-DnsClientCache -ErrorAction Stop } catch { & ipconfig.exe /flushdns | Out-Null }; return @{ Freed=0; Skipped=0 } }
        'recycle' { $before = Get-RecycleBinBytes; try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }; return @{ Freed=[math]::Max(0,$before - (Get-RecycleBinBytes)); Skipped=0 } }
        'do' { $before = Measure-CleanupCategory $Category; try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null } catch { }; return @{ Freed=[math]::Max(0,$before - (Measure-CleanupCategory $Category)); Skipped=0 } }
    }
    $restore = @()
    foreach ($svc in @($Category.Services)) {
        if (-not $svc) { continue }
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { try { Stop-Service -Name $svc -Force -ErrorAction Stop; $restore += $svc } catch { } }
    }
    try {
        $roots = @(& $Category.Paths)
        foreach ($f in (Get-CleanupFiles -Roots $roots -MinAgeHours $Category.MinAgeHours)) {
            try { $len = $f.Length; if ($f.IsReadOnly) { $f.IsReadOnly = $false }; $f.Delete(); $freed += $len } catch { $skipped++ }
        }
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            $dirs = New-Object System.Collections.Generic.List[IO.DirectoryInfo]
            $stack = New-Object System.Collections.Stack; $stack.Push((New-Object IO.DirectoryInfo $root))
            while ($stack.Count) { $d = $stack.Pop(); try { foreach ($sub in $d.GetDirectories()) { if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $dirs.Add($sub); $stack.Push($sub) } } } catch { } }
            foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) { try { if (-not $d.EnumerateFileSystemInfos().GetEnumerator().MoveNext()) { $d.Delete() } } catch { } }
        }
    } finally {
        foreach ($svc in $restore) { try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { } }
    }
    return @{ Freed=$freed; Skipped=$skipped }
}

function Invoke-Cleanup {
    param([string[]]$Ids)
    $total = 0; $lines = @()
    foreach ($cat in @($script:CleanupCategories | Where-Object { $Ids -contains $_.Id })) {
        Update-UiNow ('Cleaning {0}...' -f $cat.Label)
        Write-Log ("Cleaning {0}..." -f $cat.Label) 'Action'
        $r = Invoke-CleanupCategory $cat
        $total += $r.Freed
        $line = ('{0}: {1} freed' -f $cat.Label,(Format-Bytes $r.Freed))
        if ($r.Skipped) { $line += (' ({0} files in use were skipped)' -f $r.Skipped) }
        $lines += $line
        Write-Log $line 'Info'
    }
    Write-Log ('Cleanup finished: {0} freed in total.' -f (Format-Bytes $total)) 'Success'
    return @{ Total=$total; Lines=$lines }
}

$script:GhostAllowedBuses = '^(USB|USBSTOR|HID|PCI|BTHENUM|BTHLE|BTHLEDEVICE|BTH|DISPLAY|MONITOR|HDAUDIO|SCSI|USB4|INTELAUDIO|WPDBUSENUM)\\'
$script:GhostBlockedClasses = @('System','SoftwareDevice','SoftwareComponent','Computer','Processor','Volume','VolumeSnapshot','Firmware','SecurityDevices','LegacyDriver','Extension','Battery')
function Get-GhostDevices {
    $all = @()
    try { $all = @(Get-PnpDevice -ErrorAction Stop | Where-Object { -not $_.Present }) } catch { return @() }
    return @($all | Where-Object { [string]$_.InstanceId -match $script:GhostAllowedBuses -and $script:GhostBlockedClasses -notcontains [string]$_.Class } | Sort-Object Class,FriendlyName)
}
function Remove-GhostDevices {
    param([string[]]$InstanceIds)
    $ok = 0; $fail = 0
    foreach ($id in $InstanceIds) {
        $out = & pnputil.exe /remove-device $id 2>&1
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++; Write-Log ("Could not remove {0}: {1}" -f $id,((@($out) -join ' ').Trim())) 'Warn' }
    }
    Write-Log ("Removed {0} ghost device(s){1}." -f $ok,$(if ($fail) { ", $fail failed" } else { '' })) 'Success'
    return $ok
}

$script:CleanupTaskPath = '\RionTool\'
$script:CleanupTaskName = 'Weekly cleanup'
function Get-RionCleanupTask { return (Get-ScheduledTask -TaskPath $script:CleanupTaskPath -TaskName $script:CleanupTaskName -ErrorAction SilentlyContinue) }
function Unregister-RionCleanupTask {
    if (Get-RionCleanupTask) { Unregister-ScheduledTask -TaskPath $script:CleanupTaskPath -TaskName $script:CleanupTaskName -Confirm:$false }
    Remove-Item -LiteralPath (Join-Path $script:DataDir 'RionTool.ps1') -Force -ErrorAction SilentlyContinue
    Write-Log 'Weekly cleanup task removed.' 'Success'
}
function New-RionShortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop 'Rion Tool.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $script:PowerShellExe
    $sc.Arguments = ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath)
    $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $sc.IconLocation = ('{0},0' -f (Join-Path $env:SystemRoot 'System32\imageres.dll'))
    $sc.Description = 'Rion Tool (runs as administrator)'
    $sc.Save()
    $bytes = [IO.File]::ReadAllBytes($lnk); $bytes[0x15] = $bytes[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnk,$bytes)
    Write-Log ('Desktop shortcut created: {0} (opens Rion Tool as administrator).' -f $lnk) 'Success'
}

$script:HealthCategories = [ordered]@{
    'Tweaks'      = 'Settings that can cause problems and old placebo tweaks'
    'Drivers'     = 'Graphics driver age and devices without a working driver'
    'Security'    = 'Antivirus, firewall, restore points and recovery'
    'Maintenance' = 'Junk files, restarts, startup apps and recommended tweaks'
    'Hardware'    = 'Memory, display connection, disks'
}
function Get-HealthGroup { param([string]$Category); switch ($Category) { 'Risky settings' { 'Tweaks' } 'Placebo tweaks' { 'Tweaks' } 'Security and recovery' { 'Security' } default { $Category } } }

function Get-RegNumber {
    param([string]$Path,[string]$Name)
    try { $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name; if ($null -eq $v) { return $null }; return [int64]$v } catch { return $null }
}

function New-HealthFinding {
    param([string]$Category,[string]$Severity,[int]$Weight,[string]$Title,[string]$Detail,[string]$FixLabel,[scriptblock]$Fix)
    return [pscustomobject]@{ Category=$Category; Severity=$Severity; Weight=$Weight; Title=$Title; Detail=$Detail; FixLabel=$FixLabel; Fix=$Fix }
}

function Get-GpuDriverPage {
    param([string]$Name)
    if ($Name -match '(?i)NVIDIA|GeForce|RTX|GTX') { return 'https://www.nvidia.com/en-us/drivers/' }
    if ($Name -match '(?i)AMD|Radeon') { return 'https://www.amd.com/en/support/download/drivers.html' }
    if ($Name -match '(?i)Intel|Arc|Iris|UHD') { return 'https://www.intel.com/content/www/us/en/download-center/home.html' }
    return 'https://www.catalog.update.microsoft.com/'
}

$script:HealthChecks = @(
    @{ Category='Hardware'; Run={
        $m = Get-MemoryConfigReport
        if (-not $m) { return }
        foreach ($i in @($m.Issues)) {
            if ($i -match 'single-channel') { New-HealthFinding 'Hardware' 'bad' 15 'Memory is running in single channel' ($m.Summary + '. ' + $i) }
            elseif ($i -match 'EXPO|XMP') { New-HealthFinding 'Hardware' 'bad' 12 'Memory is below its rated speed (EXPO/XMP off)' ($m.Summary + '. ' + $i + ' On ASUS boards: Ai Tweaker > Ai Overclock Tuner > EXPO/XMP.') }
        }
    } }
    @{ Category='Hardware'; Run={
        if ($script:Env.IsLaptop) { return }
        $igpuPattern = '(?i)Radeon\(TM\) Graphics$|Radeon Graphics$|UHD Graphics|Iris|Intel\(R\) Graphics|Arc\(TM\) Graphics$|HD Graphics'
        $ig = @($script:Env.Gpus | Where-Object { $_.Name -match $igpuPattern }); $dg = @($script:Env.Gpus | Where-Object { $_.Name -notmatch $igpuPattern -and $_.Vendor -in 'NVIDIA','AMD','Intel' })
        if ($ig.Count -and $dg.Count -and @($ig | Where-Object { $_.IsMain }).Count -and -not @($dg | Where-Object { $_.IsMain }).Count) { New-HealthFinding 'Hardware' 'bad' 15 'Monitor is plugged into the motherboard' ('Games run on or copy every frame through the integrated {0} instead of the {1}. Move the monitor cable to the graphics card.' -f $ig[0].Name,$dg[0].Name) }
    } }
    @{ Category='Hardware'; Run={
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentRefreshRate -gt 0 -and $_.MaxRefreshRate -gt 0 })) {
            if ([int]$v.MaxRefreshRate -gt [int]$v.CurrentRefreshRate + 5) { New-HealthFinding 'Hardware' 'bad' 10 ('Monitor runs at {0} Hz but supports {1} Hz' -f $v.CurrentRefreshRate,$v.MaxRefreshRate) 'Set the higher refresh rate in Settings > System > Display > Advanced display > Choose a refresh rate. A wrong cable (old HDMI) or a missing monitor driver can also hide it.' 'Open display settings' { Start-Process 'ms-settings:display-advanced' } }
        }
    } }
    @{ Category='Hardware'; Run={
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction SilentlyContinue
        if (-not $d -or -not $d.Size) { return }
        $pct = [math]::Round(100 * $d.FreeSpace / $d.Size)
        if ($pct -lt 5) { New-HealthFinding 'Hardware' 'bad' 10 ('System drive almost full ({0}% free)' -f $pct) 'Windows needs free space for updates, the page file and shader caches. Run Cleanup or move games to another drive.' 'Open Cleanup' { Select-RionTab 'Cleanup' } }
        elseif ($pct -lt 12) { New-HealthFinding 'Hardware' 'warn' 6 ('System drive low on space ({0}% free)' -f $pct) 'Keep at least 10-15% free so updates and the page file have room and the SSD keeps its speed.' 'Open Cleanup' { Select-RionTab 'Cleanup' } }
    } }
    @{ Category='Hardware'; Run={
        if (-not $script:Env.HasHdd) { return }
        try {
            $disk = Get-Partition -DriveLetter ($env:SystemDrive.Substring(0,1)) -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
            if ($pd -and [string]$pd.MediaType -eq 'HDD') { New-HealthFinding 'Hardware' 'bad' 12 'Windows is installed on a hard disk drive' 'Boot, app launches and game loading are many times slower than on an SSD. Moving Windows to an SSD is the single biggest upgrade for this PC.' }
        } catch { }
        $g = @(Get-GamesOnHdd)
        if ($g.Count) { New-HealthFinding 'Hardware' 'warn' 5 'Games installed on a hard disk drive' (($g -join ', ') + '. They stutter while streaming textures; move them to an SSD.') }
    } }
    @{ Category='Hardware'; Run={
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $name = ('{0} ({1})' -f ([string]$pd.FriendlyName).Trim(),$(if ($pd.Size) { '{0:N0} GB' -f ($pd.Size/1GB) } else { 'unknown size' }))
            $hs = [string]$pd.HealthStatus
            if ($hs -eq 'Unhealthy') { New-HealthFinding 'Hardware' 'bad' 15 ('Drive failing: {0}' -f $name) ('The drive reports itself unhealthy ({0}). Back up anything important on it now and plan to replace it.' -f (@($pd.OperationalStatus) -join ', ')) }
            elseif ($hs -eq 'Warning') { New-HealthFinding 'Hardware' 'warn' 8 ('Drive warning: {0}' -f $name) ('The drive reports a health warning ({0}). Back up important files and check it with the drive maker''s tool.' -f (@($pd.OperationalStatus) -join ', ')) }
            else {
                try {
                    $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($null -ne $rc.Wear -and [int]$rc.Wear -ge 90) { New-HealthFinding 'Hardware' 'warn' 6 ('SSD nearly worn out: {0}' -f $name) ('The SSD has used {0}% of its rated write endurance. It can keep working for a while, but back up regularly and plan a replacement.' -f [int]$rc.Wear) }
                    elseif ($null -ne $rc.Temperature -and $null -ne $rc.TemperatureMax -and [int]$rc.TemperatureMax -gt 0 -and [int]$rc.Temperature -ge [int]$rc.TemperatureMax) { New-HealthFinding 'Hardware' 'warn' 4 ('Drive running hot: {0}' -f $name) ('The drive is at {0} C, at or above its rated maximum, so it slows itself down. Improve airflow or fit an M.2 heatsink.' -f [int]$rc.Temperature) }
                } catch { }
            }
        }
    } }
    @{ Category='Drivers'; Run={
        $cpu = [string]$script:Env.Cpu
        if ($cpu -match '(?i)Ryzen 9 \d{4}X3D') {
            if (-not (Get-Service -Name 'amd3dvcache' -ErrorAction SilentlyContinue)) { New-HealthFinding 'Drivers' 'warn' 6 'AMD 3D V-Cache driver is not installed' 'This CPU has two CCDs and only one has the 3D V-Cache. Without the AMD Chipset Software driver, Windows does not move games to the V-Cache CCD, which costs FPS in cache-heavy games.' 'Open download page' { Start-Process 'https://www.amd.com/en/support/download/drivers.html' } }
            if (-not @(Get-AppxPackage -Name 'Microsoft.XboxGamingOverlay' -ErrorAction SilentlyContinue).Count) { New-HealthFinding 'Drivers' 'warn' 5 'Xbox Game Bar is missing on a dual-CCD X3D CPU' 'The AMD 3D V-Cache driver uses Game Bar to recognise games and move them to the V-Cache CCD. Without it, games can run on the CCD without the extra cache. Reinstall it under Fixes, or use the "Prefer the 3D V-Cache CCD for every app" row in the AMD tab.' 'Open Fixes' { Select-RionTab 'Fixes' } }
        }
        if ($cpu -match '(?i)Ryzen \d \d?[2-5]\d{3}') {
            $amdTpm = $false
            try { $t = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1; $amdTpm = ([string]$t.ManufacturerIdTxt).Trim() -eq 'AMD' } catch { }
            $bios = $null; try { $bios = (Get-CimInstance Win32_BIOS -ErrorAction Stop).ReleaseDate } catch { }
            if ($amdTpm -and $bios -and $bios -lt (Get-Date '2022-05-01')) { New-HealthFinding 'Drivers' 'warn' 5 'Old BIOS: AMD fTPM can cause stutter' ('The BIOS is from {0:yyyy-MM-dd}. On Ryzen with firmware TPM, BIOS versions before AGESA 1.2.0.7 can freeze the PC for a moment while the TPM is accessed, felt as random stutter and audio pops. Update the BIOS from your board or PC maker.' -f $bios) }
        }
        if ($script:Env.CpuHybrid -and [int]$script:Env.Build -gt 0 -and [int]$script:Env.Build -lt 22000) { New-HealthFinding 'Drivers' 'warn' 6 'Intel hybrid CPU on Windows 10' 'Windows 10 has no Thread Director support, so games can be scheduled on the slower E-cores and lose FPS. Windows 11 schedules P-cores and E-cores properly.' }
    } }
    @{ Category='Risky settings'; Run={
        $bbr = @(Get-NetTCPSetting -ErrorAction SilentlyContinue | Where-Object { [string]$_.CongestionProvider -match '^BBR' } | ForEach-Object { $_.SettingName })
        if ($bbr.Count -and [int]$script:Env.Build -ge 26100) { New-HealthFinding 'Risky settings' 'warn' 4 'TCP congestion control set to BBR2' ('BBR2 is set for {0}. On Windows 11 24H2 and newer it can stall connections inside the PC (launchers, sync and indexing tools that talk to localhost), and it does not lower game ping: games use UDP, which congestion control does not touch. Fix puts it back to CUBIC, the Windows default.' -f ($bbr -join ', ')) 'Set back to CUBIC' { foreach ($t in 'internet','internetcustom','datacenter','datacentercustom') { & netsh.exe int tcp set supplemental template=$t congestionprovider=cubic | Out-Null }; Write-Log 'TCP congestion control set back to CUBIC.' 'Success' } }
    } }
    @{ Category='Risky settings'; Run={
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\'
        if ((Test-Path ($base + 'vgc')) -and (Test-Path ($base + 'vgk'))) {
            $off = @('vgc','vgk' | Where-Object { (Get-ServiceStartValue $_) -eq 4 })
            if ($off.Count) { New-HealthFinding 'Risky settings' 'info' 0 'Riot Vanguard is disabled' ('{0} is set to Disabled, so Valorant and League of Legends will not start (VAN errors) until it is turned back on. Ignore this if you disabled it on purpose while not playing. Fix restores the Riot defaults; restart afterwards.' -f ($off -join ' and ')) 'Turn Vanguard back on' { Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\vgc' -Name 'Start' -Value 3 -Type DWord; Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\vgk' -Name 'Start' -Value 1 -Type DWord; Write-Log 'Riot Vanguard restored (vgc Manual, vgk System). Restart to load it.' 'Success' } }
        }
    } }
    @{ Category='Risky settings'; Run={
        $why = @(Get-StartSearchProblems)
        if ($why.Count) { New-HealthFinding 'Risky settings' 'warn' 6 'Start search can ignore what you type' (('When you press Windows and start typing, nothing may appear until you click the search box, because {0}.' -f ($why -join ', and ')) + ' The fix keeps the text input host starting at sign-in and lets Start and Search run.') 'Fix Start search' { Repair-StartSearch } }
    } }
    @{ Category='Risky settings'; Run={
        $core = @(
            @('msiserver',3,'Windows Installer','Installers that use .msi packages (game launchers, drivers, Visual C++ and other runtimes) fail to install or uninstall.'),
            @('TrustedInstaller',3,'Windows Modules Installer','Optional features, .NET Framework 3.5, language packs and DISM/SFC repairs fail.'),
            @('AppXSvc',3,'AppX Deployment Service','Store apps (Xbox app, Game Bar, Calculator, Photos) cannot install, update or sometimes open.'),
            @('ClipSVC',3,'Client License Service','Store apps and Game Pass games fail their license check and will not start.'),
            @('AppReadiness',3,'App Readiness','Store app installs and new account sign-ins hang on "Preparing".'),
            @('StateRepository',3,'State Repository Service','The Start menu, Settings and Store apps stop working properly.'),
            @('InstallService',3,'Microsoft Store Install Service','Store and Xbox app installs and updates do not start.'),
            @('BITS',3,'Background Intelligent Transfer Service','The Store, Xbox app and many launchers cannot download in the background.'),
            @('Winmgmt',2,'Windows Management Instrumentation','Game launchers, anti-cheat and hardware tools that read system information fail.'),
            @('Audiosrv',2,'Windows Audio','There is no sound in games or apps.'),
            @('AudioEndpointBuilder',2,'Windows Audio Endpoint Builder','Audio devices disappear and games have no sound.'),
            @('Dhcp',2,'DHCP Client','The PC cannot get an address from the router, so there is no internet.'),
            @('Dnscache',2,'DNS Client','Websites, launchers and game servers cannot be reached by name.'),
            @('nsi',2,'Network Store Interface','Network connections and the network icon stop working.'),
            @('NlaSvc',2,'Network Location Awareness','Windows thinks there is no internet, so the Store and some games refuse to connect.'),
            @('W32Time',3,'Windows Time','The clock drifts; launcher and game logins can fail with certificate or time errors.'),
            @('FontCache',2,'Windows Font Cache','Apps start slowly and text can fail to draw.'),
            @('camsvc',3,'Capability Access Manager','Apps cannot use the microphone or camera, so voice chat in games stops working.'),
            @('DispBrokerDesktopSvc',2,'Display Policy Service','Changing resolution, refresh rate or HDR in Settings stops working.'),
            @('hidserv',3,'Human Interface Device Service','Media keys and some keyboard and controller buttons stop working.'),
            @('GameInputSvc',3,'GameInput Service','Controllers and input in newer games stop working.'),
            @('EasyAntiCheat',3,'Easy Anti-Cheat','Games protected by Easy Anti-Cheat refuse to start.'),
            @('EasyAntiCheat_EOS',3,'Easy Anti-Cheat (EOS)','Games protected by Easy Anti-Cheat refuse to start.'),
            @('BEService',3,'BattlEye Service','Games protected by BattlEye refuse to start.')
        )
        foreach ($c in $core) {
            if (-not (Test-ServiceExists $c[0]) -or (Get-ServiceStartValue $c[0]) -ne 4) { continue }
            $fix = [scriptblock]::Create(("Set-ServiceStartNow -Name '{0}' -Start {1}; {2}Write-Log '{3} turned back on.' 'Success'" -f $c[0],$c[1],$(if ($c[1] -eq 2) { "Start-Service -Name '" + $c[0] + "' -ErrorAction SilentlyContinue; " } else { '' }),$c[2]))
            New-HealthFinding 'Risky settings' 'warn' 4 ('{0} is disabled' -f $c[2]) ($c[3] + ' Windows needs this service; turn it back on.') 'Turn it back on' $fix
        }
    } }
    @{ Category='Maintenance'; Run={
        foreach ($r in @(Get-MissingRuntimes)) {
            $fix = [scriptblock]::Create(("Install-WingetPackage -Id '{0}' -Name '{1}'" -f $r.Id,$r.Name))
            if ($r.Id -eq 'Microsoft.DirectX') { New-HealthFinding 'Maintenance' 'info' 0 ('Not installed: {0}' -f $r.Name) 'Older DirectX 9-11 games need these files and show "d3dx9_43.dll is missing" without them. Newer games do not.' 'Install it' $fix }
            else { New-HealthFinding 'Maintenance' 'warn' 4 ('Not installed: {0}' -f $r.Name) 'Most games, launchers and anti-cheats need it and fail with "VCRUNTIME140.dll was not found" without it.' 'Install it' $fix }
        }
        $fx = Get-OptionalFeatureStates
        if ($fx.ContainsKey('NetFx3') -and $fx['NetFx3'] -eq 2) { New-HealthFinding 'Maintenance' 'info' 0 '.NET Framework 3.5 is not turned on' 'Some older games and tools need it and ask to download it on first start. Turning it on needs Windows Update or an install image.' 'Turn it on' { Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null; Write-Log '.NET Framework 3.5 is turned on.' 'Success' } }
    } }
    @{ Category='Drivers'; Run={
        $bios = $null; try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { }
        if (-not $bios -or -not $bios.ReleaseDate) { return }
        $age = ((Get-Date) - $bios.ReleaseDate).TotalDays / 365.25
        if ($age -lt 2) { return }
        $board = $null; try { $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch { }
        $model = (('{0} {1}' -f [string]$board.Manufacturer,[string]$board.Product).Trim())
        $q = [uri]::EscapeDataString(('{0} BIOS download' -f $model))
        $fix = [scriptblock]::Create(("Start-Process 'https://www.bing.com/search?q={0}'" -f $q))
        $txt = ('BIOS {0} from {1:yyyy-MM-dd} on {2}. Board makers keep fixing memory compatibility, stability, boost behaviour and security in BIOS updates. Update from the board or PC maker''s support page, never from a third-party site.' -f ([string]$bios.SMBIOSBIOSVersion).Trim(),$bios.ReleaseDate,$(if ($model) { $model } else { 'this board' }))
        if ($age -ge 3) { New-HealthFinding 'Drivers' 'warn' 3 ('BIOS is {0:N0} years old' -f [math]::Floor($age)) $txt 'Find the BIOS update' $fix }
        else { New-HealthFinding 'Drivers' 'info' 0 ('BIOS is {0:N0} years old' -f [math]::Floor($age)) $txt 'Find the BIOS update' $fix }
    } }
    @{ Category='Placebo tweaks'; Run={
        foreach ($v in $script:ExtraPlaceboValues) {
            $item = Get-Item -LiteralPath $v.Path -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            $names = @($item.GetValueNames() | Where-Object { $_ -match $v.Pattern })
            foreach ($n in $names) {
                $val = $item.GetValue($n)
                if ($v.Bad -and -not (& $v.Bad $val)) { continue }
                $fix = if ($null -ne $v.Default) { [scriptblock]::Create(("Set-RegValue -Path '{0}' -Name '{1}' -Value {2} -Type DWord; Write-Log '{1} is back to the Windows default.' 'Success'" -f $v.Path,$n,$v.Default)) } else { [scriptblock]::Create(("Remove-RegValue -Path '{0}' -Name '{1}'; Write-Log '{1} removed; Windows uses its default again.' 'Success'" -f $v.Path,$n)) }
                New-HealthFinding 'Placebo tweaks' $v.Sev $(if ($v.Sev -eq 'warn') { 3 } else { 0 }) ('{0} ({1}={2})' -f $v.Title,$n,(@($val) -join ',')) $v.Why 'Put back the default' $fix
            }
        }
        $pf = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction SilentlyContinue
        if ($pf) {
            $files = @($pf.GetValue('PagingFiles')) | Where-Object { $_ }
            if (-not $files.Count) { New-HealthFinding 'Placebo tweaks' 'bad' 8 'The page file is turned off' 'Games and Windows expect a page file. Without one, a game that briefly needs more memory crashes or shows out-of-memory errors instead of slowing down, and crash dumps are not saved.' 'Let Windows manage it' { $cs = Get-CimInstance Win32_ComputerSystem; Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile=$true } -ErrorAction Stop; Write-Log 'The page file is back to system-managed. Restart to apply.' 'Success' } }
        }
    } }
    @{ Category='Hardware'; Run={
        $gb = [int]$script:Env.RamNominalGB
        if ($gb -gt 0 -and $gb -lt 16) { New-HealthFinding 'Hardware' 'warn' 4 ('{0} GB of memory' -f $gb) 'Current games and a browser or Discord in the background often need more than 8-12 GB, which pushes data to the page file and causes stutter. 16 GB (two sticks) is the practical minimum for gaming.' }
    } }
    @{ Category='Drivers'; Run={
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
            if ([string]$v.Name -match '(?i)Basic Display|Basic Render') { New-HealthFinding 'Drivers' 'bad' 15 'No graphics driver installed' 'Windows is using the Microsoft Basic Display Adapter: no hardware acceleration and a fixed low refresh rate. Install the driver from the GPU maker.' 'Open driver download page' { Start-Process 'https://www.amd.com/en/support/download/drivers.html' }; continue }
            if ([string]$v.Name -match '(?i)Remote|Virtual|Parsec|Mirage') { continue }
            if (-not $v.DriverDate) { continue }
            $age = [int]((Get-Date) - [datetime]$v.DriverDate).TotalDays
            $page = Get-GpuDriverPage ([string]$v.Name)
            $fix = [scriptblock]::Create(("Start-Process '{0}'" -f $page))
            if ($age -gt 180) { New-HealthFinding 'Drivers' 'bad' 10 ('{0} driver is {1} days old' -f $v.Name,$age) ('Version {0}. GPU makers ship game fixes and performance updates about monthly; this driver misses six months or more of them. Install the newest driver from the maker (a clean install is best).' -f $v.DriverVersion) 'Open driver download page' $fix }
            elseif ($age -gt 90) { New-HealthFinding 'Drivers' 'warn' 6 ('{0} driver is {1} days old' -f $v.Name,$age) ('Version {0}. A newer driver is very likely available; check the maker''s download page.' -f $v.DriverVersion) 'Open driver download page' $fix }
        }
    } }
    @{ Category='Drivers'; Run={
        $known = @(
            @('VEN_1022&DEV_1649','AMD PSP (Platform Security Processor)','handles firmware TPM, secure boot keys and memory encryption requests','AMD Chipset Software'),
            @('AMDI0052','AMD PPM Provisioning File','gives Windows the AMD-tuned processor power settings, which affects boost behaviour','AMD Chipset Software'),
            @('AMDI0204','AMD Application Compatibility Database','lets Windows apply AMD-specific compatibility fixes for apps and games','AMD Chipset Software'),
            @('AMDIF031','AMD GPIO controller','connects board buttons, fan and sensor signals and some USB features','AMD Chipset Software'),
            @('AMDI0030','AMD GPIO controller','connects board buttons, fan and sensor signals and some USB features','AMD Chipset Software'),
            @('AMDI0010','AMD I2C controller','connects touchpads, RGB controllers and sensors on some boards','AMD Chipset Software'),
            @('AMDI0101','AMD 3D V-Cache Performance Optimizer','moves games to the V-Cache die on dual-die Ryzen X3D CPUs','AMD Chipset Software'),
            @('VEN_8086&DEV_.*&CC_0780','Intel Management Engine interface','firmware security and platform features','Intel Management Engine driver'),
            @('INT34','Intel Serial IO controller','touchpads, sensors and GPIO on Intel boards','Intel Serial IO driver')
        )
        $nod = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 28 -and [string]$_.PNPDeviceID -notmatch '^(SWD|ROOT)\\' } | Where-Object { -not (Test-OptionalDevice $_) })
        foreach ($d in $nod) {
            $id = [string]$d.PNPDeviceID
            $hit = @($known | Where-Object { $id -match $_[0] }) | Select-Object -First 1
            $amd = $id -match 'VEN_1022|AMDI'
            $page = if ($amd) { 'https://www.amd.com/en/support/download/drivers.html' } elseif ($id -match 'VEN_8086|INT[0-9A-F]{4}|INTC') { 'https://www.intel.com/content/www/us/en/download-center/home.html' } else { '' }
            $fix = if ($page) { [scriptblock]::Create(("Start-Process '{0}'" -f $page)) } else { $null }
            if ($hit) { New-HealthFinding 'Drivers' 'warn' 3 ('No driver: {0}' -f $hit[1]) ('This device {0}. Install the {1} to add its driver. ({2})' -f $hit[2],$hit[3],$id) $(if ($fix) { 'Open download page' } else { '' }) $fix }
            else { New-HealthFinding 'Drivers' 'warn' 2 ('No driver: {0}' -f $(if ($d.Name) { $d.Name } else { 'unknown device' })) ('Windows has no driver for this device ({0}). Get it from your board or PC maker''s support page.' -f $id) $(if ($fix) { 'Open download page' } else { '' }) $fix }
        }
    } }
    @{ Category='Drivers'; Run={
        $codes = @{ 1='is not configured correctly'; 3='driver is damaged or out of memory'; 10='cannot start'; 12='cannot find enough free resources'; 14='needs a restart'; 18='needs its driver reinstalled'; 19='has damaged registry settings'; 21='is being removed'; 24='is not present or not working'; 31='is not working properly'; 37='driver returned a failure'; 39='driver is missing or damaged'; 43='reported a problem and was stopped'; 48='driver is blocked as incompatible'; 52='driver signature cannot be verified' }
        $ignoreCodes = @(0,22,28,29,32,45)
        foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.ConfigManagerErrorCode -and $ignoreCodes -notcontains [int]$_.ConfigManagerErrorCode })) {
            $id = [string]$d.PNPDeviceID
            $svc = ''; try { $svc = [string](Get-RegValueFast ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id) 'Service').Value } catch { }
            if ($svc -and (Get-ServiceStartValue $svc) -eq 4) { continue }
            if ([string]$d.PNPClass -eq 'Bluetooth' -and (Get-ServiceStartValue 'bthserv') -eq 4) { continue }
            if ([string]$d.PNPClass -in 'Camera','Image' -and (Get-ServiceStartValue 'FrameServer') -eq 4) { continue }
            if ([string]$d.PNPClass -eq 'AudioEndpoint' -and (Get-ServiceStartValue 'Audiosrv') -eq 4) { continue }
            $code = [int]$d.ConfigManagerErrorCode
            $what = if ($codes.ContainsKey($code)) { $codes[$code] } else { 'has a problem' }
            $name = if ($d.Name) { [string]$d.Name } else { $id }
            $busDesc = ''; try { $busDesc = [string](Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data } catch { }
            $vendor = ''; if ($id -match 'VID_([0-9A-F]{4})') { $vendor = [string]$script:UsbVendors[$Matches[1]] }
            $label = $name
            if ($busDesc -and $busDesc -ne $name) { $label = ('{0} ({1})' -f $name,$busDesc) }
            $hint = if ($vendor) { (' Made by {0}.' -f $vendor) } else { '' }
            $usb = $id -like 'USB\*'
            $advice = if ($code -eq 10 -and $usb) { 'The device answered but failed to start. The fix removes it from Windows and lets Windows detect it again. If it comes back with the same error: unplug it and plug it into a rear USB port (a USB 2.0 port for RGB, fan and cooler controllers), then update the software or firmware from its maker. Disable it in Device Manager if you do not use it.' } else { 'The fix removes it from Windows and lets Windows detect it again. If the error comes back, reinstall or update its driver from the maker, or disable it in Device Manager if you do not use it.' }
            $fix = [scriptblock]::Create(("Reset-RionDevice -InstanceId '{0}'" -f ($id -replace "'","''")))
            New-HealthFinding 'Drivers' 'warn' 4 ('{0} {1}' -f $label,$what) (('Device Manager error code {0}.{1} ' -f $code,$hint) + $advice) 'Reset this device' $fix
        }
    } }
    @{ Category='Risky settings'; Run={
        $mpo = (Get-RegNumber 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode') -eq 5
        $ovl = (Get-RegNumber 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'DisableOverlays') -eq 1
        if ($mpo -or $ovl) { New-HealthFinding 'Risky settings' 'warn' 6 'Multi-Plane Overlay (MPO) is turned off' 'With MPO off, borderless and windowed games are composited by the desktop every frame (higher latency, lower FPS), and on recent Windows builds hardware overlays for video and overlays stop. Turn it back on unless it fixed a real flicker problem on this PC.' 'Turn MPO back on' { Remove-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode'; Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'DisableOverlays'; Write-Log 'MPO restored; restart Windows.' 'Success' } }
    } }
    @{ Category='Risky settings'; Run={
        $idle = Get-PowerIndexRecord 'IDLEDISABLE'
        if ($idle -and [int]$idle.ac -eq 1) { New-HealthFinding 'Risky settings' 'bad' 10 'CPU idle states are disabled' 'Every core stays fully awake, which eats the power and heat budget Ryzen Precision Boost and Intel Turbo use to clock the busy cores higher. It usually lowers game FPS and raises temperatures.' 'Reset processor power settings' { Reset-ProcessorPowerDefaults } }
        $minp = Get-PowerIndexRecord 'PROCTHROTTLEMIN'; $epp = Get-PowerIndexRecord 'PERFEPP'
        $active = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction SilentlyContinue).ActivePowerScheme
        if ($active -eq '381b4222-f694-41f0-9685-ff5bb260df2e' -and $minp -and [int]$minp.ac -eq 100 -and $epp -and [int]$epp.ac -eq 0) { New-HealthFinding 'Risky settings' 'warn' 4 'Balanced plan forced to 100% minimum state and EPP 0' 'This keeps the CPU at full clocks all the time without a measurable gain, and on Ryzen it reduces boost headroom. Power mode: Best performance does this the supported way.' 'Reset processor power settings' { Reset-ProcessorPowerDefaults } }
    } }
    @{ Category='Risky settings'; Run={
        $active = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction SilentlyContinue).ActivePowerScheme
        $ultimateLike = $active -in @('e9a42b02-d5df-448d-aa00-03f14749eb61','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        if (-not $ultimateLike) { $park = Get-PowerIndexRecord 'CPMINCORES'; $ultimateLike = ($park -and [int]$park.ac -eq 100 -and ($script:Env.CpuX3D -or $script:Env.CpuHybrid)) }
        if ($ultimateLike -and ($script:Env.CpuX3D -or $script:Env.CpuHybrid -or $script:Env.IsLaptop)) { New-HealthFinding 'Risky settings' 'warn' 8 'Power plan stops core parking on a CPU that needs it' ('{0} relies on core parking to keep games on the right cores (V-Cache die or performance cores). Use the Balanced plan with Power mode set to Best performance.' -f $(if ($script:Env.CpuX3D) { 'A Ryzen X3D CPU' } elseif ($script:Env.CpuHybrid) { 'An Intel hybrid CPU' } else { 'A laptop' })) 'Switch to Balanced' { & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e; Write-Log 'Balanced plan activated.' 'Success' } }
    } }
    @{ Category='Risky settings'; Run={
        $v = Get-RegNumber 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
        if ($null -ne $v -and $v -notin 2,38) { New-HealthFinding 'Risky settings' 'warn' 5 ('Foreground priority changed (Win32PrioritySeparation {0})' -f $v) 'Windows default 0x26 gives the game window extra CPU time over background apps. Custom values from tweak guides usually remove that boost.' 'Reset scheduling to defaults' { Reset-MmcssDefaults } }
        if ((Get-RegNumber 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff') -eq 1) { New-HealthFinding 'Risky settings' 'warn' 5 'Power throttling (EcoQoS) is turned off for every app' 'Background apps run at full power and compete with the game for the CPU power budget. Exempt only your games instead (CPU tab).' 'Reset scheduling to defaults' { Reset-MmcssDefaults } }
    } }
    @{ Category='Risky settings'; Run={
        if ((Get-RegNumber 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 0) { New-HealthFinding 'Risky settings' 'warn' 3 'Game Mode is off' 'Game Mode stops Windows Update from installing drivers and showing restart prompts while you play, and gives the game scheduling priority.' 'Turn Game Mode on' { Set-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -Type DWord; Write-Log 'Game Mode turned on.' 'Success' } }
        if ((Get-RegNumber 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode') -eq 2) { New-HealthFinding 'Risky settings' 'warn' 3 'Fullscreen optimizations are forced off for every game' 'On Windows 11, flip-model presentation in borderless and optimized fullscreen is as fast or faster and keeps alt-tab instant. Forcing legacy exclusive fullscreen everywhere helps nothing.' }
    } }
    @{ Category='Risky settings'; Run={
        $off = @(@('wlidsvc','Microsoft account sign-in'),@('NgcSvc','Windows Hello PIN and passkeys'),@('TokenBroker','Web Account Manager (Office, Teams, Edge sign-in)') | Where-Object { (Get-ServiceStartValue $_[0]) -eq 4 } | ForEach-Object { $_[1] })
        if ($off.Count) { New-HealthFinding 'Risky settings' 'warn' 5 'Sign-in services are disabled' ('Disabled: ' + ($off -join ', ') + '. Microsoft Store, Xbox, Office, OneDrive and Windows Hello sign-in break while these are off.') 'Repair sign-in services' { Repair-SignInServices } }
        if ((Get-ServiceStartValue 'CryptSvc') -in 3,4) { New-HealthFinding 'Risky settings' 'warn' 3 'Cryptographic Services is not set to Automatic' 'Certificate checks, Windows Update signatures and app installs depend on it.' 'Repair sign-in services' { Repair-SignInServices } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $found = @(foreach ($n in 'useplatformclock','useplatformtick','disabledynamictick','tscsyncpolicy') { if ($null -ne (Get-BcdValue '{current}' $n)) { $n } })
        if ($found.Count) { New-HealthFinding 'Placebo tweaks' 'warn' 8 ('Boot timer overrides set ({0})' -f ($found -join ', ')) 'These BCD values force the HPET or change timer behaviour. On CPUs with an invariant TSC they add timer overhead, input latency and stutter with no measured gain. Windows picks the right timer by itself.' 'Remove them' { $t = $script:TweakIndex['adv.bcd.timers']; if ($t) { foreach ($a in @($t.Apply)) { Invoke-Action $a } }; Write-Log 'BCD timer overrides removed; restart Windows.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $hpet = @(Get-PnpDevice -FriendlyName 'High precision event timer' -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        if ($hpet.Count) { New-HealthFinding 'Placebo tweaks' 'warn' 4 'High precision event timer disabled in Device Manager' 'A tweak-guide myth: Windows only uses the HPET when told to, so disabling the device gains nothing and can break apps or drivers that query it.' 'Re-enable HPET' { Get-PnpDevice -FriendlyName 'High precision event timer' -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue; Write-Log 'HPET device re-enabled.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        $odd = @()
        $nti = Get-RegNumber $sp 'NetworkThrottlingIndex'; if ($null -ne $nti -and $nti -ne 10) { $odd += ('NetworkThrottlingIndex {0}' -f $nti) }
        $sr = Get-RegNumber $sp 'SystemResponsiveness'; if ($null -ne $sr -and $sr -ne 20) { $odd += ('SystemResponsiveness {0}' -f $sr) }
        foreach ($n in 'NoLazyMode','AlwaysOn','LazyModeTimeout') { if ($null -ne (Get-RegNumber $sp $n)) { $odd += $n } }
        $gp = Get-RegNumber "$sp\Tasks\Games" 'Priority'; if ($null -ne $gp -and $gp -ne 2) { $odd += ('Games task Priority {0}' -f $gp) }
        if ($odd.Count) { New-HealthFinding 'Placebo tweaks' 'warn' 4 'Multimedia scheduler (MMCSS) values changed' (($odd -join ', ') + '. MMCSS only schedules audio and multimedia threads; these values do not raise game FPS, and NetworkThrottlingIndex off was measured to add DPC latency.') 'Reset to Windows defaults' { Reset-MmcssDefaults } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        $odd = @()
        if ((Get-RegNumber $mm 'LargeSystemCache') -eq 1) { $odd += 'LargeSystemCache=1 (server file-cache policy; takes memory from games)' }
        foreach ($n in 'IoPageLockLimit','SystemPages','NonPagedPoolSize','PagedPoolSize') { $v = Get-RegNumber $mm $n; if ($v) { $odd += ('{0}={1} (ignored on 64-bit Windows)' -f $n,$v) } }
        if ((Get-RegNumber $mm 'ClearPageFileAtShutdown') -eq 1) { $odd += 'ClearPageFileAtShutdown=1 (makes every shutdown slow)' }
        if ($odd.Count) { New-HealthFinding 'Placebo tweaks' 'warn' 4 'Memory manager tweaks found' ($odd -join '; ') 'Remove them' { foreach ($n in 'LargeSystemCache','IoPageLockLimit','SystemPages','NonPagedPoolSize','PagedPoolSize','ClearPageFileAtShutdown') { Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name $n }; Write-Log 'Memory manager values back to Windows defaults; restart Windows.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $odd = @()
        foreach ($p in @(@('mouclass','MouseDataQueueSize'),@('kbdclass','KeyboardDataQueueSize'))) { $v = Get-RegNumber ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters" -f $p[0]) $p[1]; if ($null -ne $v -and $v -ne 100) { $odd += ('{0}={1}' -f $p[1],$v) } }
        if ($odd.Count) { New-HealthFinding 'Placebo tweaks' 'warn' 4 'Mouse or keyboard buffer size changed' (($odd -join ', ') + '. The buffer only matters when input arrives faster than it is read; shrinking it can drop clicks and key presses with high-polling devices and does not lower latency.') 'Reset to 100' { foreach ($p in @(@('mouclass','MouseDataQueueSize'),@('kbdclass','KeyboardDataQueueSize'))) { Remove-RegValue -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters" -f $p[0]) -Name $p[1] }; Write-Log 'Input buffer sizes reset; restart Windows.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $q = (& fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String)
        if ($q -match 'NTFS DisableDeleteNotify\s*=\s*1') { New-HealthFinding 'Placebo tweaks' 'bad' 8 'SSD TRIM is turned off' 'Without TRIM the SSD slows down as it fills and wears faster. Some old guides turned it off; it should always be on.' 'Turn TRIM on' { & fsutil.exe behavior set DisableDeleteNotify 0 | Out-Null; Write-Log 'TRIM turned on.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $auto = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).AutomaticManagedPagefile
        $files = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if (-not $auto -and -not $files.Count) { New-HealthFinding 'Placebo tweaks' 'bad' 10 'The page file is turned off' 'Without a page file, games and browsers crash with out-of-memory errors when memory fills, and Windows cannot save a crash dump. Let Windows manage the page file size.' 'Let Windows manage it' { $cs = Get-CimInstance Win32_ComputerSystem; Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }; Write-Log 'Page file set to system managed; restart Windows.' 'Success' } }
        $pf = Get-RegNumber 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher'
        if ($pf -eq 0) { New-HealthFinding 'Placebo tweaks' 'warn' 3 'Prefetch is turned off' 'Prefetch preloads the files apps and games need at launch; with it off, launches and loading are slower, even on an SSD.' 'Turn prefetch back on' { Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name 'EnablePrefetcher' -Value 3 -Type DWord; Write-Log 'Prefetch turned back on.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        if ((Get-RegNumber $k 'FeatureSettingsOverride') -eq 3 -and (Get-RegNumber $k 'FeatureSettingsOverrideMask') -eq 3) { New-HealthFinding 'Placebo tweaks' 'warn' 5 'CPU side-channel protections (Spectre/Meltdown) are off' ('Set by a tweak tool. Meltdown does not affect AMD CPUs and modern CPUs fix most of it in hardware, so the speed gain is tiny, while malicious code in a browser or game mod can read memory it should not.{0}' -f $(if ($script:Env.CpuVendor -eq 'AMD') { ' On this AMD CPU the gain is close to zero.' } else { '' })) 'Turn protections back on' { foreach ($n in 'FeatureSettingsOverride','FeatureSettingsOverrideMask') { Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name $n }; Write-Log 'CPU side-channel protections back to Windows defaults; restart Windows.' 'Success' } }
    } }
    @{ Category='Placebo tweaks'; Run={
        $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
        $sysProcs = @('csrss.exe','dwm.exe','audiodg.exe','lsass.exe','svchost.exe','wininit.exe','winlogon.exe','services.exe','smss.exe','fontdrvhost.exe','sihost.exe','ctfmon.exe','explorer.exe','MsMpEng.exe','ntoskrnl.exe','System','StartMenuExperienceHost.exe','ShellExperienceHost.exe','SearchHost.exe','RuntimeBroker.exe','conhost.exe','dllhost.exe','spoolsv.exe','WmiPrvSE.exe','SearchIndexer.exe','SearchProtocolHost.exe','SearchFilterHost.exe','TrustedInstaller.exe','TiWorker.exe','CompatTelRunner.exe')
        $foreground = @('csrss.exe','dwm.exe','audiodg.exe','lsass.exe','winlogon.exe','fontdrvhost.exe','sihost.exe','ctfmon.exe','explorer.exe','StartMenuExperienceHost.exe','ShellExperienceHost.exe','SearchHost.exe','System','ntoskrnl.exe','wininit.exe','services.exe','smss.exe')
        $hits = @(); $flagged = @()
        foreach ($proc in $sysProcs) {
            $po = Join-Path (Join-Path $ifeo $proc) 'PerfOptions'
            if (-not (Test-Path -LiteralPath $po)) { continue }
            $v = Get-ItemProperty -LiteralPath $po -ErrorAction SilentlyContinue
            $cpu = $v.CpuPriorityClass; $io = $v.IoPriority
            $raised = ($null -ne $cpu -and [int]$cpu -in 3,4,6) -or ($null -ne $io -and [int]$io -ge 3)
            $lowered = ($null -ne $cpu -and [int]$cpu -in 1,5) -or ($null -ne $io -and [int]$io -le 1)
            if (-not ($raised -or ($lowered -and $foreground -contains $proc))) { continue }
            $desc = @()
            if ($null -ne $cpu) { $desc += ('CPU {0}' -f $(switch ([int]$cpu) { 1 {'Idle'} 2 {'Normal'} 3 {'High'} 4 {'Realtime'} 5 {'Below normal'} 6 {'Above normal'} default {[int]$cpu} })) }
            if ($null -ne $io) { $desc += ('I/O {0}' -f $(switch ([int]$io) { 0 {'Very low'} 1 {'Low'} 2 {'Normal'} 3 {'High'} default {[int]$io} })) }
            $hits += ('{0} ({1})' -f $proc,($desc -join ', ')); $flagged += $proc
        }
        if ($hits.Count) {
            New-HealthFinding 'Placebo tweaks' 'warn' 4 'Forced priorities on Windows processes' (($hits -join '; ') + '. Raising Windows processes such as csrss or dwm to High does not raise FPS and can starve the game of CPU time; lowering the desktop, audio or sign-in processes causes stutter and crackling audio. Lowering background processes (search, update installer) is fine and is not flagged.') 'Remove the forced priorities' ([scriptblock]::Create(('foreach ($p in @({0})) {{ Remove-Item -LiteralPath (Join-Path (Join-Path ''{1}'' $p) ''PerfOptions'') -Recurse -Force -ErrorAction SilentlyContinue }}; Write-Log ''Forced priorities on Windows processes removed.'' ''Success''' -f ((@($flagged | ForEach-Object { "'$_'" })) -join ','),$ifeo)))
        }    } }
    @{ Category='Placebo tweaks'; Run={
        $odd = @(); $fixes = @()
        if ((Get-RegNumber 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive') -eq 1) { $odd += 'DisablePagingExecutive=1 (Windows already keeps hot kernel code in RAM)'; $fixes += "Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'DisablePagingExecutive'" }
        $ps = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
        foreach ($n in @('NonBestEffortLimit')) { if ($null -ne (Get-RegNumber $ps $n)) { $odd += ('QoS {0} (the 20% reserved bandwidth is a myth; it only applies to apps that request QoS)' -f $n); $fixes += ("Remove-RegValue -Path '{0}' -Name '{1}'" -f $ps,$n) } }
        $dns = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
        foreach ($n in 'NegativeCacheTime','MaxNegativeCacheTtl','NetFailureCacheTime','NegativeSOACacheTime','MaxCacheTtl') { if ($null -ne (Get-RegNumber $dns $n)) { $odd += ('DNS cache {0} (no effect on game traffic)' -f $n); $fixes += ("Remove-RegValue -Path '{0}' -Name '{1}'" -f $dns,$n) } }
        $pc = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -ErrorAction SilentlyContinue
        if ($pc) { foreach ($n in @($pc.GetValueNames() | Where-Object { $_ -match '^IRQ\d+Priority$' })) { $odd += ('{0} (IRQ priority keys are ignored on APIC/MSI systems)' -f $n); $fixes += ("Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name '{0}'" -f $n) } }
        foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)) {
            foreach ($n in 'TcpAckFrequency','TCPNoDelay','TcpDelAckTicks') { if ($null -ne (Get-RegNumber $k.PSPath $n)) { $odd += ('{0} on a network interface (Nagle only affects TCP; online games use UDP)' -f $n); $fixes += ("Remove-RegValue -Path '{0}' -Name '{1}'" -f $k.PSPath,$n) } }
        }
        if ($odd.Count) { New-HealthFinding 'Placebo tweaks' 'info' 0 ('{0} harmless placebo value(s) set' -f $odd.Count) (($odd | Select-Object -Unique) -join '; ') 'Remove them' ([scriptblock]::Create((($fixes | Select-Object -Unique) -join '; ') + "; Write-Log 'Placebo values removed; restart Windows.' 'Success'")) }
    } }
    @{ Category='Security and recovery'; Run={
        $other = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object { [string]$_.displayName -notmatch '(?i)Windows Defender|Microsoft Defender' -and (([int]$_.productState -shr 12) -band 0xF) -eq 1 })
        if ($other.Count) { return }
        $m = $null; try { $m = Get-MpComputerStatus -ErrorAction Stop } catch { }
        if ($m -and $m.RealTimeProtectionEnabled) { return }
        $wd = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
        $byChoice = ((Get-RegNumber $wd 'DisableAntiSpyware') -eq 1) -or ((Get-RegNumber $wd 'DisableAntiVirus') -eq 1) -or ((Get-RegNumber ($wd + '\Real-Time Protection') 'DisableRealtimeMonitoring') -eq 1) -or ((Get-ServiceStartValue 'WinDefend') -eq 4) -or $script:Journal.ContainsKey('sec.defender')
        if ($byChoice) { New-HealthFinding 'Security and recovery' 'info' 0 'Microsoft Defender is turned off' 'It was switched off on purpose (a policy, a disabled service or the Rion Tool option), and no other antivirus is active. Downloads, mods and tools are not scanned. Use the fix to turn it back on whenever you want.' 'Turn Defender back on' { Repair-Defender } }
        else { New-HealthFinding 'Security and recovery' 'warn' 6 'No real-time antivirus protection' 'Microsoft Defender real-time protection is off and no other antivirus is active, so downloads, mods and tools run unchecked.' 'Turn Defender back on' { Repair-Defender } }
    } }
    @{ Category='Security and recovery'; Run={
        $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count) { New-HealthFinding 'Security and recovery' 'bad' 8 ('Windows Firewall is off ({0})' -f ($off -join ', ')) 'Every listening program is reachable from the network you are on, including public Wi-Fi.' 'Turn the firewall on' { Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True; Write-Log 'Windows Firewall turned on for all profiles.' 'Success' } }
    } }
    @{ Category='Security and recovery'; Run={
        $last = $null; try { $last = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1 } catch { }
        $when = if ($last) { [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime) } else { $null }
        if (-not $when) { New-HealthFinding 'Security and recovery' 'warn' 6 'No restore point found' 'If a driver, update or tweak goes wrong, there is nothing to roll back to. System Protection may be off for the system drive.' 'Create a restore point' { New-RestorePoint | Out-Null } }
        elseif (((Get-Date) - $when).TotalDays -gt 30) { New-HealthFinding 'Security and recovery' 'warn' 3 ('Newest restore point is {0} days old' -f [int]((Get-Date) - $when).TotalDays) 'Create one before changing drivers or settings.' 'Create a restore point' { New-RestorePoint | Out-Null } }
    } }
    @{ Category='Security and recovery'; Run={
        $sb = $null; try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
        if ($sb -eq $false) { New-HealthFinding 'Security and recovery' 'warn' 5 'Secure Boot is off' 'Valorant (Vanguard), Battlefield 6, Call of Duty and other anti-cheats require Secure Boot on Windows 11, and it blocks boot-level malware. Turn it on in BIOS (Boot > Secure Boot, OS type Windows UEFI).' }
        $tpm = $null; try { $tpm = Get-Tpm -ErrorAction Stop } catch { }
        if ($tpm -and -not ($tpm.TpmPresent -and $tpm.TpmReady)) { New-HealthFinding 'Security and recovery' 'warn' 5 'TPM is not ready' 'Windows 11 features, BitLocker and several anti-cheats need TPM 2.0. Enable fTPM (AMD) or PTT (Intel) in BIOS.' }
    } }
    @{ Category='Security and recovery'; Run={
        if ((Get-RegNumber 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA') -eq 0) { New-HealthFinding 'Security and recovery' 'bad' 8 'User Account Control is turned off' 'Every program runs with full administrator rights without asking, and Store apps and some games refuse to start.' 'Turn UAC back on' { Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 1 -Type DWord; Write-Log 'UAC turned on; restart Windows.' 'Success' } }
        $re = ''; try { $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\reagentc.exe'),'/info'; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true; $rp = [Diagnostics.Process]::Start($psi); $re = $rp.StandardOutput.ReadToEnd(); $rp.WaitForExit() } catch { }
        if ($re -match '(?i)Windows RE status:\s*Disabled') { New-HealthFinding 'Security and recovery' 'warn' 5 'Windows Recovery Environment is disabled' 'Reset this PC, Startup Repair and Advanced Startup need it. Turning it back on fails if the recovery files were deleted.' 'Enable WinRE' { & reagentc.exe /enable | Out-Null; Write-Log 'Windows Recovery Environment enabled (if its files are present).' 'Success' } }
    } }
    @{ Category='Maintenance'; Run={
        $sum = 0
        foreach ($cat in @($script:CleanupCategories | Where-Object { $_.Default -and -not $_.Special })) { $sum += Measure-CleanupCategory $cat }
        if ($sum -gt 1GB) { New-HealthFinding 'Maintenance' 'warn' 4 ('Your PC needs a cleanup ({0} of junk files)' -f (Format-Bytes $sum)) 'Temporary files, update caches, error reports and driver installer leftovers. Clean up now removes them; Cleanup > Deep cleanup also repairs and shrinks Windows itself.' 'Clean up now' { Invoke-QuickCleanup } }
        elseif ($sum -gt 300MB) { New-HealthFinding 'Maintenance' 'info' 0 ('{0} of junk files can be cleaned' -f (Format-Bytes $sum)) 'Not urgent.' 'Clean up now' { Invoke-QuickCleanup } }
    } }
    @{ Category='Maintenance'; Run={
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($pending) { New-HealthFinding 'Maintenance' 'warn' 3 'A restart is pending' 'Updates or driver changes finish installing only after a restart.' }
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
        if ($boot -and ((Get-Date) - $boot).TotalDays -gt 14) { New-HealthFinding 'Maintenance' 'info' 0 ('Windows has been running for {0} days' -f [int]((Get-Date) - $boot).TotalDays) 'Fast Startup keeps the kernel between shutdowns; a real restart now and then clears leaks and finishes updates.' }
    } }
    @{ Category='Maintenance'; Run={
        $on = @(Get-StartupEntries | Where-Object { -not (Test-StartupEntryDisabled $_) })
        if ($on.Count -gt 10) { New-HealthFinding 'Maintenance' 'warn' 3 ('{0} apps start with Windows' -f $on.Count) 'Each one adds sign-in time and background CPU and memory use. Turn off the ones you do not need at sign-in (Tweaks > Startup and tasks).' }
        $ghost = @(Get-GhostDevices)
        if ($ghost.Count -gt 40) { New-HealthFinding 'Maintenance' 'info' 0 ('{0} old devices are still registered' -f $ghost.Count) 'Devices that were unplugged long ago. Harmless, but removing them tidies Device Manager and clears stale network adapter and audio entries.' 'Open Cleanup' { Select-RionTab 'Cleanup' } }
    } }
    @{ Category='Maintenance'; Run={
        if (-not $script:Detection) { return }
        $missing = @($script:Tweaks | Where-Object { $_.Type -ne 'info' -and $_.Type -ne 'dropdown' -and $script:NoPreset -notcontains $_.Id -and [bool]$_.Recommend -and $script:Detection[$_.Id] -and $script:Detection[$_.Id].Present -and -not $script:Detection[$_.Id].Applied })
        if ($missing.Count) { New-HealthFinding 'Maintenance' $(if ($missing.Count -gt 20) { 'warn' } else { 'info' }) ([math]::Min(8,[int]($missing.Count / 5))) ('{0} recommended tweaks are not applied' -f $missing.Count) ('Examples: ' + ((@($missing | Select-Object -First 5 | ForEach-Object { $_.Label })) -join '; ') + '. None of them removes a feature people commonly use.') 'Review them' { Invoke-OneClickOptimize } }
    } }
)

function Invoke-HealthCheck {
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($chk in $script:HealthChecks) {
        try { foreach ($f in @(& $chk.Run)) { if ($f) { $findings.Add($f) } } }
        catch { Write-Log ("Health check ({0}) skipped: {1}" -f $chk.Category,$_.Exception.Message) 'Warn' }
    }
    $lost = 0
    foreach ($f in $findings) { $lost += switch ($f.Severity) { 'bad' { $f.Weight } 'warn' { [math]::Ceiling($f.Weight / 2) } default { 0 } } }
    $score = [math]::Max(0,100 - $lost)
    $cats = [ordered]@{}
    foreach ($c in $script:HealthCategories.Keys) {
        $catLost = 0
        foreach ($f in @($findings | Where-Object { (Get-HealthGroup $_.Category) -eq $c })) { $catLost += switch ($f.Severity) { 'bad' { $f.Weight } 'warn' { [math]::Ceiling($f.Weight / 2) } default { 0 } } }
        $cats[$c] = [math]::Max(0,100 - 3 * $catLost)
    }
    $grade = if ($score -ge 90) { 'Excellent' } elseif ($score -ge 75) { 'Good' } elseif ($score -ge 60) { 'Fair' } else { 'Needs attention' }
    $script:HealthResult = @{ Score=$score; Grade=$grade; Findings=@($findings | Sort-Object @{ Expression={ @($script:HealthCategories.Keys).IndexOf((Get-HealthGroup $_.Category)) } },@{ Expression={ switch ($_.Severity) { 'bad' {0} 'warn' {1} default {2} } } },@{ Expression={ $_.Weight }; Descending=$true }); Categories=$cats; At=(Get-Date) }
    Write-Log ("Health check: {0}/100 ({1}), {2} finding(s)." -f $score,$grade,$findings.Count) 'Info'
    return $script:HealthResult
}

function Get-PlaceboFindings {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try { $h = Invoke-HealthCheck } finally { $script:Window.Cursor = $null }
    return @($h.Findings | Where-Object { $_.Category -eq 'Placebo tweaks' -and $_.Fix })
}
function Clear-PlaceboTweaks {
    param([switch]$Quiet,$Items)
    $items = if ($null -ne $Items) { @($Items) } else { @(Get-PlaceboFindings) }
    if (-not $items.Count) { if ($Quiet) { return 0 }; [System.Windows.MessageBox]::Show('No placebo tweaks found. Everything the analysis checks is at the Windows default.','Clear placebo tweaks','OK','Information') | Out-Null; return }
    $list = ($items | ForEach-Object { '- ' + $_.Title }) -join "`r`n"
    $msg = ("These old tweak-guide values were found (set by Rion Tool or any other tool) and will be put back to the Windows defaults:`r`n`r`n{0}`r`n`r`nA restore point is created first. Some changes need a restart. Continue?" -f $list)
    if (-not $Quiet) {
        if ([System.Windows.MessageBox]::Show($msg,'Clear placebo tweaks','OKCancel','Question') -ne 'OK') { return }
        New-RestorePoint 'Rion Tool placebo cleanup' | Out-Null
    }
    $ok = 0
    foreach ($f in $items) {
        try { Write-Log ("Clearing: {0}" -f $f.Title) 'Action'; & $f.Fix; $ok++ } catch { Write-Log ("Could not clear {0}: {1}" -f $f.Title,$_.Exception.Message) 'Warn' }
    }
    Write-Log ("Placebo cleanup finished: {0} of {1} cleared. Restart Windows to finish." -f $ok,$items.Count) 'Success'
    if (-not $Quiet) { try { Update-HomeHealth } catch { } }
    return $ok
}

$script:ConnectivityServices = @{
    WiFi      = [ordered]@{ WlanSvc='Automatic'; Wcmsvc='Automatic'; NlaSvc='Automatic'; netprofm='Manual'; Dhcp='Automatic'; Dnscache='Automatic'; nsi='Automatic'; NetSetupSvc='Manual'; RmSvc='Manual'; WinHttpAutoProxySvc='Manual' }
    Ethernet  = [ordered]@{ Wcmsvc='Automatic'; NlaSvc='Automatic'; netprofm='Manual'; Dhcp='Automatic'; Dnscache='Automatic'; nsi='Automatic'; NetSetupSvc='Manual'; BFE='Automatic'; dot3svc='Manual'; WinHttpAutoProxySvc='Manual' }
    Bluetooth = [ordered]@{ bthserv='Manual'; BTAGService='Manual'; BluetoothUserService='Manual'; BthAvctpSvc='Manual'; DeviceAssociationService='Manual'; DeviceInstall='Manual'; RmSvc='Manual'; BTHUSB='Manual'; BTHPORT='Manual'; BthEnum='Manual'; BthLEEnum='Manual'; RFCOMM='Manual'; BthA2dp='Manual'; BthHFEnum='Manual' }
}
function Repair-Connectivity {
    param([ValidateSet('WiFi','Ethernet','Bluetooth')][string]$Kind)
    $changed = @()
    $defaults = $script:ConnectivityServices[$Kind]
    foreach ($name in $defaults.Keys) {
        foreach ($svcName in @(@($name) + @(Resolve-ServiceNames ($name + '_*')) | Select-Object -Unique)) {
            if (-not (Test-Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $svcName))) { continue }
            $want = [int]$script:StartMap[$defaults[$name]]
            $now = Get-ServiceStartValue $svcName
            if ($null -ne $now -and [int]$now -ne $want -and ([int]$now -eq 4 -or ($want -eq 2 -and [int]$now -eq 3))) {
                try { [void](Set-ServiceStart -Name $svcName -StartType $defaults[$name]); $changed += ('{0} -> {1}' -f $svcName,$defaults[$name]) } catch { Write-Log ("Could not reset {0}: {1}" -f $svcName,$_.Exception.Message) 'Warn' }
            }
        }
    }
    foreach ($name in $defaults.Keys) { if ($defaults[$name] -eq 'Automatic') { try { Start-Service -Name $name -ErrorAction SilentlyContinue } catch { } } }
    $driverMsg = ''
    if ($Kind -eq 'Bluetooth') {
        foreach ($d in @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object { $_.Present -and $_.Status -eq 'Error' -and $_.InstanceId -match '^(USB|PCI)\\' })) {
            try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; $changed += ('enabled {0}' -f $d.FriendlyName) } catch { }
        }
        try { Start-Service -Name 'bthserv' -ErrorAction SilentlyContinue } catch { }
        $radios = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { ([string]$_.PNPClass -eq 'Bluetooth' -or [string]$_.Name -match '(?i)bluetooth') -and [string]$_.PNPDeviceID -match '^(USB|PCI)\\' })
        $noDrv = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 28 -and [string]$_.Name -match '(?i)bluetooth' })
        if ($noDrv.Count) { $driverMsg = ('Windows found a Bluetooth adapter but has no driver for it ({0}). Install the Bluetooth driver from your motherboard or PC maker''s support page, or from the Wi-Fi card maker (Intel, MediaTek, Realtek or Qualcomm), then restart.' -f (($noDrv | ForEach-Object { $_.Name }) -join ', ')) }
        elseif (-not $radios.Count) { $driverMsg = 'No Bluetooth adapter was found. If this PC should have Bluetooth (most Wi-Fi cards include it), install the Bluetooth driver from your motherboard or PC maker''s support page, check that Bluetooth is enabled in BIOS, and on desktops make sure the Wi-Fi card antenna/USB header cable is connected. Otherwise a USB Bluetooth adapter adds it.' }
        else {
            $err = @($radios | Where-Object { $_.ConfigManagerErrorCode -notin 0,22 })
            if ($err.Count) { $driverMsg = ('The Bluetooth adapter still reports a problem (Device Manager code {0}). Reinstall its driver from your board, PC or Wi-Fi card maker and restart.' -f $err[0].ConfigManagerErrorCode) }
        }
    } else {
        $isWifi = ($Kind -eq 'WiFi')
        $match = { param($a) $wl = ([string]$a.PhysicalMediaType -match '802\.11|Wireless') -or ([string]$a.InterfaceDescription -match '(?i)Wi-?Fi|Wireless|WLAN|802\.11'); if ($isWifi) { $wl } else { -not $wl } }
        $adapters = @(Get-NetAdapter -Physical -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { & $match $_ })
        foreach ($a in @($adapters | Where-Object { $_.Status -eq 'Disabled' })) { try { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop; $changed += ('enabled adapter {0}' -f $a.Name) } catch { } }
        foreach ($a in $adapters) { try { $b = Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip -ErrorAction Stop; if (-not $b.Enabled) { Enable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip -ErrorAction Stop; $changed += ('IPv4 turned back on for {0}' -f $a.Name) } } catch { } }
        $word = if ($isWifi) { 'Wi-Fi' } else { 'Ethernet' }
        $pattern = if ($isWifi) { '(?i)wi-?fi|wireless|wlan|802\.11' } else { '(?i)ethernet|gbe|lan|network controller|realtek pcie|intel.*i2[12]\d' }
        $noDrv = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 28 -and ([string]$_.Name -match $pattern -or ([string]$_.PNPDeviceID -like 'PCI\*' -and [string]$_.Name -match '(?i)network|ethernet|controller')) })
        if ($noDrv.Count) { $driverMsg = ('Windows found a network device without a driver ({0}). Install the {1} driver from your motherboard or PC maker''s support page (or the adapter maker: Intel, Realtek, Killer, MediaTek, Qualcomm), then restart. Use another PC or phone USB tethering to download it if this PC has no other connection.' -f (($noDrv | ForEach-Object { if ($_.Name) { $_.Name } else { $_.PNPDeviceID } }) -join ', '),$word) }
        elseif (-not @($adapters).Count) { $driverMsg = ('No {0} adapter was found. Install the {0} driver from your motherboard or PC maker''s support page, and check that the adapter is enabled in BIOS{1}.' -f $word,$(if ($isWifi) { ' and the Wi-Fi card or USB adapter is connected' } else { '' })) }
    }
    if ($changed.Count) { Write-Log ('{0} repair: {1}. Restart if it still does not work.' -f $Kind,($changed -join '; ')) 'Success' } else { Write-Log ('{0} repair: services, adapters and settings were already at their Windows defaults.' -f $Kind) 'Success' }
    if ($driverMsg) { [System.Windows.MessageBox]::Show($driverMsg,('{0} driver needed' -f $(if ($Kind -eq 'WiFi') { 'Wi-Fi' } else { $Kind })),'OK','Warning') | Out-Null }
}

$fixesPanel = New-Object Windows.Controls.DockPanel; $fixesPanel.Margin='10'
$fixDefs = @(
    @{ Group='Repair Windows'; Label='Run DISM and SFC (repair system files)'; Info='DISM /Online /Cleanup-Image /RestoreHealth repairs the component store first, then sfc /scannow repairs system files from it. Fixes "features not applying" and corruption.'; Act={ Start-Process cmd '/k DISM /Online /Cleanup-Image /RestoreHealth & sfc /scannow' } }
    @{ Group='Deep cleanup'; Label='Deep clean: DISM, SFC, temp files and Disk Cleanup'; Info='Opens a window that runs DISM RestoreHealth, SFC, component store cleanup, clears user and Windows temp folders, runs Disk Cleanup (keeping the DirectX shader cache, Downloads, Recycle Bin, previous Windows installations, the Reset this PC image, File History versions, older drivers and crash dumps), then flushes DNS. Prefetch is kept because it speeds up launches. Takes 15-30 minutes.'; Act={ Invoke-FullCleanup } }
    @{ Group='Repair Windows'; Label='Turn Windows Update back on'; Info='Puts the Windows Update, Update Orchestrator, Medic, BITS and Delivery Optimization services back to their defaults, removes policies other tools use to block updates (no auto update, blocked update servers, hidden update page) and turns the update tasks back on. Your feature-update deferral and driver choices stay as they are.'; Act={ Repair-WindowsUpdate } }
    @{ Group='Repair Windows'; Label='Turn Microsoft Defender back on'; Info='Undoes the Rion Tool Defender option and removes the policies other tools use to switch Defender off (DisableAntiSpyware, real-time protection and cloud policies), turns its scheduled tasks back on and opens Windows Security. Restart afterwards.'; Act={ Repair-Defender } }
    @{ Group='Gaming and anti-cheat'; Label='Install missing game runtimes (Visual C++, DirectX)'; Info='Installs the Visual C++ 2015-2022 runtimes (64 and 32-bit) and the DirectX End-User Runtime through WinGet when they are missing. Most games and launchers need them; a missing one shows up as "VCRUNTIME140.dll was not found" or "d3dx9_43.dll is missing".'; Act={ Install-GameRuntimes } }
    @{ Group='Repair Windows'; Label='Fix Start menu typing (search ignores keys until clicked)'; Info='Lets the Start menu, Search, shell and text-input apps run in the background even when background apps are blocked, clears the per-user background-app off switches, re-enables the text input service and ctfmon, then restarts Search and Start.'; Act={ Repair-StartSearch } }
    @{ Group='Reset tuning to Windows defaults'; Label='Reset network adapter tuning to driver defaults'; Info='Puts every physical adapter back to its driver defaults for checksum/LSO/UDP offloads, flow control, interrupt moderation, packet coalescing, buffers, RSC and RSS, removes Nagle (TcpAckFrequency/TCPNoDelay) values, sets TCP autotuning to normal and restarts connected adapters (a few seconds offline). Use this if network tweaks made the connection unstable.'; Act={ Reset-NetworkTuning } }
    @{ Group='Deep cleanup'; Label='Clear Windows Update and Store caches'; Info='Stops the update services, clears the SoftwareDistribution download cache and the Delivery Optimization cache, restarts the services, and resets the Microsoft Store cache (wsreset). Fixes stuck updates and Store errors; the next update check and Store open rebuild the caches.'; Act={ Clear-UpdateAndStoreCaches } }
    @{ Group='Repair Windows'; Label='Restart to Advanced Startup (recovery options)'; Info='Runs shutdown /r /o /t 0 to reboot straight into the blue Choose an option / recovery screen (same as holding Shift while clicking Restart), where you can launch Startup Repair, System Restore, a boot device or UEFI settings. Windows must restart once to reach WinRE; there is no supported way to open it without a reboot. Save your work first.'; Act={ Start-Process shutdown.exe -ArgumentList '/r','/o','/t','0' } }
    @{ Group='Deep cleanup'; Label='Reclaim space: component store + Windows.old'; Info='Runs DISM /StartComponentCleanup /ResetBase and removes the previous Windows installation (Windows.old) through Disk Cleanup. Frees several GB, but afterwards you can no longer uninstall installed updates or roll back the last Windows feature upgrade. Keeps DirectX shader cache, Downloads and the Recycle Bin.'; Act={ Remove-WindowsOld } }
    @{ Group='Network'; Label='Repair Wi-Fi'; Info='Puts every service Wi-Fi depends on back to its Windows start type (WLAN AutoConfig, connection manager, network awareness, DHCP, DNS, network setup, radio management), re-enables disabled Wi-Fi adapters and their IPv4 binding. If no Wi-Fi adapter or driver is found, a message tells you what to install.'; Act={ Repair-Connectivity 'WiFi' } }
    @{ Group='Network'; Label='Repair Ethernet'; Info='Puts every service a wired connection depends on back to its Windows start type (DHCP, DNS, network awareness, connection manager, network setup, Base Filtering Engine, Wired AutoConfig), re-enables disabled Ethernet adapters and their IPv4 binding. If no Ethernet adapter or driver is found, a message tells you what to install.'; Act={ Repair-Connectivity 'Ethernet' } }
    @{ Group='Network'; Label='Repair Bluetooth'; Info='Puts the Bluetooth services and drivers back to their Windows start type (Bluetooth support, audio gateway, per-user Bluetooth, device association and install, radio management, Bluetooth bus drivers) and re-enables a disabled Bluetooth adapter. If no Bluetooth adapter or driver is found, a message tells you what to install.'; Act={ Repair-Connectivity 'Bluetooth' } }
    @{ Group='Network'; Label='Reset the network stack'; Info='netsh winsock reset + netsh int ip reset + flushdns. Fixes many connectivity faults. Reboot after.'; Act={ Start-Process cmd '/c netsh winsock reset & netsh int ip reset & ipconfig /flushdns' } }
    @{ Group='Repair Windows'; Label='Fix "Create a restore point" not working'; Info='Enables System Protection on C: and lifts the 24-hour throttle so restore points can be created.'; Act={ Enable-ComputerRestore -Drive 'C:\'; Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0 'DWord' } }
    @{ Group='Microsoft apps'; Label='Repair or reinstall Microsoft Store'; Info='Re-registers Store from local files, then force-installs its package through WinGet without opening the Store window. Windows Update and Delivery Optimization are started only for the package download, then their previous state is restored; Rion does not request an OS update scan or installation.'; Act={ Repair-StorePackage -App ($script:MicrosoftAppCatalog | Where-Object { $_.Name -eq 'Microsoft Store' } | Select-Object -First 1) -Reinstall } }
    @{ Group='Gaming and anti-cheat'; Label='Reinstall Xbox app and gaming components'; Info='Repairs or installs the Xbox app, Xbox Game Bar, Gaming Services, and Xbox Identity Provider. It restores disabled Xbox gaming services to on-demand startup. Installs through WinGet without opening the Store window; Windows Update is started only temporarily for package downloads, with no OS update request.'; Act={ Repair-XboxSuite } }
    @{ Group='Microsoft apps'; Label='Reinstall Snipping Tool'; Info='Re-registers Snipping Tool from local files, then force-installs its package through WinGet without opening the Store window. Windows Update and Delivery Optimization are started only for the package download, then their previous state is restored; Rion does not request an OS update scan or installation.'; Act={ Repair-StorePackage -App ($script:MicrosoftAppCatalog | Where-Object { $_.Name -eq 'Snipping Tool' } | Select-Object -First 1) -Reinstall } }
    @{ Group='Reset tuning to Windows defaults'; Label='Clear all placebo tweaks'; Info='Runs the Placebo tweaks part of the system analysis and resets everything it finds to the Windows defaults, whatever tool set it: BCD timer overrides, HPET disabled, MMCSS values, memory manager keys, input buffer sizes, TRIM off, page file off, prefetch off, CPU side-channel overrides, forced priorities on Windows processes, svchost grouping, QoS, DNS cache, IRQ priority and Nagle values. Shows the list first and creates a restore point.'; Act={ Clear-PlaceboTweaks } }
    @{ Group='Reset tuning to Windows defaults'; Label='Reset CPU scheduling and multimedia scheduler values to Windows defaults'; Info='Restores the Windows foreground boost (Win32PrioritySeparation 0x26), turns background power throttling (EcoQoS) back on, and repairs multimedia scheduler values left by older Rion Tool builds or other tweak tools. Fixed quanta without a foreground boost and EcoQoS off both let background apps compete with games for CPU time and power. Values reset: NetworkThrottlingIndex 10, SystemResponsiveness 20, the Games task back to Priority 2 / GPU Priority 8 / Medium scheduling / Normal I/O, and removes the undocumented NoLazyMode, AlwaysOn and LazyModeTimeout values. Restart to apply.'; Act={ Reset-MmcssDefaults } }
    @{ Group='Reset tuning to Windows defaults'; Label='Reset processor idle, core parking, minimum state and EPP to Windows defaults'; Info='Sets processor idle disable, core parking minimum and maximum cores, minimum processor state and energy performance preference on the active power plan back to the defaults of the Windows plan it is based on (Balanced: idle on, 5% minimum, EPP 33 on AC). Ryzen Precision Boost raises the busy cores highest when idle cores can sleep, so idle disabled, unparked cores pinned at 100% and EPP 0 can lower game clocks. High performance and Ultimate Performance keep their own 100% minimum. Other power plan values are not changed.'; Act={ Reset-ProcessorPowerDefaults } }
    @{ Group='Repair Windows'; Label='Repair sign-in and credential services'; Info='Sets the services that keep you signed in back to their Windows defaults: Microsoft account sign-in (wlidsvc) and Web Account Manager (TokenBroker), Windows Hello PIN and passkeys (NgcSvc, NgcCtnrSvc), key isolation (KeyIso), Credential Manager (VaultSvc), Cryptographic Services (CryptSvc), and the Chrome, Edge and Brave elevation services that unlock browser cookie and password encryption. Use it when Microsoft apps, Windows Hello or a browser keep signing you out. It does not bring back logins that were already lost; sign in again afterwards. Restart required.'; Act={ Repair-SignInServices } }
    @{ Group='Repair Windows'; Label='Clear Fault Tolerant Heap app list'; Info='Runs Rundll32.exe fthsvc.dll,FthSysprepSpecialize, the built-in command that resets the list of applications Fault Tolerant Heap is tracking. Apps that crashed a few times in the past lose the FTH shims that slow their memory allocations. Windows can add an app again if it keeps crashing.'; Act={ $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rundll32.exe') -ArgumentList 'fthsvc.dll,FthSysprepSpecialize' -Wait -PassThru; Write-Log ("Fault Tolerant Heap app list cleared (exit {0})." -f $proc.ExitCode) 'Success' } }
    @{ Group='Repair Windows'; Label='Rebuild the search index'; Info='Resets Windows Search. Fixes broken Start/Settings search.'; Act={ Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows Search' 'SetupCompletedSuccessfully' 0 'DWord'; Restart-Service WSearch -ErrorAction SilentlyContinue } }
    @{ Group='Gaming and anti-cheat'; Label='Repair Xbox services (Microsoft Gaming Repair Tool)'; Info='Runs the bundled Gaming Repair Tool only if its Authenticode signature is valid and Microsoft signed, then repairs or installs Xbox app, Game Bar, Gaming Services and Identity Provider through WinGet. It never falls back to an MS Store page.'; Act={ Invoke-GamingRepair } }
    @{ Group='Microsoft apps'; Label='Restore all built-in Microsoft apps'; Info='Re-registers Microsoft app packages whose files remain on disk, then restores the catalogued core apps through WinGet without opening Store UI. Covers Store, Xbox, Snipping Tool, Photos, and Calculator. App downloads do not request Windows OS updates.'; Act={ Restore-MsApps } }
    @{ Group='Gaming and anti-cheat'; Label='Fix HVCI for Valorant / Riot Vanguard'; Info='Enables Windows Memory Integrity (HVCI) and VBS, clears an explicit boot-time hypervisor/VSM opt-out, and leaves the settings unlocked for Windows Security. Restart is required. CPU virtualization must also be enabled in UEFI/BIOS, and incompatible drivers may need updating. Vanguard may require HVCI on some systems.'; Act={ Set-HvciEnabledForAntiCheat } }
    @{ Group='Gaming and anti-cheat'; Label='Fix Control Flow Guard for Vanguard / Valorant'; Info='Enables the Windows system-level Control Flow Guard mitigation through Exploit Protection. CFG helps protect indirect calls in compatible applications. A per-app override or managed policy can still take precedence; restart affected apps or Windows.'; Act={ Enable-ControlFlowGuard } }
    @{ Group='NVIDIA (Profile Inspector)'; Label='Apply NVIDIA performance profile'; Info='Uses NVIDIA Profile Inspector 3.0.1.14 or newer (place it in the Rion Tool folder; Rion Tool does not download it) to merge Rion-NVIDIA-Performance.nip into the global profile: Prefer maximum performance, 1 pre-rendered frame with Low Latency Mode On, High performance texture filtering with the anisotropic/trilinear optimizations, negative LOD bias clamped and CUDA Force P2 off. Settings IDs come from NVIDIA''s NVAPI header shipped with Profile Inspector. Your customized profiles are exported to the backups folder first and the result is read back from the driver to verify it.'; Act={ Invoke-NvidiaNipImport 'Performance' } }
    @{ Group='NVIDIA (Profile Inspector)'; Label='Apply NVIDIA performance + Fortnite potato profile'; Info='Same global performance settings, plus the Fortnite driver profile (FortniteClient-Win64-Shipping.exe) set to the classic "potato" look: texture LOD bias +15 with driver-controlled LOD bias off and Transparency Supersampling set to AA_MODE_REPLAY_MODE_ALL so the forced bias applies, and anisotropic filtering forced off. Works with Fortnite''s DirectX 11 and Performance rendering modes; DirectX 12 ignores driver LOD bias. Imported in merge mode, verified by reading the driver back.'; Act={ Invoke-NvidiaNipImport 'FortnitePotato' } }
    @{ Group='NVIDIA (Profile Inspector)'; Label='Restore NVIDIA settings changed by Rion Tool'; Info='Merges Rion-NVIDIA-Restore-Defaults.nip, which sets every setting the two buttons above change back to the driver default value in the global and Fortnite profiles. For an exact restore of everything, import the CustomProfiles_*.nip backup from the Rion Tool backups folder in Profile Inspector.'; Act={ Invoke-NvidiaNipImport 'Defaults' } }
    @{ Group='NVIDIA (Profile Inspector)'; Label='Save the Rion .nip files and open the folder'; Info='Writes Rion-NVIDIA-Performance.nip, Rion-Fortnite-Potato.nip and Rion-NVIDIA-Restore-Defaults.nip next to Rion Tool so you can inspect them or import them yourself in Profile Inspector (choose Merge when it asks).'; Act={ if (Test-NvidiaGpuPresent) { [void](Update-FortniteProfileName) }; $f = Export-RionNipFiles -Folder $PSScriptRoot; Start-Process explorer.exe ('/select,"{0}"' -f $f['Performance']) } }
    @{ Group='Undo Rion Tool changes'; Label='Re-enable all services changed by Rion Tool (full revert)'; Info='Reverts every tweak this tool applied, using each tweak''s revert actions and the saved service backup.'; Act={ Invoke-FullRevert } }
)
$script:SearchItems = @()
$script:BuildingTab = ''
function New-ActionRow {
    param([string]$Label,[string]$Info,[scriptblock]$Act)
    $r = New-Object Windows.Controls.Grid; $r.Margin='0,3,0,3'
    foreach ($w in '*','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$r.ColumnDefinitions.Add($cd) }
    $btn = New-Object Windows.Controls.Button; $btn.Content=$Label; $btn.HorizontalContentAlignment='Left'; $btn.Tag=$Act
    $btn.Add_Click({ param($s,$e) try { Write-Log ("Running: {0}" -f $s.Content) 'Action'; & $s.Tag; Write-Log ("Done: {0}" -f $s.Content) 'Success' } catch { Write-Log ("Failed: {0} - {1}" -f $s.Content,$_.Exception.Message) 'Error' } })
    [void]$r.Children.Add($btn)
    if ($Info) { $icon = New-InfoIcon $Info; [Windows.Controls.Grid]::SetColumn($icon,1); [void]$r.Children.Add($icon) }
    $script:SearchItems += @{ Row=$r; Text=('{0} {1}' -f $Label,$Info); Tab=$script:BuildingTab }
    return $r
}
function New-HintText {
    param([string]$Text,[string]$Brush = 'SubText')
    $t = New-Object Windows.Controls.TextBlock; $t.Text=$Text; $t.TextWrapping='Wrap'; $t.Margin='0,2,0,6'
    Set-ThemeBrush $t 'Foreground' $Brush
    return $t
}
function Select-RionTab {
    param([string]$Header)
    foreach ($ti in @($Tabs.Items)) { if ([string]$ti.Header -eq $Header -or ($ti.Tag -is [string] -and [string]$ti.Tag -eq $Header)) { $Tabs.SelectedItem = $ti; return } }
}

$fixInfoTop = New-HintText 'Each fix runs a specific, documented repair. Hover the info icon for what it does. Cleanup tools are on the Cleanup tab.'
$fixInfoTop.Margin='6,0,6,6'
[Windows.Controls.DockPanel]::SetDock($fixInfoTop,'Top')
[void]$fixesPanel.Children.Add($fixInfoTop)
$fixOrder = @('Repair Windows','Reset tuning to Windows defaults','Network','Microsoft apps','Gaming and anti-cheat','NVIDIA (Profile Inspector)','Undo Rion Tool changes')
$script:BuildingTab = 'Fixes'
$fixSections = foreach ($g in @($fixDefs | Where-Object { $_.Group -ne 'Deep cleanup' } | Group-Object { $_.Group } | Sort-Object { $i = $fixOrder.IndexOf($_.Name); if ($i -lt 0) { 99 } else { $i } })) {
    $fixRows = foreach ($f in $g.Group) { New-ActionRow -Label $f.Label -Info $f.Info -Act $f.Act }
    $fixBox = New-SectionBox -Title $g.Name -Children $fixRows
    if ($g.Name -eq 'NVIDIA (Profile Inspector)') { $script:NvidiaFixBox = $fixBox }
    @{ Box=$fixBox; Weight=$g.Count }
}
$fixScroll = New-TwoColumnPanel $fixSections
[void]$fixesPanel.Children.Add($fixScroll)
Add-Tab 'Fixes' $fixesPanel | Out-Null
$script:VendorTabs = @{}
foreach ($vtab in @('AMD','NVIDIA','Intel')) {
    $items = @($script:Tweaks | Where-Object { $_.Tab -eq $vtab })
    $panel = if ($items.Count) { New-TweakPanel $items } else { New-TwoColumnPanel @() }
    if ($vtab -eq 'NVIDIA' -and $script:NvidiaFixBox) {
        try { $grid = $panel.Content; [void]$script:NvidiaFixBox.Parent.Children.Remove($script:NvidiaFixBox) } catch { }
        try { $grid.Children[0].Children.Insert(0,$script:NvidiaFixBox) } catch { }
        foreach ($it in $script:SearchItems) { try { if ($it.Row.Parent.Parent -eq $script:NvidiaFixBox) { $it.Tab = 'NVIDIA' } } catch { } }
    }
    $script:VendorTabs[$vtab] = Add-Tab $vtab $panel
}
function Update-VendorTabs {
    $vendors = @(@($script:Env.GpuVendors) + @([string]$script:Env.CpuVendor) | Where-Object { $_ })
    foreach ($v in @($script:VendorTabs.Keys)) { $script:VendorTabs[$v].Visibility = if (-not $vendors.Count -or $vendors -contains $v) { 'Visible' } else { 'Collapsed' } }
}Add-Tab 'Settings' $settingsPanel | Out-Null

$script:CleanupUi = @{ Rows=@{}; GhostChecks=@() }
$cleanRoot = New-Object Windows.Controls.DockPanel; $cleanRoot.Margin='10'
$cleanTop = New-Object Windows.Controls.StackPanel; $cleanTop.Orientation='Horizontal'; $cleanTop.Margin='6,0,6,8'
$btnCleanScan = New-Object Windows.Controls.Button; $btnCleanScan.Content='Scan sizes'; $btnCleanScan.Margin='0,0,8,0'
$btnCleanRun = New-Object Windows.Controls.Button; $btnCleanRun.Content='Clean selected'; $btnCleanRun.Margin='0,0,8,0'
$btnCleanDefaults = New-Object Windows.Controls.Button; $btnCleanDefaults.Content='Select recommended'; $btnCleanDefaults.Margin='0,0,8,0'
$cleanTotal = New-HintText 'Click Scan sizes to see how much each category holds.'; $cleanTotal.VerticalAlignment='Center'; $cleanTotal.Margin='8,0,0,0'
foreach ($b in @($btnCleanScan,$btnCleanRun,$btnCleanDefaults,$cleanTotal)) { [void]$cleanTop.Children.Add($b) }
[Windows.Controls.DockPanel]::SetDock($cleanTop,'Top'); [void]$cleanRoot.Children.Add($cleanTop)

$script:BuildingTab = 'Cleanup'
$junkRows = foreach ($cat in $script:CleanupCategories) {
    $g = New-Object Windows.Controls.Grid; $g.Margin='0,3,0,3'
    foreach ($w in '*','Auto','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }
    $cb = New-Object Windows.Controls.CheckBox; $cb.Content=$cat.Label; $cb.IsChecked=[bool]$cat.Default; $cb.VerticalAlignment='Center'
    $size = New-HintText ''; $size.Margin='10,0,8,0'; $size.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($size,1)
    $catIcon = New-InfoIcon $cat.Info; [Windows.Controls.Grid]::SetColumn($catIcon,2)
    [void]$g.Children.Add($cb); [void]$g.Children.Add($size); [void]$g.Children.Add($catIcon)
    $script:CleanupUi.Rows[$cat.Id] = @{ Check=$cb; Size=$size; Category=$cat }
    $script:SearchItems += @{ Row=$g; Text=('{0} {1}' -f $cat.Label,$cat.Info); Tab='Cleanup' }
    $g
}
$junkNote = New-HintText 'Browser profiles, Discord and other app sign-in data are never touched. Files in use are skipped.'
$junkBox = New-SectionBox -Title 'Junk files' -Children (@($junkRows) + $junkNote)

$ghostList = New-Object Windows.Controls.StackPanel
$ghostScroll = New-Object Windows.Controls.ScrollViewer; $ghostScroll.MaxHeight=320; $ghostScroll.VerticalScrollBarVisibility='Auto'; $ghostScroll.Content=$ghostList
$ghostBtns = New-Object Windows.Controls.StackPanel; $ghostBtns.Orientation='Horizontal'; $ghostBtns.Margin='0,4,0,4'
$btnGhostFind = New-Object Windows.Controls.Button; $btnGhostFind.Content='Find ghost devices'; $btnGhostFind.Margin='0,0,8,0'
$btnGhostAll = New-Object Windows.Controls.Button; $btnGhostAll.Content='Select all'; $btnGhostAll.Margin='0,0,8,0'
$btnGhostRemove = New-Object Windows.Controls.Button; $btnGhostRemove.Content='Remove selected'
foreach ($b in @($btnGhostFind,$btnGhostAll,$btnGhostRemove)) { [void]$ghostBtns.Children.Add($b) }
$ghostHint = New-HintText 'Ghost devices are hardware Windows remembers but that is no longer connected: old USB sticks, monitors, headsets, phones, network adapters. Only USB, HID, PCI, Bluetooth, display, audio, storage and portable devices are listed; system, software and virtual devices are never shown. A removed device is set up again automatically the next time it is plugged in. A restore point is created first.'
$ghostBox = New-SectionBox -Title 'Ghost devices' -Children @($ghostHint,$ghostBtns,$ghostScroll)

$deepRows = foreach ($f in @($fixDefs | Where-Object { $_.Group -eq 'Deep cleanup' })) { New-ActionRow -Label $f.Label -Info $f.Info -Act $f.Act }
$deepBox = New-SectionBox -Title 'Deep cleanup (Windows tools)' -Children $deepRows

$cleanScroll = New-TwoColumnPanel @(@{ Box=$junkBox; Weight=12 },@{ Box=$ghostBox; Weight=8 },@{ Box=$deepBox; Weight=4 })
[void]$cleanRoot.Children.Add($cleanScroll)
Add-Tab 'Cleanup' $cleanRoot | Out-Null

function Update-CleanupSizes {
    $total = 0
    foreach ($id in $script:CleanupUi.Rows.Keys) {
        $row = $script:CleanupUi.Rows[$id]
        if ($row.Category.Special -eq 'dns') { $row.Size.Text = ''; continue }
        $b = 0; try { $b = Measure-CleanupCategory $row.Category } catch { }
        $row.Size.Text = Format-Bytes $b
        if ($row.Check.IsChecked) { $total += $b }
    }
    $cleanTotal.Text = ('Selected: {0}' -f (Format-Bytes $total))
}
function Invoke-SelectedCleanup {
    param([string[]]$Ids,[switch]$Quiet)
    if (-not $Ids.Count) { if (-not $Quiet) { [System.Windows.MessageBox]::Show('Nothing is selected.','Cleanup','OK','Information') | Out-Null }; return }
    $labels = @($script:CleanupCategories | Where-Object { $Ids -contains $_.Id } | ForEach-Object { '- ' + $_.Label })
    if (-not $Quiet -and [System.Windows.MessageBox]::Show(("Clean these now?`r`n`r`n{0}" -f ($labels -join "`r`n")),'Cleanup','OKCancel','Question') -ne 'OK') { return }
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try { $r = Invoke-Cleanup -Ids $Ids } finally { $script:Window.Cursor = $null }
    if (-not $Quiet) { [System.Windows.MessageBox]::Show(("Freed {0}.`r`n`r`n{1}" -f (Format-Bytes $r.Total),($r.Lines -join "`r`n")),'Cleanup finished','OK','Information') | Out-Null }
    try { Update-CleanupSizes } catch { }
    return $r
}
function Invoke-QuickCleanup { Invoke-SelectedCleanup -Ids @($script:CleanupCategories | Where-Object { $_.Default } | ForEach-Object { $_.Id }) }
$btnCleanScan.Add_Click({ $script:Window.Cursor = [Windows.Input.Cursors]::Wait; try { Update-CleanupSizes } finally { $script:Window.Cursor = $null } })
$btnCleanDefaults.Add_Click({ foreach ($id in $script:CleanupUi.Rows.Keys) { $script:CleanupUi.Rows[$id].Check.IsChecked = [bool]$script:CleanupUi.Rows[$id].Category.Default } })
$btnCleanRun.Add_Click({ Invoke-SelectedCleanup -Ids @($script:CleanupUi.Rows.Keys | Where-Object { $script:CleanupUi.Rows[$_].Check.IsChecked }) })
$btnGhostFind.Add_Click({
    $ghostList.Children.Clear(); $script:CleanupUi.GhostChecks = @()
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try { $devs = @(Get-GhostDevices) } finally { $script:Window.Cursor = $null }
    if (-not $devs.Count) { [void]$ghostList.Children.Add((New-HintText 'No ghost devices found.')); return }
    foreach ($d in $devs) {
        $cb = New-Object Windows.Controls.CheckBox; $cb.Margin='0,2,0,2'; $cb.Tag=[string]$d.InstanceId; $cb.ToolTip=[string]$d.InstanceId
        $cb.Content = ('{0}  ({1})' -f $(if ($d.FriendlyName) { $d.FriendlyName } else { $d.InstanceId }),$d.Class)
        [void]$ghostList.Children.Add($cb); $script:CleanupUi.GhostChecks += $cb
    }
    Write-Log ("Found {0} ghost device(s)." -f $devs.Count) 'Info'
})
$btnGhostAll.Add_Click({ foreach ($cb in $script:CleanupUi.GhostChecks) { $cb.IsChecked = $true } })
$btnGhostRemove.Add_Click({
    $sel = @($script:CleanupUi.GhostChecks | Where-Object { $_.IsChecked })
    if (-not $sel.Count) { [System.Windows.MessageBox]::Show('Tick the devices to remove first.','Ghost devices','OK','Information') | Out-Null; return }
    if ([System.Windows.MessageBox]::Show(("Remove {0} disconnected device(s) from Windows?`r`n`r`nA restore point is created first. Each device is set up again automatically if you plug it in later." -f $sel.Count),'Ghost devices','OKCancel','Question') -ne 'OK') { return }
    New-RestorePoint 'Rion Tool ghost device cleanup' | Out-Null
    [void](Remove-GhostDevices -InstanceIds @($sel | ForEach-Object { [string]$_.Tag }))
    foreach ($cb in $sel) { $ghostList.Children.Remove($cb) }
    $script:CleanupUi.GhostChecks = @($script:CleanupUi.GhostChecks | Where-Object { -not $_.IsChecked })
})

function Export-RionSelection {
    param([string]$Path)
    if (-not $Path) {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Rion Tool selection (*.json)|*.json'; $dlg.FileName = ('RionTool-selection-{0}.json' -f (Get-Date -Format 'yyyyMMdd'))
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $Path = $dlg.FileName
    }
    $ticked = @(); $choices = [ordered]@{}
    foreach ($id in @($script:Rows.Keys | Sort-Object)) {
        $e = $script:Rows[$id]
        if ($e.Check -and $e.Check.IsChecked) { $ticked += $id }
        elseif ($e.Combo -and $e.Combo.SelectedIndex -gt 0) { $choices[$id] = [string]$e.Combo.SelectedItem }
    }
    [ordered]@{ Tool='Rion Tool'; Build=$script:Build; Saved=(Get-Date).ToString('s'); Ticked=$ticked; Choices=$choices } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Log ('Saved {0} ticked setting(s) and {1} dropdown choice(s) to {2}' -f $ticked.Count,$choices.Count,$Path) 'Success'
}
function Import-RionSelection {
    param([string]$Path,[switch]$Quiet)
    if (-not $script:Ready) { [System.Windows.MessageBox]::Show('Rion Tool is still reading your current settings. Try again in a moment.','Load selection','OK','Information') | Out-Null; return }
    if (-not $Path) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Rion Tool selection (*.json)|*.json'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $Path = $dlg.FileName
    }
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([string]$data.Tool -ne 'Rion Tool') { throw 'This file is not a Rion Tool selection.' }
    $ticked = 0; $picked = 0; $skipped = @()
    foreach ($id in @($data.Ticked)) {
        $e = $script:Rows[[string]$id]
        if ($e -and $e.Check -and $e.Check.IsEnabled) { $e.Check.IsChecked = $true; $ticked++ } else { $skipped += [string]$id }
    }
    if ($data.Choices) {
        foreach ($p in $data.Choices.PSObject.Properties) {
            $e = $script:Rows[$p.Name]
            if ($e -and $e.Combo -and $e.Combo.IsEnabled -and $e.Combo.Items.Contains([string]$p.Value)) { $e.Combo.SelectedItem = [string]$p.Value; $e.Touched = $true; $picked++ } else { $skipped += $p.Name }
        }
    }
    Write-Log ('Loaded {0}: ticked {1} setting(s) and set {2} dropdown(s). Not available on this PC: {3}' -f (Split-Path $Path -Leaf),$ticked,$picked,$(if ($skipped.Count) { $skipped -join ', ' } else { 'none' })) 'Success'
    if (-not $Quiet) { [System.Windows.MessageBox]::Show(('Ticked {0} setting(s) and set {1} dropdown(s){2}.' -f $ticked,$picked,$(if ($skipped.Count) { (', {0} not available on this PC' -f $skipped.Count) } else { '' })) + "`r`n`r`nReview the pages, then click Apply.",'Load selection','OK','Information') | Out-Null }
}
function Invoke-OneClickOptimize {
    param([string]$Mode = 'Recommended')
    if (-not $script:Ready) { [System.Windows.MessageBox]::Show('Rion Tool is still reading your current settings. Try again in a moment.','One-click optimize','OK','Information') | Out-Null; return }
    $placebo = @(Get-PlaceboFindings)
    $junkIds = @($script:CleanupCategories | Where-Object { $_.Default } | ForEach-Object { $_.Id })
    $junk = 0; foreach ($cat in @($script:CleanupCategories | Where-Object { $_.Default -and -not $_.Special })) { try { $junk += Measure-CleanupCategory $cat } catch { } }
    $what = if ($Mode -eq 'Gamer max') { 'every Safe and Moderate performance, latency, privacy and debloat tweak ticked on every page (Gamer max). Left out: Risky rows, Defender, Windows Update, Xbox, Bluetooth, Wi-Fi and Ethernet, VBS and anti-cheat settings, and "disable all startup apps"' } else { 'the Recommended tweaks ticked on every page' }
    $msg = "One-click optimize will:`r`n`r`n1. Open the review list with " + $what + ". Nothing changes until you confirm there.`r`n2. Reset {0} placebo value(s) to the Windows defaults.`r`n3. Clean {1} of junk files (temp files, update caches, error reports, driver installer leftovers, old logs).`r`n`r`nContinue?" -f $placebo.Count,(Format-Bytes $junk)
    if ([System.Windows.MessageBox]::Show($msg,'One-click optimize','OKCancel','Question') -ne 'OK') { return }
    $PresetAllPages.IsChecked = $true
    $script:AllPagesPreset = $null
    $PresetCombo.SelectedIndex = -1
    $PresetCombo.SelectedItem = $Mode
    $curTab = if ($Tabs.SelectedItem.Tag -is [string]) { [string]$Tabs.SelectedItem.Tag } else { [string]$Tabs.SelectedItem.Header }
    if ($curTab -eq 'Games') { Select-RionTab 'Home' }
    $script:LastApplyOutcome = 'cancelled'
    $ApplyBtn.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    if ($script:LastApplyOutcome -eq 'cancelled') { Write-Log 'One-click optimize was cancelled; no placebo values were reset and no files were cleaned.' 'Info'; return }
    $cleared = 0; if ($placebo.Count) { $cleared = Clear-PlaceboTweaks -Quiet -Items $placebo }
    $r = Invoke-SelectedCleanup -Ids $junkIds -Quiet
    try { Update-HomeHealth } catch { }
    [System.Windows.MessageBox]::Show(("One-click optimize finished.`r`n`r`nPlacebo values reset: {0}`r`nJunk files cleaned: {1}`r`n`r`nRestart Windows to finish." -f $cleared,$(if ($r) { Format-Bytes $r.Total } else { '0 B' })),'One-click optimize','OK','Information') | Out-Null
}

$script:HomeUi = @{}
$homeRoot = New-Object Windows.Controls.StackPanel; $homeRoot.Margin='4'
$scoreBorder = New-Object Windows.Controls.Border; Set-ThemeBrush $scoreBorder 'Background' 'Panel'; Set-ThemeBrush $scoreBorder 'BorderBrush' 'Border'; $scoreBorder.BorderThickness='1'; $scoreBorder.CornerRadius='4'; $scoreBorder.Padding='14'; $scoreBorder.Margin='6'
$scoreStack = New-Object Windows.Controls.StackPanel
$script:HomeUi.Score = New-Object Windows.Controls.TextBlock; $script:HomeUi.Score.FontSize=28; $script:HomeUi.Score.FontWeight='SemiBold'; $script:HomeUi.Score.Text='PC health: checking...'; Set-ThemeBrush $script:HomeUi.Score 'Foreground' 'Text'
$script:HomeUi.Sub = New-HintText 'The system analysis runs after Rion Tool has read your settings.'
$script:HomeUi.Cats = New-Object Windows.Controls.WrapPanel; $script:HomeUi.Cats.Margin='0,6,0,6'
$homeBtns = New-Object Windows.Controls.WrapPanel
$btnHomeRecheck = New-Object Windows.Controls.Button; $btnHomeRecheck.Content='Run the analysis again'; $btnHomeRecheck.Margin='0,4,8,0'
$btnHomeOptimize = New-Object Windows.Controls.Button; $btnHomeOptimize.Content='One-click optimize'; $btnHomeOptimize.Margin='0,4,8,0'; $btnHomeOptimize.ToolTip='Applies the Recommended tweaks (you review the list first), resets placebo tweaks and cleans junk files.'
$btnHomeRestore = New-Object Windows.Controls.Button; $btnHomeRestore.Content='Create a restore point'; $btnHomeRestore.Margin='0,4,8,0'
$btnHomePlacebo = New-Object Windows.Controls.Button; $btnHomePlacebo.Content='Clear all placebo tweaks'; $btnHomePlacebo.Margin='0,4,8,0'; $btnHomePlacebo.ToolTip='Finds old tweak-guide values from any tool (BCD timers, MMCSS, priorities, memory and network myths) and puts them back to the Windows defaults after you review the list.'
$btnHomePlacebo.Add_Click({ Clear-PlaceboTweaks })
foreach ($b in @($btnHomeRecheck,$btnHomeOptimize,$btnHomePlacebo,$btnHomeRestore)) { $b.IsEnabled = $false; [void]$homeBtns.Children.Add($b) }
foreach ($x in @($script:HomeUi.Score,$script:HomeUi.Sub,$script:HomeUi.Cats,$homeBtns)) { [void]$scoreStack.Children.Add($x) }
$scoreBorder.Child = $scoreStack
[void]$homeRoot.Children.Add($scoreBorder)
$script:HomeUi.Findings = New-Object Windows.Controls.StackPanel
$findBox = New-SectionBox -Title 'Findings and recommendations' -Children @($script:HomeUi.Findings)
[void]$homeRoot.Children.Add($findBox)
$script:BuildingTab = 'Home'
$autoRows = @(
    (New-ActionRow -Label 'Create a desktop shortcut (opens as administrator)' -Info 'Adds "Rion Tool" to your desktop. It starts this copy of the script with PowerShell and asks for administrator rights.' -Act { New-RionShortcut }),
    (New-ActionRow -Label 'Open Autoruns (everything that starts with Windows)' -Info 'Starts Microsoft Sysinternals Autoruns from the Rion Tool folder after checking that it is signed by Microsoft. It lists every startup entry, service, driver, scheduled task and shell extension so you can find what runs at boot. If it is not in the folder, the official download page opens.' -Act { Start-RionAutoruns }),
    (New-ActionRow -Label 'Save my selection to a file' -Info 'Saves every ticked setting and every dropdown choice on all pages to a .json file. Load it on another PC to set it up the same way.' -Act { Export-RionSelection }),
    (New-ActionRow -Label 'Load a selection file' -Info 'Ticks the settings and picks the dropdown values saved in a selection file. Settings that are not in the file are left as they are, and nothing changes until you click Apply.' -Act { Import-RionSelection }),
    (New-HintText 'Command line: RionTool.ps1 -Cleanup runs the recommended cleanup without opening the window (for your own scripts or shortcuts).')
)
$autoBox = New-SectionBox -Title 'Shortcuts and automation' -Children $autoRows
[void]$homeRoot.Children.Add($autoBox)
$homeScroll = New-Object Windows.Controls.ScrollViewer; $homeScroll.VerticalScrollBarVisibility='Auto'; $homeScroll.Content=$homeRoot
$script:HomeUi.Tab = Add-Tab 'Home' $homeScroll

function Update-HomeHealth {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try { $h = Invoke-HealthCheck } finally { $script:Window.Cursor = $null }
    $brush = if ($h.Score -ge 90) { 'Safe' } elseif ($h.Score -ge 60) { 'Moderate' } else { 'Risky' }
    $script:HomeUi.Score.Text = ('PC health: {0}/100  -  {1}' -f $h.Score,$h.Grade)
    Set-ThemeBrush $script:HomeUi.Score 'Foreground' $brush
    $bad = @($h.Findings | Where-Object Severity -eq 'bad').Count; $warn = @($h.Findings | Where-Object Severity -eq 'warn').Count
    $script:HomeUi.Sub.Text = ('Checked {0}. {1} problem(s), {2} warning(s), {3} note(s). Problems cost their full weight, warnings half, notes nothing.' -f $h.At.ToString('HH:mm'),$bad,$warn,(@($h.Findings).Count - $bad - $warn))
    $HealthBtn.Content = ('PC health: {0}/100' -f $h.Score); Set-ThemeBrush $HealthBtn 'Foreground' $brush
    $script:HomeUi.Cats.Children.Clear()
    foreach ($c in $h.Categories.Keys) {
        $card = New-Object Windows.Controls.Border; Set-ThemeBrush $card 'BorderBrush' 'Border'; $card.BorderThickness='1'; $card.CornerRadius='3'; $card.Padding='8,4'; $card.Margin='0,0,8,6'; $card.ToolTip=$script:HealthCategories[$c]
        $v = $h.Categories[$c]
        $t = New-Object Windows.Controls.TextBlock; $t.Text=('{0}: {1}' -f $c,$v); Set-ThemeBrush $t 'Foreground' $(if ($v -ge 90) { 'Safe' } elseif ($v -ge 60) { 'Moderate' } else { 'Risky' })
        $card.Child = $t; [void]$script:HomeUi.Cats.Children.Add($card)
    }
    $script:HomeUi.Findings.Children.Clear()
    if (-not @($h.Findings).Count) { [void]$script:HomeUi.Findings.Children.Add((New-HintText 'No problems found.' 'Safe')) }
    foreach ($f in $h.Findings) {
        $g = New-Object Windows.Controls.Grid; $g.Margin='0,4,0,6'
        foreach ($w in 'Auto','*','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }
        $sev = New-Object Windows.Controls.TextBlock; $sev.Width=74; $sev.FontWeight='SemiBold'; $sev.VerticalAlignment='Top'
        $sev.Text = switch ($f.Severity) { 'bad' { 'Problem' } 'warn' { 'Warning' } default { 'Note' } }
        Set-ThemeBrush $sev 'Foreground' $(switch ($f.Severity) { 'bad' { 'Risky' } 'warn' { 'Moderate' } default { 'SubText' } })
        $txt = New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($txt,1)
        $tt = New-Object Windows.Controls.TextBlock; $tt.Text=('{0}  ({1})' -f $f.Title,(Get-HealthGroup $f.Category)); $tt.FontWeight='SemiBold'; $tt.TextWrapping='Wrap'; Set-ThemeBrush $tt 'Foreground' 'Text'
        [void]$txt.Children.Add($tt); [void]$txt.Children.Add((New-HintText $f.Detail))
        [void]$g.Children.Add($sev); [void]$g.Children.Add($txt)
        if ($f.Fix) {
            $fb = New-Object Windows.Controls.Button; $fb.Content=$f.FixLabel; $fb.Margin='10,0,0,0'; $fb.VerticalAlignment='Top'; $fb.Tag=$f.Fix
            $fb.Add_Click({ param($s,$e) try { Write-Log ("Fixing: {0}" -f $s.Content) 'Action'; & $s.Tag } catch { Write-Log ("Fix failed: {0}" -f $_.Exception.Message) 'Error' } })
            [Windows.Controls.Grid]::SetColumn($fb,2); [void]$g.Children.Add($fb)
        }
        [void]$script:HomeUi.Findings.Children.Add($g)
    }
}
$btnHomeRecheck.Add_Click({ Update-HomeHealth })
$btnHomeOptimize.Add_Click({ Invoke-OneClickOptimize })
$btnHomeRestore.Add_Click({ New-RestorePoint | Out-Null })
$HealthBtn.Add_Click({ Select-RionTab 'Home' })

$script:PowerUi = @{ Loaded=$false; Rows=@(); Sections=@{}; Plans=@(); Plan=$null; Syncing=$false; OrigName=''; OrigDesc='' }

function New-PowerText {
    param([string]$Text,[string]$Brush = 'SubText',[double]$Size = 12)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.VerticalAlignment = 'Center'
    Set-ThemeBrush $t 'Foreground' $Brush
    return $t
}

function New-PowerButton {
    param([string]$Text,[string]$Tip)
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text; $b.Margin = '0,0,6,6'
    if ($Tip) { $tt = New-Object Windows.Controls.TextBlock; $tt.Text = $Tip; $tt.TextWrapping = 'Wrap'; $tt.MaxWidth = 340; $b.ToolTip = $tt }
    return $b
}

function Format-PowerValue {
    param($Def,[long]$Value)
    if ($Value -lt 0) { return 'n/a' }
    if (@($Def.Options).Count) { if ($Value -lt @($Def.Options).Count) { return [string]$Def.Options[$Value] }; return ("Value {0}" -f $Value) }
    if ($Def.Units) { return ("{0} {1}" -f $Value,$Def.Units) }
    return [string]$Value
}

function New-PowerValueControl {
    param($Def)
    if (@($Def.Options).Count) {
        $c = New-Object Windows.Controls.ComboBox
        $c.Width = 180; $c.Margin = '8,0,0,0'; $c.VerticalAlignment = 'Top'
        foreach ($o in $Def.Options) { [void]$c.Items.Add([string]$o) }
        $c.Add_SelectionChanged({ param($s,$e) Update-PowerRowState $s.Tag })
        return $c
    }
    $tb = New-Object Windows.Controls.TextBox
    $tb.Width = 180; $tb.Margin = '8,0,0,0'; $tb.VerticalAlignment = 'Top'
    if ($null -ne $Def.Min) { $tb.ToolTip = ("{0} to {1} {2}, step {3}" -f $Def.Min,$Def.Max,$Def.Units,$Def.Increment).Replace('  ',' ') }
    $tb.Add_TextChanged({ param($s,$e) Update-PowerRowState $s.Tag })
    return $tb
}

function Set-PowerControlValue {
    param($Control,$Def,[long]$Value)
    if ($Control -is [Windows.Controls.ComboBox]) {
        while ($Control.Items.Count -gt @($Def.Options).Count) { $Control.Items.RemoveAt($Control.Items.Count - 1) }
        if ($Value -ge 0 -and $Value -lt $Control.Items.Count) { $Control.SelectedIndex = [int]$Value }
        elseif ($Value -ge 0) { [void]$Control.Items.Add(("Value {0}" -f $Value)); $Control.SelectedIndex = $Control.Items.Count - 1 }
        else { $Control.SelectedIndex = -1 }
    } else {
        $Control.Text = if ($Value -ge 0) { [string]$Value } else { '' }
    }
}

function Get-PowerControlValue {
    param($Control,$Def)
    if ($Control -is [Windows.Controls.ComboBox]) {
        $i = $Control.SelectedIndex
        if ($i -lt 0) { return -1 }
        if ($i -lt @($Def.Options).Count) { return [long]$i }
        $m = [regex]::Match([string]$Control.SelectedItem,'\d+')
        if ($m.Success) { return [long]$m.Value }
        return -1
    }
    $t = ([string]$Control.Text).Trim()
    if ($t -eq '') { return -1 }
    if ($t -match '^0x[0-9a-fA-F]{1,8}$') { return [Convert]::ToInt64($t.Substring(2),16) }
    $v = 0L
    if ([long]::TryParse($t,[ref]$v) -and $v -ge 0 -and $v -le 4294967295) { return $v }
    return -2
}

function Test-PowerValueValid {
    param($Def,[long]$Value)
    if ($Value -eq -1) { return $true }
    if ($Value -lt 0) { return $false }
    if ($null -ne $Def.Min -and ($Value -lt $Def.Min -or $Value -gt $Def.Max)) { return $false }
    return $true
}

function Update-PowerPendingText {
    if (-not $script:PowerUi.Pending) { return }
    $edited = @($script:PowerUi.Rows | Where-Object { $_.Edited }).Count
    $textChanged = ([string]$script:PowerUi.NameBox.Text -cne $script:PowerUi.OrigName -or [string]$script:PowerUi.DescBox.Text -cne $script:PowerUi.OrigDesc)
    $parts = @()
    if ($edited) { $parts += ("{0} setting(s) edited" -f $edited) }
    if ($textChanged) { $parts += 'name or description edited' }
    $script:PowerUi.Pending.Text = if ($parts.Count) { ($parts -join ', ') + ' - not saved yet' } else { 'No unsaved edits' }
    Set-ThemeBrush $script:PowerUi.Pending 'Foreground' $(if ($parts.Count) { 'Accent' } else { 'SubText' })
    $plan = $script:PowerUi.Plan
    $script:PowerUi.UndoBtn.IsEnabled = [bool](@($script:PowerJournal.Keys | Where-Object { $_ -like "value|$plan|*" -or ($_ -eq "text|$plan" -and $script:PowerJournal[$_].name) }).Count)
    $script:PowerUi.UnhideBtn.Content = if (@($script:PowerJournal.Keys | Where-Object { $_ -like 'attr|*' }).Count) { 'Hide them again in Control Panel' } else { 'Show hidden settings in Control Panel' }
}

function Update-PowerRowState {
    param($Row)
    if (-not $Row -or $script:PowerUi.Syncing) { return }
    $d = $Row.Def
    $a = Get-PowerControlValue $Row.Ac $d
    $c = Get-PowerControlValue $Row.Dc $d
    $parts = @()
    $brush = 'SubText'
    $Row.Invalid = -not ((Test-PowerValueValid $d $a) -and (Test-PowerValueValid $d $c))
    $Row.Edited = (-not $Row.Invalid) -and ($a -ne $Row.OrigAc -or $c -ne $Row.OrigDc)
    $Row.Modified = [bool]($Row.Default -and (($Row.OrigAc -ge 0 -and $Row.OrigAc -ne $Row.Default[0]) -or ($Row.OrigDc -ge 0 -and $Row.OrigDc -ne $Row.Default[1])))
    if ($Row.Invalid) {
        $parts += $(if ($null -ne $d.Min) { "Enter a whole number from {0} to {1}" -f $d.Min,$d.Max } else { 'Enter a whole number' })
        $brush = 'Risky'
    } elseif ($Row.Edited) {
        $parts += ("Pending: plugged in {0}, on battery {1}" -f (Format-PowerValue $d $a),(Format-PowerValue $d $c))
        $brush = 'Accent'
    }
    if ($Row.Modified) {
        $parts += ("Changed from default (default: {0} / {1})" -f (Format-PowerValue $d $Row.Default[0]),(Format-PowerValue $d $Row.Default[1]))
        if ($brush -eq 'SubText') { $brush = 'Moderate' }
    }
    if ($Row.NotSet) { $parts += $(if ($Row.Default) { 'Not stored in this plan; Windows default shown' } else { 'Not stored in this plan and no Windows default; enter a value to set it' }) }
    if ($d.Hidden) { $parts += 'Hidden by Windows' }
    elseif ($script:PowerJournal.ContainsKey("attr|$($d.Sub)|$($d.Guid)") -or $script:PowerJournal.ContainsKey("attr|$($d.Sub)|")) { $parts += 'Unhidden by Rion Tool' }
    $Row.State.Text = $parts -join '   '
    Set-ThemeBrush $Row.State 'Foreground' $brush
    $Row.State.Visibility = if ($parts.Count) { 'Visible' } else { 'Collapsed' }
    Update-PowerPendingText
}

function New-PowerSettingRow {
    param($Def)
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '0,4,0,4'
    foreach ($w in '*','Auto','Auto','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$grid.ColumnDefinitions.Add($cd) }
    $stack = New-Object Windows.Controls.StackPanel
    $name = New-PowerText $Def.Name 'Text' 13
    $name.TextWrapping = 'Wrap'
    [void]$stack.Children.Add($name)
    $state = New-PowerText '' 'SubText' 11
    $state.TextWrapping = 'Wrap'; $state.Margin = '0,1,0,0'; $state.Visibility = 'Collapsed'
    [void]$stack.Children.Add($state)
    [Windows.Controls.Grid]::SetColumn($stack,0); [void]$grid.Children.Add($stack)
    $ac = New-PowerValueControl $Def
    $dc = New-PowerValueControl $Def
    [Windows.Controls.Grid]::SetColumn($ac,1); [void]$grid.Children.Add($ac)
    [Windows.Controls.Grid]::SetColumn($dc,2); [void]$grid.Children.Add($dc)
    $lines = @()
    if ($Def.Description) { $lines += $Def.Description }
    if ($null -ne $Def.Min) { $lines += ("Range: {0} to {1} {2} (step {3})" -f $Def.Min,$Def.Max,$Def.Units,$Def.Increment) }
    if ($Def.Hidden) { $lines += 'Windows hides this setting from Control Panel. It still applies when changed here.' }
    $lines += ("Subgroup: {0} ({1})" -f $Def.SubName,$Def.Sub)
    $lines += ("Setting GUID: {0}" -f $Def.Guid)
    $info = New-InfoIcon ($lines -join "`r`n")
    $info.VerticalAlignment = 'Top'; $info.Margin = '8,3,0,0'
    [Windows.Controls.Grid]::SetColumn($info,3); [void]$grid.Children.Add($info)
    $row = @{ Def=$Def; Grid=$grid; Ac=$ac; Dc=$dc; State=$state; OrigAc=-1; OrigDc=-1; Default=$null; Edited=$false; Modified=$false; Invalid=$false; NotSet=$false }
    $ac.Tag = $row; $dc.Tag = $row
    return $row
}

function New-PowerColumnHeader {
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '0,0,0,2'
    foreach ($w in '*','Auto','Auto','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$grid.ColumnDefinitions.Add($cd) }
    $i = 1
    foreach ($label in 'Plugged in','On battery') {
        $t = New-PowerText $label 'SubText' 11
        $t.Width = 180; $t.Margin = '8,0,0,0'
        [Windows.Controls.Grid]::SetColumn($t,$i); [void]$grid.Children.Add($t); $i++
    }
    $pad = New-Object Windows.Controls.Border; $pad.Width = 26
    [Windows.Controls.Grid]::SetColumn($pad,3); [void]$grid.Children.Add($pad)
    return $grid
}

function Build-PowerRows {
    $list = $script:PowerUi.List
    $list.Children.Clear()
    $script:PowerUi.Rows = @()
    $script:PowerUi.Sections = @{}
    $catalog = @(Get-PowerSettingCatalog)
    foreach ($g in @($catalog | Group-Object SubName)) {
        $rows = @($g.Group | Sort-Object Name | ForEach-Object { New-PowerSettingRow $_ })
        $script:PowerUi.Rows += $rows
        $children = @(New-PowerColumnHeader) + @($rows | ForEach-Object { $_.Grid })
        $subHidden = [bool]($g.Group[0].SubAttributes -band 1)
        $extra = if ($subHidden) { $x = New-PowerText 'hidden subgroup' 'Muted' 11; $x.Margin = '8,0,0,0'; $x } else { $null }
        $box = New-SectionBox -Title $g.Name -Children $children -HeaderExtra $extra
        $script:PowerUi.Sections[$g.Name] = @{ Box=$box; Rows=$rows }
        [void]$list.Children.Add($box)
    }
}

function Update-PowerFilter {
    $q = ([string]$script:PowerUi.Search.Text).Trim()
    $showHidden = [bool]$script:PowerUi.ShowHidden.IsChecked
    $onlyChanged = [bool]$script:PowerUi.OnlyChanged.IsChecked
    $shown = 0
    foreach ($sec in $script:PowerUi.Sections.Values) {
        $count = 0
        foreach ($row in $sec.Rows) {
            $d = $row.Def
            $vis = ($showHidden -or -not $d.Hidden) -and (-not $onlyChanged -or $row.Modified -or $row.Edited) -and (-not $q -or $d.Name -like "*$q*" -or $d.SubName -like "*$q*" -or $d.Guid -like "*$q*" -or $d.Description -like "*$q*")
            $row.Grid.Visibility = if ($vis) { 'Visible' } else { 'Collapsed' }
            if ($vis) { $count++ }
        }
        $sec.Box.Visibility = if ($count) { 'Visible' } else { 'Collapsed' }
        $shown += $count
    }
    $all = @($script:PowerUi.Rows)
    $script:PowerUi.Summary.Text = ("{0} of {1} settings shown. {2} hidden by Windows, {3} changed from this plan's defaults." -f $shown,$all.Count,@($all | Where-Object { $_.Def.Hidden }).Count,@($all | Where-Object { $_.Modified }).Count)
}

function Update-PowerValues {
    $plan = $script:PowerUi.Plan
    if (-not $plan) { return }
    $base = Get-PowerPlanBase $plan
    $script:PowerUi.Syncing = $true
    try {
        foreach ($row in $script:PowerUi.Rows) {
            $v = [RionPowrProf]::Values($plan,$row.Def.Sub,$row.Def.Guid)
            $row.Default = Get-PowerSettingDefault -Base $base -Sub $row.Def.Sub -Setting $row.Def.Guid
            $row.NotSet = ($v[0] -lt 0 -and $v[1] -lt 0)
            if ($row.NotSet -and $row.Default) { $v = @($row.Default[0],$row.Default[1]) }
            $row.OrigAc = $v[0]; $row.OrigDc = $v[1]
            Set-PowerControlValue $row.Ac $row.Def $v[0]
            Set-PowerControlValue $row.Dc $row.Def $v[1]
        }
    } finally { $script:PowerUi.Syncing = $false }
    foreach ($row in $script:PowerUi.Rows) { Update-PowerRowState $row }
    $baseName = [string]@($script:PowerTemplates.Keys | Where-Object { $script:PowerTemplates[$_] -eq $base })[0]
    $known = @($script:PowerUi.Rows | Where-Object { $_.Default }).Count
    $script:PowerUi.BaseText.Text = if ($known) { "Defaults compared against Windows' {0} template ({1} settings have a stored default; CPU vendor processor profiles can also adjust processor values)." -f $baseName,$known } else { "Windows stores no defaults for the {0} template, so changed-from-default markers are not shown for this plan." -f $baseName }
    Update-PowerFilter
    Update-PowerPendingText
}

function Select-PowerPlan {
    param([string]$Guid)
    $script:PowerUi.Plan = $Guid
    $p = @($script:PowerUi.Plans | Where-Object { $_.Guid -eq $Guid } | Select-Object -First 1)
    if (-not $p) { return }
    $p = $p[0]
    $script:PowerUi.Syncing = $true
    try {
        $script:PowerUi.NameBox.Text = [string]$p.Name
        $script:PowerUi.DescBox.Text = [string]$p.Description
        $script:PowerUi.OrigName = [string]$p.Name
        $script:PowerUi.OrigDesc = [string]$p.Description
    } finally { $script:PowerUi.Syncing = $false }
    $script:PowerUi.ActiveText.Text = if ($p.Active) { 'This plan is active.' } else { 'This plan is not active. Edits are saved to it, but Windows uses them only after you switch to it.' }
    $script:PowerUi.ActivateBtn.IsEnabled = -not $p.Active
    $script:PowerUi.DeleteBtn.IsEnabled = (-not $p.Active) -and ($Guid -ne $script:PowerTemplates['Balanced'])
    $script:PowerUi.GuidText.Text = $Guid
    Update-PowerValues
}

function Update-PowerPlanList {
    param([string]$Select)
    $plans = @(Get-PowerPlans)
    $script:PowerUi.Plans = $plans
    if (-not $plans.Count) { return }
    $want = if ($Select) { $Select } elseif ($script:PowerUi.Plan) { $script:PowerUi.Plan } else { [string](@($plans | Where-Object { $_.Active })[0].Guid) }
    $idx = 0
    for ($i = 0; $i -lt $plans.Count; $i++) { if ($plans[$i].Guid -eq $want) { $idx = $i } }
    $script:PowerUi.Syncing = $true
    try {
        $cb = $script:PowerUi.PlanCombo
        $cb.Items.Clear()
        foreach ($p in $plans) { [void]$cb.Items.Add($(if ($p.Active) { "{0}  (active)" -f $p.Name } else { [string]$p.Name })) }
        $cb.SelectedIndex = $idx
        $overlay = [RionPowrProf]::Overlay()
        $modeName = @($script:PowerModes.Keys | Where-Object { $script:PowerModes[$_] -eq $overlay })
        $script:PowerUi.ModeCombo.SelectedIndex = if ($modeName.Count) { @($script:PowerModes.Keys).IndexOf($modeName[0]) } else { -1 }
        $script:PowerUi.ModeCombo.IsEnabled = ([RionPowrProf]::ActiveScheme() -eq $script:PowerTemplates['Balanced'])
    } finally { $script:PowerUi.Syncing = $false }
    Select-PowerPlan $plans[$idx].Guid
}

function Test-PowerUnsaved {
    $edited = @($script:PowerUi.Rows | Where-Object { $_.Edited }).Count
    $textChanged = ([string]$script:PowerUi.NameBox.Text -cne $script:PowerUi.OrigName -or [string]$script:PowerUi.DescBox.Text -cne $script:PowerUi.OrigDesc)
    if (-not $edited -and -not $textChanged) { return $false }
    $r = [System.Windows.MessageBox]::Show('This plan has edits that are not saved yet. Discard them?','Power plan','OKCancel','Warning')
    return ($r -ne 'OK')
}

function Export-PowerPlanBackup {
    param([string]$Plan)
    $file = Join-Path $script:BackupDir ("powerplan-{0}-{1}.pow" -f $Plan,(Get-Date -Format 'yyyyMMdd-HHmmss'))
    $r = Invoke-PowerCfg @('-export',$file,$Plan)
    if ($r.ExitCode -eq 0) { return $file }
    Write-Log ("Could not back up the power plan before changing it: {0}" -f $r.Error) 'Warn'
    return $null
}

function Invoke-PowerApply {
    $plan = $script:PowerUi.Plan
    if (-not $plan) { return }
    $invalid = @($script:PowerUi.Rows | Where-Object { $_.Invalid })
    if ($invalid.Count) { [System.Windows.MessageBox]::Show(("Fix the values marked in red first:`r`n{0}" -f (($invalid | Select-Object -First 8 | ForEach-Object { $_.Def.Name }) -join "`r`n")),'Power plan','OK','Warning') | Out-Null; return }
    $edited = @($script:PowerUi.Rows | Where-Object { $_.Edited })
    $newName = ([string]$script:PowerUi.NameBox.Text).Trim()
    $newDesc = ([string]$script:PowerUi.DescBox.Text).Trim()
    $textChanged = ($newName -cne $script:PowerUi.OrigName -or $newDesc -cne $script:PowerUi.OrigDesc)
    if (-not $edited.Count -and -not $textChanged) { Write-Log 'No power plan edits to save.' 'Info'; return }
    if (-not $newName) { [System.Windows.MessageBox]::Show('The plan name cannot be empty.','Power plan','OK','Warning') | Out-Null; return }
    $backup = Export-PowerPlanBackup $plan
    if ($backup) { Write-Log ("Backed up the plan to {0}" -f $backup) 'Info' }
    $fail = 0; $ok = 0
    if ($textChanged) {
        try { Set-PowerPlanText -Guid $plan -Name $newName -Description $newDesc; Write-Log ("Plan renamed to '{0}'." -f $newName) 'Success' }
        catch { Write-Log ("Rename failed: {0}" -f $_.Exception.Message) 'Error'; $fail++ }
    }
    foreach ($row in $edited) {
        $err = Set-PowerSettingValue -Plan $plan -Sub $row.Def.Sub -Setting $row.Def.Guid -Ac (Get-PowerControlValue $row.Ac $row.Def) -Dc (Get-PowerControlValue $row.Dc $row.Def)
        if ($err) { Write-Log ("{0}: {1}" -f $row.Def.Name,$err) 'Error'; $fail++ } else { $ok++ }
    }
    Save-PowerJournal
    Update-ActivePowerPlan $plan
    Write-Log ("Power plan saved: {0} setting(s) changed, {1} failed. Undo with 'Undo Rion Tool changes to this plan'." -f $ok,$fail) $(if ($fail) { 'Warn' } else { 'Success' })
    Update-PowerPlanList -Select $plan
}

function Invoke-PowerAction {
    param([string]$Name,[scriptblock]$Body)
    try { & $Body } catch { Write-Log ("{0} failed: {1}" -f $Name,$_.Exception.Message) 'Error' }
}

function Open-PowerTab {
    if (-not (Initialize-PowerApi)) { return }
    if (-not $script:PowerUi.Loaded) {
        Write-Log 'Reading every power setting, including hidden ones...' 'Action'
        Read-PowerJournal
        Build-PowerRows
        $script:PowerUi.Loaded = $true
        Update-PowerPlanList
        Write-Log ("Power plan tab ready: {0} settings across {1} plans." -f @($script:PowerUi.Rows).Count,@($script:PowerUi.Plans).Count) 'Success'
        return
    }
    $edited = @($script:PowerUi.Rows | Where-Object { $_.Edited }).Count
    if (-not $edited) { Update-PowerPlanList }
}

$powerRoot = New-Object Windows.Controls.DockPanel
$powerRoot.Margin = '10'
$powerTop = New-Object Windows.Controls.StackPanel
[Windows.Controls.DockPanel]::SetDock($powerTop,'Top')
$planBar = New-Object Windows.Controls.WrapPanel
$planBar.Margin = '6,0,6,0'
$planLabel = New-PowerText 'Plan' 'SubText' 12; $planLabel.Margin = '0,0,8,6'
$powerIntro = New-InfoIcon 'Every power setting Windows has, including hidden ones and settings that only exist in the registry, for any plan. Values are read live through the Windows power API (powrprof), the same way PowerSettingsExplorer reads them. Edits are saved only when you press Save changes, the plan is exported to the Rion Tool backups folder first, and every change can be undone with Undo or Fixes > full revert.'
$powerIntro.Margin = '0,0,8,6'
[void]$planBar.Children.Add($powerIntro)
$script:PowerUi.PlanCombo = New-Object Windows.Controls.ComboBox
$script:PowerUi.PlanCombo.Width = 260; $script:PowerUi.PlanCombo.Margin = '0,0,10,6'
$script:PowerUi.ActivateBtn = New-PowerButton 'Set active' 'Switches Windows to this plan (powercfg /setactive).'
$powerDupBtn = New-PowerButton 'Duplicate' 'Creates a copy of this plan with all of its current values (powercfg /duplicatescheme).'
$script:PowerUi.DeleteBtn = New-PowerButton 'Delete' 'Deletes this plan. The active plan and Balanced cannot be deleted. Export it first if you may want it back.'
$powerExportBtn = New-PowerButton 'Export...' 'Saves this plan to a .pow file you can import later or on another PC.'
$powerImportBtn = New-PowerButton 'Import...' 'Adds a plan from a .pow file as a new plan.'
$powerDefaultsBtn = New-PowerButton 'Restore default plans' 'Runs powercfg /restoredefaultschemes: deletes every custom plan (including Rion''s power plan) and resets Balanced, High performance and Power saver to Windows defaults.'
$powerRionBtn = New-PowerButton 'Install Rion''s power plan' 'Creates Rion''s power plan (a tuned copy of Ultimate Performance, or High performance where Ultimate is not available), names it "Rion''s power plan" and makes it active. On Ryzen X3D, Intel hybrid CPUs and laptops the Balanced plan with Power mode set to Best performance is usually the better choice.'
$modeLabel = New-PowerText 'Power mode' 'SubText' 12; $modeLabel.Margin = '8,0,8,6'
$script:PowerUi.ModeCombo = New-Object Windows.Controls.ComboBox
$script:PowerUi.ModeCombo.Width = 170; $script:PowerUi.ModeCombo.Margin = '0,0,6,6'
foreach ($m in $script:PowerModes.Keys) { [void]$script:PowerUi.ModeCombo.Items.Add($m) }
$script:PowerUi.ModeCombo.ToolTip = 'The Windows 11 Power mode slider (Settings > System > Power). It overlays the active plan and only takes effect while Balanced is the active plan. Best performance raises boost and responsiveness; Best power efficiency lowers them.'
foreach ($c in @($planLabel,$script:PowerUi.PlanCombo,$script:PowerUi.ActivateBtn,$powerDupBtn,$script:PowerUi.DeleteBtn,$powerExportBtn,$powerImportBtn,$powerRionBtn,$powerDefaultsBtn,$modeLabel,$script:PowerUi.ModeCombo)) { [void]$planBar.Children.Add($c) }
[void]$powerTop.Children.Add($planBar)

$planTextGrid = New-Object Windows.Controls.Grid
$planTextGrid.Margin = '6,2,6,4'
foreach ($w in 'Auto','2*','Auto','3*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$planTextGrid.ColumnDefinitions.Add($cd) }
$nameLabel = New-PowerText 'Name' 'SubText' 12; $nameLabel.Margin = '0,0,8,0'
$script:PowerUi.NameBox = New-Object Windows.Controls.TextBox; $script:PowerUi.NameBox.Margin = '0,0,12,0'; $script:PowerUi.NameBox.MaxLength = 120
$descLabel = New-PowerText 'Description' 'SubText' 12; $descLabel.Margin = '0,0,8,0'
$script:PowerUi.DescBox = New-Object Windows.Controls.TextBox; $script:PowerUi.DescBox.MaxLength = 500
$col = 0
foreach ($c in @($nameLabel,$script:PowerUi.NameBox,$descLabel,$script:PowerUi.DescBox)) { [Windows.Controls.Grid]::SetColumn($c,$col); [void]$planTextGrid.Children.Add($c); $col++ }
[void]$powerTop.Children.Add($planTextGrid)

$planMeta = New-Object Windows.Controls.WrapPanel
$planMeta.Margin = '6,2,6,6'
$script:PowerUi.ActiveText = New-PowerText '' 'SubText' 11; $script:PowerUi.ActiveText.Margin = '0,0,14,0'
$script:PowerUi.BaseText = New-PowerText '' 'SubText' 11; $script:PowerUi.BaseText.Margin = '0,0,14,0'
$script:PowerUi.GuidText = New-PowerText '' 'Muted' 11
foreach ($c in @($script:PowerUi.ActiveText,$script:PowerUi.BaseText,$script:PowerUi.GuidText)) { [void]$planMeta.Children.Add($c) }
[void]$powerTop.Children.Add($planMeta)

$filterBar = New-Object Windows.Controls.WrapPanel
$filterBar.Margin = '6,0,6,4'
$searchLabel = New-PowerText 'Search' 'SubText' 12; $searchLabel.Margin = '0,0,8,6'
$script:PowerUi.Search = New-Object Windows.Controls.TextBox; $script:PowerUi.Search.Width = 220; $script:PowerUi.Search.Margin = '0,0,14,6'
$script:PowerUi.ShowHidden = New-Object Windows.Controls.CheckBox; $script:PowerUi.ShowHidden.Content = 'Include hidden settings'; $script:PowerUi.ShowHidden.IsChecked = $true; $script:PowerUi.ShowHidden.Margin = '0,0,14,6'
$script:PowerUi.OnlyChanged = New-Object Windows.Controls.CheckBox; $script:PowerUi.OnlyChanged.Content = 'Only changed or edited'; $script:PowerUi.OnlyChanged.Margin = '0,0,14,6'
$script:PowerUi.UnhideBtn = New-PowerButton 'Show hidden settings in Control Panel' 'Sets the Windows attribute of every hidden setting and subgroup so it also appears in Control Panel > Power Options > Advanced settings. The original attributes are saved; press it again to hide them again.'
foreach ($c in @($searchLabel,$script:PowerUi.Search,$script:PowerUi.ShowHidden,$script:PowerUi.OnlyChanged,$script:PowerUi.UnhideBtn)) { [void]$filterBar.Children.Add($c) }
[void]$powerTop.Children.Add($filterBar)
$script:PowerUi.Summary = New-PowerText '' 'SubText' 11
$script:PowerUi.Summary.Margin = '6,0,6,4'
[void]$powerTop.Children.Add($script:PowerUi.Summary)
[void]$powerRoot.Children.Add($powerTop)

$powerBottom = New-Object Windows.Controls.DockPanel
$powerBottom.Margin = '6,8,6,0'
[Windows.Controls.DockPanel]::SetDock($powerBottom,'Bottom')
$powerBtns = New-Object Windows.Controls.StackPanel
$powerBtns.Orientation = 'Horizontal'
[Windows.Controls.DockPanel]::SetDock($powerBtns,'Right')
$powerResetBtn = New-PowerButton 'Reset plan to defaults' 'Sets every setting that differs from this plan''s Windows default back to the default. Saved through the undo journal, so Undo still works.'
$script:PowerUi.UndoBtn = New-PowerButton 'Undo Rion Tool changes to this plan' 'Restores every value, the name and the description this tool changed in this plan to what they were before.'
$powerDiscardBtn = New-PowerButton 'Discard edits' 'Reloads the saved values and drops unsaved edits.'
$powerSaveBtn = New-PowerButton 'Save changes' 'Writes the edited values, name and description to the plan and re-applies it if it is active.'
Set-ThemeBrush $powerSaveBtn 'Background' 'Accent'; Set-ThemeBrush $powerSaveBtn 'BorderBrush' 'Accent'; $powerSaveBtn.Foreground = 'White'
foreach ($c in @($powerResetBtn,$script:PowerUi.UndoBtn,$powerDiscardBtn,$powerSaveBtn)) { [void]$powerBtns.Children.Add($c) }
[void]$powerBottom.Children.Add($powerBtns)
$script:PowerUi.Pending = New-PowerText 'No unsaved edits' 'SubText' 12
[void]$powerBottom.Children.Add($script:PowerUi.Pending)
[void]$powerRoot.Children.Add($powerBottom)

$powerScroll = New-Object Windows.Controls.ScrollViewer
$powerScroll.VerticalScrollBarVisibility = 'Auto'
$script:PowerUi.List = New-Object Windows.Controls.StackPanel
$powerScroll.Content = $script:PowerUi.List
[void]$powerRoot.Children.Add($powerScroll)

$script:PowerUi.Tab = New-Object Windows.Controls.TabItem
$script:PowerUi.Tab.Header = 'Power plan'
$script:PowerUi.Tab.Content = $powerRoot
$cpuTabIndex = -1
for ($i = 0; $i -lt $Tabs.Items.Count; $i++) { if ([string]$Tabs.Items[$i].Header -eq 'CPU') { $cpuTabIndex = $i } }
if ($cpuTabIndex -ge 0) { $Tabs.Items.Insert($cpuTabIndex + 1,$script:PowerUi.Tab) } else { [void]$Tabs.Items.Add($script:PowerUi.Tab) }
$script:ValRoot = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
$script:FnRoot = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient'
$script:LayersKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
function Read-IniLines {
    param([string]$Path)
    $l = New-Object System.Collections.Generic.List[string]
    if ($Path -and (Test-Path -LiteralPath $Path)) { foreach ($x in [IO.File]::ReadAllLines($Path)) { $l.Add($x) } }
    return ,$l
}
function Get-IniFileMeta {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{ Existed=$false; NewLine="`r`n"; Final=$true; Encoding=(New-Object Text.UTF8Encoding $false); Text='' } }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc = New-Object Text.UTF8Encoding $false; $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object Text.UTF8Encoding $true; $skip = 3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = New-Object Text.UnicodeEncoding $false,$true; $skip = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = New-Object Text.UnicodeEncoding $true,$true; $skip = 2 }
    $text = $enc.GetString($bytes,$skip,$bytes.Length - $skip)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { "`r`n" }
    return @{ Existed=$true; NewLine=$nl; Final=($text.EndsWith("`n")); Encoding=$enc; Text=$text }
}
function Get-IniValue {
    param($Lines,[string]$Section,[string]$Key)
    $in = $false
    foreach ($x in $Lines) {
        $t = $x.Trim()
        if ($t.StartsWith('[')) { $in = ($t -eq ('[' + $Section + ']')); continue }
        if ($in -and $t.StartsWith($Key + '=',[StringComparison]::OrdinalIgnoreCase)) { return $t.Substring($Key.Length + 1) }
    }
    return $null
}
function Set-IniValue {
    param($Lines,[string]$Section,[string]$Key,[string]$Value)
    $start = -1; $end = $Lines.Count
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t.StartsWith('[')) { if ($start -ge 0) { $end = $i; break }; if ($t -eq ('[' + $Section + ']')) { $start = $i } }
    }
    if ($start -lt 0) { if ($Lines.Count -and $Lines[$Lines.Count - 1].Trim()) { $Lines.Add('') }; $Lines.Add('[' + $Section + ']'); $Lines.Add($Key + '=' + $Value); return }
    for ($i = $start + 1; $i -lt $end; $i++) { if ($Lines[$i].Trim().StartsWith($Key + '=',[StringComparison]::OrdinalIgnoreCase)) { $Lines[$i] = $Key + '=' + $Value; return } }
    $ins = $end; while ($ins -gt $start + 1 -and -not $Lines[$ins - 1].Trim()) { $ins-- }
    $Lines.Insert($ins,$Key + '=' + $Value)
}
function Test-ValueEqual {
    param($A,$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $x = 0.0; $y = 0.0
    $ci = [Globalization.CultureInfo]::InvariantCulture
    if ([double]::TryParse([string]$A,[Globalization.NumberStyles]::Float,$ci,[ref]$x) -and [double]::TryParse([string]$B,[Globalization.NumberStyles]::Float,$ci,[ref]$y)) { return ([math]::Abs($x - $y) -lt 0.001) }
    return ([string]$A -eq [string]$B)
}
function Get-LayerString { param([string]$Exe) if (-not $Exe) { return $null }; return [string](Get-ItemProperty -LiteralPath $script:LayersKey -Name $Exe -ErrorAction SilentlyContinue).$Exe }
function Set-LayerString {
    param([string]$Exe,[string]$Value)
    if (-not (Test-Path -LiteralPath $script:LayersKey)) { New-Item -Path $script:LayersKey -Force | Out-Null }
    if ($Value) { Set-ItemProperty -LiteralPath $script:LayersKey -Name $Exe -Value $Value -Type String } else { Remove-ItemProperty -LiteralPath $script:LayersKey -Name $Exe -ErrorAction SilentlyContinue }
}
function Set-LayerFlag {
    param([string]$Exe,[string]$Flag,[bool]$On)
    $flags = @(([string](Get-LayerString $Exe)) -split '\s+' | Where-Object { $_ -and $_ -ne '~' -and $_ -ne $Flag })
    if ($On) { $flags += $Flag }
    Set-LayerString $Exe $(if ($flags.Count) { '~ ' + ($flags -join ' ') } else { '' })
}
function Find-GameExe {
    param([string]$Game)
    $c = @()
    if ($Game -eq 'Valorant') {
        try { $ri = Get-Content -LiteralPath (Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $vl = [string]$ri.product_install_full_path.'valorant.live'; if ($vl) { $c += (Join-Path (Split-Path $vl) 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') } } catch { }
        foreach ($root in @("$env:ProgramFiles\Riot Games",'C:\Riot Games')) { $c += (Join-Path $root 'VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') }
    } else {
        foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests') -Filter '*.item' -ErrorAction SilentlyContinue)) {
            try { $e = Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json; if ($e.AppName -eq 'Fortnite' -and $e.InstallLocation) { $c += (Join-Path ([string]$e.InstallLocation) 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe') } } catch { }
        }
        foreach ($root in @("$env:ProgramFiles\Epic Games","${env:ProgramFiles(x86)}\Epic Games")) { $c += (Join-Path $root 'Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe') }
    }
    return (@($c | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1)
}
function Get-ValorantAccounts {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:ValRoot)) { return $list }
    $last = ''
    try { $m = Select-String -LiteralPath (Join-Path $script:ValRoot 'WindowsClient\RiotLocalMachine.ini') -Pattern '^LastKnownUser=(.+)$' -ErrorAction Stop | Select-Object -First 1; if ($m) { $last = $m.Matches[0].Groups[1].Value.Trim() } } catch { }
    foreach ($d in @(Get-ChildItem -LiteralPath $script:ValRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'CrashReportClient','WindowsClient','Windows' })) {
        $riot = Join-Path $d.FullName 'Windows\RiotUserSettings.ini'
        $gus = Join-Path $d.FullName 'WindowsClient\GameUserSettings.ini'
        if (-not (Test-Path -LiteralPath $riot) -and -not (Test-Path -LiteralPath $gus)) { continue }
        $times = @(@($riot,$gus) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime })
        $mg = Join-Path $script:ValRoot 'WindowsClient\GameUserSettings.ini'
        $isLast = [bool]($last -and $d.Name.StartsWith($last,[StringComparison]::OrdinalIgnoreCase))
        $list += [pscustomobject]@{ Name=('{0}{1}' -f $d.Name,$(if ($isLast) { '  - last signed in' } else { '' })); Dir=$d.FullName; Files=@{ Riot=$riot; Gus=$gus; Machine=$(if (Test-Path -LiteralPath $mg) { $mg } else { $null }) }; Changed=($times | Sort-Object -Descending | Select-Object -First 1); IsLast=$isLast }
    }
    return @($list | Sort-Object @{ Expression={ $_.IsLast }; Descending=$true },@{ Expression={ $_.Changed }; Descending=$true })
}
function Get-FortniteSources {
    $f = Join-Path $script:FnRoot 'GameUserSettings.ini'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @([pscustomobject]@{ Name='GameUserSettings.ini'; Dir=$script:FnRoot; Files=@{ Gus=$f }; Changed=(Get-Item -LiteralPath $f).LastWriteTime; IsLast=$true })
}
function New-GameOpt { param([string]$Text,[hashtable]$Values) return @{ Text=$Text; Values=$Values } }
function New-GameToggle {
    param([string]$Ref,[string]$OffText = 'Off',[string]$OnText = 'On',[string]$OffValue = 'False',[string]$OnValue = 'True')
    return @((New-GameOpt $OffText @{ $Ref=$OffValue }),(New-GameOpt $OnText @{ $Ref=$OnValue }))
}
function New-GameLevels {
    param([string[]]$Refs,[string[]]$Names)
    $o = @()
    for ($i = 0; $i -lt $Names.Count; $i++) { $v = @{}; foreach ($r in $Refs) { $v[$r] = [string]$i }; $o += (New-GameOpt $Names[$i] $v) }
    return $o
}
$script:ResList = @(@(1280,720),@(1280,960),@(1440,1080),@(1600,900),@(1680,1050),@(1920,1080),@(1920,1200),@(2560,1080),@(2560,1440),@(3440,1440),@(3840,2160))
$layerInfoAdmin = 'Adds "Run this program as an administrator" to the game exe (Properties > Compatibility). Only use it if a game overlay, macro or recording tool needs the game elevated: the launcher may then show a UAC prompt or fail to start the game, so switch it back off if that happens.'
$layerInfoFso = 'Adds "Disable fullscreen optimizations" to the game exe (Properties > Compatibility). The game then uses classic exclusive fullscreen instead of the borderless flip path. On Windows 10 and 11 the difference is usually small; test both.'
$valFps = @(New-GameOpt 'Unlimited' @{ 'R|EAresBoolSettingName::LimitFramerateAlways'='False'; 'G|FrameRateLimit'='0.000000' })
foreach ($f in 60,120,144,165,180,200,240,280,300) { $valFps += (New-GameOpt ('{0} FPS' -f $f) @{ 'R|EAresBoolSettingName::LimitFramerateAlways'='True'; 'R|EAresFloatSettingName::MaxFramerateAlways'=('{0}.000000' -f $f); 'G|FrameRateLimit'=('{0}.000000' -f $f) }) }
function New-ValCapOpts { param([string]$Which,[int[]]$Caps) $o = @(New-GameOpt 'Off' @{ ('R|EAresBoolSettingName::LimitFramerate' + $Which)='False' }); foreach ($c in $Caps) { $o += (New-GameOpt ('{0} FPS' -f $c) @{ ('R|EAresBoolSettingName::LimitFramerate' + $Which)='True'; ('R|EAresFloatSettingName::MaxFramerate' + $Which)=('{0}.000000' -f $c) }) }; return $o }
$valRes = foreach ($r in $script:ResList) { New-GameOpt ('{0} x {1}' -f $r[0],$r[1]) @{ 'G|ResolutionSizeX'=[string]$r[0]; 'G|ResolutionSizeY'=[string]$r[1]; 'G|LastUserConfirmedResolutionSizeX'=[string]$r[0]; 'G|LastUserConfirmedResolutionSizeY'=[string]$r[1] } }
function New-ValQuality {
    param([string]$RiotKey,[string[]]$Groups)
    $opts = @()
    foreach ($q in @(@('Low',0),@('Medium',1),@('High',2))) { $v = @{ ('R|' + $RiotKey) = [string]$q[1] }; foreach ($g in $Groups) { $v[('S|sg.' + $g)] = [string]$q[1] }; $opts += (New-GameOpt $q[0] $v) }
    return $opts
}
$script:GameEditors = [ordered]@{}
$script:GameEditors['Valorant'] = @{
    Key='Valorant'; Title='Valorant'; Process='VALORANT-Win64-Shipping'; SourceLabel='Valorant account:'; GetSources={ Get-ValorantAccounts }; Root={ $script:ValRoot }
    Sections=@{ R='Settings'; G='/Script/ShooterGame.ShooterGameUserSettings'; S='ScalabilityGroups' }; FileOf=@{ R='Riot'; G='Gus'; S='Gus' }; Mirror=@('G')
    Missing=@{ 'R|EAresBoolSettingName::LimitFramerateAlways'='False'; 'R|EAresBoolSettingName::LimitFramerateInMenu'='False'; 'R|EAresBoolSettingName::LimitFramerateInBackground'='False'; 'R|EAresBoolSettingName::LimitFramerateOnBattery'='False'; 'R|EAresIntSettingName::NvidiaReflexLowLatencySetting'='0'; 'R|EAresBoolSettingName::AMDAntiLag2Setting'='False'; 'R|EAresBoolSettingName::VignetteEnabled'='True'; 'R|EAresBoolSettingName::DisableDistortion'='False'; 'R|EAresBoolSettingName::ShadowsEnabled'='True' }
    Defs=@(
        @{ Group='Latency'; Label='NVIDIA Reflex Low Latency'; Info='NVIDIA GeForce only. On + Boost also keeps GPU clocks up in CPU-bound moments, which is most of Valorant.'; Opts=(New-GameLevels @('R|EAresIntSettingName::NvidiaReflexLowLatencySetting') @('Off','On','On + Boost')); Comp='On + Boost'; Vendor='NVIDIA' }
        @{ Group='Latency'; Label='AMD Anti-Lag 2'; Info='AMD Radeon only (RX 5000 and newer). Valorant''s built-in AMD latency reducer.'; Opts=(New-GameToggle 'R|EAresBoolSettingName::AMDAntiLag2Setting'); Comp='On'; Vendor='AMD' }
        @{ Group='Frame rate'; Label='Limit FPS always'; Info='Unlimited gives the lowest input delay. With FreeSync / G-SYNC, cap a few FPS below your refresh rate. Written to RiotUserSettings.ini and GameUserSettings.ini.'; Opts=$valFps; Comp='Unlimited' }
        @{ Group='Frame rate'; Label='Limit FPS in menus'; Info='Caps FPS in menus and the lobby so the GPU runs cooler there.'; Opts=(New-ValCapOpts 'InMenu' @(30,60,120,144)); Comp='60 FPS' }
        @{ Group='Frame rate'; Label='Limit FPS in background'; Info='Caps FPS while Valorant is not the active window.'; Opts=(New-ValCapOpts 'InBackground' @(30,60)); Comp='30 FPS' }
        @{ Group='Frame rate'; Label='Limit FPS on battery'; Info='Laptops: caps FPS while unplugged.'; Opts=(New-ValCapOpts 'OnBattery' @(30,60,120)); Comp='Off' }
        @{ Group='Display'; Label='Resolution'; Info='Written to the account and machine GameUserSettings.ini. A 4:3 resolution plus Fill gives stretched res.'; Opts=$valRes; Comp='' }
        @{ Group='Display'; Label='Display mode'; Info='Fullscreen gives the lowest input delay and is needed for stretched resolutions.'; Opts=@((New-GameOpt 'Fullscreen' @{ 'G|PreferredFullscreenMode'='0'; 'G|LastConfirmedFullscreenMode'='0' }),(New-GameOpt 'Windowed fullscreen' @{ 'G|PreferredFullscreenMode'='1'; 'G|LastConfirmedFullscreenMode'='1' }),(New-GameOpt 'Windowed' @{ 'G|PreferredFullscreenMode'='2'; 'G|LastConfirmedFullscreenMode'='2' })); Comp='Fullscreen' }
        @{ Group='Display'; Label='Aspect ratio method'; Info='Letterbox keeps black bars on a 4:3 resolution; Fill stretches it across the screen.'; Opts=@((New-GameOpt 'Letterbox (black bars)' @{ 'G|bShouldLetterbox'='True'; 'G|bLastConfirmedShouldLetterbox'='True' }),(New-GameOpt 'Fill (stretched)' @{ 'G|bShouldLetterbox'='False'; 'G|bLastConfirmedShouldLetterbox'='False' })); Comp='' }
        @{ Group='Display'; Label='V-Sync'; Info='Removes tearing but adds input delay.'; Opts=(New-GameToggle 'G|bUseVSync'); Comp='Off' }
        @{ Group='Graphics quality'; Label='Material quality'; Info='Also sets the engine shading, reflection and global illumination groups to the same level.'; Opts=(New-ValQuality 'EAresIntSettingName::MaterialQuality' @('ShadingQuality','ReflectionQuality','GlobalIlluminationQuality')); Comp='Low' }
        @{ Group='Graphics quality'; Label='Texture quality'; Info='Also sets the engine texture group to the same level.'; Opts=(New-ValQuality 'EAresIntSettingName::TextureQuality' @('TextureQuality')); Comp='Low' }
        @{ Group='Graphics quality'; Label='Detail quality'; Info='Also sets the engine view distance, foliage and effects groups to the same level.'; Opts=(New-ValQuality 'EAresIntSettingName::DetailQuality' @('ViewDistanceQuality','FoliageQuality','EffectsQuality')); Comp='Low' }
        @{ Group='Graphics quality'; Label='UI quality'; Info='Interface detail. No effect on gameplay.'; Opts=(New-ValQuality 'EAresIntSettingName::UIQuality' @()); Comp='Low' }
        @{ Group='Graphics quality'; Label='Vignette'; Info='Darkens the screen edges.'; Opts=(New-GameToggle 'R|EAresBoolSettingName::VignetteEnabled'); Comp='Off' }
        @{ Group='Graphics quality'; Label='Anti-aliasing'; Info='Same order as the in-game menu. The engine anti-aliasing group follows it.'; Opts=(New-GameLevels @('R|EAresIntSettingName::AntiAliasing','S|sg.AntiAliasingQuality') @('None','MSAA 2x','MSAA 4x','FXAA')); Comp='None' }
        @{ Group='Graphics quality'; Label='Anisotropic filtering'; Info='Sharpens textures seen at an angle. Nearly free on modern GPUs.'; Opts=@(foreach ($a in 1,2,4,8,16) { New-GameOpt ('{0}x' -f $a) @{ 'R|EAresIntSettingName::AnisotropicFiltering'=[string]$a } }); Comp='1x' }
        @{ Group='Graphics quality'; Label='Bloom'; Info='Glow around bright light. The engine post-process group follows it.'; Opts=@((New-GameOpt 'Off' @{ 'R|EAresIntSettingName::BloomQuality'='0'; 'S|sg.PostProcessQuality'='0' }),(New-GameOpt 'On' @{ 'R|EAresIntSettingName::BloomQuality'='1'; 'S|sg.PostProcessQuality'='2' })); Comp='Off' }
        @{ Group='Graphics quality'; Label='Distortion'; Info='Heat-haze and ability distortion effects.'; Opts=(New-GameToggle 'R|EAresBoolSettingName::DisableDistortion' 'Off' 'On' 'True' 'False'); Comp='Off' }
        @{ Group='Graphics quality'; Label='Cast shadows'; Info='Character and object shadows. The engine shadow group follows it.'; Opts=@((New-GameOpt 'Off' @{ 'R|EAresBoolSettingName::ShadowsEnabled'='False'; 'S|sg.ShadowQuality'='0' }),(New-GameOpt 'On' @{ 'R|EAresBoolSettingName::ShadowsEnabled'='True'; 'S|sg.ShadowQuality'='2' })); Comp='Off' }
        @{ Group='Windows'; Label='Run as administrator'; Info=$layerInfoAdmin; Opts=(New-GameToggle 'L|RUNASADMIN'); Comp='' }
        @{ Group='Windows'; Label='Disable fullscreen optimizations'; Info=$layerInfoFso; Opts=(New-GameToggle 'L|DISABLEDXMAXIMIZEDWINDOWEDMODE' 'No' 'Yes'); Comp='' }
    )
}
$fnFps = @(New-GameOpt 'Unlimited' @{ 'G|FrameRateLimit'='0.000000' })
foreach ($f in 30,60,120,144,165,180,200,240,360) { $fnFps += (New-GameOpt ('{0} FPS' -f $f) @{ 'G|FrameRateLimit'=('{0}.000000' -f $f) }) }
$fnRes = foreach ($r in $script:ResList) { New-GameOpt ('{0} x {1}' -f $r[0],$r[1]) @{ 'G|ResolutionSizeX'=[string]$r[0]; 'G|ResolutionSizeY'=[string]$r[1]; 'G|LastUserConfirmedResolutionSizeX'=[string]$r[0]; 'G|LastUserConfirmedResolutionSizeY'=[string]$r[1]; 'G|DesiredScreenWidth'=[string]$r[0]; 'G|DesiredScreenHeight'=[string]$r[1]; 'G|LastUserConfirmedDesiredScreenWidth'=[string]$r[0]; 'G|LastUserConfirmedDesiredScreenHeight'=[string]$r[1] } }
$fnLevels = @('Low','Medium','High','Epic')
$script:GameEditors['Fortnite'] = @{
    Key='Fortnite'; Title='Fortnite'; Process='FortniteClient-Win64-Shipping'; SourceLabel='Settings file:'; GetSources={ Get-FortniteSources }; Root={ $script:FnRoot }
    Sections=@{ G='/Script/FortniteGame.FortGameUserSettings'; S='ScalabilityGroups'; D='D3DRHIPreference'; T='RayTracing' }; FileOf=@{ G='Gus'; S='Gus'; D='Gus'; T='Gus' }; Mirror=@()
    Missing=@{ 'T|r.RayTracing.EnableInGame'='False' }
    Defs=@(
        @{ Group='Latency'; Label='NVIDIA Reflex Low Latency'; Info='NVIDIA GeForce only. On + Boost keeps GPU clocks up when the CPU is the limit.'; Opts=(New-GameLevels @('G|LatencyTweak2') @('Off','On','On + Boost')); Comp='On + Boost'; Vendor='NVIDIA' }
        @{ Group='Latency'; Label='Mouse acceleration'; Info='Off keeps aim 1:1 with mouse movement.'; Opts=(New-GameToggle 'G|bDisableMouseAcceleration' 'Off' 'On' 'True' 'False'); Comp='Off' }
        @{ Group='Frame rate'; Label='FPS limit'; Info='Unlimited gives the lowest input delay. With FreeSync / G-SYNC, cap a few FPS below your refresh rate.'; Opts=$fnFps; Comp='Unlimited' }
        @{ Group='Frame rate'; Label='Menu FPS limit'; Info='Caps FPS in the lobby and menus.'; Opts=@(foreach ($f in 30,60,120,144,240) { New-GameOpt ('{0} FPS' -f $f) @{ 'G|FrontendFrameRateLimit'=[string]$f } }); Comp='60 FPS' }
        @{ Group='Frame rate'; Label='Energy saver'; Info='Lowers FPS while idle or alt-tabbed. Off keeps full speed at all times.'; Opts=@((New-GameOpt 'Off' @{ 'G|bIsEnergySavingEnabledIdle'='False'; 'G|bIsEnergySavingEnabledFocusLoss'='False' }),(New-GameOpt 'On' @{ 'G|bIsEnergySavingEnabledIdle'='True'; 'G|bIsEnergySavingEnabledFocusLoss'='True' })); Comp='Off' }
        @{ Group='Frame rate'; Label='Show FPS'; Info='Shows the FPS counter in game.'; Opts=(New-GameToggle 'G|bShowFPS'); Comp='' }
        @{ Group='Display'; Label='Resolution'; Info='Game resolution. Lower 4:3 resolutions with Fullscreen give stretched res.'; Opts=$fnRes; Comp='' }
        @{ Group='Display'; Label='Window mode'; Info='Fullscreen gives the lowest input delay.'; Opts=@((New-GameOpt 'Fullscreen' @{ 'G|FullscreenMode'='0'; 'G|PreferredFullscreenMode'='0'; 'G|LastConfirmedFullscreenMode'='0' }),(New-GameOpt 'Windowed fullscreen' @{ 'G|FullscreenMode'='1'; 'G|PreferredFullscreenMode'='1'; 'G|LastConfirmedFullscreenMode'='1' }),(New-GameOpt 'Windowed' @{ 'G|FullscreenMode'='2'; 'G|PreferredFullscreenMode'='2'; 'G|LastConfirmedFullscreenMode'='2' })); Comp='Fullscreen' }
        @{ Group='Display'; Label='Rendering mode'; Info='Performance mode is the lightest renderer and gives the highest FPS on most PCs. DirectX 11 / 12 are needed for higher visual settings.'; Opts=@((New-GameOpt 'Performance' @{ 'D|PreferredFeatureLevel'='es31' }),(New-GameOpt 'DirectX 11' @{ 'D|PreferredRHI'='dx11'; 'D|PreferredFeatureLevel'='sm5' }),(New-GameOpt 'DirectX 12' @{ 'D|PreferredRHI'='dx12'; 'D|PreferredFeatureLevel'='sm6' })); Comp='Performance' }
        @{ Group='Display'; Label='V-Sync'; Info='Removes tearing but adds input delay.'; Opts=(New-GameToggle 'G|bUseVSync'); Comp='Off' }
        @{ Group='Display'; Label='3D resolution'; Info='Render scale of the 3D world. Below 100% looks blurry.'; Opts=@(foreach ($q in 100,90,80,75,66,50) { New-GameOpt ('{0}%' -f $q) @{ 'S|sg.ResolutionQuality'=[string]$q } }); Comp='100%' }
        @{ Group='Display'; Label='Upscaling'; Info='Native turns off temporal super resolution and DLSS so the game renders at full resolution with no upscaling blur.'; Opts=@((New-GameOpt 'Native (off)' @{ 'G|TemporalSuperResolutionQuality'='Custom'; 'G|DLSSQuality'='0' })); Comp='Native (off)' }
        @{ Group='Graphics quality'; Label='Anti-aliasing'; Info='Disabled is the sharpest and fastest. The engine anti-aliasing group follows it.'; Opts=@((New-GameOpt 'Disabled' @{ 'G|FortAntiAliasingMethod'='Disabled'; 'S|sg.AntiAliasingQuality'='0' }),(New-GameOpt 'FXAA' @{ 'G|FortAntiAliasingMethod'='FXAA' }),(New-GameOpt 'TAA' @{ 'G|FortAntiAliasingMethod'='TAA' })); Comp='Disabled' }
        @{ Group='Graphics quality'; Label='View distance'; Info='Engine view distance group.'; Opts=(New-GameLevels @('S|sg.ViewDistanceQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Shadows'; Info='Engine shadow group. Low turns shadows off.'; Opts=(New-GameLevels @('S|sg.ShadowQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Global illumination'; Info='Lumen lighting. Written to the Fortnite setting and the engine group.'; Opts=(New-GameLevels @('G|DesiredGlobalIlluminationQuality','S|sg.GlobalIlluminationQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Reflections'; Info='Written to the Fortnite setting and the engine group.'; Opts=(New-GameLevels @('G|DesiredReflectionQuality','S|sg.ReflectionQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Textures'; Info='Engine texture group. Low saves VRAM.'; Opts=(New-GameLevels @('S|sg.TextureQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Effects'; Info='Engine effects group.'; Opts=(New-GameLevels @('S|sg.EffectsQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Post processing'; Info='Engine post-process group.'; Opts=(New-GameLevels @('S|sg.PostProcessQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Meshes and shading'; Info='Engine shading group.'; Opts=(New-GameLevels @('S|sg.ShadingQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Foliage'; Info='Engine foliage group.'; Opts=(New-GameLevels @('S|sg.FoliageQuality') $fnLevels); Comp='Low' }
        @{ Group='Graphics quality'; Label='Motion blur'; Info='Blurs the screen while moving.'; Opts=(New-GameToggle 'G|bMotionBlur'); Comp='Off' }
        @{ Group='Graphics quality'; Label='Grass'; Info='Off removes grass, which makes players easier to see.'; Opts=(New-GameToggle 'G|bShowGrass' 'Hidden' 'Shown'); Comp='Hidden' }
        @{ Group='Graphics quality'; Label='Ray tracing'; Info='Hardware ray tracing. Large FPS cost.'; Opts=@((New-GameOpt 'Off' @{ 'G|bRayTracing'='False'; 'T|r.RayTracing.EnableInGame'='False' }),(New-GameOpt 'On' @{ 'G|bRayTracing'='True'; 'T|r.RayTracing.EnableInGame'='True' })); Comp='Off' }
        @{ Group='Graphics quality'; Label='Nanite'; Info='Nanite virtual geometry (DirectX 12 only). Large FPS cost.'; Opts=(New-GameToggle 'G|bUseNanite'); Comp='Off' }
        @{ Group='Graphics quality'; Label='DLSS frame generation'; Info='NVIDIA RTX 40 and newer. Adds fake frames and input delay.'; Opts=(New-GameToggle 'G|bEnableDLSSFrameGeneration'); Comp='Off' }
        @{ Group='Windows'; Label='Run as administrator'; Info=$layerInfoAdmin; Opts=(New-GameToggle 'L|RUNASADMIN'); Comp='' }
        @{ Group='Windows'; Label='Disable fullscreen optimizations'; Info=$layerInfoFso; Opts=(New-GameToggle 'L|DISABLEDXMAXIMIZEDWINDOWEDMODE' 'No' 'Yes'); Comp='' }
    )
}
function Get-GameFileValue {
    param($Game,$State,[string]$Ref)
    $kind = $Ref.Substring(0,1); $key = $Ref.Substring(2)
    if ($kind -eq 'L') { if (-not $State.Exe) { return $null }; return [string]((([string](Get-LayerString $State.Exe)) -split '\s+') -contains $key) }
    $v = Get-IniValue $State.Lines[$Game.FileOf[$kind]] $Game.Sections[$kind] $key
    if ($null -eq $v -and $Game.Missing.ContainsKey($Ref)) { $v = $Game.Missing[$Ref] }
    return $v
}
function Get-GameCurrentOption {
    param($Game,$State,$Def)
    foreach ($o in $Def.Opts) {
        $keys = @($o.Values.Keys | Where-Object { $_ -notmatch '^G\|(Last|bLast|Desired)' })
        if (@($keys | Where-Object { $_ -notlike 'S|*' }).Count) { $keys = @($keys | Where-Object { $_ -notlike 'S|*' }) }
        if (@($keys | Where-Object { $_ -like 'R|*' }).Count) { $keys = @($keys | Where-Object { $_ -ne 'G|FrameRateLimit' }) }
        if (-not $keys.Count) { continue }
        $ok = $true
        foreach ($k in $keys) { if (-not (Test-ValueEqual (Get-GameFileValue $Game $State $k) $o.Values[$k])) { $ok = $false; break } }
        if ($ok) { return $o }
    }
    return $null
}
function Set-GameFileValue {
    param($Game,$State,[string]$Ref,[string]$Value)
    $kind = $Ref.Substring(0,1); $key = $Ref.Substring(2)
    if ($kind -eq 'L') { if ($State.Exe) { Set-LayerFlag $State.Exe $key ($Value -eq 'True') }; return }
    Set-IniValue $State.Lines[$Game.FileOf[$kind]] $Game.Sections[$kind] $key $Value
    if ($Game.Mirror -contains $kind -and $State.Lines.ContainsKey('Machine') -and $State.Lines.Machine.Count) { Set-IniValue $State.Lines.Machine $Game.Sections[$kind] $key $Value }
}
function Load-GameState {
    param($Game)
    $ui = $Game.Ui
    $src = if ($ui.Source.SelectedItem) { $ui.Source.SelectedItem.Tag } else { $null }
    if (-not $src) {
        $Game.State = $null
        $ui.Status.Text = ('{0} settings not found. Start {0} once and change any setting so it creates its config files.' -f $Game.Title)
        foreach ($r in $Game.Rows) { $r.Combo.IsEnabled = $false }
        return
    }
    $lines = @{}; $metas = @{}
    foreach ($k in $src.Files.Keys) { $lines[$k] = (Read-IniLines $src.Files[$k]); $metas[$k] = (Get-IniFileMeta $src.Files[$k]) }
    $state = @{ Source=$src; Lines=$lines; Meta=$metas; Exe=(Find-GameExe $Game.Key) }
    $Game.State = $state
    foreach ($r in $Game.Rows) {
        $r.Combo.Items.Clear()
        $isLayer = [bool]@($r.Def.Opts[0].Values.Keys | Where-Object { $_ -like 'L|*' }).Count
        if ($isLayer -and -not $state.Exe) { [void]$r.Combo.Items.Add('(game not found)'); $r.Combo.SelectedIndex = 0; $r.Loaded = '(game not found)'; $r.Combo.IsEnabled = $false; continue }
        $cur = Get-GameCurrentOption $Game $state $r.Def
        if (-not $cur) { [void]$r.Combo.Items.Add('(keep current)') }
        foreach ($o in $r.Def.Opts) { [void]$r.Combo.Items.Add($o.Text) }
        $r.Combo.SelectedItem = $(if ($cur) { $cur.Text } else { '(keep current)' })
        $r.Loaded = [string]$r.Combo.SelectedItem
        $r.Combo.IsEnabled = $true
    }
    $ui.Status.Text = ('Loaded {0} (last changed {1:yyyy-MM-dd HH:mm}).{2}' -f $src.Name,$src.Changed,$(if ($state.Exe) { '' } else { ' Game exe not found, so the Windows options are unavailable.' }))
}
function Get-GameChangedRows { param($Game) if (-not $Game.State) { return @() }; return @($Game.Rows | Where-Object { [string]$_.Combo.SelectedItem -ne $_.Loaded -and [string]$_.Combo.SelectedItem -notmatch '^\(' }) }
function Test-GamesPending { foreach ($g in $script:GameEditors.Values) { if (@(Get-GameChangedRows $g).Count) { return $true } }; return $false }
function Save-GameState {
    param($Game)
    $state = $Game.State
    if (-not $state) { return $null }
    $changed = @(Get-GameChangedRows $Game)
    if (-not $changed.Count) { return $null }
    if (Get-Process -Name $Game.Process -ErrorAction SilentlyContinue) { [System.Windows.MessageBox]::Show(('Close {0} first. The game writes its settings back when it exits, which would undo these changes.' -f $Game.Title),('{0} settings' -f $Game.Title),'OK','Warning') | Out-Null; return $null }
    $toWrite = @($Game.Rows | Where-Object { [string]$_.Combo.SelectedItem -notmatch '^\(' })
    $bdir = Join-Path $script:BackupDir ('games\{0}\{1}' -f $Game.Key,(Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bdir -Force | Out-Null
    $paths = @{}
    foreach ($k in $state.Source.Files.Keys) { $fp = $state.Source.Files[$k]; if ($fp -and (Test-Path -LiteralPath $fp)) { Copy-Item -LiteralPath $fp -Destination (Join-Path $bdir ($k + '.ini')) -Force; $paths[$k] = $fp } }
    $created = @(foreach ($k in $state.Source.Files.Keys) { $fp = $state.Source.Files[$k]; if ($fp -and -not (Test-Path -LiteralPath $fp)) { $fp } })
    $meta = @{ Files=$paths; Created=$created; Exe=$state.Exe; Layers=$(if ($state.Exe) { Get-LayerString $state.Exe } else { $null }) }
    $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bdir 'backup.json') -Encoding UTF8
    foreach ($r in $toWrite) {
        $o = $r.Def.Opts | Where-Object { $_.Text -eq [string]$r.Combo.SelectedItem } | Select-Object -First 1
        foreach ($k in $o.Values.Keys) { Set-GameFileValue $Game $state $k ([string]$o.Values[$k]) }
    }
    foreach ($k in $state.Source.Files.Keys) {
        $fp = $state.Source.Files[$k]; $ln = $state.Lines[$k]
        if (-not $fp -or -not $ln -or -not $ln.Count) { continue }
        $fm = $state.Meta[$k]; if (-not $fm) { $fm = Get-IniFileMeta $fp }
        $newText = ($ln -join $fm.NewLine) + $(if ($fm.Final -or -not $fm.Existed) { $fm.NewLine } else { '' })
        if ($fm.Existed -and $newText -eq $fm.Text) { continue }
        $dir = Split-Path $fp
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $fp) { $it = Get-Item -LiteralPath $fp; if ($it.IsReadOnly) { $it.IsReadOnly = $false } }
        [IO.File]::WriteAllText($fp,$newText,$fm.Encoding)
    }
    $summary = @($changed | ForEach-Object { '{0}: {1}' -f $_.Def.Label,$_.Combo.SelectedItem })
    Write-Log ('{0}: saved {1} change(s) ({2}). Backup: {3}' -f $Game.Title,$changed.Count,($summary -join ', '),$bdir) 'Success'
    Load-GameState $Game
    return $summary
}
function Save-AllGames {
    $done = @()
    foreach ($g in $script:GameEditors.Values) { $s = Save-GameState $g; if ($s) { $done += ('{0}:' -f $g.Title); $done += @($s | ForEach-Object { '  ' + $_ }) } }
    if (-not $done.Count) { if (-not (Test-GamesPending)) { [System.Windows.MessageBox]::Show('No game setting was changed. Pick a different value in a dropdown first.','Game settings','OK','Information') | Out-Null }; return }
    if (-not $script:GameQuiet) { [System.Windows.MessageBox]::Show(("Saved:`r`n`r`n" + ($done -join "`r`n") + "`r`n`r`nStart the game to use the new settings."),'Game settings','OK','Information') | Out-Null }
}
function Restore-GameBackup {
    param($Game)
    $last = Get-ChildItem -LiteralPath (Join-Path $script:BackupDir ('games\' + $Game.Key)) -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $last) { [System.Windows.MessageBox]::Show(('No {0} backup yet. One is made every time you save.' -f $Game.Title),'Game settings','OK','Information') | Out-Null; return }
    if (Get-Process -Name $Game.Process -ErrorAction SilentlyContinue) { [System.Windows.MessageBox]::Show(('Close {0} first.' -f $Game.Title),'Game settings','OK','Warning') | Out-Null; return }
    if ([System.Windows.MessageBox]::Show(('Put back the {0} settings saved before the change at {1}?' -f $Game.Title,$last.Name),'Game settings','OKCancel','Question') -ne 'OK') { return }
    $meta = Get-Content -LiteralPath (Join-Path $last.FullName 'backup.json') -Raw | ConvertFrom-Json
    foreach ($p in $meta.Files.PSObject.Properties) { $src = Join-Path $last.FullName ($p.Name + '.ini'); if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination ([string]$p.Value) -Force } }
    foreach ($c in @($meta.Created)) { if ($c -and (Test-Path -LiteralPath ([string]$c))) { Remove-Item -LiteralPath ([string]$c) -Force -ErrorAction SilentlyContinue } }
    if ($meta.Exe) { Set-LayerString ([string]$meta.Exe) ([string]$meta.Layers) }
    Remove-Item -LiteralPath $last.FullName -Recurse -Force
    Write-Log ('{0} settings restored from the backup made at {1}.' -f $Game.Title,$last.Name) 'Success'
    Load-GameState $Game
}
function Set-GameCompetitive {
    param($Game)
    $vendors = @($script:Env.GpuVendors)
    foreach ($r in $Game.Rows) {
        if (-not $r.Combo.IsEnabled) { continue }
        $want = [string]$r.Def.Comp
        if ($r.Def.Vendor -and $vendors.Count -and $vendors -notcontains $r.Def.Vendor) { $want = 'Off' }
        if ($want -and $r.Combo.Items.Contains($want)) { $r.Combo.SelectedItem = $want }
    }
    Write-Log ('{0}: competitive values selected. Review them, then click Apply.' -f $Game.Title) 'Info'
}
function Update-GameSources {
    param($Game)
    $ui = $Game.Ui
    $ui.Source.Items.Clear()
    foreach ($a in @(& $Game.GetSources)) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = ('{0}  ({1:yyyy-MM-dd HH:mm})' -f $a.Name,$a.Changed)
        $it.Tag = $a
        [void]$ui.Source.Items.Add($it)
    }
    if ($ui.Source.Items.Count) { $ui.Source.SelectedIndex = 0 } else { Load-GameState $Game }
}
$script:BuildingTab = 'Games'
$gamesTabs = New-Object Windows.Controls.TabControl; $gamesTabs.Background = 'Transparent'; $gamesTabs.BorderThickness = '0'
$script:GameEditorsTabs = $gamesTabs
foreach ($geGame in $script:GameEditors.Values) {
    $geGame.Rows = @()
    $geUi = @{}
    $gePage = New-Object Windows.Controls.DockPanel; $gePage.Margin = '6'
    $geTop = New-Object Windows.Controls.WrapPanel; $geTop.Margin = '6,0,6,8'
    $geLab = New-HintText $geGame.SourceLabel; $geLab.VerticalAlignment = 'Center'; $geLab.Margin = '0,0,8,0'
    $geUi.Source = New-Object Windows.Controls.ComboBox; $geUi.Source.Width = 330; $geUi.Source.Margin = '0,0,8,0'
    $geBReload = New-Object Windows.Controls.Button; $geBReload.Content = 'Reload'; $geBReload.Margin = '0,0,8,0'
    $geBComp = New-Object Windows.Controls.Button; $geBComp.Content = 'Select competitive values'; $geBComp.Margin = '0,0,8,0'
    $geBUndo = New-Object Windows.Controls.Button; $geBUndo.Content = 'Undo last save'; $geBUndo.Margin = '0,0,8,0'
    $geBFolder = New-Object Windows.Controls.Button; $geBFolder.Content = 'Open config folder'; $geBFolder.Margin = '0,0,8,0'
    foreach ($geB in @($geBReload,$geBComp,$geBUndo,$geBFolder)) { $geB.Tag = $geGame }
    foreach ($geC in @($geLab,$geUi.Source,$geBReload,$geBComp,$geBUndo,$geBFolder)) { [void]$geTop.Children.Add($geC) }
    $geUi.Status = New-HintText ('Change values, then click Apply at the bottom right. {0} must be closed; every save is backed up first.' -f $geGame.Title); $geUi.Status.Margin = '6,0,6,6'
    $geHead = New-Object Windows.Controls.StackPanel
    [void]$geHead.Children.Add($geTop); [void]$geHead.Children.Add($geUi.Status)
    [Windows.Controls.DockPanel]::SetDock($geHead,'Top'); [void]$gePage.Children.Add($geHead)
    $geSections = foreach ($geG in @($geGame.Defs | Group-Object { $_.Group })) {
        $geRows = foreach ($geD in $geG.Group) {
            $geRow = New-Object Windows.Controls.Grid; $geRow.Margin = '0,3,0,3'
            foreach ($geW in '*','Auto','Auto') { $geCd = New-Object Windows.Controls.ColumnDefinition; $geCd.Width = $geW; [void]$geRow.ColumnDefinitions.Add($geCd) }
            $geLbl = New-Object Windows.Controls.TextBlock; $geLbl.Text = $geD.Label; $geLbl.VerticalAlignment = 'Center'; Set-ThemeBrush $geLbl 'Foreground' 'Text'
            $geCb = New-Object Windows.Controls.ComboBox; $geCb.Width = 190; $geCb.Margin = '8,0,8,0'; $geCb.IsEnabled = $false; [Windows.Controls.Grid]::SetColumn($geCb,1)
            $geIc = New-InfoIcon $geD.Info; [Windows.Controls.Grid]::SetColumn($geIc,2)
            [void]$geRow.Children.Add($geLbl); [void]$geRow.Children.Add($geCb); [void]$geRow.Children.Add($geIc)
            $geGame.Rows += @{ Def=$geD; Combo=$geCb; Loaded='' }
            $script:SearchItems += @{ Row=$geRow; Text=('{0} {1} {2}' -f $geGame.Title,$geD.Label,$geD.Info); Tab='Games' }
            $geRow
        }
        @{ Box=(New-SectionBox -Title ('{0} - {1}' -f $geGame.Title,$geG.Name) -Children $geRows -Tab 'Games'); Weight=$geG.Count }
    }
    [void]$gePage.Children.Add((New-TwoColumnPanel $geSections))
    $geGame.Ui = $geUi
    $geUi.Source.Tag = $geGame
    $geUi.Source.Add_SelectionChanged({ param($s,$e) if ($s.SelectedItem) { try { Load-GameState $s.Tag } catch { Write-Log ('{0}: could not read settings: {1}' -f $s.Tag.Title,$_.Exception.Message) 'Error' } } })
    $geBReload.Add_Click({ param($s,$e) try { Update-GameSources $s.Tag } catch { Write-Log ('{0}: {1}' -f $s.Tag.Title,$_.Exception.Message) 'Error' } })
    $geBComp.Add_Click({ param($s,$e) Set-GameCompetitive $s.Tag })
    $geBUndo.Add_Click({ param($s,$e) try { Restore-GameBackup $s.Tag } catch { Write-Log ('{0}: restore failed: {1}' -f $s.Tag.Title,$_.Exception.Message) 'Error' } })
    $geBFolder.Add_Click({ param($s,$e) $geG = $s.Tag; $a = $geG.Ui.Source.SelectedItem; $root = & $geG.Root; if ($a) { Start-Process explorer.exe $a.Tag.Dir } elseif (Test-Path -LiteralPath $root) { Start-Process explorer.exe $root } })
    $geTi = New-Object Windows.Controls.TabItem; $geTi.Header = $geGame.Title; $geTi.Content = $gePage
    [void]$gamesTabs.Items.Add($geTi)
    try { Update-GameSources $geGame } catch { Write-Log ('{0}: {1}' -f $geGame.Title,$_.Exception.Message) 'Warn' }
}
Add-Tab 'Games' $gamesTabs | Out-Null

$tabOrder = @('Home','Tweaks','CPU','Power plan','GPU','AMD','NVIDIA','Intel','Networking','Games','Security','Advanced','Debloat','Cleanup','Fixes','Settings')
$allTabs = @($Tabs.Items)
$Tabs.Items.Clear()
foreach ($name in $tabOrder) { foreach ($ti in $allTabs) { if ([string]$ti.Header -eq $name) { [void]$Tabs.Items.Add($ti) } } }
foreach ($ti in $allTabs) { if ($tabOrder -notcontains [string]$ti.Header) { [void]$Tabs.Items.Add($ti) } }
$Tabs.SelectedIndex = 0

$Tabs.Add_SelectionChanged({
    param($sender,$e)
    if ($e.OriginalSource -ne $sender) { return }
    if ($sender.SelectedItem -ne $script:PowerUi.Tab) { return }
    $script:Window.Dispatcher.BeginInvoke([action]{ Invoke-PowerAction 'Loading power plans' { Open-PowerTab } },[Windows.Threading.DispatcherPriority]::Background) | Out-Null
})
$script:PowerUi.PlanCombo.Add_SelectionChanged({
    param($sender,$e)
    if ($script:PowerUi.Syncing -or $sender.SelectedIndex -lt 0) { return }
    $target = [string]$script:PowerUi.Plans[$sender.SelectedIndex].Guid
    if ($target -eq $script:PowerUi.Plan) { return }
    if (Test-PowerUnsaved) {
        $script:PowerUi.Syncing = $true
        try { for ($i = 0; $i -lt $script:PowerUi.Plans.Count; $i++) { if ($script:PowerUi.Plans[$i].Guid -eq $script:PowerUi.Plan) { $sender.SelectedIndex = $i } } } finally { $script:PowerUi.Syncing = $false }
        return
    }
    Invoke-PowerAction 'Loading plan' { Select-PowerPlan $target }
})
$script:PowerUi.ModeCombo.Add_SelectionChanged({
    param($sender,$e)
    if ($script:PowerUi.Syncing -or $sender.SelectedIndex -lt 0) { return }
    $mode = [string]$sender.SelectedItem
    Invoke-PowerAction 'Changing power mode' { Set-PowerMode $script:PowerModes[$mode]; Write-Log ("Power mode set to {0}." -f $mode) 'Success'; Update-PowerPlanList -Select $script:PowerUi.Plan }
})
$script:PowerUi.NameBox.Add_TextChanged({ if (-not $script:PowerUi.Syncing) { Update-PowerPendingText } })
$script:PowerUi.DescBox.Add_TextChanged({ if (-not $script:PowerUi.Syncing) { Update-PowerPendingText } })
$script:PowerUi.Search.Add_TextChanged({ if ($script:PowerUi.Loaded) { Update-PowerFilter } })
$script:PowerUi.ShowHidden.Add_Click({ if ($script:PowerUi.Loaded) { Update-PowerFilter } })
$script:PowerUi.OnlyChanged.Add_Click({ if ($script:PowerUi.Loaded) { Update-PowerFilter } })
$powerSaveBtn.Add_Click({ Invoke-PowerAction 'Saving the power plan' { Invoke-PowerApply } })
$powerDiscardBtn.Add_Click({ Invoke-PowerAction 'Reloading the power plan' { Update-PowerPlanList -Select $script:PowerUi.Plan; Write-Log 'Unsaved power plan edits discarded.' 'Info' } })
$script:PowerUi.ActivateBtn.Add_Click({
    Invoke-PowerAction 'Switching plans' {
        if (Test-PowerUnsaved) { return }
        Set-ActivePowerPlan $script:PowerUi.Plan
        Write-Log ("Active power plan: {0}" -f [RionPowrProf]::Name($script:PowerUi.Plan,$null,$null)) 'Success'
        Update-PowerPlanList -Select $script:PowerUi.Plan
    }
})
$powerDupBtn.Add_Click({
    Invoke-PowerAction 'Duplicating the plan' {
        $src = @($script:PowerUi.Plans | Where-Object { $_.Guid -eq $script:PowerUi.Plan })[0]
        $g = Copy-PowerPlan -SourceGuid $src.Guid -Name ("{0} (copy)" -f $src.Name) -Description ([string]$src.Description)
        if (-not $g) { throw 'Windows refused to duplicate this plan.' }
        Write-Log ("Created '{0} (copy)'." -f $src.Name) 'Success'
        Update-PowerPlanList -Select $g
    }
})
$script:PowerUi.DeleteBtn.Add_Click({
    Invoke-PowerAction 'Deleting the plan' {
        $src = @($script:PowerUi.Plans | Where-Object { $_.Guid -eq $script:PowerUi.Plan })[0]
        if ([System.Windows.MessageBox]::Show(("Delete the power plan '{0}'?`r`n`r`nThis cannot be undone unless you exported it. A backup copy is saved to the Rion Tool backups folder first." -f $src.Name),'Delete power plan','OKCancel','Warning') -ne 'OK') { return }
        [void](Export-PowerPlanBackup $src.Guid)
        $r = Invoke-PowerCfg @('-delete',$src.Guid)
        if ($r.ExitCode -ne 0) { throw $r.Error }
        foreach ($k in @($script:PowerJournal.Keys | Where-Object { $_ -like "*|$($src.Guid)|*" -or $_ -like "*|$($src.Guid)" })) { $script:PowerJournal.Remove($k) }
        Save-PowerJournal
        Write-Log ("Deleted the power plan '{0}'." -f $src.Name) 'Success'
        $script:PowerUi.Plan = $null
        Update-PowerPlanList
    }
})
$powerExportBtn.Add_Click({
    Invoke-PowerAction 'Exporting the plan' {
        $src = @($script:PowerUi.Plans | Where-Object { $_.Guid -eq $script:PowerUi.Plan })[0]
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Power plan (*.pow)|*.pow'; $dlg.FileName = (($src.Name -replace '[\\/:*?"<>|]','_') + '.pow')
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $r = Invoke-PowerCfg @('-export',$dlg.FileName,$src.Guid)
        if ($r.ExitCode -ne 0) { throw $r.Error }
        Write-Log ("Exported '{0}' to {1}" -f $src.Name,$dlg.FileName) 'Success'
    }
})
$powerImportBtn.Add_Click({
    Invoke-PowerAction 'Importing a plan' {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Power plan (*.pow)|*.pow'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $r = Invoke-PowerCfg @('-import',$dlg.FileName)
        $g = [regex]::Match($r.Output,$script:PowerGuidPattern).Value
        if ($r.ExitCode -ne 0 -or -not $g) { throw $r.Error }
        Write-Log ("Imported {0} as a new plan." -f $dlg.FileName) 'Success'
        Update-PowerPlanList -Select $g
    }
})
$powerRionBtn.Add_Click({
    Invoke-PowerAction 'Installing Rion''s power plan' {
        $g = Install-RionPowerPlan
        Write-Log 'Rion''s power plan is installed and active.' 'Success'
        Update-PowerPlanList -Select ([string]$g)
    }
})
$powerDefaultsBtn.Add_Click({
    Invoke-PowerAction 'Restoring default plans' {
        $msg = "Restore the Windows default power plans?`r`n`r`nThis deletes EVERY custom plan, including Rion's power plan and any vendor plans, and resets Balanced, High performance and Power saver to their defaults. Export any plan you want to keep first."
        if ([System.Windows.MessageBox]::Show($msg,'Restore default plans','OKCancel','Warning') -ne 'OK') { return }
        $r = Invoke-PowerCfg @('-restoredefaultschemes')
        if ($r.ExitCode -ne 0) { throw $r.Error }
        foreach ($k in @($script:PowerJournal.Keys | Where-Object { $_ -notlike 'attr|*' -and $_ -ne 'overlay' })) { $script:PowerJournal.Remove($k) }
        Save-PowerJournal
        Write-Log 'Windows default power plans restored.' 'Success'
        $script:PowerUi.Plan = $null
        Update-PowerPlanList
    }
})
$powerResetBtn.Add_Click({
    Invoke-PowerAction 'Resetting the plan' {
        $rows = @($script:PowerUi.Rows | Where-Object { $_.Modified })
        if (-not $rows.Count) { Write-Log 'Every setting in this plan already matches its default.' 'Info'; return }
        if ([System.Windows.MessageBox]::Show(("Set {0} setting(s) back to this plan's Windows defaults?" -f $rows.Count),'Reset plan','OKCancel','Question') -ne 'OK') { return }
        [void](Export-PowerPlanBackup $script:PowerUi.Plan)
        $fail = 0
        foreach ($row in $rows) { if (Set-PowerSettingValue -Plan $script:PowerUi.Plan -Sub $row.Def.Sub -Setting $row.Def.Guid -Ac $row.Default[0] -Dc $row.Default[1]) { $fail++ } }
        Save-PowerJournal
        Update-ActivePowerPlan $script:PowerUi.Plan
        Write-Log ("Reset {0} setting(s) to defaults, {1} failed." -f ($rows.Count - $fail),$fail) $(if ($fail) { 'Warn' } else { 'Success' })
        Update-PowerPlanList -Select $script:PowerUi.Plan
    }
})
$script:PowerUi.UndoBtn.Add_Click({
    Invoke-PowerAction 'Undoing power plan changes' {
        $r = Restore-PowerPlanChanges $script:PowerUi.Plan
        Write-Log ("Restored {0} power setting(s) to their earlier values, {1} failed." -f $r.Restored,$r.Failed) $(if ($r.Failed) { 'Warn' } else { 'Success' })
        Update-PowerPlanList -Select $script:PowerUi.Plan
    }
})
$script:PowerUi.UnhideBtn.Add_Click({
    Invoke-PowerAction 'Changing setting visibility' {
        $show = -not @($script:PowerJournal.Keys | Where-Object { $_ -like 'attr|*' }).Count
        $n = Set-PowerSettingsVisibility -Show $show
        Write-Log $(if ($show) { "{0} hidden power settings and subgroups now show in Control Panel > Power Options." -f $n } else { "{0} power settings hidden again." -f $n }) 'Success'
        Build-PowerRows
        Update-PowerPlanList -Select $script:PowerUi.Plan
    }
})

function Update-ViewFilter {
    $showSafe = [bool]$ViewSafe.IsChecked
    $showMod  = [bool]$ViewModerate.IsChecked
    $showRisk = [bool]$ViewRisky.IsChecked
    $q = ([string]$SearchBox.Text).Trim()
    $words = @($q -split '\s+' | Where-Object { $_ })
    $boxes = @{}; $pageHits = @{}
    foreach ($id in $script:Rows.Keys) {
        $e = $script:Rows[$id]
        if (-not $e.Row.Parent) { continue }
        $risk = $e.Tweak.Risk
        $vis = switch ($risk) {
            'Safe'     { $showSafe }
            'Moderate' { $showMod }
            'Risky'    { $showRisk }
            default    { $true }
        }
        if ($vis -and $words.Count) {
            $hay = ('{0} {1} {2} {3}' -f $e.Tweak.Label,$e.Tweak.Info,$e.Tweak.Group,$e.Tweak.Warn)
            foreach ($w in $words) { if ($hay.IndexOf($w,[StringComparison]::OrdinalIgnoreCase) -lt 0) { $vis = $false; break } }
        }
        $e.Row.Visibility = if ($vis) { 'Visible' } else { 'Collapsed' }
        $box = $null; try { $box = $e.Row.Parent.Parent } catch { }
        if ($box) { $key = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($box); if (-not $boxes.ContainsKey($key)) { $boxes[$key] = @{ Box=$box; Any=$false } }; if ($vis) { $boxes[$key].Any = $true } }
        if ($vis) { $page = Get-TweakPageKey $e.Tweak; $pageHits[$page] = 1 + [int]$pageHits[$page] }
    }
    foreach ($it in $script:SearchItems) {
        $vis = $true
        if ($words.Count) { foreach ($w in $words) { if (([string]$it.Text).IndexOf($w,[StringComparison]::OrdinalIgnoreCase) -lt 0) { $vis = $false; break } } }
        $it.Row.Visibility = if ($vis) { 'Visible' } else { 'Collapsed' }
        $box = $null; try { $box = $it.Row.Parent.Parent } catch { }
        if ($box -is [Windows.Controls.Border]) { $key = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($box); if (-not $boxes.ContainsKey($key)) { $boxes[$key] = @{ Box=$box; Any=$false } }; if ($vis) { $boxes[$key].Any = $true } }
        if ($vis -and $it.Tab) { $pageHits[$it.Tab] = 1 + [int]$pageHits[$it.Tab] }
    }
    foreach ($b in $boxes.Values) { $b.Box.Visibility = if ($b.Any) { 'Visible' } else { 'Collapsed' } }
    foreach ($ti in @($Tabs.Items) + @($innerTabs.Items)) {
        if ($null -eq $ti.Tag -or $ti.Tag -isnot [string]) { $ti.Tag = [string]$ti.Header }
        $base = [string]$ti.Tag
        $key = if (@($innerTabs.Items) -contains $ti) { 'Tweaks/' + $base } else { $base }
        $n = if ($base -eq 'Tweaks') { [int](@($pageHits.Keys | Where-Object { $_ -like 'Tweaks/*' } | ForEach-Object { $pageHits[$_] }) | Measure-Object -Sum).Sum } else { [int]$pageHits[$key] }
        $ti.Header = if ($words.Count -and $n -gt 0 -and $base -notin 'Power plan','Debloat','Settings') { ('{0} ({1})' -f $base,$n) } else { $base }
    }
}
$SearchBox.Add_TextChanged({ Update-ViewFilter })
$ViewSafe.Add_Click({ Update-ViewFilter })
$ViewModerate.Add_Click({ Update-ViewFilter })
$ViewRisky.Add_Click({ Update-ViewFilter })
 
$script:NoPreset = @('feat.net.wifi','feat.net.eth','gpu.msi')
foreach ($p in @('Recommended','Gamer max','Minimal','Max (incl. Risky)','None')) { [void]$PresetCombo.Items.Add($p) }
$script:GamerMaxExclude = @('svc.bg.diag','net.teredo','startup.all','gpu.vrr.windowed','feat.lighting.off','feat.taskbar.simple','cpu.ppm.minstate','cpu.amd.x3dcache','sec.vbs','sec.lsa.ppl','sec.wu.pinversion','svc.bg.servicing','svc.net.iphlp','feat.opt.media','svc.xbox.live','task.xblgamesave')
function Test-GamerMax {
    param($Tweak)
    if ($Tweak.Risk -notin 'Safe','Moderate') { return $false }
    if ($script:GamerMaxExclude -contains $Tweak.Id) { return $false }
    if ($script:BuiltOnLaptop -and $script:LaptopRisky -contains $Tweak.Id) { return $false }
    if ([string]$Tweak.Id -match '(?i)xbox|xbl|gamedvr|defender|\.wu\.|update|bluetooth|feat\.net\.|svc\.net\.wifi|svc\.net\.eth') { return $false }
    if ([string]$Tweak.Label -match '(?i)xbox|defender|windows update|bluetooth') { return $false }
    return $true
}
$script:PagePresets = @{}
$script:AllPagesPreset = $null
$script:SyncingPreset = $false
function Get-CurrentPageKey {
    $top = [string]$Tabs.SelectedItem.Header
    if ($top -eq 'Tweaks' -and $innerTabs.SelectedItem) { return ('Tweaks/{0}' -f $innerTabs.SelectedItem.Header) }
    return $top
}
function Get-TweakPageKey {
    param($Tweak)
    if ($Tweak.Tab -eq 'Tweaks') { return ('Tweaks/{0}' -f $Tweak.SubTab) }
    return [string]$Tweak.Tab
}
function Sync-PresetCombo {
    $script:SyncingPreset = $true
    try {
        $saved = if ([bool]$PresetAllPages.IsChecked) { $script:AllPagesPreset } else { $script:PagePresets[(Get-CurrentPageKey)] }
        if ($saved) { $PresetCombo.SelectedItem = $saved } else { $PresetCombo.SelectedIndex = -1 }
    } finally { $script:SyncingPreset = $false }
}
foreach ($tc in @($Tabs,$innerTabs)) {
    $tc.Add_SelectionChanged({
        param($sender,$e)
        if ($e.OriginalSource -ne $sender) { return }
        Sync-PresetCombo
    })
}
function Set-PagePreset {
    param([string]$page,[string]$sel)
    $script:PagePresets[$page] = $sel
    if ($page -eq 'Debloat') { Set-DebloatPreset -Preset $(if ($sel -eq 'Gamer max') { 'Recommended' } else { $sel }); return }
    foreach ($id in $script:Rows.Keys) {
        $e = $script:Rows[$id]
        if ((Get-TweakPageKey $e.Tweak) -ne $page) { continue }
        if ($sel -eq 'None') {
            if ($e.Check -and $e.Check.IsEnabled) { $e.Check.IsChecked = $false }
            elseif ($e.Combo -and $e.Combo.IsEnabled) { $e.Combo.SelectedIndex = 0; $e.Touched = $script:Journal.ContainsKey($id) }
            continue
        }
        if (-not $e.Check) { continue }
        if (-not $e.Check.IsEnabled) { continue }
        $applied = [bool]($script:Detection[$id] -and $script:Detection[$id].Applied)
        if ($script:NoPreset -contains $id) { $e.Check.IsChecked = $applied; continue }
        $inPreset = switch ($sel) {
            'Recommended'       { [bool]$e.Tweak.Recommend }
            'Minimal'           { $script:MinimalIds -contains $e.Tweak.Id }
            'Max (incl. Risky)' { $true }
            'Gamer max'         { Test-GamerMax $e.Tweak }
            default             { $false }
        }
        $e.Check.IsChecked = ($applied -or [bool]$inPreset)
    }
}
$PresetCombo.Add_SelectionChanged({
    if ($script:SyncingPreset) { return }
    $sel = [string]$PresetCombo.SelectedItem
    if (-not $sel) { return }
    if ([bool]$PresetAllPages.IsChecked) {
        $script:AllPagesPreset = $sel
        $pages = @($script:Rows.Values | ForEach-Object { Get-TweakPageKey $_.Tweak } | Select-Object -Unique) + 'Debloat'
        foreach ($pg in $pages) { Set-PagePreset -page $pg -sel $sel }
    } else {
        Set-PagePreset -page (Get-CurrentPageKey) -sel $sel
    }
})
$PresetAllPages.Add_Click({
    if ([bool]$PresetAllPages.IsChecked) { $script:AllPagesPreset = $null }
    Sync-PresetCombo
})
 
function New-RestorePoint {
    param([string]$Desc = 'Rion Tool')
    try {
        Write-Log 'Creating a restore point...' 'Action'
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0 'DWord'
        Checkpoint-Computer -Description $Desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Created a restore point' 'Success'
        return $true
    } catch {
        Write-Log ("Restore point failed: {0}" -f $_.Exception.Message) 'Warn'
        return $false
    }
}
$RestoreBtn.Add_Click({ New-RestorePoint | Out-Null })
 
function Get-PendingTweaks {
    $pending = @()
    foreach ($id in $script:Rows.Keys) {
        $e = $script:Rows[$id]
        $detection = $script:Detection[$id]
        $currentlyApplied = [bool]($detection -and $detection.Applied)
        if ($e.Check -and $e.Check.IsEnabled) {
            $desiredApplied = [bool]$e.Check.IsChecked
            if ($desiredApplied -ne $currentlyApplied -and ($desiredApplied -or @(Get-RevertActions $e.Tweak).Count -gt 0)) {
                $pending += @{ Tweak=$e.Tweak; Choice=$null; TargetApplied=$desiredApplied }
            }
        } elseif ($e.Combo -and $e.Combo.IsEnabled -and $e.Touched -and $e.Combo.SelectedIndex -eq 0 -and $script:Journal.ContainsKey($id) -and [string]@($e.Tweak.Options)[0] -match '^Default') {
            $pending += @{ Tweak=$e.Tweak; Choice=$null; TargetApplied=$false }
        } elseif ($e.Combo -and $e.Combo.IsEnabled -and $e.Touched -and ($e.Combo.SelectedIndex -gt 0 -or ([string]@($e.Tweak.Options)[0] -notmatch '^Default' -and $e.Combo.SelectedIndex -eq 0))) {
            $pending += @{ Tweak=$e.Tweak; Choice=[string]$e.Combo.SelectedItem; TargetApplied=$true }
        }
    }
    return $pending
}

function Test-HvciDisableRequest {
    param($Node)
    if ($Node.Tweak.Id -eq 'sec.vbs' -and [string]$Node.Choice -eq 'Off') { return $true }
    $actions = if ($Node.TargetApplied) { @($Node.Tweak.Apply) } else { @($Node.Tweak.Revert) }
    foreach ($action in $actions) { if (Test-HvciDisableAction $action) { return $true } }
    return $false
}

function Show-HvciWarningDialog {
    param($Owner)
    $dlg = New-Object Windows.Window
    $dlg.Title='Anti-cheat compatibility warning'; $dlg.Width=660; $dlg.SizeToContent='Height'
    $dlg.ResizeMode='NoResize'; $dlg.WindowStartupLocation='CenterOwner'; $dlg.Owner=$Owner
    $dlg.ShowInTaskbar=$false; $dlg.Background=$script:Window.FindResource('Bg')
    $content = New-Object Windows.Controls.StackPanel; $content.Margin='20'
    $heading = New-Object Windows.Controls.TextBlock
    $heading.Text='ERROR: HVCI will be turned off'; $heading.FontSize=18; $heading.FontWeight='SemiBold'
    $heading.Foreground=$script:Window.FindResource('Risky'); $heading.Margin='0,0,0,12'
    $message = New-Object Windows.Controls.TextBlock
    $message.Text='Turning off Memory Integrity (HVCI) reduces protection against malicious drivers. Riot Vanguard may require HVCI/VBS on your system, and other anti-cheat software may require it too. Disabling HVCI can prevent Valorant or other protected games from launching. A restart is required for the setting to take effect.'
    $message.TextWrapping='Wrap'; $message.Foreground=$script:Window.FindResource('Text'); $message.Margin='0,0,0,18'
    [void]$content.Children.Add($heading); [void]$content.Children.Add($message)
    $buttons = New-Object Windows.Controls.StackPanel; $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'
    foreach ($choice in @(
        @{ Text='Re-enable HVCI'; Result='Enable'; Brush='Accent' },
        @{ Text='Turn HVCI off anyway'; Result='Continue'; Brush='Risky' },
        @{ Text='Skip HVCI change'; Result='Skip'; Brush='Panel' },
        @{ Text='Cancel apply'; Result='Cancel'; Brush='Panel' }
    )) {
        $button = New-Object Windows.Controls.Button; $button.Content=$choice.Text; $button.Tag=$choice.Result
        $button.Margin='0,0,8,0'; $button.Padding='10,6'; $button.Foreground=$script:Window.FindResource('Text')
        $button.Background=$script:Window.FindResource($choice.Brush); $button.BorderBrush=$script:Window.FindResource('Border')
        $button.Add_Click({ param($sender,$eventArgs) $dlg.Tag=[string]$sender.Tag; $dlg.Close() }.GetNewClosure())
        [void]$buttons.Children.Add($button)
    }
    [void]$content.Children.Add($buttons); $dlg.Content=$content; $dlg.Tag='Cancel'
    [void]$dlg.ShowDialog()
    return [string]$dlg.Tag
}
 
function Show-ApplyDialog {
    param($Pending,[object[]]$Apps=@())
    $dlg = New-Object Windows.Window
    $dlg.Title='Apply'; $dlg.Width=620; $dlg.Height=560; $dlg.WindowStartupLocation='CenterOwner'
    $dlg.Owner=$script:Window; $dlg.Background=$script:Window.FindResource('Bg')
    $grid = New-Object Windows.Controls.Grid; $grid.Margin='12'
    foreach ($h in 'Auto','*','Auto','Auto') { $rd=New-Object Windows.Controls.RowDefinition; $rd.Height=$h; [void]$grid.RowDefinitions.Add($rd) }
    $intro = New-Object Windows.Controls.TextBlock
    $applyList = @($Pending | Where-Object { $_.TargetApplied })
    $revertList = @($Pending | Where-Object { -not $_.TargetApplied })
    $intro.Text = if ($revertList.Count) { ('{0} to apply and {1} to revert to the original setting (marked REVERT). Untick anything you want to leave as it is. Expand a group to choose single services or tasks.' -f $applyList.Count,$revertList.Count) } else { 'Untick any setting or app you want to keep. Expand a group to choose single services or tasks.' }
    $intro.Foreground=$script:Window.FindResource('SubText'); $intro.TextWrapping='Wrap'; $intro.Margin='0,0,0,8'
    [Windows.Controls.Grid]::SetRow($intro,0); [void]$grid.Children.Add($intro)
 
    $tree = New-Object Windows.Controls.TreeView
    $tree.Background=$script:Window.FindResource('Panel'); $tree.BorderBrush=$script:Window.FindResource('Border')
    [Windows.Controls.Grid]::SetRow($tree,1); [void]$grid.Children.Add($tree)



    $nodes = @(); $appNodes=@()
    foreach ($p in @($applyList + $revertList)) {
        $t = $p.Tweak
        $item = New-Object Windows.Controls.TreeViewItem
        $head = New-Object Windows.Controls.StackPanel; $head.Orientation='Horizontal'
        $cb = New-Object Windows.Controls.CheckBox; $cb.IsChecked=$true; $cb.VerticalAlignment='Center'
        $txt = New-Object Windows.Controls.TextBlock
        $suffix = if ($p.Choice) { " = $($p.Choice)" } else { '' }
        $txt.Text = ("{0}{1}  ({2})" -f (Get-DisplayLabel -Tweak $t -TargetApplied ([bool]$p.TargetApplied)),$suffix,$t.Risk); $txt.Margin='6,0,0,0'
        $txt.Foreground=$script:Window.FindResource('Text'); $txt.VerticalAlignment='Center'
        [void]$head.Children.Add($cb); [void]$head.Children.Add($txt)
        if (-not $p.TargetApplied) {
            $revertTag = New-Object Windows.Controls.TextBlock
            $revertTag.Text='REVERT'; $revertTag.FontSize=10; $revertTag.FontWeight='SemiBold'; $revertTag.Margin='8,0,0,0'
            $revertTag.VerticalAlignment='Center'; $revertTag.Foreground=$script:Window.FindResource('Moderate')
            [void]$head.Children.Add($revertTag)
        }
        $warnLine = if ($p.TargetApplied) { New-WarnText -Tweak $t } else { $null }
        if ($warnLine) {
            $headStack = New-Object Windows.Controls.StackPanel
            [void]$headStack.Children.Add($head); [void]$headStack.Children.Add($warnLine)
            $item.Header=$headStack
        } else {
            $item.Header=$head
        }
        $item.IsExpanded=$false
 
        $childChecks = @()
        $children = Get-TweakChildren -Tweak $t -TargetApplied ([bool]$p.TargetApplied)
        foreach ($c in $children) {
            $ci = New-Object Windows.Controls.TreeViewItem
            $ch = New-Object Windows.Controls.StackPanel; $ch.Orientation='Horizontal'
            $ccb = New-Object Windows.Controls.CheckBox; $ccb.IsChecked=$true; $ccb.VerticalAlignment='Center'
            if($c.Data.Action.kind -eq 'service'){
                $currentStart=Get-ServiceStartValue $c.Data.Action.name
                $targetStart=$script:StartMap[[string]$c.Data.Action.start]
                if($null -ne $currentStart -and $null -ne $targetStart -and $currentStart -eq $targetStart){$ccb.IsChecked=$false}
            }
            if($c.Data.Action.kind -eq 'task'){
                $currentTask=Get-ScheduledTask -TaskPath $c.Data.Action.path -TaskName $c.Data.Action.name -ErrorAction SilentlyContinue
                if($currentTask){$isDisabled=($currentTask.State -eq 'Disabled'); $shouldDisable=(-not [bool]$c.Data.Action.enable); if($isDisabled -eq $shouldDisable){$ccb.IsChecked=$false}}
            }
            $ct = New-Object Windows.Controls.TextBlock; $ct.Text=$c.Label; $ct.Margin='6,0,0,0'
            $ct.Foreground=$script:Window.FindResource('SubText'); $ct.VerticalAlignment='Center'
            [void]$ch.Children.Add($ccb); [void]$ch.Children.Add($ct)
            $ci.Header=$ch
            [void]$item.Items.Add($ci)
            $childChecks += @{ Check=$ccb; Data=$c }
        }
        if ($childChecks.Count -gt 0) { $cb.IsChecked = (@($childChecks | Where-Object { $_.Check.IsChecked }).Count -gt 0) }
        $parentCheck = $cb
        $childRef = $childChecks
        $cb.Add_Click({ foreach($child in $childRef){$child.Check.IsChecked=[bool]$parentCheck.IsChecked} }.GetNewClosure())
        foreach($child in $childChecks){
            $childBox=$child.Check
            $childBox.Add_Click({
                $parentCheck.IsChecked=(@($childRef | Where-Object {$_.Check.IsChecked}).Count -gt 0)
            }.GetNewClosure())
        }
        [void]$tree.Items.Add($item)
        $nodes += @{ Parent=$cb; Tweak=$t; Choice=$p.Choice; TargetApplied=[bool]$p.TargetApplied; Children=$childChecks }
    }
    foreach($candidate in $Apps){
        $item=New-Object Windows.Controls.TreeViewItem
        $head=New-Object Windows.Controls.StackPanel; $head.Orientation='Horizontal'
        $cb=New-Object Windows.Controls.CheckBox; $cb.IsChecked=$true; $cb.VerticalAlignment='Center'
        $txt=New-Object Windows.Controls.TextBlock
        $kindLabel=if($candidate.Kind -eq 'program'){'desktop program'}else{'Microsoft app'}
        $suffix=if($candidate.AllowUnsupportedStoreRemoval){' (Microsoft does not support Store removal)'}else{''}
        $txt.Text=("{0}  ({1}){2}" -f $candidate.Label,$kindLabel,$suffix); $txt.Margin='6,0,0,0'
        $txt.Foreground=$script:Window.FindResource('Text'); $txt.VerticalAlignment='Center'
        [void]$head.Children.Add($cb); [void]$head.Children.Add($txt)
        $item.Header=$head
        [void]$tree.Items.Add($item)
        $appNodes+=@{Check=$cb;Candidate=$candidate}
    }
 
    $rp = New-Object Windows.Controls.CheckBox
    $rp.Content='Create a restore point first'; $rp.IsChecked=[bool]$chkRestore.IsChecked; $rp.Margin='0,8,0,8'
    $rp.Foreground=$script:Window.FindResource('Text')
    [Windows.Controls.Grid]::SetRow($rp,2); [void]$grid.Children.Add($rp)
 
    $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation='Horizontal'; $btns.HorizontalAlignment='Right'
    $cancel = New-Object Windows.Controls.Button; $cancel.Content='Cancel'; $cancel.Margin='0,0,8,0'
    $apply = New-Object Windows.Controls.Button; $apply.Content='Apply'; $apply.Background=$script:Window.FindResource('Accent'); $apply.Foreground='White'; $apply.BorderBrush=$script:Window.FindResource('Accent')
    [void]$btns.Children.Add($cancel); [void]$btns.Children.Add($apply)
    [Windows.Controls.Grid]::SetRow($btns,3); [void]$grid.Children.Add($btns)
    $dlg.Content=$grid
 
    $dlg.Tag=@{Apps=@()}
    $cancel.Add_Click({ $dlg.DialogResult=$false; $dlg.Close() })
    $apply.Add_Click({
        $hvciNodes = @($nodes | Where-Object { $_.Parent.IsChecked -and (Test-HvciDisableRequest $_) })
        if ($hvciNodes.Count -gt 0) {
            $decision = Show-HvciWarningDialog -Owner $dlg
            switch ($decision) {
                'Enable' {
                    foreach ($node in $hvciNodes) {
                        $node.HvciOverride='Enable'
                        if ($script:Rows.ContainsKey($node.Tweak.Id) -and $script:Rows[$node.Tweak.Id].Combo) {
                            $script:Rows[$node.Tweak.Id].Combo.SelectedItem='On'
                        }
                    }
                }
                'Continue' { }
                'Skip' {
                    foreach ($node in $hvciNodes) {
                        $node.Parent.IsChecked=$false
                        if ($script:Rows.ContainsKey($node.Tweak.Id) -and $script:Rows[$node.Tweak.Id].Combo) {
                            $script:Rows[$node.Tweak.Id].Combo.SelectedIndex=0
                        }
                    }
                }
                default { return }
            }
        }
        $dlg.Tag=@{Apps=@($appNodes | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Candidate })}
        $dlg.DialogResult=$true; $dlg.Hide()
        Invoke-ApplySelected -Nodes $nodes -RestoreFirst ([bool]$rp.IsChecked)
        $dlg.Close()
    }.GetNewClosure())

    $confirmed=$dlg.ShowDialog()
    return @{Confirmed=($confirmed -eq $true);Apps=@($dlg.Tag.Apps)}
}
 
function Update-UiNow {
    param([string]$Status)
    try {
        if (-not $script:Window -or -not $script:Window.IsVisible) { return }
        if ($Status -and $script:StatusLabel) { $script:StatusLabel.Text = $Status }
        $frame = New-Object Windows.Threading.DispatcherFrame
        [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null },$frame)
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch { }
}
function Get-TweakChildren {
    param($Tweak,[bool]$TargetApplied=$true)
    $children = @()
    $actions = if($TargetApplied){@($Tweak.Apply)}else{@(Get-RevertActions $Tweak)}
    if (-not $TargetApplied -and @($actions | Where-Object { $_.kind -eq 'restoreRecords' }).Count) { return @() }
    foreach ($a in $actions) {
        switch ($a.kind) {
            'service'    { foreach($serviceName in (Resolve-ServiceNames $a.name)) { $act=$a.Clone(); $act.name=$serviceName; $children += @{ Label=$serviceName; Action=$act } } }
            'taskFolder' { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like ("{0}*" -f $a.path) } | ForEach-Object { $children += @{ Label=$_.TaskName; Action=@{kind='task';path=$_.TaskPath;name=$_.TaskName;enable=$a.enable} } } }
            'task'       { if (Get-ScheduledTask -TaskPath $a.path -TaskName $a.name -ErrorAction SilentlyContinue) { $children += @{ Label=$a.name; Action=$a } } }
            'taskNamePattern' { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $taskName=$_.TaskName; $a.patterns | Where-Object { $taskName -like $_ } } | ForEach-Object { $children += @{ Label=("{0}{1}" -f $_.TaskPath,$_.TaskName); Action=@{kind='task';path=$_.TaskPath;name=$_.TaskName;enable=$a.enable} } } }
            'dxApp' { $children += @{ Label=[IO.Path]::GetFileName([string]$a.exe); Action=$a } }
            'throttleApp' { $children += @{ Label=[IO.Path]::GetFileName([string]$a.exe); Action=$a } }
            'msiMode' { if ($a.enable) { foreach ($m in @(Get-MsiTargets -WithMode)) { $children += @{ Label=('{0} ({1}, {2})' -f $m.Name,$m.Class,$(if ($m.Mode) { $m.Mode } else { 'mode unknown' })); Action=@{kind='msiMode';enable=$true;instance=$m.InstanceId} } } } }
            'optionalFeature' { $features=Get-OptionalFeatureStates; foreach ($n in @($a.names | Where-Object { $features.ContainsKey($_) -and $features[$_] -in 1,2 })) { $children += @{ Label=$n; Action=@{kind='optionalFeature';names=@($n);enable=$a.enable} } } }
            default      { }
        }
    }
    return $children
}
 
function Get-ApplyWorkerParts {
    if ($script:ApplyWorkerParts) { return $script:ApplyWorkerParts }
    $file = (Get-Command Invoke-Action).ScriptBlock.File
    $skip = 'Write-Log','Update-UiNow'
    $known = @{}
    foreach ($f in @(Get-ChildItem -Path Function:)) { if ($f.ScriptBlock.File -eq $file) { $known[$f.Name] = $f.ScriptBlock } }
    $funcs = [ordered]@{}
    $queue = New-Object System.Collections.Queue
    foreach ($r in 'Invoke-Action','Save-OriginalRecords','Invoke-DropdownChoice','Set-HvciEnabledForAntiCheat','New-RestorePoint','Get-RevertActions','Get-RevertLabel','Test-HvciDisableAction','Get-TweakDetection') { $queue.Enqueue($r) }
    while ($queue.Count) {
        $name = [string]$queue.Dequeue()
        if ($funcs.Contains($name) -or $skip -contains $name -or -not $known.ContainsKey($name)) { continue }
        $funcs[$name] = $known[$name]
        foreach ($c in $known[$name].Ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] },$true)) {
            $cn = $c.GetCommandName()
            if ($cn -and $known.ContainsKey($cn) -and -not $funcs.Contains($cn)) { $queue.Enqueue($cn) }
        }
    }
    $uiVars = 'Window','StatusLabel','Rows','LogPath'
    $vars = @{}
    $text = New-Object System.Text.StringBuilder
    foreach ($name in $funcs.Keys) {
        [void]$text.AppendLine(("function {0} {{ {1} }}" -f $name,$funcs[$name]))
        foreach ($v in $funcs[$name].Ast.FindAll({ param($x) $x -is [Management.Automation.Language.VariableExpressionAst] },$true)) {
            if ($v.VariablePath.IsScript) { $n = $v.VariablePath.UserPath -replace '^script:',''; if ($uiVars -notcontains $n) { $vars[$n] = $true } }
        }
    }
    $script:ApplyWorkerParts = @{ Functions=$text.ToString(); Vars=@($vars.Keys | Sort-Object) }
    return $script:ApplyWorkerParts
}

$script:ApplyWorkerBody = @'
function Write-Log {
    param([Parameter(Mandatory)][string]$Message,[ValidateSet('Info','Action','Success','Warn','Error')][string]$Level = 'Info')
    $applyQueue.Enqueue(@{ Kind='log'; Message=$Message; Level=$Level })
}
foreach ($k in @($applyVars.Keys)) { Set-Variable -Name $k -Value $applyVars[$k] -Scope Script }
$script:Rows = @{}
try {
    Write-Log 'Applying selected settings...' 'Action'
    if ($applyRestore) { New-RestorePoint | Out-Null }
    $nodeIndex = 0; $nodeTotal = @($applyJobs).Count
    foreach ($n in $applyJobs) {
        $nodeIndex++
        $applyQueue.Enqueue(@{ Kind='status'; Text=('Applying {0} of {1}: {2}' -f $nodeIndex,$nodeTotal,$n.Tweak.Label) })
        if ($n.ChildCount -gt 0) {
            if (-not @($n.Children).Count) { continue }
        } elseif (-not $n.Selected) { continue }
        $t = $n.Tweak
        $operationText = if ($n.TargetApplied) { ("{0} {1}" -f $t.ApplyVerb,$t.Label) } else { (Get-RevertLabel $t.Label) }
        Write-Log ("{0}..." -f $operationText) 'Action'
        try {
            $hvciReenabled = $false
            if ($n.HvciOverride -eq 'Enable') {
                Set-HvciEnabledForAntiCheat
                $hvciReenabled = $true
            }
            if ($hvciReenabled -and $t.Id -eq 'sec.vbs') {
            } elseif ($n.ChildCount -gt 0) {
                foreach ($a in @($n.Children)) {
                    if ($n.TargetApplied) { Save-OriginalRecords -Id $t.Id -Actions @($a) }
                    Invoke-Action $a
                }
                $childKinds = 'service','taskFolder','task','taskNamePattern','dxApp','throttleApp','msiMode','optionalFeature'
                $loose = @($(if ($n.TargetApplied) { @($t.Apply) } else { @(Get-RevertActions $t) }) | Where-Object { $childKinds -notcontains $_.kind })
                if ($n.TargetApplied -and $loose.Count) { Save-OriginalRecords -Id $t.Id -Actions $loose }
                foreach ($a in $loose) { Invoke-Action $a }
            } elseif ($t.Type -eq 'dropdown' -and $n.Choice) {
                Save-OriginalRecords -Id $t.Id -Actions @(@{kind='dropdownState';id=$t.Id})
                Invoke-DropdownChoice -Tweak $t -Choice $n.Choice
            } else {
                $actions = if ($n.TargetApplied) { @($t.Apply) } else { @(Get-RevertActions $t) }
                if ($hvciReenabled) { $actions = @($actions | Where-Object { -not (Test-HvciDisableAction $_) }) }
                if ($n.TargetApplied) { Save-OriginalRecords -Id $t.Id -Actions $actions }
                foreach ($a in $actions) { Invoke-Action $a }
            }
            if ($hvciReenabled -or ($t.Id -eq 'sec.vbs' -and [string]$n.Choice -eq 'On')) { $applyQueue.Enqueue(@{ Kind='hvci' }) }
            $doneVerb = if ($hvciReenabled) { 'Enabled HVCI and skipped the selected HVCI disable request' } elseif ($n.TargetApplied) { $t.DoneVerb } else { 'Restored original setting' }
            Write-Log $doneVerb 'Success'
        } catch {
            Write-Log ("Failed: {0} - {1}" -f $t.Label, $_.Exception.Message) 'Error'
        }
    }
    Write-Log 'Done. A restart is recommended for service changes.' 'Success'
    $applyQueue.Enqueue(@{ Kind='status'; Text='Reading the changed settings...' })
    try { $applySync.Fresh = Get-TweakDetection -Tweaks $applyRescan -Env $script:Env }
    catch { Write-Log ("Could not refresh setting status: {0}" -f $_.Exception.Message) 'Warn' }
} catch {
    Write-Log ("Apply stopped: {0}" -f $_.Exception.Message) 'Error'
} finally {
    $back = @{}
    foreach ($k in @($applyVars.Keys)) { $back[$k] = Get-Variable -Name $k -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
    $applySync.Vars = $back
    $applySync.Done = $true
}
'@

function Receive-ApplyMessages {
    $run = $script:ApplyRun
    if (-not $run) { return }
    $m = $null
    while ($run.Queue.TryDequeue([ref]$m)) {
        switch ([string]$m.Kind) {
            'log' { Write-Log $m.Message $m.Level }
            'status' { if ($script:StatusLabel) { $script:StatusLabel.Text = [string]$m.Text } }
            'hvci' {
                if ($script:Rows.ContainsKey('sec.vbs')) {
                    $entry = $script:Rows['sec.vbs']
                    if ($entry.Combo) { $entry.Combo.SelectedItem = 'On' }
                    if ($entry.Status) { $entry.Status.Text = 'Configured On; restart required' }
                }
            }
        }
    }
}

function Complete-ApplyRun {
    $run = $script:ApplyRun
    if (-not $run) { return }
    $run.Timer.Stop()
    try {
        Receive-ApplyMessages
        try { [void]$run.Ps.EndInvoke($run.Async) } catch { Write-Log ("Apply worker error: {0}" -f $_.Exception.Message) 'Error' }
        foreach ($err in @($run.Ps.Streams.Error)) { Write-Log ("Apply worker error: {0}" -f $err) 'Warn' }
        if ($run.Sync.Vars) {
            foreach ($k in @($run.Sync.Vars.Keys)) {
                $current = Get-Variable -Name $k -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                if (-not [object]::ReferenceEquals($current,$run.Sync.Vars[$k])) { Set-Variable -Name $k -Value $run.Sync.Vars[$k] -Scope Script }
            }
        }
        Clear-DetectionCaches
        try {
            if ($run.Sync.Fresh) {
                foreach ($k in $run.Sync.Fresh.Keys) { $script:Detection[$k] = $run.Sync.Fresh[$k] }
                Apply-Detection
                Save-DetectionCache
                $script:Window.Dispatcher.BeginInvoke([action]{ try { Update-HomeHealth } catch { } },[Windows.Threading.DispatcherPriority]::Background) | Out-Null
            }
        } catch { Write-Log ("Could not refresh setting status: {0}" -f $_.Exception.Message) 'Warn' }
    } finally {
        try { $run.Ps.Dispose(); $run.Runspace.Close(); $run.Runspace.Dispose() } catch { }
        foreach ($e in $script:Rows.Values) { $e.Touched = $false }
        foreach ($b in @($ApplyBtn,$PresetCombo)) { $b.IsEnabled = $true }
        $script:ApplyRun = $null
        $run.Frame.Continue = $false
    }
}

function Invoke-ApplySelected {
    param($Nodes,[bool]$RestoreFirst)
    if ($script:ApplyRun) { Write-Log 'An apply is already running.' 'Warn'; return }
    foreach ($b in @($ApplyBtn,$PresetCombo)) { $b.IsEnabled = $false }
    $started = $false
    try {
        $jobs = @(foreach ($n in @($Nodes)) {
            @{
                Tweak=$n.Tweak; Choice=$n.Choice; TargetApplied=[bool]$n.TargetApplied; HvciOverride=[string]$n.HvciOverride
                Selected=[bool]$n.Parent.IsChecked; ChildCount=@($n.Children).Count
                Children=@(@($n.Children) | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Data.Action })
            }
        })
        $changedIds = @($jobs | ForEach-Object { $_.Tweak.Id } | Select-Object -Unique)
        $rescan = @($script:Tweaks | Where-Object { $changedIds -contains $_.Id })
        $parts = Get-ApplyWorkerParts
        $vars = @{}
        foreach ($k in $parts.Vars) { $var = Get-Variable -Name $k -Scope Script -ErrorAction SilentlyContinue; if ($var) { $vars[$k] = $var.Value } }
        $run = @{
            Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            Sync = [hashtable]::Synchronized(@{ Done=$false; Fresh=$null; Vars=$null })
            Frame = New-Object Windows.Threading.DispatcherFrame
            Timer = New-Object Windows.Threading.DispatcherTimer
            Runspace = [runspacefactory]::CreateRunspace()
        }
        $run.Runspace.ApartmentState = 'MTA'
        $run.Runspace.Open()
        foreach ($pair in @(@('applyQueue',$run.Queue),@('applySync',$run.Sync),@('applyVars',$vars),@('applyJobs',$jobs),@('applyRestore',$RestoreFirst),@('applyRescan',$rescan))) { $run.Runspace.SessionStateProxy.SetVariable($pair[0],$pair[1]) }
        $run.Ps = [powershell]::Create()
        $run.Ps.Runspace = $run.Runspace
        [void]$run.Ps.AddScript($parts.Functions + "`n" + $script:ApplyWorkerBody)
        $run.Timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $run.Timer.Add_Tick({ Receive-ApplyMessages; if ($script:ApplyRun -and $script:ApplyRun.Sync.Done) { Complete-ApplyRun } })
        $script:ApplyRun = $run
        $run.Async = $run.Ps.BeginInvoke()
        $run.Timer.Start()
        $started = $true
        [Windows.Threading.Dispatcher]::PushFrame($run.Frame)
    } catch {
        Write-Log ("Apply could not start: {0}" -f $_.Exception.Message) 'Error'
    } finally {
        if (-not $started) {
            if ($script:ApplyRun) { try { $script:ApplyRun.Runspace.Close() } catch { }; $script:ApplyRun = $null }
            foreach ($b in @($ApplyBtn,$PresetCombo)) { $b.IsEnabled = $true }
        }
    }
}
 
function Invoke-DropdownChoice {
    param($Tweak,[string]$Choice)
    switch ($Tweak.Id) {
        'net.dns' {
            $servers = switch ($Choice) { 'Cloudflare (1.1.1.1)' {@('1.1.1.1','1.0.0.1')} 'Google (8.8.8.8)' {@('8.8.8.8','8.8.4.4')} default {$null} }
            Invoke-Action @{kind='setDns';servers=$servers}
        }
        'net.autotune' { $v=switch($Choice){'Normal'{'normal'}'Disabled'{'disabled'}default{'Default'}}; Invoke-Action @{kind='tcpAutoTune';value=$v} }
        'net.doh' { Invoke-Action @{kind='dnsDoh';value=$Choice} }
        'net.qos.bandwidth' { Invoke-Action @{kind='deliveryBandwidth';value=$Choice} }
        'gpu.hags' { $v = switch ($Choice) {'On'{2}'Off'{1}default{'Default'}}; Invoke-Action @{kind='hardwareGpu';value=$v} }
        'gpu.gamemode' { Invoke-Action @{kind='gameMode';value=$Choice} }
        'cpu.boost' { $v=switch($Choice){'Enabled'{1}'Aggressive'{2}'Disabled'{0}default{'Default'}}; Invoke-Action @{kind='powerValue';alias='PERFBOOSTMODE';value=$v} }
        'cpu.plan' {
            if (-not (Initialize-PowerApi)) { throw 'The Windows power plan API is unavailable.' }
            if ($Choice -eq $script:RionPlanName) {
                [void](Install-RionPowerPlan)
            } elseif ($Choice -eq 'Default') {
                return
            } else {
                $template = $script:PowerTemplates[$Choice]
                if (-not $template) { $template = $script:PowerTemplates['Balanced'] }
                $plans = @(Get-PowerPlans)
                $target = @($plans | Where-Object { $_.Guid -eq $template } | Select-Object -First 1)
                if (-not $target) { $target = @($plans | Where-Object { $_.Name -eq $Choice } | Select-Object -First 1) }
                $guid = if ($target) { [string]$target[0].Guid } else { Copy-PowerPlan -SourceGuid $template }
                if (-not $guid) { throw ("Windows does not offer the {0} plan on this PC. Modern Standby laptops only expose Balanced; use Windows Settings > Power mode instead." -f $Choice) }
                Set-ActivePowerPlan $guid
                Write-Log ("Power plan switched to {0}." -f [RionPowrProf]::Name($guid,$null,$null)) 'Success'
            }
        }
        'sec.vbs'  {
            if ($Choice -eq 'Default') {
                Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled'
            } elseif ($Choice -eq 'On') {
                Set-HvciEnabledForAntiCheat
            } else {
                Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 0 -Type 'DWord'
            }
        }
        'app.discord.hwaccel' { Set-DiscordHwAccel -Choice $Choice }
        default { }
    }
}
 
function Set-DiscordHwAccel {
    param([string]$Choice)
    if ($Choice -eq 'Default') { return }
    $f = Join-Path $env:APPDATA 'discord\settings.json'
    if (-not (Test-Path $f)) { return }
    try {
        $json = Get-Content $f -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName 'enableHardwareAcceleration' -NotePropertyValue ($Choice -eq 'On') -Force
        $json | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding UTF8
    } catch { }
}
 
$ApplyBtn.Add_Click({
    $script:LastApplyOutcome = 'cancelled'
    $curTab = if ($Tabs.SelectedItem.Tag -is [string]) { [string]$Tabs.SelectedItem.Tag } else { [string]$Tabs.SelectedItem.Header }
    if ($curTab -eq 'Games') { try { Save-AllGames } catch { Write-Log ('Game settings: save failed: {0}' -f $_.Exception.Message) 'Error' }; return }
    $pending = @(Get-PendingTweaks)
    Write-Log ("Apply: {0} change(s) pending; {1} rows ticked" -f $pending.Count,@($script:Rows.Values | Where-Object { $_.Check -and $_.Check.IsChecked }).Count) 'Info'
    $appPending=@($script:DebloatChecks + $script:ProgramChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $reinstallPending=@($script:ReinstallChecks | Where-Object { $_.IsChecked })
    if ($reinstallPending.Count) { try { Invoke-AppReinstall $reinstallPending } catch { Write-Log ('Reinstall failed: {0}' -f $_.Exception.Message) 'Error' }; if ($pending.Count -eq 0 -and $appPending.Count -eq 0) { return } }
    if ($pending.Count -eq 0 -and $appPending.Count -eq 0) {
        $script:LastApplyOutcome = 'nothing'
        if (Test-GamesPending) { try { Save-AllGames } catch { Write-Log ('Game settings: save failed: {0}' -f $_.Exception.Message) 'Error' }; return }
        [System.Windows.MessageBox]::Show("Nothing to change. Ticked settings are already applied.`r`n`r`nTick a setting to apply it, or untick an applied one to restore its original value.",'Rion Tool','OK','Information') | Out-Null
        return
    }
    if(@($script:PagePresets.Values) -contains 'Max (incl. Risky)' -and ($appPending.Count -gt 0 -or $pending.Count -gt 0)){
        if($script:DebloatSelectionProfile -eq 'Max (incl. Risky)'){
            $msg="The Maximum profile will attempt to remove every removable Microsoft packaged app found for this user, including Microsoft Store and Xbox. Settings, Photos, Media Player, and Snipping Tool are kept; Windows system or non-removable packages are skipped.`r`n`r`nMicrosoft does not support removing Microsoft Store, so Windows may refuse that removal and Store-based install or repair flows may stop working. Any desktop programs you checked are also listed for review. Carefully review the Apply list before continuing.`r`n`r`nContinue with the Maximum profile?"
        }else{
            $msg="The Maximum preset is selected for Windows settings. Applying will apply the selected Maximum system changes; app removals will be limited to the apps shown in the Apply list.`r`n`r`nReview the risk labels and app list carefully before continuing. Continue with the Maximum preset?"
        }
        $r=[System.Windows.MessageBox]::Show($msg,'Maximum debloat profile','OKCancel','Warning')
        if($r -ne 'OK'){return}
    }
    $hasNet = @($pending | Where-Object { $script:NoPreset -contains $_.Tweak.Id })
    if ($hasNet.Count -gt 0) {
        $names = ($hasNet | ForEach-Object { $_.Tweak.Label }) -join ', '
        $msg = "You selected a network adapter disable: $names`r`n`r`nThis cuts that connection until you re-enable it (Features tab, or Fixes > Re-enable network adapters). If this is your only connection you will lose internet access.`r`n`r`nContinue?"
        $r = [System.Windows.MessageBox]::Show($msg,'Disable network adapters','OKCancel','Warning')
        if ($r -ne 'OK') { return }
    }
    $hasDefender = $pending | Where-Object { $_.Tweak.Id -eq 'sec.defender' }
    if ($hasDefender) {
        $msg = "Disabling Defender requires Tamper Protection to be OFF first.`r`n`r`nClick OK to open Windows Security > Virus & threat protection. Turn Tamper Protection off, then return and click Apply in the dialog."
        $r = [System.Windows.MessageBox]::Show($msg,'Tamper Protection required','OKCancel','Warning')
        if ($r -eq 'OK') { Start-Process 'windowsdefender://threatsettings' } else { return }
    }
    $hasDecrypt = @($pending | Where-Object { $_.Tweak.Id -eq 'sec.encryption.decrypt' })
    if ($hasDecrypt.Count) {
        $msg = "You selected system-drive decryption. BitLocker protection will be removed from $env:SystemDrive and decryption will continue in the background. Rion cannot automatically re-enable encryption because that may require a recovery key. Continue?"
        $r = [System.Windows.MessageBox]::Show($msg,'Decrypt system drive','OKCancel','Warning')
        if ($r -ne 'OK') { return }
    }
    $applyResult=Show-ApplyDialog -Pending $pending -Apps $appPending
    if(-not $applyResult.Confirmed){return}
    $script:LastApplyOutcome = 'applied'
    if($applyResult.Apps.Count){Invoke-DebloatApply -Candidates $applyResult.Apps -Reviewed -RestoreHandled}
})

 
 
function Invoke-FullRevert {
    foreach ($id in @($script:Journal.Keys)) {
        $t = $script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        $actions = if ($t) { @(Get-RevertActions $t) } else { @(@{ kind='restoreRecords'; id=$id }) }
        try {
            Write-Log ("Reverting {0}..." -f $(if ($t) { $t.Label } else { $id })) 'Action'
            foreach ($a in $actions) { Invoke-Action $a }
        } catch { Write-Log ("Revert failed: {0} - {1}" -f $id,$_.Exception.Message) 'Warn' }
    }
    foreach ($name in @($script:ServiceBackups.Keys)) {
        try {
            $key="HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            if (Test-Path $key) { Set-ServiceStartNow -Name $name -Start ([int]$script:ServiceBackups[$name]) }
        } catch { Write-Log ("Could not restore service start type for {0}" -f $name) 'Warn' }
    }
    $script:ServiceBackups.Clear()
    try {
        if (Initialize-PowerApi) {
            Read-PowerJournal
            $plans = @(Get-PowerPlans | ForEach-Object { $_.Guid })
            $journalPlans = @($script:PowerJournal.Keys | Where-Object { $_ -like 'value|*' -or $_ -like 'text|*' } | ForEach-Object { ($_ -split '\|')[1] } | Select-Object -Unique)
            foreach ($p in $journalPlans) {
                if ($plans -notcontains $p) { continue }
                $r = Restore-PowerPlanChanges $p
                Write-Log ("Power plan {0}: restored {1} setting(s), {2} failed." -f [RionPowrProf]::Name($p,$null,$null),$r.Restored,$r.Failed) 'Success'
            }
            if ($script:PowerJournal.ContainsKey('overlay')) {
                if ([RionPowrProf]::SetOverlay([string]$script:PowerJournal['overlay']) -eq 0) { $script:PowerJournal.Remove('overlay'); Save-PowerJournal; Write-Log 'Windows power mode restored.' 'Success' }
            }
            if (@($script:PowerJournal.Keys | Where-Object { $_ -like 'attr|*' }).Count) { [void](Set-PowerSettingsVisibility -Show $false); Write-Log 'Hidden power settings hidden again in Control Panel.' 'Success' }
        }
    } catch { Write-Log ("Power plan revert failed: {0}" -f $_.Exception.Message) 'Warn' }
    if (Test-Path -LiteralPath $script:NvidiaStatePath) {
        try { Invoke-NvidiaNipImport 'Defaults' } catch { Write-Log ("NVIDIA profile revert failed: {0}" -f $_.Exception.Message) 'Warn' }
    }
}

function Build-DebloatList {
    param([bool]$AutoCheck,[bool]$ApplyPreset=$true)
    $dStoreList.Children.Clear(); $dProgramList.Children.Clear()
    $script:DebloatChecks = @(); $script:ProgramChecks = @()
    $storeHeader = New-Object Windows.Controls.TextBlock; $storeHeader.Text='Installed Store apps for this user, including apps Windows installs or pins on its own (tick to remove). WhatsApp, LinkedIn and other tiles in Start that are not listed here are install links, not installed apps: right-click them in Start and choose Unpin. Names come from this Windows installation. Windows components, frameworks, and WinGet catalogs are not apps in this list. Recommendations are apps Windows preinstalls or promotes that nothing else depends on; they only appear when installed and removable here. Removed apps can be reinstalled from Microsoft Store.'; Set-ThemeBrush $storeHeader 'Foreground' 'SubText'; $storeHeader.Margin='0,0,0,8'; $storeHeader.TextWrapping='Wrap'
    [void]$dStoreList.Children.Add($storeHeader)

    $script:DebloatChecks = @()
    $installed = @()
    try { $installed = @(Get-AppxPackage -PackageTypeFilter Main -ErrorAction Stop | Sort-Object Name -Unique) } catch { Write-Log ('Store app list: Get-AppxPackage failed ({0}); reading installed apps from the package registry instead.' -f $_.Exception.Message) 'Warn' }
    if (-not $installed.Count) {
        $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
        $installed = @(Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue | ForEach-Object {
            $parts = $_.PSChildName -split '_'
            if ($parts.Count -ge 5 -and $parts[3] -eq '') { [pscustomobject]@{ Name=$parts[0]; PackageFamilyName=($parts[0] + '_' + $parts[-1]); PackageFullName=$_.PSChildName; Publisher=$(if ($parts[0] -match '^(Microsoft|MicrosoftWindows|MicrosoftCorporationII|Clipchamp)\.') { 'CN=Microsoft Corporation' } else { '' }); SignatureKind='Store'; NonRemovable=$false } }
        } | Sort-Object Name -Unique)
        Write-Log ('Store app list read {0} installed app(s) from the package registry.' -f $installed.Count) 'Info'
    }
    $startNamesByFamily = @{}
    try {
        foreach($startApp in @(Get-StartApps -ErrorAction SilentlyContinue)) {
            $appId=[string]$startApp.AppID
            if($appId -match '^([^!]+)!' -and $startApp.Name) {
                $family=$Matches[1]
                if(-not $startNamesByFamily.ContainsKey($family)){$startNamesByFamily[$family]=@()}
                $startNamesByFamily[$family]+=([string]$startApp.Name)
            }
        }
    } catch { }
    $knownApps = @()
    foreach ($app in $installed) {
        $appx=[string]$app.Name
        if(-not $appx) { continue }
        $isMicrosoft=($app.Publisher -match '(?i)Microsoft' -or $appx -in $script:AutoDebloatApps)
        $isPromoted=[bool]@($script:PromotedStoreApps | Where-Object { $appx -like $_ }).Count
        $family=[string]$app.PackageFamilyName
        if(-not $family -or -not $startNamesByFamily.ContainsKey($family)) { continue }
        $label=(@($startNamesByFamily[$family] | Where-Object { $_ } | Select-Object -Unique) -join ', ')
        if(-not $label) { continue }
        $systemPackage=([string]$app.SignatureKind -eq 'System')
        $windowsNonRemovable=([bool]$app.NonRemovable -or $systemPackage)
        $storeRemovalUnsupported=($appx -eq 'Microsoft.WindowsStore')
        $notRemovable=($windowsNonRemovable -or $storeRemovalUnsupported)
        $isCore=($script:KeepApps -contains $appx)
        $recommended=(!$notRemovable -and -not $isCore -and ($appx -in $script:AutoDebloatApps -or $isPromoted))
        $knownApps += @{Package=$appx;Label=$label;IsCore=$isCore;NotRemovable=$notRemovable;WindowsNonRemovable=$windowsNonRemovable;StoreRemovalUnsupported=$storeRemovalUnsupported;Recommended=$recommended;ThirdParty=(-not $isMicrosoft)}
    }
    foreach($group in @(
        @{Title='Auto Debloat recommendations (preinstalled or promoted apps; selected by Auto Debloat)'; Apps=@($knownApps | Where-Object { $_.Recommended } | Sort-Object { $_.Label })},
        @{Title='Other installed Microsoft apps (not selected automatically)'; Apps=@($knownApps | Where-Object { -not $_.Recommended -and -not $_.ThirdParty } | Sort-Object { $_.Label })},
        @{Title='Other Store apps from third parties and PC makers (not selected automatically; some PC-maker apps control fans, batteries or hotkeys)'; Apps=@($knownApps | Where-Object { -not $_.Recommended -and $_.ThirdParty } | Sort-Object { $_.Label })}
    )) {
        if(-not $group.Apps.Count){continue}
        $groupHeader=New-Object Windows.Controls.TextBlock; $groupHeader.Text=$group.Title; Set-ThemeBrush $groupHeader 'Foreground' 'SubText'; $groupHeader.Margin='0,10,0,4'; $groupHeader.FontWeight='SemiBold'; $groupHeader.TextWrapping='Wrap'
        [void]$dStoreList.Children.Add($groupHeader)
        $groupGrid=New-Object Windows.Controls.Primitives.UniformGrid; $groupGrid.Columns=2
        [void]$dStoreList.Children.Add($groupGrid)
        foreach($entry in $group.Apps){
            $cb = New-Object Windows.Controls.CheckBox; $cb.Content=$entry.Label; $cb.Margin='0,2,0,2'; $cb.ToolTip=$entry.Package
            $cb.IsChecked = ($AutoCheck -and $entry.Recommended)
            $cb.Tag=@{Kind='appx';Name=$entry.Package;Label=$entry.Label;Recommended=[bool]$entry.Recommended;ThirdParty=[bool]$entry.ThirdParty;WindowsNonRemovable=$entry.WindowsNonRemovable;StoreRemovalUnsupported=$entry.StoreRemovalUnsupported;AllowUnsupportedStoreRemoval=$false}
            if($entry.NotRemovable){
                $cb.IsEnabled=$false
                $reason=if($entry.StoreRemovalUnsupported){'Microsoft does not support removing the Store app; Maximum can attempt it if Windows marks the package removable.'}else{'Windows marks this package as a system or non-removable app.'}
                $cb.ToolTip=('{0} ({1})' -f $entry.Package,$reason)
                if($entry.WindowsNonRemovable){$cb.Content=('{0} (system app)' -f $entry.Label)}
                [Windows.Controls.ToolTipService]::SetShowOnDisabled($cb,$true)
            }
            [void]$groupGrid.Children.Add($cb); $script:DebloatChecks += $cb
        }
    }
    if ($knownApps.Count -eq 0) {
        $none = New-Object Windows.Controls.TextBlock; $none.Text='No removable Store apps with Start menu entries were found for this user.'; Set-ThemeBrush $none 'Foreground' 'Muted'
        [void]$dStoreList.Children.Add($none)
    }
    $installedNames = @($installed | ForEach-Object { [string]$_.Name })
    $missingApps = @($script:ReinstallCatalog | Where-Object { -not @($_.Packages | Where-Object { $installedNames -contains $_ }).Count } | Sort-Object { $_.Name })
    $script:ReinstallChecks = @()
    if ($missingApps.Count) {
        $missHeader=New-Object Windows.Controls.TextBlock; $missHeader.Text='Not installed: Microsoft apps missing from this PC (tick to reinstall, then click Apply)'; Set-ThemeBrush $missHeader 'Foreground' 'SubText'; $missHeader.Margin='0,10,0,4'; $missHeader.FontWeight='SemiBold'; $missHeader.TextWrapping='Wrap'
        [void]$dStoreList.Children.Add($missHeader)
        $missGrid=New-Object Windows.Controls.Primitives.UniformGrid; $missGrid.Columns=2
        [void]$dStoreList.Children.Add($missGrid)
        foreach ($app in $missingApps) {
            $rcb = New-Object Windows.Controls.CheckBox; $rcb.Content=$app.Name; $rcb.Margin='0,2,0,2'; $rcb.Tag=$app
            $rcb.ToolTip=('Reinstalls {0} ({1}) from files on this PC or from the Microsoft Store catalog with WinGet.' -f $app.Name,($app.Packages -join ', '))
            [void]$missGrid.Children.Add($rcb); $script:ReinstallChecks += $rcb
            $script:SearchItems += @{ Row=$rcb; Text=('reinstall {0}' -f $app.Name); Tab='Debloat' }
        }
    }
    $programHeader=New-Object Windows.Controls.TextBlock; $programHeader.Text='Program apps (Win32 uninstall entries; check only software you intentionally want removed)'; Set-ThemeBrush $programHeader 'Foreground' 'SubText'; $programHeader.Margin='0,14,0,8'; $programHeader.FontWeight='SemiBold'
    [void]$dProgramList.Children.Add($programHeader)
    $programGrid=New-Object Windows.Controls.Primitives.UniformGrid; $programGrid.Columns=2
    [void]$dProgramList.Children.Add($programGrid)

    $programs=@(); $uninstallRoots=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach($root in $uninstallRoots){ try { $programs += Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName -and ($_.UninstallString -or $_.QuietUninstallString) } } catch{} }
    $programs=@($programs | Sort-Object DisplayName -Unique)
    foreach($program in $programs){
        $name=[string]$program.DisplayName; $protected=$false
        foreach($pattern in $script:KeepProgramPatterns){ if($name -like $pattern){$protected=$true;break} }
        $cb=New-Object Windows.Controls.CheckBox; $cb.Content=$name; $cb.Margin='0,2,0,2'; $cb.ToolTip=([string]$program.Publisher)
        $cb.IsChecked=$false; $cb.Tag=@{Kind='program';Name=$name;Label=$name;Uninstall=[string]$program.UninstallString;Quiet=[string]$program.QuietUninstallString}
        if($protected){$cb.IsEnabled=$true}
        [void]$programGrid.Children.Add($cb); $script:ProgramChecks += $cb
    }
    if(-not $programs.Count){$none=New-Object Windows.Controls.TextBlock; $none.Text='No installed Win32 programs were found.'; Set-ThemeBrush $none 'Foreground' 'Muted'; [void]$dProgramList.Children.Add($none)}
    if($ApplyPreset -and $script:PagePresets['Debloat']){Set-DebloatPreset -Preset ([string]$script:PagePresets['Debloat'])}
}

function Set-DebloatPreset {
    param([string]$Preset)
    $script:DebloatSelectionProfile=$Preset
    $isMax=($Preset -eq 'Max (incl. Risky)')
    $maxKeep=@(
        'Microsoft.Windows.Photos','Microsoft.ZuneMusic','Microsoft.WindowsMediaPlayer',
        'Microsoft.ScreenSketch','Microsoft.Windows.ImmersiveControlPanel','Microsoft.Windows.Settings'
    )
    foreach($cb in $script:DebloatChecks){
        $entry=$cb.Tag
        if(-not $entry -or $entry.Kind -ne 'appx'){continue}
        if($entry.StoreRemovalUnsupported){
            $cb.IsEnabled=$false
            $entry.AllowUnsupportedStoreRemoval=$false
            $cb.ToolTip="$($entry.Name) (Microsoft Store is always kept)"
        }
        $keepByLabel=([string]$entry.Label -match '(?i)^(Settings|Photos|Media Player|Snipping Tool|Notepad|Calculator|Terminal|Paint|Camera|Clock|Sound Recorder|Microsoft Store|Windows Security)$')
        $neverAuto=($script:NeverAutoRemove -contains [string]$entry.Name)
        $selected=switch($Preset){
            'Recommended' { [bool]$entry.Recommended }
            'Max (incl. Risky)' { ($cb.IsEnabled -and $entry.Name -notin $maxKeep -and -not $keepByLabel -and -not $neverAuto -and -not ($entry.ThirdParty -and -not $entry.Recommended)) }
            default { $false }
        }
        $cb.IsChecked=([bool]$selected -and [bool]$cb.IsEnabled)
    }
}
 
function Show-DebloatReview {
    param([object[]]$Candidates)
    $review = New-Object Windows.Window
    $review.Title='Review debloat selection'; $review.Width=560; $review.Height=600
    $review.MinWidth=420; $review.MinHeight=360; $review.ResizeMode='CanResize'
    $review.WindowStartupLocation='CenterOwner'; $review.Owner=$script:Window
    $review.Background=$script:Window.FindResource('Bg'); $review.Foreground=$script:Window.FindResource('Text')
    $layout=New-Object Windows.Controls.Grid; $layout.Margin='16'
    $headRow=New-Object Windows.Controls.RowDefinition; $headRow.Height='Auto'
    $listRow=New-Object Windows.Controls.RowDefinition; $listRow.Height='*'
    $buttonRow=New-Object Windows.Controls.RowDefinition; $buttonRow.Height='Auto'
    [void]$layout.RowDefinitions.Add($headRow); [void]$layout.RowDefinitions.Add($listRow); [void]$layout.RowDefinitions.Add($buttonRow)
    $intro=New-Object Windows.Controls.TextBlock
    $intro.Text='Review the proposed removals. Uncheck every app you want to keep. Nothing is removed until you choose Remove selected.'
    $intro.TextWrapping='Wrap'; $intro.Margin='0,0,0,12'; $intro.Foreground=$script:Window.FindResource('SubText')
    [Windows.Controls.Grid]::SetRow($intro,0); [void]$layout.Children.Add($intro)
    $list=New-Object Windows.Controls.StackPanel
    foreach($candidate in $Candidates){
        $check=New-Object Windows.Controls.CheckBox; $check.Content=$candidate.Label; $check.Tag=$candidate
        $check.IsChecked=$true; $check.Margin='0,3,0,3'; $check.ToolTip=[string]$candidate.Name
        [void]$list.Children.Add($check)
    }
    $scroll=New-Object Windows.Controls.ScrollViewer; $scroll.VerticalScrollBarVisibility='Auto'; $scroll.Content=$list
    [Windows.Controls.Grid]::SetRow($scroll,1); [void]$layout.Children.Add($scroll)
    $buttons=New-Object Windows.Controls.StackPanel; $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; $buttons.Margin='0,12,0,0'
    $cancel=New-Object Windows.Controls.Button; $cancel.Content='Cancel'; $cancel.MinWidth=90; $cancel.Margin='0,0,8,0'; $cancel.IsCancel=$true
    $remove=New-Object Windows.Controls.Button; $remove.Content='Remove selected'; $remove.MinWidth=120; $remove.IsDefault=$true
    [void]$buttons.Children.Add($cancel); [void]$buttons.Children.Add($remove)
    [Windows.Controls.Grid]::SetRow($buttons,2); [void]$layout.Children.Add($buttons)
    $review.Content=$layout
    $remove.Add_Click({
        $review.Tag=@($list.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        $review.DialogResult=$true
    }.GetNewClosure())
    $null=$review.ShowDialog()
    return @($review.Tag)
}

function Invoke-DebloatApply {
    param([object[]]$Candidates,[switch]$Reviewed,[switch]$RestoreHandled)
    if($PSBoundParameters.ContainsKey('Candidates')){$toRemove=@($Candidates)}else{$toRemove=@($script:DebloatChecks + $script:ProgramChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })}
    if (-not $toRemove) { [System.Windows.MessageBox]::Show('No apps selected to remove.','Rion Tool','OK','Information')|Out-Null; return }
    $invalid = @($toRemove | Where-Object { $_.Kind -notin @('appx','program') })
    if ($invalid.Count) { throw 'Debloat selection contained a non-app action. Nothing was changed.' }
    if(-not $Reviewed -and $script:DebloatSelectionProfile -eq 'Max (incl. Risky)'){
        $warning="The Maximum profile selects every optional Microsoft packaged app found for this user, including the Xbox app. Microsoft Store, App Installer, Windows Security, Notepad, Calculator, Terminal, Paint, Photos, Camera, Snipping Tool, Media Player, Clock, Sound Recorder, Settings, media codecs, and the Xbox sign-in and Gaming Services components are always kept. Windows system or non-removable packages are skipped.`r`n`r`nCarefully review the removal list before continuing.`r`n`r`nContinue with the Maximum profile?"
        $decision=[System.Windows.MessageBox]::Show($warning,'Maximum debloat profile','OKCancel','Warning')
        if($decision -ne 'OK'){return}
    }
    if(-not $Reviewed){$toRemove=Show-DebloatReview -Candidates $toRemove}
    if (-not $toRemove.Count) { return }
    if(-not $RestoreHandled){$rp=[System.Windows.MessageBox]::Show('Create a Windows restore point before removing these apps?','Debloat','YesNoCancel','Question'); if($rp -eq 'Cancel'){return}; if($rp -eq 'Yes'){New-RestorePoint|Out-Null}}
    foreach ($a in $toRemove) { try {
        Update-UiNow ('Removing {0}...' -f $a.Label)
        $verb = if ($a.Kind -eq 'program') { 'Uninstalling program' } else { 'Uninstalling Store app' }
        Write-Log ("{0}: {1}..." -f $verb,$a.Label) 'Action'
        if($a.Kind -eq 'appx'){ Invoke-Action @{kind='appx';name=$a.Name;AllowUnsupportedStoreRemoval=[bool]$a.AllowUnsupportedStoreRemoval;provisioned=[bool]$chkProvisioned.IsChecked} }
        elseif($a.Kind -eq 'program') { Invoke-ProgramUninstall $a }
        $done = if ($a.Kind -eq 'program') { 'Uninstalled program' } else { 'Uninstalled Store app' }
        Write-Log ("{0}: {1}" -f $done,$a.Label) 'Success'
    } catch { Write-Log ("Removal failed for {0}: {1}" -f $a.Label,$_.Exception.Message) 'Error' } }
}

function Invoke-ProgramUninstall {
    param($Program)
    $command=if($Program.Quiet){[string]$Program.Quiet}else{[string]$Program.Uninstall}
    if(-not $command){throw 'No uninstall command is registered for this program.'}
    if($command -match '(?i)msiexec(?:\.exe)?\s+.*?/i\s*(\{[0-9a-f-]+\})'){
        $proc=Start-Process msiexec.exe -ArgumentList @('/x',$Matches[1],'/qn','/norestart') -Wait -PassThru
    } else {
        $proc=Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/s','/c',$command) -Wait -PassThru
    }
    if ($proc.ExitCode -notin @(0,3010,1641)) { throw "Uninstaller returned exit code $($proc.ExitCode)." }
}
 
$btnScan.Add_Click({ Build-DebloatList -AutoCheck $false; Write-Log 'Rescanned installed apps' 'Success' })
$btnAuto.Add_Click({
    Build-DebloatList -AutoCheck $true -ApplyPreset:$false
    $script:DebloatSelectionProfile='Auto Debloat'
    $selected = @($script:DebloatChecks + $script:ProgramChecks | Where-Object { $_.IsChecked }).Count
    $debloatViews.SelectedItem=$dStoreTab
    Write-Log ("Auto debloat prepared {0} recommended Microsoft apps. Review and adjust the selection; nothing is removed until you confirm." -f $selected) 'Action'
    $candidates=@($script:DebloatChecks + $script:ProgramChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if(-not $candidates.Count){[System.Windows.MessageBox]::Show('No recommended Microsoft apps are installed and removable on this Windows installation.','Auto Debloat','OK','Information')|Out-Null;return}
    $applyResult=Show-ApplyDialog -Pending @() -Apps $candidates
    if($applyResult.Confirmed -and $applyResult.Apps.Count){Invoke-DebloatApply -Candidates $applyResult.Apps -Reviewed -RestoreHandled}
})
$btnDebApply.Add_Click({ Invoke-DebloatApply })
 
$openLog.Add_Click({ Start-Process explorer.exe $script:DataDir })
 
$script:IsDark = $true
$script:Palettes = @{
    Dark  = @{ Bg='#121318'; Panel='#181A20'; Border='#262A31'; Text='#D7DAE0'; SubText='#8A9099'; Accent='#5B7A99' }
    Light = @{ Bg='#F3F3F5'; Panel='#FFFFFF'; Border='#D9DADE'; Text='#1A1A1A'; SubText='#5F6368'; Accent='#3C5A78' }
}
function Set-Theme {
    param([bool]$Dark)
    $p = if ($Dark) { $script:Palettes.Dark } else { $script:Palettes.Light }
    foreach ($k in $p.Keys) {
        $color = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString([string]$p[$k])
        $brush = [Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $script:Window.Resources[$k] = $brush
    }
    $script:IsDark = $Dark
    Set-ThemeIcon
}

function Set-ThemeIcon {
    $data = if ($script:IsDark) {
        'M8,12 A4,4 0 1 1 16,12 A4,4 0 1 1 8,12 Z M12,2 L12,4 M12,20 L12,22 M2,12 L4,12 M20,12 L22,12 M4.9,4.9 L6.3,6.3 M17.7,17.7 L19.1,19.1 M4.9,19.1 L6.3,17.7 M17.7,6.3 L19.1,4.9'
    } else {
        'M12,3 A6,6 0 0 0 21,12 A9,9 0 1 1 12,3 Z'
    }
    $path = New-Object Windows.Shapes.Path
    $path.Data = [Windows.Media.Geometry]::Parse($data)
    $path.Stroke = $script:Window.FindResource('Text')
    $path.StrokeThickness = 2
    $path.StrokeLineJoin = 'Round'
    $path.StrokeStartLineCap = 'Round'
    $path.StrokeEndLineCap = 'Round'
    $canvas = New-Object Windows.Controls.Canvas
    $canvas.Width = 24; $canvas.Height = 24
    [void]$canvas.Children.Add($path)
    $box = New-Object Windows.Controls.Viewbox
    $box.Width = 16; $box.Height = 16
    $box.Child = $canvas
    $script:ThemeFooter.Content = $box
    $script:ThemeFooter.ToolTip = if ($script:IsDark) { 'Switch to light mode' } else { 'Switch to dark mode' }
}

$script:ThemeState = @{ Animating = $false }
function Invoke-ThemeToggle {
    if ($script:ThemeState.Animating) { return }
    $target = -not $script:IsDark
    $w = $RootGrid.ActualWidth; $h = $RootGrid.ActualHeight
    if ([bool]$chkReduce.IsChecked -or $w -le 0 -or $h -le 0) { Set-Theme $target; return }

    $scaleX = 1.0; $scaleY = 1.0
    try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($RootGrid); $scaleX = $dpi.DpiScaleX; $scaleY = $dpi.DpiScaleY } catch { }
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][math]::Ceiling($w * $scaleX)), ([int][math]::Ceiling($h * $scaleY)), (96 * $scaleX), (96 * $scaleY), ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($RootGrid)

    $snapshot = New-Object Windows.Controls.Image
    $snapshot.Source = $bmp
    $snapshot.Width = $w; $snapshot.Height = $h
    $snapshot.Stretch = 'Fill'
    $SplashLayer.Children.Clear()
    [void]$SplashLayer.Children.Add($snapshot)
    [Windows.Controls.Canvas]::SetLeft($snapshot, 0)
    [Windows.Controls.Canvas]::SetTop($snapshot, 0)

    $center = $script:ThemeFooter.TranslatePoint((New-Object Windows.Point ($script:ThemeFooter.ActualWidth / 2), ($script:ThemeFooter.ActualHeight / 2)), $RootGrid)
    $radius = 0.0
    foreach ($corner in @(@(0,0),@($w,0),@(0,$h),@($w,$h))) {
        $dx = $corner[0] - $center.X; $dy = $corner[1] - $center.Y
        $radius = [math]::Max($radius, [math]::Sqrt($dx * $dx + $dy * $dy))
    }

    $hole = New-Object Windows.Media.EllipseGeometry
    $hole.Center = $center; $hole.RadiusX = 0; $hole.RadiusY = 0
    $full = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, $w, $h)
    $snapshot.Clip = New-Object Windows.Media.CombinedGeometry ([Windows.Media.GeometryCombineMode]::Exclude), $full, $hole

    $script:ThemeState.Animating = $true
    Set-Theme $target

    $anim = New-Object Windows.Media.Animation.DoubleAnimation
    $anim.From = 0; $anim.To = $radius
    $anim.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(280))
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $anim.EasingFunction = $ease
    $layer = $SplashLayer
    $state = $script:ThemeState
    $anim.Add_Completed({ $layer.Children.Clear(); $state.Animating = $false }.GetNewClosure())
    $hole.BeginAnimation([Windows.Media.EllipseGeometry]::RadiusXProperty, $anim)
    $hole.BeginAnimation([Windows.Media.EllipseGeometry]::RadiusYProperty, $anim)
}

Set-ThemeIcon
$script:ThemeFooter.Add_Click({
    try { Invoke-ThemeToggle }
    catch {
        $script:ThemeState.Animating = $false
        $SplashLayer.Children.Clear()
        Write-Log ("Theme switch failed: {0}" -f $_.Exception.Message) 'Error'
    }
})
 
$script:Detection = @{}
 
$script:DetectionCachePath = Join-Path $script:DataDir 'detection-cache.json'
function Save-DetectionCache {
    try {
        if (-not $script:Detection) { return }
        @{ Build=$script:Build; At=(Get-Date).ToString('o'); Env=$script:Env; Detection=$script:Detection } | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $script:DetectionCachePath -Encoding UTF8
    } catch { }
}
function Read-DetectionCache {
    try {
        if (-not (Test-Path -LiteralPath $script:DetectionCachePath)) { return $false }
        $j = Get-Content -LiteralPath $script:DetectionCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ([string]$j.Build -ne $script:Build) { return $false }
        $det = @{}
        foreach ($pr in $j.Detection.PSObject.Properties) { $h = @{}; foreach ($q in $pr.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }; $det[$pr.Name] = $h }
        foreach ($q in $j.Env.PSObject.Properties) { if ($q.Name -eq 'Gpus') { $script:Env.Gpus = @($q.Value | ForEach-Object { $g = @{}; foreach ($x in $_.PSObject.Properties) { $g[$x.Name] = $x.Value }; $g }) } else { $script:Env[$q.Name] = $q.Value } }
        $script:Detection = $det
        return $true
    } catch { return $false }
}
function Apply-Detection {
    param([switch]$KeepRows)
    Update-AppliedFromJournal
    if ($script:NvidiaFixBox -and @($script:Env.GpuVendors).Count) { $script:NvidiaFixBox.Visibility = if (@($script:Env.GpuVendors) -contains 'NVIDIA') { 'Visible' } else { 'Collapsed' } }
    foreach ($id in $script:Rows.Keys) {
        $e = $script:Rows[$id]
        $det = $script:Detection[$id]
        if (-not $det) { continue }
        $script:Window.Dispatcher.Invoke([action]{
            if ($det.Present) {
                if ($e.Check) { $e.Check.IsEnabled=$true; $e.Check.IsChecked=[bool]$det.Applied }
                if ($e.Combo) { $e.Combo.IsEnabled=$true }
                $e.Status.Text = [string]$det.Status
            } else {
                if ($e.Check) { $e.Check.IsEnabled=$false; $e.Check.IsChecked=$false }
                if ($e.Combo) { $e.Combo.IsEnabled=$false }
                if ($KeepRows) { return }
                $row = $e.Row
                $section = $row.Parent
                if ($section -and $section -is [Windows.Controls.Panel]) {
                    [void]$section.Children.Remove($row)
                    if ($section.Children.Count -le 1) {
                        $groupBox = $section.Parent
                        if ($groupBox -and $groupBox.Parent -is [Windows.Controls.Panel]) { [void]$groupBox.Parent.Children.Remove($groupBox) }
                    }
                }
            }
        })
    }
    $toggles = @($script:Rows.Values | Where-Object { $_.Check })
    try {
        $report = foreach ($t in @($script:Tweaks | Where-Object { $_.Type -eq 'toggle' })) {
            $det = $script:Detection[$t.Id]
            if (-not $det) { continue }
            $state = if (-not $det.Present) { 'not present' } elseif ($det.Applied) { 'APPLIED' } else { 'not applied' }
            $source = if (-not $det.Present) { [string]$det.Reason } elseif ($det.Live) { 'live' } elseif ($script:Journal.ContainsKey($t.Id)) { 'journal' } else { 'unknown' }
            "{0}`t{1}`t{2}`t{3}`t{4}" -f $t.Id,$state,$source,$t.Label,$det.Evidence
        }
        Set-Content -LiteralPath (Join-Path $script:DataDir 'detection.txt') -Value (@("id`tstate`tsource`tlabel`tevidence") + @($report)) -Encoding UTF8
    } catch { }
    Write-Log ("Read {0} settings: {1} detected as applied; {2} of {3} toggles ticked" -f $script:Detection.Count,@($script:Detection.Values | Where-Object { $_.Applied }).Count,@($toggles | Where-Object { $_.Check.IsChecked }).Count,$toggles.Count) 'Info'
}
 
$sync = [hashtable]::Synchronized(@{ Done=$false; Env=$null; Detection=$null; Error=$null })
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState='MTA'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync',$sync)
$rs.SessionStateProxy.SetVariable('tweaks',$script:Tweaks)
$fnNames = 'Invoke-Detect','Get-NominalRamGB','Get-SvcThreshold','Get-TweakDetection','Test-TweakRegistryActionsApplied','Test-ServiceExists','Resolve-ServiceNames','Get-ServiceStartValue','Get-RunKeyEntry','Test-GameInstalled','Test-InstalledAppName','Get-BcdValue','Get-PowerIndexRecord','Get-ActionLiveState','Get-TweakLiveState','Get-OptionalFeatureStates','Get-AppxStartupStates','Test-ServiceStartMet','Get-DxGlobalSetting','Get-MsiTargets','Get-NetPropertyMaxValue','Get-MatchingNetProperties','Resolve-NetDisplayValue','Test-IsLaptop','Test-HybridIntelCpu','Test-RunKeyDisabled','Get-StartupEntries','Test-StartupEntryDisabled','Get-BitLockerState','Initialize-DetectionCaches','Clear-DetectionCaches','Get-RegValueFast',
    'Get-ActivePowerOverlay','Get-BoardInstallerHint','Get-DxAppSetting','Get-GamesOnHdd','Get-MemoryConfigReport','Get-MsiIrqMap','Get-RatedMemorySpeed','Get-RecognizedGames','Get-ThrottleExemptions','Invoke-PowerCfg','Test-ThrottleExempt'
$initScript = ('$script:DxPrefsPath = ''{0}''' -f $script:DxPrefsPath) + "`n" + '$script:ThrottleExemptCache = $null' + "`n" + '$script:PowerModes = [ordered]@{' + ((@($script:PowerModes.Keys) | ForEach-Object { "'{0}'='{1}'" -f $_,$script:PowerModes[$_] }) -join ';') + '}' + "`n"
foreach ($fn in $fnNames) { $initScript += "function $fn { $((Get-Command $fn).ScriptBlock) }`n" }
$worker = [powershell]::Create()
$worker.Runspace = $rs
$rs.SessionStateProxy.SetVariable('initScript',$initScript)
[void]$worker.AddScript($initScript + @'
try {
    $sync.Env = Invoke-Detect
    $parts = 4
    $pool = [runspacefactory]::CreateRunspacePool(1,$parts); $pool.ApartmentState = 'MTA'; $pool.Open()
    $jobs = @()
    for ($i = 0; $i -lt $parts; $i++) {
        $chunk = @(for ($j = $i; $j -lt $tweaks.Count; $j += $parts) { $tweaks[$j] })
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($initScript + "`n" + 'Get-TweakDetection -Tweaks $args[0] -Env $args[1]').AddArgument($chunk).AddArgument($sync.Env)
        $jobs += @{ Ps=$ps; Async=$ps.BeginInvoke() }
    }
    $merged = @{}
    foreach ($j in $jobs) {
        foreach ($res in @($j.Ps.EndInvoke($j.Async))) { if ($res -is [hashtable]) { foreach ($k in $res.Keys) { $merged[$k] = $res[$k] } } }
        if ($j.Ps.Streams.Error.Count) { $sync.Error = [string]$j.Ps.Streams.Error[0] }
        $j.Ps.Dispose()
    }
    $pool.Close()
    $sync.Detection = $merged
} catch { $sync.Error = $_.Exception.Message }
finally { $sync.Done = $true }
'@)
$async = $worker.BeginInvoke()
 
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:StatusLabel.Text = 'Reading current settings...'
$timer.Add_Tick({
    if (-not $sync.Done) { return }
    $timer.Stop()
    try {
        if ($sync.Error) { Write-Log ("Scan error: {0}" -f $sync.Error) 'Error' }
        if ($sync.Env) {
            foreach ($k in $sync.Env.Keys) { $script:Env[$k] = $sync.Env[$k] }
            $main = ($script:Env.Gpus | Where-Object { $_.IsMain } | Select-Object -First 1)
            $gpuTxt = if ($main) { $main.Name } elseif ($script:Env.Gpus.Count) { $script:Env.Gpus[0].Name } else { 'Unknown GPU' }
            $EnvInfo.Text = ("{0} build {1}  -  {2}  -  {3} GB RAM  -  {4}" -f $script:Env.OsName,$script:Env.Build,$script:Env.Cpu,$script:Env.RamNominalGB,$gpuTxt)
            Write-Log ("{0} build {1}, {2}, {3} GB RAM, GPU: {4}" -f $script:Env.OsName,$script:Env.Build,$script:Env.Cpu,$script:Env.RamNominalGB,$gpuTxt) 'Info'
        }
        if ($sync.Detection) { $script:Detection = $sync.Detection; Apply-Detection; Save-DetectionCache }
        try { Update-VendorTabs } catch { }
        Build-DebloatList -AutoCheck $false
        foreach ($b in @($PresetCombo,$RestoreBtn,$ApplyBtn,$btnAuto,$btnScan,$btnDebApply)) { $b.IsEnabled=$true }
        Update-ViewFilter
        $script:Ready = $true
        Write-Log 'Ready' 'Success'
        foreach ($b in @($btnHomeRecheck,$btnHomeOptimize,$btnHomePlacebo,$btnHomeRestore,$HealthBtn)) { $b.IsEnabled = $true }
        $script:Window.Dispatcher.BeginInvoke([action]{ try { Update-HomeHealth } catch { Write-Log ("Health check failed: {0}" -f $_.Exception.Message) 'Error' } },[Windows.Threading.DispatcherPriority]::Background) | Out-Null
        $script:Window.Dispatcher.BeginInvoke([action]{ Invoke-PowerAction 'Loading power plans' { Open-PowerTab } },[Windows.Threading.DispatcherPriority]::ContextIdle) | Out-Null
    } catch { Write-Log ("Startup finalize error: {0}" -f $_.Exception.Message) 'Error' }
    finally { try { $worker.EndInvoke($async); $worker.Dispose(); $rs.Close() } catch {} }
})
 
if ($Cleanup) {
    Write-Log 'Started with -Cleanup: running the recommended cleanup without the window.' 'Info'
    try { $worker.Stop() } catch { }
    $r = Invoke-Cleanup -Ids @($script:CleanupCategories | Where-Object { $_.Default } | ForEach-Object { $_.Id })
    foreach ($line in $r.Lines) { Write-Host $line }
    Write-Host ('Freed {0}.' -f (Format-Bytes $r.Total))
    try { $rs.Close() } catch { }
    return
}
if (Read-DetectionCache) {
    try {
        $main = ($script:Env.Gpus | Where-Object { $_.IsMain } | Select-Object -First 1)
        $EnvInfo.Text = ("{0} build {1}  -  {2}  -  {3} GB RAM  -  {4}" -f $script:Env.OsName,$script:Env.Build,$script:Env.Cpu,$script:Env.RamNominalGB,$(if ($main) { $main.Name } else { '' }))
        Apply-Detection -KeepRows
        try { Update-VendorTabs } catch { }
        Update-ViewFilter
        Write-Log 'Showing the last scan while the current settings are read in the background.' 'Info'
    } catch { }
}
Write-Log 'Detecting CPU and GPU' 'Info'
$timer.Start()
 
$script:Window.Add_Closed({ try { if ($rs -and -not $rs.IsDisposed) { $rs.Close() } } catch {} })
[void]$script:Window.ShowDialog()
 
