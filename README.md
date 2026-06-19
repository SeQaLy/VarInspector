# VarInspector

ソースコード（**Go / C / C++**）から変数を抽出し、**変数名・型・スコープ・外部公開の有無**を
一覧化するツールです。

- ✅ **PowerShell 標準機能のみ** で動作（追加インストール不要 / Windows PowerShell 5.1・PowerShell 7 両対応）
- ✅ **CUI / GUI** 両対応
- ✅ 対象は **ファイル単体** または **フォルダ（再帰可）**
- ✅ **外部公開（exported / external linkage / public）かどうか** を判定
- ✅ **型・変数名** を抽出（ローカル変数・引数・メンバ・グローバルまで）
- ✅ **並列処理（RunspacePool）** で高速化

---

## 使い方

### CUI

```powershell
# フォルダを再帰的に解析してコンソール表示
.\VarInspector.ps1 -Path .\src -Recurse

# ファイル単体を JSON 出力
.\VarInspector.ps1 -Path .\main.go -Format Json -OutFile vars.json

# 外部公開された変数だけを、グローバル/メンバに絞って CSV 保存
.\VarInspector.ps1 -Path .\lib -Recurse -ExportedOnly -Scope Global,Member -OutFile out.csv -Format Csv

# パイプラインで後続処理（Object 形式は PSObject を返す）
.\VarInspector.ps1 -Path .\src -Recurse -Format Object | Where-Object Exported | Sort-Object Name
```

### GUI

```powershell
.\VarInspector.ps1 -Gui

# 対象を指定して起動すると、開いた直後に自動で抽出します
.\VarInspector.ps1 -Gui -Path .\src
```

- 「フォルダ」「ファイル」で対象を選択 →「抽出 ▶」
- 「サブフォルダも対象」「外部公開のみ」チェック、範囲（スコープ）選択、名前/型の絞り込みで表示を即時フィルタ
- 「CSV 保存」「JSON 保存」で現在の表示内容を**日本語項目名**で保存
- モダンなフラットデザイン（ダークヘッダー＋アクセントカラー、日本語の列見出し）
- ※ GUI は STA スレッドが必要です。PowerShell 7 (pwsh) が MTA の場合は自動で
  `powershell.exe -STA` に切り替えて再起動します。

---

## プロファイル登録（`VarInspector` コマンド化）

[VarInspector.profile.ps1](VarInspector.profile.ps1) をプロファイルで読み込むと、どこからでも
`VarInspector` コマンドが使えます。

```powershell
# $PROFILE に次の1行を追記（このリポジトリのパスに合わせる）
. "Z:\develop\VarInspector\VarInspector.profile.ps1"
```

追記は手動でも、読み込み後に補助コマンドでも行えます:

```powershell
. "Z:\develop\VarInspector\VarInspector.profile.ps1"   # 一度読み込む
Install-VarInspectorProfile                             # $PROFILE に自動登録（重複しない）
```

登録後の使い方:

```powershell
VarInspector                         # 引数なし → GUI を「別プロセス」で起動（コンソールは止まらない）
VarInspector -Gui .\src              # 対象を指定して GUI 起動（開いた直後に自動抽出）
VarInspector -Path .\src -Recurse    # CUI でその場実行（結果表示）
VarInspector .\src -Format Object | Where-Object Exported   # パイプライン連携
vins .\src                           # 短縮エイリアス
```

- 引数なし／`-Gui` のときは GUI を **別プロセス**で起動するため、コンソールをブロックしません。
- `-Path` 指定（`-Gui` なし）は **その場で実行**し、結果をそのまま出力します（`-Format Object` でオブジェクトを返却）。
- ※ `VarInspector.ps1` と `VarInspector.profile.ps1` は同じフォルダに置いてください。

---

## パラメータ

