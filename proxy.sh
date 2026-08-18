#!/bin/bash

# Проверка необходимости перезагрузить
if [[ -f /var/run/reboot-required ]] || pidof apt apt-get dpkg unattended-upgrades &>/dev/null; then
	echo 'Error: You need to reboot this server before installation!'
	exit 2
fi

# Проверка прав root
if [[ "$EUID" -ne 0 ]]; then
	echo 'Error: You need to run this as root!'
	exit 3
fi

cd /root

# Проверка на OpenVZ и LXC
if [[ "$(systemd-detect-virt)" == 'openvz' || "$(systemd-detect-virt)" == 'lxc' ]]; then
	echo 'Error: OpenVZ and LXC are not supported!'
	exit 4
fi

# Проверка версии системы
OS="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
VERSION="$(lsb_release -rs | cut -d '.' -f1)"

if [[ "$OS" == 'debian' ]]; then
	if (( VERSION < 12 )); then
		echo "Error: Debian $VERSION is not supported! Minimal supported version is 12"
		exit 5
	fi
elif [[ "$OS" == 'ubuntu' ]]; then
	if (( VERSION < 22 )); then
		echo "Error: Ubuntu $VERSION is not supported! Minimal supported version is 22"
		exit 6
	fi
else
	echo "Error: Your Linux distribution ($OS) is not supported!"
	exit 7
fi

DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
if [[ -z "$DEFAULT_INTERFACE" ]]; then
	echo 'Default network interface not found!'
	exit 8
fi

DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
if [[ -z "$DEFAULT_IP" ]]; then
	echo 'Default IPv4 address not found!'
	exit 9
fi

DEFAULT_IP6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+')"

echo
echo -e '\e[1;32mInstalling proxy for AntiZapret VPN server\e[0m'
echo 'Proxied ports:'
echo '    OpenVPN UDP:           80, 443, 504, 508, 50080, 50443'
echo '    OpenVPN TCP:           80, 443, 504, 508, 50080, 50443'
echo '    WireGuard/AmneziaWG:   540, 580, 51080, 51443, 52080, 52443'
echo 'More details: https://github.com/GubernievS/AntiZapret-VPN'
echo

MTU=$(< /sys/class/net/$DEFAULT_INTERFACE/mtu)
if (( MTU < 1500 )); then
	echo "Warning! Low MTU on $DEFAULT_INTERFACE: $MTU"
	echo "Change MTU in OpenVPN and WireGuard configs from 1420 to $((MTU-80)) on AntiZapret VPN server"
	echo
fi

# Спрашиваем о настройках
until [[ "$OPENVPN_UDP" =~ (y|n) ]]; do
	read -rp 'Enable OpenVPN UDP proxying? [y/n]: ' -e -i y OPENVPN_UDP
done
echo
until [[ "$OPENVPN_TCP" =~ (y|n) ]]; do
	read -rp 'Enable OpenVPN TCP proxying? [y/n]: ' -e -i n OPENVPN_TCP
done
echo
until [[ "$WIREGUARD" =~ (y|n) ]]; do
	read -rp 'Enable WireGuard/AmneziaWG proxying? [y/n]: ' -e -i y WIREGUARD
done
echo
if [[ "$OPENVPN_UDP" == 'y' || "$OPENVPN_TCP" == 'y' ]]; then
	while read -rp 'Enter OpenVPN server IPv4 address: ' -e OPENVPN_IP
	do
		[[ -n $(getent ahostsv4 "$OPENVPN_IP") ]] || continue
		break
	done
	echo
fi
if [[ "$WIREGUARD" == 'y' ]]; then
	while read -rp 'Enter WireGuard/AmneziaWG server IPv4 address: ' -e WIREGUARD_IP
	do
		[[ -n $(getent ahostsv4 "$WIREGUARD_IP") ]] || continue
		break
	done
	echo
