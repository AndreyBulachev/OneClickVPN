#!/usr/bin/env bash
set -Eeuo pipefail

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-xray-reality.conf"
readonly CLIENT_OUTPUT="/root/xray-reality-client.txt"
readonly PORT="443"

PRESET_DESTS=(
  "www.microsoft.com"
  "www.samsung.com"
  "www.asus.com"
  "dl.google.com"
  "www.logitech.com"
  "www.apple.com"
)

log() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$*" >&2
}

ok() {
  printf '\033[1;32mOK:\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

print_banner() {
  printf '\n\033[1;34mXray VLESS Reality installer\033[0m\n' >&2
  printf 'Ubuntu-only setup for Xray-core, VLESS and XTLS-Reality.\n' >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Запустите скрипт от root: sudo bash $0"
  fi
}

require_ubuntu() {
  if [[ ! -r /etc/os-release ]]; then
    die "Не удалось определить ОС. Скрипт рассчитан на Ubuntu."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Обнаружена ОС '${PRETTY_NAME:-unknown}'. Скрипт рассчитан на Ubuntu."
  fi
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[YyДд]$ ]]
}

apt_prepare() {
  log "Обновление системы и установка утилит"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get upgrade -y
  apt-get autoremove -y
  apt-get install -y \
    ca-certificates curl wget git vim nano htop net-tools \
    netcat-openbsd iputils-ping telnet openssl ufw jq qrencode \
    lsb-release gnupg unzip
}

configure_ufw() {
  log "Настройка UFW"

  local ssh_port
  ssh_port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  ssh_port="${ssh_port:-22}"

  ufw allow "${ssh_port}/tcp" comment "SSH"
  ufw allow "${PORT}/tcp" comment "Xray VLESS Reality"
  ufw allow "${PORT}/udp" comment "Xray VLESS Reality UDP"
  ufw --force enable
  ufw status verbose
}

configure_sysctl() {
  log "Включение BBR и оптимизация сетевых параметров ядра"

  cat > "$SYSCTL_CONFIG" <<'EOF'
# Xray Reality VPN TCP tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 1024 65535
EOF

  sysctl --system >/dev/null

  local congestion_control
  congestion_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$congestion_control" == "bbr" ]]; then
    ok "BBR активирован."
  else
    warn "BBR не активирован сейчас (текущее значение: ${congestion_control:-unknown}). Может потребоваться ребут или поддержка BBR в ядре."
  fi
}

install_xray() {
  log "Установка Xray-core официальным installer-скриптом"

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || die "Xray не найден после установки."
  xray version || xray -version
}

