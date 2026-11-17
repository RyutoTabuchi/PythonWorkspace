# Python ワークスペース

WindowsとVS CodeでPythonプロジェクトを開発するための共通基盤です。
プロジェクトの作成、許可パッケージの管理と導入、共通の開発手順をまとめています。
新規開発はPython単体で行います。

## フォルダー構成

```text
PythonWorkspace/
  .github/                 GitHub Copilot向けの共通指示
  .tools/                  プロジェクト作成・許可パッケージ管理の共通ツール
  .vscode/                 共通のVS Codeタスクと設定
  ApprovedPackages/        許可パッケージの正式データと一覧資料（.gitkeepのみGit管理）
  Projects/
    _Template_Python/      プロジェクト作成用テンプレート
    Project 表示名/        作成したプロジェクト（独立したGitリポジトリ）
  Reports/                 不具合・保守のレポート
  SampleDatas/             一時的な検証用サンプルデータの置き場
  README.md                この文書
```

各プロジェクトの構成は次のとおりです。

```text
Projects/Project 表示名/
  README.md                目的・実行方法・依存関係
  requirements.txt         実行用パッケージ
  requirements-dev.txt     開発用パッケージ
  .gitignore
  .git/                    このプロジェクト専用のGitリポジトリ
  .venv/                   このプロジェクト専用の仮想環境
  source/                  Pythonコード（実行ファイルは source/main.py）
  tests/                   自動テスト（automated/）と試作（experiments/）
  config/ 
  input/ 
  output/ 
  logs/
```

プロジェクトごとに独立したGitリポジトリと `.venv` を持ちます。

## プロジェクトを作成する

1. `Workspace.code-workspace` またはワークスペース直下のフォルダーをVS Codeで開きます。
2. 「ターミナル」→「タスクの実行」→「Workspace: 新規プロジェクトを作成」を選びます。
3. 表示に従い、プロジェクト表示名、使用するPython、Python識別名、最低Pythonバージョンを入力します。`Sample` と入力すると `Projects/Project Sample` が作成されます。

作成処理は、`.venv` の作成と `git init -b main` までを行います。パッケージの導入、ステージング、コミット、pushは行いません。作成したプロジェクトがGitビューに表示されない場合は、`Developer: Reload Window` を実行するか、`Git: リポジトリを開く` で作成先を指定してください。

詳しい引数、メッセージ、テストは [.tools/README.md](.tools/README.md) を参照してください。

## パッケージを導入する

導入できるのは、`ApprovedPackages/approved-packages.json` で許可済みのパッケージだけです。許可パッケージの一覧は、ローカルの `ApprovedPackages/approved-packages.md` で確認できます。許可パッケージの登録・変更はワークスペース管理者が行います。

`ApprovedPackages/` はフォルダー維持用の `.gitkeep` のみGit管理し、許可リストのデータは管理しません。`Workspace: 許可パッケージを管理` タスクを起動すると、JSONがなければ空の許可リストを作成し、MarkdownがなければJSONから生成します。JSONが壊れている場合は自動修復・上書きせずエラーにします。新しくクローンした場合、空のリストには許可パッケージが登録されていないため、ワークスペース管理者から最新版の `approved-packages.json` を入手するか、管理者が許可パッケージを登録してください。

既存環境で一覧の追跡解除を含む変更を取り込む前に、`ApprovedPackages/` をワークスペースの外へ退避してください。Gitによって追跡中だったファイルが作業ツリーから削除される場合があるため、取り込み後に元の場所へ戻します。

1. プロジェクトの `requirements.txt`（実行用）または `requirements-dev.txt`（開発用）へ、`package` または `package==version` の形式で記載します。
2. 「ターミナル」→「タスクの実行」から、次のいずれかを選びます。対象プロジェクトは一覧から番号で選択します。
   - `Project: 実行用パッケージを導入`
   - `Project: 開発用パッケージを導入`
   - `Project: すべてのパッケージを導入`

`requirements.txt` を直接 `pip install -r` で導入しないでください。許可されていないパッケージが1つでも含まれる場合は、何も導入せずに停止します。

許可パッケージを管理するタスクは次のとおりです。

- `Workspace: 許可パッケージを管理`
- `Workspace: 許可パッケージ資料を再生成`

## 実行する

通常の実行は、ターミナルからプロジェクト内の `.venv` のPythonを直接実行します。

```powershell
cd ".\Projects\Project 表示名"
.\.venv\Scripts\python.exe .\source\main.py
```

この実行方法は、VS Codeで選択中のインタープリターには依存しません。補完や型解析など、VS Code上で対象プロジェクトの環境が必要な場合は `Python: Select Interpreter` で、`Projects\Project 表示名\.venv\Scripts\python.exe` を選択してください。プロジェクトを切り替えた場合は、必要に応じて選び直します。

## Gitの構成

ワークスペース直下の親リポジトリと、各プロジェクトのリポジトリは別々のGitリポジトリです。親リポジトリは `Projects/Project */` を管理しません。VS Codeのソース管理に複数のリポジトリが表示されるのは正常です。コミット前に、操作対象のリポジトリ名を必ず確認してください。詳しくは [Git 管理ガイド.md](<Git 管理ガイド.md>) を参照してください。

## SampleDatas

`SampleDatas/` は、一時的な検証用サンプルデータを置く場所です。中身はGit管理されません。実業務データ、個人情報、機密情報、認証情報、顧客情報など、Git管理してはいけないデータは置かないでください。

## 関連ドキュメント

- [新人向け開発手順書](新人向け開発手順書.md)
- [Git 管理ガイド](<Git 管理ガイド.md>)
- [Workspace全体ロジック](Workspace全体ロジック.md)
- [.tools/README.md](.tools/README.md)
- [プロジェクトテンプレートのREADME](Projects/_Template_Python/README.md)