fi
if [[ -n "$DEFAULT_IP6" ]]; then
	echo "Detected IPv6 address on $DEFAULT_INTERFACE: $DEFAULT_IP6"
	echo 'Enter IPv6 addresses of AntiZapret VPN server to proxy IPv6 connections, or press Enter to skip'
	if [[ "$OPENVPN_UDP" == 'y' || "$OPENVPN_TCP" == 'y' ]]; then
		while read -rp 'Enter OpenVPN server IPv6 address: ' -e OPENVPN_IP6
		do
			[[ -z "$OPENVPN_IP6" ]] && break
			[[ -n $(getent ahostsv6 "$OPENVPN_IP6") ]] && break
		done
		echo
	fi
	if [[ "$WIREGUARD" == 'y' ]]; then
		while read -rp 'Enter WireGuard/AmneziaWG server IPv6 address: ' -e WIREGUARD_IP6
		do
			[[ -z "$WIREGUARD_IP6" ]] && break
			[[ -n $(getent ahostsv6 "$WIREGUARD_IP6") ]] && break
		done
		echo
	fi
fi
echo 'Warning! SSH protection may block your IP after 5 logins/minute!'
until [[ "$SSH_PROTECTION" =~ (y|n) ]]; do
	read -rp 'Enable SSH brute-force protection? [y/n]: ' -e -i y SSH_PROTECTION
done
echo
echo 'Warning! Scan protection blocks ping and closed-port replies!'
until [[ "$SCAN_PROTECTION" =~ (y|n) ]]; do
	read -rp 'Enable network scan protection? [y/n]: ' -e -i y SCAN_PROTECTION
done
echo
echo 'Installation, please wait...'

# Удалим ненужные службы
apt-get purge -y ufw
apt-get purge -y firewalld
apt-get purge -y apparmor
apt-get purge -y apport
apt-get purge -y modemmanager
apt-get purge -y snapd
apt-get purge -y upower
apt-get purge -y multipath-tools
apt-get purge -y rsyslog
apt-get purge -y udisks2
apt-get purge -y qemu-guest-agent
apt-get purge -y tuned
apt-get purge -y sysstat
apt-get purge -y acpid
apt-get purge -y fwupd
# apt-get purge -y watchdog
apt-get purge -y pcscd
apt-get purge -y packagekit

# SSH protection включён
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	apt-get purge -y fail2ban
	apt-get purge -y sshguard
fi

# Включим или отключим IPv6
if [[ -n "$OPENVPN_IP6" || -n "$WIREGUARD_IP6" ]]; then
	IPV6=y
	sysctl -w net.ipv6.conf.all.forwarding=1
	# Форвардинг отключает приём Router Advertisement, возвращаем его на внешнем интерфейсе
	sysctl -w net.ipv6.conf.$DEFAULT_INTERFACE.accept_ra=2 || true
else
	IPV6=n
	sysctl -w net.ipv6.conf.all.disable_ipv6=1
	sysctl -w net.ipv6.conf.default.disable_ipv6=1
	sysctl -w net.ipv6.conf.lo.disable_ipv6=1
fi

# Удаляем переопределённые параметры ядра
# sed -i '/^$/!{/^#/!d}' /etc/sysctl.conf

# Принудительная загрузка модуля nf_conntrack
echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf

# Завершим выполнение скрипта при ошибке
set -e

# Обработка ошибок
handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Автоматически сохраним правила iptables
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
if [[ "$IPV6" == 'y' ]]; then
	echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
else
	echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
fi

# Обновляем систему и ставим необходимые пакеты
export DEBIAN_FRONTEND=noninteractive
apt-get clean
apt-get update
dpkg --configure -a
apt-get install --fix-broken -y
apt-get dist-upgrade -y
apt-get install -y iptables iptables-persistent irqbalance unattended-upgrades
apt-get autoremove --purge -y
apt-get clean
dpkg-reconfigure -f noninteractive unattended-upgrades

# Изменим параметры для прокси
if [[ "$IPV6" == 'y' ]]; then
	echo "# Proxy parameters modification
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.$DEFAULT_INTERFACE.accept_ra=2" > /etc/sysctl.d/99-proxy.conf
	rm -f /etc/sysctl.d/99-disable-ipv6.conf
else
	echo "# Proxy parameters modification
net.ipv4.ip_forward=1" > /etc/sysctl.d/99-proxy.conf

	# Отключим IPv6
	echo "# Disable IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1" > /etc/sysctl.d/99-disable-ipv6.conf
fi

