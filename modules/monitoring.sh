#!/usr/bin/env bash
# =============================================================================
# modules/monitoring.sh
# -----------------------------------------------------------------------------
# Informe de estado del NAS: disco, servicios, accesos. Durante la instalación
# crea el comando "nas-status" para consultarlo después. También se puede
# ejecutar directamente:  sudo ./modules/monitoring.sh
# =============================================================================

monitoring_status() {
    local ips first_ip pct svc state
    local -a services=(smbd nmbd)

    ips="$(hostname -I 2>/dev/null || true)"     # todas las IP del equipo
    first_ip="${ips%% *}"                        # solo la primera
    [[ "$ENABLE_NFS" == "yes" ]] && services+=(nfs-server)

    printf '\n========== ESTADO DEL NAS ==========\n'
    printf 'Equipo : %s\n' "$(hostname)"
    printf 'IP(s)  : %s\n' "${ips:-desconocida}"
    printf 'Uptime : %s\n' "$(uptime -p)"

    printf '\n-- Almacenamiento (%s) --\n' "$NAS_MOUNT_POINT"
    if mountpoint -q "$NAS_MOUNT_POINT"; then
        df -h "$NAS_MOUNT_POINT"
        pct="$(df --output=pcent "$NAS_MOUNT_POINT" | tail -n1 | tr -dc '0-9')"
        if (( ${pct:-0} >= 90 )); then
            log_warn "Disco casi lleno (${pct}%)."
        fi
    else
        printf 'NO MONTADO (revisa /etc/fstab y el disco)\n'
    fi

    printf '\n-- Servicios --\n'
    for svc in "${services[@]}"; do
        state="$(systemctl is-active "$svc" 2>/dev/null || true)"
        printf '%-12s %s\n' "$svc" "${state:-desconocido}"
    done

    printf '\n-- Cómo conectarse --\n'
    printf 'Windows : \\\\%s\\%s\n' "${first_ip:-IP_DEL_NAS}" "$SMB_SHARE_NAME"
    printf 'Linux/Mac: smb://%s/%s\n\n' "${first_ip:-IP_DEL_NAS}" "$SMB_SHARE_NAME"
}

monitoring_run() {
    # Enlace simbólico para poder escribir simplemente "sudo nas-status".
    chmod +x "${PROJECT_DIR}/modules/monitoring.sh"
    ln -sfn "${PROJECT_DIR}/modules/monitoring.sh" /usr/local/bin/nas-status
    log_ok "Comando disponible: nas-status"
    monitoring_status
}

# ---- Modo directo (también cubre el enlace nas-status) ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export PROJECT_DIR
    source "${PROJECT_DIR}/config/defaults.conf"
    source "${PROJECT_DIR}/config/network.conf"
    mkdir -p "$LOG_DIR"; touch "$LOG_FILE"
    source "${PROJECT_DIR}/modules/system_checker.sh"
    enable_error_handling
    CURRENT_STEP="monitoring_status"
    monitoring_status
fi