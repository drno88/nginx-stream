[← README](../README.md)

# Прокладка к AntiZapret-VPN

Частый случай: сервер [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) закрыт для клиентов по IPv4,
а по IPv6 доступен. Прокладка принимает клиентов по IPv4 и ведёт их к серверу по IPv6. Нужны три шага.

## 1. На сервере AntiZapret: OpenVPN по IPv6

AntiZapret настраивает OpenVPN только на IPv4 (`proto udp4`, `proto tcp4`), и соединения от прокладки по IPv6
он не примет. Поменяйте строку `proto` и перезапустите работающие серверы OpenVPN:

```bash
cd /etc/openvpn/server
sed -i 's/^proto udp4$/proto udp6/' antizapret-udp.conf vpn-udp.conf
sed -i 's/^proto tcp4$/proto tcp6/' antizapret-tcp.conf vpn-tcp.conf
systemctl try-restart openvpn-server@antizapret-udp openvpn-server@vpn-udp \
  openvpn-server@antizapret-tcp openvpn-server@vpn-tcp
```

`udp6` и `tcp6` принимают и IPv6, и IPv4, так что клиенты, которые ходят напрямую, продолжают работать.
WireGuard и AmneziaWG по IPv6 принимают и без правок. **После переустановки или обновления AntiZapret
правку повторите** — он вернёт `udp4`. Проверено на UDP; TCP настраивается так же.

## 2. На прокладке: установка с портами AntiZapret

Запасные порты (80, 443, 504, 508, 540, 580, 52080, 52443) AntiZapret переводит в настоящие только для IPv4,
поэтому для IPv6 это делает прокладка:

```bash
bash <(wget -qO- --inet4-only https://raw.githubusercontent.com/drno88/nginx-stream/main/install.sh) \
  --target 2001:db8::10 \
  --ports 'both:80>50080,both:443>50443,both:504>50443,both:508>50080,both:50080,both:50443,udp:540>51443,udp:580>51080,udp:52080>51080,udp:52443>51443,udp:51080,udp:51443'
```

Вместо `2001:db8::10` — IPv6-адрес сервера AntiZapret (`ip -6 addr show scope global` на нём). Остальное
установщик спросит.

| Порты на прокладке | Порт на сервере AntiZapret | Что |
|---|---|---|
| 80, 508, 50080 | 50080 | OpenVPN |
| 443, 504, 50443 | 50443 | OpenVPN |
| 580, 52080, 51080 | 51080 | WireGuard / AmneziaWG |
| 540, 52443, 51443 | 51443 | WireGuard / AmneziaWG |

Если OpenVPN по TCP не нужен, замените `both:` на `udp:`. Порт 80 прокладка может взять, только если на нём
нет сайта; иначе уберите правило `both:80>50080`.

## 3. Клиентам: адрес прокладки

В профилях замените адрес сервера AntiZapret на адрес прокладки: строка `remote` в OpenVPN, `Endpoint` в WireGuard
и AmneziaWG. Порты не меняются.

## Если в AntiZapret включена защита от атак

Все клиенты приходят к нему с одного адреса прокладки. Лимит защиты — 100 000 новых соединений в час с адреса;
обычно этого хватает. Файла исключений для IPv6 у AntiZapret нет; при большой нагрузке адрес прокладки можно
исключить командой `ipset add antizapret-allow6 <IPv6 прокладки>` (действует до перезапуска AntiZapret).
