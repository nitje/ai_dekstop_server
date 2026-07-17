#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="${ROOT_PATH}:${PATH:-}"

DEFAULT_APP_NAME="ai_desktop_server"
APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
AI_BASE_DIR="${AI_BASE_DIR:-/opt/${APP_NAME}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONTAINER_DIR="${SOURCE_CONTAINER_DIR:-${SCRIPT_DIR}/container}"
TARGET_CONTAINER_DIR="${TARGET_CONTAINER_DIR:-${AI_BASE_DIR}/container}"

OPEN_WEBUI_DEFAULT_PORT="${OPEN_WEBUI_DEFAULT_PORT:-28080}"
OPEN_WEBUI_DEFAULT_IMAGE="${OPEN_WEBUI_DEFAULT_IMAGE:-ghcr.io/open-webui/open-webui:main}"
OPEN_WEBUI_OLLAMA_DEFAULT_IMAGE="${OPEN_WEBUI_OLLAMA_DEFAULT_IMAGE:-ghcr.io/open-webui/open-webui:ollama}"
OLLAMA_DEFAULT_IMAGE="${OLLAMA_DEFAULT_IMAGE:-ollama/ollama:0.9.3}"
OLLAMA_DEFAULT_PORT="${OLLAMA_DEFAULT_PORT:-11434}"
DEFAULT_RESTART_POLICY="${DEFAULT_RESTART_POLICY:-unless-stopped}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_sudo() {
  if [[ -n "${SUDO}" ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo ist nicht installiert. Bitte als root starten:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  bash ./ai_desktop_server_container.sh"
      exit 1
    fi
    if ! sudo -v; then
      echo "Keine sudo-Rechte. Bitte als root starten."
      exit 1
    fi
  fi
}

run_root() {
  need_sudo
  if [[ -n "${SUDO}" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local answer
  if [[ "${default}" == "y" ]]; then
    suffix="[Y/n]"
  fi
  while true; do
    read -r -p "${prompt} ${suffix} " answer
    answer="${answer:-${default}}"
    case "${answer,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      *) echo "Bitte mit y/n antworten." ;;
    esac
  done
}

ask_value() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  echo "${value:-${default}}"
}

ask_optional_value() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " value
    echo "${value:-${default}}"
  else
    read -r -p "${prompt} [leer = nicht setzen]: " value
    echo "${value}"
  fi
}

ask_port() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(ask_value "${prompt}" "${default}")"
    if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
      echo "${value}"
      return 0
    fi
    echo "Bitte einen Port von 1 bis 65535 eingeben."
  done
}

ask_restart_policy() {
  local default="$1"
  local value
  echo "Restart Policy: no, unless-stopped, always, on-failure" >&2
  while true; do
    value="$(ask_value "restart" "${default}")"
    case "${value}" in
      no|unless-stopped|always|on-failure) echo "${value}"; return 0 ;;
      *) echo "Bitte no, unless-stopped, always oder on-failure eingeben." >&2 ;;
    esac
  done
}

command_ok() {
  command -v "$1" >/dev/null 2>&1
}

compose_cmd() {
  if command_ok docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if command_ok docker-compose; then
    echo "docker-compose"
    return 0
  fi
  return 1
}

compose_file_source() {
  local project="$1"
  if [[ -f "${SOURCE_CONTAINER_DIR}/${project}/docker-compose.yml" ]]; then
    echo "${SOURCE_CONTAINER_DIR}/${project}/docker-compose.yml"
  elif [[ -f "${SOURCE_CONTAINER_DIR}/${project}/docker-compose.yaml" ]]; then
    echo "${SOURCE_CONTAINER_DIR}/${project}/docker-compose.yaml"
  else
    return 1
  fi
}

project_dir() {
  echo "${TARGET_CONTAINER_DIR}/$1"
}

project_compose_file() {
  echo "$(project_dir "$1")/docker-compose.yml"
}

project_installed() {
  [[ -f "$(project_compose_file "$1")" ]]
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

port_in_use() {
  local port="$1"
  if command_ok ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    return $?
  fi
  return 1
}

warn_port_if_used() {
  local port="$1"
  if port_in_use "${port}"; then
    echo "Port ${port} scheint bereits belegt zu sein."
    ask_yes_no "Trotzdem fortsetzen?" "n"
  fi
}

installed_port_for() {
  local project="$1"
  local container_port="$2"
  local fallback="$3"
  local file
  file="$(project_compose_file "${project}")"
  if [[ -f "${file}" ]]; then
    local port
    port="$(grep -E "^[[:space:]]+- \"[0-9]+:${container_port}\"" "${file}" | head -n1 | sed -E "s/.*\"([0-9]+):${container_port}\".*/\1/" || true)"
    if [[ -n "${port}" ]]; then
      echo "${port}"
      return 0
    fi
  fi
  echo "${fallback}"
}

