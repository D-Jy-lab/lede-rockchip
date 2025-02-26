# Copyright (C) 2006-2013 OpenWrt.org

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

get_mac_binary() {
	local path="$1"
	local offset="$2"

	if ! [ -e "$path" ]; then
		echo "get_mac_binary: file $path not found!" >&2
		return
	fi

	hexdump -v -n 6 -s $offset -e '5/1 "%02x:" 1/1 "%02x"' $path 2>/dev/null
}

get_mac_label_dt() {
	local basepath="/proc/device-tree"
	local macdevice="$(cat "$basepath/aliases/label-mac-device" 2>/dev/null)"
	local macaddr

	[ -n "$macdevice" ] || return

	macaddr=$(get_mac_binary "$basepath/$macdevice/mac-address" 0 2>/dev/null)
	[ -n "$macaddr" ] || macaddr=$(get_mac_binary "$basepath/$macdevice/local-mac-address" 0 2>/dev/null)

	echo $macaddr
}

get_mac_label_json() {
	local cfg="/etc/board.json"
	local macaddr

	[ -s "$cfg" ] || return

	json_init
	json_load "$(cat $cfg)"
	if json_is_a system object; then
		json_select system
			json_get_var macaddr label_macaddr
		json_select ..
	fi

	echo $macaddr
}

get_mac_label() {
	local macaddr=$(get_mac_label_dt)

	[ -n "$macaddr" ] || macaddr=$(get_mac_label_json)

	echo $macaddr
}

find_mtd_chardev() {
	local INDEX=$(find_mtd_index "$1")
	local PREFIX=/dev/mtd

	[ -d /dev/mtd ] && PREFIX=/dev/mtd/
	echo "${INDEX:+$PREFIX$INDEX}"
}

mtd_get_mac_ascii() {
	local mtdname="$1"
	local key="$2"
	local part
	local mac_dirty

	part=$(find_mtd_part "$mtdname")
	if [ -z "$part" ]; then
		echo "mtd_get_mac_ascii: partition $mtdname not found!" >&2
		return
	fi

	mac_dirty=$(strings "$part" | sed -n 's/^'"$key"'=//p')

	# "canonicalize" mac
	[ -n "$mac_dirty" ] && macaddr_canonicalize "$mac_dirty"
}

mtd_get_mac_ascii_mmc() {
	local mtdname="$1"
	local key="$2"
	local part
	local mac_dirty

	part=$(find_mmc_part "$mtdname")
	if [ -z "$part" ]; then
		echo "mtd_get_mac_ascii: partition $mtdname not found!" >&2
		return
	fi

	mac_dirty=$(strings "$part" | sed -n 's/^'"$key"'=//p')

	# "canonicalize" mac
	[ -n "$mac_dirty" ] && macaddr_canonicalize "$mac_dirty"
}

mtd_get_mac_text() {
	local mtdname=$1
	local offset=$(($2))
	local part
	local mac_dirty

	part=$(find_mtd_part "$mtdname")
	if [ -z "$part" ]; then
		echo "mtd_get_mac_text: partition $mtdname not found!" >&2
		return
	fi

	if [ -z "$offset" ]; then
		echo "mtd_get_mac_text: offset missing!" >&2
		return
	fi

	mac_dirty=$(dd if="$part" bs=1 skip="$offset" count=17 2>/dev/null)

	# "canonicalize" mac
	[ -n "$mac_dirty" ] && macaddr_canonicalize "$mac_dirty"
}

mtd_get_mac_binary() {
	local mtdname="$1"
	local offset="$2"
	local part

	part=$(find_mtd_part "$mtdname")
	get_mac_binary "$part" "$offset"
}

mtd_get_mac_binary_ubi() {
	local mtdname="$1"
	local offset="$2"

	. /lib/upgrade/nand.sh

	local ubidev=$(nand_find_ubi $CI_UBIPART)
	local part=$(nand_find_volume $ubidev $1)

	get_mac_binary "/dev/$part" "$offset"
}

