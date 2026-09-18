#!/bin/bash

check() {
    return 0;
}

depends() {
    echo ""
}

installkernel() {
    local modules_dep modules_root modfile modname

    modules_root="${DRACUT_MODULES_ROOT:-/lib/modules}"
    if [[ -n "${kernel:-}" && -r "$modules_root/$kernel/modules.dep" ]]; then
        modules_dep="$modules_root/$kernel/modules.dep"
    elif [[ -n "${KERNELVERSION:-}" && -r "$modules_root/$KERNELVERSION/modules.dep" ]]; then
        modules_dep="$modules_root/$KERNELVERSION/modules.dep"
    else
        modules_dep=$(ls -1 "$modules_root"/*/modules.dep 2>/dev/null | head -n 1)
    fi

    [[ -r "$modules_dep" ]] || return 0

    while IFS= read -r modfile; do
        modfile=${modfile%%:*}
        modname=${modfile##*/}
        modname=${modname%.ko*}
        instmods "$modname"
    done < "$modules_dep"
}

_dracut_install_opt() {
    local src="$1"
    local dst=$2;
    if [[ -z "$dst" ]]; then
        test -e "$src" && dracut_install "$src"
    else
        test -e "$src" && dracut_install "$src" "$dst"
    fi
}

install() {
    dracut_install wget openssl tar mstflint ipmitool cpio gzip lsmod ethtool modprobe touch echo cut wc bash
    dracut_install netstat # broadcom update requires
    dracut_install uniq # mellanox update requires
    dracut_install grep ip hostname /usr/bin/awk egrep grep dirname expr
    dracut_install mount.nfs sshd vi reboot lspci parted tmux mkfs mkfs.ext4 mkfs.xfs xfs_db
    #dracut_install libvirtd /usr/share/libvirt/cpu_map.xml /usr/bin/qemu-img /usr/libexec/qemu-kvm
    dracut_install mkswap df ifenslave ssh-keygen scp clear
    # getdestiny makes its request file with mktemp.
    dracut_install mktemp
    dracut_install lldpad

    # RHEL 10 packages no ISC dhcp-client. Install whichever client the build root carries;
    # doxcat chooses between them at run time.
    if command -v dhclient >/dev/null 2>&1; then
        dracut_install dhclient
    elif command -v dhcpcd >/dev/null 2>&1; then
        dracut_install dhcpcd
        # dhcpcd runs these on every lease. They write resolv.conf, the hostname and
        # ntp.conf, which is the work dhclient-script does for the ISC client.
        dracut_install /usr/libexec/dhcpcd-run-hooks
        for _dhcpcd_hook in /usr/libexec/dhcpcd-hooks/*; do
            _dracut_install_opt "$_dhcpcd_hook"
        done
        _dracut_install_opt /etc/dhcpcd.conf
    fi

    # OpenSSH 9.8 moved the per-connection work into sshd-session, which sshd execs by
    # absolute path.
    for _sshd_helper in \
        /usr/libexec/openssh/sshd-session \
        /usr/libexec/openssh/sshd-auth \
        /usr/lib/openssh/sshd-session \
        /usr/lib/openssh/sshd-auth
    do
        _dracut_install_opt "$_sshd_helper"
    done

    # tmux exits under the C locale, and the image carries no locale data of its own.
    for _lc_file in /usr/lib/locale/C.utf8/LC_*; do
        _dracut_install_opt "$_lc_file"
    done
    # glibc NSS: /lib64 on EL, /usr/lib64 on SUSE.
    _dracut_install_opt /lib64/libnss_dns.so.2
    _dracut_install_opt /usr/lib64/libnss_dns.so.2
    dracut_install poweroff hwclock date /usr/share/terminfo/x/xterm /usr/share/terminfo/s/screen /etc/nsswitch.conf /etc/services
    dracut_install /etc/protocols umount /usr/lib/rpm/rpmrc
    # SUSE keeps these under /usr; EL under the /sbin and /bin compatibility paths.
    _dracut_install_opt /sbin/rsyslogd || _dracut_install_opt /usr/sbin/rsyslogd
    _dracut_install_opt /bin/rpm      || _dracut_install_opt /usr/bin/rpm
    #dracut_install chmod /sbin/route /sbin/ifconfig /usr/bin/whoami /usr/bin/head /usr/bin/tail basename /etc/redhat-release ping tr lsusb /usr/share/hwdata/usb.ids #ibm fw wrapper requirements
    dracut_install chmod ip /usr/bin/whoami /usr/bin/head /usr/bin/tail basename /etc/redhat-release ping tr lsusb /usr/share/hwdata/usb.ids #ibm fw wrapper requirements
    # uxspi prereqs. dmidecode also improves the decision on loading ipmi_si. Neither is
    # packaged for ppc64le, so install whichever the build root carries.
    for _fw_tool in efibootmgr dmidecode; do
        command -v "$_fw_tool" >/dev/null 2>&1 && dracut_install "$_fw_tool"
    done
    dracut_install lldptool
    # Time zones. EL ships a posix/ duplicate of the zone tree; SUSE ships only the tree
    # itself, and dracut_install is fatal on a miss, so every zone below stopped the SUSE
    # image build. Take the posix/ copy where it exists and the plain one otherwise. The
    # zone list is data: keep it as a list, not as 565 lines of install commands.
    for _tz in \
        Zulu GMT-0 Europe/Istanbul Europe/San_Marino Europe/Jersey Europe/Bucharest \
        Europe/Gibraltar Europe/Uzhgorod Europe/Moscow Europe/Brussels Europe/Nicosia Europe/Zurich \
        Europe/Berlin Europe/Guernsey Europe/Budapest Europe/Kiev Europe/Podgorica Europe/Isle_of_Man \
        Europe/Mariehamn Europe/Belgrade Europe/Belfast Europe/Ljubljana Europe/Chisinau Europe/Andorra \
        Europe/Athens Europe/Stockholm Europe/Vienna Europe/Lisbon Europe/London Europe/Paris \
        Europe/Oslo Europe/Zagreb Europe/Helsinki Europe/Warsaw Europe/Copenhagen Europe/Riga \
        Europe/Vaduz Europe/Vilnius Europe/Volgograd Europe/Amsterdam Europe/Tiraspol Europe/Tallinn \
        Europe/Kaliningrad Europe/Malta Europe/Sarajevo Europe/Madrid Europe/Zaporozhye Europe/Simferopol \
        Europe/Sofia Europe/Skopje Europe/Monaco Europe/Rome Europe/Prague Europe/Luxembourg \
        Europe/Minsk Europe/Vatican Europe/Dublin Europe/Samara Europe/Tirane Europe/Bratislava \
        Greenwich US/Indiana-Starke US/Alaska US/Michigan US/Aleutian US/Hawaii \
        US/Central US/Eastern US/Pacific US/Samoa US/Mountain US/Arizona \
        US/East-Indiana EST HST Eire America/Cancun America/Santo_Domingo \
        America/Jujuy America/Guatemala America/Monterrey America/Ensenada America/Dawson_Creek America/Mendoza \
        America/Coral_Harbour America/Martinique America/Cordoba America/Recife America/Cayman America/Shiprock \
        America/Tortola America/Lima America/Antigua America/Blanc-Sablon America/Nipigon America/Nome \
        America/Montserrat America/Atka America/St_Thomas America/Halifax America/Montreal America/Curacao \
        America/Cuiaba America/Winnipeg America/North_Dakota/New_Salem America/North_Dakota/Center America/Panama America/Rosario \
        America/Anguilla America/Ojinaga America/Guyana America/Eirunepe America/Grand_Turk America/Rio_Branco \
        America/Santa_Isabel America/Scoresbysund America/Adak America/Menominee America/Resolute America/Guadeloupe \
        America/Indianapolis America/Vancouver America/Glace_Bay America/Buenos_Aires America/Virgin America/Belem \
        America/Catamarca America/Bahia America/Fort_Wayne America/Hermosillo America/Rankin_Inlet America/Mexico_City \
        America/Belize America/Maceio America/Dominica America/Swift_Current America/St_Johns America/St_Barthelemy \
        America/Yellowknife America/Costa_Rica America/Pangnirtung America/Bogota America/Port-au-Prince America/Phoenix \
        America/Port_of_Spain America/Matamoros America/Puerto_Rico America/Detroit America/Edmonton America/Toronto \
        America/Cambridge_Bay America/Godthab America/Atikokan America/Juneau America/Managua America/Anchorage \
        America/Merida America/Thunder_Bay America/Porto_Velho America/Argentina/Jujuy America/Argentina/La_Rioja America/Argentina/Mendoza \
        America/Argentina/Cordoba America/Argentina/Ushuaia America/Argentina/Rio_Gallegos America/Argentina/Buenos_Aires America/Argentina/San_Juan America/Argentina/Catamarca \
        America/Argentina/San_Luis America/Argentina/ComodRivadavia America/Argentina/Salta America/Argentina/Tucuman America/Iqaluit America/Chicago \
        America/Miquelon America/Havana America/Guayaquil America/St_Vincent America/St_Lucia America/Boise \
        America/Yakutat America/Santarem America/Campo_Grande America/Santiago America/Porto_Acre America/Sao_Paulo \
        America/Thule America/New_York America/Nassau America/Dawson America/Louisville America/Asuncion \
        America/Inuvik America/Paramaribo America/Chihuahua America/Mazatlan America/Grenada America/Denver \
        America/Los_Angeles America/Marigot America/Manaus America/Regina America/Barbados America/Noronha \
        America/Montevideo America/Caracas America/Rainy_River America/La_Paz America/Jamaica America/Moncton \
        America/Whitehorse America/Fortaleza America/Kentucky/Monticello America/Kentucky/Louisville America/Indiana/Marengo America/Indiana/Indianapolis \
        America/Indiana/Knox America/Indiana/Tell_City America/Indiana/Petersburg America/Indiana/Winamac America/Indiana/Vincennes America/Indiana/Vevay \
        America/Danmarkshavn America/St_Kitts America/Aruba America/Boa_Vista America/Bahia_Banderas America/Tegucigalpa \
        America/Araguaina America/El_Salvador America/Cayenne America/Tijuana America/Knox_IN America/Goose_Bay \
        EET EST5EDT MST Iceland Atlantic/Faeroe Atlantic/Stanley \
        Atlantic/Reykjavik Atlantic/St_Helena Atlantic/Faroe Atlantic/South_Georgia Atlantic/Jan_Mayen Atlantic/Azores \
        Atlantic/Cape_Verde Atlantic/Madeira Atlantic/Bermuda Atlantic/Canary GMT0 Poland \
        Indian/Chagos Indian/Maldives Indian/Comoro Indian/Mauritius Indian/Mayotte Indian/Christmas \
        Indian/Antananarivo Indian/Kerguelen Indian/Mahe Indian/Cocos Indian/Reunion Mexico/BajaNorte \
        Mexico/BajaSur Mexico/General Turkey Egypt Hongkong GB \
        GMT+0 ROK Antarctica/Mawson Antarctica/Macquarie Antarctica/South_Pole Antarctica/Rothera \
        Antarctica/Davis Antarctica/DumontDUrville Antarctica/McMurdo Antarctica/Casey Antarctica/Vostok Antarctica/Palmer \
        Antarctica/Syowa Universal CET WET Navajo UTC \
        Pacific/Enderbury Pacific/Johnston Pacific/Pago_Pago Pacific/Saipan Pacific/Norfolk Pacific/Chuuk \
        Pacific/Galapagos Pacific/Palau Pacific/Tarawa Pacific/Fakaofo Pacific/Rarotonga Pacific/Wake \
        Pacific/Kosrae Pacific/Tahiti Pacific/Fiji Pacific/Ponape Pacific/Tongatapu Pacific/Efate \
        Pacific/Honolulu Pacific/Niue Pacific/Kwajalein Pacific/Guam Pacific/Funafuti Pacific/Majuro \
        Pacific/Midway Pacific/Nauru Pacific/Samoa Pacific/Marquesas Pacific/Kiritimati Pacific/Noumea \
        Pacific/Truk Pacific/Guadalcanal Pacific/Pohnpei Pacific/Pitcairn Pacific/Port_Moresby Pacific/Yap \
        Pacific/Easter Pacific/Wallis Pacific/Apia Pacific/Auckland Pacific/Gambier Pacific/Chatham \
        Japan Libya ROC Iran Brazil/West Brazil/East \
        Brazil/Acre Brazil/DeNoronha Arctic/Longyearbyen Portugal MET W-SU \
        Kwajalein CST6CDT GB-Eire Australia/Melbourne Australia/Broken_Hill Australia/Queensland \
        Australia/South Australia/Eucla Australia/Yancowinna Australia/Lord_Howe Australia/Hobart Australia/NSW \
        Australia/West Australia/LHI Australia/Perth Australia/ACT Australia/Darwin Australia/Lindeman \
        Australia/Sydney Australia/North Australia/Canberra Australia/Adelaide Australia/Brisbane Australia/Victoria \
        Australia/Tasmania Australia/Currie UCT Cuba Singapore GMT \
        NZ-CHAT Asia/Istanbul Asia/Kuwait Asia/Saigon Asia/Urumqi Asia/Brunei \
        Asia/Ujung_Pandang Asia/Muscat Asia/Kashgar Asia/Kamchatka Asia/Manila Asia/Vladivostok \
        Asia/Jayapura Asia/Magadan Asia/Almaty Asia/Qyzylorda Asia/Anadyr Asia/Nicosia \
        Asia/Kathmandu Asia/Qatar Asia/Jerusalem Asia/Yakutsk Asia/Karachi Asia/Samarkand \
        Asia/Kolkata Asia/Ulaanbaatar Asia/Irkutsk Asia/Baku Asia/Gaza Asia/Seoul \
        Asia/Chungking Asia/Amman Asia/Kuala_Lumpur Asia/Aqtobe Asia/Katmandu Asia/Tashkent \
        Asia/Oral Asia/Dhaka Asia/Hovd Asia/Makassar Asia/Bangkok Asia/Tokyo \
        Asia/Macao Asia/Riyadh Asia/Rangoon Asia/Jakarta Asia/Aden Asia/Calcutta \
        Asia/Ashkhabad Asia/Beirut Asia/Harbin Asia/Novosibirsk Asia/Omsk Asia/Aqtau \
        Asia/Bahrain Asia/Dili Asia/Pontianak Asia/Singapore Asia/Baghdad Asia/Novokuznetsk \
        Asia/Dubai Asia/Dushanbe Asia/Damascus Asia/Krasnoyarsk Asia/Tbilisi Asia/Yerevan \
        Asia/Pyongyang Asia/Bishkek Asia/Colombo Asia/Yekaterinburg Asia/Chongqing Asia/Ho_Chi_Minh \
        Asia/Hong_Kong Asia/Thimbu Asia/Thimphu Asia/Ashgabat Asia/Shanghai Asia/Tehran \
        Asia/Tel_Aviv Asia/Taipei Asia/Kabul Asia/Macau Asia/Choibalsan Asia/Vientiane \
        Asia/Dacca Asia/Kuching Asia/Phnom_Penh Asia/Ulan_Bator Asia/Sakhalin MST7MDT \
        Canada/Atlantic Canada/Central Canada/Eastern Canada/Yukon Canada/Pacific Canada/Saskatchewan \
        Canada/Mountain Canada/Newfoundland Israel Africa/Lagos Africa/Kigali Africa/Lome \
        Africa/Niamey Africa/Conakry Africa/Asmera Africa/Banjul Africa/Abidjan Africa/Bujumbura \
        Africa/Luanda Africa/Kampala Africa/Ouagadougou Africa/Libreville Africa/Lubumbashi Africa/Dakar \
        Africa/Bamako Africa/Nairobi Africa/Bangui Africa/Johannesburg Africa/Accra Africa/Bissau \
        Africa/Timbuktu Africa/Nouakchott Africa/Maputo Africa/Ndjamena Africa/Maseru Africa/Tripoli \
        Africa/Blantyre Africa/Gaborone Africa/Addis_Ababa Africa/Porto-Novo Africa/Kinshasa Africa/Dar_es_Salaam \
        Africa/Douala Africa/Mogadishu Africa/Monrovia Africa/Mbabane Africa/Algiers Africa/Lusaka \
        Africa/Khartoum Africa/Asmara Africa/Tunis Africa/Casablanca Africa/Sao_Tome Africa/Ceuta \
        Africa/El_Aaiun Africa/Harare Africa/Freetown Africa/Windhoek Africa/Djibouti Africa/Malabo \
        Africa/Cairo Africa/Brazzaville Etc/Zulu Etc/GMT-0 Etc/Greenwich Etc/GMT+6 \
        Etc/GMT+9 Etc/GMT-9 Etc/GMT+5 Etc/GMT0 Etc/GMT-10 Etc/GMT+0 \
        Etc/Universal Etc/GMT+12 Etc/GMT-5 Etc/GMT+2 Etc/UTC Etc/GMT+8 \
        Etc/GMT-11 Etc/GMT-4 Etc/GMT-12 Etc/GMT+11 Etc/GMT+3 Etc/GMT+4 \
        Etc/GMT+1 Etc/GMT-14 Etc/UCT Etc/GMT+7 Etc/GMT-6 Etc/GMT-2 \
        Etc/GMT Etc/GMT-3 Etc/GMT-8 Etc/GMT-7 Etc/GMT-13 Etc/GMT-1 \
        Etc/GMT+10 PST8PDT Jamaica NZ PRC Chile/EasterIsland \
        Chile/Continental
    do
        _dracut_install_opt "/usr/share/zoneinfo/posix/${_tz}" \
            || _dracut_install_opt "/usr/share/zoneinfo/${_tz}"
    done
    inst "$moddir/xcatroot" "/sbin/xcatroot"
    inst "$moddir/dhclient.conf" "/etc/dhclient.conf"
    # dhclient executes this helper, so it must stay executable in initramfs.
    inst_script "$moddir/dhclient-script" "/sbin/dhclient-script"
    inst "$moddir/rsyslog.conf" "/etc/rsyslog.conf"
    dracut_install chronyc chronyd rpcbind systemd-tmpfiles
    dracut_install /etc/ssh
    _dracut_install_opt /etc/chrony.conf
    _dracut_install_opt /etc/chrony.keys
    dracut_install /run/rpcbind
    _dracut_install_opt /etc/systemd/system.conf
    dracut_install /etc/netconfig rpcbind /etc/host.conf
    _dracut_install_opt /sbin/rpc.statd  || _dracut_install_opt /usr/sbin/rpc.statd
    _dracut_install_opt /usr/sbin/sm-notify  || _dracut_install_opt /sbin/sm-notify
    _dracut_install_opt /usr/sbin/rpc.idmapd || _dracut_install_opt /sbin/rpc.idmapd
    dracut_install ps free find #debug
    inst_dir /var/lib/nfs
    inst_dir /var/lib/nfs/statd/sm
    inst_dir /var/lib/nfs/statd/sm.bak
    inst_dir /var/lib/nfs/rpc_pipefs/nfs
    inst "/bin/bash" "/bin/sh"
    inst "/usr/share/terminfo/l/linux"
    inst "/usr/share/terminfo/v/vt100"
    inst_hook cmdline 10 "$moddir/xcat-cmdline.sh"
    # rsyslog modules. EL keeps them in /lib64/rsyslog, SUSE in /usr/lib64/rsyslog, and
    # dracut_install is fatal on a miss -- which stopped the SUSE image build here. Install
    # from whichever root this distribution uses.
    for _rsmod in lmtcpclt omtesting lmnetstrms imfile imklog lmzlibw immark imudp lmregexp lmtcpsrv lmnsd_ptcp imtcp lmnet imuxsock; do
        _dracut_install_opt "/lib64/rsyslog/${_rsmod}.so"
        _dracut_install_opt "/usr/lib64/rsyslog/${_rsmod}.so"
    done
    # These six are the sysclone payload. Their paths and package names differ between EL and
    # SUSE -- SUSE keeps the udev rules only under /usr/lib, and ships nc in netcat-openbsd
    # rather than in the nmap package -- so install what is present rather than asserting the
    # EL layout. dracut_install is fatal when a name is missing, which stopped the whole SUSE
    # genesis build at %install.
    _dracut_install_opt /usr/lib64/libnfsidmap/nsswitch.so
    _dracut_install_opt /usr/lib/libnfsidmap/nsswitch.so
    dracut_install killall logger nslookup bc chown chroot dd expr kill mkdosfs parted rsync shutdown sort ssh-keygen tr blockdev findfs insmod kexec lvm mdadm mke2fs pivot_root sshd swapon tune2fs pvcreate lvremove vgremove vgcreate  lvcreate  lvscan  lvchange vgchange pvdisplay lvdisplay vgdisplay blkid dmsetup sfdisk # for sysclone
    # nc: EL gets it from nmap-ncat, SUSE from netcat-openbsd. Install whichever the build root has.
    for _nc in nc ncat netcat; do
        command -v "$_nc" >/dev/null 2>&1 && { dracut_install "$_nc"; break; }
    done
    for _dmrule in 10-dm 11-dm-lvm 13-dm-disk 95-dm-notify; do
        _dracut_install_opt "/lib/udev/rules.d/${_dmrule}.rules"
        _dracut_install_opt "/usr/lib/udev/rules.d/${_dmrule}.rules"
    done
    # The DB files for lspci
    _dracut_install_opt /usr/share/hwdata/pci.ids || _dracut_install_opt /usr/share/pci.ids
    # The DB files for udevadm
    _dracut_install_opt /etc/udev/hwdb.bin || _dracut_install_opt /usr/lib/udev/hwdb.bin
}
