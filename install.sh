#!/usr/bin/env bash
# nginx-stream: TCP/UDP relay on nginx "stream" for Debian 12+ / Ubuntu 22.04+. One self-contained file.
# Run:  bash <(wget -qO- --inet4-only https://raw.githubusercontent.com/drno88/nginx-stream/main/install.sh)
# Help: bash install.sh --help
# The last line must stay "main": under `curl | bash` the whole script is parsed before stdin goes back to /dev/tty.
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
	echo "bash >= 4 is required / нужен bash >= 4" >&2
	exit 1
fi

# ---------------------------------------------------------------- constants

readonly INSTALLER_VER="1.0.0"
readonly T=$'\t'
readonly NGX_DIR=/etc/nginx
readonly NGX_MAIN=$NGX_DIR/nginx.conf
readonly NGX_MAIN_BACKUP=$NGX_DIR/nginx.conf.before-nginx-stream
readonly NGX_STREAM_CONF=$NGX_DIR/nginx-stream.conf
readonly NGX_INCLUDE_LINE="include /etc/nginx/nginx-stream.conf;"
readonly INCLUDE_MARK="# added by nginx-stream installer"
readonly STATE_DIR=/etc/nginx-stream
readonly SETTINGS_FILE=$STATE_DIR/settings.env
readonly FIREWALL_FILE=$STATE_DIR/firewall.nft
readonly FIREWALL_UNIT=/etc/systemd/system/nginx-stream-firewall.service
readonly PORTS_SCRIPT=$STATE_DIR/ports.sh
readonly PORTS_UNIT=/etc/systemd/system/nginx-stream-ports.service
readonly NGX_FRESH_MARK=$STATE_DIR/nginx-installed-by-us
readonly NFT_DROPIN=/etc/systemd/system/nftables.service.d/nginx-stream.conf
readonly IPT_MARK_RE='--comment nginx-stream( |$)'
readonly NFT_MARK_RE='comment "nginx-stream"'
readonly NFTABLES_CONF=/etc/nftables.conf
readonly NGX_OVERRIDE=/etc/systemd/system/nginx.service.d/nginx-stream.conf
readonly SYSCTL_FILE=/etc/sysctl.d/90-nginx-stream.conf
readonly MODLOAD_FILE=/etc/modules-load.d/nginx-stream.conf
readonly SELF_PATH=/usr/local/sbin/nginx-stream
readonly SELF_URL=https://raw.githubusercontent.com/drno88/nginx-stream/main/install.sh
readonly NFT_TABLE="inet nginx_stream"

# Questions: saved to settings.env, reused as defaults on reconfigure.
SETTING_KEYS=(UI_LANG TARGET PORTS
	LISTEN PROXY_PROTOCOL LOGS TCP_TIMEOUT UDP_TIMEOUT TUNE SSH_PROTECT SCAN_PROTECT AUTO_UPDATES
	NGINX_MODE NGINX_FRESH DEFAULT_SITE_REMOVED UFW_RULES INSTALLER_VERSION)

UI_LANG="" TARGET="" PORTS=""
LISTEN="" PROXY_PROTOCOL="" LOGS="" TCP_TIMEOUT="" UDP_TIMEOUT="" TUNE="" SSH_PROTECT="" SCAN_PROTECT=""
AUTO_UPDATES="" NGINX_MODE="" NGINX_FRESH="" DEFAULT_SITE_REMOVED="" UFW_RULES="" INSTALLER_VERSION=""

ACTION="" YES=0 DRY_RUN=0 OUT_DIR="./out" RAM_MB=""
declare -A D=()
RULES=()                 # "proto listen_ip listen host target_port src sni"; * = all, - = none, IPv6 in brackets
declare -A GDEF=() GNAMED=() # GNAMED=1: TCP group with names; GDEF: index of its default rule
SELF_KEPT=0
STAGE=""
BAKS=() NEWS=()
APPLIED=0                # from the first file written until verified: errors roll back
RESTART_TRIED=0 DEFAULT_LINK="" DEFAULT_UNLINKED=0 FW_TOUCHED=0 PORTS_TOUCHED=0 PORT_TOKENS=""
NGINX_WAS=0 NGINX_WHY="" # NGINX_WAS: nginx.conf existed before; NGINX_WHY: why NGINX_MODE was chosen
OPEN_TCP=""              # TCP ports < 10000 listening at install time: kept out of the RST drop
OPEN_HIGH=""             # TCP ports >= 10000 listening at install time: kept out of the ephemeral range
R_PROTO="" R_LIP="" R_LP="" R_HOST="" R_TP="" R_SRC="" R_SNI=""
SSH_PORT="22" BBR=n HAVE_IPV6=n SERVER_IP4="" SERVER_IP6="" PREV_INSTALLED=0 DOMAIN_WARNED=0

# ---------------------------------------------------------------- output

# C_* stdout, E_* stderr, RL_* for read -p (readline needs \001..\002 around codes)
C_BOLD="" C_CYAN="" C_GRN="" C_RED="" C_DIM="" C_OFF=""
E_RED="" E_YEL="" E_OFF=""
RL_BOLD="" RL_DIM="" RL_CYAN="" RL_OFF=""

# no colour with NO_COLOR, TERM=dumb or a non-tty; stdout and stderr are checked separately
init_colors() {
	if [[ -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then return 0; fi
	if [[ -t 1 ]]; then
		C_BOLD=$'\033[1m' C_CYAN=$'\033[36m' C_GRN=$'\033[32m' C_RED=$'\033[31m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
	fi
	if [[ -t 2 ]]; then
		E_RED=$'\033[31m' E_YEL=$'\033[33m' E_OFF=$'\033[0m'
		RL_BOLD=$'\001\033[1m\002' RL_DIM=$'\001\033[2m\002' RL_CYAN=$'\001\033[36m\002' RL_OFF=$'\001\033[0m\002'
	fi
}

# msg RU EN -> the string for the current language
msg() {
	if [[ $UI_LANG == en ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

say() { printf '%s\n' "$(msg "$1" "$2")"; }
ok() { printf '%s%s%s\n' "$C_GRN" "$(msg "$1" "$2")" "$C_OFF"; }
dim() { printf '%s%s%s\n' "$C_DIM" "$(msg "$1" "$2")" "$C_OFF"; }
hdr() { printf '%s%s%s\n' "$C_BOLD" "$(msg "$1" "$2")" "$C_OFF"; }   # block title
step() { printf '%s› %s%s\n' "$C_CYAN" "$(msg "$1" "$2")" "$C_OFF"; }  # stage of the work
li() { printf '  • %s\n' "$(msg "$1" "$2")"; }
opt() { printf '  %s%s)%s %s\n' "$C_CYAN" "$1" "$C_OFF" "$2"; } # opt N LABEL: a numbered choice
# row "ru label" "en label" VALUE: labels are pre-padded, printf widths count bytes
row() { printf '  %s%s%s %s\n' "$C_DIM" "$(msg "$1" "$2")" "$C_OFF" "$3"; }
yn_word() { if [[ $1 == y ]]; then msg "да" "yes"; else msg "нет" "no"; fi; }
banner() {
	printf '\n%snginx-stream%s %sv%s · TCP/UDP relay on nginx%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$INSTALLER_VER" "$C_OFF"
}
bad() { printf '%s%s%s\n' "$E_RED" "$(msg "$1" "$2")" "$E_OFF" >&2; } # failed check, not fatal
stc() {
	case $1 in
	up | active) printf '%s%s%s' "$C_GRN" "$1" "$C_OFF" ;;
	DOWN | inactive | failed | unknown) printf '%s%s%s' "$C_RED" "$1" "$C_OFF" ;;
	*) printf '%s' "$1" ;;
	esac
}
warn() { printf '%s! %s%s\n' "$E_YEL" "$(msg "$1" "$2")" "$E_OFF" >&2; }
die() {
	printf '%sx %s%s\n' "$E_RED" "$(msg "$1" "$2")" "$E_OFF" >&2
	exit 1
}
emit() { printf '%s\n' "$*"; }

on_err() {
	local rc=$1 line=$2 cmd=$3 os="unknown"
	# shellcheck disable=SC1091  # /etc/os-release exists only on the target system
	os=$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}") || printf unknown)
	printf '%sx %s%s\n' "$E_RED" "$(msg "Ошибка (код $rc) в строке $line: $cmd" "Error (code $rc) at line $line: $cmd")" "$E_OFF" >&2
	printf '  OS: %s, kernel: %s, installer: %s\n' "$os" "$(uname -r 2>/dev/null || echo ?)" "$INSTALLER_VER" >&2
	# main shell only, not inside $(...)
	if ((APPLIED)) && [[ $BASHPID == "$$" ]]; then
		rollback_apply >&2 || true
	fi
}

POLICY_RC=/usr/sbin/policy-rc.d
POLICY_SET=0

# only if this installer created it
drop_policy_rc() {
	if ((POLICY_SET)); then
		rm -f "$POLICY_RC"
		POLICY_SET=0
	fi
}

cleanup() {
	drop_policy_rc
	if [[ -n $STAGE && -d $STAGE ]]; then
		rm -rf "$STAGE"
	fi
}

# signals: roll back if files are already changed
on_signal() {
	if ((APPLIED)) && [[ $BASHPID == "$$" ]]; then
		APPLIED=0
		# HUP: no terminal to print to; output errors must not stop the rollback
		if [[ $1 == HUP ]]; then rollback_apply >/dev/null 2>&1 || true; else rollback_apply >&2 || true; fi
	fi
	exit 130
}

trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# ---------------------------------------------------------------- help

usage_ru() {
	cat <<'EOF'
nginx-stream: прокладка (relay) на nginx stream. Установщик для Debian 12+ / Ubuntu 22.04+.

Использование: bash install.sh [флаги]

Действия:
  --status              состояние службы, портов и соединений
  --uninstall           удалить прокладку и вернуть прежние настройки
  --dry-run             только собрать конфиги в --out DIR (по умолчанию ./out); без root, систему не трогает
  --help                эта справка
  Без действия: установка; если уже установлено - меню.

Общие:
  --yes                 не задавать вопросы, недостающее брать по умолчанию
  --lang ru|en          язык (по умолчанию ru)

Что ставим (всё это спрашивается, если не задано флагом):
  --target АДРЕС        сервер назначения по умолчанию: IPv4, IPv6 или домен
                        (обязателен, если есть правило без своего хоста)
  --ports ПРАВИЛА       правила через запятую: proto:[адрес:]порт[/имя][>[хост:]порт_цели][@src] (tcp:443)
                        proto: tcp, udp или both; хост: IPv4, [IPv6] в скобках или домен;
                        адрес - свой адрес сервера для слушания (IPv4 или [IPv6]), по умолчанию все.
                        Значение - в кавычках, иначе ">" - перенаправление в shell:
                        --ports 'tcp:443,udp:8443>443,tcp:2222>203.0.113.20:22'
                        --ports 'udp:51820>[2001:db8::20]:51820'
                        --ports 'udp:192.0.2.20:443>[2001:db8::20]:443,udp:192.0.2.21:443>[2001:db8::21]:443'
                        @адрес в конце правила - с какого адреса сервера ходить к серверу назначения
                        (IPv4 или [IPv6], того же семейства, что адрес назначения):
                        --ports 'udp:443>[2001:db8::21]:443@[2001:db8::5]'
                        /имя - только TCP: цель по имени из TLS (SNI), точное или *.зона;
                        правило порта без имени - цель по умолчанию:
                        --ports 'tcp:443/a.example.com>203.0.113.5:443,tcp:443>203.0.113.9:443'
  --listen v4|v4v6      слушать IPv4 или IPv4 и IPv6 (v4v6, если на сервере есть IPv6)
  --proxy-protocol y|n  PROXY protocol к серверу назначения, только TCP (n)
  --logs off|error      журнал nginx (off)
  --tcp-timeout ВРЕМЯ   простой TCP до закрытия, формат nginx (10m)
  --udp-timeout ВРЕМЯ   простой UDP-сессии (10m)
  --tune y|n            параметры ядра (y)
  --ssh-protect y|n     ограничить частые новые подключения к SSH (y)
  --scan-protect y|n    не отвечать на ping и закрытые порты (n)
  --auto-updates y|n    автообновления безопасности (y)

Для --dry-run:
  --out DIR             куда писать файлы (./out)
  --ram-mb N            объём памяти для расчёта параметров ядра (1024)
EOF
}

usage_en() {
	cat <<'EOF'
nginx-stream: a relay on nginx stream. Installer for Debian 12+ / Ubuntu 22.04+.

Usage: bash install.sh [flags]

Actions:
  --status              show service, ports and connections
  --uninstall           remove the relay and restore previous settings
  --dry-run             only build the configs into --out DIR (default ./out); no root, system untouched
  --help                this help
  No action: install; if already installed - a menu.

General:
  --yes                 no questions, missing values take defaults
  --lang ru|en          language (default ru)

What to install (asked interactively unless given as a flag):
  --target ADDRESS      default destination server: IPv4, IPv6 or domain
                        (required if any rule has no host of its own)
  --ports RULES         comma separated rules: proto:[address:]port[/name][>[host:]target_port][@src] (tcp:443)
                        proto: tcp, udp or both; host: IPv4, [IPv6] in brackets or a domain;
                        address - the server's own address to listen on (IPv4 or [IPv6]), default all.
                        Quote the value, otherwise ">" is a shell redirect:
                        --ports 'tcp:443,udp:8443>443,tcp:2222>203.0.113.20:22'
                        --ports 'udp:51820>[2001:db8::20]:51820'
                        --ports 'udp:192.0.2.20:443>[2001:db8::20]:443,udp:192.0.2.21:443>[2001:db8::21]:443'
                        @address at the end of a rule - the server address used to reach the destination
                        (IPv4 or [IPv6], same family as the destination address):
                        --ports 'udp:443>[2001:db8::21]:443@[2001:db8::5]'
                        /name - TCP only: destination by the TLS name (SNI), exact or *.zone;
                        the port's rule without a name is the default destination:
                        --ports 'tcp:443/a.example.com>203.0.113.5:443,tcp:443>203.0.113.9:443'
  --listen v4|v4v6      listen on IPv4 or IPv4 and IPv6 (v4v6 if the server has IPv6)
  --proxy-protocol y|n  PROXY protocol to the destination, TCP only (n)
  --logs off|error      nginx log (off)
  --tcp-timeout TIME    idle TCP timeout, nginx format (10m)
  --udp-timeout TIME    idle UDP session timeout (10m)
  --tune y|n            kernel parameters (y)
  --ssh-protect y|n     rate-limit new SSH connections (y)
  --scan-protect y|n    do not answer ping and closed ports (n)
  --auto-updates y|n    unattended security updates (y)

For --dry-run:
  --out DIR             where to write the files (./out)
  --ram-mb N            memory size used for the kernel parameters (1024)
EOF
}

print_help() {
	if [[ $UI_LANG == en ]]; then usage_en; else usage_ru; fi
}

# ---------------------------------------------------------------- argument parsing

parse_args() {
	local arg var
	while (($#)); do
		arg=$1
		shift
		if [[ $arg == --*=* ]]; then
			set -- "${arg#*=}" "$@"
			arg=${arg%%=*}
		fi
		case $arg in
		--help | -h) ACTION=help ;;
		--status) ACTION=status ;;
		--uninstall) ACTION=uninstall ;;
		--yes | -y) YES=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--lang | --target | \
			--ports | --listen | --proxy-protocol | --logs | --tcp-timeout | --udp-timeout | --tune | \
			--ssh-protect | --scan-protect | --auto-updates | --ram-mb | --out)
			(($#)) || die "Флагу $arg нужно значение" "Flag $arg needs a value"
			case $arg in
			--lang) var=UI_LANG ;;
			--out) var=OUT_DIR ;;
			*)
				var=${arg#--}
				var=${var^^}
				var=${var//-/_}
				;;
			esac
			printf -v "$var" '%s' "$1"
			shift
			;;
		*) die "Неизвестный флаг: $arg (см. --help)" "Unknown flag: $arg (see --help)" ;;
		esac
	done
}