mtd_get_mac_binary_mmc() {
	local mtdname="$1"
	local offset="$2"
	local part

	part=$(find_mmc_part "$mtdname")
	get_mac_binary "$part" "$offset"
}

mtd_get_part_size() {
	local part_name=$1
	local first dev size erasesize name
	while read dev size erasesize name; do
		name=${name#'"'}; name=${name%'"'}
		if [ "$name" = "$part_name" ]; then
			echo $((0x$size))
			break
		fi
	done < /proc/mtd
}

mmc_get_mac_binary() {
	local part_name="$1"
	local offset="$2"
	local part

	part=$(find_mmc_part "$part_name")
	get_mac_binary "$part" "$offset"
}

macaddr_add() {
	local mac=$1
	local val=$2
	local oui=${mac%:*:*:*}
	local nic=${mac#*:*:*:}

	nic=$(printf "%06x" $((0x${nic//:/} + val & 0xffffff)) | sed 's/^\(.\{2\}\)\(.\{2\}\)\(.\{2\}\)/\1:\2:\3/')
	echo $oui:$nic
}

macaddr_generate_from_mmc_cid() {
	local mmc_dev=$1

	local sd_hash=$(sha256sum /sys/class/block/$mmc_dev/device/cid)
	local mac_base=$(macaddr_canonicalize "$(echo "${sd_hash}" | dd bs=1 count=12 2>/dev/null)")
	echo "$(macaddr_unsetbit_mc "$(macaddr_setbit_la "${mac_base}")")"
}

macaddr_geteui() {
	local mac=$1
	local sep=$2

	echo ${mac:9:2}$sep${mac:12:2}$sep${mac:15:2}
}

macaddr_setbit() {
	local mac=$1
	local bit=${2:-0}

	[ $bit -gt 0 -a $bit -le 48 ] || return

	printf "%012x" $(( 0x${mac//:/} | 2**(48-bit) )) | sed -e 's/\(.\{2\}\)/\1:/g' -e 's/:$//'
}

macaddr_unsetbit() {
	local mac=$1
	local bit=${2:-0}

	[ $bit -gt 0 -a $bit -le 48 ] || return

	printf "%012x" $(( 0x${mac//:/} & ~(2**(48-bit)) )) | sed -e 's/\(.\{2\}\)/\1:/g' -e 's/:$//'
}

macaddr_setbit_la() {
	macaddr_setbit $1 7
}

macaddr_unsetbit_mc() {
	local mac=$1

	printf "%02x:%s" $((0x${mac%%:*} & ~0x01)) ${mac#*:}
}

macaddr_random() {
	local randsrc=$(get_mac_binary /dev/urandom 0)
	
	echo "$(macaddr_unsetbit_mc "$(macaddr_setbit_la "${randsrc}")")"
}

macaddr_2bin() {
	local mac=$1

	echo -ne \\x${mac//:/\\x}
}

macaddr_canonicalize() {
	local mac="$1"
	local canon=""

	mac=$(echo -n $mac | tr -d \")
	[ ${#mac} -gt 17 ] && return
	[ -n "${mac//[a-fA-F0-9\.: -]/}" ] && return

	for octet in ${mac//[\.:-]/ }; do
		case "${#octet}" in
		1)
			octet="0${octet}"
			;;
		2)
			;;
		4)
			octet="${octet:0:2} ${octet:2:2}"
			;;
		12)
			octet="${octet:0:2} ${octet:2:2} ${octet:4:2} ${octet:6:2} ${octet:8:2} ${octet:10:2}"
			;;
		*)
			return
			;;
		esac
		canon=${canon}${canon:+ }${octet}
	done

	[ ${#canon} -ne 17 ] && return

	printf "%02x:%02x:%02x:%02x:%02x:%02x" 0x${canon// / 0x} 2>/dev/null
}

dt_is_enabled() {
	grep -q okay "/proc/device-tree/$1/status"
}
