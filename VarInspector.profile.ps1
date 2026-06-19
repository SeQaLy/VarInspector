<#
.SYNOPSIS
    VarInspector を PowerShell のコマンドとして使えるようにするローダー（関数版）。

.DESCRIPTION
    このファイルを PowerShell プロファイル ($PROFILE) で読み込むと、
    `VarInspector` コマンドが使えるようになります。

      VarInspector                      … GUI を起動（別プロセス・コンソールは止まりません）
      VarInspector -Gui .\src           … 対象を指定して GUI 起動（開いた直後に自動抽出）
      VarInspector -Path .\src -Recurse … CUI で抽出（その場で実行、結果を表示/パイプ可）
      VarInspector .\main.go -Format Json -OutFile vars.json

    ── 導入手順 ───────────────────────────────────────────────
    プロファイルに次の1行を追記します（このファイルのフルパスを指定）:

        . "Z:\develop\VarInspector\VarInspector.profile.ps1"

    かんたん追記（PowerShell で一度だけ実行。このファイルを読み込み済みなら）:

        Install-VarInspectorProfile

    手動で追記する場合の例:

        if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
        Add-Content -LiteralPath $PROFILE -Value '. "Z:\develop\VarInspector\VarInspector.profile.ps1"'

    ※ VarInspector.ps1 はこのローダーと同じフォルダに置いてください。
#>

# このローダーと VarInspector.ps1 の場所を記憶（関数から確実に参照できるよう Global に保持）
$Global:VarInspectorScriptPath = Join-Path $PSScriptRoot 'VarInspector.ps1'
$Global:VarInspectorLoaderPath = $PSCommandPath

function Invoke-VarInspector {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [switch]$Recurse,
        [switch]$Gui,
        [ValidateSet('Console', 'Csv', 'Json', 'Object')][string]$Format = 'Console',
        [string]$OutFile,
        [string[]]$Include,
        [ValidateSet('Global', 'Package', 'Member', 'Local', 'Parameter')][string[]]$Scope,
        [switch]$ExportedOnly,
        [int]$ThrottleLimit = 0
    )

    $scriptPath = $Global:VarInspectorScriptPath
    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
        Write-Error "VarInspector.ps1 が見つかりません: $scriptPath（このローダーと同じフォルダに置いてください）"
        return
    }

    # 対象も -Gui も指定が無ければ GUI 起動とみなす
    $useGui = $Gui.IsPresent -or (-not $Path -or @($Path).Count -eq 0)

    if ($useGui) {
        # GUI は別プロセスで起動してコンソールをブロックしない（-NoProfile で高速・再帰読込防止、-STA で確実に）
        $exe = $null
        try { $exe = (Get-Process -Id $PID -ErrorAction Stop).Path } catch {}
        if (-not $exe) { $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' } }

        $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Gui')
        if ($Path -and @($Path).Count -gt 0) {
            $argList += '-Path'
            foreach ($p in @($Path)) { $argList += ('"{0}"' -f ($p -replace '"', '')) }
        }
        Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
        Write-Host 'VarInspector の GUI を起動しました。' -ForegroundColor DarkCyan
        return
    }

    # CUI はその場で実行（結果をそのまま出力＝パイプライン連携可）
    $forward = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'Gui') { continue }
        $forward[$kv.Key] = $kv.Value
    }
    & $scriptPath @forward
}

# $PROFILE にこのローダーの読み込み行を追記する補助コマンド（重複は追記しない）
function Install-VarInspectorProfile {
    [CmdletBinding()]
    param()
    $loader = $Global:VarInspectorLoaderPath
    if (-not $loader -or -not (Test-Path -LiteralPath $loader)) {
        Write-Error 'ローダーのパスを特定できませんでした。手動で $PROFILE に追記してください。'
        return
    }
    $line = '. "{0}"' -f $loader
    if (-not (Test-Path -LiteralPath $PROFILE)) {
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }
    $existing = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing.Contains($loader)) {
        Write-Host "既に $PROFILE に登録済みです。" -ForegroundColor Yellow
        return
    }
    Add-Content -LiteralPath $PROFILE -Value $line -Encoding UTF8
    Write-Host "登録しました: $PROFILE" -ForegroundColor Green
    Write-Host '新しい PowerShell を開くか、次を実行して反映してください:' -ForegroundColor Gray
    Write-Host "    . `"$loader`"" -ForegroundColor Gray
}

# `VarInspector` コマンド（および短縮 `vins`）を提供
Set-Alias -Name VarInspector -Value Invoke-VarInspector -Scope Global -Force
Set-Alias -Name vins -Value Invoke-VarInspector -Scope Global -Force
