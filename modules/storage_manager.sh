#!/usr/bin/env bash
# =============================================================================
# modules/storage_manager.sh
# -----------------------------------------------------------------------------
# Objetivo: dejar un disco secundario formateado en ext4, montado en
# $NAS_MOUNT_POINT y persistente en /etc/fstab por UUID.
#
# SEGURIDAD ANTE DATOS (formatear es destructivo):
#   - Solo se autoselecciona un disco que no tenga particiones, ni firma de
#     sistema de archivos/tabla de particiones, ni nada montado.
#   - Si hay 0 o más de 1 candidato, se ABORTA y se pide definir NAS_DISK.
#   - Nunca se formatea un disco que ya contenga un sistema de archivos
#     (si ya es ext4 se reutiliza; si es otro, se aborta).
# Nota: se formatea el disco completo (sin tabla de particiones), lo más simple.
# =============================================================================

NAS_DEVICE=""   # dispositivo elegido (lo rellenan las funciones de abajo)

# Imprime, uno por línea, los discos "libres" (candidatos seguros).
storage_list_free_disks() {
    local disk
    # lsblk -d (solo discos, sin hijos) -p (ruta completa) -n (sin cabecera) -r (crudo)
    # awk: solo type=disk, no solo-lectura (RO=0) y se descartan zram/ram/loop/nbd/fd.
    while read -r disk; do
        # A) ¿Tiene particiones u otros hijos? (lsblk lista el disco + sus hijos)
        if (( $(lsblk -nr -o NAME "$disk" | wc -l) > 1 )); then continue; fi
        # B) ¿Tiene firma de sistema de archivos o de tabla de particiones?
        if [[ -n "$(blkid -p -o value -s TYPE   "$disk" 2>/dev/null || true)" ]]; then continue; fi
        if [[ -n "$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null || true)" ]]; then continue; fi
        # C) ¿Está montado en algún sitio?
        if [[ -n "$(lsblk -nr -o MOUNTPOINT "$disk" | tr -d '[:space:]')" ]]; then continue; fi
        printf '%s\n' "$disk"
    done < <(lsblk -dpnr -o NAME,TYPE,RO | awk '$2=="disk" && $3==0 && $1 !~ "^/dev/(zram|ram|nbd|loop|fd)" {print $1}')
}

