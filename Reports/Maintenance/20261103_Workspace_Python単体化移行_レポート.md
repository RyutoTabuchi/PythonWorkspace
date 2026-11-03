# Workspace：VBA×PythonからPython単体への移行 レポート

| 項目 | 内容 |
| --- | --- |
| 種類 | Maintenance |
| 作成日 | 2026-11-03 |
| 最終更新日 | 2026-11-03 |
| 対象 | PythonWorkspace（親リポジトリ）の構成、共通ツール、許可パッケージ、VS Codeタスク、指示書、文書。TClickプロジェクトは対象外（別工程） |
| 状態 | 対応中 |

## 1. 概要・結論

本ワークスペースを、VBA×Python統合の構成から、Windows・VS Code向けのPython単体構成へ移行した。親リポジトリでの工程2〜10は完了し、工程11（総合テストと本レポートの作成）まで実施した。

状態は**対応中**とする。次の理由による。

- 実際のpipによるパッケージ導入など、Copilotが確認できていない項目が残る（「8. 検証結果」の「未検証」）。
- TClickプロジェクト（独立リポジトリ）の整理が未着手である。

Copilotが実測できた範囲では、不合格の項目はない。実測した結果は、現在のワークスペースで `Test-New-Project.ps1 -Group All` が54件合格、`Test-ApprovedPackages.ps1` が179件合格である。これらは偽のPythonと一時フォルダーを使う静的・模擬的な検証であり、実環境での動作確認ではない。

「完了」への更新は、利用者が指示したときに日付付きで追記する。

## 2. 背景・目的

利用者が決定した移行仕様（Python専用ワークスペースの初版仕様）に従い、既存のVBA×Python統合ワークスペースを、Python単体の開発基盤へ移行する。目的は次のとおり。

- Pythonプロジェクトを、テンプレートから一定の構成で作成できるようにする。
- 使用できる外部パッケージを許可リストで管理し、導入を専用ツールに集約する。
- VBA・Excel専用の資産を、削除せずArchiveへ分離する。
- 指示書と文書を、Python単体の運用に合わせる。

## 3. 対象・影響範囲

- 対象：親リポジトリ（PythonWorkspace直下）。基準は最初のコミット `dd8bfc7`（仕様移行初期状態）。
- 影響：新規プロジェクトの作成方法、パッケージ導入の手順、VS Codeタスク、Copilot指示書、各文書。旧VBA×Pythonプロジェクト作成タスクとExcel関連タスクは利用できなくなった。
- 対象外：
  - `Projects/Project Tclick申請補助/`（独立したGitリポジトリ。本移行では変更していない）。
  - リモートリポジトリの設定とpush（リモートは未設定）。
  - 実際のpipによるパッケージ導入の実環境検証。

## 4. 事象・変更前の状態

移行前（基準 `dd8bfc7`）の構成と課題は次のとおり。

- 作成できるプロジェクトは、`Pysource/` と `VBsource/` を持つVBA×Python統合の1種類だった。テンプレートは `Projects/_Template_Combined`。
- 作成ツールは `.tools/New-Project.ps1` で、`ExecutionPolicy Bypass` を使うタスクから起動していた。仮想環境は作成せず、Gitのステージングまで行っていた。
- パッケージの許可リストと導入ツールはなかった。
- `.tools/UserFormCsvExporter/` とExcel用タスクが存在した。
- 共通指示書と文書は、VBA・Excelを前提としていた。
- `Git 管理ガイド.md` はコードブロックが閉じておらず、表示が崩れていた。
- `SampleDatas/.gitkeep` が `.gitignore` により管理対象外だった。

## 5. 調査・作業内容

