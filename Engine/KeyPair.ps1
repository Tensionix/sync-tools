<#
    Пары ключей ssh без пароля - одним способом на всю программу.

    Способ был один, а мест создания - два: ключ машины заводило окно, ключ
    REVERSE SSH TUN - Setup-SshBeacon.ps1, и сценарий звал ssh-keygen по-своему. Под
    PowerShell 7 `-N '""'` отдаёт ssh-keygen две кавычки, и тот берёт их за
    пароль: ключ создан, код выхода ноль, а держатель канала с BatchMode на нём
    молча виснет. Поэтому функции живут здесь, и их дот-сорсят и окно, и
    сценарии.
#>

function Test-AbkKeyOpens {
    <#
        Открывается ли приватный ключ без пароля: из него обязан выводиться
        публичный, без единого вопроса. Сам публичный ключ остаётся в
        переменной и никуда не печатается.

        Пустой пароль передаётся явно, `-P ""`. Закрытый стандартный ввод
        ssh-keygen не останавливает: пароль он спрашивает у консоли, и на ключе
        с паролем прежняя проверка висела, пока процесс не снимут руками. С
        `-P ""` такой ключ отвергается сразу, кодом 255. На случай иного
        ssh-keygen у проверки есть и предел времени: не уложилась - ключ не
        годится, процесс снимается вместе с дочерним.

        Зовём через cmd: Windows PowerShell 5.1 теряет пустую строку при
        передаче нативной программе.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 15
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $process = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'cmd.exe'
        $info.Arguments = '/d /c ssh-keygen -y -P "" -f "{0}" 2>&1' -f $Path
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $reading = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            return $false
        }
        $derived = $reading.Result
        return ($process.ExitCode -eq 0 -and "$derived" -match '(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) ')
    } catch {
        return $false
    } finally {
        if ($process) { $process.Dispose() }
        $ErrorActionPreference = $was
    }
}

function New-AbkKeyPair {
    <#
        Пара ключей без пароля - и проверка, что она такой вышла.

        Зовём через cmd: Windows PowerShell 5.1 теряет пустую строку при
        передаче нативной программе («Too many arguments»), а `-N '""'`
        отдаёт ssh-keygen две кавычки, и тот берёт их за пароль. Ключ при
        этом создаётся и выглядит целым; негодность вскрывается позже, когда
        автоматика молча виснет на вводе.

        Поэтому проверяем сразу: из закрытой половины обязана выводиться
        открытая, без единого вопроса. Негодную пару удаляем - её создали
        только что, и ничего, кроме неё, она не заменяла.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Comment
    )

    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $line = 'ssh-keygen -t ed25519 -f "{0}" -N "" -C "{1}" 2>&1' -f $Path, $Comment
        $said = & cmd.exe /c $line
    } finally {
        $ErrorActionPreference = $was
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Ok = $false; Said = @($said) }
    }

    if (-not (Test-AbkKeyOpens -Path $Path)) {
        # Ключ с паролем автоматике не годится: спросить его некому.
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($Path + '.pub') -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Said = @($said) }
    }

    return @{ Ok = $true; Said = @($said) }
}
