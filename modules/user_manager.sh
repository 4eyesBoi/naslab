#!/usr/bin/env bash
# =============================================================================
# modules/user_manager.sh
# -----------------------------------------------------------------------------
# Sprint 1: acceso libre en la red local. No se crean usuarios; solo se prepara
# la carpeta compartida para que cualquier cliente (invitado) pueda leer/escribir.
# Samba mapea al invitado a "nobody" (ver templates/smb.conf), por eso la
# carpeta pertenece a nobody:nogroup.
# (Sprint futuro: usuarios y grupos reales con permisos por carpeta.)
# =============================================================================

user_manager_run() {
    # La carpeta debe crearse DENTRO del disco montado; si no, acabaría en el disco del sistema.
    mountpoint -q "$NAS_MOUNT_POINT" || die "${NAS_MOUNT_POINT} no está montado; no se crea la carpeta compartida."

    # El usuario y grupo "nobody/nogroup" existen por defecto en Ubuntu.
    id nobody >/dev/null 2>&1          || die "No existe el usuario 'nobody'."
    getent group nogroup >/dev/null    || die "No existe el grupo 'nogroup'."

    mkdir -p "$NAS_SHARE_DIR"                  # crea la carpeta (idempotente)
    chown nobody:nogroup "$NAS_SHARE_DIR"      # propietario = invitado de Samba
    chmod 0777 "$NAS_SHARE_DIR"                # lectura/escritura para todos (acceso libre)
    log_ok "Carpeta compartida lista: ${NAS_SHARE_DIR} (nobody:nogroup, 0777)"
}