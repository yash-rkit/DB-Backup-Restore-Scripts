<#
.SYNOPSIS
    Windows Server baseline provisioning - discovery-driven, no manual version pinning.

.DESCRIPTION
    Runs in distinct phases:

      PHASE 1  DISCOVER  Queries vendor feeds for current versions, download URLs and
                         publisher hashes. Nothing is downloaded or installed.
      PHASE 2  PLAN      Prints what will be installed, what is already present, and
                         anything that could NOT be resolved. Waits for your confirmation.
      PHASE 3  ACQUIRE   Downloads and verifies every payload BEFORE touching the system,
                         so a bad download cannot leave the server half-provisioned.

    Version information lives in memory for the duration of the run only. No plan file, no
    hash file, nothing about versions or URLs written to disk. Every run re-discovers.
      PHASE 4  INSTALL   Ordered install. .NET Hosting Bundles ascend by major version.
      PHASE 5  VERIFY    ANCM version, exporter scrape, summary.

    Single file. Windows PowerShell 5.1. No modules, no package manager.

.PARAMETER DiscoverOnly
    Run phases 1-2 and stop. Nothing downloaded, nothing installed.

.PARAMETER Yes
    Skip the confirmation prompt. For unattended runs.

.PARAMETER Include
    Install only these packages (by name). Skips the interactive menu.
    Dependencies are pulled in automatically. e.g. -Include IIS,URLRewrite,WindowsExporter

.PARAMETER Exclude
    Install everything except these. Combine with -Yes for unattended runs.

.PARAMETER Reconfigure
    Re-run configuration steps for packages that are ALREADY installed - rewrites
    windows_exporter's config.yaml, resets the firewall rule, restarts the service and
    re-verifies the endpoint. Without this, an installed package is skipped entirely.

.PARAMETER PrometheusAllowedIP
    Source addresses allowed to reach the exporter port. Defaults to LocalSubnet.

.EXAMPLE
    # See what would happen
    .\Install-ServerBaseline.ps1 -DiscoverOnly

.EXAMPLE
    # Unattended
    .\Install-ServerBaseline.ps1 -Yes -PrometheusAllowedIP '10.20.30.40'

.NOTES
    Run elevated, under powershell.exe (not pwsh). Server 2019 / 2022 / 2025, x64.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]   $WorkRoot                = 'C:\Provisioning',
    [int]      $ExporterPort            = 9182,
    [string[]] $PrometheusAllowedIP     = @('LocalSubnet'),
    [string[]] $DotnetChannels          = @('6.0','8.0','10.0'),
    [switch]   $DiscoverOnly,
    [switch]   $Reconfigure,
    [string[]] $Include,
    [string[]] $Exclude,
    [switch]   $Yes,
    [switch]   $AllowUnverified,
    [string[]] $Only
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Warning 'PowerShell 7+ detected. Use powershell.exe. Feature install will fall back to DISM.'
}

$script:Log       = $null
$script:Results   = New-Object System.Collections.ArrayList
$script:RebootReq = $false
$script:UA        = @{ 'User-Agent' = 'Install-ServerBaseline/2.0' }
$script:AncmTrail = New-Object System.Collections.ArrayList

# $PSScriptRoot is EMPTY when the script is run from the ISE console pane, dot-sourced, or
# pasted rather than invoked with -File. Join-Path then fails with "Cannot bind argument to
# parameter 'Path' because it is an empty string" and every download dies before it starts.
$script:SelectionWasInteractive = $false
$script:ScriptRoot =
    if     ($PSScriptRoot)                    { $PSScriptRoot }
    elseif ($PSCommandPath)                   { Split-Path -Parent $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path)     { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else                                      { (Get-Location).ProviderPath }
$script:ExporterCollectors = @('cpu','cpu_info','memory','net','os','system','time','logical_disk',
                               'physical_disk','diskdrive','service','process','iis','tcp','udp',
                               'dns','dhcp','smtp')

#region ========================== INFRASTRUCTURE ==============================

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO')
    $line = '{0}  [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    if ($script:Log) { Add-Content -Path $script:Log -Value $line -Encoding UTF8 }
}

function Write-Both {
    # Write-Host alone never reaches the transcript, which made the plan table and the
    # confirmation prompt invisible in the log file - the run looked like it had died.
    param([string]$Text = '', [string]$Colour = 'Gray')
    if ($Colour -eq 'Gray') { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Colour }
    if ($script:Log) { Add-Content -Path $script:Log -Value $Text -Encoding UTF8 }
}

function Assert-Elevated {
    $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Must run elevated (Run as Administrator).'
    }
}

function Initialize-Tls {
    $proto = [Net.SecurityProtocolType]::Tls12
    try { $proto = $proto -bor [Net.SecurityProtocolType]::Tls13 } catch { }
    [Net.ServicePointManager]::SecurityProtocol = $proto
}

function Get-OSInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $ci = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Caption = $os.Caption
        Build   = [int]$ci.CurrentBuildNumber
        Arch    = $os.OSArchitecture
        Family  = switch -Regex ($os.Caption) { '2019'{'2019'} '2022'{'2022'} '2025'{'2025'} default{'Unknown'} }
    }
}

function Get-NetFxRelease {
    $k = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not (Test-Path $k)) { return 0 }
    $v = Get-ItemProperty $k -EA SilentlyContinue
    if (-not $v -or $v.PSObject.Properties.Name -notcontains 'Release') { return 0 }
    return [int]$v.Release
}

function Test-UninstallEntry {
    <#
        Does NOT use 'Select-Object -First 1' - that halts the pipeline via
        StopUpstreamCommandsException, which under $ErrorActionPreference='Stop' can surface
        as a terminating error and be swallowed by the caller.
        -Explain makes it report exactly what it looked for and what it found.
    #>
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string[]]$PathHint,
        [switch]$Explain
    )

    foreach ($p in $PathHint) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        # -LiteralPath: product paths contain '+' and '(' which Test-Path would otherwise
        # try to interpret. 'Notepad++' and 'Program Files (x86)' both hit this.
        if (Test-Path -LiteralPath $p) { return $true }
        if ($Explain) { Write-Log "    no file at: $p" -Level WARN }
    }

    foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $props = @(Get-ItemProperty $r -EA SilentlyContinue)
        $named = @($props | Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' })
        $hits  = @($named | Where-Object { $_.DisplayName -match $Pattern })
        if ($hits.Count -gt 0) { return $true }
        if ($Explain) {
            Write-Log "    $($named.Count) uninstall entries in $($r -replace '\\\*$',''), none match '$Pattern'" -Level WARN
        }
    }
    return $false
}

function Show-DetectionDiagnostics {
    <# Called only when a package installs cleanly but detection still says no. #>
    param($Pkg, [string]$Keyword)
    Write-Log "  detection diagnostics for $($Pkg.Name):" -Level WARN
    try { $null = & $Pkg.Detect } catch { Write-Log "    detect threw: $($_.Exception.Message)" -Level ERROR }

    foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $near = @(Get-ItemProperty $r -EA SilentlyContinue |
                  Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and
                                 $_.DisplayName -like "*$Keyword*" } |
                  ForEach-Object { $_.DisplayName })
        if ($near.Count) { Write-Log "    registry shows: $($near -join ' | ')" -Level WARN }
    }
}