| 工程 | コミット | 作業内容 |
| --- | --- | --- |
| 基準 | `dd8bfc7` | 仕様移行初期状態。移行前の状態を記録した最初のコミット |
| 1 | （コミットなし） | 削除状態だった `.tools/UserFormCsvExporter` の4ファイルをHEADから復元した |
| 2 | `bd1e099` | `.gitignore` の更新、`SampleDatas/.gitkeep` の追加、`Archive/` の除外 |
| 3 | `d243b4a`, `a3a4f91` | `Projects/_Template_Python`（11ファイル）の作成と、`tests/README.md` の追加 |
| 4 | `ff39fe6` | プロジェクト作成ツール（`New-Project.ps1` とそのメッセージ、テスト）の作り直し |
| 5 | `77ab5c6` | 作成ツールを `.tools/NewProject/` へ移動。許可パッケージの共通関数、管理・資料生成ツール、テスト、初期データ8件 |
| 6 | `6b4c2e0` | `Install-Packages.ps1` の追加。テンプレートREADMEの更新 |
| 7 | `ae881d4` | `.vscode/tasks.json` を6タスクに整理。`settings.json` の旧Python設定を削除 |
| 8 | `502327c` | `.github` の共通指示書（英語正本と日本語版）とレポート規則の見直し |
| 9 | `f720c7c` | 5つの文書の更新と `Workspacee全体ロジック.md` の改名 |
| 10 | `d56897a` | `Archive/Legacy-VBA/` の作成と、VBA専用資産11ファイルの移動 |
| 11 | （未コミット） | 総合テスト、`Test-New-Project.ps1` の最小修正、本レポートの作成 |

基準から工程10のコミット（`d56897a`）までの差分は49ファイルで、追加24、変更10、削除15である（`git diff --find-renames`）。各工程のコミットはすべて利用者が作成した。Copilotはステージングとコミットを行っていない。

## 6. 原因・変更理由

- Python単体の開発に絞り、VBA・Excel固有の運用を共通基盤から分離するため。
- 使用できるパッケージを統制し、導入手順を一本化するため（直接依存のみ許可リストと照合する）。
- 実行ポリシーのBypassに依存せず、プロジェクトごとの `.venv` を明示的に使う運用にするため。
- 移行前から壊れていた文書（コードブロック、`.gitkeep` の管理漏れ）を、移行の機会に直すため。

主な設計判断（利用者が決定したもの）は次のとおり。

- プロジェクトは独立したGitリポジトリで、親は `Project */` を管理しない。作成時に行うGit操作は `git init -b main` だけである。
- 許可リストは `ApprovedPackages/approved-packages.json` を正式データとし、`.md` は自動生成する。削除機能はなく、利用停止は `disabled` で表す。
- `Install-Packages.ps1` は、直接依存を1回のpip呼び出しで導入する。失敗時は `requirements` を変更せず、ロールバックもしない。
- `Archive/` はGit管理外で、バックアップではない。
- 命名はPEP 8、Pythonバージョンの下限は固定しない（プロジェクトごとに選択する）。

## 7. 対応・変更内容

### 実施済みの変更（親リポジトリ）

| 領域 | 変更後の状態 |
| --- | --- |
| テンプレート | `Projects/_Template_Python/`（`source/`、`tests/`、`config/`、`input/`、`output/`、`logs/`、`requirements*.txt`、README） |
| プロジェクト作成 | `.tools/NewProject/`。`.venv` を作成し、`git init -b main` を実行する。パッケージ導入とステージングは行わない |
| 許可パッケージ | `.tools/ApprovedPackages/`（管理、資料生成、導入、共通関数、テスト）と `ApprovedPackages/`（初期8件） |
| VS Codeタスク | `Workspace:` 3件と `Project:` 3件の6タスク。`-ExecutionPolicy Bypass` とExcelタスクは削除した |
| 指示書 | `.github/copilot-instructions.md`（正本）、`.ja.md`、`Report Writing Rules.instructions.md` |
| 文書 | [README.md](../../README.md)、[.tools/README.md](../../.tools/README.md)、[Git 管理ガイド.md](../../Git%20管理ガイド.md)、[新人向け開発手順書.md](../../新人向け開発手順書.md)、[Workspace全体ロジック.md](../../Workspace全体ロジック.md) |
| Archive | `Archive/Legacy-VBA/`（`Tools`、`Projects`、`Reports`）。Git管理外 |

許可リストの初期登録は、pdfplumber（0.10.3）、playwright（バージョン指定なし）、pyinstaller（6.\*.\*）、pypdf（6.8.0）、pyperclip（1.\*）、pytest（8.\*.\*）、python-pptx（1.\*.\*）、pywin32（312）の8件である。

### 工程11で行った変更（未コミット）

