<#
.SYNOPSIS
    ソースコード（Go / C / C++）から変数を抽出するツール。CUI / GUI 両対応・並列処理。

.DESCRIPTION
    指定したファイル単体、またはフォルダ（再帰可）を走査し、変数を抽出して
    「変数名 / 型 / スコープ / 公開(外部公開)か否か」を一覧化します。
    PowerShell 標準機能のみで動作し、特別なインストールは不要です。
    解析は RunspacePool による並列処理で高速化しています。

.PARAMETER Path
    解析対象。ファイルパスまたはフォルダパス（複数指定可）。

.PARAMETER Recurse
    フォルダをサブフォルダまで再帰的に走査します。

.PARAMETER Gui
    GUI（WinForms）を起動します。

.PARAMETER Format
    CUI 出力形式: Console / Csv / Json / Object（既定: Console）。

.PARAMETER OutFile
    出力先ファイル。指定すると Format に応じて保存します。

.PARAMETER Include
    対象拡張子を上書き（ドットなし、例: go,c,cpp,h,hpp）。

.PARAMETER Scope
    抽出後にスコープで絞り込み（Global,Package,Member,Local,Parameter）。

.PARAMETER ExportedOnly
    外部公開されている変数のみに絞り込みます。

.PARAMETER ThrottleLimit
    並列度（0 = CPU コア数）。

.EXAMPLE
    .\VarInspector.ps1 -Path .\src -Recurse

.EXAMPLE
    .\VarInspector.ps1 -Path .\main.go -Format Json -OutFile vars.json

.EXAMPLE
    .\VarInspector.ps1 -Gui
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [switch]$Recurse,
    [switch]$Gui,

    [ValidateSet('Console', 'Csv', 'Json', 'Object')]
    [string]$Format = 'Console',

    [string]$OutFile,

    [string[]]$Include,

    [ValidateSet('Global', 'Package', 'Member', 'Local', 'Parameter')]
    [string[]]$Scope,

    [switch]$ExportedOnly,

    [int]$ThrottleLimit = 0
)

# ===========================================================================
#  既定の対象拡張子
# ===========================================================================
$script:DefaultExtensions = @(
    'go',                                              # Go
    'c', 'h',                                          # C
    'cpp', 'cc', 'cxx', 'c++', 'hpp', 'hh', 'hxx', 'h++', 'ipp', 'tpp', 'inl'  # C++
)