# Decide qué dispositivo usar y lo deja en NAS_DEVICE.
storage_pick_device() {
    local by_label mounts m
    local -a candidates=()

    # Caso 1: el usuario fijó NAS_DISK explícitamente.
    if [[ -n "$NAS_DISK" ]]; then
        [[ -b "$NAS_DISK" ]] || die "NAS_DISK=${NAS_DISK} no es un dispositivo de bloques válido."
        # Protección: nunca tocar un disco con algo montado (salvo nuestro punto de montaje).
        mounts="$(lsblk -nr -o MOUNTPOINT "$NAS_DISK")"
        while read -r m; do
            if [[ -n "$m" && "$m" != "$NAS_MOUNT_POINT" ]]; then
                die "${NAS_DISK} tiene algo montado en ${m}; no es seguro usarlo."
            fi
        done <<< "$mounts"
        NAS_DEVICE="$NAS_DISK"
        log_info "Usando disco indicado por el usuario: ${NAS_DEVICE}"
        return 0
    fi

    # Caso 2 (re-ejecución): ya existe un FS con nuestra etiqueta -> es nuestro disco.
    by_label="$(blkid -L "$NAS_FS_LABEL" 2>/dev/null || true)"
    if [[ -n "$by_label" ]]; then
        NAS_DEVICE="$by_label"
        log_ok "Disco NAS existente encontrado por etiqueta '${NAS_FS_LABEL}': ${NAS_DEVICE}"
        return 0
    fi

    # Caso 3: buscar un disco secundario libre.
    mapfile -t candidates < <(storage_list_free_disks)
    if (( ${#candidates[@]} == 0 )); then
        die "No se encontró ningún disco secundario libre. Conecta uno o define NAS_DISK=/dev/sdX."
    elif (( ${#candidates[@]} > 1 )); then
        die "Hay varios discos libres (${candidates[*]}). Elige uno con: sudo NAS_DISK=/dev/sdX ./install.sh"
    fi
    NAS_DEVICE="${candidates[0]}"
    log_info "Disco secundario libre detectado: ${NAS_DEVICE}"
}

# Formatea en ext4 SOLO si el dispositivo no tiene ningún sistema de archivos.
storage_format_if_needed() {
    local fs_type
    fs_type="$(blkid -p -o value -s TYPE "$NAS_DEVICE" 2>/dev/null || true)"

    if [[ -z "$fs_type" ]]; then
        log_warn "Formateando ${NAS_DEVICE} como ext4 (etiqueta '${NAS_FS_LABEL}')."
        # -F: no pedir confirmación (disco entero, sin particiones)
        # -L: etiqueta, para reconocer el disco en próximas ejecuciones
        mkfs.ext4 -F -L "$NAS_FS_LABEL" "$NAS_DEVICE" >>"$LOG_FILE" 2>&1
        udevadm settle          # espera a que udev actualice UUID/etiqueta
        log_ok "Formateo completado."
    elif [[ "$fs_type" == "ext4" ]]; then
        log_ok "${NAS_DEVICE} ya es ext4: no se formatea."
    else
        die "${NAS_DEVICE} contiene un sistema '${fs_type}'. No se sobrescribe (protección de datos)."
    fi
}

# Añade la entrada UUID a /etc/fstab si no existe.
storage_ensure_fstab() {
    local uuid="$1" fstab="/etc/fstab"

    # Si la entrada ya existe, no hacemos nada (idempotencia).
    if grep -qs "^UUID=${uuid}[[:space:]]" "$fstab"; then
        log_ok "fstab ya contiene este disco (UUID=${uuid})."
        return 0
    fi
    # Si el punto de montaje ya está en fstab con OTRO dispositivo, no lo pisamos.
    if grep -qsE "^[^#]*[[:space:]]${NAS_MOUNT_POINT}[[:space:]]" "$fstab"; then
        die "/etc/fstab ya tiene una entrada para ${NAS_MOUNT_POINT} con otro dispositivo. Revísala a mano."
    fi
    # Copia de seguridad única del fstab original.
    [[ -f /etc/fstab.nas-backup ]] || cp -a "$fstab" /etc/fstab.nas-backup

    # defaults = opciones estándar; nofail = el arranque NO se bloquea si el disco falta;
    # 0 = sin dump; 2 = fsck después de la raíz.
    printf '\n# nas-deployment-manager: almacenamiento NAS\nUUID=%s %s ext4 defaults,nofail 0 2\n' \
        "$uuid" "$NAS_MOUNT_POINT" >> "$fstab"
    systemctl daemon-reload      # systemd relee fstab y regenera sus unidades de montaje
    log_ok "Añadida entrada a /etc/fstab (UUID=${uuid})."
}

storage_manager_run() {
    local uuid

    mkdir -p "$NAS_MOUNT_POINT"          # -p: no falla si ya existe

    if mountpoint -q "$NAS_MOUNT_POINT"; then
        # Ya montado (re-ejecución): recuperamos el dispositivo que lo respalda.
        NAS_DEVICE="$(findmnt -n -o SOURCE "$NAS_MOUNT_POINT")"
        [[ -b "$NAS_DEVICE" ]] || die "${NAS_MOUNT_POINT} está montado con algo que no es un disco (${NAS_DEVICE})."
        log_ok "${NAS_MOUNT_POINT} ya está montado desde ${NAS_DEVICE}."
    else
        storage_pick_device
        storage_format_if_needed
    fi

    # UUID del sistema de archivos: identificador estable (los /dev/sdX pueden cambiar).
    uuid="$(blkid -p -o value -s UUID "$NAS_DEVICE")"
    [[ -n "$uuid" ]] || die "No se pudo obtener el UUID de ${NAS_DEVICE}."

    storage_ensure_fstab "$uuid"

    if ! mountpoint -q "$NAS_MOUNT_POINT"; then
        mount "$NAS_MOUNT_POINT"         # usa la entrada de fstab recién creada
    fi
    mountpoint -q "$NAS_MOUNT_POINT" || die "No se pudo montar ${NAS_MOUNT_POINT}."
    log_ok "Almacenamiento listo: ${NAS_DEVICE} -> ${NAS_MOUNT_POINT}"
}