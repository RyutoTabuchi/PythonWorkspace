# 共通ツール

PythonWorkspaceの共通ツールをまとめたフォルダーです。

| フォルダー | 内容 |
| --- | --- |
| [NewProject/](NewProject) | Pythonプロジェクトの作成ツールと、そのテスト |
| [ApprovedPackages/](ApprovedPackages) | 許可パッケージの管理・資料生成・導入ツールと、そのテスト |

許可パッケージの正式データは、ワークスペース直下の `ApprovedPackages/` にあります。このフォルダーのツールで管理・導入しますが、データそのものは含みません。

## 利用に必要な環境

Windows PowerShell 5.1以降、VS Code、Git for Windows、インストール済みのPythonを使用します。専用拡張やインストーラーは不要です。

VS Codeタスクは `powershell.exe -NoProfile -File` でスクリプトを実行し、`-ExecutionPolicy Bypass` は使用しません。ツールも実行ポリシーを変更しません。実行ポリシーのためにスクリプトを実行できない場合は、自分で変更せず、ワークスペース管理者へ相談してください。

## VS Codeタスク

共通タスクは `.vscode/tasks.json` に定義しています。「ターミナル」→「タスクの実行」から選びます。いずれも専用パネルで開き、対話入力ができます。

| タスク | 実行するスクリプト | 用途 |
| --- | --- | --- |
| `Workspace: 新規プロジェクトを作成` | `NewProject\New-Project.ps1` | プロジェクトを作成する |
| `Workspace: 許可パッケージを管理` | `ApprovedPackages\Manage-ApprovedPackage.ps1` | 許可パッケージの登録・変更をする |
| `Workspace: 許可パッケージ資料を再生成` | `ApprovedPackages\Update-ApprovedPackagesDocument.ps1` | 許可パッケージの一覧資料を再生成する |
| `Project: 実行用パッケージを導入` | `ApprovedPackages\Install-Packages.ps1 -SelectProject -Target Runtime` | `requirements.txt` を導入する |
| `Project: 開発用パッケージを導入` | `ApprovedPackages\Install-Packages.ps1 -SelectProject -Target Development` | `requirements-dev.txt` を導入する |
| `Project: すべてのパッケージを導入` | `ApprovedPackages\Install-Packages.ps1 -SelectProject -Target All` | 両方のファイルを導入する |

`Project:` タスクは、実行後にプロジェクトを一覧から番号で選びます。`-Target` はタスクごとに固定されています。

`.vscode/settings.json` には、リポジトリの自動検出（`git.autoRepositoryDetection`）と検索深度2階層（`git.repositoryScanMaxDepth`）を設定しています。親リポジトリと各プロジェクトのリポジトリを、VS Codeがすべて検出するための設定です。個人固有のPythonパスや、プロジェクト別のインタープリター設定は置きません。

## NewProject

[NewProject/New-Project.ps1](NewProject/New-Project.ps1) は、`Projects/_Template_Python` をコピーして `Projects/Project 表示名` を作成します。日本語メッセージは、同じフォルダーの `New-Project.messages.json`（UTF-8、BOMなし）から読み込みます。

### 作成の流れ

1. `Workspace: 新規プロジェクトを作成` を実行します。
2. プロジェクト表示名を入力します。`Project ` は自動で付くため入力しません。`Sample` なら `Project Sample` が作成されます。
3. インストール済みのPythonを、一覧から番号で選びます。
4. Python識別名を入力します。小文字の英字・数字・アンダースコアで構成し、日本語やハイフンは使えません。`main` とPythonの予約語は使えません。標準ライブラリと同名の場合は、警告と確認が表示されます。
5. 最低Pythonバージョンを入力します。Enterのみで、選んだPythonの `メジャー.マイナー` が既定値になります。選んだPythonより新しいバージョンは指定できません。
6. 作成内容を確認し、`Y` で作成します。

