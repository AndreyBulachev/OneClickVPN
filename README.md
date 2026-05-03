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
  - HTTP-ответ `2xx` или `3xx`.
- Предупреждает, если системный CA-store не подтверждает сертификат `dest`-сайта или если HTTP/2 через ALPN `h2` не подтверждён. Эти проверки не блокируют установку, потому что для Reality критична поддержка TLS 1.3.
- Создаёт серверный конфиг Xray в `/usr/local/etc/xray/config.json`.
- Проверяет конфиг через `xray run -test`.
- Запускает `xray` и включает автозапуск через `systemd`.
- Формирует VLESS-ссылку и QR-код для клиента.
- Сохраняет клиентскую конфигурацию в `/root/xray-reality-client.txt`.
- В репозитории есть отдельный скрипт управления пользователями Xray: просмотр списка, добавление и удаление клиентов в `settings.clients`.

## Требования

- Ubuntu server.
- Debian этим скриптом не поддерживается; для Debian нужен отдельный сценарий установки и проверки зависимостей.
- Root-доступ или пользователь с `sudo`.
- Открытый входящий порт `443` у провайдера/VPS.
- Рабочее сетевое соединение с GitHub для установки Xray-core.

## Как запустить

На чистом Ubuntu-сервере выполните:

```bash
sudo apt-get update
sudo apt-get install -y curl
curl -L https://raw.githubusercontent.com/AndreyBulachev/OneClickVPN/master/core/ubuntu/install-xray-reality.sh -o install-xray-reality.sh
chmod +x install-xray-reality.sh
sudo bash install-xray-reality.sh
```

Скрипт интерактивный: он попросит подтвердить установку, выбрать `dest`-сайт для Reality и подтвердить публичный IP или домен сервера для клиентской ссылки.

## Локальная проверка

Перед публикацией можно проверить синтаксис и встроенные unit-проверки парсинга:

```bash
bash -n core/ubuntu/install-xray-reality.sh
bash -n core/ubuntu/manage-xray-users.sh
bash core/ubuntu/install-xray-reality.sh --self-test
bash core/ubuntu/manage-xray-users.sh --self-test
```

Для проверки в чистой Ubuntu 24.04 через Docker:

```bash
bash scripts/test-install-xray-reality-docker.sh
```

Чтобы дополнительно скачать свежий Xray release и проверить реальный формат `xray x25519`:

```bash
LIVE_XRAY_TEST=1 bash scripts/test-install-xray-reality-docker.sh
```

После успешного завершения скрипт выведет:

- VLESS-ссылку для импорта в клиент;
- QR-код для мобильных клиентов;
- путь к файлу с параметрами: `/root/xray-reality-client.txt`.

## Управление пользователями Xray

После установки можно управлять клиентами в `/usr/local/etc/xray/config.json` отдельным скриптом:

```bash
curl -L https://raw.githubusercontent.com/AndreyBulachev/OneClickVPN/master/core/ubuntu/manage-xray-users.sh -o manage-xray-users.sh
chmod +x manage-xray-users.sh
```

Вывести список пользователей:

```bash
sudo bash manage-xray-users.sh list
```

Добавить пользователя и получить VLESS-ссылку:

```bash
sudo bash manage-xray-users.sh add user@example.com --server YOUR_SERVER_IP_OR_DOMAIN
```

Удалить пользователя по email или UUID:

```bash
sudo bash manage-xray-users.sh delete user@example.com
sudo bash manage-xray-users.sh delete 00000000-0000-4000-8000-000000000000
```

Скрипт перед изменением делает backup рядом с конфигом, проверяет новый JSON через `xray run -test` и перезапускает `xray`. Для сухой проверки без перезапуска можно добавить `--no-restart`.

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