function Test-VCRuntime {
    param([Parameter(Mandatory)][ValidateSet('x64','x86')][string]$Arch)
    $key = if ($Arch -eq 'x64') { 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' }
           else                 { 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86' }
    if (-not (Test-Path $key)) { return $false }
    $v = Get-ItemProperty $key -EA SilentlyContinue
    if (-not $v -or $v.PSObject.Properties.Name -notcontains 'Installed') { return $false }
    return ($v.Installed -eq 1)
}

function Test-SharedFramework {
    param([Parameter(Mandatory)][int]$Major)
    $dir = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.AspNetCore.App'
    if (-not (Test-Path $dir)) { return $false }
    return [bool](Get-ChildItem $dir -Directory -EA SilentlyContinue | Where-Object { $_.Name -match "^$Major\." })
}

function Get-AncmVersion {
    $dll = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    if (Test-Path $dll) { return (Get-Item $dll).VersionInfo.FileVersion }
    return $null
}

function Test-PendingReboot {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path $k) { return $true }
    }
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -EA SilentlyContinue
    return ($sm -and $sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations')
}

function Test-PackageInstalled {
    # Not every package defines a Detect block (IIS is handled by feature enumeration).
    # Calling '& $null' throws - that is what killed Show-Plan.
    param($Pkg)
    if (-not $Pkg.ContainsKey('Detect')) { return $false }
    if ($null -eq $Pkg.Detect)           { return $false }
    try   { return [bool](& $Pkg.Detect) }
    catch {
        # Silently returning $false here is what hid the Test-UninstallEntry bug for two runs.
        Write-Log "  detection error for $($Pkg.Name): $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Test-UrlAvailable {
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30 -Headers $script:UA
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch {
        # Some CDNs reject HEAD. Fall back to a 1-byte ranged GET.
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.UserAgent = 'Install-ServerBaseline/2.0'
            $req.AddRange(0,0); $req.Timeout = 30000
            $resp = $req.GetResponse(); $resp.Close()
            return $true
        } catch { return $false }
    }
}
#endregion

#region ============================ RESOLVERS =================================
# Each resolver returns a hashtable, or $null when the information is unavailable.
#   @{ Version; FileName; Url; Hash; HashAlg; Source }

function Resolve-DotnetHostingBundle {
    <# Microsoft's official release metadata. Gives version, URL, SHA512 and support state. #>
    param([Parameter(Mandatory)][string]$Channel)

    $indexUrls = @(
        'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
        'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json'
    )
    $index = $null
    foreach ($u in $indexUrls) {
        try { $index = Invoke-RestMethod -Uri $u -UseBasicParsing -TimeoutSec 60 -Headers $script:UA; break }
        catch { Write-Verbose "index fetch failed: $u" }
    }
    if (-not $index) { Write-Log "  .NET $Channel : release index unreachable." -Level WARN; return $null }

    $ch = $index.'releases-index' | Where-Object { $_.'channel-version' -eq $Channel } | Select-Object -First 1
    if (-not $ch) { Write-Log "  .NET $Channel : channel not present in Microsoft's index." -Level WARN; return $null }

    try { $rel = Invoke-RestMethod -Uri $ch.'releases.json' -UseBasicParsing -TimeoutSec 120 -Headers $script:UA }
    catch { Write-Log "  .NET $Channel : channel manifest unreachable." -Level WARN; return $null }

    $latest = $rel.releases | Where-Object { $_.'release-version' -eq $ch.'latest-release' } | Select-Object -First 1
    if (-not $latest) { $latest = $rel.releases | Select-Object -First 1 }

    # The metadata 'name' field is the GENERIC 'dotnet-hosting-win.exe' - the version appears
    # only in the URL. Matching name against a versioned pattern silently finds nothing.
    $file = $null
    if ($latest.PSObject.Properties.Name -contains 'aspnetcore-runtime' -and $latest.'aspnetcore-runtime') {
        $ar = $latest.'aspnetcore-runtime'
        if ($ar.PSObject.Properties.Name -contains 'files' -and $ar.files) {
            $file = $ar.files | Where-Object {
                $_.url -match 'dotnet-hosting-.*-win\.exe$' -or $_.name -match '^dotnet-hosting.*\.exe$'
            } | Select-Object -First 1
        }
    }
    if (-not $file) {
        Write-Log "  .NET $Channel : no Windows hosting bundle in manifest." -Level WARN
        if ($latest.PSObject.Properties.Name -contains 'aspnetcore-runtime' -and $latest.'aspnetcore-runtime'.files) {
            Write-Log "  candidates were: $(((($latest.'aspnetcore-runtime'.files).name) | Select-Object -Unique) -join ', ')" -Level WARN
        }
        return $null
    }

    # Real filename comes from the URL, not the generic 'name'.
    $fileName = [IO.Path]::GetFileName(($file.url -split '\?')[0])

    @{
        Version     = $latest.'release-version'
        FileName    = $fileName
        Url         = $file.url
        Hash        = $file.hash
        HashAlg     = 'SHA512'
        Source      = 'Microsoft release metadata'
        SupportPhase= $ch.'support-phase'
        EolDate     = $ch.'eol-date'
    }
}

function Resolve-GitHubAsset {
    <# API first; falls back to the /releases/latest redirect when rate-limited (60/hr per IP). #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetPattern,
        [string]$FallbackTemplate   # {V} = tag with leading 'v' stripped
    )

    try {
        $rel   = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $script:UA -TimeoutSec 60
        $asset = $rel.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
        if ($asset) {
            return @{
                Version  = ($rel.tag_name -replace '^v','')
                FileName = $asset.name
                Url      = $asset.browser_download_url
                Hash     = ''
                HashAlg  = ''
                Source   = "GitHub API ($Repo)"
            }
        }
        Write-Log "  $Repo : release found but no asset matching $AssetPattern" -Level WARN
        return $null
    }
    catch {
        Write-Log "  $Repo : API unavailable ($($_.Exception.Message)). Trying redirect." -Level WARN
    }

    if (-not $FallbackTemplate) { return $null }
    try {
        $r   = Invoke-WebRequest "https://github.com/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 60 -Headers $script:UA
        $uri = $r.BaseResponse.ResponseUri.AbsoluteUri
        if ($uri -notmatch '/tag/(.+)$') { return $null }
        $ver  = $Matches[1] -replace '^v',''
        $name = $FallbackTemplate -replace '\{V\}', $ver
        $url  = "https://github.com/$Repo/releases/download/$($Matches[1])/$name"
        if (-not (Test-UrlAvailable $url)) { Write-Log "  $Repo : constructed URL not reachable." -Level WARN; return $null }
        return @{ Version=$ver; FileName=$name; Url=$url; Hash=''; HashAlg=''; Source="GitHub redirect ($Repo)" }
    }
    catch { return $null }
}

function Resolve-SevenZip {
    # ip7z/7zip is the official repo. If it has no MSI, scrape the download page.
    $r = Resolve-GitHubAsset -Repo 'ip7z/7zip' -AssetPattern '-x64\.msi$'
    if ($r) { return $r }
    try {
        $page = Invoke-WebRequest 'https://www.7-zip.org/download.html' -UseBasicParsing -TimeoutSec 60 -Headers $script:UA
        $m = [regex]::Matches($page.Content, 'a/(7z(\d{4})-x64\.msi)') |
             Sort-Object { [int]$_.Groups[2].Value } -Descending | Select-Object -First 1
        if (-not $m) { return $null }
        $name = $m.Groups[1].Value
        $ver  = $m.Groups[2].Value
        return @{ Version="$($ver.Substring(0,2)).$($ver.Substring(2,2))"; FileName=$name
                  Url="https://www.7-zip.org/a/$name"; Hash=''; HashAlg=''; Source='7-zip.org' }
    }
    catch { return $null }
}

function Resolve-MySQLWorkbench {
    # Oracle publishes no version feed. Try the downloads page; if that fails (JS-rendered,
    # blocked, or restyled) walk the CDN downwards until a build responds.
    $ver = $null; $src = ''
    try {
        $page = Invoke-WebRequest 'https://dev.mysql.com/downloads/workbench/' -UseBasicParsing -TimeoutSec 60 -Headers $script:UA
        $m = [regex]::Match($page.Content, 'mysql-workbench-community-(\d+\.\d+\.\d+)-winx64\.msi')
        if ($m.Success) { $ver = $m.Groups[1].Value; $src = 'dev.mysql.com' }
    } catch { Write-Log '  dev.mysql.com not reachable - will probe the CDN.' -Level WARN }

    if ($ver) {
        $url = "https://cdn.mysql.com/Downloads/MySQLGUITools/mysql-workbench-community-$ver-winx64.msi"
        if (Test-UrlAvailable $url) {
            return @{ Version=$ver; FileName="mysql-workbench-community-$ver-winx64.msi"; Url=$url
                      Hash=''; HashAlg=''; Source=$src }
        }
        Write-Log "  page reported $ver but the CDN does not serve it - probing." -Level WARN
    }

    Write-Log '  probing cdn.mysql.com for the current 8.0.x build ...'
    for ($n = 60; $n -ge 30; $n--) {
        $v    = "8.0.$n"
        $name = "mysql-workbench-community-$v-winx64.msi"
        $url  = "https://cdn.mysql.com/Downloads/MySQLGUITools/$name"
        if (Test-UrlAvailable $url) {
            return @{ Version=$v; FileName=$name; Url=$url; Hash=''; HashAlg=''; Source='cdn.mysql.com (probed)' }
        }
    }
    return $null
}