- `.tools/NewProject/Test-New-Project.ps1`：次の3行だけを修正した。
  - `$script:TasksGroupReady` を `$false` から `$true` に変更した。
  - 冒頭の説明と、Tasksグループの見出しの2つのコメントを、現状に合わせて修正した。
  - 修正前は、Tasksグループの失敗が「NotReady」と表示されて隠れる状態だった。修正前のSHA-256は `885429DB8B6E10516…`、修正後は `C4C2678444C622FBB…` である。
- 本レポートを作成した。

### Archiveへ移動した11ファイル

移動前後のSHA-256（先頭12桁）は一致している（工程10で確認）。Archiveは追跡されないため、ここに記録する。

| 移動先（`Archive/Legacy-VBA/` 配下） | SHA-256（先頭12桁） |
| --- | --- |
| `Tools/UserFormCsvExporter/Export-UserFormCsv.ps1` | 2A4F4B5234AF |
| `Tools/UserFormCsvExporter/Import-UserFormCsv.ps1` | A80300398F70 |
| `Tools/UserFormCsvExporter/Module1.bas` | DA16EECF0F46 |
| `Tools/UserFormCsvExporter/README.md` | 4F3E1DB04595 |
| `Projects/_Template_Combined/.gitignore` | 46565926DC2F |
| `Projects/_Template_Combined/README.md` | 2F6D5A5EFFA2 |
| `Projects/_Template_Combined/requirements.txt` | 3450274731B7 |
| `Projects/_Template_Combined/Sandbox/README.md` | 7CD93217A27D |
| `Projects/_Template_Combined/source/.gitkeep` | 567B5C8B312C |
| `Reports/20261027_ExcelVBASync_…レポート.md` | 6E293FA5FD31 |
| `Reports/Undated_D_CallPython_…レポート.md` | 946926F74F1D |

### 切り戻し方法

- コミット済みの内容は、Git履歴から戻せる。基準 `dd8bfc7` の内容は、`git checkout dd8bfc7 -- <パス>` などで取得できる。
- Archiveへ移動した11ファイルは、移動前のコミット（`f720c7c` 以前）にも残っている。Archive自体はバックアップではないため、Archiveが失われた場合はGit履歴から復元する。
- 工程11の変更（未コミット）は、コミット前であれば、`Test-New-Project.ps1` の変更を元に戻し、本レポートを削除すれば取り消せる。

## 8. 検証結果

### 判定の区別

| 判定 | 意味 |
| --- | --- |
| 合格（Copilotが実測） | Copilotがこのセッションで実行し、結果を直接確認した |
| 不合格 | Copilotが実行し、期待と異なる結果だった |
| 未検証（Copilot未実施） | Copilotが実行していない。結果は不明である |
| 利用者報告（Copilot未確認） | 利用者が確認済みと回答したが、Copilotは内容を確認していない |

### Copilotが実測した検証

実行環境：Windows PowerShell 5.1、Python 3.13.3（`C:\Users\1623120\AppData\Local\Programs\Python\Python313\python.exe`）。ネットワーク接続と実際のpipは使用していない。

