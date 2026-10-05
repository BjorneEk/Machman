#!/bin/bash
# A cloud-init NoCloud seed (volume "cidata"): meta-data + user-data in an ISO9660/Joliet image
# made with hdiutil makehybrid — never hdiutil attach, never diskutil (no mounted volume, no
# Finder, no Spotlight). cloud-init (Debian) and FreeBSD's nuageinit both read it.
#
#   seed.sh <out.iso> --instance-id ID --hostname H [--user U --key <pubfile>
#           [--groups G] [--doas '<rule>'] [--packages 'a b'] [--runcmd-file F]]
#           [--user-data <file>]
#   seed.sh --self-check
#
# Without --user-data it writes a #cloud-config: users (name, groups, shell /bin/sh,
# ssh_authorized_keys), packages, doas, runcmd (the file's text as one script) and
# ssh_pwauth false. The staging dir <out>.d is removed after the image is made.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

usage() {
	sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

yq() { # a YAML single-quoted scalar
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

build() {
	local out="" iid="" host="" user="" key="" groups="" doas="" packages="" runcmd="" ud=""
	[ $# -gt 0 ] || usage
	out="$1"
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--instance-id) iid="${2:-}"; shift 2 ;;
		--hostname) host="${2:-}"; shift 2 ;;
		--user) user="${2:-}"; shift 2 ;;
		--key) key="${2:-}"; shift 2 ;;
		--groups) groups="${2:-}"; shift 2 ;;
		--doas) doas="${2:-}"; shift 2 ;;
		--packages) packages="${2:-}"; shift 2 ;;
		--runcmd-file) runcmd="${2:-}"; shift 2 ;;
		--user-data) ud="${2:-}"; shift 2 ;;
		*) usage ;;
		esac
	done
	case "$out" in *.iso) ;; *) lab_die 64 "the seed's path ends in .iso, not '$out'." ;; esac
	[ -n "$iid" ] && [ -n "$host" ] || lab_die 64 "--instance-id and --hostname are required."
	if [ -n "$user" ]; then
		[ -f "$key" ] || lab_die 64 "--user needs --key <public key file>."
	fi
	[ -z "$runcmd" ] || [ -f "$runcmd" ] || lab_die 64 "no runcmd file at '$runcmd'."
	[ -z "$ud" ] || [ -f "$ud" ] || lab_die 64 "no user-data file at '$ud'."
	local stage="$out.d"
	rm -rf "$stage" "$out"
	mkdir -p "$stage" || lab_die 1 "cannot create $stage."
	printf 'instance-id: %s\nlocal-hostname: %s\n' "$iid" "$host" > "$stage/meta-data"
	if [ -n "$ud" ]; then
		cp "$ud" "$stage/user-data"
	else
		{
			echo '#cloud-config'
			if [ -n "$user" ]; then
				echo 'users:'
				echo "  - name: $(yq "$user")"
				[ -z "$groups" ] || echo "    groups: $(yq "$groups")"
				echo "    shell: /bin/sh"
				echo "    ssh_authorized_keys:"
				echo "      - $(yq "$(head -n 1 "$key")")"
			fi
			if [ -n "$packages" ]; then
				echo 'packages:'
				for p in $packages; do echo "  - $(yq "$p")"; done
			fi
			[ -z "$doas" ] || printf 'doas:\n  - %s\n' "$(yq "$doas")"
			if [ -n "$runcmd" ]; then
				echo 'runcmd:'
				echo '  - |'
				sed 's/^/    /' "$runcmd"
			fi
			echo 'ssh_pwauth: false'
		} > "$stage/user-data"
	fi
	hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$out" "$stage" \
		|| { rm -rf "$stage"; lab_die 1 "hdiutil makehybrid failed for $out."; }
	rm -rf "$stage"
	[ -f "$out" ] || lab_die 1 "hdiutil made no $out."
	printf '%s\n' "$out"
}