function Resolve-Chrome {
    # Google publishes no per-version MSI URL - the enterprise MSI link is a rolling permalink
    # that always serves current stable. The VersionHistory API tells us which build that is,
    # so the plan can still show a real version number before you confirm.
    $ver = $null
    try {
        $r = Invoke-RestMethod 'https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions' `
                               -TimeoutSec 60 -Headers $script:UA
        if ($r.PSObject.Properties.Name -contains 'versions' -and $r.versions) {
            $sorted = @($r.versions | ForEach-Object { $_.version } |
                        Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending)
            if ($sorted.Count) { $ver = $sorted[0] }
        }
    } catch { Write-Log '  Chrome version API unreachable - MSI permalink is still current stable.' -Level WARN }

    $url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    if (-not (Test-UrlAvailable $url)) { return $null }

    return @{
        Version  = $(if ($ver) { $ver } else { 'rolling (latest stable)' })
        FileName = 'googlechromestandaloneenterprise64.msi'
        Url      = $url
        Hash     = ''
        HashAlg  = ''
        Source   = $(if ($ver) { 'Google VersionHistory API' } else { 'Google enterprise permalink' })
    }
}

function Resolve-WinSCP {
    # WinSCP is distributed via SourceForge, which exposes machine-readable release metadata.
    # That is far more reliable than scraping winscp.net, which failed on this network.
    $ver = $null; $src = ''
    try {
        $j = Invoke-RestMethod 'https://sourceforge.net/projects/winscp/best_release.json' `
                               -TimeoutSec 60 -Headers $script:UA
        $blob = ($j | ConvertTo-Json -Depth 6)
        $m = [regex]::Match($blob, 'WinSCP-(\d+\.\d+(?:\.\d+)?)-Setup\.exe')
        if ($m.Success) { $ver = $m.Groups[1].Value; $src = 'SourceForge release metadata' }
    } catch { Write-Log '  SourceForge metadata unreachable - trying winscp.net.' -Level WARN }

    if (-not $ver) {
        foreach ($page in @('https://winscp.net/eng/download.php','https://winscp.net/eng/downloads.php')) {
            try {
                $html = (Invoke-WebRequest $page -UseBasicParsing -TimeoutSec 60 -Headers $script:UA).Content
                $m = [regex]::Match($html, 'WinSCP-(\d+\.\d+(?:\.\d+)?)-Setup\.exe')
                if ($m.Success) { $ver = $m.Groups[1].Value; $src = 'winscp.net'; break }
            } catch { }
        }
    }
    if (-not $ver) { Write-Log '  could not determine the current WinSCP version.' -Level WARN; return $null }

    $name = "WinSCP-$ver-Setup.exe"
    foreach ($url in @("https://cdn.winscp.net/files/$name",
                       "https://downloads.sourceforge.net/project/winscp/WinSCP/$ver/$name")) {
        if (Test-UrlAvailable $url) {
            return @{ Version=$ver; FileName=$name; Url=$url; Hash=''; HashAlg=''; Source=$src }
        }
    }
    Write-Log "  version $ver found but no reachable download URL." -Level WARN
    return $null
}

function Resolve-Static {
    <# For vendors with no version feed at all. Availability is probed, version is fixed or rolling. #>
    param([string]$Url, [string]$FileName, [string]$Version, [string]$Source)
    if (-not (Test-UrlAvailable $Url)) { return $null }
    return @{ Version=$Version; FileName=$FileName; Url=$Url; Hash=''; HashAlg=''; Source=$Source }
}
#endregion

#region ====================== PACKAGE BEHAVIOUR CATALOG ========================
# Behaviour ONLY - no versions, no URLs. Discovery supplies those. Keeping the two
# separate is what lets a saved plan (pure data) be rehydrated identically elsewhere.