| 確認項目 | 方法・条件 | 期待結果 | 実際の結果 | 判定 |
| --- | --- | --- | --- | --- |
| ローカルクローンの内容（HEAD `d56897a`） | `git clone` を `%TEMP%` へ実行し、HEADの追跡ファイル一覧と比較 | 追跡ファイルが一致し、`.gitkeep`、テンプレート、許可リストが存在する | 追跡41件が一致し、`.gitkeep` 5件、テンプレート、許可リスト、`tasks.json` が存在。Archive、旧テンプレート、旧ツール、一時ファイルは含まれない | 合格（Copilotが実測） |
| ローカルクローンでのテスト | クローン内で `Test-New-Project.ps1 -Group Unit` と `-Group Tasks` | 失敗なし | Unit 35件合格、Tasks 5件合格 | 合格（Copilotが実測） |
| 現在のワークスペースでの `Test-New-Project.ps1 -Group All`（修正後） | 工程11の修正を含む状態で実行（約80秒）。Integrationは `%TEMP%` 配下で `.venv` を作成する。パッケージ導入なし | 失敗なし | Pass 54、Fail 0、NotReady 0（Unit 35、Tasks 5、Integration 14） | 合格（Copilotが実測） |
| `Test-ApprovedPackages.ps1` | 現在のワークスペースで実行（約203秒）。偽のPythonと `%TEMP%` のテスト用ワークスペースを使う | 失敗なし | Pass 179、Fail 0、NotReady 0。実際の許可リストは変更されない | 合格（Copilotが実測） |
| PowerShellスクリプトの構文 | PowerShellのパーサーで `.tools` 配下のps1を解析（実行はしない） | エラー0件 | 7ファイルでエラー0件 | 合格（Copilotが実測） |
| JSONの読み込み | 許可リスト、メッセージ2件、`tasks.json`、`settings.json`、`launch.json` | すべて読み込める | 6件すべて読み込めた | 合格（Copilotが実測） |
| 文字コードと改行 | 追跡中のテキスト41件（非空33件）でBOM、改行の混在、ps1の非ASCII、文字化けを検査 | 問題なし | 問題なし。ただし、LFのみのファイルが2件ある（下記の注記） | 合格（Copilotが実測） |
| Markdownのリンク | 追跡中のMarkdownの相対リンクの存在を確認 | リンク切れなし | 新しい文書、`.github` ではリンク切れ0件。残した過去レポートに6件ある（「10. 残課題」） | 合格（Copilotが実測）。ただし過去レポートの6件は既存の問題 |
| 旧語句の残存 | `Reports/` 以外の追跡ファイルを検索 | 旧語句が残らない | テストツール内の否定検査（「Sandboxを含まない」など）と、一時フォルダー名のダミーだけが該当 | 合格（Copilotが実測） |
| タスク定義とスクリプトの整合 | `tasks.json` の6タスクの参照先を確認 | すべて存在する | 6件すべてのスクリプトが存在する | 合格（Copilotが実測） |
| ArchiveがGit管理外 | `git check-ignore`（工程10）と、クローンに含まれないことを確認 | 追跡も表示もされない | 無視されており、クローンにも含まれない | 合格（Copilotが実測） |
| TClickの不変 | HEADとツリーのハッシュ、`git status` | 変更なし | HEAD `52c174d0bff50d2506a385c4e812564573b589bf`、クリーン | 合格（Copilotが実測） |
| 一時フォルダーの残り | `%TEMP%` を確認 | 残らない | 残りなし（クローンも削除済み） | 合格（Copilotが実測） |
| 不合格 | － | － | 不合格の項目なし。ただし修正前は、Tasksグループの失敗が隠れる状態だった（「7」で修正） | 不合格：なし |

注記：

- ローカルクローンは、コミット済みのHEAD `d56897a` を検証したものである。**工程11の未コミットの修正（`Test-New-Project.ps1`）は含まない。** 修正後の状態は、現在のワークスペースで実行した `-Group All` の結果として別に示している。
- ローカルクローンは、別PCでのクローンの代わりにはならない。
- `Workspace全体ロジック.md` と `Workspace.code-workspace` は、リポジトリ内ではLFで保存されている。`core.autocrlf=true` の環境では、クローン後の作業ツリーでCRLFになることを確認した（2件とも）。内容は変わらないが、改行コードは環境の設定に依存する。
- 現在のワークスペースでのIntegrationは、Python 3.13.3 でのみ実行した。

### 未検証（Copilot未実施）

| 項目 | 状態・理由 |
| --- | --- |
| 実際のpipによるパッケージ導入 | **未検証（Copilot未実施）**。導入後のバージョン確認、`pip freeze` の出力形式、stderrの扱い、失敗時の挙動は、偽のPythonでの模擬テストのみ。実際のpipは一度も実行していない |
| New-Project、Manageのキーボードによる実際の対話操作 | **未検証（Copilot未実施）**。標準入力と引数による自動テストのみ |
| VS Codeでの実機操作（Gitビューの複数リポジトリ表示、`Python: Select Interpreter`） | **未検証（Copilot未実施）** |
| 別PCでのクローンと動作 | **未検証（Copilot未実施）** |
| リモートの設定とpush | **未検証（Copilot未実施）**。リモートは未設定 |
| 実行ポリシーが異なるPCでのタスク実行 | **未検証（Copilot未実施）** |
| Python 3.12 でのプロジェクト作成 | **未検証（Copilot未実施）**。検証は3.13.3のみ |
| 社内ネットワーク、証明書、プロキシ環境でのpip | **未検証（Copilot未実施）** |
| 指示書（`.github`）がCopilotの動作に与える効果 | **未検証（Copilot未実施）**。内容の整合のみ確認した |
| TClickプロジェクトの整理 | **未検証（Copilot未実施）**。未着手 |

