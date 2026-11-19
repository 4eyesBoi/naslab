#!/usr/bin/env bash
# =============================================================================
# modules/security_manager.sh   (OPCIONAL: ENABLE_FIREWALL=yes)
# -----------------------------------------------------------------------------
# Sprint 1: firewall básico con UFW. Lee templates/firewall.rules, abre solo
# SSH + Samba (+ NFS si está activo) para la red local y bloquea el resto
# de la entrada. SSH (22/tcp) queda abierto SIEMPRE para no perder el acceso.
# =============================================================================

security_manager_run() {
    local rules_file="${PROJECT_DIR}/templates/firewall.rules"
    local line scope rule cidr expanded
    local -a args=()

    if [[ "$ENABLE_FIREWALL" != "yes" ]]; then
        log_info "Firewall desactivado (ENABLE_FIREWALL=no): se omite."
        return 0
    fi
    [[ -f "$rules_file" ]] || die "No existe ${rules_file}"

    pkg_install ufw

    # Lee el archivo línea a línea. "|| [[ -n $line ]]" procesa la última línea
    # aunque no termine en salto de línea.
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignora líneas vacías y comentarios.
        if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then continue; fi

        scope="${line%% *}"      # primera palabra: "base" o "nfs"
        rule="${line#* }"        # resto de la línea: argumentos de ufw

        # Las reglas "nfs" solo aplican si NFS está activo.
        if [[ "$scope" == "nfs" && "$ENABLE_NFS" != "yes" ]]; then continue; fi

        if [[ "$rule" == *"@@LAN@@"* ]]; then
            # La regla depende de la red: se aplica una vez por cada CIDR.
            # shellcheck disable=SC2086
            for cidr in $LAN_CIDR; do
                expanded="${rule//@@LAN@@/${cidr}}"
                read -ra args <<< "$expanded"          # separa en palabras de forma segura
                ufw "${args[@]}" >>"$LOG_FILE" 2>&1    # "ufw allow ..." es idempotente
            done
        else
            read -ra args <<< "$rule"
            ufw "${args[@]}" >>"$LOG_FILE" 2>&1
        fi
    done < "$rules_file"

    # --force: activa UFW sin la pregunta interactiva "¿continuar?".
    ufw --force enable >>"$LOG_FILE" 2>&1
    log_ok "Firewall UFW activo (acceso permitido desde: ${LAN_CIDR})."
}