function Get-PackageCatalog {
    @{
        'IIS' = @{
            Kind='WindowsFeature'; Order=10
            # Display only - the install path enumerates features individually.
            Detect={ $null -ne (Get-Service W3SVC -EA SilentlyContinue) }
            Features = @(
                'Web-Server','Web-WebServer','Web-Common-Http','Web-Default-Doc','Web-Dir-Browsing',
                'Web-Http-Errors','Web-Static-Content','Web-Http-Redirect',
                'Web-Health','Web-Http-Logging','Web-Log-Libraries','Web-Request-Monitor',
                'Web-Performance','Web-Stat-Compression','Web-Dyn-Compression',
                'Web-Security','Web-Filtering','Web-Windows-Auth',
                'Web-App-Dev','Web-Net-Ext45','Web-Asp-Net45','Web-ISAPI-Ext','Web-ISAPI-Filter',
                'Web-Mgmt-Tools','Web-Mgmt-Console','Web-Scripting-Tools',
                'NET-Framework-45-ASPNET','NET-WCF-HTTP-Activation45')
            DismFeatures = @(
                'IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-DefaultDocument',
                'IIS-DirectoryBrowsing','IIS-HttpErrors','IIS-StaticContent','IIS-HttpRedirect',
                'IIS-HealthAndDiagnostics','IIS-HttpLogging','IIS-LoggingLibraries','IIS-RequestMonitor',
                'IIS-Performance','IIS-HttpCompressionStatic','IIS-HttpCompressionDynamic',
                'IIS-Security','IIS-RequestFiltering','IIS-WindowsAuthentication',
                'IIS-ApplicationDevelopment','IIS-NetFxExtensibility45','IIS-ASPNET45',
                'IIS-ISAPIExtensions','IIS-ISAPIFilter',
                'IIS-WebServerManagementTools','IIS-ManagementConsole','IIS-ManagementScriptingTools',
                'NetFx4Extended-ASPNET45','WCF-HTTP-Activation45')
        }
        'NetFx481' = @{
            Kind='Exe'; Order=20; Args='/q /norestart /log "{LOG}"'
            Detect={ (Get-NetFxRelease) -ge 533320 }
        }
        'VCRedist_x64' = @{
            Kind='Exe'; Order=30; Args='/install /quiet /norestart /log "{LOG}"'
            Detect={ Test-VCRuntime -Arch x64 }
        }
        'VCRedist_x86' = @{
            Kind='Exe'; Order=31; Args='/install /quiet /norestart /log "{LOG}"'
            Detect={ Test-VCRuntime -Arch x86 }
        }
        'URLRewrite' = @{
            Kind='Msi'; Order=60; Args=''; Requires='IIS'
            Detect={ Test-Path 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite' }
        }
        'WindowsExporter' = @{
            Kind='Msi'; Order=70
            Args='CONFIG_FILE="C:\ProgramData\windows_exporter\config.yaml" LISTEN_PORT="{PORT}"'
            UnsignedOk=$true   # project signs with its own self-signed cert by design
            Detect={ $null -ne (Get-Service windows_exporter -EA SilentlyContinue) }
            PreInstall={ Write-ExporterConfig }
            PostInstall={ Set-ExporterFirewall; Restart-ExporterService; Test-ExporterEndpoint }
        }
        'SevenZip' = @{
            Kind='Msi'; Order=80; Args=''
            UnsignedOk=$true   # 7-Zip ships no Authenticode signature; verified by publisher URL only
            Detect={ Test-UninstallEntry -Pattern '^7-Zip' -PathHint @("$env:ProgramFiles\7-Zip\7z.exe") }
        }
        'NotepadPlusPlus' = @{
            Kind='Exe'; Order=81; Args='/S'
            Detect={ Test-UninstallEntry -Pattern '^Notepad\+\+' -PathHint @("$env:ProgramFiles\Notepad++\notepad++.exe") }
        }
        'GoogleChrome' = @{
            Kind='Msi'; Order=82; Args=''
            Detect={ Test-UninstallEntry -Pattern '^Google Chrome' -PathHint @(
                        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')) }
        }
        'WinSCP' = @{
            Kind='Exe'; Order=83
            # Inno Setup. /SP- suppresses the "This will install..." prompt.
            Args='/VERYSILENT /SP- /NORESTART /SUPPRESSMSGBOXES /ALLUSERS'
            Detect={ Test-UninstallEntry -Pattern '^WinSCP' -PathHint @(
                        (Join-Path ${env:ProgramFiles(x86)} 'WinSCP\WinSCP.exe'),
                        (Join-Path $env:ProgramFiles 'WinSCP\WinSCP.exe')) }
        }
        'RedisDesktopManager' = @{
            Kind='Exe'; Order=84; Args='/S'      # electron-builder NSIS
            Detect={ Test-UninstallEntry -Pattern 'Redis Desktop Manager' -PathHint @(
                        (Join-Path $env:ProgramFiles 'Another Redis Desktop Manager\Another Redis Desktop Manager.exe'),
                        (Join-Path ${env:LOCALAPPDATA} 'Programs\another-redis-desktop-manager\Another Redis Desktop Manager.exe')) }
        }
        'MySQLWorkbench' = @{
            Kind='Msi'; Order=90; Args=''; Requires='VCRedist_x64'
            Detect={ Test-UninstallEntry -Pattern 'MySQL Workbench' -PathHint @(
                        "$env:ProgramFiles\MySQL\MySQL Workbench 8.0 CE\MySQLWorkbench.exe",
                        "$env:ProgramFiles\MySQL\MySQL Workbench 8.0\MySQLWorkbench.exe") }
        }
    }
}

function Get-PackageBehaviour {
    param([Parameter(Mandatory)][string]$Name)
    # Hosting bundles are generated per channel. Order = 40 + major, so ascending major
    # version is guaranteed by construction rather than by remembering to hand-number them.
    if ($Name -match '^HostingBundle_(\d+)$') {
        $m = [int]$Matches[1]
        return @{
            Kind='Exe'; Order=(40 + $m); Args='/install /quiet /norestart /log "{LOG}"'
            Detect=[scriptblock]::Create("Test-SharedFramework -Major $m")
        }
    }
    $cat = Get-PackageCatalog
    if ($cat.ContainsKey($Name)) { return $cat[$Name] }
    return $null
}

function New-PlanEntry {
    param([Parameter(Mandatory)][string]$Name, $Res)
    $b = Get-PackageBehaviour -Name $Name
    if (-not $b) { throw "No behaviour defined for package '$Name'." }

    $e = @{ Name = $Name }
    foreach ($k in $b.Keys) { $e[$k] = $b[$k] }

    if ($Res) {
        $e.Resolved = $true
        foreach ($k in @('Version','FileName','Url','Hash','HashAlg','Source','SupportPhase','EolDate')) {
            if ($Res.ContainsKey($k)) { $e[$k] = $Res[$k] }
        }
        Write-Log "  -> $($e.Version)  [$($e.Source)]" -Level OK
    } else {
        $e.Resolved = $false
        $e.Version  = 'UNAVAILABLE'
        $e.Source   = 'could not resolve'
        Write-Log "  -> COULD NOT RESOLVE $Name - it will be SKIPPED." -Level ERROR
    }
    return $e
}
#endregion

#region ============================= PHASE 1 ==================================

function Invoke-Discovery {
    Write-Log 'PHASE 1 - DISCOVERY' -Level STEP
    Write-Log 'Querying vendor feeds. Nothing will be downloaded or installed.'

    $plan = New-Object System.Collections.ArrayList

    # IIS is an OS role - nothing to resolve.
    [void]$plan.Add((New-PlanEntry -Name 'IIS' -Res @{ Version='OS built-in'; Source='Windows Server role' }))

    Write-Log 'Resolving .NET Framework 4.8.1 ...'
    if ((Get-NetFxRelease) -ge 533320) {
        Write-Log '  Already 4.8.1 or newer - not required on this host.' -Level OK
        $e = New-PlanEntry -Name 'NetFx481' -Res @{ Version='already present'; Source='in-box' }
        $e.Kind = 'Skip'
        [void]$plan.Add($e)
    } else {
        [void]$plan.Add((New-PlanEntry -Name 'NetFx481' -Res (Resolve-Static `
            -Url 'https://go.microsoft.com/fwlink/?linkid=2203304' `
            -FileName 'ndp481-x86-x64-allos-enu.exe' -Version '4.8.1' -Source 'Microsoft fwlink (static)')))
    }

    foreach ($arch in @('x64','x86')) {
        Write-Log "Resolving VC++ redistributable $arch ..."
        [void]$plan.Add((New-PlanEntry -Name "VCRedist_$arch" -Res (Resolve-Static `
            -Url "https://aka.ms/vs/17/release/vc_redist.$arch.exe" -FileName "vc_redist.$arch.exe" `
            -Version 'rolling (latest)' -Source 'Microsoft permalink')))
    }

    foreach ($ch in ($DotnetChannels | Sort-Object { [double]$_ })) {
        Write-Log "Resolving .NET $ch hosting bundle ..."
        $r     = Resolve-DotnetHostingBundle -Channel $ch
        $major = [int]($ch -split '\.')[0]
        if ($r -and $r.SupportPhase -in @('eol','maintenance')) {
            Write-Log "  .NET $ch is '$($r.SupportPhase)' per Microsoft - EOL $($r.EolDate)." -Level WARN
        }
        [void]$plan.Add((New-PlanEntry -Name "HostingBundle_$major" -Res $r))
    }

    Write-Log 'Resolving IIS URL Rewrite ...'
    [void]$plan.Add((New-PlanEntry -Name 'URLRewrite' -Res (Resolve-Static `
        -Url 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' `
        -FileName 'rewrite_amd64_en-US.msi' -Version '2.1' -Source 'Microsoft download (static)')))

    Write-Log 'Resolving windows_exporter ...'
    [void]$plan.Add((New-PlanEntry -Name 'WindowsExporter' -Res (Resolve-GitHubAsset `
        -Repo 'prometheus-community/windows_exporter' -AssetPattern '\-amd64\.msi$' `
        -FallbackTemplate 'windows_exporter-{V}-amd64.msi')))

    Write-Log 'Resolving 7-Zip ...'
    [void]$plan.Add((New-PlanEntry -Name 'SevenZip' -Res (Resolve-SevenZip)))

    Write-Log 'Resolving Notepad++ ...'
    [void]$plan.Add((New-PlanEntry -Name 'NotepadPlusPlus' -Res (Resolve-GitHubAsset `
        -Repo 'notepad-plus-plus/notepad-plus-plus' -AssetPattern 'Installer\.x64\.exe$' `
        -FallbackTemplate 'npp.{V}.Installer.x64.exe')))

    Write-Log 'Resolving Google Chrome ...'
    [void]$plan.Add((New-PlanEntry -Name 'GoogleChrome' -Res (Resolve-Chrome)))

    Write-Log 'Resolving WinSCP ...'
    [void]$plan.Add((New-PlanEntry -Name 'WinSCP' -Res (Resolve-WinSCP)))

    Write-Log 'Resolving Redis Desktop Manager ...'
    # The original Redis Desktop Manager is now commercial (rebranded RESP.app). This resolves
    # 'Another Redis Desktop Manager', the maintained free fork most people mean today.
    [void]$plan.Add((New-PlanEntry -Name 'RedisDesktopManager' -Res (Resolve-GitHubAsset `
        -Repo 'qishibo/AnotherRedisDesktopManager' -AssetPattern '^Another-Redis-Desktop-Manager.*\.exe$' `
        -FallbackTemplate 'Another-Redis-Desktop-Manager.{V}.exe')))

    Write-Log 'Resolving MySQL Workbench ...'
    [void]$plan.Add((New-PlanEntry -Name 'MySQLWorkbench' -Res (Resolve-MySQLWorkbench)))

    return ,$plan
}

#endregion

#region ============================= PHASE 2 ==================================

function Show-Plan {
    param($Plan)

    Write-Log 'PHASE 2 - PLAN' -Level STEP

    $rows = foreach ($p in ($Plan | Sort-Object { $_.Order })) {
        $state = 'will install'
        if ($p.Kind -eq 'Skip')           { $state = 'not required' }
        elseif (-not $p.Resolved)         { $state = 'SKIPPED (unresolved)' }
        elseif (Test-PackageInstalled $p) { $state = 'already present' }

        [pscustomobject]@{
            Order   = $p.Order
            Package = $p.Name
            Version = $p.Version
            Action  = $state
            Verify  = if ($p.ContainsKey('Hash') -and $p.Hash)   { $p.HashAlg + ' (publisher)' }
                      elseif ($p.ContainsKey('UnsignedOk') -and $p.UnsignedOk) { 'UNSIGNED (allowed)' }
                      elseif ($p.Kind -in @('Exe','Msi'))        { 'Authenticode' }
                      else                                       { '-' }
            Source  = $p.Source
        }
    }

    Write-Both (($rows | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())

    $unresolved = @($Plan | Where-Object { -not $_.Resolved })
    if ($unresolved.Count) {
        Write-Both ''
        Write-Both '  !! THE FOLLOWING COULD NOT BE RESOLVED AND WILL NOT BE INSTALLED:' 'Red'
        foreach ($u in $unresolved) { Write-Both "     - $($u.Name)" 'Red' }
        Write-Both '     Usually no internet route, a proxy, or the vendor moved the feed.' 'Yellow'
        Write-Both '     To supply one by hand: drop the installer in .\payload\ and re-run.' 'Yellow'
    }

    $eol = @($Plan | Where-Object { $_.ContainsKey('SupportPhase') -and $_.SupportPhase -in @('eol','maintenance') })
    if ($eol.Count) {
        Write-Both ''
        Write-Both '  ! Out-of-support runtimes included (Microsoft support-phase):' 'Yellow'
        foreach ($e in $eol) { Write-Both "     - $($e.Name)  $($e.Version)  $($e.SupportPhase), EOL $($e.EolDate)" 'Yellow' }
    }

    $todo = @($Plan | Where-Object { $_.Resolved -and $_.Kind -ne 'Skip' -and -not (Test-PackageInstalled $_) })
    Write-Both ''
    Write-Both "  $($todo.Count) package(s) to install, $($unresolved.Count) unavailable." 'Cyan'
    Write-Both '  No reboot will be performed. Pending-reboot state is reported at the end.' 'Cyan'
    return $rows
}

function Test-InteractiveHost {
    if (-not [Environment]::UserInteractive) { return $false }
    try { $null = $Host.UI.RawUI.KeyAvailable; return $true } catch { return $false }
}

function Expand-SelectionSpec {
    # Accepts "1,3,5-8" style input. Returns $null on anything invalid so the caller re-prompts.
    param([string]$Spec, [int]$Max)
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($tok in @($Spec -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(\d+)\s*-\s*(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -gt $hi) { $t = $lo; $lo = $hi; $hi = $t }
            if ($lo -lt 1 -or $hi -gt $Max) { return $null }
            for ($i = $lo; $i -le $hi; $i++) { $out.Add($i) }
        }
        elseif ($tok -match '^\d+$') {
            $i = [int]$tok
            if ($i -lt 1 -or $i -gt $Max) { return $null }
            $out.Add($i)
        }
        else { return $null }
    }
    return @($out | Sort-Object -Unique)
}

function Add-RequiredDependencies {
    <# Selecting URL Rewrite without IIS, or Workbench without VC++, would fail. Pull them in. #>
    param($Plan, [string[]]$Names)
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in $Names) { [void]$set.Add($n) }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $Plan) {
            if (-not $set.Contains($p.Name)) { continue }
            if (-not $p.ContainsKey('Requires')) { continue }
            if ($set.Contains($p.Requires))     { continue }
            $dep = @($Plan | Where-Object { $_.Name -eq $p.Requires })
            if ($dep.Count -and -not (Test-PackageInstalled $dep[0])) {
                [void]$set.Add($p.Requires)
                Write-Log "  + $($p.Requires) added automatically (required by $($p.Name))" -Level WARN
                $changed = $true
            }
        }
    }
    return @($set)
}

function Select-Packages {
    <#
        Returns the names to install. Order of precedence:
          -Include  explicit list
          -Exclude  everything but these
          -Yes      everything installable
          else      interactive numbered menu
    #>
    param($Plan)

    $candidates = @($Plan | Sort-Object { $_.Order } | Where-Object {
        $_.Kind -ne 'Skip' -and $_.Resolved -and -not (Test-PackageInstalled $_)
    })

    if (-not $candidates.Count) {
        Write-Log 'Nothing left to install - everything resolved is already present.' -Level OK
        return @()
    }

    $known = @($Plan | ForEach-Object { $_.Name })

    if ($Include) {
        $bad = @($Include | Where-Object { $known -notcontains $_ })
        if ($bad.Count) { throw "Unknown package name(s) in -Include: $($bad -join ', '). Known: $($known -join ', ')" }
        return (Add-RequiredDependencies -Plan $Plan -Names $Include)
    }

    if ($Exclude) {
        $bad = @($Exclude | Where-Object { $known -notcontains $_ })
        if ($bad.Count) { throw "Unknown package name(s) in -Exclude: $($bad -join ', ')" }
        $keep = @($candidates | Where-Object { $Exclude -notcontains $_.Name } | ForEach-Object { $_.Name })
        return (Add-RequiredDependencies -Plan $Plan -Names $keep)
    }

    if ($Yes) { return @($candidates | ForEach-Object { $_.Name }) }

    if (-not (Test-InteractiveHost)) {
        Write-Log 'Cannot show the selection menu on a non-interactive host.' -Level ERROR
        Write-Log 'Use -Include / -Exclude / -Yes instead.' -Level WARN
        return $null
    }

    Write-Both ''
    Write-Both '  SELECT WHAT TO INSTALL' 'Cyan'
    Write-Both '  ----------------------' 'Cyan'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Both ('   [{0,2}]  {1,-22} {2}' -f ($i + 1), $candidates[$i].Name, $candidates[$i].Version)
    }
    Write-Both ''
    Write-Both '   a = all      n = abort      or a list such as  1,3,5-8' 'Cyan'

    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $ans = "$(Read-Host '  Selection')".Trim()

        if ($ans -match '^(a|all)$') {
            Write-Log "Selected: all $($candidates.Count) package(s)." -Level OK
            $script:SelectionWasInteractive = $true
            return @($candidates | ForEach-Object { $_.Name })
        }
        if ($ans -match '^(n|no|q|quit|abort)$') {
            Write-Log 'Aborted at selection. Nothing was changed.' -Level WARN
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($ans)) {
            Write-Both '  (nothing entered - type a, n, or a list like 1,3,5-8)' 'Yellow'
            continue
        }

        $idx = Expand-SelectionSpec -Spec $ans -Max $candidates.Count
        if ($null -eq $idx -or -not $idx.Count) {
            Write-Both "  (could not parse '$ans' - use numbers 1-$($candidates.Count), e.g. 1,3,5-8)" 'Yellow'
            continue
        }

        $picked = @($idx | ForEach-Object { $candidates[$_ - 1].Name })
        Write-Log "Selected: $($picked -join ', ')" -Level OK
        $script:SelectionWasInteractive = $true
        return (Add-RequiredDependencies -Plan $Plan -Names $picked)
    }

    Write-Log 'No valid selection after 5 attempts. Aborting.' -Level WARN
    return $null
}

