# Contributing

Everything in the repository is in English: code, comments, script output, documentation and commit messages.

## Branches

Nothing is committed to `main` directly. Each feature or fix gets its own branch from `main`, named `<type>/<short-name>`, for example `feat/help`, and reaches `main` through a pull request once the tests pass. A pull request is merged as a fast-forward, so the signed commits stay as they are.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <summary>

Optional body: why the change is needed, not what it does.
```

- **type:** `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`.
- **scope** (optional): `client`, `server`, `image`, `tests`, `ci`.
- **summary:** imperative mood, lowercase, no period, at most 72 characters.
- **body:** wrapped at 72 characters.
- A breaking change gets `!` after the type or scope and a `BREAKING CHANGE:` footer.

Examples:

```
fix(server): retry the restart right after start
feat(client): reject a missing Wayland socket early
docs: describe token setup for organizations
```

## Tests

Run `./test.sh` before opening a pull request. Changes to the firewall, network options or mounts also need `./test.sh vm`, server changes need `./test.sh server`. See the README for details.

Scripts are POSIX `sh` unless they need bash, and `shellcheck` runs as part of `./test.sh unit`.
