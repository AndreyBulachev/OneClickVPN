#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_CONFIG="${XRAY_CONFIG:-$DEFAULT_XRAY_CONFIG}"
readonly DEFAULT_PORT="443"

RESTART_XRAY=1
SERVER_ADDRESS="${SERVER_ADDRESS:-}"

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

usage() {
  cat <<EOF
Управление пользователями Xray VLESS Reality.

Использование:
  sudo bash $0 list [--config PATH]
  sudo bash $0 add EMAIL [--server IP_OR_DOMAIN] [--config PATH] [--no-restart]
  sudo bash $0 delete UUID_OR_EMAIL [--config PATH] [--no-restart]

Команды:
  list              вывести пользователей из первого VLESS inbound
  add EMAIL         добавить пользователя, сгенерировать UUID и VLESS-ссылку
  delete TARGET     удалить пользователя по UUID или email

Опции:
  --config PATH     путь к config.json (по умолчанию: ${DEFAULT_XRAY_CONFIG})
  --server VALUE    публичный IP или домен сервера для клиентской ссылки
  --no-restart      проверить конфиг, но не перезапускать systemd-сервис xray
  -h, --help        показать справку
EOF
}

require_root() {
  if [[ "${XRAY_USER_ALLOW_NON_ROOT_FOR_TESTS:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    die "Запустите скрипт от root: sudo bash $0"
  fi
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "Нужен jq. Установите: sudo apt-get install -y jq"
  command -v xray >/dev/null 2>&1 || die "Нужен xray в PATH."
}

backup_config() {
  cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
}

validate_email_label() {
  local email="$1"
  [[ -n "$email" ]] || die "EMAIL обязателен."
  [[ "$email" =~ ^[A-Za-z0-9._%+=:@-]+$ ]] || die "EMAIL содержит неподдерживаемые символы."
}

validate_target() {
  local target="$1"
  [[ -n "$target" ]] || die "Укажите UUID или email пользователя."
}

vless_inbound_index() {
  jq -er '
    (.inbounds // [])
    | to_entries
    | map(select(.value.protocol == "vless"))
    | first
    | .key
  ' "$XRAY_CONFIG"
}

ensure_config() {
  [[ -r "$XRAY_CONFIG" ]] || die "Конфиг не найден или недоступен для чтения: ${XRAY_CONFIG}"
  jq empty "$XRAY_CONFIG" >/dev/null
  vless_inbound_index >/dev/null || die "В ${XRAY_CONFIG} не найден inbound с protocol=vless."
}

list_users() {
  ensure_config

  local inbound_index
  inbound_index="$(vless_inbound_index)"

  jq -r --argjson i "$inbound_index" '
    .inbounds[$i].settings.clients // []
    | if length == 0 then
        "Пользователей нет."
      else
        (["UUID", "EMAIL", "FLOW", "LEVEL"] | @tsv),
        (.[] | [.id, (.email // "-"), (.flow // "-"), ((.level // 0) | tostring)] | @tsv)
      end
  ' "$XRAY_CONFIG" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
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

      if (key_label == wanted || index(key_label, wanted) > 0) {
        value = line
        sub(/^[^:]*:/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  '
}

public_key_from_private() {
  local private_key="$1"
  local key_output public_key

  key_output="$(xray x25519 -i "$private_key" 2>/dev/null || true)"
  public_key="$(extract_x25519_key "publickey" <<<"$key_output")"
  if [[ -z "$public_key" ]]; then
    public_key="$(extract_x25519_key "password" <<<"$key_output")"
  fi

  printf '%s' "$public_key"
}

detect_server_address() {
  local detected service candidate

  if [[ -n "$SERVER_ADDRESS" ]]; then
    printf '%s' "$SERVER_ADDRESS"
    return 0
  fi

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

  if [[ -n "${detected:-}" ]]; then
    printf '%s' "$detected"
    return 0
  fi

  warn "Не удалось определить публичный IP. Передайте --server IP_OR_DOMAIN, чтобы получить готовую VLESS-ссылку."
  printf ''
}

build_client_uri() {
  local uuid="$1"
  local email="$2"
  local inbound_index server port sni private_key public_key short_id encoded_email
  inbound_index="$(vless_inbound_index)"

  server="$(detect_server_address)"
  [[ -n "$server" ]] || return 0

  port="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].port // "'"$DEFAULT_PORT"'"' "$XRAY_CONFIG")"
  sni="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].streamSettings.realitySettings.serverNames[0] // (.inbounds[$i].streamSettings.realitySettings.dest | split(":")[0])' "$XRAY_CONFIG")"
  private_key="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].streamSettings.realitySettings.privateKey // ""' "$XRAY_CONFIG")"
  short_id="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].streamSettings.realitySettings.shortIds[0] // ""' "$XRAY_CONFIG")"
  public_key="$(public_key_from_private "$private_key")"

  [[ -n "$public_key" ]] || die "Не удалось получить public key из privateKey. Проверьте 'xray x25519 -i'."
  [[ -n "$short_id" ]] || die "В Reality-настройках не найден shortIds[0]."
  [[ -n "$sni" && "$sni" != "null" ]] || die "В Reality-настройках не найден serverNames[0] или dest."

  encoded_email="${email// /%20}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$server" "$port" "$sni" "$public_key" "$short_id" "$encoded_email"
}

validate_xray_config() {
  local config_path="${1:-$XRAY_CONFIG}"
  jq empty "$config_path" >/dev/null
  xray run -test -config "$config_path" >/dev/null
}

restart_xray() {
  if [[ "$RESTART_XRAY" -eq 0 ]]; then
    warn "Перезапуск xray пропущен (--no-restart)."
    return 0
  fi

  systemctl restart xray
  systemctl is-active --quiet xray || die "xray не активен после перезапуска. Смотрите: journalctl -u xray -n 50"
}

add_user() {
  local email="$1"
  local inbound_index uuid tmp_file
  validate_email_label "$email"
  ensure_config

  inbound_index="$(vless_inbound_index)"
  if jq -e --argjson i "$inbound_index" --arg email "$email" 'any(.inbounds[$i].settings.clients[]?; (.email // "") == $email)' "$XRAY_CONFIG" >/dev/null; then
    die "Пользователь с email '${email}' уже есть."
  fi

  uuid="$(xray uuid)"
  [[ -n "$uuid" ]] || die "Не удалось сгенерировать UUID."

  tmp_file="$(mktemp)"
  jq --argjson i "$inbound_index" --arg uuid "$uuid" --arg email "$email" '
    .inbounds[$i].settings.clients =
      ((.inbounds[$i].settings.clients // []) + [{
        "id": $uuid,
        "email": $email,
        "flow": "xtls-rprx-vision",
        "level": 0
      }])
  ' "$XRAY_CONFIG" > "$tmp_file"

  validate_xray_config "$tmp_file"
  backup_config
  cat "$tmp_file" > "$XRAY_CONFIG"
  rm -f "$tmp_file"

  restart_xray

  ok "Пользователь добавлен: ${email}"
  printf 'UUID: %s\n' "$uuid"
  build_client_uri "$uuid" "$email"
}

delete_user() {
  local target="$1"
  local inbound_index before after tmp_file
  validate_target "$target"
  ensure_config

  inbound_index="$(vless_inbound_index)"
  before="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].settings.clients // [] | length' "$XRAY_CONFIG")"

  tmp_file="$(mktemp)"
  jq --argjson i "$inbound_index" --arg target "$target" '
    .inbounds[$i].settings.clients =
      ((.inbounds[$i].settings.clients // [])
      | map(select(.id != $target and (.email // "") != $target)))
  ' "$XRAY_CONFIG" > "$tmp_file"
  after="$(jq -r --argjson i "$inbound_index" '.inbounds[$i].settings.clients // [] | length' "$tmp_file")"

  if [[ "$before" == "$after" ]]; then
    rm -f "$tmp_file"
    die "Пользователь '${target}' не найден."
  fi

  validate_xray_config "$tmp_file"
  backup_config
  cat "$tmp_file" > "$XRAY_CONFIG"
  rm -f "$tmp_file"

  restart_xray
  ok "Пользователь удалён: ${target}"
}

parse_args() {
  COMMAND="${1:-}"
  [[ -n "$COMMAND" ]] || { usage; exit 1; }
  shift || true

  POSITIONAL=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config)
        shift
        [[ -n "${1:-}" ]] || die "--config требует путь."
        XRAY_CONFIG_OVERRIDE="$1"
        ;;
      --server)
        shift
        [[ -n "${1:-}" ]] || die "--server требует значение."
        SERVER_ADDRESS="$1"
        ;;
      --no-restart)
        RESTART_XRAY=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        POSITIONAL+=("$1")
        ;;
    esac
    shift || true
  done

  if [[ -n "${XRAY_CONFIG_OVERRIDE:-}" ]]; then
    XRAY_CONFIG="$XRAY_CONFIG_OVERRIDE"
  fi
}

self_test() {
  local tmpdir config mockbin output
  tmpdir="$(mktemp -d)"
  config="${tmpdir}/config.json"
  mockbin="${tmpdir}/bin"
  mkdir -p "$mockbin"

  cat > "$mockbin/xray" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  uuid)
    printf '11111111-1111-4111-8111-111111111111\n'
    ;;
  x25519)
    printf 'Private key: private\nPublic key: public\n'
    ;;
  run)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$mockbin/xray"

  cat > "$mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mockbin/systemctl"

  cat > "$config" <<'EOF'
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "00000000-0000-4000-8000-000000000000",
            "email": "first@example.com",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "serverNames": ["www.microsoft.com"],
          "privateKey": "private",
          "shortIds": ["abcd1234abcd1234"]
        }
      }
    }
  ]
}
EOF

  PATH="${mockbin}:$PATH" XRAY_CONFIG="$config" SERVER_ADDRESS="vpn.example.com" XRAY_USER_ALLOW_NON_ROOT_FOR_TESTS=1 bash "$0" add second@example.com --no-restart >/tmp/xray-user-add.out
  output="$(PATH="${mockbin}:$PATH" XRAY_CONFIG="$config" XRAY_USER_ALLOW_NON_ROOT_FOR_TESTS=1 bash "$0" list)"
  grep -q "first@example.com" <<<"$output"
  grep -q "second@example.com" <<<"$output"
  grep -q "11111111-1111-4111-8111-111111111111" "$config"
  grep -q "vless://11111111-1111-4111-8111-111111111111@vpn.example.com:443" /tmp/xray-user-add.out

  PATH="${mockbin}:$PATH" XRAY_CONFIG="$config" XRAY_USER_ALLOW_NON_ROOT_FOR_TESTS=1 bash "$0" delete second@example.com --no-restart >/dev/null
  output="$(PATH="${mockbin}:$PATH" XRAY_CONFIG="$config" XRAY_USER_ALLOW_NON_ROOT_FOR_TESTS=1 bash "$0" list)"
  grep -q "first@example.com" <<<"$output"
  ! grep -q "second@example.com" <<<"$output"

  rm -rf "$tmpdir" /tmp/xray-user-add.out
  ok "Self-test passed."
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    list)
      require_root
      require_tools
      list_users
      ;;
    add)
      require_root
      require_tools
      add_user "${POSITIONAL[0]:-}"
      ;;
    delete|remove|del)
      require_root
      require_tools
      delete_user "${POSITIONAL[0]:-}"
      ;;
    --self-test)
      self_test
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
