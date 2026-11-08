#!/bin/bash
# Runs as dev inside the test server.
set -eu
pass() { echo "OK    $1"; }
fail() { echo "FAIL  $1"; exit 1; }
wait_ready() { # version
  for _ in $(seq 60); do
    [ "$(orca-ide status --json 2>/dev/null | jq -r '.result.runtime.appVersion + " " + .result.runtime.state')" = "$1 ready" ] && return 0
    sleep 2
  done
  fail "Orca $1 did not start"
}

wait_ready 1.4.241; pass "Orca 1.4.241 runs through orca-serve"
mkdir -p ~/proj && cd ~/proj
git init -q 2>/dev/null
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
orca-ide repo add --path ~/proj --json >/dev/null 2>&1 || true
T=$(orca-ide terminal create --worktree path:/home/dev/proj --command bash --json | jq -r .result.terminal.handle)
orca-ide terminal send --terminal "$T" --text 'echo SHELL=$$; sleep 3000 &' --enter --json >/dev/null
sleep 3
shell=$(orca-ide terminal read --terminal "$T" --json | jq -r '.result.terminal.tail[]' | sed -n 's/^SHELL=\([0-9]*\)$/\1/p' | tail -n 1)
[ -n "$shell" ] || fail "the terminal did not answer"
pass "terminal running, shell $shell"

orca-update | tail -n 1
new=$(readlink ~/.local/share/orca-server/current)
wait_ready "$new"; pass "updated to $new"
orca-ide terminal send --terminal "$T" --text 'echo AFTER=$$' --enter --json >/dev/null
sleep 2
after=$(orca-ide terminal read --terminal "$T" --json | jq -r '.result.terminal.tail[]' | sed -n 's/^AFTER=\([0-9]*\)$/\1/p' | tail -n 1)
[ "$after" = "$shell" ] || fail "the terminal did not survive the update: '$after' vs '$shell'"
pgrep -x sleep >/dev/null || fail "the terminal process did not survive"
pass "the terminal survived the update"
set -- ~/.local/share/orca-server/[0-9]*
[ "$#" = 2 ] || fail "number of versions: $#"
pass "the old version stays for a rollback"

if orca-update 0.0.1 2>/dev/null; then fail "a nonexistent version was accepted"; fi
[ "$(readlink ~/.local/share/orca-server/current)" = "$new" ] || fail "the version changed after a failure"
pass "a nonexistent version changed nothing"

image=$(/opt/node/bin/node --version)
bash -ic 'exit' 2>/dev/null || true
mkdir -p ~/n26 && cd ~/n26 && echo "${image%%.*}" > .nvmrc
[ "$(bash -ic 'cd ~/n26 && node --version' 2>/dev/null | tail -n 1)" = "$image" ] || fail ".nvmrc with the image version"
pass ".nvmrc with the image version downloads nothing"
mkdir -p ~/n24 && cd ~/n24 && echo 24 > .nvmrc
case "$(bash -ic 'cd ~/n24 && node --version' 2>/dev/null | tail -n 1)" in v24.*) pass "PODS_NODE_VERSIONS: Node 24 in the home directory" ;; *) fail "Node 24" ;; esac

cred() { printf 'protocol=https\nhost=%s\npath=%s\n\n' "$1" "$2" | git-credential-pods get; }
[ "$(cred github.com example-user/x.git | sed -n 's/^password=//p')" = token-user ] || fail "user token"
[ "$(cred github.com Example-Org/app.git | sed -n 's/^password=//p')" = token-org ] || fail "org token"
[ -z "$(cred github.com someone-else/x.git)" ] || fail "another owner got a token"
[ -z "$(cred example.com example-user/x.git)" ] || fail "another host got a token"
[ -z "$(cred github.com ../etc/x)" ] || fail "path escape"
pass "git picks the token by owner"
[ "$(git config --system credential.useHttpPath)" = true ] || fail "useHttpPath"
[ "$(git config commit.gpgsign)" = false ] || fail "gpgsign"
[ "$(git config --get url.https://github.com/.insteadOf | head -n 1)" != "" ] || fail "insteadOf"
pass "gitconfig"
cd ~/proj
git remote remove origin 2>/dev/null || true
git remote add origin git@github.com:example-org/app.git
printf '#!/bin/sh\necho "$GH_TOKEN"\n' >/tmp/fake-gh
chmod +x /tmp/fake-gh
sed 's#/usr/bin/gh#/tmp/fake-gh#' "$(command -v gh)" >/tmp/gh-test
[ "$(bash /tmp/gh-test pr list)" = token-org ] || fail "gh by origin"
[ "$(bash /tmp/gh-test pr list --repo example-user/x)" = token-user ] || fail "gh by --repo"
[ "$(bash /tmp/gh-test pr list -R example-user/x)" = token-user ] || fail "gh by -R"
[ "$(bash /tmp/gh-test pr list -R someone-else/x)" = token-default ] || fail "gh unknown owner"
[ "$(bash /tmp/gh-test repo view example-user/x)" = token-user ] || fail "gh repo view owner/name"
[ "$(bash /tmp/gh-test repo clone https://github.com/Example-User/x.git)" = token-user ] || fail "gh repo clone URL"
cd /tmp
[ "$(bash /tmp/gh-test pr list)" = token-default ] || fail "gh default"
pass "gh picks the token"