function Confirm-Proceed {
    if ($Yes) { Write-Log 'Confirmation bypassed (-Yes). Proceeding.' -Level WARN; return $true }

    if (-not (Test-InteractiveHost)) {
        Write-Log 'This host cannot prompt (non-interactive session).' -Level ERROR
        Write-Log 'Re-run with -Yes to proceed without confirmation.' -Level WARN
        return $false
    }

    Write-Both ''
    Write-Both '  ---------------------------------------------------------------' 'Cyan'
    Write-Both '   Enter  y  to download and install everything listed above.'      'Cyan'
    Write-Both '   Enter  n  to abort. Nothing on this server has changed yet.'     'Cyan'
    Write-Both '  ---------------------------------------------------------------' 'Cyan'
    Write-Log  'Waiting for confirmation at the console ...' -Level STEP

    # Pasting a multi-line command leaves its trailing newline in the input buffer.
    # Without this flush, Read-Host swallows it as an empty answer and the script
    # appears to refuse input entirely.
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $a = Read-Host '  Proceed? [y/n]'
        $a = "$a".Trim()

        if ($a -match '^(y|yes)$') {
            Write-Log "Confirmed. Starting download and installation." -Level OK
            return $true
        }
        if ($a -match '^(n|no|q|quit)$') {
            Write-Log 'Declined. Nothing was changed.' -Level WARN
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($a)) {
            Write-Both '  (no input received - type y or n and press Enter)' 'Yellow'
        } else {
            Write-Both "  (did not understand '$a' - type y or n)" 'Yellow'
        }
    }

    Write-Log 'No valid response after 5 attempts. Aborting; nothing was changed.' -Level WARN
    Write-Log 'If your console cannot accept input, re-run with -Yes.' -Level WARN
    return $false
}

