#!/bin/bash
# Set up a machine to use the Lustre bugs vault: the SSH tunnel, the
# bugs-vault CLI and the agent skill.  Linux (WSL included) and macOS.
# onboard/README.md is the one-page guide, onboard/AGENT-SETUP.md the
# step by step for a coding agent.
#
#   install.sh --show-key [--key PATH]    print the public key to send to Patrick
#   install.sh --user NAME [--key PATH]   install, or repair, everything
#   install.sh                            rerun with the saved user and key
#   install.sh --check                    check what is installed, change nothing
#   install.sh --uninstall                remove everything this script installed
#
# Options: --endpoint ID (the vault's pigeons endpoint id: needed once by
# the public copy of this script, which leaves it out; saved after that),
# --lan (on Patrick's LAN: no pigeon; --pigeon goes back),
# --no-service (no tunnel service; `bugs-vault-tunnel start` runs it),
# --no-skill.
#
# What it touches: ~/.local/share/bugs-vault (CLI venv, pigeons, skill,
# pinned host key), ~/.local/bin/bugs-vault and bugs-vault-tunnel,
# ~/.config/bugs-vault/config, one marked block at the top of
# ~/.ssh/config, the tunnel service (systemd user unit or launchd agent)
# and bugs-vault links in ~/.claude/skills and ~/.codex/skills.  It never
# creates or changes SSH keys and never needs root.
#
# Exit status: 0 ready; 2 bad usage or a missing prerequisite; 3 the
# vault does not accept the key yet (send it to Patrick); 4 the tunnel or
# the vault is not answering; 5 the tunnel works but the CLI login fails.
set -euo pipefail

# Fixed facts about the vault (deploy/PRODUCTION.md, Reaching it).  The
# endpoint id is not public: deploy/publish-setup-kit.sh blanks this line.
PIGEON_ID=	# given with --endpoint: it is not public
HOST_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBmDdwNJAnTGu34mp2sHYsGaRSxQZtp5lnTfCmJtsPs"
LAN_ADDR=192.168.50.114
PORT=8470	# fixed: passkeys are bound to http://localhost:8470
URL=http://localhost:$PORT
PIGEONS_VERSION=v0.2.1
PIGEONS_URL=https://github.com/n0-computer/pigeons/releases/download/$PIGEONS_VERSION
pigeons_sha256() {
	case $1 in
	linux-x86_64) echo d439697159e89f3080c849cc98230852379cacf73d16c32643193dabcd8a2c8a ;;
	linux-aarch64) echo 3b27e1e737e3397cf4715f490b07f91779303859fef049400c7a79d12baf7a9c ;;
	darwin-aarch64) echo e4fcbc8a446391635b67ae8fc7d610bdf25426b38215bf8cb65bda7104e0c523 ;;
	darwin-x86_64) echo a0682f5a8501f480d220f71e3ef3fffeff48efac80a175f4fbbb632f398d3674 ;;
	esac
}

SHARE=$HOME/.local/share/bugs-vault
BIN=$HOME/.local/bin
CONF_DIR=$HOME/.config/bugs-vault
CONF=$CONF_DIR/config
SSH_CONFIG=$HOME/.ssh/config
UNIT=$HOME/.config/systemd/user/bugs-vault-tunnel.service
LABEL=org.lustre.bugs-vault-tunnel
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
BEGIN='# >>> bugs-vault (managed by bugs-vault install.sh; edits are replaced) >>>'
END='# <<< bugs-vault <<<'

say() { printf '%s\n' "bugs-vault install: $*" >&2; }
die() { local rc=$1; shift; say "ERROR: $*"; exit "$rc"; }

