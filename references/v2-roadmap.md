# v2 Roadmap: Conversation Archaeology

v1 inventories the filesystem. v2 inventories the *conversation history* - the half of the Yammer Effect that filesystem scanning misses entirely.

## The problem v2 solves

Filesystem scanning surfaces stale folders. But the actual Yammer Effect signal lives in chats:

- "I should write the partnership pitch deck this week" - mentioned weeks ago, never appears again
- "Let me follow up with that contact about the introduction" - decided in one chat, no follow-through visible elsewhere
- "Need to migrate the billing docs to Confluence" - committed to in one session, scattered across three later ones

These are stated intents that didn't survive the next session's tangent. Filesystem scans can't see them. Notion can't see them either - they're trapped in chat history. And native chat search is generally poor: keyword-matching against thousands of long sessions surfaces noise, not signal.

## What v2 does

Periodically scan the user's chat history (Claude conversations and Projects) and surface:

1. **Unfulfilled commitments**: "I'll do X", "let me handle Y", "follow up on Z" patterns where the same thread has no resolution mention later
2. **Project intent without project artefact**: a project name appears in chat but doesn't exist in the filesystem inventory yet (potential lost project)
3. **Decisions made but not recorded**: "let's go with approach X" with no corresponding doc, commit, or DB entry
4. **Cross-session dropped threads**: a topic mentioned heavily for two weeks then silence

Output: same DB as v1, but a new property "Unfulfilled commitments" and a new view "Buried in chat".

## Hard problems to solve

### 1. Distinguishing intent from noise

Not every "I should..." is a commitment. Filter for:

- **Commitment language**: "I'll", "I will", "let me", "next I'll", "I'm going to", "by [date]"
- **Action verbs**: write, send, build, ship, finish, follow up, schedule, book
- **Specificity**: vague intents ("I should do better at X") count less than specific ones ("I'll send the contract by Friday")

Heuristic confidence scoring rather than binary classification. High-confidence commitments float to the top.

### 2. Resolution detection

A commitment + a later "done" message = resolved, not stalled. Look for:

- Same conversation/Project containing later resolution language ("sent it", "shipped", "done")
- Filesystem evidence: file created/modified in the relevant folder around the right date
- Cross-conversation evidence: another chat references the completed thing

If no resolution signal within N days (configurable, default 14), flag as unfulfilled.

### 3. Cross-session deduplication

Same task gets discussed across multiple chats. Need to collapse:

- Fuzzy matching on task description (embedding similarity, not string match)
- Group commitments referring to the same thing - even if phrased differently
- Promote the most recent mention as the canonical version

### 4. Project attribution

Was that commitment for Company A's work or Company B's advisory engagement? Signals:

- Explicit mentions in surrounding context (project names, people, code paths)
- Conversation Project membership (if user uses Claude Projects)
- User-defined keyword maps (configurable in skill - e.g. "<colleague name>" → Company A)

### 5. Decay and archive

A commitment from 3 months ago with no resolution might be:
- Long-since done off-platform (archive it)
- No longer relevant (archive it)
- Genuinely buried (surface it)

Auto-archive commitments older than 90 days unless they reappear. User can manually un-archive.

## Tooling needed

v2 depends on access to chat history that v1 doesn't need. In Claude.ai, this likely means:

- **`conversation_search` tool**: keyword search across past chats
- **`recent_chats` tool**: time-windowed retrieval
- **Memory access**: surface user-stated priorities and projects

These are available in Claude (the assistant) but not directly accessible from a bash script. So v2 architecture is different:

- v1: bash + jq + gh + ripgrep, runs via launchd
- v2: Claude (in Claude Code or Cowork) running this skill on a schedule, calling chat-history tools, writing to the same DB

This means v2 isn't pure scheduled-cron. It's a skill that the user invokes ("audit my chats for buried commitments"), or a Claude Code task triggered by a launchd-fired prompt file.

## Suggested v2 build order

1. **Manual mode first**: user runs the skill and gets a one-shot audit. No scheduling. Validate the heuristics on real chat history.
2. **Confidence tuning**: iterate on what counts as a real commitment vs noise, using the user's feedback on each surfaced item ("yes this is real" / "no, ignore this pattern")
3. **Filesystem cross-reference**: tie surfaced commitments to filesystem state (did the project they reference get touched recently? if so, lower urgency)
4. **DB integration**: write surfaced commitments into the same DB as v1, new view
5. **Scheduling**: only after the heuristics earn trust. Premature scheduling on bad heuristics produces noise that erodes trust in the whole system.

## What not to build in v2

**Avoid**:

- Auto-resolving commitments without user confirmation (false positives are worse than false negatives here)
- Surfacing every "I should..." (signal-to-noise will be terrible)
- Building this before v1 has been used for at least a month (you don't yet know what filesystem inventory misses in practice)

**Defer to v3 or later**:

- Email/calendar archaeology (commitments made in email, meeting decisions)
- Cross-tool reconciliation (Slack messages, Jira tickets, Confluence pages)
- Anything involving inferring meeting outcomes from transcripts

These compound the noise problem. Get v2 right first.

## Honest assessment

v2 is significantly harder than v1 and the heuristics are where the system lives or dies. v1 is mechanical: scan, classify, write. v2 is judgement: what counts as a real commitment, when does silence mean stalled vs. silence mean done off-platform, when does cross-session dedup work and when does it merge unrelated things.

This is the kind of feature that demos great on cherry-picked examples and fails on real data. Build v2 only after v1 has shipped and you have a month of data and feedback. Don't build v2 because the v1 success made you feel ambitious. Optimism bias check.
