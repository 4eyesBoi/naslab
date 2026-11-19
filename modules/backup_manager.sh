#!/usr/bin/env bash
# =============================================================================
# modules/backup_manager.sh   (OPCIONAL: ENABLE_BACKUP=yes)
# -----------------------------------------------------------------------------
# Copias diarias con rsync, estilo "snapshots" con enlaces duros (--link-dest):
# cada día ocupa solo lo que cambió. Se conservan las últimas BACKUP_KEEP.
# AVISO: las copias están en el MISMO disco; protegen de borrados accidentales,
# NO de la avería del disco.
#
# Este archivo sirve para dos cosas:
#   - cargado por install.sh  -> backup_manager_run (configura cron)
#   - ejecutado por cron      -> bash backup_manager.sh --run (hace la copia)
# =============================================================================

# Hace una copia de NAS_SHARE_DIR en BACKUP_DIR/AAAA-MM-DD y rota las antiguas.
backup_snapshot() {
    local today dest prev snap total
    local -a snaps=()

    mountpoint -q "$NAS_MOUNT_POINT" || die "${NAS_MOUNT_POINT} no está montado: no se hace backup."
    [[ -d "$NAS_SHARE_DIR" ]]        || die "No existe ${NAS_SHARE_DIR}."

    today="$(date +%F)"                       # formato AAAA-MM-DD
    dest="${BACKUP_DIR}/${today}"
    mkdir -p "$BACKUP_DIR" "$dest"

    # Copia anterior más reciente (distinta de hoy), para enlazar archivos sin cambios.
    prev="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' ! -name "$today" | sort | tail -n1)"

    log_info "Backup: ${NAS_SHARE_DIR} -> ${dest}"
    if [[ -n "$prev" ]]; then
        # -a: conserva permisos/fechas; --delete: refleja borrados dentro de la copia de hoy.
        rsync -a --delete --link-dest="$prev" "${NAS_SHARE_DIR}/" "${dest}/"
    else
        rsync -a --delete "${NAS_SHARE_DIR}/" "${dest}/"
    fi
    log_ok "Backup completado: ${dest}"

    # Rotación: borra las copias más antiguas por encima de BACKUP_KEEP.
    mapfile -t snaps < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' | sort)
    total="${#snaps[@]}"
    if (( total > BACKUP_KEEP )); then
        for snap in "${snaps[@]:0:total-BACKUP_KEEP}"; do
            log_info "Eliminando copia antigua: ${snap}"
            rm -rf -- "$snap"
        done
    fi
}

# Configuración durante la instalación.
backup_manager_run() {
    local cron_file="/etc/cron.d/nas-backup"   # sin punto en el nombre (cron ignora los que lo tienen)
    local tmp

    if [[ "$ENABLE_BACKUP" != "yes" ]]; then
        log_info "Backups desactivados (ENABLE_BACKUP=no): se omite."
        return 0
    fi
    mountpoint -q "$NAS_MOUNT_POINT" || die "${NAS_MOUNT_POINT} no está montado."

    pkg_install rsync cron
    service_enable_start cron

    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"                  # solo root (y no se comparte por Samba)

    # Genera la tarea programada. Formato cron.d: min hora dia mes dsem USUARIO comando
    tmp="$(mktemp)"
    {
        printf 'SHELL=/bin/bash\n'
        printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
        printf '%s root /bin/bash %s/modules/backup_manager.sh --run >> %s/backup.log 2>&1\n' \
            "$BACKUP_CRON_SCHEDULE" "$PROJECT_DIR" "$LOG_DIR"
    } > "$tmp"

    if [[ -f "$cron_file" ]] && cmp -s "$tmp" "$cron_file"; then
        log_ok "Tarea de backup ya configurada."
    else
        install -m 0644 -o root -g root "$tmp" "$cron_file"
        log_ok "Tarea de backup programada (${BACKUP_CRON_SCHEDULE}), conserva ${BACKUP_KEEP} copias."
    fi
    rm -f "$tmp"
}

# ---- Modo directo (lo usa cron): carga config y utilidades por su cuenta ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export PROJECT_DIR
    source "${PROJECT_DIR}/config/defaults.conf"
    source "${PROJECT_DIR}/config/network.conf"
    mkdir -p "$LOG_DIR"; touch "$LOG_FILE"
    source "${PROJECT_DIR}/modules/system_checker.sh"
    enable_error_handling
    case "${1:-}" in
        --run) CURRENT_STEP="backup_snapshot"; require_root; backup_snapshot ;;
        *)     echo "Uso: $0 --run" >&2; exit 1 ;;
    esac
fi