MODE=install USER_NAME='' KEY='' LAN='' SERVICE=true SKILL=true ENDPOINT=''
while (($#)); do
	case $1 in
	--user) USER_NAME=${2:-}; shift 2 ;;
	--key) KEY=${2:-}; shift 2 ;;
	--endpoint) ENDPOINT=${2:-}; shift 2 ;;
	--lan) LAN=true; shift ;;
	--pigeon) LAN=false; shift ;;
	--no-service) SERVICE=false; shift ;;
	--no-skill) SKILL=false; shift ;;
	--show-key) MODE=show-key; shift ;;
	--check) MODE=check; shift ;;
	--uninstall) MODE=uninstall; shift ;;
	-h|--help) sed -n '2,28p' "$0"; exit 0 ;;
	*) die 2 "unknown argument: $1 (see --help)" ;;
	esac
done

OS=$(uname -s)
case $OS in
Linux) PLAT=linux ;;
Darwin) PLAT=darwin ;;
*) die 2 "unsupported system $OS (Linux, WSL and macOS only)" ;;
esac
case $(uname -m) in
x86_64|amd64) ARCH=x86_64 ;;
arm64|aarch64) ARCH=aarch64 ;;
*) die 2 "unsupported CPU $(uname -m)" ;;
esac

sha256_of() {
	if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Write a file from stdin if its content changes (status 1 if not).  An
# existing file is rewritten in place, so a symlinked ~/.ssh/config stays one.
put_file() {	# PATH MODE
	local tmp
	tmp=$(mktemp "${TMPDIR:-/tmp}/bugs-vault.XXXXXX")
	cat >"$tmp"
	if [[ -f $1 ]] && cmp -s "$tmp" "$1"; then
		rm -f "$tmp"
		return 1
	fi
	if [[ -f $1 ]]; then
		cat "$tmp" >"$1"
		rm -f "$tmp"
	else
		mv -f "$tmp" "$1"
	fi
	chmod "$2" "$1"
	return 0
}

conf_get() {	# KEY: from the saved config
	[[ -r $CONF ]] || return 0
	sed -n "s/^$1=//p" "$CONF" | tail -1 | sed "s/^[\"']//; s/[\"']\$//"
}

# The key: --key, else the saved one, else the first default key.
pick_key() {
	local k
	[[ $KEY ]] || KEY=$(conf_get BUGS_VAULT_KEY)
	KEY=${KEY%.pub}
	if [[ -z $KEY ]]; then
		for k in id_ed25519 id_ecdsa id_ed25519_sk id_ecdsa_sk id_rsa; do
			if [[ -f $HOME/.ssh/$k.pub ]]; then
				KEY=$HOME/.ssh/$k
				break
			fi
		done
	fi
	case $KEY in "~/"*) KEY=$HOME/${KEY#"~/"} ;; esac
	[[ $KEY ]] && [[ -f $KEY.pub ]] ||
		die 2 "no SSH key found${KEY:+ at $KEY}.  Give --key PATH, or make one with:" \
			"ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519  (a passphrase is fine with ssh-agent)"
	[[ -f $KEY ]] || die 2 "$KEY.pub exists but the private key $KEY does not"
	ssh-keygen -l -f "$KEY.pub" >/dev/null 2>&1 || die 2 "$KEY.pub is not an SSH public key"
}

key_has_passphrase() { ! ssh-keygen -y -P '' -f "$KEY" >/dev/null 2>&1; }
key_in_agent() {
	local fp
	fp=$(ssh-keygen -l -f "$KEY.pub" | awk '{print $2}')
	[[ ${SSH_AUTH_SOCK:-} ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"
}

# ---------------------------------------------------------------- show-key
if [[ $MODE == show-key ]]; then
	pick_key
	say "send this public key (one line) to Patrick, with the user name you want:"
	cat "$KEY.pub"
	exit 0
fi

# ---------------------------------------------------------------- service helpers
have_systemd_user() {
	[[ $PLAT == linux ]] && command -v systemctl >/dev/null &&
		systemctl --user show-environment >/dev/null 2>&1
}

write_tunnel_helper() {
	put_file "$BIN/bugs-vault-tunnel" 755 <<'EOF' || true
#!/bin/bash
# The SSH tunnel to the bugs vault (localhost:8470).  Installed by the
# bugs-vault install.sh: start, stop, restart, status, log.
set -uo pipefail
SHARE=$HOME/.local/share/bugs-vault
UNIT=bugs-vault-tunnel.service
LABEL=org.lustre.bugs-vault-tunnel
PIDF=$SHARE/tunnel.pid
LOG=$SHARE/tunnel.log
mode=loop
if [[ $(uname -s) == Darwin ]] && [[ -f $HOME/Library/LaunchAgents/$LABEL.plist ]]; then
	mode=launchd
elif [[ -f $HOME/.config/systemd/user/$UNIT ]] &&
	systemctl --user show-environment >/dev/null 2>&1; then
	mode=systemd
fi
up() { curl -fsS -m 5 http://localhost:8470/healthz >/dev/null 2>&1; }
loop_pid() { [[ -s $PIDF ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null && cat "$PIDF"; }
case ${1:-status} in
start)
	case $mode in
	systemd) systemctl --user start "$UNIT" ;;
	launchd)
		launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" \
			2>/dev/null || launchctl kickstart "gui/$(id -u)/$LABEL" ;;
	loop)
		loop_pid >/dev/null && exit 0
		nohup bash -c 'trap "kill \$c 2>/dev/null; exit 0" TERM
			while :; do ssh -N -o BatchMode=yes bugs-vault & c=$!; wait $c
				sleep 10 & c=$!; wait $c; done' >>"$LOG" 2>&1 &
		echo $! >"$PIDF" ;;
	esac ;;
stop)
	case $mode in
	systemd) systemctl --user stop "$UNIT" ;;
	launchd) launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null ;;
	loop)
		p=$(loop_pid) && kill "$p"
		rm -f "$PIDF" ;;
	esac ;;
