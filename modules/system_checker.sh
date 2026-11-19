#!/usr/bin/env bash
# =============================================================================
# modules/system_checker.sh
# -----------------------------------------------------------------------------
# Hace DOS cosas:
#   1) Define las utilidades comunes que usan todos los módulos
#      (logs, manejo de errores, instalación de paquetes, plantillas, red).
#   2) Verifica los requisitos del sistema (system_checker_run).
# Se carga con "source"; no se ejecuta directamente.
# =============================================================================

# Si alguien lo ejecuta directamente, BASH_SOURCE[0] == $0: lo impedimos.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: este archivo se carga desde install.sh; no se ejecuta solo." >&2
    exit 1
fi

# ------------------------------- Colores --------------------------------------
# Solo se usan colores si la salida es una terminal (-t 1); en logs/cron no.
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

CURRENT_STEP="inicio"   # paso en curso (para mensajes de error)
APT_UPDATED=0           # 1 cuando ya hicimos "apt-get update" en esta ejecución

# --------------------------------- Logs ---------------------------------------
# Escribe una línea con fecha en el archivo de log. $1 = nivel, $2 = mensaje.
_log_file() {
    printf '[%s] [%-5s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE"
}
# Cada función imprime en consola (con color) y guarda en el log (sin color).
log_info()  { printf '%s[INFO ]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*";      _log_file INFO  "$*"; }
log_ok()    { printf '%s[ OK  ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*";      _log_file OK    "$*"; }
log_warn()  { printf '%s[WARN ]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2;  _log_file WARN  "$*"; }
log_error() { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2;  _log_file ERROR "$*"; }

# Error crítico: muestra el mensaje y termina TODO el script.
# (No usar dentro de $( ... ): ahí solo saldría del subshell.)
die() { log_error "$*"; exit 1; }

# ------------------------- Manejo de errores (traps) --------------------------
# Se invoca automáticamente cuando un comando falla (trap ERR).
on_error() {
    local exit_code=$?                   # código de salida del comando que falló
    local line="${1:-?}" cmd="${2:-?}"   # línea y comando que nos pasa el trap
    trap - ERR                           # desactiva el trap para evitar recursión
    log_error "Fallo en el paso '${CURRENT_STEP}' (línea ${line}, código ${exit_code})."
    log_error "Comando que falló: ${cmd}"
    exit "$exit_code"                    # aborta de inmediato
}

# Se invoca SIEMPRE al terminar el script (trap EXIT), con éxito o con error.
on_exit() {
    local code=$?
    if (( code != 0 )); then
        log_error "El proceso terminó con errores (código ${code}). Revisa el log: ${LOG_FILE}"
        log_error "Puedes corregir el problema y volver a ejecutar: el script es idempotente."
    fi
}

# Activa modo estricto y registra los traps. Se llama desde install/uninstall.
enable_error_handling() {
    set -Eeuo pipefail
    shopt -s inherit_errexit 2>/dev/null || true   # "set -e" también dentro de $( )
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR  # comillas simples: se evalúa al fallar
    trap on_exit EXIT
}

# ------------------------------ Utilidades ------------------------------------
# Falla si no se es root.
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then die "Debes ejecutar como root (sudo)."; fi
}

# Falla si alguno de los comandos indicados no existe.
require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Falta el comando requerido: ${c}"
    done
}

# Reintenta un comando N veces. Uso: retry <intentos> <segundos> comando args...
# Útil en un Ubuntu recién instalado, donde apt puede estar bloqueado un rato
# por actualizaciones automáticas.
retry() {
    local tries="$1" delay="$2" n=1
    shift 2
    # "until": repite mientras el comando falle. No dispara "set -e".
    until "$@"; do
        if (( n >= tries )); then return 1; fi
        log_warn "Falló '$*' (intento ${n}/${tries}); reintento en ${delay}s..."
        sleep "$delay"
        n=$((n + 1))
    done
}

# ¿Está instalado el paquete $1? (se evita "dpkg | grep -q": con pipefail daría falsos negativos)
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

# Ejecuta "apt-get update" una sola vez por ejecución.
apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        log_info "Actualizando índices de paquetes..."
        retry 5 15 env DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG_FILE" 2>&1
        APT_UPDATED=1
    fi
}