### 利用者報告（Copilot未確認）

| 項目 | 内容 |
| --- | --- |
| 工程7：VS Codeタスクの起動確認 | **起動確認完了、確認詳細は未記録**。どのタスクをどの条件で確認したかは記録されておらず、Copilotは確認していない。実際のpip導入を実行したかどうかも不明のため、pip導入は未検証のままである |

## 9. 再発防止・運用上の注意

- コミットする前に、操作対象のリポジトリ名（親か、各プロジェクトか）を確認する。
- パッケージは、`Project:` の導入タスク（`Install-Packages.ps1`）だけで導入する。直接 `pip install` しない。許可リストの変更は、ワークスペース管理者が `Manage-ApprovedPackage.ps1` で行う。
- `Archive/` はGit管理外でバックアップではない。移動したファイルを残す場合は、別の保管方法を検討する。
- `Test-New-Project.ps1` は、Tasksグループの失敗を隠さなくなった。`tasks.json` を変更したあとは、`-Group Tasks` を実行して確認する。
- 実行ポリシーのために実行できない場合は、自分で変更せずワークスペース管理者へ相談する。

## 10. 残課題・次の対応

| 課題・未確認事項 | 次に行うこと | 担当・期限 |
| --- | --- | --- |
| 実際のpipによる導入の実環境確認 | 利用者が、許可済みパッケージで `Project:` タスクを実行し、結果を記録する | 未定 |
| New-Project、Manageの対話操作の実機確認 | 利用者が、VS Codeのタスクから操作して確認する | 未定 |
| 別PCでのクローン、リモート設定とpush | リモートを設定した場合に、別PCでクローンして確認する | 未定 |
| Python 3.12 での作成確認 | `Test-New-Project.ps1 -IntegrationPythonPath` で3.12を指定して実行する | 未定 |
| 工程7の確認詳細が未記録 | 必要であれば、確認したタスクと結果を追記する | 未定 |
| TClickプロジェクトの整理（T0〜T7） | VBA専用資料の分離、READMEなどの参照修正、`requirements.txt` の実行用・開発用の分割と許可リスト登録を、TClickの別工程で行う。TClickの `docs` は、本ワークスペースの `Reports/Defects/` や存在しないMaintenanceレポートを参照している | 未定 |
| 過去レポートのリンク切れ（6件） | 過去の記録を書き換えない方針のため修正しない。必要な場合のみ、日付付きの注記を追記する | 未定 |
| 一時ファイル2点（`PythonworkSpaceへの移行計画書.md`、`指示一時置き場後で消す.md`） | TClickの工程の完了後に、利用者が削除する。TClickの工程では引き続き参照する | TClick工程の完了後 |
| 工程11の変更のコミット | 利用者が、`Test-New-Project.ps1` の修正と本レポートをコミットする | 未定 |
| 本レポートの状態を「完了」へ更新 | 利用者の指示があったときに、日付付きで追記する | 未定 |

## 11. 参考資料・変更履歴

### 参考資料

- [Report Writing Rules](../../.github/instructions/Report%20Writing%20Rules.instructions.md)
- [共通指示書（英語正本）](../../.github/copilot-instructions.md)
- [共通指示書（日本語版）](../../.github/copilot-instructions.ja.md)
- [共通ツールの説明](../../.tools/README.md)
- [許可パッケージ一覧](../../ApprovedPackages/approved-packages.md)
- [プロジェクトテンプレートのREADME](../../Projects/_Template_Python/README.md)
- 移行仕様は、未追跡の一時ファイル（`PythonworkSpaceへの移行計画書.md`）である。TClickの工程の完了後に削除するため、リンクは設定しない。

### 変更履歴

| 日付 | 変更内容 |
| --- | --- |
| 2026-11-03 | 初版作成（状態：対応中） |