既存の作成先がある場合は、処理を始める前にエラーで停止し、上書きしません。

### 作成する内容

- テンプレートの内容をコピーします。`.git`、`.venv`、`venv`、`__pycache__` はコピーしません。
- プロジェクト名やPython識別名など、README内の置換項目を置き換えます。
- 選んだPythonで、プロジェクト内に `.venv` を作成します。失敗した場合は、今回作成したフォルダーを削除するかどうかを確認します。
- コピー先で `git init -b main` を実行します。ステージング、コミット、リモート登録、pushは行いません。
- パッケージは導入しません。必要なパッケージは、`requirements.txt` などに記載したうえで `Install-Packages.ps1` で導入します。

### PowerShellから直接実行する

PythonWorkspace直下で実行します。引数を省略した項目は、対話で入力します。

```powershell
.\.tools\NewProject\New-Project.ps1
```

引数: `-ProjectDisplayName`、`-PythonIdentifier`、`-PythonPath`、`-MinimumPythonVersion`。そのほかの引数は、テスト専用です。

### Gitビューに表示されない場合

編集内容を保存し、`Developer: Reload Window` を実行すると、標準Git拡張機能が2階層以内のリポジトリを再検出します。表示されない場合は `Git: リポジトリを開く` で作成先を指定してください。Gitの再初期化は不要です。

### 検証する

```powershell
.\.tools\NewProject\Test-New-Project.ps1
```

`-Group` で範囲を指定できます。省略時は `All` です。

| グループ | 内容 |
| --- | --- |
| `Unit` | 関数単位の検証。プロジェクトも `.venv` も作成しません |
| `Tasks` | `.vscode/tasks.json` の検証 |
| `Integration` | `%TEMP%` 配下の一時フォルダーでプロジェクトを作成して検証します。そこで `.venv` を作成しますが、パッケージ導入やネットワーク接続はしません |
| `All` | すべて |

結果は Pass、Fail、NotReady で表示されます。Failがある場合だけ終了コードが1になります。一時フォルダーは終了時に削除し、`Projects/` は変更しません。VS Codeの入力画面やGitビューの自動検出は、このテストの対象外です。

## ApprovedPackages

プロジェクトで使用できるパッケージを、許可リストで管理するツールです。日本語メッセージは、すべて `ApprovedPackages.messages.json`（UTF-8、BOMなし）から読み込みます。

| スクリプト | 内容 |
| --- | --- |
| [ApprovedPackages/Manage-ApprovedPackage.ps1](ApprovedPackages/Manage-ApprovedPackage.ps1) | 許可リストを対話式で管理します |
| [ApprovedPackages/Update-ApprovedPackagesDocument.ps1](ApprovedPackages/Update-ApprovedPackagesDocument.ps1) | JSONから一覧資料 `approved-packages.md` を生成します |
| [ApprovedPackages/Install-Packages.ps1](ApprovedPackages/Install-Packages.ps1) | 許可リストと照合したうえで、パッケージを導入します |
| [ApprovedPackages/ApprovedPackages.Common.ps1](ApprovedPackages/ApprovedPackages.Common.ps1) | 上記が共有する関数です。直接実行しません |
| [ApprovedPackages/Test-ApprovedPackages.ps1](ApprovedPackages/Test-ApprovedPackages.ps1) | 上記のテストです |

### 許可リスト

正式データは `ApprovedPackages/approved-packages.json` です。`approved-packages.md` は、JSONから生成する閲覧用の資料です。直接編集せず、一覧の更新は `Workspace: 許可パッケージを管理` で行います。変更後に資料は自動で再生成されます。単独で再生成する場合は `Workspace: 許可パッケージ資料を再生成` を使います。生成日時は記載しないため、内容が同じなら出力も同じです。

