# Mission-flow localization

The normal `apply-japanese.ps1` patcher runs this script automatically for mission messages, dialogue, prompts, banners, mission labels, and scroll stories. The main patcher also supports `-FlowOnly` to apply only these files.

The locator catalog identifies replacements by file, zero-based line number, character range, and a SHA-256 fingerprint of the expected source text. It stores the Japanese replacement and hashes, not English lookup strings. Scroll-story blocks are guarded by source and expected-output hashes. The script checks every source and expected output before writing any file; if the installed mission files differ from the supported version, it stops without changing them.

The catalog covers 44 supported mission-flow files. It skips the game's test flows and `README.txt`. It requires the verified original flow backups created by the main patcher under `JapaneseLocalization/backup`.

For a standalone run from the game folder, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\JapaneseLocalization\Tools\apply-flow-locators.ps1"
```

The script can also be called with `-DataRoot` for a separate game-data folder or `-FlowFileNames` for a selected set of files. Reapplying it to files with the recorded Japanese output hashes is a no-op.

A game update requires rebuilding and verifying the locator data for that exact version before applying it.
