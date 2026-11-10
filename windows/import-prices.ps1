# Brings a CraftGraph prices file (.cg.json) into the game.
# Started by "Import CraftGraph data.cmd". The game cannot open files, so
# this puts the file's text where the addon reads it at the next login.
param([string]$File = "")
$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "CraftGraph: import shared prices"
function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Finish($code) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null; exit $code }
try {
    Say ""
    Say "  CraftGraph: import shared prices" "Yellow"
    Say ""
    if (-not $File) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Pick the CraftGraph prices file you were sent"
        $dialog.Filter = "CraftGraph prices (*.cg.json;*.cgjson)|*.cg.json;*.cgjson|JSON files (*.json)|*.json|All files (*.*)|*.*"
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Say "Nothing was imported." "Yellow"; Finish 1 }
        $File = $dialog.FileName
    }
    $text = [System.IO.File]::ReadAllText($File)
    try { $data = $text | ConvertFrom-Json } catch { Say "That file is not valid JSON." "Red"; Finish 1 }
    if ($data.format -ne "craftgraph-prices" -or -not $data.items) { Say "That file is JSON, but not CraftGraph prices." "Red"; Finish 1 }
    $count = @($data.items.PSObject.Properties).Count

    # The addon folder: next to this script when run from the unzipped
    # download is not it; the one in the game is.
    $target = $null
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq "Fixed" -and $drive.IsReady) {
            foreach ($sub in @("Program Files (x86)\World of Warcraft", "Program Files\World of Warcraft",
                    "World of Warcraft", "Games\World of Warcraft", "Blizzard\World of Warcraft")) {
                $candidate = Join-Path $drive.RootDirectory.FullName ($sub + "\_forever_\Interface\AddOns\CraftGraph\Data")
                if (-not $target -and (Test-Path $candidate)) { $target = $candidate }
            }
        }
    }
    if (-not $target) {
        Say "Could not find CraftGraph in the game. Pick your World of Warcraft folder (the one that holds _forever_)."
        Add-Type -AssemblyName System.Windows.Forms
        $folder = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($folder.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Say "Nothing was imported." "Yellow"; Finish 1 }
        $target = Join-Path $folder.SelectedPath "_forever_\Interface\AddOns\CraftGraph\Data"
        if (-not (Test-Path $target)) { Say "CraftGraph is not installed there. Install it first." "Red"; Finish 1 }
    }
    $level = ""
    while ($text.Contains("]" + $level + "]")) { $level += "=" }
    $lua = "-- Put here by Import CraftGraph data. Read by the addon at login.`r`nlocal _, ns = ...`r`nns.SharedFile = [$level[" + $text + "]$level]`r`n"
    [System.IO.File]::WriteAllText((Join-Path $target "Shared.lua"), $lua, (New-Object System.Text.UTF8Encoding($false)))
    Say "Ready: $count prices for `"$($data.realm)`" from $($data.from)." "Green"
    Say "Log in (or type /reload) and the game says in chat how many it took in."
    Say "In game, /cg sources shows them and lets you switch them off."
    Finish 0
} catch {
    Say ("Something went wrong: " + $_.Exception.Message) "Red"
    Say "You can also paste the file's text in game: /cg import"
    Finish 1
}
