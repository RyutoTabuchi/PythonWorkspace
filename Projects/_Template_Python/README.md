# {{PROJECT_DISPLAY_NAME}}

> 【テンプレート運用中の注意】ワークスペース共通の `Install-Packages.ps1` が未作成の間は、このテンプレートを正式な新規プロジェクト作成に使用しないでください。（導入ツールの完成後に、この注意書きを削除します。）

## 概要

このプロジェクトの概要を記載します。

## プロジェクト情報

- Python識別名：`{{PYTHON_IDENTIFIER}}`
- 最低Pythonバージョン：{{MIN_PYTHON_VERSION}}
- 対象OS：Windows
- ソースコード：`source/`
- 仮想環境：`.venv`

## フォルダー構成

| フォルダー・ファイル | 内容 |
| --- | --- |
| `source/` | Pythonソースコード。標準の実行ファイルは `source/main.py` です |
| `tests/` | テスト用。テスト基盤は標準では含まれません |
| `config/` | 設定ファイル用。初期状態では設定ファイルはありません |
| `input/` | 入力ファイル用。中身はGit管理されません |
| `output/` | 出力ファイル用。中身はGit管理されません |
| `logs/` | ログ用。中身はGit管理されません |
| `requirements.txt` | 実行用パッケージの一覧 |
| `requirements-dev.txt` | 開発用パッケージの一覧 |

`config/` には、パスワード、APIキー、アクセストークンなどの秘密情報を保存しないでください。`config/` はGit管理されます。

## 実行方法

ワークスペース直下から対象プロジェクトへ移動し、プロジェクト内の `.venv` のPythonを直接実行します。

```powershell
cd ".\Projects\Project {{PROJECT_DISPLAY_NAME}}"
.\.venv\Scripts\python.exe .\source\main.py
```

仮想環境の有効化（`Activate.ps1`）は標準手順に含めません。PowerShellの実行ポリシーに依存せず、対象プロジェクトの `.venv` を明示的に使用するためです。

個人固有のPython実行ファイルの絶対パスは、このREADMEに記録しません。

## 依存関係

| ファイル | 役割 |
| --- | --- |
| `requirements.txt` | プログラムの実行に必要なパッケージ（実行用） |
| `requirements-dev.txt` | テスト、静的解析、型チェック、ドキュメント作成、EXE化など、開発時だけ必要なパッケージ（開発用） |

プロジェクト作成時には、どちらも空です。パッケージは自動導入されません。

記載できる形式は、次の2つだけです。

```text
package
package==1.2.3
```

空行と、`#` で始まるコメント行は使用できます。`>=`、`<`、`~=`、`[extra]`、`-e .`、`git+https://...`、ローカルパス、URL指定は使用できません。

## パッケージ導入方法

パッケージは、ワークスペース共通の導入ツール `Install-Packages.ps1` を使用して導入します。`requirements.txt` や `requirements-dev.txt` を直接 `pip install -r` で導入しないでください。

導入ツールは、共通の許可パッケージ一覧との照合後にパッケージを導入します。許可されていないパッケージが1つでも含まれる場合は、導入を行わず処理全体を停止します。

次のコマンドは、**PythonWorkspace直下**で実行します。

実行用パッケージ（`requirements.txt`）：

```powershell
.\.tools\Install-Packages.ps1 `
    -ProjectPath ".\Projects\Project {{PROJECT_DISPLAY_NAME}}" `
    -Target Runtime
```

開発用パッケージ（`requirements-dev.txt`）：

```powershell
.\.tools\Install-Packages.ps1 `
    -ProjectPath ".\Projects\Project {{PROJECT_DISPLAY_NAME}}" `
    -Target Development
```

すべてのパッケージ（両方のファイル）：

```powershell
.\.tools\Install-Packages.ps1 `
    -ProjectPath ".\Projects\Project {{PROJECT_DISPLAY_NAME}}" `
    -Target All
```
