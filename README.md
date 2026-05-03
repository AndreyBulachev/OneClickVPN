# OneClickVPN

Интерактивный Bash-скрипт для установки и настройки VPN-сервера на Ubuntu с использованием Xray-core, VLESS и XTLS-Reality.

Скрипт основан на разделах 2.3 и 3 материала [VPN-сервер с протоколом VLESS: теория и базовая настройка](https://github.com/AndreyBulachev/Product-Engineer-from-scratch/blob/master/course/appendix-vpn-vless/C1-vpn-theory-and-setup.md).

## Что делает скрипт

- Обновляет систему через `apt`.
- Устанавливает необходимые утилиты: `curl`, `wget`, `openssl`, `ufw`, `jq`, `qrencode` и сетевые инструменты.
- Настраивает UFW:
  - разрешает SSH;
  - открывает порт `443/tcp` для VLESS Reality;
  - открывает порт `443/udp`.
- Включает BBR (`net.ipv4.tcp_congestion_control=bbr`).
- Добавляет сетевые оптимизации ядра в `/etc/sysctl.d/99-xray-reality.conf`.
- Устанавливает Xray-core официальным скриптом XTLS.
- Генерирует:
  - UUID для одного пользователя;
  - Reality X25519 private/public key;
  - shortId.
- Предлагает выбрать `dest`-сайт для Reality из списка или указать свой.
- Проверяет пользовательский `dest`-сайт на пригодность:
  - корректный формат домена;
  - TLS 1.3 handshake;
  - валидный сертификат;
  - HTTP/2 через ALPN `h2`;
  - HTTP-ответ `2xx` или `3xx`.
- Создаёт серверный конфиг Xray в `/usr/local/etc/xray/config.json`.
- Проверяет конфиг через `xray run -test`.
- Запускает `xray` и включает автозапуск через `systemd`.
- Формирует VLESS-ссылку и QR-код для клиента.
- Сохраняет клиентскую конфигурацию в `/root/xray-reality-client.txt`.

## Требования

- Ubuntu server.
- Root-доступ или пользователь с `sudo`.
- Открытый входящий порт `443` у провайдера/VPS.
- Рабочее сетевое соединение с GitHub для установки Xray-core.

## Как запустить

На чистом Ubuntu-сервере выполните:

```bash
sudo apt-get update
sudo apt-get install -y curl
curl -L https://raw.githubusercontent.com/AndreyBulachev/OneClickVPN/main/core/ubuntu/install-xray-reality.sh -o install-xray-reality.sh
chmod +x install-xray-reality.sh
sudo bash install-xray-reality.sh
```

Скрипт интерактивный: он попросит подтвердить установку, выбрать `dest`-сайт для Reality и подтвердить публичный IP или домен сервера для клиентской ссылки.

После успешного завершения скрипт выведет:

- VLESS-ссылку для импорта в клиент;
- QR-код для мобильных клиентов;
- путь к файлу с параметрами: `/root/xray-reality-client.txt`.

## Клиенты

Полученную VLESS-ссылку или QR-код можно импортировать в клиенты с поддержкой VLESS Reality, например:

- Hiddify;
- v2rayN;
- v2rayNG;
- NekoBox;
- FoXray.

## Безопасность

Скрипт меняет firewall, sysctl-настройки, устанавливает Xray и перезаписывает `/usr/local/etc/xray/config.json`. Если файл конфигурации уже существует, перед заменой создаётся backup рядом с ним.

Перед запуском убедитесь, что SSH-порт корректно разрешён и доступ к серверу не зависит только от текущей SSH-сессии.

## Лицензия

Проект распространяется бесплатно для личного некоммерческого использования. Коммерческое использование запрещено без отдельного письменного разрешения автора.

Подробности см. в файле [LICENSE](LICENSE).
