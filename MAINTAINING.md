# Maintaining

Smoke checks before tagging a release or merging a PR that touches the script.

## Pre-commit / pre-release checklist

```bash
# 1. Bash syntax
bash -n scripts/yammer-scan-template.sh

# 2. shellcheck (install once: brew install shellcheck)
shellcheck scripts/yammer-scan-template.sh
shellcheck --severity=info scripts/yammer-scan-template.sh

# 3. Placeholder guard fires for an unconfigured copy
cp scripts/yammer-scan-template.sh /tmp/yscan-test.sh
chmod +x /tmp/yscan-test.sh
/tmp/yscan-test.sh 2>&1 | tail -n 5
# Expected: "configuration incomplete — replace REPLACE_WITH_YOUR_* values..."
# Exit code: 2

# 4. --help renders the header block
scripts/yammer-scan-template.sh --help | head -n 30

# 5. Release bundle contents
tar -czf /tmp/yammer-effect.skill --exclude='.git' --exclude='.DS_Store' --exclude='.claude' --exclude='yammer-effect.skill' .
tar -tzf /tmp/yammer-effect.skill | sort
# Expected: SKILL.md, README.md, LICENCE, references/*, scripts/*. No .git, no .DS_Store, no .claude.
```

## Things to verify by hand before a release tag

- [ ] Working tree clean (`git status`)
- [ ] All five smoke checks above pass
- [ ] Commit author is the GitHub no-reply email (`git log --format=fuller -1`) — no `*.local` hostname leak
- [ ] No personal repo names, employer names, or path-leaking strings in tracked files (`git grep -iE 'jondavies|jMac|insuredhq|taiken'`)
- [ ] Version-related text (README status callout, release notes) matches the tag being cut

## Known invariants

- **Dry-run never writes.** `ensure_stack_options`, `upsert_record`, and any future write path must short-circuit on `DRY_RUN=1` before issuing PATCH/POST. The dry-run-bypass bug fixed in v0.1.1 is the canonical example of how this can go wrong.
- **Scope guard runs before any write.** `verify_workspace_scope` must fire as the first action in both `main_full_scan` and `main_single`.
- **Manual fields are read-only to the scanner.** Priority, Project type, Owner/Context, Notes, and a manual `Status=Archived` are preserved on upsert. If you add a new auto-derived field, do not put it in this set.