#endregion

#region ============================= PHASE 3 ==================================

function Get-Payload {
    param($Pkg)

    $cacheDir = Join-Path $WorkRoot 'Cache'
    $local    = Join-Path $cacheDir $Pkg.FileName
    $sideload = $null
    if (-not [string]::IsNullOrWhiteSpace($script:ScriptRoot)) {
        $sideload = Join-Path $script:ScriptRoot "payload\$($Pkg.FileName)"
    }

    if ($sideload -and (Test-Path -LiteralPath $sideload)) {
        Write-Log "  side-loaded: $($Pkg.FileName)"; $local = $sideload
    }
    elseif (Test-Path -LiteralPath $local) { Write-Log "  cached: $($Pkg.FileName)" }
    else {
        Write-Log "  downloading $($Pkg.FileName) ..."
        $tmp = "$local.partial"
        try {
            Invoke-WebRequest -Uri $Pkg.Url -OutFile $tmp -UseBasicParsing -TimeoutSec 1800 -Headers $script:UA
            Move-Item $tmp $local -Force
        } catch {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -EA SilentlyContinue }
            throw "download failed: $($_.Exception.Message)"
        }
        Write-Log "  got $([math]::Round((Get-Item $local).Length/1MB,1)) MB" -Level OK
    }

    Confirm-Payload -Path $local -Pkg $Pkg
    return $local
}

function Confirm-Payload {
    <#
        Two tiers, both entirely in memory:
          1. Publisher hash - Microsoft's .NET metadata ships SHA512 beside the URL.
          2. Authenticode   - proves the publisher; enforced by default.
        Nothing is persisted. Each run re-verifies against the feed.
    #>
    param([string]$Path, $Pkg)

    if ($Pkg.ContainsKey('Hash') -and $Pkg.Hash) {
        $alg    = if ($Pkg.HashAlg) { $Pkg.HashAlg } else { 'SHA512' }
        $actual = (Get-FileHash -Path $Path -Algorithm $alg).Hash
        if ($actual -ne $Pkg.Hash.ToUpper()) {
            Remove-Item $Path -Force -EA SilentlyContinue
            throw "$alg MISMATCH against publisher metadata. Downloaded copy deleted."
        }
        Write-Log "  $alg verified against Microsoft release metadata" -Level OK
        return
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -eq 'Valid') {
        $cn = $sig.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1'
        Write-Log "  Authenticode valid - signed by $cn" -Level OK
    }
    elseif ($Pkg.ContainsKey('UnsignedOk') -and $Pkg.UnsignedOk) {
        Write-Log "  Authenticode: $($sig.Status) - this publisher does not sign; accepted by policy." -Level WARN
    }
    else {
        Write-Log "  Authenticode: $($sig.Status) - publisher could NOT be verified." -Level ERROR
        if (-not $AllowUnverified) {
            throw "Refusing to install $($Pkg.FileName): no publisher hash and no valid signature. Use -AllowUnverified to override."
        }
        Write-Log '  proceeding anyway (-AllowUnverified)' -Level WARN
    }
    Write-Log "  SHA256 (this run only): $((Get-FileHash $Path -Algorithm SHA256).Hash)"
}

function Invoke-Acquire {
    param($Plan)
    Write-Log 'PHASE 3 - ACQUIRE' -Level STEP
    Write-Log 'Downloading and verifying everything before any installation begins.'

    $failed = @()
    foreach ($p in ($Plan | Sort-Object { $_.Order })) {
        if ($p.Kind -in @('WindowsFeature','Skip') -or -not $p.Resolved) { continue }
        if (-not $p.Selected) { continue }
        if (Test-PackageInstalled $p) { continue }
        Write-Log "$($p.Name):"
        try { $p.LocalPath = Get-Payload -Pkg $p }
        catch { Write-Log "  $($_.Exception.Message)" -Level ERROR; $failed += $p.Name; $p.Resolved = $false }
    }

    if ($failed) {
        Write-Log "$($failed.Count) payload(s) failed verification or download: $($failed -join ', ')" -Level ERROR
        Write-Log 'These will be skipped. Nothing has been installed yet.' -Level WARN
        if (-not $Yes) {
            Write-Host '  Continue with the remainder? [y/N]: ' -ForegroundColor Cyan -NoNewline
            if ((Read-Host) -notmatch '^(y|yes)$') { return $false }
        }
    }
    return $true
}
#endregion

#region ========================= PHASE 4 - INSTALL ============================

function Install-ServerFeatures {
    param([string[]]$Features, [string[]]$DismFeatures)
    $useSM = $null -ne (Get-Command Install-WindowsFeature -EA SilentlyContinue)
    if (-not $useSM) { try { Import-Module ServerManager -EA Stop; $useSM = $true } catch { $useSM = $false } }

    if ($useSM) {
        $missing = @()
        foreach ($f in $Features) {
            $st = Get-WindowsFeature -Name $f -EA SilentlyContinue
            if (-not $st)           { Write-Log "Feature not on this SKU: $f" -Level WARN; continue }
            if (-not $st.Installed) { $missing += $f }
        }
        if (-not $missing) { return @{ Changed=$false; Reboot=$false; Count=0; Via='ServerManager' } }
        Write-Log "Installing $($missing.Count) feature(s): $($missing -join ', ')"
        $r = Install-WindowsFeature -Name $missing -IncludeManagementTools -EA Stop
        return @{ Changed=$true; Reboot=($r.RestartNeeded -ne 'No'); Count=$missing.Count; Via='ServerManager' }
    }

    Write-Log 'ServerManager unavailable - DISM fallback.' -Level WARN
    $missing = @()
    foreach ($f in $DismFeatures) {
        $st = Get-WindowsOptionalFeature -Online -FeatureName $f -EA SilentlyContinue
        if (-not $st)                { Write-Log "DISM feature not available: $f" -Level WARN; continue }
        if ($st.State -ne 'Enabled') { $missing += $f }
    }
    if (-not $missing) { return @{ Changed=$false; Reboot=$false; Count=0; Via='DISM' } }
    Write-Log "Enabling $($missing.Count) feature(s) via DISM: $($missing -join ', ')"
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $missing -All -NoRestart -EA Stop
    return @{ Changed=$true; Reboot=[bool]$r.RestartNeeded; Count=$missing.Count; Via='DISM' }
}