# ---------------------------------------------------------------- defaults and previous answers

init_defaults() {
	D[UI_LANG]=ru
	D[TARGET]=""
	D[PORTS]="tcp:443"
	D[LISTEN]=v4
	D[PROXY_PROTOCOL]=n
	D[LOGS]=off
	D[TCP_TIMEOUT]=10m
	D[UDP_TIMEOUT]=10m
	D[TUNE]=y
	D[SSH_PROTECT]=y
	D[SCAN_PROTECT]=n
	D[AUTO_UPDATES]=y
	D[NGINX_MODE]=""
	D[UFW_RULES]=""
}

# Dry-run assumes a typical server.
detect_env_defaults() {
	if ((DRY_RUN)); then
		HAVE_IPV6=y
		D[LISTEN]=v4v6
		return 0
	fi
	if ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1; then
		HAVE_IPV6=y
		D[LISTEN]=v4v6
	fi
	SERVER_IP6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
	SERVER_IP4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
}

# Sourced in a subshell: flags given now must not be overwritten.
load_previous() {
	[[ -f $SETTINGS_FILE ]] || return 0
	PREV_INSTALLED=1
	local dump
	# shellcheck disable=SC1090  # file written by this installer
	dump=$(
		set +u
		source "$SETTINGS_FILE"
		for k in "${SETTING_KEYS[@]}"; do
			if [[ -v $k && -n ${!k} ]]; then printf 'D[%s]=%q\n' "$k" "${!k}"; fi
		done
	)
	eval "$dump"
}

load_settings_globals() {
	local keep=$UI_LANG
	[[ -f $SETTINGS_FILE ]] || die "nginx-stream не установлен (нет $SETTINGS_FILE)" "nginx-stream is not installed ($SETTINGS_FILE missing)"
	# shellcheck disable=SC1090  # file written by this installer
	source "$SETTINGS_FILE"
	if [[ -n $keep ]]; then UI_LANG=$keep; fi
}

# ---------------------------------------------------------------- validators (return 0/1, warn about the reason)

strip_brackets() {
	local h=$1
	h=${h#\[}
	h=${h%\]}
	printf '%s' "$h"
}

