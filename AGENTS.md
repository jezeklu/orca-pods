# Agent Instructions

Guidance for AI coding agents working on this repository. Human contributors follow [CONTRIBUTING.md](CONTRIBUTING.md), and everything there applies here too.

## Language

Everything in the repository is in English: code, comments, script output, documentation, commit messages, pull requests and issues.

## Layout

- `op-client.sh`, `op-server.sh`: the role scripts. `build.sh` inlines `lib/common.sh` at `# @include` and writes standalone files to `dist/`. Never edit `dist/`.
- `lib/common.sh`: shared code. The caller sets `ROLE` before loading it.
- `Dockerfile`: one file, the `server` stage for the server image, the last stage for the client image.
- `image/bin/`: helpers installed into both images (`orca-release`).
- `server/bin/`: helpers installed into the server image (`orca-serve`, `orca-update`, `gh`, `git-credential-pods`, …).
- `dev.sh`: runs the client with a locally built image from `.local/` and paths from `client.env`.
- `test.sh`, `tests/`: all tests, see below.
- `sign-release.sh`: signs `dist/op-server` on the host for releases.

## Code style

- POSIX `sh` unless a script really needs bash. Every script must pass `shellcheck`.
- `set -eu`, quote every expansion, no new dependencies outside the distribution packages.
- Keep scripts short and readable. A comment says why, not what.
- User-facing messages are short English sentences. Test output uses the existing prefixes `OK    `, `FAIL  `, `SKIP  `, `WARNING:` and `RESULT:`.
- Keep the README in sync with behavior changes. It is the only user documentation.

## Security invariants

These are the point of the project. Do not weaken them, and flag any change that touches them:

- The container never gets the Docker or Podman socket, `~/.ssh`, the GPG agent or any host credentials.
- The firewall lives in the rootless network namespace, outside the container's reach. Neither role starts without it. The container must not reach the LAN, the VPN or host services.
- The server container gets only a read-only secrets folder and `~/.gitconfig` from the host. The host never executes what the container wrote. Host updates come only from a signed release.
- No secrets, tokens, pairing codes, real hostnames, private paths or personal data in the repository, in tests or in examples. Use generic placeholders such as `example-user`, `example-org` or `server`.
- Never print token or pairing-code values in logs or test output.

## Tests

Run what fits the change before you finish:

```sh
./test.sh unit         # always: unit tests and shellcheck, fast
./test.sh              # unit tests, four distributions, client isolation on this machine
./test.sh server       # server role changes: image, isolation and end-to-end tests
./test.sh vm [distro]  # firewall, network option or mount changes
```

Tests download images and Orca releases. Run only code you have reviewed, and never point tests at production hosts.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) as described in [CONTRIBUTING.md](CONTRIBUTING.md), for example `fix(server): retry the restart right after start`. Do not commit, push, tag or publish releases unless the maintainer asks.

Never commit to `main`. Each change gets its own branch from the current `main` before the first commit, named after its type, for example `feat/help` or `fix/server-unit`. It reaches `main` only through a pull request, after the tests pass and the maintainer approves the merge. If you find yourself on `main` with uncommitted changes, move them to a new branch first.
