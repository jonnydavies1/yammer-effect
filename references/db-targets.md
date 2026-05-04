# Database Targets

Notion is the default and the only target implemented in v1. Airtable and SQLite are designed but not yet built — the schema below is target-agnostic, so adding them is a thin write-adapter rather than a redesign.

## Notion (default)

**Auth**: OAuth via Claude's built-in Notion MCP, or workspace-scoped integration token stored in macOS Keychain (`security add-generic-password -s yammer-scan -a $USER -w`).

**Why default**: most users tracking parallel projects already have Notion. Rich filtering, multiple views, collaborative if needed.

**Caveats**:
- OAuth is workspace-scoped. Confirm the right workspace before creating the database. Wrong workspace = rework.
- Internal integrations need to be added to the parent page via Notion's Connections UI - the MCP/integration can't add itself.
- Rate limits ~3 req/sec. Fine for under 30 projects; add 350ms sleep between rows beyond that.

## Airtable (designed, not yet implemented)

**Status**: not built in v1. The notes below describe the intended approach.

**Auth**: API key per base, stored in keychain (same pattern as Notion).

**When this would be the right target**: user already lives in Airtable for project tracking, or wants formula fields the script doesn't compute (e.g. complex priority scoring).

**Open questions for the build**:
- Schema would need to be created in Airtable UI first; the script writes rows but doesn't create tables. (Or use Airtable Meta API but adds complexity.)
- Different upsert semantics: match by Path field, use `PATCH` with `performUpsert.fieldsToMergeOn`.

## Local SQLite (designed, not yet implemented)

**Status**: not built in v1. The notes below describe the intended approach.

**Auth**: none. File at `~/.local/share/yammer/inventory.db`.

**When this would be the right target**: privacy-conscious user, no cloud account, lightweight viewer (datasette, sqlite-web) acceptable.

**Open questions for the build**:
- No views; user queries directly or via a viewer
- Loses the "phone access" benefit of Notion
- Best paired with a static HTML report generator if user wants quick visual review

## Linear

**Not recommended**. Linear's data model is issue-tracking-focused; force-fitting projects-as-issues creates friction. If user insists, suggest a separate Linear team for "Personal Inventory" rather than mixing with real work.

## What's not supported

- Google Sheets: API auth is painful, schema management is fragile, rate limits are aggressive. Skip.
- Trello: deprecated as a serious tool by most teams; not worth the integration cost.
- Plaintext files: tempting but loses queryability. SQLite is the better lightweight option.

## Switching targets later

The scan script's data model is target-agnostic. Switching from Notion to SQLite later is a matter of swapping the write functions, not redesigning the schema. Build the scan logic first; the target is a thin layer at the end.