is_ipv4() {
	local o
	local -a oct
	[[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	IFS=. read -ra oct <<<"$1"
	for o in "${oct[@]}"; do
		((10#$o <= 255)) || return 1
	done
}

is_ipv6() {
	[[ $1 == *:*:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]
}

# IPv6 in brackets, as nginx wants
fmt_host() {
	local h
	h=$(strip_brackets "$1")
	if [[ $h == *:* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

host_safe() {
	local h
	h=$(strip_brackets "$1")
	h=${h,,}
	printf '%s' "${h//[^a-z0-9]/_}"
}

v_yn() { [[ $1 == y || $1 == n ]]; }

v_nonempty() { [[ -n $1 ]]; }

v_timeout() {
	[[ $1 =~ ^[0-9]+(ms|s|m|h|d)?$ ]] || {
		warn "Неверное время nginx: $1 (пример: 90s, 10m)" "Invalid nginx time: $1 (e.g. 90s, 10m)"
		return 1
	}
}

v_ram() {
	[[ $1 =~ ^[0-9]+$ ]] && (($1 >= 128))
}

is_domain() {
	[[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# the last label is alpha (TLD) or punycode: an IP is not a name
is_sni_domain() {
	[[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,}|xn--[a-z0-9-]*[a-z0-9])$ ]]
}

# v_sni_name NAME (lower-case): a.example.com or *.example.com, syntax only
v_sni_name() {
	local n=$1
	if ((${#n} > 253)); then
		:
	elif [[ $n == "*."* ]]; then
		if is_sni_domain "${n#\*.}"; then return 0; fi
	elif [[ $n != *"*"* && $n != .* ]]; then
		if is_sni_domain "$n"; then return 0; fi
	fi
	warn "Неверное имя «$n»: нужно точное имя (a.example.com) или *.example.com, до 253 символов; IP, .example.com, example.* и regex не поддерживаются" \
		"Invalid name \"$n\": expected an exact name (a.example.com) or *.example.com, up to 253 characters; IPs, .example.com, example.* and regex are not supported"
	return 1
}

v_target() {
	local h
	h=$(strip_brackets "$1")
	if is_ipv4 "$h" || is_ipv6 "$h"; then return 0; fi
	if is_domain "$h"; then
		check_domain "$h" || return 1
		return 0
	fi
	warn "Не похоже на IPv4, IPv6 или домен: $1" "Not an IPv4, IPv6 or domain name: $1"
	return 1
}

v_target_opt() {
	[[ -z $1 ]] || v_target "$1"
}

check_domain() {
	if command -v getent >/dev/null 2>&1; then
		if ! getent ahosts "$1" >/dev/null 2>&1; then
			if ((DRY_RUN)); then
				warn "Домен $1 не резолвится здесь (dry-run: принимаю как есть)" "Domain $1 does not resolve here (dry-run: accepted as is)"
			else
				warn "Домен $1 не резолвится" "Domain $1 does not resolve"
				return 1
			fi
		fi
	fi
	if ((!DOMAIN_WARNED)); then
		DOMAIN_WARNED=1
		warn "nginx резолвит домен только при старте; если у домена есть и A, и AAAA - в upstream попадут оба адреса." \
			"nginx resolves the domain only at start; if it has both A and AAAA records, both go into the upstream."
	fi
}

# One rule proto:[listen_ip:]listen[/name][>[host:]port][@src] -> R_PROTO R_LIP R_LP R_SNI R_HOST R_TP R_SRC
# (empty = all addresses / none / default target). Syntax only, no DNS: safe to call again from build_rules.
parse_rule() {
	local item=$1 body=$1 left tail="" host src="" re_rule='^(tcp|udp|both):([^>]+)(>(.*))?$'
	R_PROTO="" R_LIP="" R_LP="" R_HOST="" R_TP="" R_SRC="" R_SNI=""
	if [[ $item == *@* ]]; then
		src=${item##*@}
		body=${item%@*}
		if [[ $src =~ ^\[([^]]*)\]$ ]]; then
			host=${BASH_REMATCH[1]}
			if ! is_ipv6 "$host"; then
				warn "Неверный IPv6 после @: «$item»" "Invalid IPv6 after @: \"$item\""
				return 1
			fi
			R_SRC="[${host,,}]"
		elif is_ipv4 "$src"; then
			R_SRC=$src
		elif [[ $src == *:*:* ]]; then
			warn "IPv6 после @ пишется в квадратных скобках: @[2001:db8::5] («$item»)" \
				"An IPv6 after @ needs square brackets: @[2001:db8::5] (\"$item\")"
			return 1
		else
			warn "Неверный адрес после @: «$item» (нужен IPv4 или [IPv6])" "Invalid address after @: \"$item\" (expected an IPv4 or [IPv6])"
			return 1
		fi
	fi
	if [[ ! $body =~ $re_rule ]] || [[ -n ${BASH_REMATCH[3]} && -z ${BASH_REMATCH[4]} ]]; then
		warn "Неверное правило: «$item» (нужно proto:[адрес:]порт[/имя][>[хост:]порт_цели][@src], proto = tcp, udp или both)" \
			"Invalid rule: \"$item\" (expected proto:[address:]port[/name][>[host:]target_port][@src], proto = tcp, udp or both)"
		return 1
	fi
	R_PROTO=${BASH_REMATCH[1]} left=${BASH_REMATCH[2]} tail=${BASH_REMATCH[4]}
	if [[ $left == */* ]]; then
		R_SNI=${left#*/}
		left=${left%%/*}
		R_SNI=${R_SNI,,}
		if [[ $R_PROTO != tcp ]]; then
			warn "Неверное правило: «$item» (разбор по имени - только TCP с TLS; для UDP задайте отдельное правило udp:$left)" \
				"Invalid rule: \"$item\" (matching by name is TCP with TLS only; for UDP add a separate rule udp:$left)"
			return 1
		fi
		v_sni_name "$R_SNI" || return 1
	fi
	if [[ $left =~ ^[0-9]+$ ]]; then
		R_LP=$left
	elif [[ $left =~ ^\[([^]]*)\]:([0-9]+)$ ]]; then
		host=${BASH_REMATCH[1]}
		R_LP=${BASH_REMATCH[2]}
		if ! is_ipv6 "$host"; then
			warn "Неверный IPv6 адреса слушания: «$item»" "Invalid IPv6 listen address: \"$item\""
			return 1
		fi
		R_LIP="[${host,,}]"
	elif [[ $left =~ ^([^:]+):([0-9]+)$ ]]; then
		host=${BASH_REMATCH[1]}
		R_LP=${BASH_REMATCH[2]}
		if ! is_ipv4 "$host"; then
			warn "Адрес слушания не IPv4: «$item»" "The listen address is not an IPv4: \"$item\""
			return 1
		fi
		R_LIP=$host
	elif [[ $left == *:*:* ]]; then
		warn "IPv6 адрес слушания пишется в квадратных скобках: [2001:db8::1]:443 («$item»)" \
			"An IPv6 listen address needs square brackets: [2001:db8::1]:443 (\"$item\")"
		return 1
	else
		warn "Неверное правило: «$item» (слева от > ожидается порт, IPv4:порт или [IPv6]:порт)" \
			"Invalid rule: \"$item\" (left of > expected a port, IPv4:port or [IPv6]:port)"
		return 1
	fi
	R_TP=$R_LP
	if [[ -n $tail ]]; then
		if [[ $tail =~ ^[0-9]+$ ]]; then
			R_TP=$tail
		elif [[ $tail =~ ^\[([^]]*)\]:([0-9]+)$ ]]; then
			host=${BASH_REMATCH[1]}
			R_TP=${BASH_REMATCH[2]}
			if ! is_ipv6 "$host"; then
				warn "Неверный IPv6 в правиле: «$item»" "Invalid IPv6 in the rule: \"$item\""
				return 1
			fi
			R_HOST="[$host]"
		elif [[ $tail =~ ^([^:]+):([0-9]+)$ ]]; then
			host=${BASH_REMATCH[1]}
			R_TP=${BASH_REMATCH[2]}
			if ! is_ipv4 "$host" && ! is_domain "$host"; then
				warn "Хост в правиле не IPv4 и не домен: «$item»" "The host in the rule is neither IPv4 nor a domain: \"$item\""
				return 1
			fi
			R_HOST=$host
		elif [[ $tail == *:*:* ]]; then
			warn "IPv6 в правиле пишется в квадратных скобках: [2001:db8::20]:51820 («$item»)" \
				"IPv6 in a rule needs square brackets: [2001:db8::20]:51820 (\"$item\")"
			return 1
		else
			warn "Неверное правило: «$item» (после > ожидается порт или хост:порт)" \
				"Invalid rule: \"$item\" (after > expected a port or host:port)"
			return 1
		fi
	fi
	if ((10#$R_LP < 1 || 10#$R_LP > 65535 || 10#$R_TP < 1 || 10#$R_TP > 65535)); then
		warn "Порт вне диапазона 1-65535: $item" "Port out of range 1-65535: $item"
		return 1
	fi
	# 08080 is 8080, not octal: one port, one duplicate key
	R_LP=$((10#$R_LP)) R_TP=$((10#$R_TP))
}

# R_SRC must match the destination family; for a domain only a warning
check_src() {
	local dest sf df=""
	dest=$(strip_brackets "${R_HOST:-$TARGET}")
	if [[ $R_SRC == "["* ]]; then sf=6; else sf=4; fi
	if is_ipv4 "$dest"; then df=4; elif [[ $dest == *:* ]]; then df=6; fi
	if [[ -z $df ]]; then
		warn "Адрес назначения $dest - домен: он должен резолвиться в адреса того же семейства, что и $(strip_brackets "$R_SRC") (IPv$sf)." \
			"The destination $dest is a domain: it must resolve to addresses of the same family as $(strip_brackets "$R_SRC") (IPv$sf)."
	elif [[ $sf != "$df" ]]; then
		warn "Адрес после @ ($(strip_brackets "$R_SRC")) - IPv$sf, а адрес назначения ($dest) - IPv$df: семейства должны совпадать." \
			"The address after @ ($(strip_brackets "$R_SRC")) is IPv$sf, but the destination ($dest) is IPv$df: the families must match."
		return 1
	fi
}

# group = (proto, listen address, port): names and at most one nameless rule share it
v_ports() {
	local item p g
	local -a items
	local -A grp_all=() grp_one=() seen_plain=() seen_name=()
	[[ -n $1 ]] || {
		warn "Список правил пуст" "The rule list is empty"
		return 1
	}
	IFS=, read -ra items <<<"$1"
	for item in "${items[@]}"; do
		parse_rule "$item" || return 1
		if [[ -z $R_HOST && -z $TARGET ]]; then
			warn "У правила «$item» нет своего хоста, а адрес назначения по умолчанию (--target) не задан" \
				"The rule \"$item\" has no host of its own and the default destination (--target) is not set"
			return 1
		fi
		if [[ -n $R_HOST && $R_HOST != "["* ]] && ! is_ipv4 "$R_HOST"; then
			check_domain "$R_HOST" || return 1
		fi
		if [[ -n $R_SRC ]]; then check_src || return 1; fi
		for p in tcp udp; do
			if [[ $R_PROTO != both && $R_PROTO != "$p" ]]; then continue; fi
			# no address = all: conflicts with any address on the same proto and port
			if [[ -z $R_LIP && -n ${grp_one[$p:$R_LP]:-} ]] || [[ -n $R_LIP && -n ${grp_all[$p:$R_LP]:-} ]]; then
				warn "Повтор $p:${R_LIP:+$R_LIP:}$R_LP" "Duplicate $p:${R_LIP:+$R_LIP:}$R_LP"
				return 1
			fi
			g=$p:${R_LIP:-*}:$R_LP
			if [[ -n $R_SNI ]]; then
				if [[ -n ${seen_name[$g/$R_SNI]:-} ]]; then
					warn "Повтор имени $R_SNI на $p:${R_LIP:+$R_LIP:}$R_LP" "Duplicate name $R_SNI on $p:${R_LIP:+$R_LIP:}$R_LP"
					return 1
				fi
				seen_name[$g/$R_SNI]=1
			else
				if [[ -n ${seen_plain[$g]:-} ]]; then
					warn "Повтор $p:${R_LIP:+$R_LIP:}$R_LP" "Duplicate $p:${R_LIP:+$R_LIP:}$R_LP"
					return 1
				fi
				seen_plain[$g]=1
			fi
			if [[ -z $R_LIP ]]; then grp_all[$p:$R_LP]=1; else grp_one[$p:$R_LP]=1; fi
		done
	done
}

# ---------------------------------------------------------------- questions

norm_yn() {
	case "${1,,}" in
	y | yes | д | да | true | 1) printf y ;;
	n | no | н | нет | false | 0) printf n ;;
	*) printf '%s' "$1" ;;
	esac
}

setup_tty() {
	if [[ -t 0 ]]; then return 0; fi
	if (: </dev/tty) 2>/dev/null; then
		exec </dev/tty
		return 0
	fi
	# "soft": the caller has a safe answer without a terminal
	if ((!YES)) && [[ ${1:-} != soft ]]; then
		die "Нет терминала для вопросов: запустите с --yes и флагами (см. --help)" \
			"No terminal for questions: run with --yes and flags (see --help)"
	fi
}

bad_value() {
	die "Недопустимое значение для $1" "Invalid value for $1"
}

# ask VAR "ru" "en" validator   (flag > --yes default > prompt)
ask() {
	local var=$1 ru=$2 en=$3 check=$4 val=${!1:-} def=${D[$1]:-}
	if [[ -n $val ]]; then
		"$check" "$val" || bad_value "$var"
		return 0
	fi
	if ((YES)); then
		"$check" "$def" || bad_value "$var"
		printf -v "$var" '%s' "$def"
		return 0
	fi
	printf '\n'
	hdr "$ru" "$en"
	if [[ -n ${5:-} ]]; then "$5"; fi
	while :; do
		read -r -e -p "$RL_CYAN>$RL_OFF " -i "$def" val || die "Ввод прерван" "Input aborted"
		if "$check" "$val"; then break; fi
	done
	printf -v "$var" '%s' "$val"
}

# ask_yn VAR "ru" "en" ["note ru" "note en"]
ask_yn() {
	local var=$1 ru=$2 en=$3 val def
	val=$(norm_yn "${!var:-}")
	def=$(norm_yn "${D[$var]:-n}")
	if [[ -n $val ]]; then
		v_yn "$val" || bad_value "$var"
		printf -v "$var" '%s' "$val"
		return 0
	fi
	if ((YES)); then
		printf -v "$var" '%s' "$def"
		return 0
	fi
	printf '\n'
	hdr "$ru" "$en"
	if (($# > 3)); then dim "  $4" "  $5"; fi
	while :; do
		read -r -e -p "$RL_CYAN>$RL_OFF ${RL_DIM}(y/n)$RL_OFF " -i "$def" val || die "Ввод прерван" "Input aborted"
		val=$(norm_yn "$val")
		if v_yn "$val"; then break; fi
		say "Ответьте y или n." "Answer y or n."
	done
	printf -v "$var" '%s' "$val"
}

# choose VAR "ru title" "en title" "value|ru label|en label" ...
choose() {
	local var=$1 ru=$2 en=$3 val=${!1:-} def=${D[$1]:-} o i pick rest lr le defn=1
	shift 3
	local -a opts=("$@")
	if [[ -n $val ]]; then
		for o in "${opts[@]}"; do
			if [[ ${o%%|*} == "$val" ]]; then return 0; fi
		done
		bad_value "$var"
	fi
	for ((i = 0; i < ${#opts[@]}; i++)); do
		if [[ ${opts[i]%%|*} == "$def" ]]; then defn=$((i + 1)); fi
	done
	if ((YES)); then
		printf -v "$var" '%s' "${opts[defn - 1]%%|*}"
		return 0
	fi
	printf '\n'
	hdr "$ru" "$en"
	for ((i = 0; i < ${#opts[@]}; i++)); do
		rest=${opts[i]#*|}
		lr=${rest%%|*}
		le=${rest#*|}
		opt $((i + 1)) "$(msg "$lr" "$le")"
	done
	while :; do
		read -r -e -p "$RL_CYAN>$RL_OFF " -i "$defn" pick || die "Ввод прерван" "Input aborted"
		if [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#opts[@]})); then
			printf -v "$var" '%s' "${opts[pick - 1]%%|*}"
			return 0
		fi
		say "Введите номер из списка." "Enter a number from the list."
	done
}

# confirm "ru" "en" default(y|n) -> 0 for yes
confirm() {
	local ans def=${3:-n}
	if ((YES)); then
		[[ $def == y ]]
		return
	fi
	while :; do
		if ! read -r -e -p "$RL_BOLD$(msg "$1" "$2")$RL_OFF ${RL_DIM}(y/n)$RL_OFF " -i "$def" ans; then
			# "soft": end of input means the default answer, not abort
			if [[ ${4:-} == soft ]]; then
				printf '\n'
				ans=$def
			else
				die "Ввод прерван" "Input aborted"
			fi
		fi
		ans=$(norm_yn "$ans")
		if v_yn "$ans"; then break; fi
	done
	[[ $ans == y ]]
}

ask_lang() {
	local pick defn=1
	case $UI_LANG in
	ru | en) return 0 ;;
	"") ;;
	*) die "--lang: ru | en" "--lang: ru | en" ;;
	esac
	UI_LANG=${D[UI_LANG]:-ru}
	if ((YES)); then return 0; fi
	if [[ $UI_LANG == en ]]; then defn=2; fi
	printf '\n%sLanguage / Язык%s\n' "$C_BOLD" "$C_OFF"
	opt 1 Русский
	opt 2 English
	while :; do
		read -r -e -p "$RL_CYAN>$RL_OFF " -i "$defn" pick || die "Ввод прерван" "Input aborted"
		case $pick in
		1) UI_LANG=ru ;;
		2) UI_LANG=en ;;
		*) continue ;;
		esac
		break
	done
}

target_hint() {
	dim "  IPv4, IPv6 или домен: куда передавать соединения" "  IPv4, IPv6 or a domain: where connections go"
}

ports_hint() {
	dim "  proto:порт[/имя][>[хост:]порт_цели][@адрес] через запятую; proto - tcp, udp или both" \
		"  proto:port[/name][>[host:]target_port][@address], comma separated; proto is tcp, udp or both"
	dim "    tcp:443                         TCP 443 -> тот же порт сервера назначения" \
		"    tcp:443                         TCP 443 -> the same port of the destination"
	dim "    udp:8443>443                    UDP 8443 -> порт 443" "    udp:8443>443                    UDP 8443 -> port 443"
	dim "    tcp:2222>203.0.113.20:22        на другой сервер" "    tcp:2222>203.0.113.20:22        to another server"
	dim "    udp:51820>[2001:db8::20]:51820  IPv6 - в квадратных скобках" \
		"    udp:51820>[2001:db8::20]:51820  IPv6 in square brackets"
	dim "    tcp:443/a.example.com>203.0.113.5:443,tcp:443>203.0.113.9:443  по имени сайта (TLS)" \
		"    tcp:443/a.example.com>203.0.113.5:443,tcp:443>203.0.113.9:443  by site name (TLS)"
	dim "  Адрес слушания и исходящий адрес (@) - в README." "  Listen and outgoing (@) addresses: see the README."
}

ask_all() {
	ask_lang
	# required in the dialog, or the rules question would loop with no way back;
	# an empty --target (a host in every rule) is for flags only
	local tcheck=v_target
	if ((YES)); then tcheck=v_target_opt; fi
	ask TARGET "Адрес сервера назначения" "Destination address" "$tcheck" target_hint
	TARGET=$(strip_brackets "$TARGET")
	ask PORTS "Правила портов" "Port rules" v_ports ports_hint
	choose LISTEN "На каких адресах слушать?" "Listen on which addresses?" \
		"v4|только IPv4|IPv4 only" \
		"v4v6|IPv4 и IPv6|IPv4 and IPv6"
	ask_yn PROXY_PROTOCOL "Включить PROXY protocol к серверу назначения?" "Send PROXY protocol to the destination?" \
		"Передаёт серверу назначения адрес клиента. Только если сервер это принимает: иначе соединения ломаются." \
		"Passes the client address to the destination. Only if it accepts that: otherwise connections break."
	choose LOGS "Журнал nginx" "nginx log" \
		"off|нет|none" \
		"error|только ошибки|errors only"
	ask_yn TUNE "Настроить параметры ядра?" "Tune kernel parameters?" \
		"Больше соединений, сетевые буферы, BBR. Что ядро не даёт поменять, пропускается." \
		"More connections, network buffers, BBR. What the kernel does not allow is skipped."
	ask_yn SSH_PROTECT "Защитить SSH от перебора?" "Protect SSH from brute force?" \
		"Не больше 10 новых подключений в минуту с одной сети (/24, IPv6: /64): подбор пароля бесполезен." \
		"At most 10 new connections a minute from one network (/24, IPv6: /64): password guessing is pointless."
	ask_yn SCAN_PROTECT "Защита от сканирования?" "Scan protection?" \
		"Сервер не отвечает на ping и закрытые порты. Новой службе на порту ниже 10000 нужен перезапуск установщика." \
		"The server ignores ping and closed ports. A new service on a port below 10000 needs a rerun of the installer."
	ask_yn AUTO_UPDATES "Включить автообновления безопасности?" "Enable unattended security updates?" \
		"Обновления безопасности ставятся сами, без перезагрузки." "Security updates install themselves, without a reboot."
	: "${TCP_TIMEOUT:=${D[TCP_TIMEOUT]}}" "${UDP_TIMEOUT:=${D[UDP_TIMEOUT]}}"
	v_timeout "$TCP_TIMEOUT" || bad_value --tcp-timeout
	v_timeout "$UDP_TIMEOUT" || bad_value --udp-timeout
}

# ---------------------------------------------------------------- rules

add_rule() { RULES+=("$1 $2 $3 $4 $5 $6 $7"); }

has_proto() {
	local rule
	for rule in "${RULES[@]}"; do
		if [[ $rule == "$1 "* ]]; then return 0; fi
	done
	return 1
}

has_sni() {
	local rule proto lip lp host tp src sni
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		if [[ $sni != "-" ]]; then return 0; fi
	done
	return 1
}

# fills GNAMED and GDEF; default = the nameless rule, else the first named one
group_info() {
	local i gk proto lip lp host tp src sni
	local -A plain=() first=()
	GDEF=() GNAMED=()
	for ((i = 0; i < ${#RULES[@]}; i++)); do
		read -r proto lip lp host tp src sni <<<"${RULES[i]}"
		gk="$proto $lip $lp"
		if [[ $sni == "-" ]]; then
			plain[$gk]=$i
		else
			GNAMED[$gk]=1
			if [[ -z ${first[$gk]:-} ]]; then first[$gk]=$i; fi
		fi
	done
	for gk in "${!GNAMED[@]}"; do
		GDEF[$gk]=${plain[$gk]:-${first[$gk]}}
	done
}

# rule_line INDEX: "tcp 443 [name] -> host:port from src (default)"; needs group_info first
rule_line() {
	local proto lip lp host tp src sni gk nm="" df=""
	read -r proto lip lp host tp src sni <<<"${RULES[$1]}"
	gk="$proto $lip $lp"
	if [[ $sni != "-" ]]; then nm=" [$sni]"; fi
	if [[ -n ${GNAMED[$gk]:-} && ${GDEF[$gk]} == "$1" ]]; then df=$(msg " (по умолчанию)" " (default)"); fi
	if [[ ${2:-} == sub ]]; then
		if [[ -z $nm ]]; then nm=" $(msg "(без имени)" "(no name)")"; fi
		printf '%s -> %s:%s%s%s' "${nm# }" "$host" "$tp" "$(src_note "$src")" "$df"
	else
		printf '%s %s%s -> %s:%s%s%s' "$proto" "$(fmt_lp "$lip" "$lp")" "$nm" "$host" "$tp" "$(src_note "$src")" "$df"
	fi
}

# $1 listen_ip (* = all), $2 port -> "lp" or "listen_ip:lp"
fmt_lp() { if [[ $1 == "*" ]]; then printf '%s' "$2"; else printf '%s:%s' "$1" "$2"; fi; }

# $1 src (- = none) -> " from ADDR"
src_note() {
	local a
	if [[ -z $1 || $1 == "-" ]]; then return 0; fi
	a=$(strip_brackets "$1")
	msg " с $a" " from $a"
}

src_addrs() {
	local rule proto lip lp host tp src sni
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		if [[ $src != "-" ]]; then strip_brackets "$src"; printf '
'; fi
	done | sort -u | paste -sd' ' -
}

listen_addrs() {
	local rule proto lip lp host tp src sni
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		if [[ $lip != "*" ]]; then printf '%s
' "$lip"; fi
	done | sort -u | paste -sd' ' -
}

build_rules() {
	local item host p
	local -a items
	RULES=()
	IFS=, read -ra items <<<"$PORTS"
	for item in "${items[@]}"; do
		parse_rule "$item" || die "Неверное правило: $item" "Invalid rule: $item"
		host=${R_HOST:-$(fmt_host "$TARGET")}
		for p in tcp udp; do
			if [[ $R_PROTO == both || $R_PROTO == "$p" ]]; then add_rule "$p" "${R_LIP:-*}" "$R_LP" "$host" "$R_TP" "${R_SRC:--}" "${R_SNI:--}"; fi
		done
	done
}

# listen ports >= 10000 and OPEN_HIGH: outgoing connections must not take them
reserved_ports() {
	local rule proto lip lp host tp src sni
	{
		for rule in "${RULES[@]}"; do
			read -r proto lip lp host tp src sni <<<"$rule"
			if ((lp >= 10000)); then printf '%s\n' "$lp"; fi
		done
		if [[ -n $OPEN_HIGH ]]; then tr ' ' '\n' <<<"$OPEN_HIGH"; fi
	} | sort -un | paste -sd, -
}

rule_ports() {
	local rule proto lip lp host tp src sni
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		printf '%s/%s\n' "$lp" "$proto"
	done | sort -u | paste -sd' ' -
}

need_firewall() { [[ $SSH_PROTECT == y || $SCAN_PROTECT == y ]]; }

# ---------------------------------------------------------------- render (pure: only stdout)

render_nginx_conf() {
	local errlog="/dev/null crit"
	if [[ $LOGS == error ]]; then errlog="/var/log/nginx/error.log warn"; fi
	emit "# nginx-stream - https://github.com/drno88/nginx-stream"
	emit "# Generated; the previous file is nginx.conf.before-nginx-stream."
	emit "user www-data;"
	emit "worker_processes auto;"
	emit "worker_rlimit_nofile 262144;"
	if has_proto udp; then
		emit "# without it old workers keep UDP sessions after a reload (clients keep sending)"
		emit "worker_shutdown_timeout 10s;"
	fi
	emit "pid /run/nginx.pid;"
	emit "error_log $errlog;"
	emit "include /etc/nginx/modules-enabled/*.conf;"
	emit ""
	emit "events {"
	emit "${T}worker_connections 65535;"
	emit "${T}multi_accept on;"
	emit "}"
	emit ""
	emit "$NGX_INCLUDE_LINE"
}

# Shared mode: stdin nginx.conf -> stdout with our include added once.
render_shared_main() {
	local conf
	conf=$(cat)
	if grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/nginx-stream\.conf;' <<<"$conf"; then
		printf '%s\n' "$conf"
	elif grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf;' <<<"$conf"; then
		awk -v inc="$NGX_INCLUDE_LINE" -v mark="$INCLUDE_MARK" '
			{ print }
			!done && /^[ \t]*include[ \t]+\/etc\/nginx\/modules-enabled\/\*\.conf;/ { print mark; print inc; done = 1 }
		' <<<"$conf"
	else
		# at the end: an include before load_module makes nginx -t fail
		printf '%s\n%s\n%s\n' "$conf" "$INCLUDE_MARK" "$NGX_INCLUDE_LINE"
	fi
}

# ensure_upstream PROTO HOST PORT: one upstream block per triple, its name in UP_NAME
# (upname, upused: the calling render_stream_conf variables)
ensure_upstream() {
	local proto=$1 host=$2 tp=$3 hk hs name n=1
	hk=$(strip_brackets "$host")
	hk=${hk,,}
	if [[ -z ${upname[$proto $hk $tp]:-} ]]; then
		# host_safe can collide: the next such host gets _2, _3...
		hs=$(host_safe "$hk")
		name=${proto}_${hs}_${tp}
		while [[ -n ${upused[$name]:-} ]]; do
			n=$((n + 1))
			name=${proto}_${hs}_${tp}_$n
		done
		upused[$name]=1
		upname[$proto $hk $tp]=$name
		emit ""
		emit "${T}upstream $name {"
		emit "${T}${T}server $host:$tp max_fails=0;"
		emit "${T}}"
	fi
	UP_NAME=${upname[$proto $hk $tp]}
}

# emit_listens PROTO "lip@lp ..."
emit_listens() {
	local proto=$1 l lip_l lp k tl
	local -a ls
	read -ra ls <<<"$2"
	for l in "${ls[@]}"; do
		lip_l=${l%@*} lp=${l#*@}
		if [[ $lip_l == "*" ]]; then tl="$lp [::]:$lp"; else tl="$lip_l:$lp"; fi
		for k in $tl; do
			if [[ $k == "[::]:$lp" && $LISTEN != v4v6 ]]; then continue; fi
			if [[ $proto == tcp ]]; then
				emit "${T}${T}listen $k so_keepalive=on backlog=65535;"
			elif [[ $TUNE == y ]]; then
				emit "${T}${T}listen $k udp reuseport rcvbuf=16m sndbuf=16m;"
			else
				emit "${T}${T}listen $k udp reuseport;"
			fi
		done
	done
}

emit_proxy_opts() {
	if [[ $1 == tcp ]]; then
		emit "${T}${T}proxy_connect_timeout 5s;"
		emit "${T}${T}proxy_timeout $TCP_TIMEOUT;${T}# closes idle connections"
		emit "${T}${T}proxy_socket_keepalive on;"
		emit "${T}${T}proxy_buffer_size 64k;${T}# default 16k: extra syscalls on a fat stream"
		if [[ $PROXY_PROTOCOL == y ]]; then emit "${T}${T}proxy_protocol on;"; fi
	else
		emit "${T}${T}proxy_timeout $UDP_TIMEOUT;"
	fi
}

# map_rows W KEY VALUE ...: map lines with the values in one column
map_rows() {
	local w=$1
	shift
	while (($# >= 2)); do
		emit "${T}${T}$(printf '%-*s%s;' "$w" "$1" "$2")"
		shift 2
	done
}

# One server per group with names: maps pick the upstream (and outgoing address) by TLS server name.
# Maps hold upstream names, not host:port: a domain in a variable would need a resolver.
emit_named_group() {
	local gk=$1 proto lip lp i def vs w d dsrc v hassrc=0 host tp src sni
	local -a idx up_of=() rows=() srows=()
	read -ra idx <<<"${gmem[$gk]}"
	def=${GDEF[$gk]}
	for i in "${idx[@]}"; do
		read -r proto lip lp host tp src sni <<<"${RULES[i]}"
		ensure_upstream tcp "$host" "$tp"
		up_of[i]=$UP_NAME
		if [[ $src != "-" ]]; then hassrc=1; fi
	done
	read -r proto lip lp <<<"$gk"
	if [[ $lip == "*" ]]; then vs=${proto}_$lp; else vs=${proto}_$(host_safe "$lip")_$lp; fi
	rows=(default "${up_of[def]}")
	w=9
	for i in "${idx[@]}"; do
		read -r d d d d d src sni <<<"${RULES[i]}"
		if [[ $sni == "-" ]]; then continue; fi
		rows+=("$sni" "${up_of[i]}")
		if ((${#sni} + 2 > w)); then w=$((${#sni} + 2)); fi
	done
	emit ""
	emit "${T}# SNI picks the destination; no name, another name or not TLS goes to default"
	emit "${T}map \$ssl_preread_server_name \$ns_up_$vs {"
	emit "${T}${T}hostnames;"
	map_rows "$w" "${rows[@]}"
	emit "${T}}"
	if ((hassrc)); then
		read -r d d d d d dsrc d <<<"${RULES[def]}"
		if [[ $dsrc == "-" ]]; then dsrc='""'; else dsrc=$(strip_brackets "$dsrc"); fi
		srows=(default "$dsrc")
		for i in "${idx[@]}"; do
			read -r d d d d d src sni <<<"${RULES[i]}"
			if [[ $sni == "-" ]]; then continue; fi
			if [[ $src == "-" ]]; then v='""'; else v=$(strip_brackets "$src"); fi
			# a row per name even if equal to default: a *.zone with another @ must not cover it
			srows+=("$sni" "$v")
		done
		emit ""
		emit "${T}# outgoing address (@) per name"
		emit "${T}map \$ssl_preread_server_name \$ns_src_$vs {"
		emit "${T}${T}hostnames;"
		map_rows "$w" "${srows[@]}"
		emit "${T}}"
	fi
	emit ""
	emit "${T}server {"
	emit_listens tcp "$lip@$lp"
	emit "${T}${T}ssl_preread on;"
	emit "${T}${T}proxy_pass \$ns_up_$vs;"
	if ((hassrc)); then emit "${T}${T}proxy_bind \$ns_src_$vs;${T}# outgoing address"; fi
	emit_proxy_opts tcp
	emit "${T}}"
}

render_stream_conf() {
	local proto lip lp host tp src sni key hk gk i entry udp_noted=0
	local -a order=()
	local -A listens=() hostof=() upname=() upused=() gmem=()
	local UP_NAME=""
	group_info
	for ((i = 0; i < ${#RULES[@]}; i++)); do
		read -r proto lip lp host tp src sni <<<"${RULES[i]}"
		gk="$proto $lip $lp"
		if [[ -n ${GNAMED[$gk]:-} ]]; then
			if [[ -z ${gmem[$gk]:-} ]]; then order+=("G$gk"); fi
			gmem[$gk]+="${gmem[$gk]:+ }$i"
			continue
		fi
		# grouped by the host itself: a-b.example.com and a.b.example.com have one host_safe but are two hosts
		hk=$(strip_brackets "$host")
		hk=${hk,,}
		key="$proto $hk $tp $src"
		if [[ -z ${listens[$key]:-} ]]; then
			order+=("U$key")
			hostof[$key]=$host
		fi
		listens[$key]+="${listens[$key]:+ }$lip@$lp"
	done
	emit "# nginx-stream: target=${TARGET:-none}"
	emit "stream {"
	emit "${T}access_log off;"
	if ((${#GNAMED[@]})); then
		# a hash element is a pointer plus the name aligned to 8; 128 fits names up to ~110 characters
		local maxn=0 bucket=128
		for ((i = 0; i < ${#RULES[@]}; i++)); do
			read -r proto lip lp host tp src sni <<<"${RULES[i]}"
			if [[ $sni != "-" ]] && ((${#sni} > maxn)); then maxn=${#sni}; fi
		done
		if ((maxn > 110)); then bucket=512; fi
		emit ""
		emit "${T}map_hash_bucket_size $bucket;${T}# room for long host names in the maps"
	fi
	emit ""
	emit "${T}# max_fails=0: a short failure must not take one address of a dual-stack domain out"
	for entry in "${order[@]}"; do
		if [[ ${entry:0:1} == G ]]; then
			emit_named_group "${entry:1}"
			continue
		fi
		key=${entry:1}
		read -r proto hk tp src <<<"$key"
		host=${hostof[$key]}
		ensure_upstream "$proto" "$host" "$tp"
		emit ""
		if [[ $proto == udp && $udp_noted == 0 ]]; then
			udp_noted=1
			emit "${T}# reuseport: else one client's datagrams spread over workers and the server sees mixed sessions"
		fi
		emit "${T}server {"
		emit_listens "$proto" "${listens[$key]}"
		emit "${T}${T}proxy_pass $UP_NAME;"
		if [[ $src != "-" ]]; then emit "${T}${T}proxy_bind $(strip_brackets "$src");${T}# outgoing address"; fi
		emit_proxy_opts "$proto"
		emit "${T}}"
	done
	emit "}"
}

render_override() {
	emit "[Service]"
	emit "LimitNOFILE=262144"
	emit "Restart=on-failure"
	emit "RestartSec=2s"
}

render_modules_load() {
	emit "# nginx-stream: BBR congestion control"
	emit "tcp_bbr"
}

# render_sysctl RAM_MB BBR(y|n)
render_sysctl() {
	local ram=$1 bbr=$2 rdef=1048576 bufs="4096 262144 16777216" high low press reserved
	if ((ram < 1024)); then rdef=262144; fi
	if ((ram <= 1024)); then bufs="4096 131072 8388608"; fi
	high=$((ram * 1024 * 14 / 4 / 100))
	low=$((high / 3))
	press=$((2 * high / 3))
	reserved=$(reserved_ports)
	emit "# nginx-stream: relay kernel parameters (apply: sysctl -e -p <this file>)"
	emit ""
	if [[ $bbr == y ]]; then
		emit "# BBR + fq: better throughput on lossy long-distance paths"
		emit "net.core.default_qdisc = fq"
		emit "net.ipv4.tcp_congestion_control = bbr"
		emit ""
	fi
	emit "# socket buffers: UDP bursts must not be dropped before nginx reads them"
	emit "net.core.rmem_max = 16777216"
	emit "net.core.wmem_max = 16777216"
	emit "net.core.rmem_default = $rdef"
	emit "net.core.wmem_default = $rdef"
	emit "net.ipv4.udp_rmem_min = 16384"
	emit "net.ipv4.udp_wmem_min = 16384"
	emit "net.ipv4.tcp_rmem = $bufs"
	emit "net.ipv4.tcp_wmem = $bufs"
	emit ""
	emit "# total TCP memory: 14% of RAM in 4 KB pages (kernel default is too low on 1 GB; more risks OOM)"
	emit "net.ipv4.tcp_mem = $low $press $high"
	emit ""
	emit "# queues: many simultaneous connections"
	emit "net.core.netdev_max_backlog = 16384"
	emit "net.core.somaxconn = 65535"
	emit "net.ipv4.tcp_max_syn_backlog = 8192"
	emit ""
	emit "# wide outgoing range; our listen ports >= 10000 are reserved against it"
	emit "net.ipv4.ip_local_port_range = 10000 65535"
	if [[ -n $reserved ]]; then emit "net.ipv4.ip_local_reserved_ports = $reserved"; fi
	emit ""
	emit "net.ipv4.tcp_mtu_probing = 1"
	emit "net.ipv4.tcp_slow_start_after_idle = 0"
	emit "net.ipv4.tcp_notsent_lowat = 131072"
	emit ""
	emit "# dead peers noticed in ~11 min; closed sockets released sooner"
	emit "net.ipv4.tcp_keepalive_time = 600"
	emit "net.ipv4.tcp_keepalive_intvl = 30"
	emit "net.ipv4.tcp_keepalive_probes = 3"
	emit "net.ipv4.tcp_fin_timeout = 15"
	emit "net.ipv4.tcp_tw_reuse = 1"
	emit ""
	emit "# keep the relay in RAM"
	emit "vm.swappiness = 10"
}

# render_firewall "SSH_PORT..." (the ports of sshd, space separated)
render_firewall() {
	local rule proto lip lp host tp src sni low dp p
	local -a sp
	read -ra sp <<<"$1"
	if ((${#sp[@]} == 1)); then
		dp=${sp[0]}
	else
		printf -v dp '%s, ' "${sp[@]}"
		dp="{ ${dp%, } }"
	fi
	emit "#!/usr/sbin/nft -f"
	emit "# nginx-stream: own table only, other rules are not touched"
	emit "table $NFT_TABLE"
	emit "delete table $NFT_TABLE"
	emit "table $NFT_TABLE {"
	if [[ $SSH_PROTECT == y ]]; then
		emit "${T}set ssh4 { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m; }"
		emit "${T}set ssh6 { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 2m; }"
	fi
	emit "${T}chain input {"
	emit "${T}${T}type filter hook input priority -10; policy accept;"
	if [[ $SSH_PROTECT == y ]]; then
		# No "ct state": it would load conntrack for all relay traffic ("table full" on small RAM).
		# Syntax is checked with `nft -c -f` before applying (apply()); if rejected, the protection is switched off.
		emit "${T}${T}# ssh-protect: >10 new connections/min from one /24 (IPv6: /64) are dropped (bare SYN, no conntrack)"
		emit "${T}${T}tcp dport $dp tcp flags & (fin|syn|rst|ack) == syn update @ssh4 { ip saddr and 255.255.255.0 limit rate over 10/minute burst 10 packets } drop"
		emit "${T}${T}tcp dport $dp tcp flags & (fin|syn|rst|ack) == syn update @ssh6 { ip6 saddr and ffff:ffff:ffff:ffff:: limit rate over 10/minute burst 10 packets } drop"
	fi
	if [[ $SCAN_PROTECT == y ]]; then
		emit "${T}${T}# scan-protect: no answer to ping"
		emit "${T}${T}icmp type echo-request drop"
		emit "${T}${T}icmpv6 type echo-request drop"
	fi
	emit "${T}}"
	if [[ $SCAN_PROTECT == y ]]; then
		low=$(
			{
				for p in "${sp[@]}"; do
					if ((p < 10000)); then printf '%s\n' "$p"; fi
				done
				# listening now (empty in dry-run)
				if [[ -n $OPEN_TCP ]]; then tr ' ' '\n' <<<"$OPEN_TCP"; fi
				for rule in "${RULES[@]}"; do
					read -r proto lip lp host tp src sni <<<"$rule"
					if [[ $proto == tcp ]] && ((lp < 10000)); then printf '%s\n' "$lp"; fi
				done
			} | sort -un | paste -sd, - | sed 's/,/, /g'
		)
		emit "${T}chain output {"
		emit "${T}${T}type filter hook output priority -10; policy accept;"
		emit "${T}${T}# scan-protect: no RST from closed ports, except nginx (listen and 10000-65535), SSH and TCP ports"
		emit "${T}${T}# listening at install time (else their dropped connections hang); newer services need a rerun"
		emit "${T}${T}tcp flags & rst == rst tcp sport != { ${low:+$low, }10000-65535 } drop"
		emit "${T}${T}icmp type destination-unreachable icmp code port-unreachable drop"
		emit "${T}${T}icmpv6 type destination-unreachable icmpv6 code port-unreachable drop"
		emit "${T}}"
	fi
	emit "}"
}

render_firewall_unit() {
	emit "[Unit]"
	emit "Description=nginx-stream firewall (own nftables table)"
	emit "# nftables.service flushes the ruleset: our table is loaded again after its restart/reload (start: drop-in)"
	emit "After=network-pre.target nftables.service"
	emit "PartOf=nftables.service"
	emit "ReloadPropagatedFrom=nftables.service"
	emit ""
	emit "[Service]"
	emit "Type=oneshot"
	emit "RemainAfterExit=yes"
	emit "ExecStart=/usr/sbin/nft -f $FIREWALL_FILE"
	emit "ExecReload=/usr/sbin/nft -f $FIREWALL_FILE"
	emit "ExecStop=-/usr/sbin/nft delete table $NFT_TABLE"
	emit ""
	emit "[Install]"
	emit "WantedBy=multi-user.target"
}

# PartOf covers stop/restart only: after every start of nftables (our units may be active already) restart them.
# --no-block: they are ordered after nftables.
render_nft_dropin() {
	local units="nginx-stream-ports.service"
	if need_firewall; then units="nginx-stream-firewall.service $units"; fi
	emit "# nginx-stream: nftables.service starts with flush ruleset, load our rules again after it"
	emit "[Service]"
	emit "ExecStartPost=-/bin/systemctl --no-block restart $units"
}

# render_ports_script TOKEN...: sh script opening the relay ports in the input filters found when it runs
# (token = proto:port:fam, fam 4|6|46). "up" runs at boot and when the other firewall restarts.
render_ports_script() {
	emit "#!/bin/sh"
	emit "# nginx-stream: opens relay ports in iptables and foreign nft input chains (rules marked nginx-stream)"
	emit "PORTS='$*'"
	cat <<'EOF'
rc=0

# ports_for FAMILY (4|6|46): proto:port of the fitting tokens, unique
ports_for() {
	for t in $PORTS; do
		f=${t##*:}
		case $f in *4*) case $1 in *4*) echo "${t%:*}" ;; esac ;; esac
		case $f in *6*) case $1 in *6*) echo "${t%:*}" ;; esac ;; esac
	done | sort -u
}

down() {
	for bin in iptables ip6tables; do
		command -v "$bin" >/dev/null 2>&1 || continue
		"$bin" -w 5 -S INPUT 2>/dev/null | grep -E -e '--comment nginx-stream( |$)' | sed 's/^-A INPUT /-D INPUT /' |
			while IFS= read -r r; do
				# shellcheck disable=SC2086  # the rule is words on purpose
				"$bin" -w 5 $r >/dev/null 2>&1 || true
			done
	done
	command -v nft >/dev/null 2>&1 || return 0
	nft -a list ruleset 2>/dev/null | awk '
		$1 == "table" { fam = $2; tbl = $3 }
		$1 == "chain" { ch = $2 }
		/comment "nginx-stream"/ && /# handle [0-9]+$/ && !(fam == "inet" && tbl == "nginx_stream") {
			print fam, tbl, ch, $NF
		}' | while read -r fam tbl ch h; do
		nft delete rule "$fam" "$tbl" "$ch" handle "$h" >/dev/null 2>&1 || true
	done
}

# ACCEPT goes before the final catch-all DROP/REJECT, or at the end if only the policy drops; not first:
# that would bypass the owner's bans (-s X -j DROP, sets). A chain open by default needs nothing.

# ipt_up BIN FAMILY
ipt_up() {
	command -v "$1" >/dev/null 2>&1 || return 0
	# "I N": the last rule N is a bare DROP/REJECT (comment, input interface allowed); "A": policy DROP; "N": none
	where=$("$1" -w 5 -S INPUT 2>/dev/null | awk '
		/^-P INPUT / { pol = $3 }
		/^-A INPUT / { n++; last = $0; lastn = n }
		END {
			r = last
			gsub(/ -m comment --comment ("[^"]*"|[^ ]+)/, "", r)
			gsub(/ -i [^ ]+/, "", r)
			if (r ~ /^-A INPUT -j (DROP|REJECT)( --reject-with [^ ]+)?$/) print "I " lastn
			else if (pol == "DROP") print "A"
			else print "N"
		}')
	for t in $(ports_for "$2"); do
		case $where in
		I*) "$1" -w 5 -I INPUT "${where#I }" -p "${t%:*}" --dport "${t#*:}" -m comment --comment nginx-stream -j ACCEPT || rc=1 ;;
		A) "$1" -w 5 -A INPUT -p "${t%:*}" --dport "${t#*:}" -m comment --comment nginx-stream -j ACCEPT || rc=1 ;;
		esac
	done
}

# nft_up: foreign base chains of the input hook (not iptables-nft's INPUT: iptables owns it): insert by handle
# before the final bare drop/reject (counter, log, comment, iif allowed); with only policy drop, add at the end.
nft_up() {
	command -v nft >/dev/null 2>&1 || return 0
	for c in $(nft -a list ruleset 2>/dev/null | awk '
		BEGIN {
			cnt = "counter([ \t]+packets[ \t]+[0-9]+[ \t]+bytes[ \t]+[0-9]+)?"
			lg = "log(([ \t]+prefix[ \t]+\"[^\"]*\")|([ \t]+(level|group|snaplen|queue-threshold|flags)[ \t]+[^ \t]+))*"
			verd = "(drop|reject([ \t]+with[ \t]+[^ \t]+([ \t]+[^ \t]+([ \t]+[^ \t]+)?)?)?)"
			re = "^[ \t]*((" cnt "|" lg ")[ \t]+)*" verd "[ \t]*$"
		}
		function flush() {
			if (ok) {
				if (solid) print fam ":" tbl ":" ch ":I:" lasth
				else if (pol) print fam ":" tbl ":" ch ":A"
			}
			ok = 0
		}
		$1 == "table" { flush(); fam = $2; tbl = $3 }
		$1 == "chain" { flush(); ch = $2; solid = 0; pol = 0; lasth = "" }
		/type filter hook input/ {
			ok = (fam == "ip" || fam == "ip6" || fam == "inet") && !(fam == "inet" && tbl == "nginx_stream") && !(fam != "inet" && ch == "INPUT")
			pol = /policy drop;/ ? 1 : 0
			next
		}
		ok && /# handle [0-9]+[ \t]*$/ {
			lasth = $NF
			r = $0
			sub(/[ \t]*#[ \t]*handle[ \t]+[0-9]+[ \t]*$/, "", r)
			# a comment and an input interface do not make the verdict partial
			sub(/[ \t]+comment[ \t]+"[^"]*"[ \t]*$/, "", r)
			gsub(/(^|[ \t])iif(name)?[ \t]+("[^"]*"|[^ \t]+)/, " ", r)
			solid = (r ~ re)
		}
		/^[ \t]*}/ { flush() }
		END { flush() }'); do
		fam=${c%%:*}
		rest=${c#*:}
		tbl=${rest%%:*}
		rest=${rest#*:}
		ch=${rest%%:*}
		rest=${rest#*:}
		where=${rest%%:*}
		h=${rest#*:}
		case $fam in ip) w=4 ;; ip6) w=6 ;; *) w=46 ;; esac
		for t in $(ports_for "$w"); do
			if [ "$where" = I ]; then
				nft insert rule "$fam" "$tbl" "$ch" position "$h" "${t%:*}" dport "${t#*:}" accept comment '"nginx-stream"' || rc=1
			else
				nft add rule "$fam" "$tbl" "$ch" "${t%:*}" dport "${t#*:}" accept comment '"nginx-stream"' || rc=1
			fi
		done
	done
}

# ufw: the installer adds its own rules; our INPUT ACCEPT would bypass its denies
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; }

# firewalld: ports are only printed; its reload would wipe our rules
firewalld_active() { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; }

up() {
	down
	if firewalld_active; then return 0; fi
	if ! ufw_active; then
		ipt_up iptables 4
		ipt_up ip6tables 6
	fi
	nft_up
}

case ${1:-} in
up) up ;;
down) down ;;
*)
	echo "usage: $0 up|down" >&2
	exit 2
	;;
esac
exit $rc
EOF
}

render_ports_unit() {
	emit "[Unit]"
	emit "Description=nginx-stream: relay ports open in the host firewall"
	emit "# follows the other firewall: restart, reload, stop + start (start of nftables: its drop-in)"
	emit "After=network-pre.target nftables.service netfilter-persistent.service iptables.service ip6tables.service ufw.service firewalld.service"
	emit "PartOf=nftables.service netfilter-persistent.service"
	emit "ReloadPropagatedFrom=nftables.service netfilter-persistent.service"
	emit "Wants=network-pre.target"
	emit ""
	emit "[Service]"
	emit "Type=oneshot"
	emit "RemainAfterExit=yes"
	emit "ExecStart=$PORTS_SCRIPT up"
	emit "ExecReload=$PORTS_SCRIPT up"
	emit "ExecStop=-$PORTS_SCRIPT down"
	emit ""
	emit "[Install]"
	emit "WantedBy=multi-user.target netfilter-persistent.service"
}

render_settings() {
	local k
	# shellcheck disable=SC2034  # saved below through indirect expansion ${!k}
	INSTALLER_VERSION=$INSTALLER_VER
	emit "# nginx-stream settings (written by the installer; sourced by it on reconfigure)"
	for k in "${SETTING_KEYS[@]}"; do
		printf '%s=%q\n' "$k" "${!k}"
	done
}

# render_all DIR: every install file under its dry-run name; the real install copies from here.
render_all() {
	local d=$1
	mkdir -p "$d"
	if [[ $NGINX_MODE == shared ]]; then
		render_shared_main <"$NGX_MAIN" >"$d/nginx.conf"
	else
		render_nginx_conf >"$d/nginx.conf"
	fi
	render_stream_conf >"$d/nginx-stream.conf"
	render_override >"$d/nginx-service-override.conf"
	if [[ $TUNE == y ]]; then
		render_sysctl "$RAM_MB" "$BBR" >"$d/90-nginx-stream.conf"
		if [[ $BBR == y ]]; then render_modules_load >"$d/modules-load-nginx-stream.conf"; fi
	fi
	if need_firewall; then
		render_firewall "$SSH_PORT" >"$d/firewall.nft"
		render_firewall_unit >"$d/nginx-stream-firewall.service"
	fi
	# shellcheck disable=SC2086  # the tokens are words on purpose
	render_ports_script $PORT_TOKENS >"$d/ports.sh"
	render_ports_unit >"$d/nginx-stream-ports.service"
	render_nft_dropin >"$d/nftables-service-nginx-stream.conf"
	render_settings >"$d/settings.env"
}

# ---------------------------------------------------------------- summary

show_choices() {
	local i why_ru why_en mode_ru mode_en listen_ru listen_en logs_ru logs_en
	case $NGINX_WHY in
	fresh) why_ru="nginx ставится этим запуском" why_en="nginx is installed by this run" ;;
	ours) why_ru="nginx.conf уже наш" why_en="nginx.conf is already ours" ;;
	settings) why_ru="как при прошлой установке" why_en="as in the previous install" ;;
	changed) why_ru="nginx.conf изменён после установки, добавляется include" why_en="nginx.conf was changed after the install, an include is added" ;;
	pristine) why_ru="на nginx ничего нет, кроме пакетного" why_en="nginx has nothing but the package config" ;;
	*) why_ru="nginx уже обслуживает сайты, добавляется include" why_en="nginx already serves sites, an include is added" ;;
	esac
	mode_ru="свой" mode_en="own"
	if [[ $NGINX_MODE == shared ]]; then mode_ru="общий" mode_en="shared"; fi
	listen_ru="IPv4 и IPv6" listen_en="IPv4 and IPv6"
	if [[ $LISTEN == v4 ]]; then listen_ru="только IPv4" listen_en="IPv4 only"; fi
	logs_ru="нет" logs_en="none"
	if [[ $LOGS == error ]]; then logs_ru="только ошибки" logs_en="errors only"; fi
	printf '\n'
	hdr "Сводка" "Summary"
	row "Сервер назначения      " "Destination            " "${TARGET:--}"
	row "Слушать                " "Listen on              " "$(msg "$listen_ru" "$listen_en")"
	row "Режим nginx            " "nginx mode             " "$(msg "$mode_ru - $why_ru" "$mode_en - $why_en")"
	row "PROXY protocol         " "PROXY protocol         " "$(yn_word "$PROXY_PROTOCOL")"
	row "Журнал nginx           " "nginx log              " "$(msg "$logs_ru" "$logs_en")"
	row "Параметры ядра         " "Kernel tuning          " "$(yn_word "$TUNE")"
	row "Защита SSH             " "SSH protection         " "$(yn_word "$SSH_PROTECT")"
	row "Защита от сканирования " "Scan protection        " "$(yn_word "$SCAN_PROTECT")"
	row "Автообновления         " "Security updates       " "$(yn_word "$AUTO_UPDATES")"
	row "Правила                " "Rules                  " ""
	group_info
	for ((i = 0; i < ${#RULES[@]}; i++)); do
		printf '    %s\n' "$(rule_line "$i")"
	done
	printf '\n'
}

final_report() {
	local rule i cmd ip=${SERVER_IP4:-"<IPv4 этого сервера>"} addrs la a
	if [[ $UI_LANG == en && -z $SERVER_IP4 ]]; then ip="<this server's IPv4>"; fi
	# outgoing connections use the main addresses (by route), not the listen ones
	addrs="IPv4 $ip${SERVER_IP6:+, IPv6 $SERVER_IP6}"
	la=$(listen_addrs)
	a=$(src_addrs)
	if [[ -n $a ]]; then addrs+="; $(msg "исходящие" "outgoing"): ${a// /, }"; fi
	if [[ -n $la ]]; then
		# clients: the listen addresses, plus the main one if some rule has none
		local -a shown=()
		if [[ " ${RULES[*]} " == *" * "* ]]; then shown=("$ip"); fi
		for a in $la; do
			if [[ " ${shown[*]} " != *" $a "* ]]; then shown+=("$a"); fi
		done
		ip=$(printf '%s, ' "${shown[@]}")
		ip=${ip%, }
	fi
	printf '\n%s%s%s\n' "$C_BOLD$C_GRN" "$(msg "Готово. Прокладка слушает:" "Done. The relay listens on:")" "$C_OFF"
	group_info
	for ((i = 0; i < ${#RULES[@]}; i++)); do
		printf '    %s\n' "$(rule_line "$i")"
	done
	printf '\n'
	hdr "Что дальше" "Next steps"
	li "Клиентам - адрес этого сервера ${C_CYAN}$ip${C_OFF} вместо адреса сервера назначения; порты - те, что слушает прокладка." \
		"Clients: use this server's address ${C_CYAN}$ip${C_OFF} instead of the destination's; the ports are the ones the relay listens on."
	li "Если сервер назначения пускает не всех, разрешите на нём адреса прокладки: ${C_CYAN}$addrs${C_OFF}." \
		"If the destination does not accept everyone, allow the relay addresses there: ${C_CYAN}$addrs${C_OFF}."
	if has_sni; then
		li "Имена сайтов должны указывать в DNS на адрес прокладки." "The site names must point to the relay address in DNS."
	fi
	if [[ $PROXY_PROTOCOL == y ]]; then
		warn "PROXY protocol включён: сервер назначения должен его принимать (TCP-правила)." \
			"PROXY protocol is on: the destination must accept it (TCP rules)."
	fi
	if (($(count_port_rules) > 0)); then
		li "Порты открыты в фаерволе сервера и останутся открытыми после перезагрузки (служба nginx-stream-ports)." \
			"The ports are open in the server firewall and stay open after a reboot (nginx-stream-ports service)."
	elif ! ufw_active && ! firewalld_active && input_drops_seen; then
		warn "Во входящих фильтрах есть DROP/REJECT, а места для правил служба портов не нашла: проверьте, что порты $(rule_ports) открыты, и при нужде откройте их сами." \
			"The input filters have DROP/REJECT rules, but the ports service found no place for its rules: check that the ports $(rule_ports) are open and open them yourself if needed."
	fi
	if [[ $NGINX_MODE == shared ]]; then
		warn "nginx общий: лимиты воркеров (worker_rlimit_nofile, worker_connections) не менялись - стоит поднять вручную." \
			"nginx is shared: worker limits (worker_rlimit_nofile, worker_connections) were not changed - consider raising them."
	fi
	cmd=$(self_cmd)
	printf '\n'
	say "Состояние, перенастройка, удаление: ${C_CYAN}$cmd${C_OFF}  ${C_DIM}(настройки: $SETTINGS_FILE)${C_OFF}" \
		"Status, reconfigure, uninstall: ${C_CYAN}$cmd${C_OFF}  ${C_DIM}(settings: $SETTINGS_FILE)${C_OFF}"
}

# ---------------------------------------------------------------- system helpers (real mode only)

require_root() {
	if [[ $(id -u) -ne 0 ]]; then
		die "Нужен root: запустите через sudo или от root." "Root is required: run with sudo or as root."
	fi
	if [[ $(uname -s) != Linux ]]; then
		die "Поддерживается только Linux." "Linux only."
	fi
}

# port_owners PROTO PORT [LISTEN_IP(* = all)] [exact] -> lines "nginx ADDR" / "other ADDR"
# ADDR: ss address, lower case, zone cut, "*" = any; without "exact" a socket on any address counts (clash)
port_owners() {
	local flag=t lip=${3:-*}
	if [[ $1 == udp ]]; then flag=u; fi
	ss -Hln${flag}p 2>/dev/null | awk -v p="$2" -v lip="${lip,,}" -v exact="${4:-}" '
		{
			a = $4
			i = match(a, /:[0-9]+$/)
			if (!i || substr(a, i + 1) != p) next
			a = tolower(substr(a, 1, i - 1))
			sub(/%[^]]*/, "", a)
			if (a == "0.0.0.0" || a == "[::]" || a == "*") a = "*"
			if (lip != "*") {
				if (exact != "" && a != lip) next
				if (exact == "" && a != "*" && a != lip) next
			} else if (exact != "" && a != "*") next
			print (/"nginx"/ ? "nginx" : "other"), a
		}
	' || true
}

# previous rules from settings.env, "proto:addr:port" -> 1: their nginx sockets are no hindrance
declare -A PREV_LISTEN=()
load_prev_listen() {
	local item p a
	local -a items
	PREV_LISTEN=()
	if [[ $PREV_INSTALLED != 1 || -z ${D[PORTS]:-} ]]; then return 0; fi
	IFS=, read -ra items <<<"${D[PORTS]}"
	for item in "${items[@]}"; do
		parse_rule "$item" 2>/dev/null || continue
		a=${R_LIP:-*}
		for p in tcp udp; do
			if [[ $R_PROTO == both || $R_PROTO == "$p" ]]; then PREV_LISTEN[$p:${a,,}:$R_LP]=1; fi
		done
	done
}

# port_busy PROTO PORT LISTEN_IP: 0 if a foreign (or not our) nginx socket is in the way; BUSY_BY=other|nginx
# Own mode: all of nginx is ours; shared: only what the previous rules listened on.
port_busy() {
	local kind addr n=0 o=0
	BUSY_BY=""
	while read -r kind addr; do
		if [[ -z $kind ]]; then continue; fi
		if [[ $kind == nginx ]]; then
			if [[ $NGINX_MODE == own ]]; then continue; fi
			if [[ -n ${PREV_LISTEN[$1:$addr:$2]:-} ]]; then continue; fi
			n=1
		else
			o=1
		fi
	done < <(port_owners "$1" "$2" "$3")
	if ((o)); then BUSY_BY=other; elif ((n)); then BUSY_BY=nginx; fi
	[[ -n $BUSY_BY ]]
}

port_listening() { # PROTO PORT [LISTEN_IP]
	local lip=${3:-*}
	if [[ $lip == "*" ]]; then
		port_owners "$1" "$2" | grep -q nginx
	else
		port_owners "$1" "$2" "$lip" exact | grep -q nginx
	fi
}

# -> 0 if local
has_local_addr() {
	local a
	a=$(strip_brackets "$1")
	if [[ $a == *:* ]]; then
		ip -o -6 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qixF "$a"
	else
		ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$a"
	fi
}

check_os() {
	local id="" ver=""
	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091  # exists only on the target system
		id=$(. /etc/os-release && printf '%s' "${ID:-}")
		# shellcheck disable=SC1091
		ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-0}")
	fi
	case $id in
	debian) if dpkg --compare-versions "$ver" ge 12; then return 0; fi ;;
	ubuntu) if dpkg --compare-versions "$ver" ge 22.04; then return 0; fi ;;
	*) ;;
	esac
	warn "Система ($id $ver) не из проверенных: Debian 12+, Ubuntu 22.04+." "This system ($id $ver) is not a tested one: Debian 12+, Ubuntu 22.04+."
	confirm "Продолжить?" "Continue?" y || die "Остановлено." "Stopped."
}

preflight_system() {
	check_os
	if [[ -e /var/run/reboot-required ]]; then
		warn "Системе нужна перезагрузка (/var/run/reboot-required) - сделайте её позже." "The system needs a reboot (/var/run/reboot-required) - do it later."
	fi
	if [[ -z $SERVER_IP4 ]]; then
		warn "IPv4 сервера не определён (ip route get 1.1.1.1)." "Server IPv4 not detected (ip route get 1.1.1.1)."
	fi
}

# own: nginx is ours alone; shared: it already serves sites
pkg_conf_md5() { # PATH -> md5 of a package conffile (dpkg), empty if unknown
	local p
	for p in nginx-common nginx nginx-core; do
		# shellcheck disable=SC2016  # ${Conffiles} is a dpkg-query field, not a shell variable
		dpkg-query -W -f='${Conffiles}\n' "$p" 2>/dev/null | awk -v f="$1" '$1 == f { print $2; exit }'
	done | awk 'NF { print; exit }' || true
}

file_md5() { md5sum <"$1" 2>/dev/null | cut -d' ' -f1 || true; }

# 0 only for the stock package config: nginx.conf may then be replaced
nginx_pristine() {
	local want f
	# anything but the package page in /var/www/html is the owner's content
	if [[ -n $(find /var/www/html -mindepth 1 ! -path /var/www/html/index.nginx-debian.html -print -quit 2>/dev/null) ]]; then
		return 1
	fi
	want=$(pkg_conf_md5 "$NGX_MAIN")
	[[ -n $want && $(file_md5 "$NGX_MAIN") == "$want" ]] || return 1
	for f in "$NGX_DIR"/sites-enabled/* "$NGX_DIR"/conf.d/*; do
		if [[ ! -e $f && ! -L $f ]]; then continue; fi
		if [[ $f == */sites-enabled/default ]]; then continue; fi
		return 1
	done
	want=$(pkg_conf_md5 "$NGX_DIR/sites-available/default")
	for f in "$NGX_DIR/sites-available/default" "$NGX_DIR/sites-enabled/default"; do
		if [[ -e $f ]]; then
			[[ -n $want && $(file_md5 "$f") == "$want" ]] || return 1
		fi
	done
	if grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$NGX_MAIN"; then return 1; fi
	return 0
}

# Own mode (nginx.conf replaced) only when certainly safe, else shared (an include is added).
# Runs before apt: it must know whether nginx was there.
detect_mode() {
	NGINX_WAS=0
	if [[ -f $NGX_MAIN ]]; then NGINX_WAS=1; fi
	# NGINX_FRESH: the installer put nginx there (kept on reconfigure): uninstall then switches it off.
	# The mark file is written right after apt, so a first run that failed later still counts.
	if ((!NGINX_WAS)) || [[ -e $NGX_FRESH_MARK ]]; then
		NGINX_FRESH=y
	else
		NGINX_FRESH=${D[NGINX_FRESH]:-n}
	fi
	if ((!NGINX_WAS)); then
		NGINX_MODE=own NGINX_WHY=fresh
	elif [[ $(head -n1 "$NGX_MAIN" 2>/dev/null || true) == "# nginx-stream - "* ]]; then
		NGINX_MODE=${D[NGINX_MODE]:-own} NGINX_WHY=ours
	elif [[ ${D[NGINX_MODE]:-} == own ]]; then
		# own mode chosen, but nginx.conf is no longer ours: do not replace it
		NGINX_MODE=shared NGINX_WHY=changed
	elif [[ -n ${D[NGINX_MODE]:-} ]]; then
		NGINX_MODE=${D[NGINX_MODE]} NGINX_WHY=settings
	elif nginx_pristine; then
		NGINX_MODE=own NGINX_WHY=pristine
	else
		NGINX_MODE=shared NGINX_WHY=foreign
	fi
}

check_no_foreign_stream() {
	local found
	found=$(grep -rEl '^[[:space:]]*stream[[:space:]]*\{' "$NGX_MAIN" "$NGX_DIR/conf.d" "$NGX_DIR/sites-enabled" 2>/dev/null || true)
	if [[ -n $found ]]; then
		die "В конфигурации nginx уже есть блок stream (${found//$'\n'/ }): nginx не принимает второй. Перенесите правила туда вручную или уберите блок." \
			"nginx already has a stream block (${found//$'\n'/ }): nginx does not accept a second one. Move the rules there manually or remove the block."
	fi
}

preflight_rules() {
	local rule proto lip lp host tp src sni h lp_s
	local -A probed=()
	load_prev_listen
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		h=$(strip_brackets "$host")
		if [[ $h == *:* && $HAVE_IPV6 != y ]]; then
			die "Цель $h - IPv6, а у сервера нет глобального IPv6. Нужен IPv4-адрес цели или IPv6 на этом сервере." \
				"Target $h is IPv6, but this server has no global IPv6. Use an IPv4 target or get IPv6 on this server."
		fi
		if [[ $lip != "*" ]]; then
			if [[ $lip == "["* && $HAVE_IPV6 != y ]]; then
				die "Адрес слушания $lip - IPv6, а у сервера нет глобального IPv6." "Listen address $lip is IPv6, but this server has no global IPv6."
			fi
			if ! has_local_addr "$lip"; then
				die "Адреса слушания $lip нет на этом сервере (ip -o addr)." "The listen address $lip is not on this server (ip -o addr)."
			fi
		fi
		if [[ $src != "-" ]]; then
			if [[ $src == "["* && $HAVE_IPV6 != y ]]; then
				die "Исходящий адрес $src - IPv6, а у сервера нет глобального IPv6." "Outgoing address $src is IPv6, but this server has no global IPv6."
			fi
			if ! has_local_addr "$src"; then
				die "Исходящего адреса $src (@) нет на этом сервере (ip -o addr)." "The outgoing address $src (@) is not on this server (ip -o addr)."
			fi
		fi
		lp_s=$(fmt_lp "$lip" "$lp")
		if port_busy "$proto" "$lp" "$lip"; then
			if [[ $BUSY_BY == nginx ]]; then
				die "Порт $lp_s/$proto уже слушает сам nginx (сайт или другая настройка): выберите другой порт." \
					"Port $lp_s/$proto is already listened on by nginx itself (a site or other config): choose another port."
			fi
			die "Порт $lp_s/$proto уже занят другой программой (ss -lnp)." "Port $lp_s/$proto is already used by another program (ss -lnp)."
		fi
		if [[ $proto == tcp && -z ${probed[$h:$tp]:-} ]]; then
			probed[$h:$tp]=1
			# shellcheck disable=SC2016  # $1 $2 are expanded by the inner bash
			if ! timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$h" "$tp" 2>/dev/null; then
				warn "Цель $h:$tp не отвечает с этого сервера (TCP). Продолжаю, проверьте позже." \
					"Target $h:$tp does not answer from this server (TCP). Continuing, check it later."
			fi
		fi
	done
	if [[ $LISTEN == v4v6 && $HAVE_IPV6 != y ]]; then
		warn "У сервера нет глобального IPv6: слушаю только IPv4." "The server has no global IPv6: listening on IPv4 only."
		LISTEN=v4
	fi
	if [[ $NGINX_MODE == shared ]]; then check_no_foreign_stream; fi
}

apt_busy() {
	if command -v fuser >/dev/null 2>&1; then
		fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1
	else
		pgrep -x 'apt|apt-get|dpkg' >/dev/null 2>&1
	fi
}

wait_apt() {
	local i
	# fresh cloud VM: cloud-init may hold the apt locks
	if command -v cloud-init >/dev/null 2>&1 && [[ $(cloud-init status 2>/dev/null || true) == *"status: running"* ]]; then
		step "cloud-init ещё настраивает систему, жду его завершения (до 10 минут)..." "cloud-init is still setting the system up, waiting for it (up to 10 minutes)..."
		timeout 600 cloud-init status --wait >/dev/null 2>&1 || true
	fi
	# the first unattended-upgrade run on a fresh VM can take minutes
	for ((i = 0; i < 600; i += 5)); do
		if ! apt_busy; then return 0; fi
		if ((i == 0)); then
			step "apt/dpkg занят (обычно это автообновление), жду до 10 минут..." "apt/dpkg is busy (usually automatic updates), waiting up to 10 minutes..."
		elif ((i % 60 == 0)); then
			dim "  всё ещё жду apt/dpkg: прошло $((i / 60)) мин из 10..." "  still waiting for apt/dpkg: $((i / 60)) of 10 minutes passed..."
		fi
		sleep 5
	done
	die "apt/dpkg занят дольше 10 минут. Повторите позже." "apt/dpkg has been busy for more than 10 minutes. Try again later."
}

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == "install ok installed" ]]; }

# security updates on, as dpkg-reconfigure unattended-upgrades does, without the dpkg lock
enable_auto_updates() {
	local f=/etc/apt/apt.conf.d/20auto-upgrades
	local want=$'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";'
	if [[ $(cat "$f" 2>/dev/null || true) != "$want" ]]; then printf '%s\n' "$want" >"$f"; fi
}

install_packages() {
	local -a pkgs=() missing=()
	local p v=""
	# a stock nginx (or one built by hand) is not replaced by the package
	if ! command -v nginx >/dev/null 2>&1 && ! pkg_installed nginx; then pkgs+=(nginx); fi
	# stream module: needed unless nginx has it built in (nginx.org: --with-stream)
	if command -v nginx >/dev/null 2>&1; then v=$(nginx -V 2>&1 || true); fi
	if [[ -z $v || $v == *--with-stream=dynamic* || ! $v =~ --with-stream([[:space:]]|$) ]]; then
		pkgs+=(libnginx-mod-stream)
	fi
	if need_firewall; then pkgs+=(nftables); fi
	if [[ $AUTO_UPDATES == y ]]; then pkgs+=(unattended-upgrades); fi
	for p in "${pkgs[@]}"; do
		if ! pkg_installed "$p"; then missing+=("$p"); fi
	done
	if ((${#missing[@]} == 0)); then
		# reconfigure: everything is there; apt is not needed (and may be busy)
		if [[ $AUTO_UPDATES == y ]]; then enable_auto_updates; fi
		return 0
	fi
	wait_apt
	export DEBIAN_FRONTEND=noninteractive
	step "Ставлю пакеты: ${missing[*]}" "Installing packages: ${missing[*]}"
	# a broken third-party repository must not stop the install
	apt-get update || warn "apt-get update завершился с ошибкой, продолжаю." "apt-get update failed, continuing."
	# no stock site on a fresh nginx: port 80 may be taken (apache) and postinst would fail;
	# nginx is started later with our config
	if ((!NGINX_WAS)) && [[ ! -e $POLICY_RC ]]; then
		printf '#!/bin/sh\nexit 101\n' >"$POLICY_RC"
		chmod 755 "$POLICY_RC"
		POLICY_SET=1
	fi
	apt-get install -y -o Dpkg::Options::=--force-confold "${missing[@]}" ||
		die "Не удалось установить пакеты (apt-get install)." "Could not install the packages (apt-get install)."
	drop_policy_rc
	if ((!NGINX_WAS)); then
		mkdir -p "$STATE_DIR"
		: >"$NGX_FRESH_MARK"
	fi
	if [[ $AUTO_UPDATES == y ]] && systemctl cat unattended-upgrades.service >/dev/null 2>&1; then
		systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
	fi
	if [[ ! -e /usr/lib/nginx/modules/ngx_stream_module.so && $(nginx -V 2>&1) != *with-stream* ]]; then
		die "В nginx нет модуля stream." "nginx has no stream module."
	fi
	if has_sni && [[ $(nginx -V 2>&1) != *stream_ssl_preread_module* ]]; then
		die "Для правил с именем нужен модуль ssl_preread (stream_ssl_preread_module), а nginx собран без него." \
			"Rules with a name need the ssl_preread module (stream_ssl_preread_module), but this nginx is built without it."
	fi
	if [[ $AUTO_UPDATES == y ]]; then enable_auto_updates; fi
}

detect_ssh_port() {
	local p
	if command -v sshd >/dev/null 2>&1; then
		# every "port" line: sshd may listen on several ports
		p=$(sshd -T 2>/dev/null | awk '/^port [0-9]+$/{print $2}' | sort -un | paste -sd' ' - || true)
		if [[ $p =~ ^[0-9]+( [0-9]+)*$ ]]; then
			printf '%s' "$p"
			return 0
		fi
	fi
	printf 22
}

detect_bbr() {
	modprobe tcp_bbr >/dev/null 2>&1 || true
	if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then printf y; else printf n; fi
}

# not "ufw status | grep -q": under pipefail grep exits early and ufw dies of SIGPIPE
ufw_active() { command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; }

firewalld_active() { systemctl is-active --quiet firewalld 2>/dev/null; }

# put_file SRC DST MODE (backup beside the old file; unchanged files are skipped)
put_file() {
	local src=$1 dst=$2 mode=$3
	mkdir -p "$(dirname "$dst")"
	if [[ -e $dst ]]; then
		if cmp -s "$src" "$dst"; then return 0; fi
		cp -a "$dst" "$dst.nginx-stream-bak"
		BAKS+=("$dst")
	else
		NEWS+=("$dst")
	fi
	if [[ $dst == "$NGX_MAIN" ]]; then
		put_in_place "$src" "$dst"
	else
		install -m "$mode" "$src" "$dst"
	fi
}

# in place: a symlink, owner and mode stay as they were
put_in_place() { cat "$1" >"$2"; }

rollback_files() {
	local f
	for f in "${BAKS[@]}"; do
		if [[ ! -e $f.nginx-stream-bak ]]; then continue; fi
		if [[ $f == "$NGX_MAIN" ]]; then
			put_in_place "$f.nginx-stream-bak" "$f" && rm -f "$f.nginx-stream-bak"
		else
			mv -f "$f.nginx-stream-bak" "$f"
		fi
	done
	for f in "${NEWS[@]}"; do rm -f "$f"; done
	BAKS=() NEWS=()
}

# Restore the pre-run state (files, default site, units) and start the old nginx.
rollback_apply() {
	APPLIED=0
	if ((PORTS_TOUCHED)); then systemctl disable --now nginx-stream-ports.service >/dev/null 2>&1 || true; fi
	rollback_files
	if ((DEFAULT_UNLINKED)) && [[ ! -e $NGX_DIR/sites-enabled/default && -n $DEFAULT_LINK ]]; then
		ln -s "$DEFAULT_LINK" "$NGX_DIR/sites-enabled/default" || true
	fi
	systemctl daemon-reload || true
	if ((FW_TOUCHED)); then
		if [[ -e $FIREWALL_UNIT ]]; then
			systemctl restart nginx-stream-firewall.service || true
		else
			systemctl disable --now nginx-stream-firewall.service >/dev/null 2>&1 || true
			# shellcheck disable=SC2086  # NFT_TABLE is "family name": two words on purpose
			nft delete table $NFT_TABLE >/dev/null 2>&1 || true
		fi
	fi
	if ((PORTS_TOUCHED)) && [[ -e $PORTS_UNIT ]]; then
		systemctl enable nginx-stream-ports.service >/dev/null 2>&1 || true
		systemctl restart nginx-stream-ports.service || true
	fi
	if ((RESTART_TRIED)); then systemctl restart nginx || true; fi
	warn "Установка не удалась: прежние файлы возвращены." "The install failed: previous files restored."
}

# apply_failed RU EN: roll back, show why nginx failed, exit with an error
apply_failed() {
	local j
	j=$(journalctl -u nginx -n 20 --no-pager 2>&1 || true)
	rollback_apply
	if [[ -n $j ]]; then printf '%s\n' "$j" >&2; fi
	die "$1" "$2"
}

drop_backups() {
	local f
	for f in "${BAKS[@]}"; do rm -f "$f.nginx-stream-bak"; done
}

deploy_files() {
	local s=$1 out
	APPLIED=1
	if [[ $NGINX_MODE == own && -f $NGX_MAIN && ! -e $NGX_MAIN_BACKUP ]]; then
		cp -a "$NGX_MAIN" "$NGX_MAIN_BACKUP"
	fi
	put_file "$s/nginx.conf" "$NGX_MAIN" 644
	put_file "$s/nginx-stream.conf" "$NGX_STREAM_CONF" 644
	put_file "$s/nginx-service-override.conf" "$NGX_OVERRIDE" 644
	if [[ $TUNE == y ]]; then
		put_file "$s/90-nginx-stream.conf" "$SYSCTL_FILE" 644
		if [[ $BBR == y ]]; then put_file "$s/modules-load-nginx-stream.conf" "$MODLOAD_FILE" 644; fi
	fi
	if need_firewall; then
		put_file "$s/firewall.nft" "$FIREWALL_FILE" 644
		put_file "$s/nginx-stream-firewall.service" "$FIREWALL_UNIT" 644
	fi
	put_file "$s/ports.sh" "$PORTS_SCRIPT" 755
	put_file "$s/nginx-stream-ports.service" "$PORTS_UNIT" 644
	put_file "$s/nftables-service-nginx-stream.conf" "$NFT_DROPIN" 644
	if ! out=$(nginx -t 2>&1); then
		rollback_apply
		printf '%s\n' "$out" >&2
		die "nginx -t не прошёл, прежние файлы возвращены." "nginx -t failed, previous files restored."
	fi
}

remove_firewall() {
	if [[ -e $FIREWALL_UNIT ]]; then
		systemctl disable --now nginx-stream-firewall.service >/dev/null 2>&1 || true
		rm -f "$FIREWALL_UNIT"
	fi
	# shellcheck disable=SC2086  # NFT_TABLE is "family name": two words on purpose
	nft delete table $NFT_TABLE >/dev/null 2>&1 || true
	rm -f "$FIREWALL_FILE"
}

remove_tuning() {
	rm -f "$SYSCTL_FILE" "$MODLOAD_FILE"
}

# TCP ports < 10000 listening now: their RST must stay under scan protection
listening_tcp_ports() {
	ss -Hlnt 2>/dev/null | awk '{ n = split($4, a, ":"); p = a[n]; if (p ~ /^[0-9]+$/ && p < 10000) print p }' |
		sort -un | paste -sd' ' - || true
}

# TCP ports >= 10000 listening now: the ephemeral range must not take them. Not UDP: ss lists every
# unconnected UDP socket, client ones too. Own mode skips nginx sockets: they are the previous rules.
listening_high_ports() {
	local skip=0
	if [[ $NGINX_MODE == own ]]; then skip=1; fi
	ss -Hlntp 2>/dev/null | awk -v skip="$skip" '
		skip == 1 && /"nginx"/ { next }
		{ n = split($4, a, ":"); p = a[n]; if (p ~ /^[0-9]+$/ && p >= 10000) print p }' |
		sort -un | paste -sd' ' - || true
}

# UFW_RULES: rules this installer adds or added before; a rule that already exists is not ours
plan_ufw() {
	local r added prev=" ${D[UFW_RULES]:-} "
	UFW_RULES=""
	if ! ufw_active; then
		# ufw is off: earlier rules stay on record (they apply again with ufw)
		if command -v ufw >/dev/null 2>&1; then UFW_RULES=${D[UFW_RULES]:-}; fi
		return 0
	fi
	added=$(ufw show added 2>/dev/null || true)
	for r in $(rule_ports); do
		if [[ $prev == *" $r "* ]] || ! grep -qE "^ufw allow $r( |\$)" <<<"$added"; then
			UFW_RULES+="${UFW_RULES:+ }$r"
		fi
	done
}

sync_ufw() {
	local r old=${D[UFW_RULES]:-}
	for r in $old; do
		if [[ " $UFW_RULES " != *" $r "* ]]; then ufw delete allow "$r" >/dev/null 2>&1 || true; fi
	done
	for r in $UFW_RULES; do
		ufw allow "$r" comment nginx-stream >/dev/null ||
			warn "Не удалось добавить правило ufw для $r: добавьте его сами (ufw allow $r)." "Could not add the ufw rule for $r: add it yourself (ufw allow $r)."
	done
}

# PORT_TOKENS = "proto:port:fam" of the relay listens (fam 4, 6 or 46), unique. ports.sh decides at
# every start whether to open them, not here: a firewall switched on later is picked up.
plan_ports() {
	local rule proto lip lp host tp src sni f t
	local -A seen=()
	PORT_TOKENS=""
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		if [[ $lip == "["* ]]; then
			f=6
		elif [[ $lip == "*" && $LISTEN == v4v6 ]]; then
			f=46
		else
			f=4
		fi
		t="$proto:$lp:$f"
		if [[ -n ${seen[$t]:-} ]]; then continue; fi
		seen[$t]=1
		PORT_TOKENS+="${PORT_TOKENS:+ }$t"
	done
}

# Our rules are restored by our own unit: other tools (netfilter-persistent) save a snapshot of the
# whole ruleset, with docker's dynamic chains in it.
remove_ports_service() {
	if [[ -e $PORTS_UNIT || -e $PORTS_SCRIPT ]]; then
		systemctl disable --now nginx-stream-ports.service >/dev/null 2>&1 || true
		if [[ -x $PORTS_SCRIPT ]]; then "$PORTS_SCRIPT" down >/dev/null 2>&1 || true; fi
	fi
	rm -f "$PORTS_UNIT" "$PORTS_SCRIPT" "$NFT_DROPIN"
	rmdir "$(dirname "$NFT_DROPIN")" 2>/dev/null || true
}

# Our rules now in iptables and nftables
count_port_rules() {
	local n=0 bin
	for bin in iptables ip6tables; do
		if command -v "$bin" >/dev/null 2>&1; then
			n=$((n + $("$bin" -w 5 -S INPUT 2>/dev/null | grep -cE -e "$IPT_MARK_RE" || true)))
		fi
	done
	# iptables-nft rules also show in nft (ip/ip6 filter INPUT): already counted above
	if command -v nft >/dev/null 2>&1; then
		n=$((n + $(nft list ruleset 2>/dev/null | awk -v m="$NFT_MARK_RE" '
			$1 == "table" { fam = $2 }
			$1 == "chain" { ch = $2 }
			index($0, m) && !(fam != "inet" && ch == "INPUT") { c++ }
			END { print c + 0 }')))
	fi
	printf '%s' "$n"
}

# Some DROP/REJECT in iptables or a foreign nft input filter (not our table) and none of our rules added:
# the relay ports may be closed by a rule the ports service does not take for a final one.
input_drops_seen() {
	local bin s=""
	for bin in iptables ip6tables; do
		if command -v "$bin" >/dev/null 2>&1; then s+=$("$bin" -w 5 -S INPUT 2>/dev/null || true)$'\n'; fi
	done
	if [[ $s =~ -j\ (DROP|REJECT)|-P\ INPUT\ DROP ]]; then return 0; fi
	command -v nft >/dev/null 2>&1 || return 1
	nft list ruleset 2>/dev/null | awk '
		$1 == "table" { t = $2 " " $3; inp = 0 }
		$1 == "chain" { inp = 0 }
		/type filter hook input/ { inp = (t != "inet nginx_stream") }
		inp && /(^|[ \t])(drop|reject)([ \t;]|$)/ { f = 1 }
		END { exit !f }'
}

# Lines with our comment in the owner's saved rules (iptables-persistent) would come back at boot
strip_saved_ipt() {
	local f tmp
	for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
		if [[ ! -f $f ]] || ! grep -qE -e "$IPT_MARK_RE" "$f"; then continue; fi
		tmp=$(mktemp)
		grep -vE -e "$IPT_MARK_RE" "$f" >"$tmp" || true
		cat "$tmp" >"$f"
		rm -f "$tmp"
	done
	if [[ -f $NFTABLES_CONF ]] && grep -qF -e "$NFT_MARK_RE" "$NFTABLES_CONF"; then
		tmp=$(mktemp)
		grep -vF -e "$NFT_MARK_RE" "$NFTABLES_CONF" >"$tmp" || true
		cat "$tmp" >"$NFTABLES_CONF"
		rm -f "$tmp"
	fi
}

verify_listening() {
	local rule proto lip lp host tp src sni bad=0 i
	local -A seen=()
	for rule in "${RULES[@]}"; do
		read -r proto lip lp host tp src sni <<<"$rule"
		if [[ -n ${seen[$proto $lip $lp]:-} ]]; then continue; fi
		seen[$proto $lip $lp]=1
		for ((i = 0; i < 10; i++)); do
			if port_listening "$proto" "$lp" "$lip"; then break; fi
			sleep 1
		done
		if port_listening "$proto" "$lp" "$lip"; then
			ok "  $(fmt_lp "$lip" "$lp")/$proto  ok" "  $(fmt_lp "$lip" "$lp")/$proto  ok"
		else
			bad "  $(fmt_lp "$lip" "$lp")/$proto  nginx не слушает" "  $(fmt_lp "$lip" "$lp")/$proto  nginx is not listening"
			bad=1
		fi
	done
	return "$bad"
}

# fetch_self DEST: download the installer (20 s limit)
fetch_self() {
	if command -v wget >/dev/null 2>&1; then
		timeout 25 wget -q --inet4-only -T 20 -t 1 -O "$1" "$SELF_URL"
	elif command -v curl >/dev/null 2>&1; then
		timeout 25 curl -fsSL -4 --max-time 20 -o "$1" "$SELF_URL"
	else
		return 1
	fi
}

# How to rerun the installer: the kept copy, else the one-liner.
self_cmd() {
	if ((SELF_KEPT)); then printf 'nginx-stream'; else printf 'bash <(wget -qO- --inet4-only %s)' "$SELF_URL"; fi
}

# Keep a copy as $SELF_PATH. Under `bash <(wget ...)` $0 is /dev/fd/N (unreadable twice), under
# `curl | bash` it is just "bash" (a stray file of that name may exist): then download.
install_self() {
	local src="" tmp="$STAGE/self.sh"
	SELF_KEPT=0
	if [[ -f $0 && $0 != /dev/fd/* && $0 != /proc/self/fd/* && $(head -c 2 "$0" 2>/dev/null || true) == '#!' ]] &&
		grep -q '^readonly INSTALLER_VER=' "$0" 2>/dev/null; then
		src=$0
	elif fetch_self "$tmp" && bash -n "$tmp" && [[ $(head -c 2 "$tmp" 2>/dev/null || true) == '#!' ]]; then
		src=$tmp
	fi
	if [[ -n $src ]]; then
		if [[ $src -ef $SELF_PATH ]] || install -m 755 "$src" "$SELF_PATH"; then
			SELF_KEPT=1
			return 0
		fi
	fi
	warn "Копию установщика сохранить не удалось: для перенастройки и удаления запускайте однострочник из README." \
		"Could not keep a copy of the installer: to reconfigure or uninstall run the one-liner from the README."
}

apply() {
	local mem
	STAGE=$(mktemp -d)
	mem=$(awk '/^MemTotal:/{print int($2 / 1024)}' /proc/meminfo)
	RAM_MB=$mem
	SSH_PORT=$(detect_ssh_port)
	BBR=n
	if [[ $TUNE == y ]]; then BBR=$(detect_bbr); fi
	# shared mode leaves sites alone, also a link the owner put back with their own nginx.conf
	DEFAULT_SITE_REMOVED=n
	if [[ $NGINX_MODE == own && -L $NGX_DIR/sites-enabled/default ]]; then DEFAULT_SITE_REMOVED=y; fi
	if [[ $NGINX_MODE == own && ${D[DEFAULT_SITE_REMOVED]:-} == y ]]; then DEFAULT_SITE_REMOVED=y; fi
	plan_ufw
	plan_ports
	if [[ $SCAN_PROTECT == y ]]; then OPEN_TCP=$(listening_tcp_ports); fi
	if [[ $TUNE == y ]]; then OPEN_HIGH=$(listening_high_ports); fi

	step "Записываю настройки и запускаю nginx..." "Writing the settings and starting nginx..."
	render_all "$STAGE"
	if need_firewall && ! nft -c -f "$STAGE/firewall.nft" 2>"$STAGE/nft.err"; then
		warn "nft не принял правила защиты, защита отключена: $(tr '\n' ' ' <"$STAGE/nft.err")" \
			"nft rejected the protection rules, protection disabled: $(tr '\n' ' ' <"$STAGE/nft.err")"
		SSH_PROTECT=n
		SCAN_PROTECT=n
		render_all "$STAGE"
	fi

	mkdir -p "$STATE_DIR"
	deploy_files "$STAGE"
	systemctl daemon-reload
	if [[ $DEFAULT_SITE_REMOVED == y && -L $NGX_DIR/sites-enabled/default ]]; then
		DEFAULT_LINK=$(readlink "$NGX_DIR/sites-enabled/default")
		DEFAULT_UNLINKED=1
		rm -f "$NGX_DIR/sites-enabled/default"
	fi
	if [[ $TUNE == y ]]; then sysctl -e -p "$SYSCTL_FILE" >/dev/null || true; fi
	systemctl enable nginx >/dev/null 2>&1
	RESTART_TRIED=1
	systemctl restart nginx ||
		apply_failed "nginx не запустился, прежние файлы возвращены." "nginx failed to start, previous files restored."
	if need_firewall; then
		FW_TOUCHED=1
		systemctl enable nginx-stream-firewall.service >/dev/null 2>&1
		systemctl restart nginx-stream-firewall.service
	fi
	PORTS_TOUCHED=1
	systemctl enable nginx-stream-ports.service >/dev/null 2>&1
	systemctl restart nginx-stream-ports.service ||
		warn "Не удалось открыть порты в фаерволе: $(journalctl -u nginx-stream-ports -n 5 --no-pager 2>&1 | tr '\n' ' ')" \
			"Could not open the ports in the firewall: $(journalctl -u nginx-stream-ports -n 5 --no-pager 2>&1 | tr '\n' ' ')"
	step "Проверяю порты:" "Checking the ports:"
	verify_listening ||
		apply_failed "Не все порты открыты, прежние файлы возвращены." "Not all ports are open, previous files restored."
	# verified: settings are saved last, then nothing is rolled back; what is switched off is removed only
	# after that (a signal in between would roll back files the rollback cannot bring back)
	put_file "$STAGE/settings.env" "$SETTINGS_FILE" 600
	APPLIED=0
	drop_backups
	if ! need_firewall; then remove_firewall; fi
	if [[ $TUNE != y ]]; then remove_tuning; fi
	if ufw_active; then
		sync_ufw
	elif firewalld_active; then
		warn "Активен firewalld: откройте порты ${UFW_RULES:-$(rule_ports)} сами." "firewalld is active: open the ports ${UFW_RULES:-$(rule_ports)} yourself."
	fi
	install_self
}

# ---------------------------------------------------------------- status / uninstall / menu

status() {
	local i j proto lip lp host tp src sni n gk
	local -A gseen=()
	require_root
	load_settings_globals
	build_rules
	group_info
	n=$(systemctl is-active nginx 2>&1 || true)
	say "nginx: $(stc "$n")" "nginx: $(stc "$n")"
	hdr "Порты:" "Ports:"
	for ((i = 0; i < ${#RULES[@]}; i++)); do
		read -r proto lip lp host tp src sni <<<"${RULES[i]}"
		gk="$proto $lip $lp"
		if [[ -n ${gseen[$gk]:-} ]]; then continue; fi
		gseen[$gk]=1
		if port_listening "$proto" "$lp" "$lip"; then n=$(stc up); else n=$(stc DOWN); fi
		if [[ $proto == tcp ]]; then
			n="$n, $(ss -Htn state established "( sport = :$lp )" 2>/dev/null | wc -l) conn"
		fi
		if [[ -n ${GNAMED[$gk]:-} ]]; then
			# named group: state once, destinations below
			printf '  %s %s  [%s]\n' "$proto" "$(fmt_lp "$lip" "$lp")" "$n"
			for ((j = 0; j < ${#RULES[@]}; j++)); do
				if [[ ${RULES[j]} == "$proto $lip $lp "* ]]; then printf '    %s\n' "$(rule_line "$j" sub)"; fi
			done
		else
			printf '  %s  [%s]\n' "$(rule_line "$i")" "$n"
		fi
	done
	say "UDP-сокетов nginx: $(ss -Hlnup 2>/dev/null | grep -c '"nginx"' || true)" "nginx UDP sockets: $(ss -Hlnup 2>/dev/null | grep -c '"nginx"' || true)"
	if need_firewall; then
		# the oneshot unit stays active after "flush ruleset": ask nft for the table itself
		# shellcheck disable=SC2086  # NFT_TABLE is "family name": two words on purpose
		if nft list table $NFT_TABLE >/dev/null 2>&1; then
			say "Таблица защит nft: ${C_GRN}есть${C_OFF}" "Protection nft table: ${C_GRN}present${C_OFF}"
		else
			bad "Таблица защит nft: нет (systemctl restart nginx-stream-firewall)" "Protection nft table: missing (systemctl restart nginx-stream-firewall)"
		fi
	fi
	n=$(count_port_rules)
	local svc
	svc=$(stc "$(systemctl is-active nginx-stream-ports.service 2>&1 || true)")
	say "Служба портов: $svc, правил открыто: $n" "Ports service: $svc, rules open: $n"
	hdr "Настройки ($SETTINGS_FILE):" "Settings ($SETTINGS_FILE):"
	grep -v '^#' "$SETTINGS_FILE" | sed 's/^/  /'
}

uninstall() {
	local r tmp rm_pkg=0 p
	local -a pkgs=()
	require_root
	load_settings_globals
	# the only question, asked before any change; end of input means "no"
	if [[ $NGINX_MODE == shared ]]; then
		# purge would take /etc/nginx with the other sites
		say "nginx обслуживает и другие сайты - пакет оставлен." "nginx serves other sites too - the package is kept."
	elif confirm "Удалить и пакет nginx? purge удалит весь /etc/nginx" "Remove the nginx package too? purge deletes the whole /etc/nginx" n soft; then
		rm_pkg=1
	fi
	step "Удаляю nginx-stream..." "Removing nginx-stream..."
	remove_firewall
	remove_ports_service
	strip_saved_ipt
	if [[ -e $SYSCTL_FILE ]]; then
		say "Значения ядра останутся до перезагрузки." "Kernel values stay until reboot."
	fi
	remove_tuning
	rm -f "$NGX_OVERRIDE"
	rmdir "$(dirname "$NGX_OVERRIDE")" 2>/dev/null || true
	systemctl daemon-reload
	if [[ $NGINX_MODE == shared ]]; then
		if [[ -f $NGX_MAIN ]]; then
			tmp=$(mktemp)
			sed -e "\|^$INCLUDE_MARK\$|d" -e "\|^$NGX_INCLUDE_LINE\$|d" "$NGX_MAIN" >"$tmp"
			put_in_place "$tmp" "$NGX_MAIN"
			rm -f "$tmp"
		fi
		# left from an own-mode install that was switched to shared
		rm -f "$NGX_MAIN_BACKUP"
	else
		if [[ -f $NGX_MAIN_BACKUP ]]; then
			put_in_place "$NGX_MAIN_BACKUP" "$NGX_MAIN"
			rm -f "$NGX_MAIN_BACKUP"
		else
			warn "Копии nginx.conf.before-nginx-stream нет: nginx.conf оставлен как есть." "nginx.conf.before-nginx-stream is missing: nginx.conf left as is."
		fi
		if [[ $DEFAULT_SITE_REMOVED == y && -e $NGX_DIR/sites-available/default && ! -e $NGX_DIR/sites-enabled/default ]]; then
			ln -s ../sites-available/default "$NGX_DIR/sites-enabled/default"
		fi
	fi
	rm -f "$NGX_STREAM_CONF"
	if command -v ufw >/dev/null 2>&1; then
		for r in $UFW_RULES; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
	fi
	if ((rm_pkg)); then
		wait_apt
		systemctl stop nginx >/dev/null 2>&1 || true
		for p in nginx nginx-core nginx-common libnginx-mod-stream; do
			if dpkg -s "$p" >/dev/null 2>&1; then pkgs+=("$p"); fi
		done
		if ((${#pkgs[@]})); then
			DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
		fi
	elif [[ $NGINX_MODE != shared && ${NGINX_FRESH:-n} == y ]]; then
		systemctl disable --now nginx >/dev/null 2>&1 || true
		say "nginx остановлен и выключен: до установки его не было." "nginx is stopped and disabled: it was not there before the install."
	elif nginx -t >/dev/null 2>&1; then
		systemctl restart nginx ||
			warn "nginx не перезапустился: проверьте systemctl status nginx." "nginx did not restart: check systemctl status nginx."
	else
		warn "nginx -t не проходит после удаления: проверьте конфигурацию вручную." "nginx -t fails after removal: check the configuration manually."
	fi
	rm -rf "$STATE_DIR" "$SELF_PATH"
	ok "Удалено." "Removed."
}

show_menu() {
	local c
	printf '\n'
	hdr "Прокладка уже установлена. Что сделать?" "The relay is already installed. What to do?"
	opt 1 "$(msg "Перенастроить" "Reconfigure")"
	opt 2 "$(msg "Состояние" "Status")"
	opt 3 "$(msg "Удалить" "Uninstall")"
	opt 4 "$(msg "Выход" "Quit")"
	read -r -e -p "$RL_CYAN>$RL_OFF " -i 1 c || die "Ввод прерван" "Input aborted"
	case $c in
	1) return 0 ;;
	2)
		status
		exit 0
		;;
	3)
		uninstall
		exit 0
		;;
	*) exit 0 ;;
	esac
}

# ---------------------------------------------------------------- install / dry-run

run_dry() {
	local f
	NGINX_MODE=own
	DEFAULT_SITE_REMOVED=n
	UFW_RULES=""
	SSH_PORT=22
	BBR=y
	RAM_MB=${RAM_MB:-1024}
	v_ram "$RAM_MB" || bad_value --ram-mb
	NGINX_FRESH=y
	plan_ports
	# replace only render_all's files: the directory may hold anything else
	for f in nginx.conf nginx-stream.conf nginx-service-override.conf 90-nginx-stream.conf modules-load-nginx-stream.conf \
		firewall.nft nginx-stream-firewall.service ports.sh nginx-stream-ports.service nftables-service-nginx-stream.conf settings.env; do
		rm -f "${OUT_DIR:?}/$f"
	done
	render_all "$OUT_DIR"
	say "Файлы собраны в $OUT_DIR (система не тронута):" "Files written to $OUT_DIR (system untouched):"
	for f in "$OUT_DIR"/*; do printf '  %s\n' "$f"; done
}

run_install() {
	require_root
	detect_mode
	ask_lang
	preflight_system
	ask_all
	build_rules
	preflight_rules
	show_choices
	confirm "Продолжить?" "Continue?" y || die "Остановлено." "Stopped."
	install_packages
	apply
	final_report
}

main() {
	init_colors
	parse_args "$@"
	case $UI_LANG in
	"" | ru | en) ;;
	*) die "--lang: ru | en" "--lang: ru | en" ;;
	esac
	if [[ $ACTION == help ]]; then
		print_help
		return 0
	fi
	if ((DRY_RUN)) && [[ -n $ACTION ]]; then
		die "--dry-run нельзя сочетать с --$ACTION" "--dry-run cannot be combined with --$ACTION"
	fi
	init_defaults
	if ((!DRY_RUN)); then
		if [[ $ACTION == status || $ACTION == uninstall ]]; then require_root; fi
		detect_env_defaults
		load_previous
	else
		detect_env_defaults
	fi
	case $ACTION in
	status)
		status
		return 0
		;;
	uninstall)
		setup_tty soft
		uninstall
		return 0
		;;
	*) ;;
	esac
	setup_tty
	if ((!YES)); then banner; fi
	if ((PREV_INSTALLED && !YES)); then
		local keep=$UI_LANG
		if [[ -z $UI_LANG ]]; then UI_LANG=${D[UI_LANG]:-ru}; fi
		show_menu
		UI_LANG=$keep
	fi
	if ((DRY_RUN)); then
		ask_all
		build_rules
		run_dry
	else
		run_install
	fi
}

main "$@"