docker_status() {
  local project="$1"
  if ! command_ok docker; then
    echo "Docker fehlt"
    return
  fi
  local count names
  names="$(docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' 2>/dev/null || true)"
  count="$(printf "%s\n" "${names}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "${count}" != "0" ]]; then
    echo "running (${count})"
    return
  fi
  names="$(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' 2>/dev/null || true)"
  count="$(printf "%s\n" "${names}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "${count}" != "0" ]]; then
    echo "stopped (${count})"
    return
  fi
  echo "fehlt"
}

scan_status() {
  section "Container / Docker Compose Status"
  printf "%-28s %s\n" "Docker" "$(command_ok docker && echo installiert || echo fehlt)"
  printf "%-28s %s\n" "Docker Compose" "$(compose_cmd >/dev/null 2>&1 && echo installiert || echo fehlt)"
  echo
  printf "%-28s %-16s %-18s %s\n" "Projekt" "Quelle" "Installation" "Container"
  for project in open_webui open_webui_ollama; do
    local source_state="fehlt"
    local install_state="fehlt"
    compose_file_source "${project}" >/dev/null 2>&1 && source_state="vorhanden"
    project_installed "${project}" && install_state="vorhanden"
    printf "%-28s %-16s %-18s %s\n" "${project}" "${source_state}" "${install_state}" "$(docker_status "${project}")"
  done
  echo
  echo "Quelle: ${SOURCE_CONTAINER_DIR}"
  echo "Ziel:   ${TARGET_CONTAINER_DIR}"
}

choose_action() {
  local project="$1"
  local action
  if project_installed "${project}"; then
    echo "Optionen fuer ${project}:" >&2
    echo "r) reparieren/aktualisieren" >&2
    echo "u) deinstallieren" >&2
    echo "s) ueberspringen" >&2
    while true; do
      read -r -p "Auswahl [s]: " action
      case "${action,,}" in
        r|repair|reparieren) echo "repair"; return 0 ;;
        u|uninstall|deinstallieren) echo "uninstall"; return 0 ;;
        ""|s|skip) echo "skip"; return 0 ;;
        *) echo "Bitte r, u oder s eingeben." >&2 ;;
      esac
    done
  else
    echo "Optionen fuer ${project}:" >&2
    echo "i) installieren" >&2
    echo "s) ueberspringen" >&2
    while true; do
      read -r -p "Auswahl [s]: " action
      case "${action,,}" in
        i|install|installieren) echo "install"; return 0 ;;
        ""|s|skip) echo "skip"; return 0 ;;
        *) echo "Bitte i oder s eingeben." >&2 ;;
      esac
    done
  fi
}

ensure_dependencies() {
  if ! command_ok docker; then
    echo "Docker fehlt. Bitte zuerst Docker mit ai_desktop_server.sh installieren."
    return 1
  fi
  if ! compose_cmd >/dev/null 2>&1; then
    echo "Docker Compose fehlt. Bitte zuerst docker-compose-plugin oder docker-compose installieren."
    return 1
  fi
}

compose_down() {
  local project="$1"
  local remove_volumes="${2:-n}"
  local file
  file="$(project_compose_file "${project}")"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  local cmd
  cmd="$(compose_cmd)"
  if [[ "${cmd}" == "docker compose" ]]; then
    if [[ "${remove_volumes}" == "y" ]]; then
      run_root docker compose -f "${file}" -p "${project}" down --remove-orphans -v
    else
      run_root docker compose -f "${file}" -p "${project}" down --remove-orphans
    fi
  else
    if [[ "${remove_volumes}" == "y" ]]; then
      run_root docker-compose -f "${file}" -p "${project}" down --remove-orphans -v
    else
      run_root docker-compose -f "${file}" -p "${project}" down --remove-orphans
    fi
  fi
}

compose_up() {
  local project="$1"
  local file
  file="$(project_compose_file "${project}")"
  local cmd
  cmd="$(compose_cmd)"
  if [[ "${cmd}" == "docker compose" ]]; then
    run_root docker compose -f "${file}" -p "${project}" pull
    run_root docker compose -f "${file}" -p "${project}" up -d
  else
    run_root docker-compose -f "${file}" -p "${project}" pull
    run_root docker-compose -f "${file}" -p "${project}" up -d
  fi
}

