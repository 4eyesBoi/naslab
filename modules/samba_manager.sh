#!/usr/bin/env bash
# =============================================================================
# modules/samba_manager.sh
# -----------------------------------------------------------------------------
# Instala Samba y despliega templates/smb.conf con acceso de invitado.
# Idempotente: solo reemplaza la configuración y reinicia si el contenido cambió.
# =============================================================================

samba_manager_run() {
    local template="${PROJECT_DIR}/templates/smb.conf"
    local target="/etc/samba/smb.conf"
    local marker="Managed by nas-deployment-manager"
    local tmp test_out changed=0

    [[ -f "$template" ]] || die "No existe la plantilla: ${template}"

    # 1) Paquete (samba incluye smbd, nmbd y testparm).
    pkg_install samba

    # 2) Copia de seguridad ÚNICA del smb.conf original (si aún no es el nuestro).
    if [[ -f "$target" && ! -f "${target}.orig-nas" ]] && ! grep -q "$marker" "$target"; then
        cp -a "$target" "${target}.orig-nas"
        log_info "Copia del smb.conf original: ${target}.orig-nas"
    fi

    # 3) Genera la configuración en un archivo temporal sustituyendo los marcadores.
    tmp="$(mktemp)"
    render_template "$template" "$tmp" \
        "SMB_WORKGROUP=${SMB_WORKGROUP}" \
        "SMB_SERVER_STRING=${SMB_SERVER_STRING}" \
        "SMB_SHARE_NAME=${SMB_SHARE_NAME}" \
        "NAS_SHARE_DIR=${NAS_SHARE_DIR}" \
        "LAN_CIDR=${LAN_CIDR}"

    # 4) Valida la sintaxis ANTES de instalarla (testparm: verificador oficial de Samba).
    if ! test_out="$(testparm -s "$tmp" 2>&1)"; then
        rm -f "$tmp"
        log_error "$test_out"
        die "La configuración de Samba generada no es válida."
    fi

    # 5) Instala solo si cambió.
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        log_ok "smb.conf ya está actualizado."
    else
        install -m 0644 -o root -g root "$tmp" "$target"
        changed=1
        log_ok "smb.conf desplegado."
    fi
    rm -f "$tmp"

    # 6) Habilita e inicia los servicios (smbd = archivos; nmbd = nombre NetBIOS).
    service_enable_start smbd
    service_enable_start nmbd
    if (( changed == 1 )); then
        systemctl restart smbd nmbd >>"$LOG_FILE" 2>&1
        log_ok "Samba reiniciado con la nueva configuración."
    fi

    # 7) Comprobación rápida: ¿escucha en el puerto 445?
    sleep 2
    if [[ -n "$(ss -H -ltn 'sport = :445')" ]]; then
        log_ok "Samba escuchando en el puerto 445."
    else
        log_warn "Samba no parece escuchar en el 445; revisa: systemctl status smbd"
    fi
}