restart) "$0" stop; sleep 1; "$0" start ;;
status)
	echo "service: $mode"
	if up; then echo "vault: answering on http://localhost:8470"; exit 0; fi
	echo "vault: not answering on http://localhost:8470"; exit 1 ;;
log)
	case $mode in
	systemd) journalctl --user -u "$UNIT" -n "${2:-30}" --no-pager ;;
	launchd) tail -n "${2:-30}" "$HOME/Library/Logs/bugs-vault-tunnel.log" 2>/dev/null ;;
	*) tail -n "${2:-30}" "$LOG" 2>/dev/null ;;
	esac ;;
*) echo "usage: bugs-vault-tunnel start|stop|restart|status|log [N]" >&2; exit 2 ;;
esac
EOF
}

# ---------------------------------------------------------------- uninstall
remove_ssh_block() {
	[[ -f $SSH_CONFIG ]] && grep -qF "$BEGIN" "$SSH_CONFIG" || return 0
	awk -v b="$BEGIN" -v e="$END" '$0 == b {skip = 1; next}
		skip && $0 == e {skip = 0; next} !skip' "$SSH_CONFIG" |
		put_file "$SSH_CONFIG" 600 || true
}

unlink_ours() {	# PATH: remove it if it is a link into $SHARE
	local t
	[[ -L $1 ]] || return 0
	t=$(readlink "$1")
	case $t in "$SHARE"/*) rm -f "$1" ;; esac
}

if [[ $MODE == uninstall ]]; then
	if [[ -f $UNIT ]]; then
		systemctl --user disable --now bugs-vault-tunnel.service 2>/dev/null || true
		rm -f "$UNIT"
		systemctl --user daemon-reload 2>/dev/null || true
	fi
	if [[ -f $PLIST ]]; then
		launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
		rm -f "$PLIST"
	fi
	[[ -x $BIN/bugs-vault-tunnel ]] && "$BIN/bugs-vault-tunnel" stop >/dev/null 2>&1 || true
	rm -f "$BIN/bugs-vault-tunnel"
	unlink_ours "$BIN/bugs-vault"
	unlink_ours "$HOME/.claude/skills/bugs-vault"
	unlink_ours "$HOME/.codex/skills/bugs-vault"
	remove_ssh_block
	if [[ -x $SHARE/venv/bin/bugs-vault ]]; then
		"$SHARE/venv/bin/bugs-vault" logout >/dev/null 2>&1 || true
	fi
	rm -rf "$SHARE" "$CONF_DIR" "$HOME/.cache/bugs-vault"
	say "removed.  Your SSH key is untouched; ask Patrick to remove your account if you are leaving."
	exit 0
fi

# ---------------------------------------------------------------- prerequisites
for c in ssh ssh-keygen curl tar awk; do
	command -v "$c" >/dev/null || die 2 "$c is missing; install it first"
done

find_python() {
	local p
	for p in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
		command -v "$p" >/dev/null || continue
		if "$p" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
			command -v "$p"
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------- check
check() {
	local rc=0
	echo "user: $(conf_get BUGS_VAULT_USER)  key: $(conf_get BUGS_VAULT_KEY)"
	[[ -x $SHARE/venv/bin/bugs-vault ]] && echo "cli: $SHARE/venv/bin/bugs-vault" ||
		{ echo "cli: missing"; rc=1; }
	command -v bugs-vault >/dev/null && echo "on PATH: $(command -v bugs-vault)" ||
		{ echo "on PATH: no (add $BIN to PATH)"; rc=1; }
	grep -qF "$BEGIN" "$SSH_CONFIG" 2>/dev/null && echo "ssh config: Host bugs-vault" ||
		{ echo "ssh config: missing"; rc=1; }
	"$BIN/bugs-vault-tunnel" status 2>/dev/null || rc=1
	for d in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
		[[ -e $d/bugs-vault/SKILL.md ]] && echo "skill: $d/bugs-vault"
	done
	if [[ -x $SHARE/venv/bin/bugs-vault ]]; then
		"$SHARE/venv/bin/bugs-vault" whoami || rc=1
		echo
	fi
	return $rc
}
if [[ $MODE == check ]]; then
	check
	exit $?
fi

# ---------------------------------------------------------------- install
[[ $USER_NAME ]] || USER_NAME=$(conf_get BUGS_VAULT_USER)
[[ $USER_NAME ]] || die 2 "give --user NAME (the vault user name Patrick gave you)"
[[ $USER_NAME =~ ^[a-z][a-z0-9._-]*$ ]] || die 2 "bad user name: $USER_NAME"
pick_key
PY=$(find_python) || die 2 "Python 3.10 or newer is needed (macOS: brew install python;" \
	"Debian/Ubuntu: sudo apt install python3 python3-venv)"
say "user $USER_NAME, key $KEY, python $PY"

mkdir -p "$SHARE/bin" "$BIN" "$CONF_DIR" "$HOME/.ssh"
chmod 700 "$HOME/.ssh" "$SHARE"
if [[ -z $LAN ]]; then
	[[ $(cat "$SHARE/route" 2>/dev/null) == lan ]] && LAN=true || LAN=false
fi
$LAN && echo lan >"$SHARE/route" || echo pigeon >"$SHARE/route"

# 1. pigeons, the off-LAN transport (a pinned release, checked).  The
#    endpoint id: --endpoint, else the saved one, else the built-in one.
if ! $LAN; then
	[[ $ENDPOINT ]] || ENDPOINT=$(cat "$SHARE/endpoint" 2>/dev/null || true)
	[[ $ENDPOINT ]] || ENDPOINT=$PIGEON_ID
	[[ $ENDPOINT =~ ^[0-9a-f]{64}$ ]] ||
		die 2 "give --endpoint ID (the vault endpoint id in the setup note Patrick sent)"
	PIGEON_ID=$ENDPOINT
	echo "$PIGEON_ID" >"$SHARE/endpoint"
	if [[ $("$SHARE/bin/pigeons" version 2>/dev/null) != "pigeons $PIGEONS_VERSION" ]]; then
		want=$(pigeons_sha256 "$PLAT-$ARCH")
		[[ $want ]] || die 2 "no pigeons build for $PLAT-$ARCH"
		tmp=$(mktemp -d)
		say "fetching pigeons $PIGEONS_VERSION ($PLAT-$ARCH)"
		curl -fsSL -o "$tmp/p.tgz" "$PIGEONS_URL/pigeons-$PIGEONS_VERSION-$PLAT-$ARCH.tar.gz" ||
			die 4 "could not download pigeons from github.com"
		[[ $(sha256_of "$tmp/p.tgz") == "$want" ]] || die 4 "pigeons download: sha256 mismatch"
		tar -xzf "$tmp/p.tgz" -C "$tmp" ./pigeons
		install -m 755 "$tmp/pigeons" "$SHARE/bin/pigeons"
		rm -rf "$tmp"
	fi
fi

# 2. ssh: the pinned host key and a Host block at the top of ~/.ssh/config.
echo "bugs-vault $HOST_KEY" | put_file "$SHARE/known_hosts" 644 || true
# macOS: a key with a passphrase loads from the Keychain without a prompt.
keychain=
[[ $PLAT == darwin ]] && keychain="
    IgnoreUnknown UseKeychain
    UseKeychain yes
    AddKeysToAgent yes"
if $LAN; then
	route="    HostName $LAN_ADDR"
else
	route="    HostName bugs-vault
    ProxyCommand \"$SHARE/bin/pigeons\" fly --stdio $PIGEON_ID"
fi
block="$BEGIN
# The Lustre bugs vault tunnel: \`ssh -N bugs-vault\` (bugs-vault-tunnel).
Host bugs-vault
$route
    User vault
    HostKeyAlias bugs-vault
    UserKnownHostsFile \"$SHARE/known_hosts\"
    StrictHostKeyChecking yes
    UpdateHostKeys no
    IdentityFile \"$KEY\"
    IdentitiesOnly yes
    LocalForward $PORT 127.0.0.1:$PORT
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ControlMaster no
    ControlPath none
    ForwardAgent no
    ForwardX11 no
    RequestTTY no$keychain
Match all
$END"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
if [[ -s $SSH_CONFIG && ! -e $SSH_CONFIG.bugs-vault.bak ]] && ! grep -qF "$BEGIN" "$SSH_CONFIG"; then
	cp -p "$SSH_CONFIG" "$SSH_CONFIG.bugs-vault.bak"
	say "saved your ssh config as $SSH_CONFIG.bugs-vault.bak"
fi
{
	printf '%s\n' "$block"
	awk -v b="$BEGIN" -v e="$END" '$0 == b {skip = 1; next}
		skip && $0 == e {skip = 0; next} !skip' "$SSH_CONFIG"
} | put_file "$SSH_CONFIG" 600 && say "wrote the bugs-vault block in $SSH_CONFIG"
ssh -G bugs-vault >/dev/null || die 2 "ssh rejects $SSH_CONFIG; fix it and rerun"

# 3. The CLI configuration.  A key with a passphrase signs through
#    ssh-agent, which the CLI reaches through the public key.
keyspec=$KEY
if key_has_passphrase; then
	keyspec=$KEY.pub
	key_in_agent || die 2 "$KEY has a passphrase and is not in ssh-agent; the tunnel" \
		"and the CLI sign through the agent.  Run: ssh-add $KEY  (then rerun this)"
fi
put_file "$CONF" 600 <<EOF && say "wrote $CONF" || true
# Written by the bugs-vault install.sh.  Agents also set BUGS_VAULT_AS_BOT=1.
BUGS_VAULT_URL=$URL
BUGS_VAULT_USER=$USER_NAME
BUGS_VAULT_KEY=$keyspec
EOF

# 4. Does the vault accept this key yet?  vault@ runs nologin for any
#    command: status 1 with that message means the key was accepted.
probe=$(ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ConnectTimeout=60 \
	bugs-vault true 2>&1) && rc=0 || rc=$?
if ((rc == 255)); then
	case $probe in
	*"Permission denied"*)
		say "the vault does not accept $KEY.pub yet.  Send it to Patrick (install.sh --show-key)"
		say "and rerun this script once he confirms your account."
		exit 3 ;;
	*"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION"*)
		die 4 "the vault's host key does not match the pinned one: stop and tell Patrick" ;;
	*) die 4 "ssh to the vault failed: $probe" ;;
	esac
fi

# 5. The tunnel: a service that keeps it up, and the helper.
write_tunnel_helper
agent_env=
if key_has_passphrase && [[ ${SSH_AUTH_SOCK:-} ]]; then
	agent_env="Environment=SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
fi
if $SERVICE && have_systemd_user; then
	mkdir -p "$(dirname "$UNIT")"
	put_file "$UNIT" 644 <<EOF && changed=true || changed=false
# The SSH tunnel to the Lustre bugs vault (installed by the bugs-vault install.sh).
[Unit]
Description=bugs vault SSH tunnel (localhost:$PORT)
After=network-online.target

[Service]
ExecStart=$(command -v ssh) -N -o BatchMode=yes bugs-vault
Restart=always
RestartSec=10
$agent_env

[Install]
WantedBy=default.target
EOF
	systemctl --user daemon-reload
	systemctl --user enable --quiet bugs-vault-tunnel.service
	if $changed; then
		systemctl --user restart bugs-vault-tunnel.service
	else
		systemctl --user start bugs-vault-tunnel.service
	fi
	say "tunnel: systemd user unit bugs-vault-tunnel.service"
elif $SERVICE && [[ $PLAT == darwin ]]; then
	mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
	put_file "$PLIST" 644 <<EOF && changed=true || changed=false
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/ssh</string><string>-N</string>
		<string>-o</string><string>BatchMode=yes</string><string>bugs-vault</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/bugs-vault-tunnel.log</string>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/bugs-vault-tunnel.log</string>
</dict>
</plist>
EOF
	if $changed; then
		launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	fi
	launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 ||
		launchctl bootstrap "gui/$(id -u)" "$PLIST"
	say "tunnel: launchd agent $LABEL"
else
	$SERVICE && say "no systemd user manager here (WSL without systemd?): the tunnel runs" \
		"while this session does; start it again with: bugs-vault-tunnel start"
	"$BIN/bugs-vault-tunnel" start
fi
for ((i = 0; i < 60; i++)); do
	curl -fsS -m 5 "$URL/healthz" >/dev/null 2>&1 && break
	sleep 1
done
curl -fsS -m 5 "$URL/healthz" >/dev/null 2>&1 ||
	die 4 "the vault is not answering on $URL (bugs-vault-tunnel log; is port $PORT taken?)"

# 6. The CLI and the skill, from the vault itself, checked against its manifest.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsS -m 30 -o "$tmp/manifest.json" "$URL/dist/manifest.json" ||
	die 4 "could not fetch $URL/dist/manifest.json"
mf() { "$PY" -c 'import json, sys; m = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
	"$tmp/manifest.json" "$1"; }
fetch() {	# NAME: into $tmp, checked
	curl -fsS -m 120 -o "$tmp/$1" "$URL/dist/$1" || die 4 "could not fetch $URL/dist/$1"
	[[ $(sha256_of "$tmp/$1") == $(mf "m['files']['$1']['sha256']") ]] ||
		die 4 "$1: sha256 does not match the manifest"
}

# A newer installer from the vault replaces this one and runs instead.
fetch install.sh
install -m 755 "$tmp/install.sh" "$SHARE/install.sh.new"
if ! cmp -s "$tmp/install.sh" "$0" && [[ -z ${BUGS_VAULT_INSTALL_REEXEC:-} ]]; then
	mv -f "$SHARE/install.sh.new" "$SHARE/install.sh"
	say "running the newer installer from the vault"
	args=(--user "$USER_NAME" --key "$KEY")
	$LAN && args+=(--lan)
	$SERVICE || args+=(--no-service)
	$SKILL || args+=(--no-skill)
	BUGS_VAULT_INSTALL_REEXEC=1 exec bash "$SHARE/install.sh" "${args[@]}"
fi
mv -f "$SHARE/install.sh.new" "$SHARE/install.sh"
for f in AGENT-SETUP.md README.md; do
	fetch "$f"
	install -m 644 "$tmp/$f" "$SHARE/$f"
done

wheel=$(mf "m['wheel']")
have=$(cat "$SHARE/cli-wheel" 2>/dev/null || true)
if [[ $have != "$wheel" ]] || [[ ! -x $SHARE/venv/bin/bugs-vault ]]; then
	fetch "$wheel"
	if [[ ! -x $SHARE/venv/bin/python ]]; then
		"$PY" -m venv "$SHARE/venv" 2>"$tmp/venv.err" || {
			rm -rf "$SHARE/venv"
			die 2 "python -m venv failed (Debian/Ubuntu: sudo apt install python3-venv): " \
				"$(tail -1 "$tmp/venv.err")"
		}
	fi
	say "installing the CLI ($wheel)"
	"$SHARE/venv/bin/python" -m pip install -q --disable-pip-version-check --upgrade \
		--force-reinstall "$tmp/$wheel" >"$tmp/pip.log" 2>&1 ||
		{ tail -20 "$tmp/pip.log" >&2; die 2 "pip install failed (it needs PyPI for click and requests)"; }
	echo "$wheel" >"$SHARE/cli-wheel"
fi
ln -sfn "$SHARE/venv/bin/bugs-vault" "$BIN/bugs-vault"

if $SKILL; then
	skill=$(mf "m['skill']")
	fetch "$skill"
	rm -rf "$SHARE/skill"
	mkdir -p "$SHARE/skill"
	tar -xzf "$tmp/$skill" -C "$SHARE/skill"
	linked=
	for tool in claude codex; do
		d=$HOME/.$tool/skills
		[[ -d $HOME/.$tool ]] || command -v "$tool" >/dev/null || continue
		mkdir -p "$d"
		if [[ -e $d/bugs-vault || -L $d/bugs-vault ]] && ! [[ -L $d/bugs-vault &&
			$(readlink "$d/bugs-vault") == "$SHARE/skill/bugs-vault" ]]; then
			say "left $d/bugs-vault alone: it is not ours"
			continue
		fi
		ln -sfn "$SHARE/skill/bugs-vault" "$d/bugs-vault"
		linked="$linked $d/bugs-vault"
	done
	[[ $linked ]] && say "skill:$linked" ||
		say "skill: $SHARE/skill/bugs-vault (no ~/.claude or ~/.codex here to link it into)"
fi

# 7. Check the login.
case ":$PATH:" in
*":$BIN:"*) ;;
*) say "NOTE: $BIN is not on PATH; add it (export PATH=\"\$HOME/.local/bin:\$PATH\")" ;;
esac
if ! out=$("$SHARE/venv/bin/bugs-vault" whoami 2>&1); then
	say "the tunnel works but the CLI login failed: $out"
	key_has_passphrase && say "is the key in ssh-agent?  ssh-add $KEY"
	exit 5
fi
say "logged in: $out"
cat >&2 <<EOF

Ready.  The vault: $URL (in a browser on this machine) and \`bugs-vault\`.
Last step, for the person (not an agent): get a passkey for the web UI.
  1. run: bugs-vault passkey-enroll
  2. open the "url" it prints, within 10 minutes, in the browser that should
     hold the passkey, and follow the prompts.
Agents act as your bot alias: export BUGS_VAULT_AS_BOT=1 (the skill says so).
EOF
exit 0
