```
bash <(wget -qO- --no-hsts --inet4-only https://raw.githubusercontent.com/TripleA150/AntiZapret-VPN/patch-1/setup.sh)
```

## Поддержка IPv6

Установщик задаёт вопрос `Enable IPv6 support? [y/n]` (по умолчанию `y`, если у сервера
есть глобальный IPv6-адрес). Выбор сохраняется в `/root/antizapret/setup` в переменной `IPV6`,
после её изменения нужно перезапустить установку или отредактировать конфиги вручную.

Когда IPv6 включён:

* OpenVPN слушает `proto udp`/`proto tcp` (двойной стек), WireGuard/AmneziaWG слушает IPv6 всегда —
  клиенты могут подключаться к серверу как по IPv4, так и по IPv6;
* внутри туннеля клиенты получают IPv6-адреса из ULA-подсетей, IPv6-адрес клиента образуется
  из последнего октета его IPv4-адреса (`10.29.8.5` → `fd29:0:0:8::5`);
* полный VPN (`vpn-*`) заворачивает в туннель весь IPv6-трафик (`redirect-gateway ipv6`, `AllowedIPs = ::/0`);
* AntiZapret VPN (`antizapret-*`) заворачивает в туннель только подменные IPv6-адреса и IPv6-подсети
  из `config/include-ips.txt` и `download/*ips.txt` — раньше IPv6-подсети из этих списков отбрасывались;
* Knot Resolver перестаёт отвечать `::` на AAAA-запросы, а AAAA заблокированных доменов
  подменяются адресами из `fd30::/32` и разворачиваются обратно через `DNAT` в `ip6tables`;
* исходящий IPv6-трафик клиентов транслируется (`SNAT`/`MASQUERADE`) в IPv6-адрес сервера
  или в IPv6-адрес Cloudflare WARP, если WARP включён.

Когда IPv6 выключен, поведение прежнее: IPv6 отключается через `sysctl`, OpenVPN работает
на `udp4`/`tcp4` с `block-ipv6`, а AAAA-запросы получают в ответ `::`.

Используемые IPv6-подсети (меняются переменными в `/root/antizapret/setup`):

| Подсеть | Назначение |
| --- | --- |
| `fd29::/48` | AntiZapret VPN (`ANTIZAPRET_NET6`) |
| `fd28::/48` | полный VPN (`VPN_NET6`) |
| `fd28::/47` | обе подсети сразу (`CLIENT_NET6`) |
| `fd30::/32` | подменные IPv6-адреса (`FAKE_NET6`) |
| `fd29:0:0:8::1` | шлюз WireGuard/AmneziaWG AntiZapret VPN (`ANTIZAPRET_WG_IP6`) |
| `fd28:0:0:8::1` | шлюз WireGuard/AmneziaWG полного VPN (`VPN_WG_IP6`) |

`proxy.sh` тоже умеет проксировать IPv6-подключения — при установке он спросит IPv6-адрес
сервера AntiZapret VPN, и если его указать, добавит правила `DNAT`/`SNAT` в `ip6tables`.