# ===========================================================================
#  1ファイルを解析するスクリプト（並列ワーカーへ注入するため自己完結）
# ===========================================================================
$script:ParseFileScript = {
    param($FilePath)

    # ---- ユーティリティ ----------------------------------------------------

    # コメント / 文字列 / 文字リテラル / プリプロセッサ行を空白化（行番号は保持）
    function Get-CleanCode {
        param([string]$Text, [bool]$Preproc, [bool]$GoRaw)
        $n = $Text.Length
        $sb = New-Object System.Text.StringBuilder $n
        $i = 0
        $atLineStart = $true
        $NL = [char]10
        while ($i -lt $n) {
            $c = $Text[$i]
            $d = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }

            if ($c -eq $NL) { [void]$sb.Append($c); $atLineStart = $true; $i++; continue }
            if ($c -eq [char]13) { [void]$sb.Append($c); $i++; continue }   # CR
            if ([char]::IsWhiteSpace($c)) { [void]$sb.Append($c); $i++; continue }

            # プリプロセッサ行（C/C++）: 行継続 \ も処理
            if ($Preproc -and $atLineStart -and $c -eq [char]'#') {
                while ($i -lt $n) {
                    $cc = $Text[$i]
                    if ($cc -eq $NL) {
                        $k = $i - 1
                        while ($k -ge 0 -and ($Text[$k] -eq [char]' ' -or $Text[$k] -eq [char]9 -or $Text[$k] -eq [char]13)) { $k-- }
                        [void]$sb.Append($NL); $i++
                        if ($k -ge 0 -and $Text[$k] -eq [char]'\') { continue } else { break }
                    }
                    else { [void]$sb.Append(' '); $i++ }
                }
                $atLineStart = $true
                continue
            }

            $atLineStart = $false

            # 行コメント
            if ($c -eq [char]'/' -and $d -eq [char]'/') {
                while ($i -lt $n -and $Text[$i] -ne $NL) { [void]$sb.Append(' '); $i++ }
                continue
            }
            # ブロックコメント
            if ($c -eq [char]'/' -and $d -eq [char]'*') {
                [void]$sb.Append('  '); $i += 2
                while ($i -lt $n) {
                    if ($Text[$i] -eq [char]'*' -and ($i + 1 -lt $n) -and $Text[$i + 1] -eq [char]'/') { [void]$sb.Append('  '); $i += 2; break }
                    if ($Text[$i] -eq $NL) { [void]$sb.Append($NL) } else { [void]$sb.Append(' ') }
                    $i++
                }
                continue
            }
            # 文字列 "..."
            if ($c -eq [char]'"') {
                [void]$sb.Append('"'); $i++
                while ($i -lt $n) {
                    $cc = $Text[$i]
                    if ($cc -eq [char]'\') {
                        [void]$sb.Append(' '); $i++
                        if ($i -lt $n) { if ($Text[$i] -eq $NL) { [void]$sb.Append($NL) } else { [void]$sb.Append(' ') }; $i++ }
                        continue
                    }
                    if ($cc -eq [char]'"') { [void]$sb.Append('"'); $i++; break }
                    if ($cc -eq $NL) { [void]$sb.Append($NL) } else { [void]$sb.Append(' ') }
                    $i++
                }
                continue
            }
            # 文字リテラル '...'
            if ($c -eq [char]"'") {
                [void]$sb.Append("'"); $i++
                while ($i -lt $n) {
                    $cc = $Text[$i]
                    if ($cc -eq [char]'\') { [void]$sb.Append(' '); $i++; if ($i -lt $n) { [void]$sb.Append(' '); $i++ }; continue }
                    if ($cc -eq [char]"'") { [void]$sb.Append("'"); $i++; break }
                    [void]$sb.Append(' '); $i++
                }
                continue
            }
            # Go raw string `...`
            if ($GoRaw -and $c -eq [char]'`') {
                [void]$sb.Append(' '); $i++
                while ($i -lt $n) {
                    if ($Text[$i] -eq [char]'`') { [void]$sb.Append(' '); $i++; break }
                    if ($Text[$i] -eq $NL) { [void]$sb.Append($NL) } else { [void]$sb.Append(' ') }
                    $i++
                }
                continue
            }

            [void]$sb.Append($c); $i++
        }
        return $sb.ToString()
    }

    # トップレベル（括弧外）で区切り文字で分割
    function Split-TopLevel {
        param([string]$s, [char]$delim)
        $res = New-Object System.Collections.Generic.List[string]
        $d = 0; $a = 0; $ang = 0
        $cur = New-Object System.Text.StringBuilder
        foreach ($ch in $s.ToCharArray()) {
            if ($ch -eq [char]'(') { $d++ }
            elseif ($ch -eq [char]')') { if ($d -gt 0) { $d-- } }
            elseif ($ch -eq [char]'{') { $d++ }
            elseif ($ch -eq [char]'}') { if ($d -gt 0) { $d-- } }
            elseif ($ch -eq [char]'[') { $a++ }
            elseif ($ch -eq [char]']') { if ($a -gt 0) { $a-- } }
            elseif ($ch -eq [char]'<') { $ang++ }
            elseif ($ch -eq [char]'>') { if ($ang -gt 0) { $ang-- } }

            if ($ch -eq $delim -and $d -eq 0 -and $a -eq 0 -and $ang -eq 0) {
                $res.Add($cur.ToString()); $cur = New-Object System.Text.StringBuilder
            }
            else { [void]$cur.Append($ch) }
        }
        $res.Add($cur.ToString())
        return $res.ToArray()
    }

    # 最初のトップレベル代入 '=' の位置（比較演算子・複合代入は除外）。無ければ -1
    function Get-AssignIndex {
        param([string]$s)
        $d = 0; $a = 0; $ang = 0
        for ($i = 0; $i -lt $s.Length; $i++) {
            $ch = $s[$i]
            if ($ch -eq [char]'(') { $d++ }
            elseif ($ch -eq [char]')') { if ($d -gt 0) { $d-- } }
            elseif ($ch -eq [char]'{') { $d++ }
            elseif ($ch -eq [char]'}') { if ($d -gt 0) { $d-- } }
            elseif ($ch -eq [char]'[') { $a++ }
            elseif ($ch -eq [char]']') { if ($a -gt 0) { $a-- } }
            elseif ($ch -eq [char]'<') { $ang++ }
            elseif ($ch -eq [char]'>') { if ($ang -gt 0) { $ang-- } }

            if ($ch -eq [char]'=' -and $d -eq 0 -and $a -eq 0 -and $ang -eq 0) {
                $p = if ($i -gt 0) { $s[$i - 1] } else { [char]0 }
                $nx = if ($i + 1 -lt $s.Length) { $s[$i + 1] } else { [char]0 }
                $bad = @([char]'=', [char]'!', [char]'<', [char]'>', [char]'+', [char]'-', [char]'*', [char]'/', [char]'%', [char]'&', [char]'|', [char]'^', [char]':')
                if (($bad -notcontains $p) -and ($nx -ne [char]'=')) { return $i }
            }
        }
        return -1
    }

    # トップレベルの () グループの中身を配列で返す
    function Get-ParenGroups {
        param([string]$s)
        $res = New-Object System.Collections.Generic.List[string]
        $d = 0; $start = -1
        for ($i = 0; $i -lt $s.Length; $i++) {
            $ch = $s[$i]
            if ($ch -eq [char]'(') { if ($d -eq 0) { $start = $i + 1 }; $d++ }
            elseif ($ch -eq [char]')') { $d--; if ($d -eq 0 -and $start -ge 0) { $res.Add($s.Substring($start, $i - $start)); $start = -1 } }
        }
        return $res.ToArray()
    }

    function New-VarRecord {
        param($File, $Line, $Lang, $Scope, $Access, [bool]$Exported, $Type, $Name, $Qualifiers, $Decl)
        $decl = if ($Decl) { ($Decl -replace '\s+', ' ').Trim() } else { '' }
        if ($decl.Length -gt 160) { $decl = $decl.Substring(0, 157) + '...' }
        [pscustomobject]@{
            Name        = $Name
            Type        = $Type
            Scope       = $Scope
            Access      = $Access
            Exported    = $Exported
            Language    = $Lang
            Qualifiers  = $Qualifiers
            Line        = $Line
            File        = $File
            Declaration = $decl
        }
    }

    # ---- C / C++ 解析 ------------------------------------------------------

    function Test-TypeBody {
        param([string]$h)
        if ($h -match '\(') { return $null }                  # 関数っぽいものは除外
        if ($h -notmatch '\b(class|struct|union)\b') { return $null }
        if ($h -match '\bunion\b') { return 'union' }
        if ($h -match '\bstruct\b') { return 'struct' }
        return 'class'
    }

    # '{' をスコープ開始とみなすか初期化子とみなすかを判定
    function Get-BraceDecision {
        param([string]$header)
        if ($header -eq '') { return @{ Kind = 'scope'; Frame = @{ Type = 'block'; Access = 'public' } } }
        if ($header -match '\bnamespace\b' -and (Get-AssignIndex $header) -lt 0) {
            return @{ Kind = 'scope'; Frame = @{ Type = 'namespace'; Access = 'public' } }
        }
        $tb = Test-TypeBody $header
        if ($tb) {
            $acc = if ($tb -eq 'class') { 'private' } else { 'public' }
            return @{ Kind = 'scope'; Frame = @{ Type = $tb; Access = $acc } }
        }
        if ($header -match '\benum\b' -and $header -notmatch '\(') {
            return @{ Kind = 'scope'; Frame = @{ Type = 'enum'; Access = 'public' } }
        }
        if ((Get-AssignIndex $header) -ge 0) { return @{ Kind = 'init' } }
        if ($header -match '\)\s*(const|noexcept|override|final|mutable|throw|\->.*|:.*)?$') {
            if ($header -match '^\s*(if|for|while|switch|catch|else|do|return|sizeof)\b') {
                return @{ Kind = 'scope'; Frame = @{ Type = 'block'; Access = 'public' } }
            }
            return @{ Kind = 'scope'; Frame = @{ Type = 'func'; Access = 'public' } }
        }
        if ($header -match '\b(else|try|do)\s*$') {
            return @{ Kind = 'scope'; Frame = @{ Type = 'block'; Access = 'public' } }
        }
        if ($header -notmatch '\(' -and $header -match '^[\w:<>,\*&\s]+\s+\*?[A-Za-z_]\w*(\s*\[[^\]]*\])*$') {
            return @{ Kind = 'init' }
        }
        return @{ Kind = 'scope'; Frame = @{ Type = 'block'; Access = 'public' } }
    }

    # 開き '{' から対応する '}' の直後までスキップ
    function Skip-Braces {
        param([string]$text, [int]$start, [int]$line)
        $d = 0; $i = $start; $n = $text.Length
        $NL = [char]10
        while ($i -lt $n) {
            $c = $text[$i]
            if ($c -eq $NL) { $line++ }
            elseif ($c -eq [char]'{') { $d++ }
            elseif ($c -eq [char]'}') { $d--; if ($d -eq 0) { $i++; break } }
            $i++
        }
        return @{ Index = $i; Line = $line }
    }

    function Get-ScopeInfo {
        param($ctx)
        if ($ctx.Count -eq 0) { return @{ Scope = 'Global'; Access = 'external' } }
        $top = $ctx[$ctx.Count - 1]
        switch ($top.Type) {
            'namespace' { return @{ Scope = 'Global'; Access = 'external' } }
            'class' { return @{ Scope = 'Member'; Access = $top.Access } }
            'struct' { return @{ Scope = 'Member'; Access = $top.Access } }
            'union' { return @{ Scope = 'Member'; Access = $top.Access } }
            default { return @{ Scope = 'Local'; Access = 'local' } }
        }
    }

    # 1つの宣言文から変数レコード（複数宣言子対応）を生成
    function Get-CDeclRecords {
        param($Stmt, $File, $Line, $Lang, $Scope, $DefaultAccess)
        $s = ($Stmt -replace '\s+', ' ').Trim()
        if (-not $s) { return @() }

        $skip = @('return', 'if', 'else', 'for', 'while', 'switch', 'case', 'default', 'break',
            'continue', 'goto', 'do', 'using', 'typedef', 'namespace', 'template', 'friend',
            'delete', 'throw', 'new', 'co_return', 'co_await', 'co_yield', 'static_assert',
            'sizeof', 'assert', 'operator', 'public', 'private', 'protected', 'export',
            'static_cast', 'reinterpret_cast', 'const_cast', 'dynamic_cast')
        $first = ($s -split '[ \(\*&:<]', 2)[0]
        if ($skip -contains $first) { return @() }
        if ($s -match '\boperator\b') { return @() }

        # 先頭の記憶域クラス／修飾子を分離
        $pre = New-Object System.Collections.Generic.List[string]
        $work = $s
        while ($work -match '^(static|extern|const|constexpr|volatile|register|mutable|inline|thread_local|virtual|explicit|friend|typename)\b\s*') {
            $pre.Add($Matches[1]); $work = $work.Substring($Matches[0].Length)
        }
        $work = $work.Trim()
        if (-not $work) { return @() }

        $eq = Get-AssignIndex $work
        $head = if ($eq -ge 0) { $work.Substring(0, $eq) } else { $work }

        $isStatic = $pre -contains 'static'
        $isExtern = $pre -contains 'extern'

        # 関数ポインタ変数
        if ($head -match '\(\s*\*\s*\w+\s*\)\s*\(') {
            if ($work -match '\(\s*\*\s*(?<n>\w+)\s*\)') {
                $name = $Matches.n
                $rec = New-CVarRecord -File $File -Line $Line -Lang $Lang -Scope $Scope -DefaultAccess $DefaultAccess `
                    -IsStatic $isStatic -IsExtern $isExtern -Type '(function pointer)' -Name $name `
                    -Pre ($pre -join ' ') -Decl $s
                return @($rec)
            }
        }
        # 関数宣言／呼び出し／most-vexing-parse は除外
        if ($head -match '\(') { return @() }

        $parts = @(Split-TopLevel $work ',')
        $records = New-Object System.Collections.Generic.List[object]
        $baseType = $null

        for ($pi = 0; $pi -lt $parts.Count; $pi++) {
            $part = $parts[$pi].Trim()
            if ($part -eq '') { continue }
            $pe = Get-AssignIndex $part
            $declHead = if ($pe -ge 0) { $part.Substring(0, $pe).Trim() } else { $part.Trim() }

            $name = $null; $ptr = ''; $arr = ''
            if ($pi -eq 0) {
                if ($declHead -match '^(?<type>.*?)(?<sep>[\s\*&]+)(?<name>[A-Za-z_]\w*)(?<arr>(?:\s*\[[^\]]*\])*)\s*$') {
                    $baseType = $Matches.type.Trim()
                    $name = $Matches.name
                    $ptr = ($Matches.sep -replace '\s', '')
                    $arr = ($Matches.arr -replace '\s', '')
                }
                else { return @() }   # 型+名前に分解できない＝宣言ではない
            }
            else {
                if ($null -eq $baseType) { continue }
                if ($declHead -match '^(?<sep>[\s\*&]*)(?<name>[A-Za-z_]\w*)(?<arr>(?:\s*\[[^\]]*\])*)\s*$') {
                    $name = $Matches.name
                    $ptr = ($Matches.sep -replace '\s', '')
                    $arr = ($Matches.arr -replace '\s', '')
                }
                else { continue }
            }

            $fullType = $baseType
            if ($ptr) { $fullType += ' ' + $ptr }
            if ($arr) { $fullType += $arr }

            $records.Add((New-CVarRecord -File $File -Line $Line -Lang $Lang -Scope $Scope -DefaultAccess $DefaultAccess `
                        -IsStatic $isStatic -IsExtern $isExtern -Type $fullType -Name $name `
                        -Pre ($pre -join ' ') -Decl $s))
        }
        return $records.ToArray()
    }

    function New-CVarRecord {
        param($File, $Line, $Lang, $Scope, $DefaultAccess, [bool]$IsStatic, [bool]$IsExtern, $Type, $Name, $Pre, $Decl)
        switch ($Scope) {
            'Global' {
                if ($IsStatic) { $access = 'private'; $exp = $false }
                elseif ($IsExtern) { $access = 'public'; $exp = $true }
                else { $access = 'public'; $exp = $true }
            }
            'Member' {
                $access = $DefaultAccess
                $exp = ($DefaultAccess -eq 'public')
            }
            default { $access = 'local'; $exp = $false }
        }
        New-VarRecord -File $File -Line $Line -Lang $Lang -Scope $Scope -Access $access -Exported $exp `
            -Type $Type -Name $Name -Qualifiers $Pre -Decl $Decl
    }

    # 関数定義ヘッダから引数を抽出（最初の () グループ）
    function Get-CParamRecords {
        param($Header, $File, $Line, $Lang)
        $groups = @(Get-ParenGroups $Header)
        if ($groups.Count -eq 0) { return @() }
        $inside = $groups[0]
        $recs = New-Object System.Collections.Generic.List[object]
        foreach ($partRaw in @(Split-TopLevel $inside ',')) {
            $part = $partRaw.Trim()
            if ($part -eq '' -or $part -eq 'void' -or $part -eq '...') { continue }
            $pe = Get-AssignIndex $part
            if ($pe -ge 0) { $part = $part.Substring(0, $pe).Trim() }
            if ($part -match '^(?<type>.*?)(?<sep>[\s\*&]+)(?<name>[A-Za-z_]\w*)(?<arr>(?:\s*\[[^\]]*\])*)\s*$') {
                $type = $Matches.type.Trim()
                $ptr = ($Matches.sep -replace '\s', '')
                $arr = ($Matches.arr -replace '\s', '')
                $pname = $Matches.name
                if ($ptr) { $type += ' ' + $ptr }
                if ($arr) { $type += $arr }
                $recs.Add((New-VarRecord -File $File -Line $Line -Lang $Lang -Scope 'Parameter' `
                            -Access 'parameter' -Exported $false -Type $type -Name $pname -Qualifiers 'param' -Decl $Header))
            }
        }
        return $recs.ToArray()
    }

    function Get-CLikeVariables {
        param($Text, $File, $Lang)
        $clean = Get-CleanCode -Text $Text -Preproc $true -GoRaw $false
        $results = New-Object System.Collections.Generic.List[object]
        $n = $clean.Length
        $ctx = New-Object System.Collections.Generic.List[object]
        $buf = New-Object System.Text.StringBuilder
        $bufHas = $false
        $segLine = 1
        $line = 1
        $paren = 0
        $i = 0
        $NL = [char]10
        while ($i -lt $n) {
            $c = $clean[$i]
            if ($c -eq $NL) { $line++; if ($bufHas) { [void]$buf.Append(' ') }; $i++; continue }

            if ($c -eq [char]'{') {
                $header = ($buf.ToString() -replace '\s+', ' ').Trim()
                $dec = Get-BraceDecision $header
                if ($dec.Kind -eq 'init') {
                    $r = Skip-Braces $clean $i $line
                    $i = $r.Index; $line = $r.Line
                    continue
                }
                else {
                    $ctx.Add($dec.Frame)
                    if ($dec.Frame.Type -eq 'func') {
                        foreach ($pr in (Get-CParamRecords -Header $header -File $File -Line $segLine -Lang $Lang)) { $results.Add($pr) }
                    }
                    [void]$buf.Clear(); $bufHas = $false; $paren = 0
                    $i++; continue
                }
            }
            if ($c -eq [char]'}') {
                if ($ctx.Count -gt 0) { $ctx.RemoveAt($ctx.Count - 1) }
                [void]$buf.Clear(); $bufHas = $false; $paren = 0
                $i++; continue
            }
            if ($c -eq [char]';' -and $paren -le 0) {
                $stmt = $buf.ToString()
                $si = Get-ScopeInfo $ctx
                foreach ($rr in (Get-CDeclRecords -Stmt $stmt -File $File -Line $segLine -Lang $Lang -Scope $si.Scope -DefaultAccess $si.Access)) {
                    $results.Add($rr)
                }
                [void]$buf.Clear(); $bufHas = $false; $paren = 0
                $i++; continue
            }
            if ($c -eq [char]'(') { $paren++ }
            elseif ($c -eq [char]')') { if ($paren -gt 0) { $paren-- } }
            if ($c -eq [char]':') {
                if ($i + 1 -lt $n -and $clean[$i + 1] -eq [char]':') {
                    if (-not $bufHas) { $bufHas = $true; $segLine = $line }
                    [void]$buf.Append('::'); $i += 2; continue
                }
                $t = ($buf.ToString() -replace '\s+', ' ').Trim()
                $top = if ($ctx.Count -gt 0) { $ctx[$ctx.Count - 1] } else { $null }
                if ($paren -le 0 -and $top -and ($top.Type -in @('class', 'struct', 'union')) -and ($t -in @('public', 'private', 'protected'))) {
                    $top.Access = $t
                    [void]$buf.Clear(); $bufHas = $false; $i++; continue
                }
                [void]$buf.Append(':'); $i++; continue
            }

            if (-not [char]::IsWhiteSpace($c)) { if (-not $bufHas) { $bufHas = $true; $segLine = $line } }
            [void]$buf.Append($c); $i++
        }
        return $results
    }

    # ---- Go 解析 -----------------------------------------------------------

    function Test-GoExported { param([string]$Name) return ($Name.Length -gt 0 -and [char]::IsUpper($Name[0])) }

    function ConvertTo-GoVarSpec {
        param([string]$rest)
        $rest = $rest.Trim()
        $eq = Get-AssignIndex $rest
        $head = if ($eq -ge 0) { $rest.Substring(0, $eq).Trim() } else { $rest }
        if ($head -match '^(?<names>[A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*)(\s+(?<type>.+))?$') {
            $names = $Matches.names -split '\s*,\s*'
            $type = if ($Matches.type) { ($Matches.type -replace '\{\s*$', '').Trim() } else { '' }
            if ($type -eq '') { $type = '(inferred)' }
            return @{ Names = $names; Type = $type }
        }
        return $null
    }

    function ConvertTo-GoField {
        param([string]$t)
        $t = ($t -replace '\{\s*$', '').Trim()
        if ($t -eq '') { return @() }
        if ($t -match '^\*?[A-Za-z_][\w\.]*$') {
            $nm = ($t -replace '^\*', '')
            $nm = ($nm -split '\.')[-1]
            return @(@{ Name = $nm; Type = $t; Embedded = $true })
        }
        if ($t -match '^(?<names>[A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*)\s+(?<type>.+)$') {
            $names = $Matches.names -split '\s*,\s*'
            $type = $Matches.type.Trim()
            return @($names | ForEach-Object { @{ Name = $_; Type = $type; Embedded = $false } })
        }
        return @()
    }

    # 関数の括弧内（受信側/引数/結果）から name/type を抽出
    function Get-GoParams {
        param([string]$inside)
        $res = New-Object System.Collections.Generic.List[object]
        if (-not $inside -or $inside.Trim() -eq '') { return $res.ToArray() }
        $items = @(Split-TopLevel $inside ',')
        $buffer = New-Object System.Collections.Generic.List[string]
        foreach ($itRaw in $items) {
            $it = $itRaw.Trim()
            if ($it -eq '') { continue }
            if ($it -match '^(?<name>[A-Za-z_]\w*)\s+(?<type>.+)$') {
                $type = $Matches.type.Trim(); $nm = $Matches.name
                $res.Add(@{ Name = $nm; Type = $type })
                foreach ($bn in $buffer) { $res.Add(@{ Name = $bn; Type = $type }) }
                $buffer.Clear()
            }
            elseif ($it -match '^[A-Za-z_]\w*$') {
                $buffer.Add($it)   # 後続の型を共有する名前
            }
            else {
                $buffer.Clear()    # 無名の結果型など
            }
        }
        return $res.ToArray()
    }

    function Get-GoVariables {
        param($Text, $File, $Lang)
        $clean = Get-CleanCode -Text $Text -Preproc $false -GoRaw $true
        $results = New-Object System.Collections.Generic.List[object]
        $lines = $clean -split "`n"
        $frames = New-Object System.Collections.Generic.List[string]
        $group = $null
        $groupScope = 'Package'
        $lbuf = ''

        for ($idx = 0; $idx -lt $lines.Count; $idx++) {
            $ln = $idx + 1
            $raw = $lines[$idx]
            $t = $raw.Trim()
            $top = if ($frames.Count -gt 0) { $frames[$frames.Count - 1] } else { 'package' }
            $scope = switch ($top) {
                'struct' { 'Member' }
                'interface' { 'Member' }
                'func' { 'Local' }
                'block' { 'Local' }
                default { 'Package' }
            }

            if ($t -ne '') {
                if ($group) {
                    if ($t -match '^\)') { $group = $null }
                    else {
                        $spec = ConvertTo-GoVarSpec $t
                        if ($spec) {
                            foreach ($nm in $spec.Names) {
                                $exp = (($groupScope -eq 'Package') -and (Test-GoExported $nm))
                                $acc = if ($exp) { 'public' } else { 'private' }
                                $results.Add((New-VarRecord -File $File -Line $ln -Lang $Lang -Scope $groupScope `
                                            -Access $acc -Exported $exp -Type $spec.Type -Name $nm -Qualifiers $group -Decl $t))
                            }
                        }
                    }
                }
                elseif ($t -match '^(var|const)\s*\(\s*$') { $group = $Matches[1]; $groupScope = $scope }
                elseif ($t -match '^(var|const)\s+(.+)$') {
                    $kw = $Matches[1]; $spec = ConvertTo-GoVarSpec $Matches[2]
                    if ($spec) {
                        foreach ($nm in $spec.Names) {
                            $exp = (($scope -eq 'Package') -and (Test-GoExported $nm))
                            $acc = if ($exp) { 'public' } elseif ($scope -eq 'Local') { 'local' } else { 'private' }
                            $results.Add((New-VarRecord -File $File -Line $ln -Lang $Lang -Scope $scope `
                                        -Access $acc -Exported $exp -Type $spec.Type -Name $nm -Qualifiers $kw -Decl $t))
                        }
                    }
                }
                elseif ($scope -eq 'Local' -and $t -match '^(?<names>[A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*)\s*:=') {
                    foreach ($nm in ($Matches.names -split '\s*,\s*')) {
                        if ($nm -eq '_') { continue }
                        $results.Add((New-VarRecord -File $File -Line $ln -Lang $Lang -Scope 'Local' `
                                    -Access 'local' -Exported $false -Type '(inferred)' -Name $nm -Qualifiers ':=' -Decl $t))
                    }
                }
                elseif ($top -eq 'struct') {
                    foreach ($f in (ConvertTo-GoField $t)) {
                        $exp = Test-GoExported $f.Name
                        $acc = if ($exp) { 'public' } else { 'private' }
                        $q = if ($f.Embedded) { 'embedded' } else { 'field' }
                        $results.Add((New-VarRecord -File $File -Line $ln -Lang $Lang -Scope 'Member' `
                                    -Access $acc -Exported $exp -Type $f.Type -Name $f.Name -Qualifiers $q -Decl $t))
                    }
                }

                # 関数シグネチャの引数・受信側・名前付き戻り値
                if ($t -match '\bfunc\b') {
                    foreach ($grp in (Get-ParenGroups $t)) {
                        foreach ($p in (Get-GoParams $grp)) {
                            if ($p.Name -eq '_') { continue }
                            $results.Add((New-VarRecord -File $File -Line $ln -Lang $Lang -Scope 'Parameter' `
                                        -Access 'parameter' -Exported $false -Type $p.Type -Name $p.Name -Qualifiers 'param' -Decl $t))
                        }
                    }
                }
            }

            # この行の波括弧でフレームを更新（func シグネチャ行は lbuf に蓄積して継続）
            foreach ($ch in $raw.ToCharArray()) {
                if ($ch -eq [char]'{') {
                    if ($lbuf -match '\bstruct\b') { $frames.Add('struct') }
                    elseif ($lbuf -match '\binterface\b') { $frames.Add('interface') }
                    elseif ($lbuf -match '\bfunc\b') { $frames.Add('func') }
                    else { $frames.Add('block') }
                    $lbuf = ''
                }
                elseif ($ch -eq [char]'}') {
                    if ($frames.Count -gt 0) { $frames.RemoveAt($frames.Count - 1) }
                    $lbuf = ''
                }
                else { $lbuf += $ch }
            }
        }
        return $results
    }

    # ---- ディスパッチ ------------------------------------------------------
    try {
        $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLower()
        $text = [System.IO.File]::ReadAllText($FilePath)
    }
    catch { return @() }

    $cppExt = @('cpp', 'cc', 'cxx', 'c++', 'hpp', 'hh', 'hxx', 'h++', 'ipp', 'tpp', 'inl')
    if ($ext -eq 'go') {
        return (Get-GoVariables -Text $text -File $FilePath -Lang 'Go')
    }
    elseif ($cppExt -contains $ext) {
        return (Get-CLikeVariables -Text $text -File $FilePath -Lang 'C++')
    }
    elseif ($ext -eq 'c') {
        return (Get-CLikeVariables -Text $text -File $FilePath -Lang 'C')
    }
    elseif ($ext -eq 'h') {
        return (Get-CLikeVariables -Text $text -File $FilePath -Lang 'C/C++ header')
    }
    return @()
}

# ===========================================================================
#  並列オーケストレータ（ファイル列挙 + RunspacePool 解析）
# ===========================================================================
$script:OrchestratorScript = {
    param($Paths, $Recurse, $ExtList, $ParseText, $Throttle, $Sync)
    try {
        $files = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Paths) {
            if (-not $p) { continue }
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $files.Add((Resolve-Path -LiteralPath $p).Path)
            }
            elseif (Test-Path -LiteralPath $p -PathType Container) {
                $gci = Get-ChildItem -LiteralPath $p -File -Recurse:$Recurse -ErrorAction SilentlyContinue
                foreach ($f in $gci) {
                    $ext = $f.Extension.TrimStart('.').ToLower()
                    if ($ExtList -contains $ext) { $files.Add($f.FullName) }
                }
            }
        }
        $files = @($files | Select-Object -Unique)
        $Sync.Total = $files.Count
        if ($files.Count -eq 0) { $Sync.Results = @(); $Sync.Completed = $true; return }

        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $iss, $Host)
        $pool.Open()

        $jobs = New-Object System.Collections.Generic.List[object]
        foreach ($file in $files) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($ParseText).AddArgument($file)
            $h = $ps.BeginInvoke()
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $h; Done = $false })
        }

        $all = New-Object System.Collections.Generic.List[object]
        while ($true) {
            $remaining = $false
            foreach ($j in $jobs) {
                if (-not $j.Done) {
                    if ($j.Handle.IsCompleted) {
                        try {
                            $out = $j.PS.EndInvoke($j.Handle)
                            if ($out) { foreach ($o in $out) { $all.Add($o) } }
                        }
                        catch {}
                        $j.PS.Dispose(); $j.Done = $true
                        $Sync.Done = $Sync.Done + 1
                    }
                    else { $remaining = $true }
                }
            }
            if (-not $remaining) { break }
            Start-Sleep -Milliseconds 25
        }
        $pool.Close(); $pool.Dispose()
        $Sync.Results = $all.ToArray()
        $Sync.Completed = $true
    }
    catch {
        $Sync.Error = $_.ToString()
        $Sync.Results = @()
        $Sync.Completed = $true
    }
}

# ===========================================================================
#  共通ヘルパ
# ===========================================================================
function Get-Throttle {
    param([int]$Requested)
    if ($Requested -gt 0) { return $Requested }
    $c = [Environment]::ProcessorCount
    if ($c -lt 1) { $c = 1 }
    return $c
}

function Start-ScanBackground {
    param([string[]]$Paths, [bool]$Recurse, [string[]]$ExtList, [int]$Throttle)
    $sync = [hashtable]::Synchronized(@{ Total = 0; Done = 0; Results = $null; Completed = $false; Error = $null })
    $rs = [runspacefactory]::CreateRunspace()
    try { $rs.ApartmentState = 'MTA' } catch {}
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:OrchestratorScript.ToString()).
        AddArgument($Paths).AddArgument($Recurse).AddArgument($ExtList).
        AddArgument($script:ParseFileScript.ToString()).AddArgument($Throttle).AddArgument($sync)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PS = $ps; Handle = $handle; Sync = $sync; Runspace = $rs }
}

function Invoke-Scan {
    param([string[]]$Paths, [bool]$Recurse, [string[]]$ExtList, [int]$Throttle, [bool]$ShowProgress = $true)
    $job = Start-ScanBackground -Paths $Paths -Recurse $Recurse -ExtList $ExtList -Throttle $Throttle
    while (-not $job.Sync.Completed) {
        if ($ShowProgress) {
            $tot = [int]$job.Sync.Total; $dn = [int]$job.Sync.Done
            if ($tot -gt 0) {
                Write-Progress -Activity 'VarInspector' -Status "解析中: $dn / $tot ファイル" -PercentComplete ([int](100 * $dn / $tot))
            }
            else { Write-Progress -Activity 'VarInspector' -Status 'ファイル列挙中...' }
        }
        Start-Sleep -Milliseconds 80
    }
    if ($ShowProgress) { Write-Progress -Activity 'VarInspector' -Completed }
    try { $job.PS.EndInvoke($job.Handle) | Out-Null } catch {}
    $err = $job.Sync.Error
    $results = $job.Sync.Results
    $job.PS.Dispose(); $job.Runspace.Dispose()
    if ($err) { Write-Warning "解析中にエラー: $err" }
    if ($null -eq $results) { return @() }
    return @($results)
}

function Select-Results {
    param($Results, [string[]]$Scope, [bool]$ExportedOnly)
    $r = $Results
    if ($Scope) { $r = $r | Where-Object { $Scope -contains $_.Scope } }
    if ($ExportedOnly) { $r = $r | Where-Object { $_.Exported } }
    return @($r)
}

# 表示・出力用の日本語項目名マップ（内部プロパティ名は英語のまま）
$script:ColumnLabels = [ordered]@{
    Name        = '変数名'
    Type        = '型'
    Scope       = 'スコープ'
    Access      = '公開区分'
    Exported    = '外部公開'
    Language    = '言語'
    Qualifiers  = '修飾子'
    Line        = '行'
    File        = 'ファイル'
    Declaration = '宣言'
}

# レコードを日本語キーのオブジェクトへ変換（CSV/JSON 出力・保存用）
function ConvertTo-LocalizedRecord {
    param($Records)
    foreach ($r in $Records) {
        [pscustomobject][ordered]@{
            '変数名'   = $r.Name
            '型'       = $r.Type
            'スコープ' = $r.Scope
            '公開区分' = $r.Access
            '外部公開' = $r.Exported
            '言語'     = $r.Language
            '修飾子'   = $r.Qualifiers
            '行'       = $r.Line
            'ファイル' = $r.File
            '宣言'     = $r.Declaration
        }
    }
}

# ===========================================================================
#  GUI
# ===========================================================================
function Test-StaOrRelaunch {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { return $true }
    $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) {
        Write-Warning 'GUI には STA スレッドが必要です。Windows PowerShell (powershell.exe) で実行してください。'
        return $false
    }
    if (-not $PSCommandPath) {
        Write-Warning 'GUI には STA が必要です。powershell.exe -STA -File .\VarInspector.ps1 -Gui で実行してください。'
        return $false
    }
    Write-Host 'STA スレッドへ切り替えて GUI を再起動します...' -ForegroundColor Yellow
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Gui')
    return $false
}

function ConvertTo-DataTable {
    param($Records)
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('Name', [string])
    [void]$dt.Columns.Add('Type', [string])
    [void]$dt.Columns.Add('Scope', [string])
    [void]$dt.Columns.Add('Access', [string])
    [void]$dt.Columns.Add('Exported', [bool])
    [void]$dt.Columns.Add('Language', [string])
    [void]$dt.Columns.Add('Qualifiers', [string])
    [void]$dt.Columns.Add('Line', [int])
    [void]$dt.Columns.Add('File', [string])
    [void]$dt.Columns.Add('Declaration', [string])
    foreach ($r in $Records) {
        $row = $dt.NewRow()
        $row['Name'] = [string]$r.Name
        $row['Type'] = [string]$r.Type
        $row['Scope'] = [string]$r.Scope
        $row['Access'] = [string]$r.Access
        $row['Exported'] = [bool]$r.Exported
        $row['Language'] = [string]$r.Language
        $row['Qualifiers'] = [string]$r.Qualifiers
        $row['Line'] = [int]$r.Line
        $row['File'] = [string]$r.File
        $row['Declaration'] = [string]$r.Declaration
        $dt.Rows.Add($row)
    }
    return , $dt
}

function Show-Gui {
    param([string[]]$InitialPaths)
    if (-not (Test-StaOrRelaunch)) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:allResults = @()

    # ---- カラーパレット / フォント ----
    $C = @{
        Bg         = [System.Drawing.ColorTranslator]::FromHtml('#EEF1F8')
        Card       = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
        Header     = [System.Drawing.ColorTranslator]::FromHtml('#1F2440')
        Accent     = [System.Drawing.ColorTranslator]::FromHtml('#4361EE')
        AccentHov  = [System.Drawing.ColorTranslator]::FromHtml('#2F4BD8')
        Text       = [System.Drawing.ColorTranslator]::FromHtml('#2B2F42')
        Muted      = [System.Drawing.ColorTranslator]::FromHtml('#8A90A6')
        HeaderSub  = [System.Drawing.ColorTranslator]::FromHtml('#AEB4D6')
        GridHead   = [System.Drawing.ColorTranslator]::FromHtml('#2B2F42')
        Alt        = [System.Drawing.ColorTranslator]::FromHtml('#F5F7FC')
        Sel        = [System.Drawing.ColorTranslator]::FromHtml('#DCE4FF')
        Border     = [System.Drawing.ColorTranslator]::FromHtml('#D7DCEA')
    }
    $fontBase = New-Object System.Drawing.Font('Yu Gothic UI', 9.75)
    $fontTitle = New-Object System.Drawing.Font('Yu Gothic UI', 16, [System.Drawing.FontStyle]::Bold)
    $fontSub = New-Object System.Drawing.Font('Yu Gothic UI', 8.25)
    $fontBtn = New-Object System.Drawing.Font('Yu Gothic UI', 9.75)
    $fontHead = New-Object System.Drawing.Font('Yu Gothic UI', 9.75, [System.Drawing.FontStyle]::Bold)

    # ---- スタイル適用ヘルパ ----
    $styleAccent = {
        param($b)
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $C.Accent; $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.MouseOverBackColor = $C.AccentHov
        $b.Font = $fontBtn; $b.Cursor = 'Hand'
    }
    $styleGhost = {
        param($b)
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $C.Border
        $b.BackColor = $C.Card; $b.ForeColor = $C.Text
        $b.FlatAppearance.MouseOverBackColor = $C.Bg
        $b.Font = $fontBtn; $b.Cursor = 'Hand'
    }
    $styleInput = {
        param($t)
        $t.BorderStyle = 'FixedSingle'; $t.BackColor = $C.Card; $t.ForeColor = $C.Text; $t.Font = $fontBase
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'VarInspector — 変数抽出ツール (Go / C / C++)'
    $form.Size = New-Object System.Drawing.Size(1080, 700)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(820, 520)
    $form.BackColor = $C.Bg
    $form.Font = $fontBase

    # ================= グリッド（最初に追加して Fill 残余を確保） =================
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BorderStyle = 'None'
    $grid.EnableHeadersVisualStyles = $false
    $grid.BackgroundColor = $C.Card
    $grid.GridColor = $C.Border
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersHeight = 38
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $C.GridHead
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.Font = $fontHead
    $grid.ColumnHeadersDefaultCellStyle.Alignment = 'MiddleLeft'
    $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $grid.DefaultCellStyle.Font = $fontBase
    $grid.DefaultCellStyle.ForeColor = $C.Text
    $grid.DefaultCellStyle.SelectionBackColor = $C.Sel
    $grid.DefaultCellStyle.SelectionForeColor = $C.Text
    $grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $C.Alt
    $grid.RowTemplate.Height = 30
    $form.Controls.Add($grid)

    # ================= フッター =================
    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = 52; $footer.BackColor = $C.Card
    $footer.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    $form.Controls.Add($footer)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = '  対象を指定して「抽出」を押してください'
    $lblStatus.Location = New-Object System.Drawing.Point(16, 18); $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = $C.Muted
    $footer.Controls.Add($lblStatus)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(540, 16); $progress.Size = New-Object System.Drawing.Size(240, 18)
    $progress.Anchor = 'Bottom,Right'
    $progress.ForeColor = $C.Accent
    $footer.Controls.Add($progress)

    $btnCsv = New-Object System.Windows.Forms.Button
    $btnCsv.Text = 'CSV 保存'; $btnCsv.Location = New-Object System.Drawing.Point(796, 12); $btnCsv.Size = New-Object System.Drawing.Size(98, 28)
    $btnCsv.Anchor = 'Bottom,Right'; & $styleGhost $btnCsv
    $footer.Controls.Add($btnCsv)

    $btnJson = New-Object System.Windows.Forms.Button
    $btnJson.Text = 'JSON 保存'; $btnJson.Location = New-Object System.Drawing.Point(900, 12); $btnJson.Size = New-Object System.Drawing.Size(98, 28)
    $btnJson.Anchor = 'Bottom,Right'; & $styleGhost $btnJson
    $footer.Controls.Add($btnJson)

    # ================= ツールバー（白カード） =================
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Top'; $toolbar.Height = 116; $toolbar.BackColor = $C.Card
    $form.Controls.Add($toolbar)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = '対象'; $lblPath.Location = New-Object System.Drawing.Point(20, 22); $lblPath.AutoSize = $true; $lblPath.ForeColor = $C.Muted
    $toolbar.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(64, 18); $txtPath.Size = New-Object System.Drawing.Size(610, 26)
    $txtPath.Anchor = 'Top,Left,Right'; & $styleInput $txtPath
    $toolbar.Controls.Add($txtPath)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'フォルダ'; $btnFolder.Location = New-Object System.Drawing.Point(684, 17); $btnFolder.Size = New-Object System.Drawing.Size(78, 28)
    $btnFolder.Anchor = 'Top,Right'; & $styleGhost $btnFolder
    $toolbar.Controls.Add($btnFolder)

    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = 'ファイル'; $btnFile.Location = New-Object System.Drawing.Point(768, 17); $btnFile.Size = New-Object System.Drawing.Size(78, 28)
    $btnFile.Anchor = 'Top,Right'; & $styleGhost $btnFile
    $toolbar.Controls.Add($btnFile)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = '抽出  ▶'; $btnScan.Location = New-Object System.Drawing.Point(852, 17); $btnScan.Size = New-Object System.Drawing.Size(190, 28)
    $btnScan.Anchor = 'Top,Right'; & $styleAccent $btnScan
    $toolbar.Controls.Add($btnScan)

    $chkRecurse = New-Object System.Windows.Forms.CheckBox
    $chkRecurse.Text = 'サブフォルダも対象'; $chkRecurse.Checked = $true
    $chkRecurse.Location = New-Object System.Drawing.Point(64, 64); $chkRecurse.AutoSize = $true; $chkRecurse.ForeColor = $C.Text
    $toolbar.Controls.Add($chkRecurse)

    $chkExported = New-Object System.Windows.Forms.CheckBox
    $chkExported.Text = '外部公開のみ'; $chkExported.Location = New-Object System.Drawing.Point(214, 64); $chkExported.AutoSize = $true; $chkExported.ForeColor = $C.Text
    $toolbar.Controls.Add($chkExported)

    $lblExt = New-Object System.Windows.Forms.Label
    $lblExt.Text = '拡張子'; $lblExt.Location = New-Object System.Drawing.Point(330, 66); $lblExt.AutoSize = $true; $lblExt.ForeColor = $C.Muted
    $toolbar.Controls.Add($lblExt)

    $txtExt = New-Object System.Windows.Forms.TextBox
    $txtExt.Location = New-Object System.Drawing.Point(382, 62); $txtExt.Size = New-Object System.Drawing.Size(150, 26)
    $txtExt.Text = ($script:DefaultExtensions -join ','); & $styleInput $txtExt
    $toolbar.Controls.Add($txtExt)

    $lblScope = New-Object System.Windows.Forms.Label
    $lblScope.Text = '範囲'; $lblScope.Location = New-Object System.Drawing.Point(548, 66); $lblScope.AutoSize = $true; $lblScope.ForeColor = $C.Muted
    $toolbar.Controls.Add($lblScope)

    $cmbScope = New-Object System.Windows.Forms.ComboBox
    $cmbScope.DropDownStyle = 'DropDownList'; $cmbScope.FlatStyle = 'Flat'; $cmbScope.BackColor = $C.Card
    $cmbScope.Location = New-Object System.Drawing.Point(588, 62); $cmbScope.Size = New-Object System.Drawing.Size(128, 26)
    [void]$cmbScope.Items.AddRange(@('全スコープ', 'Global', 'Package', 'Member', 'Local', 'Parameter'))
    $cmbScope.SelectedIndex = 0
    $toolbar.Controls.Add($cmbScope)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = '絞り込み'; $lblFilter.Location = New-Object System.Drawing.Point(732, 66); $lblFilter.AutoSize = $true; $lblFilter.ForeColor = $C.Muted
    $lblFilter.Anchor = 'Top,Right'
    $toolbar.Controls.Add($lblFilter)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(792, 62); $txtFilter.Size = New-Object System.Drawing.Size(250, 26)
    $txtFilter.Anchor = 'Top,Right'; & $styleInput $txtFilter
    $toolbar.Controls.Add($txtFilter)

    # ================= ヘッダーバンド =================
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 64; $header.BackColor = $C.Header
    $form.Controls.Add($header)

    $accentStrip = New-Object System.Windows.Forms.Panel
    $accentStrip.Dock = 'Left'; $accentStrip.Width = 6; $accentStrip.BackColor = $C.Accent
    $header.Controls.Add($accentStrip)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'VarInspector'; $lblTitle.Font = $fontTitle; $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Location = New-Object System.Drawing.Point(22, 9); $lblTitle.AutoSize = $true
    $header.Controls.Add($lblTitle)

    $lblTag = New-Object System.Windows.Forms.Label
    $lblTag.Text = 'ソースコード変数抽出  ·  C / C++'
    $lblTag.Font = $fontSub; $lblTag.ForeColor = $C.HeaderSub
    $lblTag.Location = New-Object System.Drawing.Point(24, 40); $lblTag.AutoSize = $true
    $header.Controls.Add($lblTag)

    # --- グリッド列を日本語ヘッダー・幅・整列で整える ---
    $styleColumns = {
        foreach ($col in $grid.Columns) {
            if ($script:ColumnLabels.Contains($col.Name)) { $col.HeaderText = $script:ColumnLabels[$col.Name] }
        }
        $w = @{ Name = 130; Type = 150; Scope = 90; Access = 80; Exported = 70; Language = 90; Qualifiers = 80; Line = 50; File = 170; Declaration = 220 }
        foreach ($k in $w.Keys) { if ($grid.Columns[$k]) { $grid.Columns[$k].FillWeight = $w[$k] } }
        if ($grid.Columns['Line']) { $grid.Columns['Line'].DefaultCellStyle.Alignment = 'MiddleRight' }
        if ($grid.Columns['Exported']) { $grid.Columns['Exported'].DefaultCellStyle.Alignment = 'MiddleCenter' }
    }

    # --- フィルタ適用 ---
    $applyFilter = {
        $recs = $script:allResults
        if ($chkExported.Checked) { $recs = $recs | Where-Object { $_.Exported } }
        if ($cmbScope.SelectedIndex -gt 0) {
            $sc = $cmbScope.SelectedItem
            $recs = $recs | Where-Object { $_.Scope -eq $sc }
        }
        $f = $txtFilter.Text.Trim()
        if ($f) { $recs = $recs | Where-Object { $_.Name -like "*$f*" -or $_.Type -like "*$f*" } }
        $recs = @($recs)
        $grid.DataSource = (ConvertTo-DataTable $recs)
        & $styleColumns
        $total = @($script:allResults).Count
        $expc = @($script:allResults | Where-Object { $_.Exported }).Count
        $lblStatus.Text = "  合計 $total 件   ·   外部公開 $expc 件   ·   表示 $($recs.Count) 件"
    }

    # --- スキャン用タイマー ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 120
    $script:job = $null

    $timer.Add_Tick({
            $s = $script:job.Sync
            $tot = [int]$s.Total; $dn = [int]$s.Done
            if ($tot -gt 0) {
                $progress.Style = 'Continuous'
                $progress.Maximum = $tot
                if ($dn -le $tot) { $progress.Value = $dn }
                $lblStatus.Text = "解析中: $dn / $tot ファイル"
            }
            else {
                $progress.Style = 'Marquee'
                $lblStatus.Text = 'ファイル列挙中...'
            }
            if ($s.Completed) {
                $timer.Stop()
                try { $script:job.PS.EndInvoke($script:job.Handle) | Out-Null } catch {}
                $err = $s.Error
                $script:allResults = @($s.Results)
                $script:job.PS.Dispose(); $script:job.Runspace.Dispose()
                $progress.Style = 'Continuous'; $progress.Value = $progress.Maximum
                $btnScan.Enabled = $true
                if ($err) { [System.Windows.Forms.MessageBox]::Show("エラー: $err", 'VarInspector', 'OK', 'Error') | Out-Null }
                & $applyFilter
            }
        })

    # --- イベント ---
    $btnFolder.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($dlg.ShowDialog() -eq 'OK') { $txtPath.Text = $dlg.SelectedPath }
        })
    $btnFile.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Multiselect = $true
            $dlg.Filter = 'ソース (*.go;*.c;*.h;*.cpp;*.hpp)|*.go;*.c;*.h;*.cpp;*.cc;*.cxx;*.hpp;*.hh;*.hxx|すべて (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') { $txtPath.Text = ($dlg.FileNames -join ';') }
        })
    $btnScan.Add_Click({
            $paths = @($txtPath.Text -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
            if ($paths.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('対象を指定してください。', 'VarInspector') | Out-Null; return }
            $exts = @($txtExt.Text -split ',' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim().TrimStart('.').ToLower() })
            if ($exts.Count -eq 0) { $exts = $script:DefaultExtensions }
            $btnScan.Enabled = $false
            $progress.Style = 'Marquee'
            $lblStatus.Text = '開始しています...'
            $script:job = Start-ScanBackground -Paths $paths -Recurse $chkRecurse.Checked -ExtList $exts -Throttle (Get-Throttle 0)
            $timer.Start()
        })
    $txtFilter.Add_TextChanged({ if ($script:allResults.Count) { & $applyFilter } })
    $chkExported.Add_CheckedChanged({ if ($script:allResults.Count) { & $applyFilter } })
    $cmbScope.Add_SelectedIndexChanged({ if ($script:allResults.Count) { & $applyFilter } })

    $saveTo = {
        param($filter, $isJson)
        if (@($script:allResults).Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('保存するデータがありません。', 'VarInspector') | Out-Null; return }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = $filter
        if ($dlg.ShowDialog() -eq 'OK') {
            # 現在の表示（フィルタ適用後）を日本語項目名で保存
            $dt = $grid.DataSource
            $rows = @()
            foreach ($rv in $dt.Rows) {
                $rows += [pscustomobject][ordered]@{
                    '変数名'   = $rv['Name']
                    '型'       = $rv['Type']
                    'スコープ' = $rv['Scope']
                    '公開区分' = $rv['Access']
                    '外部公開' = $rv['Exported']
                    '言語'     = $rv['Language']
                    '修飾子'   = $rv['Qualifiers']
                    '行'       = $rv['Line']
                    'ファイル' = $rv['File']
                    '宣言'     = $rv['Declaration']
                }
            }
            if ($isJson) { $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8 }
            else { $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8 }
            $lblStatus.Text = "  保存しました: $($dlg.FileName)"
        }
    }
    $btnCsv.Add_Click({ & $saveTo 'CSV (*.csv)|*.csv' $false })
    $btnJson.Add_Click({ & $saveTo 'JSON (*.json)|*.json' $true })

    # 起動時に対象が渡されていれば自動で抽出
    if ($InitialPaths -and @($InitialPaths).Count -gt 0) {
        $txtPath.Text = (@($InitialPaths) -join ';')
        $form.Add_Shown({ $btnScan.PerformClick() })
    }

    [void]$form.ShowDialog()
}

# ===========================================================================
#  CUI 出力
# ===========================================================================
function Write-CuiOutput {
    param($Results, [string]$Format, [string]$OutFile)
    $Results = @($Results)
    switch ($Format) {
        'Object' { return $Results }
        'Json' {
            $json = (ConvertTo-LocalizedRecord $Results) | ConvertTo-Json -Depth 4
            if ($OutFile) { $json | Set-Content -LiteralPath $OutFile -Encoding UTF8; Write-Host "保存: $OutFile ($($Results.Count) 件)" -ForegroundColor Green }
            else { $json }
        }
        'Csv' {
            $loc = ConvertTo-LocalizedRecord $Results
            if ($OutFile) { $loc | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8; Write-Host "保存: $OutFile ($($Results.Count) 件)" -ForegroundColor Green }
            else { $loc | ConvertTo-Csv -NoTypeInformation }
        }
        default {
            # Console
            $total = $Results.Count
            $exp = @($Results | Where-Object { $_.Exported }).Count
            $byLang = $Results | Group-Object Language | Sort-Object Name
            $accent = 'Cyan'
            Write-Host ''
            Write-Host ('  ┌' + ('─' * 46) + '┐') -ForegroundColor $accent
            Write-Host '  │  VarInspector  —  変数抽出レポート           │' -ForegroundColor $accent
            Write-Host ('  └' + ('─' * 46) + '┘') -ForegroundColor $accent
            Write-Host ('   合計 ' ) -ForegroundColor Gray -NoNewline
            Write-Host ("{0} 件" -f $total) -ForegroundColor White -NoNewline
            Write-Host '   /   外部公開 ' -ForegroundColor Gray -NoNewline
            Write-Host ("{0} 件" -f $exp) -ForegroundColor Green
            Write-Host '   言語 : ' -ForegroundColor Gray -NoNewline
            Write-Host (($byLang | ForEach-Object { "$($_.Name) $($_.Count)" }) -join '   ') -ForegroundColor White
            $byScope = $Results | Group-Object Scope | Sort-Object Name
            Write-Host '   範囲 : ' -ForegroundColor Gray -NoNewline
            Write-Host (($byScope | ForEach-Object { "$($_.Name) $($_.Count)" }) -join '   ') -ForegroundColor White
            Write-Host ''
            if ($total -gt 0) {
                $Results |
                    Sort-Object File, Line |
                    Format-Table -AutoSize -Property `
                    @{ N = '変数名'; E = { $_.Name } },
                    @{ N = '型'; E = { $_.Type } },
                    @{ N = 'スコープ'; E = { $_.Scope } },
                    @{ N = '公開区分'; E = { $_.Access } },
                    @{ N = '外部公開'; E = { if ($_.Exported) { '○' } else { '・' } } },
                    @{ N = '言語'; E = { $_.Language } },
                    @{ N = '行'; E = { $_.Line }; Align = 'Right' },
                    @{ N = 'ファイル'; E = { Split-Path $_.File -Leaf } }
            }
            if ($OutFile) {
                (ConvertTo-LocalizedRecord $Results) | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
                Write-Host "CSV 保存: $OutFile" -ForegroundColor Green
            }
        }
    }
}

# ===========================================================================
#  エントリポイント
# ===========================================================================
if ($Gui) {
    Show-Gui -InitialPaths $Path
    return
}

if (-not $Path -or $Path.Count -eq 0) {
    Write-Host @"
VarInspector - ソースコード変数抽出ツール (Go / C / C++)

使い方:
  CUI: .\VarInspector.ps1 -Path <ファイル|フォルダ> [-Recurse] [-Format Console|Csv|Json|Object] [-OutFile out.csv]
  GUI: .\VarInspector.ps1 -Gui

オプション:
  -Recurse        フォルダを再帰的に走査
  -ExportedOnly   外部公開された変数のみ
  -Scope          Global,Package,Member,Local,Parameter で絞り込み
  -Include        対象拡張子 (例: -Include go,c,cpp)
  -ThrottleLimit  並列度 (0=CPUコア数)

例:
  .\VarInspector.ps1 -Path .\src -Recurse
  .\VarInspector.ps1 -Path .\main.go -Format Json -OutFile vars.json
  .\VarInspector.ps1 -Path .\lib -Recurse -ExportedOnly -Scope Global,Member
"@ -ForegroundColor Gray
    return
}

$exts = if ($Include) { @($Include | ForEach-Object { $_.TrimStart('.').ToLower() }) } else { $script:DefaultExtensions }
$throttle = Get-Throttle $ThrottleLimit

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = Invoke-Scan -Paths $Path -Recurse $Recurse.IsPresent -ExtList $exts -Throttle $throttle -ShowProgress ($Format -eq 'Console')
$results = Select-Results -Results $results -Scope $Scope -ExportedOnly $ExportedOnly.IsPresent
$sw.Stop()

if ($Format -eq 'Console') {
    Write-Host ("(解析時間: {0:N2} 秒, 並列度: {1})" -f $sw.Elapsed.TotalSeconds, $throttle) -ForegroundColor DarkGray
}
Write-CuiOutput -Results $results -Format $Format -OutFile $OutFile