install_compose_file() {
  local project="$1"
  local tmp="$2"
  local target_dir
  target_dir="$(project_dir "${project}")"
  run_root install -d -m 0755 "${target_dir}"
  run_root install -m 0644 "${tmp}" "$(project_compose_file "${project}")"
  run_root install -d -m 0775 "${target_dir}/data" "${target_dir}/ollama"
}

write_limit_lines() {
  local mem_limit="$1"
  local cpus="$2"
  if [[ -n "${mem_limit}" ]]; then
    echo "    mem_limit: \"${mem_limit}\""
  fi
  if [[ -n "${cpus}" ]]; then
    echo "    cpus: \"${cpus}\""
  fi
}

generate_open_webui_compose() {
  local tmp="$1"
  local port="$2"
  local image="$3"
  local restart="$4"
  local mem_limit="$5"
  local cpus="$6"
  {
    echo "# Generated by ai_desktop_server_container.sh"
    echo "services:"
    echo "  open_webui:"
    echo "    image: \"${image}\""
    echo "    container_name: open_webui"
    echo "    restart: \"${restart}\""
    write_limit_lines "${mem_limit}" "${cpus}"
    echo "    ports:"
    echo "      - \"${port}:8080\""
    echo "    volumes:"
    echo "      - ./data:/app/backend/data"
    echo "    network_mode: bridge"
  } >"${tmp}"
}

generate_open_webui_ollama_compose() {
  local tmp="$1"
  local web_port="$2"
  local ollama_port="$3"
  local web_image="$4"
  local ollama_image="$5"
  local restart="$6"
  local web_mem="$7"
  local web_cpus="$8"
  local ollama_mem="$9"
  local ollama_cpus="${10}"
  {
    echo "# Generated by ai_desktop_server_container.sh"
    echo "services:"
    echo "  open_webui_ollama:"
    echo "    image: \"${web_image}\""
    echo "    container_name: open_webui_ollama"
    echo "    restart: \"${restart}\""
    write_limit_lines "${web_mem}" "${web_cpus}"
    echo "    ports:"
    echo "      - \"${web_port}:8080\""
    echo "    volumes:"
    echo "      - ./data:/app/backend/data"
    echo "      - ./ollama:/root/.ollama"
    echo "    environment:"
    echo "      - OLLAMA_BASE_URL=http://ollama:11434"
    echo "    depends_on:"
    echo "      - ollama"
    echo "    networks:"
    echo "      - net"
    echo
    echo "  ollama:"
    echo "    image: \"${ollama_image}\""
    echo "    container_name: ollama"
    echo "    restart: \"${restart}\""
    write_limit_lines "${ollama_mem}" "${ollama_cpus}"
    echo "    ports:"
    echo "      - \"${ollama_port}:11434\""
    echo "    volumes:"
    echo "      - ./ollama:/root/.ollama"
    echo "    networks:"
    echo "      - net"
    echo "    deploy:"
    echo "      resources:"
    echo "        reservations:"
    echo "          devices:"
    echo "            - capabilities: [gpu]"
    echo
    echo "networks:"
    echo "  net:"
    echo "    driver: bridge"
  } >"${tmp}"
}

configure_open_webui() {
  local project="$1"
  local tmp
  local port default_port image restart mem_limit cpus
  section "${project} konfigurieren"
  default_port="$(installed_port_for "${project}" "8080" "${OPEN_WEBUI_DEFAULT_PORT}")"
  port="$(ask_port "Open WebUI Host-Port" "${default_port}")"
  if [[ "${port}" != "${default_port}" || ! -f "$(project_compose_file "${project}")" ]]; then
    warn_port_if_used "${port}"
  fi
  image="$(ask_value "Open WebUI Image" "${OPEN_WEBUI_DEFAULT_IMAGE}")"
  restart="$(ask_restart_policy "${DEFAULT_RESTART_POLICY}")"
  mem_limit="$(ask_optional_value "mem_limit fuer Open WebUI, z.B. 1g")"
  cpus="$(ask_optional_value "cpus fuer Open WebUI, z.B. 4")"
  tmp="$(mktemp)"
  generate_open_webui_compose "${tmp}" "${port}" "${image}" "${restart}" "${mem_limit}" "${cpus}"
  install_compose_file "${project}" "${tmp}"
  rm -f "${tmp}"
}

