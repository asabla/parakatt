# Ship: Push, PR, merge, and tag

Full release workflow for the current branch. Pushes the branch, creates a PR, waits for CI, rebase-merges, updates local main, and pushes a new tag.

## Prerequisites
- You must be on a feature/fix branch (not main)
- All changes must be committed

## Steps

1. **Push the branch** to origin with `-u` flag
2. **Create a PR** using `gh pr create` with a summary and test plan
3. **Wait for CI** using `gh pr checks <number> --watch`
   - If CI fails, inspect logs with `gh run view <id> --log-failed`, fix the issue, commit, push, and wait again
4. **Merge the PR** using `gh pr merge <number> --rebase --delete-branch`
5. **Update local main**: `git checkout main && git pull --rebase origin main`
6. **Determine next tag**: look at `git tag --sort=-v:refname | head -1` and bump appropriately (patch for fixes, minor for features)
7. **Ask the user** to confirm the tag version before creating it
8. **Create and push the tag**: `git tag <version> && git push origin <version>`

## Important
- Never force-push
- Never push directly to main — always go through a PR
- If CI fails, fix and push — don't skip checks
- Confirm the tag version with the user before pushing