# ucs2hex <ascii>: its UCS-2 big-endian bytes (Joliet's file names) as one hex string.
ucs2hex() {
	printf '%s' "$1" | od -An -tx1 -v | tr -s ' \n' '  ' | sed 's/ \([0-9a-f][0-9a-f]\)/00\1/g' \
		| tr -d ' '
}

# vd_id <iso> <sector>: the volume descriptor's type and its 32-byte volume id field.
vd_type() { dd if="$1" bs=2048 skip="$2" count=1 2>/dev/null | head -c 6 | od -An -c | tr -d ' '; }
vd_volid() {
	dd if="$1" bs=2048 skip="$2" count=1 2>/dev/null | dd bs=1 skip=40 count=32 2>/dev/null
}

self_check() {
	local root fails=0 iso key pvd svd s t
	root="$(lab_new_root)"
	SC_ROOT="$root"
	trap 'rm -rf "$SC_ROOT"' EXIT
	ok() { echo "ok    $*"; }
	bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
	key="$root/key.pub"
	echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISEEDSELFCHECK lab@seed' > "$key"
	printf 'echo one\necho "two: it'"'"'s"\n' > "$root/run.sh"
	iso="$("$HERE/seed.sh" "$root/seed.iso" --instance-id sc-1 --hostname sc --user lab \
		--key "$key" --groups wheel --doas 'permit nopass lab' --packages 'doas sudo' \
		--runcmd-file "$root/run.sh")" || bad "seed.sh failed"
	[ -f "$iso" ] && [ ! -e "$root/seed.iso.d" ] && ok "built $(basename "$iso"), staging removed" \
		|| bad "no iso or the staging dir is left"
	pvd="$(vd_volid "$iso" 16 | tr -d ' ')"
	# The supplementary (Joliet) descriptor: the first type-2 descriptor after the PVD.
	svd=""
	for s in 17 18 19 20; do
		t="$(vd_type "$iso" "$s")"
		case "$t" in
		002CD001) svd="$(vd_volid "$iso" "$s" | LC_ALL=C tr -d '\000 ')"; break ;;
		377CD001) break ;;
		esac
	done
	[ "$(vd_type "$iso" 16)" = 001CD001 ] && ok "ISO9660 PVD volume id: '$pvd'" \
		|| bad "no primary volume descriptor at sector 16"
	[ "$svd" = cidata ] && ok "Joliet volume id: '$svd'" || bad "Joliet volume id '$svd'"
	local jm jud
	jm="$(ucs2hex meta-data)"
	jud="$(ucs2hex user-data)"
	local hex
	hex="$(od -An -tx1 -v "$iso" | tr -d ' \n')"
	case "$hex" in *"$jm"*) ok "Joliet record meta-data" ;; *) bad "no Joliet meta-data" ;; esac
	case "$hex" in *"$jud"*) ok "Joliet record user-data" ;; *) bad "no Joliet user-data" ;; esac
	if LC_ALL=C grep -aq 'permit nopass lab' "$iso" && LC_ALL=C grep -aq '^    echo one' "$iso" \
		&& LC_ALL=C grep -aq "two: it's" "$iso" && LC_ALL=C grep -aq '#cloud-config' "$iso" \
		&& LC_ALL=C grep -aq 'local-hostname: sc' "$iso"; then
		ok "user-data and meta-data carry the doas rule, the runcmd script and the hostname"
	else
		bad "the user-data or meta-data text is not in the image"
	fi
	if "$HERE/seed.sh" "$root/x.img" --instance-id a --hostname b >/dev/null 2>&1; then
		bad "a non-.iso path was accepted"
	else
		ok "refused a non-.iso path"
	fi
	if [ "$fails" = 0 ]; then echo "seed.sh --self-check: all ok"
	else echo "seed.sh --self-check: $fails FAILED"; fi
	[ "$fails" = 0 ]
}

case "${1:-}" in
--self-check) self_check ;;
''|-h|--help) usage ;;
*) build "$@" ;;
esac; exit $?