normalize_dest() {
  local raw="$1"
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%%/*}"
  raw="${raw%%\?*}"
  raw="${raw%%#*}"

  if [[ "$raw" == *:* ]]; then
    printf '%s' "$raw"
  else
    printf '%s:443' "$raw"
  fi
}

dest_host() {
  printf '%s' "${1%:*}"
}

dest_port() {
  printf '%s' "${1##*:}"
}

is_valid_host_port() {
  local dest="$1"
  local host port
  host="$(dest_host "$dest")"
  port="$(dest_port "$dest")"

  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$host" == *.* ]] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

extract_x25519_key() {
  local label="$1"
  awk -v wanted="$label" '
    BEGIN {
      wanted = tolower(wanted)
      gsub(/[^a-z0-9]/, "", wanted)
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line !~ /:/) {
        next
      }

      key_label = line
      sub(/:.*/, "", key_label)
      key_label = tolower(key_label)
      gsub(/[^a-z0-9]/, "", key_label)

      if (key_label == wanted) {
        value = line
        sub(/^[^:]*:/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  '
}

check_dest_site() {
  local dest="$1"
  local host port http_code tls_output alpn_output
  host="$(dest_host "$dest")"
  port="$(dest_port "$dest")"

  printf 'Проверяю %s...\n' "$dest" >&2

  if ! is_valid_host_port "$dest"; then
    warn "Некорректный формат. Используйте domain или domain:port."
    return 1
  fi

  if ! tls_output="$(timeout 10 openssl s_client -tls1_3 -servername "$host" -connect "$host:$port" </dev/null 2>&1)"; then
    warn "TLS 1.3 handshake не прошёл."
    return 1
  fi

  if ! grep -q "Verify return code: 0 (ok)" <<<"$tls_output"; then
    warn "Сертификат сайта не прошёл проверку системным CA-store. Продолжаю: для Reality это не является обязательным условием."
  fi

  if ! grep -Eq "TLSv1\.3|Protocol *: TLSv1\.3|New, TLSv1\.3" <<<"$tls_output"; then
    warn "Не подтверждена поддержка TLS 1.3."
    return 1
  fi

  alpn_output="$(timeout 10 openssl s_client -tls1_3 -alpn h2 -servername "$host" -connect "$host:$port" </dev/null 2>&1 || true)"
  if grep -q "ALPN protocol: h2" <<<"$alpn_output"; then
    ok "HTTP/2 через ALPN h2 подтверждён."
  else
    warn "HTTP/2 через ALPN h2 не подтверждён. Продолжаю: это некритичная проверка для Reality."
  fi

  http_code="$(curl -4 -L -I -sS --connect-timeout 8 --max-time 15 -o /dev/null -w '%{http_code}' "https://$host:$port" || true)"
  if [[ ! "$http_code" =~ ^(2|3)[0-9][0-9]$ ]]; then
    warn "Сайт отвечает HTTP $http_code, ожидался 2xx или 3xx."
    return 1
  fi

  ok "TLS 1.3 и доступность подтверждены для ${dest}."
}

choose_dest_site() {
  log "Выбор dest-сайта для Reality"

  local choice custom dest i
  while true; do
    printf '\nРекомендуемые варианты:\n' >&2
    for i in "${!PRESET_DESTS[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${PRESET_DESTS[$i]}" >&2
    done
    printf '  %d) Указать свой сайт\n' "$((${#PRESET_DESTS[@]} + 1))" >&2

    read -r -p "Выберите dest-сайт [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#PRESET_DESTS[@]} )); then
      dest="$(normalize_dest "${PRESET_DESTS[$((choice - 1))]}")"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice == ${#PRESET_DESTS[@]} + 1 )); then
      read -r -p "Введите домен или domain:port: " custom
      dest="$(normalize_dest "$custom")"
    else
      warn "Неверный выбор."
      continue
    fi

    if check_dest_site "$dest"; then
      printf '%s' "$dest"
      return 0
    fi

    warn "Этот dest-сайт не подходит. Выберите другой."
  done
}

generate_materials() {
  log "Генерация UUID, Reality x25519-ключей и shortId"

  XRAY_UUID="$(xray uuid)"

  local key_output
  if ! key_output="$(xray x25519 2>&1)"; then
    die "Не удалось выполнить 'xray x25519'. Проверьте установку Xray."
  fi
  REALITY_PRIVATE_KEY="$(extract_x25519_key "privatekey" <<<"$key_output")"
  REALITY_PUBLIC_KEY="$(extract_x25519_key "publickey" <<<"$key_output")"
  if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
    REALITY_PUBLIC_KEY="$(extract_x25519_key "password" <<<"$key_output")"
  fi
  SHORT_ID="$(openssl rand -hex 8)"

  [[ -n "$XRAY_UUID" ]] || die "Не удалось сгенерировать UUID."
  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Не удалось получить private key из xray x25519."
  [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Не удалось получить public key/password из xray x25519."
}

detect_server_address() {
  log "Определение адреса сервера"

  local detected service candidate
  detected=""
  for service in \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://ipv4.icanhazip.com"; do
    candidate="$(curl -4 -sS --connect-timeout 5 --max-time 8 "$service" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      detected="$candidate"
      break
    fi
  done

  if [[ -n "$detected" ]]; then
    read -r -p "Публичный адрес сервера [$detected]: " SERVER_ADDRESS
    SERVER_ADDRESS="${SERVER_ADDRESS:-$detected}"
  else
    read -r -p "Введите публичный IP или домен сервера: " SERVER_ADDRESS
  fi

  [[ -n "$SERVER_ADDRESS" ]] || die "Адрес сервера обязателен для клиентской ссылки."
}

write_xray_config() {
  log "Создание серверной конфигурации Xray"

  local dest="$1"
  local host
  host="$(dest_host "$dest")"

  install -d -m 755 /usr/local/etc/xray /var/log/xray
  chown -R nobody:nogroup /var/log/xray 2>/dev/null || chown -R nobody:nobody /var/log/xray

  if [[ -f "$XRAY_CONFIG" ]]; then
    cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "info",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "serverNames": [
            "${host}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "AsIs"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ]
}
EOF

  chmod 600 "$XRAY_CONFIG"
}

validate_xray_config() {
  log "Проверка конфигурации Xray"

  jq empty "$XRAY_CONFIG"

  if ! xray run -test -config "$XRAY_CONFIG"; then
    die "Xray отклонил конфигурацию. Сервис не будет запущен."
  fi
}

start_xray() {
  log "Запуск Xray и включение автозагрузки"

  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  sleep 2

  if ! systemctl is-active --quiet xray; then
    systemctl --no-pager --full status xray || true
    die "Xray не запустился. Смотри: journalctl -u xray -n 50"
  fi

  systemctl --no-pager --full status xray
  ok "Xray активен."
}

build_client_uri() {
  local dest="$1"
  local sni remark encoded_remark
  sni="$(dest_host "$dest")"
  remark="Xray-Reality-${SERVER_ADDRESS}"
  encoded_remark="${remark// /%20}"

  CLIENT_URI="vless://${XRAY_UUID}@${SERVER_ADDRESS}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${encoded_remark}"
}

save_client_config() {
  cat > "$CLIENT_OUTPUT" <<EOF
Server: ${SERVER_ADDRESS}
Port: ${PORT}
Protocol: VLESS
Security: Reality
Flow: xtls-rprx-vision
SNI: $(dest_host "$DEST_SITE")
Dest: ${DEST_SITE}
UUID: ${XRAY_UUID}
Public key: ${REALITY_PUBLIC_KEY}
Short ID: ${SHORT_ID}
Fingerprint: chrome

${CLIENT_URI}
EOF
  chmod 600 "$CLIENT_OUTPUT"
  ok "Клиентская конфигурация сохранена в ${CLIENT_OUTPUT}."
}

print_client_config() {
  log "Клиентская конфигурация"

  printf '\n%s\n\n' "$CLIENT_URI"
  qrencode -t ansiutf8 "$CLIENT_URI"

  printf '\nПараметры подключения:\n'
  printf '  Server      : %s\n' "$SERVER_ADDRESS"
  printf '  Port        : %s\n' "$PORT"
  printf '  UUID        : %s\n' "$XRAY_UUID"
  printf '  Public key  : %s\n' "$REALITY_PUBLIC_KEY"
  printf '  Short ID    : %s\n' "$SHORT_ID"
  printf '  SNI         : %s\n' "$(dest_host "$DEST_SITE")"
  printf '  Dest        : %s\n' "$DEST_SITE"
  printf '  Fingerprint : chrome\n'

  printf '\nПолезные команды:\n'
  printf '  systemctl status xray\n'
  printf '  journalctl -u xray -f\n'
  printf '  systemctl restart xray\n'
  printf '  xray run -test -config %s\n' "$XRAY_CONFIG"

  printf '\nРекомендуемые клиенты:\n'
  printf '  Android : v2rayNG, Hiddify\n'
  printf '  iOS     : Hiddify, Shadowrocket\n'
  printf '  Windows : v2rayN\n'
  printf '  macOS   : V2Box, Hiddify\n'
  printf '  Linux   : Nekoray, Hiddify\n'

  printf '\nКонфигурация сохранена в %s\n' "$CLIENT_OUTPUT"
}

final_checks() {
  log "Итоговая проверка"

  local congestion_control
  congestion_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  printf 'BBR: %s\n' "${congestion_control:-unknown}"
  if [[ "$congestion_control" != "bbr" ]]; then
    warn "BBR не активен. VPN может работать, но TCP-ускорение не применилось."
  fi

  printf '\nUFW:\n'
  ufw status

  printf '\nПорт %s:\n' "$PORT"
  ss -tlnp | grep ":${PORT} " || warn "Порт ${PORT} не найден в LISTEN. Проверьте journalctl -u xray -n 100."

  printf '\nXray:\n'
  systemctl is-active --quiet xray && printf 'active\n' || die "Сервис xray не активен."
}

self_test_assert_equal() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual  : %s\n' "$name" "$expected" "$actual" >&2
    return 1
  fi
}

self_test() {
  local old_format new_format spaced_format
  old_format=$'Private key: old-private\nPublic key: old-public'
  new_format=$'PrivateKey: new-private\nPassword: new-password\nHash32: ignored'
  spaced_format=$'Private key : spaced-private\r\nPublic key : spaced-public'

  self_test_assert_equal "old private key" "old-private" "$(extract_x25519_key "privatekey" <<<"$old_format")"
  self_test_assert_equal "old public key" "old-public" "$(extract_x25519_key "publickey" <<<"$old_format")"
  self_test_assert_equal "new private key" "new-private" "$(extract_x25519_key "privatekey" <<<"$new_format")"
  self_test_assert_equal "new password as public key" "new-password" "$(extract_x25519_key "password" <<<"$new_format")"
  self_test_assert_equal "spaced private key" "spaced-private" "$(extract_x25519_key "privatekey" <<<"$spaced_format")"
  self_test_assert_equal "spaced public key" "spaced-public" "$(extract_x25519_key "publickey" <<<"$spaced_format")"

  ok "Self-test passed."
}

main() {
  declare XRAY_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY SHORT_ID SERVER_ADDRESS DEST_SITE CLIENT_URI

  print_banner
  require_root
  require_ubuntu

  warn "Скрипт изменит firewall, sysctl, установит Xray и перезапишет ${XRAY_CONFIG}."
  if ! confirm "Продолжить установку?"; then
    die "Установка отменена пользователем."
  fi

  apt_prepare
  configure_ufw
  configure_sysctl
  install_xray
  DEST_SITE="$(choose_dest_site)"
  generate_materials
  detect_server_address
  write_xray_config "$DEST_SITE"
  validate_xray_config
  build_client_uri "$DEST_SITE"
  save_client_config
  start_xray
  final_checks
  print_client_config

  ok "Готово."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi

  main "$@"
fi
