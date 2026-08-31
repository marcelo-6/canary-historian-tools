# Releasing

Releases are tag-driven and use `git-cliff` for the changelog/release-note body.

## Versioning

The repository follows semantic version tags:

```text
v0.1.0
v0.2.0
v1.0.0
```

`git-cliff --bumped-version` can infer the next version from Conventional Commit-style history.

## Prepare a release

Run all checks:

```text
just check
```

Generate the changelog:

```text
just changelog
```

Review `CHANGELOG.md`, commit the release preparation, then tag:

```text
git add CHANGELOG.md
git commit -m "chore(release): prepare release"
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

## GitHub release workflow

A `v*` tag triggers `.github/workflows/release.yml`.

The workflow:

1. Checks out the complete Git history.
2. Runs repository tests/lint.
3. Installs `git-cliff`.
4. Generates notes for the latest tag.
5. Packages the public scripts and top-level documentation into `canary-historian-tools-<tag>.zip`.
6. Generates a SHA-256 checksum.
7. Creates the GitHub Release with both assets.