function Invoke-Installer {
    param([string]$Path, [ValidateSet('Exe','Msi')][string]$Kind, [string]$Arguments = '', [string]$LogFile)
    if ($Kind -eq 'Msi') {
        $exe = "$env:SystemRoot\System32\msiexec.exe"
        $all = "/i `"$Path`" /qn /norestart /L*V `"$LogFile`" $Arguments"
    } else { $exe = $Path; $all = $Arguments }

    Write-Log "  exec: $(Split-Path $exe -Leaf) $all"
    $rc = (Start-Process -FilePath $exe -ArgumentList $all -Wait -PassThru -NoNewWindow).ExitCode
    switch ($rc) {
        0     { @{ Ok=$true;  Reboot=$false; Msg='Installed' } }
        3010  { @{ Ok=$true;  Reboot=$true;  Msg='Installed (reboot required)' } }
        1641  { @{ Ok=$true;  Reboot=$true;  Msg='Installed (reboot initiated)' } }
        1638  { @{ Ok=$true;  Reboot=$false; Msg='Newer version already present' } }
        1618  { @{ Ok=$false; Reboot=$false; Msg='Another install in progress' } }
        1603  { @{ Ok=$false; Reboot=$false; Msg="Fatal error - see $LogFile" } }
        default { @{ Ok=$false; Reboot=$false; Msg="Exit code $rc" } }
    }
}

function Write-ExporterConfig {
    $dir = 'C:\ProgramData\windows_exporter'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # ONLY the collector list is written here.
    #
    # The per-collector 'collector:' block (process.include / service.include) was removed
    # deliberately. The service collector's include/exclude flags do not exist in current
    # builds, and windows_exporter EXITS AT STARTUP on an unrecognised config key rather than
    # ignoring it - which is why the service refused to start.
    $yaml = @"
# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by Install-ServerBaseline.ps1
# Collector list only. Do not add a 'collector:' block unless you have verified every key
# against this build - an unknown key stops the service from starting.
#
# Note: dns / dhcp / smtp only emit series when those roles are installed. On a plain IIS
# host they log a collector error each scrape. Harmless, but noisy.
collectors:
  enabled: $($script:ExporterCollectors -join ',')
log:
  level: info
"@
    Set-Content -Path (Join-Path $dir 'config.yaml') -Value $yaml -Encoding ASCII
    Write-Log "  exporter config written: $dir\config.yaml"
    Write-Log "  collectors: $($script:ExporterCollectors -join ',')"
}

function Set-ExporterFirewall {
    Get-NetFirewallRule -DisplayName '*windows_exporter*' -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
    New-NetFirewallRule -DisplayName 'windows_exporter (scoped)' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $ExporterPort -RemoteAddress $PrometheusAllowedIP -Profile Any -EA Stop | Out-Null
    Write-Log "  firewall: TCP/$ExporterPort from $($PrometheusAllowedIP -join ', ')" -Level OK
}

function Restart-ExporterService {
    $svc = Get-Service windows_exporter -EA SilentlyContinue
    if (-not $svc) { return }
    try {
        Restart-Service windows_exporter -Force -EA Stop
        Write-Log '  exporter service restarted to pick up config.' -Level OK
    } catch {
        Write-Log "  restart failed: $($_.Exception.Message)" -Level WARN
    }
}

