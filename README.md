# transfer-claude-sessions

**Switched Claude accounts and your Code tab sidebar went empty? Your sessions are still on your disk. This copies them to the new account in one command.**

Dry run first. Backup before it touches anything. One command to undo. Never moves or deletes a file.

![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

If this saves your sessions, a star helps the next person find it.

## Quick start

```powershell
# 1. Dry run. Shows your account folders and exactly what would be copied. Changes nothing.
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1

# 2. Happy with the plan? Run it for real. It backs up first.
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Apply

# 3. Changed your mind? Restore the backup.
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Undo -Apply
```

Read the guide below once before you run it. The one thing people get wrong is the order of steps.

## Step by step guide

Takes about five minutes. Verified on a real account switch with 34 sessions.

**Step 1. Create the new account's folder first.**
Open Claude Desktop, sign into the **new** account, and open the Code tab once. You do not need to start a session. The app creates a folder for the new account the first time the Code tab opens. Without this step there is nowhere to copy to, and you may end up copying into some older account's folder by mistake.

**Step 2. Quit Claude Desktop completely.**
Closing the window is not enough. Right click the Claude icon in the system tray (bottom right, next to the clock, maybe hidden under the ^ arrow) and choose Quit. The script checks for this and refuses to run while the app is open, because the app rewrites these files while it runs. The Claude Code CLI in a terminal is fine and is ignored.

**Step 3. Get the script.**
Download `transfer-claude-sessions.ps1` from the [latest release](../../releases/latest) or from this repo. Put it in any folder. If Windows blocks it, right click the file, Properties, tick Unblock, OK.

**Step 4. Open PowerShell in that folder.**
In Explorer, right click inside the folder and choose "Open in Terminal", or click the address bar, type `powershell` and press Enter.

**Step 5. Dry run.**

```powershell
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1
```

You get a numbered list of account folders. Each line shows how many sessions it holds and when it was last touched. The script tags the account you signed into most recently and any folder created in the last 24 hours with no sessions, which is almost always the new account.

- SOURCE is the folder with your sessions in it, the account you are leaving.
- DESTINATION is the new account's folder, usually the one with 0 records.

Type the numbers when asked. The script prints exactly what it would copy and stops. Nothing has changed yet.

**Step 6. Apply.**

```powershell
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Apply
```

Pick the same two numbers. It backs up the whole sessions folder to your Desktop, verifies the backup, copies the records, and prints a summary with the exact undo command.

**Step 7. Check.**
Open Claude Desktop, sign into the new account, open the Code tab. Your sessions are in the sidebar. Click one to make sure it resumes.

**If it did not work.**
Quit the app and run the dry run again. If a new folder with 0 records appeared that was not there before, the account you signed into was not the one you copied to. Just run -Apply again with that folder as the destination. Extra copies in the wrong folder are harmless, and undo can remove them if you care.

## The problem this fixes

Claude Desktop's Code tab lists your sessions in a sidebar. That list only shows sessions for the account that is signed in. The moment you switch to a different account (new email, new organization, moving from a personal plan to a team plan, or the other way), the sidebar in the new account is empty.

The sessions are not gone. Every one of them is still on your disk. The app just does not know the new account should see them.

This script fixes that by copying the session records into the new account's folder. Nothing is downloaded, nothing is sent anywhere, and nothing is deleted.

## What you see

```text
transfer-claude-sessions   mode: DRY RUN (nothing will change)
Claude Desktop is not running. Good.

Session folders under C:\Users\you\AppData\Roaming\Claude\claude-code-sessions
  [1]    0 records   last modified no records         33c1eb2b-...\8b566fdf-...   <- signed in most recently; created in the last 24h, probably the NEW account
  [2]   34 records   last modified 2026-10-01 21:28   86005cb2-...\2bd90bbf-...
  [3]   22 records   last modified 2026-08-27 04:29   af94b77e-...\65b3675f-...

Tip: the destination is normally the folder of the account you just signed into, which is usually the one with 0 records.

Enter the number of the SOURCE folder: 2
Enter the number of the DESTINATION folder: 1

Source:      86005cb2-...\2bd90bbf-...   (34 records)
Destination: 33c1eb2b-...\8b566fdf-...   (0 records)

Plan: 34 to copy, 0 to replace (source newer), 0 to skip, 0 invalid
  COPY     local_12a1df3c-....json   (not in destination)
  COPY     local_1b44b4ad-....json   (not in destination)
  ...

DRY RUN: nothing was copied. If the plan looks right, run again with -Apply.
```

After `-Apply` you get a summary (copied, replaced, skipped, failed), the path of the backup, a log file with one line per file, and the exact undo command.

## How it works

Claude Desktop keeps one small JSON record per session at

```text
%APPDATA%\Claude\claude-code-sessions\<accountId>\<orgId>\local_<id>.json
```

The record holds the title, working folder, model, last activity time, and a pointer to the real transcript. The transcript lives in

```text
%USERPROFILE%\.claude\projects\...
```

and is shared by every account on the machine. The record does not contain the account or org ID anywhere inside it. So copying the record into the new account's folder is enough for the sidebar to list the session, and the session can be resumed because the transcript is already there.

That is the whole trick. The script adds the guard rails.

## Safety

| Rule | How |
|---|---|
| Never runs while Claude is open | Checks for the Claude process and refuses, with instructions to quit from the tray. |
| Never changes anything by accident | Dry run is the default. You must pass `-Apply`. |
| Always has a way back | Backs up the whole sessions folder to your Desktop before copying and verifies the file count. |
| Never moves or deletes | Copy only. Even undo keeps the folder it replaces instead of deleting it. |
| Never clobbers newer data | Replaces a destination file only when the source copy is newer. Every skip is logged with the reason. |
| Never touches transcripts | Only the record files are copied. `.claude\projects` is left alone. |
| Stops if the layout looks wrong | Checks that folders are `<guid>\<guid>` and each record parses as JSON with a `sessionId`. |

The folders also contain `deleted_<id>` markers and `scheduled-tasks.json`. Those are per account and are deliberately not copied.

## Undo

Every `-Apply` run leaves a folder on your Desktop named `claude-code-sessions-backup-<timestamp>` and prints the exact undo command at the end. Quit Claude Desktop fully, then:

```powershell
# Show the backups it can find and what it would do
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Undo

# Restore
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Undo -Apply
```

Undo moves the current sessions folder aside to `claude-code-sessions-before-undo-<timestamp>` and copies the backup into place. Nothing is deleted. Remove the "before-undo" folder yourself once you are happy.

## Options

```text
-Apply              Do it for real. Without this, dry run.
-DryRun             Spell out a dry run. Already the default.
-Source <n|text>    Source folder by list number or accountId\orgId text. Skips the prompt.
-Destination <...>  Same, for the destination.
-Undo               Restore from a backup. Add -Apply to actually restore.
-BackupFolder <p>   With -Undo, the exact backup folder to restore.
-BackupPath <p>     Where backups and logs go. Default: your Desktop.
-SessionsRoot <p>   Use a different sessions folder. For testing on a copy.
-SkipProcessCheck   Skip the "is Claude running" check. Only honored together with a
                    custom -SessionsRoot, so it cannot be used on the real folder.
```

Example without prompts:

```powershell
powershell -ExecutionPolicy Bypass -File .\transfer-claude-sessions.ps1 -Source 1 -Destination 2 -Apply
```

If your Desktop syncs to OneDrive, the backup and log sync too. The records include session titles and short summaries. Pass `-BackupPath C:\Users\you\claude-backups` to keep them local.

## FAQ

**Will I lose anything?**
No. The script only adds files to the destination folder. The source folder, the transcripts, and everything else stay exactly as they were. A verified backup is made first, and undo restores it.

**Does it work in both directions?**
Yes. Pick whichever folder is the source and whichever is the destination. You can also run it twice to merge two accounts into each other.

**Can I merge sessions from two accounts into one?**
Yes. Run it with the old account as source and the new one as destination. Existing records in the destination are kept unless the source copy is newer.

**Why does it refuse to run?**
Claude Desktop is still open. Closing the window is not enough. Right click the Claude icon in the system tray (bottom right, maybe under the ^ arrow) and choose Quit. The app rewrites these files while running, so copying under it would be unsafe. The Claude Code CLI in a terminal is fine and is ignored, since only the Desktop app touches these files.

**It says only one account folder exists.**
The new account has never opened the Code tab on this machine, so its folder does not exist yet. Sign into it, open the Code tab once, quit, run again.

**Does this work on macOS or Linux?**
Not yet. The Windows app stores sessions under `%APPDATA%\Claude`. If you know where the Mac app keeps them, open an issue and I will add it.

**Does it work for cloud or remote sessions?**
It handles the records named `local_*.json`, which is what the Code tab creates for sessions on your machine.

**Windows blocked the script.**
Right click the `.ps1` file, Properties, tick Unblock, OK. Or run `Unblock-File .\transfer-claude-sessions.ps1`.

**A resumed session warns about missing tools or connectors.**
The record remembers which connectors and MCP servers were enabled when the session was created. If the new account does not have the same ones, the session still opens, it just cannot use those tools.

**Does it send anything anywhere?**
No. It is a single PowerShell file with no dependencies and no network access. Read it before you run it.

## Troubleshooting

| Message | Fix |
|---|---|
| Claude Desktop is still running | Quit from the tray icon. Check Task Manager for any process named Claude. |
| Only one account folder exists | Sign into the new account, open the Code tab once, quit, run again. |
| Sessions folder not found | The Code tab has never been used on this computer, or your version stores data elsewhere. Open an issue with your version. |
| did not match exactly one folder | Use the number from the list, or paste the full accountId\orgId text. |
| Window flashes and closes | Run it from an open PowerShell window, not by double clicking. |
| Copied, but the sidebar is still empty | Make sure you are signed into the destination account and picked that account's folder. The "signed in most recently" tag updates after you sign in and quit once more. |

## Limits

- Relies on how Claude Desktop stores data today. It is undocumented and may change. If the layout does not match, the script stops without touching anything.
- Windows only for now.
- Verified on 2026-10-01 with Claude Desktop 2.16 on Windows 11: 34 sessions copied to a freshly created account, all visible in the new sidebar and resumable.

## Contributing

Issues and pull requests are welcome. The most useful things right now:

- Confirm it works on your version of Claude Desktop (open an issue with the version and the result, even if it just worked).
- Where the macOS app stores these records, so a Mac version can be added.
- Edge cases in the folder layout you have seen.

Keep it a single `.ps1` with no dependencies and keep dry run as the default.

## License

MIT. See [LICENSE](LICENSE).
