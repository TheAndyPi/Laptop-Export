# PR #3 Merge Conflict Report

Repository: `TheAndyPi/Laptop-Export`

Pull request: https://github.com/TheAndyPi/Laptop-Export/pull/3/conflicts

## Correct merge direction

PR #3 merges the feature branch into the repository's base branch:

- Base: `main` / `A1A2-Prototype`
- Base commit: `c123ee7b2854aa4abf276478ada951bfb5d18e4e`
- Head: `PrototypeSuperUnstable`
- Head commit: `aac42c54eff983839603455b9b2beca9c22bbaf`
- Common ancestor: `3c188460c67de8d5605b6b777300430e4a1fdaba`

The remote `main` and `A1A2-Prototype` refs currently point to the same commit.

## Conflict result

A read-only three-way merge simulation of `main` with `PrototypeSuperUnstable` found 12 conflicts:

1. `Export-LaptopData.ps1` — changed in both
2. `README.md` — changed in both
3. `devlogs/DEVELOPMENT_LOG_2026-07-28.md` — added in both
4. `src/00-development-config.psd1` — changed in both
5. `src/01-bootstrap.ps1` — changed in both
6. `src/03-core.ps1` — changed in both
7. `src/04-destination.ps1` — changed in both
8. `src/05-user-data.ps1` — changed in both
9. `src/06-settings-printers.ps1` — changed in both
10. `src/07-browsers-onedrive.ps1` — changed in both
11. `src/08-import-template.ps1` — changed in both
12. `src/10-main.ps1` — changed in both

There are no deleted-by-us or deleted-by-them conflicts in the simulated merge.

## Important correction

The initial local comparison used the current branch as `ours` and `A1A2-Prototype` as `theirs`. Because `A1A2-Prototype` was an ancestor of the current branch, that comparison produced no conflicts. It did not reproduce PR #3's merge direction.

The correct comparison is:

```powershell
$base = git merge-base origin/main origin/PrototypeSuperUnstable
git merge-tree $base origin/main origin/PrototypeSuperUnstable
```

This command performs a read-only merge analysis and does not modify the working tree. The attempted `git merge-tree --write-tree` was not used because this workspace does not permit writing temporary objects to `.git/objects`.

## Repository state at inspection

- Working tree: clean
- Remote refs were checked with `git ls-remote`
- No merge, checkout, reset, or conflict-resolution operation was performed
