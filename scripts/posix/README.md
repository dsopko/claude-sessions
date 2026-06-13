# POSIX scripts — help wanted

Linux and macOS ports of the Windows scripts land here. The jobs are identical:

1. `setup.sh` — interview flags -> config.json, optional protocol registration, first index
2. `update-session-index.sh` (or a shared Node implementation) — head/tail scan of
   `~/.claude/projects/*/!(agent-*).jsonl` -> data.js (see the schema in CLAUDE.md)
3. Protocol registration: `.desktop` file + `xdg-mime` (Linux); stub `.app`
   bundle with `CFBundleURLTypes` (macOS)
4. `launch-handler` — same validation rules; read SECURITY.md before writing it

WSL2's missing piece is different: the browser lives on Windows, so the handler
must register Windows-side and launch back across the boundary
(`wsl.exe --cd <path> -- claude ...`). Tracked as its own milestone.
