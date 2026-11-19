#!/usr/bin/env bash
# =============================================================================
# install.sh  -  Orquestador del despliegue del NAS
# -----------------------------------------------------------------------------
# Qué hace:
#   1. Carga la configuración (config/*.conf).
#   2. Carga las utilidades comunes (modules/system_checker.sh).
#   3. Ejecuta los módulos en orden. Cada módulo define una función
#      <nombre>_run y todos se cargan con "source" (comparten el mismo shell,
#      así el "trap" de errores funciona en todos).
#   4. Si cualquier paso falla, aborta de inmediato con un mensaje claro.
# Uso:  sudo ./install.sh        (ver --help)
# =============================================================================

# -E : los "trap ERR" se heredan en funciones y subshells.
# -e : abortar si un comando falla.
# -u : abortar si se usa una variable sin definir.
# -o pipefail : una tubería falla si falla CUALQUIER comando de ella.
set -Eeuo pipefail

# Ruta absoluta de este script, resolviendo enlaces simbólicos.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
# Carpeta raíz del proyecto = carpeta donde vive install.sh.
PROJECT_DIR="$(dirname "$SCRIPT_PATH")"
# Se exporta para que la vean los archivos de configuración y los módulos.
export PROJECT_DIR

# Muestra la ayuda de uso.
usage() {
    cat <<'EOF'
Uso: sudo ./install.sh [--help]

Variables de entorno útiles (se pasan así: sudo NAS_DISK=/dev/sdb ./install.sh):
  NAS_DISK          Disco o partición a usar (por defecto: autodetecta).
  ENABLE_NFS        yes|no  - exporta también por NFS   (defecto: no)
  ENABLE_FIREWALL   yes|no  - configura UFW             (defecto: no)
  ENABLE_BACKUP     yes|no  - copias diarias con rsync  (defecto: no)
  LAN_CIDR          Red local, ej. 192.168.1.0/24       (defecto: autodetecta)
Más opciones en config/defaults.conf y config/network.conf.
EOF
}

# Procesa argumentos: solo existe --help / -h.
case "${1:-}" in
    -h|--help) usage; exit 0 ;;          # muestra ayuda y sale sin error
    "") ;;                               # sin argumentos: continuar
    *) echo "Opción desconocida: $1" >&2; usage >&2; exit 1 ;;
esac

# Se necesita root: instalar paquetes, formatear y editar /etc lo exigen.
# Se comprueba ANTES de cargar nada para no crear logs con el usuario equivocado.
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: ejecuta como root ->  sudo ./install.sh" >&2
    exit 1
fi

# Carga la configuración. "source" ejecuta el archivo en este mismo shell,
# dejando sus variables disponibles.
source "${PROJECT_DIR}/config/defaults.conf"
source "${PROJECT_DIR}/config/network.conf"

# Crea la carpeta de logs (-p: no falla si ya existe) y el archivo de log.
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Carga las utilidades comunes (log_info, die, pkg_install, trap handlers...).
source "${PROJECT_DIR}/modules/system_checker.sh"

# Activa "set -Eeuo pipefail" + traps de ERR y EXIT (definidos en system_checker).
enable_error_handling

# Lista ORDENADA de pasos, formato "archivo|función". El orden importa:
#   storage -> user (necesita el montaje) -> samba/nfs (necesitan la carpeta)
STEPS=(
    "modules/system_checker.sh|system_checker_run"
    "modules/storage_manager.sh|storage_manager_run"
    "modules/user_manager.sh|user_manager_run"
    "modules/samba_manager.sh|samba_manager_run"
    "modules/nfs_manager.sh|nfs_manager_run"
    "modules/security_manager.sh|security_manager_run"
    "modules/backup_manager.sh|backup_manager_run"
    "modules/monitoring.sh|monitoring_run"
)

log_info "===== Inicio de la instalación del NAS ====="
log_info "Log: ${LOG_FILE}"

# Recorre cada paso de la lista.
for step in "${STEPS[@]}"; do
    file="${step%%|*}"      # todo lo que hay ANTES del primer "|"  -> archivo
    func="${step##*|}"      # todo lo que hay DESPUÉS del último "|" -> función

    CURRENT_STEP="$func"    # lo usa el trap de errores para decir dónde falló

    # El archivo del módulo debe existir; si no, abortamos.
    [[ -f "${PROJECT_DIR}/${file}" ]] || die "No existe el módulo: ${file}"

    # Carga el módulo solo si su función aún no está definida
    # (evita volver a cargar system_checker.sh, que ya cargamos arriba).
    if ! declare -F "$func" >/dev/null; then
        source "${PROJECT_DIR}/${file}"
    fi

    log_info "--- Ejecutando: ${func} ---"
    "$func"                 # llama a la función del módulo
done

CURRENT_STEP="fin"
log_ok "===== Instalación completada correctamente ====="
log_info "Consulta el estado en cualquier momento con:  sudo nas-status"