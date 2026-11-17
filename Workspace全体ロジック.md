# Workspace 全体ロジックガイド

## 1. このワークスペースは何をする場所か

このワークスペースは、WindowsとVS Codeで開発するPythonプロジェクトの作成・開発基盤です。各プロジェクトは `Projects/` 配下に置き、Pythonソース、README、依存関係、Git履歴をプロジェクト単位で管理します。新規開発はPython単体で行います。

ワークスペース直下には、共通の開発手順、Git運用情報、VS Code設定、補助ツール、許可パッケージの管理データ、プロジェクト作成用テンプレートを置きます。プロジェクト固有の機能・処理内容・コマンドは、それぞれのREADMEを参照してください。

## 2. フォルダー構成と役割

| 場所 | 役割 |
| --- | --- |
| `Projects/_Template_Python/` | Pythonプロジェクトのテンプレートです。 |
| `Projects/Project 表示名/` | 作成したプロジェクトです。プロジェクトごとに独立したGitリポジトリと `.venv` を持ちます。 |
| `Projects/Project 表示名/source/` | Pythonの本番ソースを置きます。実行ファイルは `source/main.py` です。 |
| `Projects/Project 表示名/tests/` | 自動テスト（`automated/`）と、本番採用前の試作・調査（`experiments/`）を置きます。 |
| `Projects/Project 表示名/requirements.txt` | 実行用パッケージを記載します。開発用は `requirements-dev.txt` です。 |
| `ApprovedPackages/` | 許可パッケージの正式データ（`approved-packages.json`）と、自動生成する一覧資料（`approved-packages.md`）を置きます。データはGit管理外で、フォルダー維持用の `.gitkeep` のみ管理します。 |
| `.vscode/` | ワークスペース共通のVS Codeタスクと設定を置きます。 |
| `.tools/` | プロジェクト作成と許可パッケージの管理・導入のツールを置きます。 |
| `.github/` | GitHub Copilot向けの共通指示を置きます。 |
| `Reports/` | 不具合・保守のレポートを置きます。 |
| `SampleDatas/` | 一時的な検証用サンプルデータの置き場です。中身はGit管理しません。 |
| `新人向け開発手順書.md` | 作業対象の選定、環境準備、実行、変更確認などの共通手順です。 |
| `Git 管理ガイド.md` | Gitの基本操作と、このワークスペースでの管理上の注意を説明します。 |

## 3. プロジェクト作成と開発

新規作成はVS Codeの `Workspace: 新規プロジェクトを作成` タスク、または `.tools/NewProject/New-Project.ps1` を使用します。作成できるのはPythonプロジェクトだけで、プロジェクト種類の選択はありません。

作成処理は、テンプレートのコピー、プロジェクト内の `.venv` の作成、`git init -b main` を行います。パッケージの導入、ステージング、コミット、リモート登録、pushは行いません。

作業前に対象プロジェクトのREADMEと設定を確認します。各プロジェクトのコード、依存関係、実行方法、テスト方法は個別に管理し、ワークスペース全体を一括実行・更新する前提にはしません。

通常の実行は、ターミナルからプロジェクト内の `.venv\Scripts\python.exe` を直接実行します。VS Codeで選択中のインタープリターには依存しません。

## 4. 許可パッケージ

使用できる外部パッケージは、`ApprovedPackages/approved-packages.json` に許可済みとして登録されたものだけです。登録・変更はワークスペース管理者が `Workspace: 許可パッケージを管理` で行います。`approved-packages.md` はJSONから自動生成するため、直接編集しません。

パッケージの導入は、`Project:` の導入タスク（`.tools/ApprovedPackages/Install-Packages.ps1`）で行います。処理の流れは次のとおりです。

1. 対象プロジェクトの `requirements.txt` または `requirements-dev.txt` を読み込み、`package` または `package==version` の形式だけを受け付けます。
2. 直接依存だけを許可リストと照合します。1つでも許可されていないパッケージがあれば、何も導入せずに全体を停止します。
3. プロジェクトの `.venv` のpipで、直接依存を1回の呼び出しで導入します。推移的依存はpipに任せます。
4. 導入に成功した場合だけ、バージョンのない行を実際に導入された版に書き換えます。失敗した場合は `requirements` を変更しません。

`requirements` を直接 `pip install -r` で導入しないでください。

## 5. Gitと機密情報

ワークスペース直下の親リポジトリと、各プロジェクトのリポジトリは別々のGitリポジトリです。親リポジトリは `Projects/Project */` を管理せず、各プロジェクトの管理範囲は、プロジェクト直下の `.gitignore` を含めて確認します。VS Codeのソース管理に複数のリポジトリが表示されるのは正常です。コミット前に、操作対象のリポジトリ名を必ず確認してください。

仮想環境、一時ファイル、秘密情報を不用意にコミットしないでください。`SampleDatas/`、`input/`、`output/`、`logs/` の中身はGit管理しません。実業務データ、個人情報、機密情報、認証情報は、コードや設定にも保存しないでください。

## 6. Excelファイルとの関係

新規のVBAは作成しません。PythonでExcelファイルを扱うことは禁止していません。ただし、CopilotにExcelの起動、ブックの読み取り、マクロ実行、変更・保存、COM操作を依頼する場合は、対象と操作内容ごとに事前許可を確認します。

## 7. 関連ドキュメント

- [ワークスペースREADME](README.md)
- [プロジェクトテンプレートのREADME](Projects/_Template_Python/README.md)
- [共通ツール](.tools/README.md)
- 許可パッケージ一覧: ローカルの `ApprovedPackages/approved-packages.md`
- [新人向け開発手順書](新人向け開発手順書.md)
- [Git管理ガイド](Git%20管理ガイド.md)