- パッケージは、正規化した名前（小文字、`-` `_` `.` の連続を `-` に統一）の昇順で保存します。
- ステータスは `approved`、`pending`、`deprecated`、`disabled` です。導入できるのは `approved` だけです。1つでも導入できないパッケージが含まれる場合は、全体を停止します。
- 登録済みパッケージの削除はできません。利用を停止する場合は、`disabled` にします。
- `approvedDate` は、`approved` になったときの日付を記録し、`approved` 以外では空です。用途、備考、許可バージョンを変更しても更新しません。
- 許可バージョンは、`312`、`0.10.3`、`8.*`、`8.*.*` の形式です。`8.*` と `8.*.*` は、どちらもメジャーバージョン8を許可します。末尾の0は、比較のときだけ同値として扱い、保存した表記は変更しません。
- `allowedVersions` が空の場合は、任意のバージョンを許可します。導入前に警告と確認が表示されます。

### Manage-ApprovedPackage.ps1

`Workspace: 許可パッケージを管理` で起動し、メニューの番号を入力します。操作できるのは、新規登録、登録内容の確認、用途（purpose）の更新、備考（notes）の更新、許可バージョンの追加・削除、ステータス変更、資料の再生成です。許可バージョンをすべて削除すると、任意バージョンの許可になるため、警告と確認が表示されます。

### Install-Packages.ps1

`Project:` タスクを使うのが標準です。ターミナルからは、PythonWorkspace直下でプロジェクトを指定して実行します。

```powershell
.\.tools\ApprovedPackages\Install-Packages.ps1 -ProjectPath ".\Projects\Project Sample" -Target Runtime
```

| 引数 | 内容 |
| --- | --- |
| `-ProjectPath` | 対象プロジェクトのパス。`-SelectProject` と同時に指定できません |
| `-SelectProject` | プロジェクトを一覧から番号で選びます。`-ProjectPath` と同時に指定できません |
| `-Target` | `Runtime`（`requirements.txt`）、`Development`（`requirements-dev.txt`）、`All`（両方） |
| `-ValidateOnly` | すべての確認と導入計画の表示だけを行い、pipの実行もファイルの変更もしません |

動作は次のとおりです。

- `requirements` には、`package` または `package==version` の行だけを記載できます。範囲指定、extras、URL、行末コメントなどは、理由を表示して停止します。コメント行と空行は使用できます。
- 照合・導入の対象は、直接依存だけです。推移的依存はpipに任せ、ファイルに追記しません。
- 導入は、プロジェクトの `.venv` のpipを、1回の呼び出しで実行します。`--upgrade`、`--trusted-host` は付けず、SSL検証の無効化やpip設定の変更もしません。
- バージョンを指定していない行は、許可リストに従って決まります。完全固定なら固定バージョンを、`8.*.*` のような指定なら範囲内の最新版（`>=8,<9` に相当）を、`allowedVersions` が空ならpipの選択を使います。
- `requirements` に正確なバージョンがある場合は、許可リストとの一致だけを検証し、その版を導入します。
- 導入に成功した後、バージョンのない行だけを、実際に導入された版（`package==version`）に書き換えます。コメント、空行、並び順、BOM、改行コードは維持します。
- 失敗した場合や導入結果を確認できない場合は、`requirements` を変更しません。自動のアンインストールや巻き戻しはしないため、プロジェクトの `.venv` を確認してください。
- 終了コードは、0が成功、1がエラー、2が利用者による中止です。

### 検証する

```powershell
.\.tools\ApprovedPackages\Test-ApprovedPackages.ps1
```

実行には約3分かかります。許可リスト、名前とバージョンの判定、requirementsの解析、書き込み、Markdown生成、Manageの操作、導入計画と停止条件、`-ValidateOnly` を検証します。導入のテストは、`%TEMP%` 配下のテスト用ワークスペースと、記録用の偽のPythonを使います。実際のpip、外部パッケージの導入、ネットワーク接続は行わず、`Projects/` と許可リストは変更しません。実際のpipの動作は、このテストの対象外です。