function Wait-ServiceRunning {
    param([string]$Name, [int]$TimeoutSec = 60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $svc = Get-Service $Name -EA SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') { return $true }
            # Blindly calling Start-Service while the MSI is still bringing it up throws
            # "Failed to start service". Only nudge it if it has actually settled Stopped.
            if ($svc.Status -eq 'Stopped') {
                try { Start-Service $Name -EA Stop }
                catch { Write-Log "  start attempt: $($_.Exception.Message)" -Level WARN }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Show-ExporterDiagnostics {
    $exe = Join-Path $env:ProgramFiles 'windows_exporter\windows_exporter.exe'
    if (Test-Path $exe) {
        try {
            $printed = & $exe --collectors.print 2>&1 | Out-String
            $valid   = @($printed -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $bad     = @($script:ExporterCollectors | Where-Object { $valid -notcontains $_ })
            if ($bad.Count) { Write-Log "  collectors this build does not recognise: $($bad -join ', ')" -Level ERROR }
            else            { Write-Log '  all configured collector names are valid for this build.' }
        } catch { Write-Log "  could not enumerate collectors: $($_.Exception.Message)" -Level WARN }
    }
    # The MSI points the service log at the Windows event log, so the real reason is there.
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='windows_exporter' } `
                               -MaxEvents 5 -EA SilentlyContinue)
        foreach ($e in $evts) {
            $first = @($e.Message -split "`r?`n" | Where-Object { $_.Trim() })
            if ($first.Count) { Write-Log "  eventlog $($e.TimeCreated.ToString('HH:mm:ss')): $($first[0])" -Level WARN }
        }
        if (-not $evts.Count) { Write-Log '  no windows_exporter entries in the Application event log.' -Level WARN }
    } catch { }
    Write-Log "  service command line: $((Get-CimInstance Win32_Service -Filter "Name='windows_exporter'" -EA SilentlyContinue).PathName)" -Level WARN
}

function Test-ExporterEndpoint {
    if (-not (Wait-ServiceRunning -Name 'windows_exporter' -TimeoutSec 60)) {
        Write-Log '  exporter service did not reach Running within 60s.' -Level ERROR
        Show-ExporterDiagnostics
        return
    }
    Write-Log '  service running.' -Level OK

    try {
        $body = (Invoke-WebRequest "http://127.0.0.1:$ExporterPort/metrics" -UseBasicParsing -TimeoutSec 20).Content
        $found = @('windows_cpu_info','windows_os_info','windows_logical_disk','windows_iis_') |
                 Where-Object { $body -match [regex]::Escape($_) }
        Write-Log "  exporter up. series present: $($found -join ', ')" -Level OK
        $n = ([regex]::Matches($body,'windows_process_cpu_time_total\{')).Count
        Write-Log "  process collector is emitting $n series (one per process, unfiltered)."
        if ($n -ge 300) {
            Write-Log '  that is high cardinality for Prometheus. Filter on the SCRAPE side with' -Level WARN
            Write-Log '  metric_relabel_configs rather than in config.yaml.' -Level WARN
        }
    }
    catch {
        Write-Log "  service is running but /metrics did not respond: $($_.Exception.Message)" -Level ERROR
        Show-ExporterDiagnostics
    }
}

function Invoke-Install {
    param($Plan)
    Write-Log 'PHASE 4 - INSTALL' -Level STEP

    $queue = $Plan | Sort-Object { $_.Order }   # scriptblock: Sort-Object cannot see hashtable keys as properties
    if ($Only) { $queue = $queue | Where-Object { $Only -contains $_.Name } }

    foreach ($p in $queue) {
        if ($p.Kind -eq 'Skip') { continue }
        if (-not $p.Selected -and -not ($Reconfigure -and (Test-PackageInstalled $p))) { continue }
        Write-Log "=== $($p.Name) ===" -Level STEP

        if (-not $p.Resolved) {
            Write-Log 'Skipped - version information was not available.' -Level WARN
            [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Unavailable'; Detail=$p.Source })
            continue
        }
        if ($p.ContainsKey('Requires')) {
            $dep = $script:Results | Where-Object Name -eq $p.Requires
            if ($dep -and $dep.Status -eq 'Failed') {
                Write-Log "Skipped - dependency $($p.Requires) failed." -Level ERROR
                [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Skipped'; Detail="dep $($p.Requires)" })
                continue
            }
        }

        try {
            if ($p.Kind -eq 'WindowsFeature') {
                if ($PSCmdlet.ShouldProcess('IIS features','Install')) {
                    $r = Install-ServerFeatures -Features $p.Features -DismFeatures $p.DismFeatures
                    if ($r.Reboot) { $script:RebootReq = $true }
                    $st = if ($r.Changed) { 'Installed' } else { 'AlreadyPresent' }
                    Write-Log "$st via $($r.Via)" -Level OK
                    [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status=$st; Detail="$($r.Count) features / $($r.Via)" })
                }
                continue
            }

            if (Test-PackageInstalled $p) {
                $hasConfig = $p.ContainsKey('PreInstall') -or $p.ContainsKey('PostInstall')
                if ($Reconfigure -and $hasConfig) {
                    Write-Log 'Already installed - re-running configuration (-Reconfigure).' -Level WARN
                    try {
                        if ($p.ContainsKey('PreInstall'))  { & $p.PreInstall }
                        if ($p.ContainsKey('PostInstall')) { & $p.PostInstall }
                        [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Reconfigured'; Detail=$p.Version })
                    } catch {
                        Write-Log "  reconfigure failed: $($_.Exception.Message)" -Level ERROR
                        [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Failed'; Detail='reconfigure' })
                    }
                } else {
                    Write-Log 'Already installed.' -Level OK
                    [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='AlreadyPresent'; Detail=$p.Version })
                }
                continue
            }

            if ($p.ContainsKey('PreInstall')) { & $p.PreInstall }

            $logFile  = Join-Path $WorkRoot "Logs\$($p.Name).install.log"
            $instArgs = $p.Args -replace '\{LOG\}',$logFile -replace '\{PORT\}',$ExporterPort

            if ($PSCmdlet.ShouldProcess($p.Name,'Install')) {
                $res = Invoke-Installer -Path $p.LocalPath -Kind $p.Kind -Arguments $instArgs -LogFile $logFile
                if ($res.Reboot) { $script:RebootReq = $true }
                if (-not $res.Ok) {
                    Write-Log $res.Msg -Level ERROR
                    [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Failed'; Detail=$res.Msg })
                    continue
                }
                # Some installers finalise registry/filesystem state slightly after msiexec
                # returns, so give detection a few chances before calling it suspect.
                $seen = $false
                for ($try = 1; $try -le 8; $try++) {
                    Start-Sleep -Seconds 2
                    if (Test-PackageInstalled $p) { $seen = $true; break }
                }
                if (-not $seen) {
                    Write-Log "Installer reported success but detection failed after 16s - check $logFile" -Level WARN
                    Show-DetectionDiagnostics -Pkg $p -Keyword ($p.Name -replace '[^A-Za-z]','' )
                    [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Suspect'; Detail='installed, not detected'})
                } else {
                    Write-Log "$($res.Msg)  ($($p.Version))" -Level OK
                    [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Installed'; Detail=$p.Version })
                }
                # PostInstall is diagnostics/config. A failure there must not turn a successful
                # install into 'Failed' - that is what produced the duplicate WindowsExporter row.
                if ($p.ContainsKey('PostInstall')) {
                    try { & $p.PostInstall }
                    catch { Write-Log "  post-install step failed: $($_.Exception.Message)" -Level ERROR }
                }

                if ($p.Name -like 'HostingBundle_*') {
                    [void]$script:AncmTrail.Add([pscustomobject]@{ Bundle = $p.Version; Ancm = (Get-AncmVersion) })
                }
            }
        }
        catch {
            Write-Log "$($p.Name): $($_.Exception.Message)" -Level ERROR
            [void]$script:Results.Add([pscustomobject]@{ Name=$p.Name; Status='Failed'; Detail=$_.Exception.Message })
        }
    }
}
#endregion

#region ========================= PHASE 5 - VERIFY =============================

function Invoke-PostChecks {
    param($Plan)
    Write-Log 'PHASE 5 - VERIFY' -Level STEP

    # ANCM has its OWN version line (13.x, 16.x, 20.x ...) unrelated to the .NET major.
    # Comparing it against '10' was meaningless. The real invariant is that installing bundles
    # in ascending order must never DECREASE it.
    $ancm = Get-AncmVersion
    if ($script:AncmTrail.Count) {
        Write-Log 'ASP.NET Core Module after each bundle:'
        $prev = $null; $downgraded = $false
        foreach ($t in $script:AncmTrail) {
            Write-Log "  after .NET $($t.Bundle) -> ANCM $($t.Ancm)"
            if ($prev -and $t.Ancm) {
                try { if ([version]$t.Ancm -lt [version]$prev) { $downgraded = $true } } catch { }
            }
            if ($t.Ancm) { $prev = $t.Ancm }
        }
        if ($downgraded) {
            Write-Log 'ANCM was DOWNGRADED by a later bundle. Re-run the newest hosting bundle.' -Level ERROR
        } else {
            Write-Log "ASP.NET Core Module: v$ancm (never downgraded)" -Level OK
        }
    }
    elseif ($ancm) { Write-Log "ASP.NET Core Module: v$ancm" -Level OK }
    else           { Write-Log 'aspnetcorev2.dll not found - IIS cannot host ASP.NET Core apps.' -Level WARN }

    $fx = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.AspNetCore.App'
    if (Test-Path $fx) { Write-Log "ASP.NET Core runtimes: $(((Get-ChildItem $fx -Directory).Name) -join ', ')" -Level OK }

    $rel = Get-NetFxRelease
    Write-Log ".NET Framework release key: $rel $(if($rel -ge 533320){'(4.8.1)'}elseif($rel -ge 528040){'(4.8)'}else{'(<4.8)'})"

    if (Get-Service W3SVC -EA SilentlyContinue) {
        if ((Get-Service W3SVC).Status -ne 'Running') { Start-Service W3SVC -EA SilentlyContinue }
        if ($ancm) { Write-Log 'iisreset to load ANCM ...'; & "$env:SystemRoot\System32\iisreset.exe" /noforce | Out-Null }
    }
}

function Write-Summary {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    $script:Results | Format-Table -AutoSize Name, Status, Detail | Out-String -Width 200 | Write-Host

    $bad = $script:Results | Where-Object Status -in @('Failed','Suspect','Skipped','Unavailable')
    if ($bad) { Write-Log "$($bad.Count) package(s) need attention. Logs: $WorkRoot\Logs" -Level ERROR }
    else      { Write-Log 'All packages completed successfully.' -Level OK }

    if ($script:RebootReq -or (Test-PendingReboot)) {
        Write-Host ''
        Write-Host '  *** REBOOT REQUIRED - nothing was restarted ***' -ForegroundColor Yellow
        Write-Host '  Reboot when convenient, then re-run to confirm a clean idempotent pass.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Log "Transcript: $script:Log"
}
#endregion

#region ============================== MAIN ====================================
try {
    Assert-Elevated
    foreach ($d in @('Cache','Logs')) {
        $pp = Join-Path $WorkRoot $d
        if (-not (Test-Path $pp)) { New-Item -ItemType Directory -Path $pp -Force | Out-Null }
    }
    $script:Log = Join-Path $WorkRoot ('Logs\baseline-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    Write-Log 'Windows Server baseline provisioning' -Level STEP
    Initialize-Tls
    $osi = Get-OSInfo
    Write-Log "Host: $($osi.Caption)  build $($osi.Build)  $($osi.Arch)"
    if ($osi.Arch -notmatch '64') { throw 'x64 required.' }

    $plan = Invoke-Discovery

    Show-Plan -Plan $plan | Out-Null

    if ($DiscoverOnly) { Write-Log 'Discovery complete (-DiscoverOnly). Nothing changed.' -Level OK; exit 0 }

    $selected = Select-Packages -Plan $plan
    if ($null -eq $selected) { exit 2 }
    foreach ($p in $plan) { $p.Selected = ($selected -contains $p.Name) }

    if (-not $selected.Count -and -not $Reconfigure) {
        Write-Log 'Nothing selected. Exiting without changes.' -Level WARN
        exit 0
    }

    Write-Log "Will install: $($selected -join ', ')" -Level STEP
    # Choosing from the menu already IS the confirmation - a second y/n is just noise.
    if (-not $script:SelectionWasInteractive) {
        if (-not (Confirm-Proceed)) { exit 2 }
    }
    if (-not (Invoke-Acquire -Plan $plan)) { Write-Log 'Aborted before install.' -Level WARN; exit 2 }

    Invoke-Install    -Plan $plan
    Invoke-PostChecks -Plan $plan
    Write-Summary

    if ($script:Results | Where-Object Status -eq 'Failed') { exit 1 }
    if ($script:RebootReq) { exit 3010 }
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
#endregion
