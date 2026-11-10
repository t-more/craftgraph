# Installs the CraftGraph addon into World of Warcraft Forever on Windows.
# Started by "Install CraftGraph.cmd" (double-click that), or run directly:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# It copies the CraftGraph folder that sits next to this script into the
# game's Interface\AddOns folder. It changes nothing else on the computer.
param([string]$GameFolder = "")

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "CraftGraph installer"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }

function Finish($code) {
    Write-Host ""
    Read-Host "Press Enter to close" | Out-Null
    exit $code
}

try {
    Say ""
    Say "  CraftGraph for World of Warcraft Forever" "Yellow"
    Say "  ----------------------------------------" "DarkYellow"
    Say ""

    $source = Join-Path $PSScriptRoot "CraftGraph"
    if (-not (Test-Path (Join-Path $source "CraftGraph.toc"))) {
        Say "The CraftGraph folder is not next to this installer." "Red"
        Say "Unzip the whole download first, then run the installer from the unzipped folder."
        Finish 1
    }
    $version = "?"
    foreach ($line in Get-Content (Join-Path $source "CraftGraph.toc")) {
        if ($line -match "^## Version:\s*(.+)$") { $version = $Matches[1].Trim() }
    }

    # Is there a newer release than the one in this folder? Only asks GitHub
    # for the latest version number; skipped quietly without a connection.
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/t-more/craftgraph/releases/latest" `
            -Headers @{ "User-Agent" = "craftgraph-installer" } -TimeoutSec 8
        $latest = "$($release.tag_name)".TrimStart("v", "V")
        if ([version]$latest -gt [version]$version) {
            Say "A newer version is out: $latest (this folder holds $version)." "Yellow"
            Say "Get it here: https://github.com/t-more/craftgraph/releases/latest"
            Say "Carrying on with $version."
            Say ""
        }
    } catch { }

    # Where the game might be: what was given, what the game wrote in the
    # registry, and the usual folders on every drive.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($GameFolder) { $candidates.Add($GameFolder) }
    foreach ($key in @(
            "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
            "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft")) {
        try {
            $path = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($path) {
                $candidates.Add($path)
                $candidates.Add((Split-Path $path.TrimEnd('\') -Parent))
            }
        } catch { }
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq "Fixed" -and $drive.IsReady) {
            $root = $drive.RootDirectory.FullName
            foreach ($sub in @("Program Files (x86)\World of Warcraft", "Program Files\World of Warcraft",
                    "World of Warcraft", "Games\World of Warcraft", "Blizzard\World of Warcraft")) {
                $candidates.Add((Join-Path $root $sub))
            }
        }
    }

    # A candidate may be the game folder itself or its _forever_ folder.
    function Find-Forever($path) {
        if (-not $path -or -not (Test-Path $path)) { return $null }
        if ((Split-Path $path.TrimEnd('\') -Leaf) -eq "_forever_") { return $path.TrimEnd('\') }
        $inner = Join-Path $path "_forever_"
        if (Test-Path $inner) { return $inner }
        return $null
    }

    $forever = $null
    foreach ($candidate in $candidates) {
        $forever = Find-Forever $candidate
        if ($forever) { break }
    }

    if (-not $forever) {
        Say "Could not find World of Warcraft Forever by itself."
        Say "A window opens now: pick your World of Warcraft folder (the one that holds _forever_)."
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Pick your World of Warcraft folder (the one that holds _forever_)"
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Say "Nothing was installed." "Yellow"
            Finish 1
        }
        $forever = Find-Forever $dialog.SelectedPath
        if (-not $forever) {
            Say "That folder has no _forever_ folder in it, so it is not a World of Warcraft Forever install." "Red"
            Say "Nothing was installed."
            Finish 1
        }
    }

    $addons = Join-Path $forever "Interface\AddOns"
    $target = Join-Path $addons "CraftGraph"
    Say "Game found:   $forever"
    Say "Installing:   CraftGraph $version"
    Say "Into:         $target"
    Say ""

    # Online price data written by the optional sync tool is kept.
    $online = Join-Path $target "Data\Online.lua"
    $keptOnline = $null
    if (Test-Path $online) {
        $first = Get-Content $online -TotalCount 1
        if ($first -notmatch "This file is replaced by") {
            $keptOnline = Join-Path $env:TEMP ("CraftGraph-Online-" + [guid]::NewGuid().ToString() + ".lua")
            Copy-Item $online $keptOnline
        }
    }

    New-Item -ItemType Directory -Force -Path $addons | Out-Null
    $updating = Test-Path $target
    if ($updating) { Remove-Item -Recurse -Force $target }
    Copy-Item -Recurse -Force $source $target
    if ($keptOnline) {
        Copy-Item -Force $keptOnline $online
        Remove-Item -Force $keptOnline
    }

    if (-not (Test-Path (Join-Path $target "CraftGraph.toc"))) {
        Say "The copy did not arrive. Nothing usable was installed." "Red"
        Finish 1
    }

    if ($updating) { Say "Updated to CraftGraph $version." "Green" } else { Say "Installed CraftGraph $version." "Green" }
    Say ""
    Say "Your prices, plans and settings are stored elsewhere by the game and were not touched."
    if (Get-Process -Name "Wow*" -ErrorAction SilentlyContinue) {
        Say "The game is running: quit it fully and start it again to load the addon." "Yellow"
    } else {
        Say "Start the game, tick CraftGraph under AddOns on the character screen, and type /cg in game."
    }
    Finish 0
}
catch {
    Say ""
    Say "Something went wrong and the install may be incomplete:" "Red"
    Say ("  " + $_.Exception.Message) "Red"
    Say "You can also install by hand: copy the CraftGraph folder into"
    Say "  World of Warcraft\_forever_\Interface\AddOns\"
    Finish 1
}
