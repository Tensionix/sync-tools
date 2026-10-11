# The window of ONE copy of the program driven without a mouse and without keys sent to whatever
# is in front: through UI Automation, by the full path of the exe. For a release build, which has
# no dev steps. A real pointer clicks into the window on top, and that may be the owner's.
#
#   dev-uia.ps1 -Exe <exe> -Tree                      what the windows of the copy hold: type and name
#   dev-uia.ps1 -Exe <exe> -Select "Audion Backup X"  put the dot of a radio button whose row holds that text
#   dev-uia.ps1 -Exe <exe> -Invoke "DOWNLOAD"         press the button of that name
#   dev-uia.ps1 -Exe <exe> -Toggle "LOCAL"            press a switch of that name
#   -In "Title"                                       look only in the window whose title holds that text
param(
    [Parameter(Mandatory)][string]$Exe,
    [switch]$Tree,
    [string]$Select = '',
    [string]$Invoke = '',
    [string]$Toggle = '',
    [string]$In = '',
    [int]$Depth = 12
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$full = (Resolve-Path -LiteralPath $Exe).Path
$process = Get-Process | Where-Object { $_.Path -eq $full } | Select-Object -First 1
if (-not $process) { throw "no process of $full" }

$auto = [System.Windows.Automation.AutomationElement]
$byProcess = New-Object System.Windows.Automation.PropertyCondition($auto::ProcessIdProperty, $process.Id)
$windows = @($auto::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $byProcess))
if ($In) { $windows = @($windows | Where-Object { $_.Current.Name -like "*$In*" }) }
if (-not $windows.Count) { throw 'the copy has no window to look into' }
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

function Show-Element($element, [int]$level) {
    if ($level -gt $Depth) { return }
    $type = $element.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $name = "$($element.Current.Name)".Replace("`r", ' ').Replace("`n", ' ')
    if ($name.Length -gt 70) { $name = $name.Substring(0, 70) + '…' }
    ('{0}{1}  "{2}"{3}' -f ('  ' * $level), $type, $name, $(if ($element.Current.IsEnabled) { '' } else { '  (disabled)' }))
    $child = $walker.GetFirstChild($element)
    while ($child) { Show-Element $child ($level + 1); $child = $walker.GetNextSibling($child) }
}

function Find-All($type) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($auto::ControlTypeProperty, $type)
    foreach ($window in $windows) { $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) }
}

if ($Tree) { foreach ($window in $windows) { Show-Element $window 0 }; return }

if ($Select) {
    # The row of a radio button is a caption and a note: the text is looked for in the button and under it.
    foreach ($radio in Find-All ([System.Windows.Automation.ControlType]::RadioButton)) {
        $texts = @($radio.Current.Name) + @($radio.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
        if ($texts -contains $Select) {
            $radio.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            "selected: $Select"; return
        }
    }
    throw "no radio button with: $Select"
}

if ($Invoke -or $Toggle) {
    $wanted = if ($Invoke) { $Invoke } else { $Toggle }
    foreach ($button in Find-All ([System.Windows.Automation.ControlType]::Button)) {
        $texts = @($button.Current.Name) + @($button.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
        if ($texts -notcontains $wanted) { continue }
        if (-not $button.Current.IsEnabled) { throw "the button is disabled: $wanted" }
        $pattern = $null
        if ($button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); "pressed: $wanted"; return }
        if ($button.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle(); "switched: $wanted"; return }
        throw "the button cannot be pressed: $wanted"
    }
    throw "no button: $wanted"
}