# Очистка правил iptables
iptables -w -F
iptables -w -t nat -F
iptables -w -t mangle -F
iptables -w -t raw -F
ip6tables -w -F
ip6tables -w -t nat -F
ip6tables -w -t mangle -F
ip6tables -w -t raw -F

# Новые правила iptables
# filter
# Default policy
iptables -w -P INPUT ACCEPT
iptables -w -P FORWARD ACCEPT
iptables -w -P OUTPUT ACCEPT
ip6tables -w -P INPUT ACCEPT
ip6tables -w -P FORWARD ACCEPT
ip6tables -w -P OUTPUT ACCEPT
# INPUT connection tracking
iptables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
# OUTPUT connection tracking
iptables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
# SSH protection
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name proxy-ssh --hashlimit-htable-expire 60000 -j DROP
	ip6tables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name proxy-ssh6 --hashlimit-htable-expire 60000 -j DROP
fi
# Scan protection
if [[ "$SCAN_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmp --icmp-type echo-request -j DROP
	iptables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	iptables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmp --icmp-type port-unreachable -j DROP
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type echo-request -j DROP
	ip6tables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	ip6tables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type port-unreachable -j DROP
fi

# mangle
# Clamp TCP MSS
iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# nat
# OpenVPN TCP
if [[ "$OPENVPN_TCP" == 'y' ]]; then
#	iptables -w -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $OPENVPN_IP:50080
#	iptables -w -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination $OPENVPN_IP:50443
	iptables -w -t nat -A PREROUTING -p tcp --dport 504 -j DNAT --to-destination $OPENVPN_IP:50443
	iptables -w -t nat -A PREROUTING -p tcp --dport 508 -j DNAT --to-destination $OPENVPN_IP:50080
	iptables -w -t nat -A PREROUTING -p tcp --dport 50080 -j DNAT --to-destination $OPENVPN_IP:50080
	iptables -w -t nat -A PREROUTING -p tcp --dport 50443 -j DNAT --to-destination $OPENVPN_IP:50443
fi
# OpenVPN UDP
if [[ "$OPENVPN_UDP" == 'y' ]]; then
#	iptables -w -t nat -A PREROUTING -p udp --dport 80 -j DNAT --to-destination $OPENVPN_IP:50080
#	iptables -w -t nat -A PREROUTING -p udp --dport 443 -j DNAT --to-destination $OPENVPN_IP:50443
	iptables -w -t nat -A PREROUTING -p udp --dport 504 -j DNAT --to-destination $OPENVPN_IP:50443
	iptables -w -t nat -A PREROUTING -p udp --dport 508 -j DNAT --to-destination $OPENVPN_IP:50080
	iptables -w -t nat -A PREROUTING -p udp --dport 50080 -j DNAT --to-destination $OPENVPN_IP:50080
	iptables -w -t nat -A PREROUTING -p udp --dport 50443 -j DNAT --to-destination $OPENVPN_IP:50443
fi
# WireGuard/AmneziaWG
if [[ "$WIREGUARD" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -p udp --dport 540 -j DNAT --to-destination $WIREGUARD_IP:51443
	iptables -w -t nat -A PREROUTING -p udp --dport 580 -j DNAT --to-destination $WIREGUARD_IP:51080
	iptables -w -t nat -A PREROUTING -p udp --dport 51080 -j DNAT --to-destination $WIREGUARD_IP:51080
	iptables -w -t nat -A PREROUTING -p udp --dport 51443 -j DNAT --to-destination $WIREGUARD_IP:51443
	iptables -w -t nat -A PREROUTING -p udp --dport 52080 -j DNAT --to-destination $WIREGUARD_IP:51080
	iptables -w -t nat -A PREROUTING -p udp --dport 52443 -j DNAT --to-destination $WIREGUARD_IP:51443
fi
# SNAT
if [[ -n "$OPENVPN_IP" ]]; then
	iptables -w -t nat -A POSTROUTING -d $OPENVPN_IP -j SNAT --to-source $DEFAULT_IP
fi
if [[ -n "$WIREGUARD_IP" && "$WIREGUARD_IP" != "$OPENVPN_IP" ]]; then
	iptables -w -t nat -A POSTROUTING -d $WIREGUARD_IP -j SNAT --to-source $DEFAULT_IP
fi
# OpenVPN TCP IPv6
if [[ "$OPENVPN_TCP" == 'y' && -n "$OPENVPN_IP6" ]]; then
#	ip6tables -w -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination [$OPENVPN_IP6]:50080
#	ip6tables -w -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination [$OPENVPN_IP6]:50443
	ip6tables -w -t nat -A PREROUTING -p tcp --dport 504 -j DNAT --to-destination [$OPENVPN_IP6]:50443
	ip6tables -w -t nat -A PREROUTING -p tcp --dport 508 -j DNAT --to-destination [$OPENVPN_IP6]:50080
	ip6tables -w -t nat -A PREROUTING -p tcp --dport 50080 -j DNAT --to-destination [$OPENVPN_IP6]:50080
	ip6tables -w -t nat -A PREROUTING -p tcp --dport 50443 -j DNAT --to-destination [$OPENVPN_IP6]:50443
fi
# OpenVPN UDP IPv6
if [[ "$OPENVPN_UDP" == 'y' && -n "$OPENVPN_IP6" ]]; then
#	ip6tables -w -t nat -A PREROUTING -p udp --dport 80 -j DNAT --to-destination [$OPENVPN_IP6]:50080
#	ip6tables -w -t nat -A PREROUTING -p udp --dport 443 -j DNAT --to-destination [$OPENVPN_IP6]:50443
	ip6tables -w -t nat -A PREROUTING -p udp --dport 504 -j DNAT --to-destination [$OPENVPN_IP6]:50443
	ip6tables -w -t nat -A PREROUTING -p udp --dport 508 -j DNAT --to-destination [$OPENVPN_IP6]:50080
	ip6tables -w -t nat -A PREROUTING -p udp --dport 50080 -j DNAT --to-destination [$OPENVPN_IP6]:50080
	ip6tables -w -t nat -A PREROUTING -p udp --dport 50443 -j DNAT --to-destination [$OPENVPN_IP6]:50443
fi
# WireGuard/AmneziaWG IPv6
if [[ "$WIREGUARD" == 'y' && -n "$WIREGUARD_IP6" ]]; then
	ip6tables -w -t nat -A PREROUTING -p udp --dport 540 -j DNAT --to-destination [$WIREGUARD_IP6]:51443
	ip6tables -w -t nat -A PREROUTING -p udp --dport 580 -j DNAT --to-destination [$WIREGUARD_IP6]:51080
	ip6tables -w -t nat -A PREROUTING -p udp --dport 51080 -j DNAT --to-destination [$WIREGUARD_IP6]:51080
	ip6tables -w -t nat -A PREROUTING -p udp --dport 51443 -j DNAT --to-destination [$WIREGUARD_IP6]:51443
	ip6tables -w -t nat -A PREROUTING -p udp --dport 52080 -j DNAT --to-destination [$WIREGUARD_IP6]:51080
	ip6tables -w -t nat -A PREROUTING -p udp --dport 52443 -j DNAT --to-destination [$WIREGUARD_IP6]:51443
fi
# SNAT IPv6
if [[ -n "$OPENVPN_IP6" ]]; then
	ip6tables -w -t nat -A POSTROUTING -d $OPENVPN_IP6 -j SNAT --to-source $DEFAULT_IP6
fi
if [[ -n "$WIREGUARD_IP6" && "$WIREGUARD_IP6" != "$OPENVPN_IP6" ]]; then
	ip6tables -w -t nat -A POSTROUTING -d $WIREGUARD_IP6 -j SNAT --to-source $DEFAULT_IP6
fi

# Сброс счётчиков
iptables -w -Z
iptables -w -t nat -Z
iptables -w -t mangle -Z
iptables -w -t raw -Z
ip6tables -w -Z
ip6tables -w -t nat -Z
ip6tables -w -t mangle -Z
ip6tables -w -t raw -Z

# Сохранение новых правил iptables
netfilter-persistent save
systemctl enable netfilter-persistent

# Перезагружаем
echo
echo -e '\e[1;32mProxy for AntiZapret VPN server installed successfully!\e[0m'
reboot