# Instala SOLO los paquetes que faltan, sin preguntas. Uso: pkg_install samba rsync
pkg_install() {
    local pkg
    local -a missing=()
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_info "Paquete ya instalado: ${pkg}"
        else
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} == 0 )); then return 0; fi   # nada que hacer

    apt_update_once
    log_info "Instalando paquetes: ${missing[*]}"
    # DEBIAN_FRONTEND=noninteractive : apt/dpkg nunca abren diálogos.
    # NEEDRESTART_MODE=a             : needrestart reinicia servicios solo, sin preguntar.
    # -y                             : responde "sí" a las confirmaciones.
    # DPkg::Lock::Timeout=300        : espera hasta 5 min si dpkg está ocupado.
    # --force-confdef/--force-confold: ante conflictos de config, mantiene lo existente.
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y \
        -o DPkg::Lock::Timeout=300 \
        -o "Dpkg::Options::=--force-confdef" \
        -o "Dpkg::Options::=--force-confold" \
        "${missing[@]}" >>"$LOG_FILE" 2>&1
    log_ok "Instalado: ${missing[*]}"
}

# Habilita el servicio en el arranque y lo inicia (idempotente).
service_enable_start() {
    systemctl enable --now "$1" >>"$LOG_FILE" 2>&1
    log_ok "Servicio activo: $1"
}

# Rellena una plantilla sustituyendo @@CLAVE@@ por su valor.
# Uso: render_template <plantilla> <salida> CLAVE=valor CLAVE2=valor2 ...
render_template() {
    local src="$1" dst="$2" content pair key val
    shift 2
    # Bash 5.2+ trata "&" como especial en reemplazos; lo desactivamos por seguridad.
    shopt -u patsub_replacement 2>/dev/null || true
    content="$(cat "$src")"
    for pair in "$@"; do
        key="${pair%%=*}"     # texto antes del primer "="
        val="${pair#*=}"      # texto después del primer "="
        content="${content//@@${key}@@/${val}}"   # reemplaza todas las apariciones
    done
    printf '%s\n' "$content" > "$dst"
    # Si quedó algún @@MARCADOR@@ sin resolver, es un error de plantilla.
    if grep -q '@@[A-Z_]\+@@' "$dst"; then
        die "La plantilla ${src} tiene marcadores sin resolver."
    fi
}

# Detecta la red local (CIDR) de la interfaz con ruta por defecto. Imprime el CIDR.
detect_lan_cidr() {
    local iface cidr
    # Interfaz de la ruta por defecto: toma la palabra que sigue a "dev".
    iface="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$iface" ]]; then return 1; fi
    # Red directamente conectada (scope link) de esa interfaz, ej. 192.168.1.0/24.
    cidr="$(ip -4 route show dev "$iface" scope link 2>/dev/null | awk '$1 ~ /\//{print $1; exit}')"
    if [[ -z "$cidr" ]]; then return 1; fi
    printf '%s\n' "$cidr"
}

# Deja LAN_CIDR definido: el configurado, el autodetectado o el fallback.
resolve_lan_cidr() {
    local detected
    if [[ -n "${LAN_CIDR}" ]]; then
        log_info "Red local configurada: ${LAN_CIDR}"
    elif detected="$(detect_lan_cidr)"; then
        LAN_CIDR="$detected"
        log_ok "Red local detectada: ${LAN_CIDR}"
    else
        LAN_CIDR="${LAN_FALLBACK_CIDRS}"
        log_warn "No se pudo detectar la red local; se permiten redes privadas: ${LAN_CIDR}"
    fi
}

# --------------------------- Verificación del sistema -------------------------
system_checker_run() {
    local os_id os_version avail_mb

    require_root

    # Lee /etc/os-release en un subshell para no ensuciar nuestras variables.
    os_id="$(. /etc/os-release && printf '%s' "${ID:-desconocido}")"
    os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-desconocido}")"
    if [[ "$os_id" != "ubuntu" ]]; then
        die "Sistema no soportado: ${os_id}. Este proyecto es para Ubuntu Server."
    fi
    if [[ "$os_version" != "26.04" ]]; then
        log_warn "Probado para Ubuntu 26.04 LTS; se detectó ${os_version}. Se continúa."
    else
        log_ok "Ubuntu ${os_version} detectado."
    fi

    # Herramientas imprescindibles (todas vienen en una instalación de Ubuntu Server).
    require_cmd lsblk blkid findmnt mountpoint awk sed ip systemctl mkfs.ext4 udevadm
    log_ok "Herramientas del sistema disponibles."

    # Espacio mínimo en la raíz para instalar paquetes (500 MB).
    avail_mb="$(df --output=avail -BM / | tail -n1 | tr -dc '0-9')"
    if (( ${avail_mb:-0} < 500 )); then
        die "Espacio insuficiente en / (${avail_mb:-0} MB libres; se requieren 500 MB)."
    fi

    # Conectividad con el repositorio (solo aviso: si los paquetes ya están, no hace falta).
    if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        log_ok "Resolución DNS correcta."
    else
        log_warn "Sin DNS/Internet: la instalación de paquetes podría fallar."
    fi

    # Determina la red local que usarán Samba, NFS y el firewall.
    resolve_lan_cidr
}