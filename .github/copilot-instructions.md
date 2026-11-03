# Workspace-wide instructions

> **Workspace purpose: Python-only project development on Windows with VS Code.** Each project under `Projects/` owns its source code, documentation, and Git history as one unit.

- Create new projects only with `.tools\NewProject\New-Project.ps1` (VS Code task `Workspace: 新規プロジェクトを作成`), which copies `Projects/_Template_Python`. New development is Python only; do not add project-type selection and do not create new VBA code.
- Follow the conventions of the project being changed. Keep changes focused on the request, readable, and consistent with nearby code.
- Before editing, read the README for the target project and inspect relevant source, configuration, and tests. Read other projects' READMEs only when the task spans those projects or shared behavior.
- Project layout: Python code in `source/` (entry point `source/main.py` with `def main()`), automated tests in `tests/automated/`, unverified experiments and prototypes in `tests/experiments/`, runtime dependencies in `requirements.txt`, development dependencies in `requirements-dev.txt`, and the virtual environment in `.venv/`. Preserve these exact names. Do not mix unverified experiments with production source or imply that experimental code is already adopted.
- Normal execution is from a terminal with the project's own interpreter (`.\.venv\Scripts\python.exe .\source\main.py`), not through the interpreter selected in VS Code. Do not store PC-specific absolute paths in code or settings, and never commit secrets.
- Git layout: the parent repository at the workspace root and each `Projects/Project *` folder are independent repositories; the parent ignores the project folders. Do not create nested repositories inside a project or restructure projects unless requested or necessary for the task. Run `git add`, `commit`, `push`, `tag`, and `remote` operations only when the user asks; read-only Git checks are allowed.
- Keep shared tools and standard VS Code tasks at the workspace root. Normally work with the whole workspace open; nested project `.vscode/settings.json` files do not configure the parent workspace. Each project has its own `.venv`, so do not add a project-specific interpreter to the shared workspace settings.
- `Archive/` holds retired legacy material outside Git. Do not investigate or edit it unless the user asks.
- After code changes, run the smallest relevant existing validation and report what was checked and any checks that could not be run.

## Approved packages

- Use only packages registered as approved in `ApprovedPackages/approved-packages.json` (canonical data). `ApprovedPackages/approved-packages.md` is generated from it; never edit it by hand. Edit the list only through `.tools\ApprovedPackages\Manage-ApprovedPackage.ps1` and regenerate the document with `Update-ApprovedPackagesDocument.ps1`.
- Do not add an external library on your own initiative. Only direct dependencies are checked against the list. If a needed package is not approved, report it and ask the user instead of adding it.
- Do not create `.venv`, run `pip`, or install packages yourself. Installation is done by the user with `.tools\ApprovedPackages\Install-Packages.ps1` (VS Code `Project:` tasks). You may run it with `-ValidateOnly`, which changes nothing.
- `requirements.txt` and `requirements-dev.txt` accept only `package` or `package==version` lines plus whole-line comments and blank lines. Do not add version ranges, extras, or transitive dependencies.

## Approval before Excel operations

- Before starting Excel, opening a workbook, running a macro, or modifying or saving a live workbook, ask for explicit permission in Japanese and wait for an affirmative reply. This separate confirmation is required even if the original task requests the operation; a general request to investigate or improve the workspace is not permission.
- Make the request unmistakable as a permission question, not a notice. State the exact workbook path, planned operation, relevant macro or script, and whether workbook contents will change. For example: 「【許可の確認】Excelを起動して、ブック『<フルパス>』を開いてもよいですか？ 読み取りのみで、マクロの実行や変更・保存は行いません。許可をいただくまで操作しません。」
- Permission to open or read does not authorize macro execution, modification, or saving. Obtain separate permission before expanding scope. Never substitute a similarly named workbook.
- This applies to tools, tasks, scripts, delegated work, and COM automation, including Python scripts that launch Excel or use COM to open, read, modify, or save workbooks, and read-only tools that may launch Excel automatically. Do not run such scripts for validation before approval. When behavior is uncertain, inspect offline files first. Without approval, limit work to offline source, configuration, and documentation and disclose runtime validation limits.

## VBA and Excel files

- Do not create new VBA code. Existing VBA files (for example `.bas`, `.cls`, `.frm`) are reference material: change them only when the user explicitly asks.
- Do not import code into a workbook or run macros unless explicitly requested, and follow the Japanese permission procedure above before any Excel operation. Editing a source file does not update the code inside a workbook.
- Python code may handle Excel files, and doing so is not prohibited. Check the project's README and approved packages before choosing a library.

## Python development

Apply these rules when creating or changing Python source, including experiments.

- Target the Python version selected by the project (its README and `.venv`). There is no fixed workspace-wide minimum version; do not use syntax or library features newer than the selected version.
- Use four spaces for indentation. Add type hints to public functions where practical.
- Add Japanese docstrings in triple double quotes to newly created or modified modules, classes, and functions, including private ones. Describe their purpose or behavior.
- Keep each function focused and reasonably short. Add brief comments only when the logic is not self-explanatory.
- Use the standard-library `logging` module, rather than `print`, to report errors and warnings.
- Naming follows PEP 8: `snake_case` for functions, variables, and parameters; `UpperCamelCase` for classes; `UPPER_SNAKE_CASE` for constants; prefix private names with `_`. Existing code keeps the conventions of its surrounding code.
- Prefer the standard library over external packages unless the project or user requires otherwise. Before changing dependencies or behavior, check the target project's README, `requirements.txt`, `requirements-dev.txt`, and relevant tests, and follow the approved-packages rules above.
- Validate with the target project's `.venv\Scripts\python.exe`. If `.venv` does not exist, run only read-only or standard-library-only checks with the installed system Python. Do not create a virtual environment or install packages. Confirm the interpreter used for validation and report it.
- Avoid PC-specific hardcoded paths and changes to a shared Python environment outside the requested scope.

## Validation and handoff

- Distinguish source checks, Python tests, and runtime checks in the real environment (including Excel or VS Code operation). Passing static checks or Python tests does not establish that the real operation works. Report untested boundaries explicitly.
- Do not claim automatic activity logging or memory generation unless the required tools are configured and their results have been verified.
- If a project already uses `CopilotActivityLog.md` and `CopilotMemory.md`, follow its README. Keep new activity entries uniquely identified and `copilot_context: false`; only the user changes them to `true` or `discard`. Do not overwrite history, delete entries, or claim memory was generated without performing and verifying the operation. Never record secrets or unrelated personal data.

## Troubleshooting reports

- Before investigating a concrete problem, search existing reports for the target project and relevant shared area. Check `Defects/` and `Maintenance/` subfolders when present. Verify historical guidance against current code, configuration, and environment rather than applying it blindly.
- Once a concrete problem is fixed and verified, record the confirmed cause, resolution, and validation in the appropriate report. Check for the same root cause first; add a dated note when a recurrence adds useful information instead of duplicating or replacing history. Clearly label guesses and unverified results.
- For report creation, organization, updates, or investigation summaries, follow the instruction file `instructions/Report Writing Rules.instructions.md`. Do not relocate or rename existing reports merely to apply the new rules.

These English-language instructions are the authoritative workspace guidance for Copilot.
