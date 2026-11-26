#!/bin/sh
# nginx-stream: opens the relay ports in iptables and in foreign nftables input chains (rules marked nginx-stream)
PORTS='udp:443:4 tcp:443:4 tcp:8443:6 tcp:2222:46'
rc=0

# ports_for FAMILY: proto:port of the tokens that fit the table family (4, 6 or 46), without duplicates
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

# Where the ACCEPT goes: not first (it would bypass the owner's bans "-s X -j DROP" and block sets), but where the
# chain would close the port: before its final catch-all DROP/REJECT, or at the end if only the policy is DROP.
# A chain that accepts by default and has no final catch-all drop has the ports open already: nothing is added.

# ipt_up BIN FAMILY
ipt_up() {
	command -v "$1" >/dev/null 2>&1 || return 0
	# "I N": the last -A INPUT rule is a bare DROP/REJECT (a comment and an input interface allowed) and is rule
	# number N; "A": policy DROP; "N": nothing to do
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

# nft_up: every foreign base chain of the input hook (not iptables-nft's INPUT: iptables owns it). The last rule
# is a bare drop/reject (counter, log, comment, input interface allowed): insert before it, by its handle. No such rule
# and policy drop: add to the end. Otherwise the chain lets the ports through already.
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

# ufw has the ports open by its own rules (the installer adds them); our ACCEPT in INPUT would bypass its denies
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; }

# firewalld: the ports are only printed by the installer; its reload would wipe our rules, so none are added
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
