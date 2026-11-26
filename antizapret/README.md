[← README](../README.md)

# Прокладка к AntiZapret-VPN

Частый случай: сервер [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) закрыт для клиентов по IPv4,
а по IPv6 доступен. Прокладка принимает клиентов по IPv4 и ведёт их к серверу по IPv6. Нужны три шага.

## 1. На сервере AntiZapret: `custom-up.sh`

Две вещи мешают прокладке работать с AntiZapret по IPv6:

- **OpenVPN слушает только IPv4** (`proto udp4`, `proto tcp4`) и соединения прокладки по IPv6 не примет.
  `udp6` и `tcp6` принимают и IPv6, и IPv4, так что клиенты, которые ходят напрямую, продолжат работать.
  WireGuard и AmneziaWG принимают IPv6 и так.
- **Защита от атак** (если включена) видит всех клиентов прокладки как один адрес. Её лимит — 100 000 новых
  соединений в час с адреса. Файла исключений для IPv6 у AntiZapret нет: адрес прокладки добавляется в набор
  `antizapret-allow6` командой, и после перезагрузки он пропадает.

Обе правки кладём в `/root/antizapret/custom-up.sh`: AntiZapret запускает его при каждом старте (и при загрузке
сервера), а при переустановке сохраняет. Переустановка возвращает `udp4` в конфигах OpenVPN — `custom-up.sh`
при следующем старте поправит их снова.

Допишите в конец `/root/antizapret/custom-up.sh` (вместо `2001:db8::5` — IPv6-адрес прокладки,
`ip -6 addr show scope global` на ней):

```bash
# nginx-stream: OpenVPN принимает и IPv6 (переустановка AntiZapret возвращает udp4/tcp4)
cd /etc/openvpn/server &&
	if grep -qsE '^proto (udp|tcp)4$' antizapret-udp.conf vpn-udp.conf antizapret-tcp.conf vpn-tcp.conf; then
		sed -i -E 's/^proto (udp|tcp)4$/proto \16/' antizapret-udp.conf vpn-udp.conf antizapret-tcp.conf vpn-tcp.conf
		systemctl --no-block try-restart openvpn-server@antizapret-udp openvpn-server@vpn-udp \
			openvpn-server@antizapret-tcp openvpn-server@vpn-tcp 2>/dev/null
	fi
cd /root/antizapret
# nginx-stream: адрес прокладки - в исключения защиты от атак
ipset add antizapret-allow6 2001:db8::5 -exist 2>/dev/null || true
```

Применить сразу: `systemctl restart antizapret`. Серверы OpenVPN перезапустятся один раз — клиенты
переподключатся; при следующих стартах, если конфиги уже правильные, OpenVPN не трогается.

Проверить:

```bash
grep -H '^proto' /etc/openvpn/server/*.conf    # udp6 / tcp6
ss -Hlnup | grep openvpn                       # [::]:50443, [::]:50080 и т. д.
ipset list antizapret-allow6 | tail -n 3       # адрес прокладки (только при включённой защите)
```

Защита выключена — строка с `ipset` ничего не делает. Проверено на UDP; TCP настраивается так же.

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
