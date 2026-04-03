# Merge PR: Wait for CI, merge, pull, and tag

Merge an existing PR after CI passes, update local main, and optionally tag a release.

## Arguments
- `$ARGUMENTS` — PR number (required). Example: `/merge-pr 18`

## Steps

1. **Check CI status** using `gh pr checks $ARGUMENTS --watch`
   - If CI fails, inspect logs with `gh run view <id> --log-failed` and report to user
2. **Merge the PR** using `gh pr merge $ARGUMENTS --rebase --delete-branch`
3. **Update local main**: `git checkout main && git pull --rebase origin main`
4. **Ask about tagging**: ask the user if they want to create a new tag
   - If yes, determine next version from `git tag --sort=-v:refname | head -1`, confirm with user, then `git tag <version> && git push origin <version>`

## Important
- Never force-push
- If CI fails, report the failure — don't merge with failing checks