configure_open_webui_ollama() {
  local project="$1"
  local tmp
  local web_port ollama_port default_web_port default_ollama_port web_image ollama_image restart web_mem web_cpus ollama_mem ollama_cpus
  section "${project} konfigurieren"
  default_web_port="$(installed_port_for "${project}" "8080" "${OPEN_WEBUI_DEFAULT_PORT}")"
  web_port="$(ask_port "Open WebUI Host-Port" "${default_web_port}")"
  if [[ "${web_port}" != "${default_web_port}" || ! -f "$(project_compose_file "${project}")" ]]; then
    warn_port_if_used "${web_port}"
  fi
  default_ollama_port="$(installed_port_for "${project}" "11434" "${OLLAMA_DEFAULT_PORT}")"
  ollama_port="$(ask_port "Ollama Host-Port" "${default_ollama_port}")"
  if [[ "${ollama_port}" != "${default_ollama_port}" || ! -f "$(project_compose_file "${project}")" ]]; then
    warn_port_if_used "${ollama_port}"
  fi
  web_image="$(ask_value "Open WebUI Image" "${OPEN_WEBUI_OLLAMA_DEFAULT_IMAGE}")"
  ollama_image="$(ask_value "Ollama Image" "${OLLAMA_DEFAULT_IMAGE}")"
  restart="$(ask_restart_policy "${DEFAULT_RESTART_POLICY}")"
  web_mem="$(ask_optional_value "mem_limit fuer Open WebUI, z.B. 1g")"
  web_cpus="$(ask_optional_value "cpus fuer Open WebUI, z.B. 4")"
  ollama_mem="$(ask_optional_value "mem_limit fuer Ollama, z.B. 28g")"
  ollama_cpus="$(ask_optional_value "cpus fuer Ollama, z.B. 4")"
  tmp="$(mktemp)"
  generate_open_webui_ollama_compose "${tmp}" "${web_port}" "${ollama_port}" "${web_image}" "${ollama_image}" "${restart}" "${web_mem}" "${web_cpus}" "${ollama_mem}" "${ollama_cpus}"
  install_compose_file "${project}" "${tmp}"
  rm -f "${tmp}"
}

install_or_repair_project() {
  local project="$1"
  ensure_dependencies
  if ! compose_file_source "${project}" >/dev/null 2>&1; then
    echo "Warnung: Quell-Compose fehlt fuer ${project}: ${SOURCE_CONTAINER_DIR}/${project}/docker-compose.yml"
    echo "Das Script erzeugt die Compose-Datei trotzdem aus den Eingaben."
  fi
  case "${project}" in
    open_webui) configure_open_webui "${project}" ;;
    open_webui_ollama) configure_open_webui_ollama "${project}" ;;
    *) echo "Unbekanntes Projekt: ${project}"; return 1 ;;
  esac
  compose_up "${project}"
  echo
  echo "${project} gestartet."
}

uninstall_project() {
  local project="$1"
  local target_dir
  target_dir="$(project_dir "${project}")"
  section "${project} deinstallieren"
  if ask_yes_no "Datenordner/Bind-Mounts fuer ${project} loeschen? (${target_dir})" "n"; then
    compose_down "${project}" "y"
    echo "Loesche ${target_dir}"
    run_root rm -rf "${target_dir}"
  else
    compose_down "${project}" "n"
    echo "Daten bleiben erhalten: ${target_dir}"
  fi
}

print_project_summary() {
  local project="$1"
  local file
  file="$(project_compose_file "${project}")"
  echo
  echo "${project}:"
  echo "  Compose: ${file}"
  echo "  Status:  $(docker_status "${project}")"
  if [[ -f "${file}" ]]; then
    local port
    port="$(grep -E '^[[:space:]]+- "[0-9]+:8080"' "${file}" | head -n1 | sed -E 's/.*"([0-9]+):8080".*/\1/' || true)"
    if [[ -n "${port}" ]]; then
      echo "  Lokal:   http://127.0.0.1:${port}/"
      echo "  Netz:    http://$(primary_lan_ip):${port}/"
    fi
  fi
}

main() {
  scan_status
  for project in open_webui open_webui_ollama; do
    section "${project}"
    local action
    action="$(choose_action "${project}")"
    case "${action}" in
      install|repair) install_or_repair_project "${project}" ;;
      uninstall) uninstall_project "${project}" ;;
      skip) echo "${project}: uebersprungen." ;;
    esac
  done
  section "Fertig"
  scan_status
  print_project_summary "open_webui"
  print_project_summary "open_webui_ollama"
  echo
  echo "Start: chmod +x ./ai_desktop_server_container.sh && ./ai_desktop_server_container.sh"
}

main "$@"
