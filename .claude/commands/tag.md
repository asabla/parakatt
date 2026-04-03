# Tag: Create and push a version tag

Bump the version tag and push it to origin.

## Arguments
- `$ARGUMENTS` — optional explicit version (e.g., `v1.0.0`). If omitted, auto-determine from latest tag.

## Steps

1. **Ensure on main**: verify current branch is main and up-to-date with origin
2. **Determine version**:
   - If `$ARGUMENTS` is provided, use that as the tag
   - Otherwise, get latest tag from `git tag --sort=-v:refname | head -1` and suggest a patch bump
3. **Confirm with user** before creating the tag
4. **Create and push**: `git tag <version> && git push origin <version>`