| パラメータ | 説明 |
|---|---|
| `-Path <string[]>` | 解析対象（ファイル/フォルダ、複数可） |
| `-Recurse` | フォルダを再帰的に走査 |
| `-Gui` | GUI を起動 |
| `-Format <Console\|Csv\|Json\|Object>` | 出力形式（既定: Console） |
| `-OutFile <path>` | 出力先ファイル |
| `-Include <string[]>` | 対象拡張子を上書き（例: `-Include go,c,cpp`） |
| `-Scope <...>` | `Global,Package,Member,Local,Parameter` で絞り込み |
| `-ExportedOnly` | 外部公開された変数のみ |
| `-ThrottleLimit <int>` | 並列度（0 = CPU コア数） |

> 補足: `pwsh -File .\VarInspector.ps1 -Scope Global,Member` のように **`-File` 経由でカンマ区切り配列**を渡すと
> 1 つの文字列として扱われます。配列指定は PowerShell セッション内で
> `.\VarInspector.ps1 -Scope Global,Member` のように実行してください。

---

## 出力カラム

Console / CSV / JSON / GUI では**日本語の項目名**で表示・保存します。
（`-Format Object` のみ、スクリプト連携用に英語プロパティ名のまま返します）

| 表示名（日本語） | プロパティ名 | 内容 |
|---|---|---|
| `変数名` | `Name` | 変数名 |
| `型` | `Type` | 型（Go の型推論は `(inferred)`） |
| `スコープ` | `Scope` | `Global`(C/C++) / `Package`(Go) / `Member` / `Local` / `Parameter` |
| `公開区分` | `Access` | `public` / `private` / `protected` / `local` / `parameter` |
| `外部公開` | `Exported` | **外部公開なら `True`（GUI ではチェック表示）** |
| `言語` | `Language` | `Go` / `C` / `C++` / `C/C++ header` |
| `修飾子` | `Qualifiers` | `static`,`extern`,`const`,`var`,`:=`,`field`,`embedded`,`param` 等 |
| `行` / `ファイル` | `Line` / `File` | 出現位置 |
| `宣言` | `Declaration` | 宣言のスニペット |

### 「外部公開」の判定基準

| 言語 | 外部公開（Exported=True）の条件 |
|---|---|
| **Go** | パッケージレベルの変数/定数・構造体フィールドで **先頭が大文字** |
| **C** | ファイルスコープのグローバル変数で **`static` が付いていない**（外部リンケージ）。`extern` も公開扱い |
| **C++** | グローバル/名前空間スコープで非 `static`、またはクラス/構造体メンバで **`public`** |

---

## 対象拡張子（既定）

`go` / `c` `h` / `cpp` `cc` `cxx` `c++` `hpp` `hh` `hxx` `h++` `ipp` `tpp` `inl`

---

## 仕組み

1. ファイルを列挙（`-Recurse` で再帰）
2. **RunspacePool** で 1 ファイル＝1 ランスペースとして並列解析
3. 各言語ごとのパーサ:
   - コメント / 文字列 / 文字リテラル / プリプロセッサ行を除去（行番号は保持）
   - **C/C++**: 波括弧の入れ子でスコープ（namespace / class / struct / 関数 / ブロック）を追跡し、
     `public:` 等のアクセス指定子、`static`/`extern` を解釈
   - **Go**: 行単位で `var`/`const`（グループ含む）、`:=`、構造体フィールド、関数引数・レシーバ・名前付き戻り値を解釈

---

## 既知の制限（正規表現ベースのヒューリスティック解析）

完全なコンパイラ・パーサではないため、以下は取りこぼし/誤判定の可能性があります:

- C/C++ の `for (int i=0; ...)` の **初期化部の変数**、ラムダの引数は抽出しません
- C++ の most-vexing-parse（`Type x(args);`）は関数宣言とみなしてスキップします
- マクロは展開しないため、型にマクロ名が残ることがあります（例: `char[BUFFER_SIZE]`）
- C++ の名前空間内 `const` は厳密には内部リンケージですが、本ツールは公開扱いにします
- 複数行にまたがる関数シグネチャの引数は、先頭行のみ解釈する場合があります

精度向上が必要な場合は対象言語の AST パーサ併用を検討してください。
