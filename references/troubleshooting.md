# Troubleshooting

Common failure modes seen in real-world v1 deployments, and how to handle them.

## Notion workspace mismatch

**Symptom**: MCP search returns content from one workspace but the user expects another.

**Cause**: Notion MCP OAuth is workspace-scoped and binds to whichever workspace was selected during the auth flow.

**Fix**:
1. In Claude Code: `/mcp` -> find Notion -> disconnect/revoke
2. Reconnect - browser opens for OAuth
3. **At the top of the Notion permission page, switch the workspace dropdown** to the target workspace before clicking Allow
4. Verify with `/mcp` (still connected) and a search test

If the user has the same login email across workspaces, the dropdown is the only thing to watch. If different emails, log out of Notion in browser first so OAuth offers account selection.

## "Workspace cannot be reached" from MCP

**Symptom**: search and fetch via Notion MCP return only old workspace content even after re-OAuth.

**Cause**: usually OAuth completed but the user clicked through the workspace prompt without changing it, or accepted defaults.

**Fix**: revoke at notion.so -> Settings -> My Connections -> Claude -> Disconnect. Then re-OAuth from scratch. The "select workspace" prompt is more prominent on a fresh auth.

## Keychain entry empty after add

**Symptom**: `security find-generic-password` returns exit 0 but no value, script aborts saying token missing.

**Cause**: usually a paste error - either the secret didn't get included in the `-w` argument, or shell quoting ate it.

**Fix**:
```bash
security delete-generic-password -s yammer-scan -a "$USER" 2>/dev/null
security add-generic-password -s yammer-scan -a "$USER" -w 'PASTE_TOKEN_HERE'
```

Single quotes prevent shell interpretation of special characters. Verify with:
```bash
security find-generic-password -s yammer-scan -a "$USER" -w | wc -c
```
Should print > 40 (token length plus newline).

## Multi-line shell commands fail with "command not found: -w"

**Symptom**: pasting a multi-line `security add-generic-password \` command and getting `zsh: command not found: -w` etc.

**Cause**: `\` line continuations require nothing after them on the line - not even a space. Pasting from formatted documents often introduces trailing whitespace.

**Fix**: paste as one line, no continuations.

## Em-dashes replacing hyphens

**Symptom**: command fails with usage error, but visually looks correct.

**Cause**: clipboard or terminal autocorrect substituting `-` with `–` or `—`.

**Fix**: type the command manually or paste from a plain-text source. Especially common on macOS with autocorrect or smart-paste enabled.

## launchd plist loaded but no scans firing

**Symptom**: `launchctl print` shows the plist loaded with state=waiting, but the log file has no scan entries after the trigger time.

**Possible causes**:

1. **Mac was asleep at trigger time and stayed asleep through all triggers**
   - Fix: ensure the plist has multiple `StartCalendarInterval` entries to catch wake events

2. **PATH in plist doesn't include Homebrew tools**
   - Symptom in logs: "command not found: rg" or "jq"
   - Fix: explicit `PATH` env in plist including `/opt/homebrew/bin` and `/usr/local/bin`

3. **Script needs interactive auth that launchd can't provide**
   - Symptom: silent failure, or "could not authenticate" in log
   - Fix: pre-auth via keychain (script uses `security find-generic-password` non-interactively)

**Smoke test**: `launchctl kickstart -k gui/$UID/<service-name>` triggers an immediate run. If that works, the plist is fine and the issue is timing/sleep.

## Scope guard fires unexpectedly

**Symptom**: scan aborts with "scope guard: title mismatch" or "parent mismatch".

**Causes**:
- DB renamed in Notion UI without updating `NOTION_EXPECTED_DB_TITLE` in the script
- Parent page moved
- Wrong DB ID configured

**Fix**: update the script constants. The hard-stop is intentional - it's preventing writes to the wrong target.

## Debounce stuck

**Symptom**: `inv` runs but says "debounced, last scan Xs ago" and skips, even when you want a fresh scan.

**Fix**:
```bash
rm ~/Library/Caches/yammer-scan.last
inv
```

Or use `inv --dry-run` (bypasses debounce) or `inv --repo <path>` (also bypasses).

## Notion API rate limiting

**Symptom**: random 429 errors mid-scan.

**Cause**: Notion limits ~3 req/sec; with 30+ projects and 2 calls per project, peaks can exceed.

**Fix**: add 350ms sleep between row writes. Cheap insurance.

## set -u nounset traps

**Symptom**: `something[@]: unbound variable` errors in stderr during scan.

**Cause**: bash `set -u` (strict mode) blows up on empty arrays referenced as `${arr[@]}`.

**Fix**: gate with `[ ${#arr[@]} -gt 0 ] || return 0` before referencing the array.

## OAuth token revoked silently

**Symptom**: scan worked yesterday, today gets 401 from Notion.

**Cause**: token revoked at notion.so/profile/integrations, or workspace permissions changed.

**Fix**: re-add token to keychain. If using OAuth via Claude MCP, re-OAuth via `/mcp`.
