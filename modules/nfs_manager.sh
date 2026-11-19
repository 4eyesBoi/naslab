#!/usr/bin/env bash
# =============================================================================
# modules/nfs_manager.sh   (OPCIONAL: ENABLE_NFS=yes)
# -----------------------------------------------------------------------------
# Exporta NAS_SHARE_DIR por NFS a la red local. "all_squash" convierte a todos
# los clientes en nobody (65534), coherente con el acceso libre de Samba.
# El bloque en /etc/exports está delimitado por marcas para reescribirlo
# sin duplicar líneas.
# =============================================================================

nfs_manager_run() {
    local begin="# BEGIN nas-deployment-manager"
    local end="# END nas-deployment-manager"
    local opts="rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534"
    local cidr clients=""

    if [[ "$ENABLE_NFS" != "yes" ]]; then
        log_info "NFS desactivado (ENABLE_NFS=no): se omite."
        return 0
    fi

    pkg_install nfs-kernel-server
    touch /etc/exports                       # asegura que exista

    # Borra el bloque anterior (si lo hay) para reescribirlo limpio.
    sed -i "/^${begin}\$/,/^${end}\$/d" /etc/exports

    # Un cliente por cada red de LAN_CIDR (la expansión sin comillas es intencionada).
    # shellcheck disable=SC2086
    for cidr in $LAN_CIDR; do
        clients+=" ${cidr}(${opts})"
    done

    # Escribe el bloque nuevo al final del archivo.
    {
        printf '%s\n' "$begin"
        printf '%s%s\n' "$NAS_SHARE_DIR" "$clients"
        printf '%s\n' "$end"
    } >> /etc/exports

    exportfs -ra                             # recarga todas las exportaciones
    service_enable_start nfs-server
    log_ok "NFS exportando ${NAS_SHARE_DIR} a: ${LAN_CIDR}"
}