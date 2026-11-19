#!/usr/bin/env bash
# =============================================================================
# selftest.sh  -  Pruebas automáticas del NAS (se ejecuta EN el servidor)
# -----------------------------------------------------------------------------
# Automatiza todo lo que el propio servidor puede comprobar:
#   1. Almacenamiento : montaje, fstab por UUID, permisos de la carpeta.
#   2. Samba          : paquete, servicios, configuración, puertos y una
#                       prueba REAL de listar/crear/leer/borrar archivos por SMB.
#   3. Opcionales     : NFS, firewall (UFW), backups y nas-status; solo se
#                       prueban si están activados (si no, se marcan SKIP).
#   4. Estado general : unidades systemd fallidas.
# Con --full además:
#   - Desmonta y vuelve a montar el disco usando SOLO /etc/fstab
#     (prueba la persistencia sin reiniciar).
#   - Vuelve a ejecutar install.sh y comprueba la idempotencia.
#   - Ejecuta un backup real si el módulo de backups está activado.
#
# Resultados: PASS (bien), FAIL (error), WARN (revisar), SKIP (no aplica).
# Código de salida: 0 si no hay ningún FAIL, 1 si hay alguno.
# Se guarda un registro en logs/selftest-FECHA.log
#
# Uso:  sudo bash selftest.sh [--full] [--no-install]
# NO se puede probar desde aquí: acceso desde otros equipos (Windows/Linux),
# reglas de firewall vistas desde fuera y el reinicio real. Ver el final.
# =============================================================================

# Sin "set -e" a propósito: una prueba fallida no debe detener las demás.
# -u: error si se usa una variable sin definir. pipefail: falla una tubería si
# falla cualquiera de sus partes.
set -uo pipefail

# Carpeta del proyecto = carpeta de este script (resuelve enlaces simbólicos).
PROJECT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export PROJECT_DIR   # defaults.conf lo exige

usage() {
    cat <<'EOF'
Uso: sudo bash selftest.sh [--full] [--no-install]

  --full        Pruebas más profundas: desmonta/monta el disco desde fstab,
                re-ejecuta install.sh (idempotencia) y lanza un backup si
                está activado. Interrumpe unos segundos el recurso compartido.
  --no-install  No instalar smbclient automáticamente (se omiten las pruebas
                SMB funcionales si no está instalado).
  -h, --help    Esta ayuda.
EOF
}

FULL="no"
AUTO_INSTALL="yes"
for arg in "$@"; do
    case "$arg" in
        --full)       FULL="yes" ;;
        --no-install) AUTO_INSTALL="no" ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Opción desconocida: ${arg}" >&2; usage >&2; exit 1 ;;
    esac
done

# Hace falta root: testparm, blkid -p, umount, ufw y exportfs lo exigen.
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: ejecuta como root ->  sudo bash selftest.sh" >&2
    exit 1
fi

# Carga la misma configuración que usa el instalador.
for f in config/defaults.conf config/network.conf; do
    if [[ ! -f "${PROJECT_DIR}/${f}" ]]; then
        echo "ERROR: falta ${PROJECT_DIR}/${f}" >&2
        exit 1
    fi
done
source "${PROJECT_DIR}/config/defaults.conf"
source "${PROJECT_DIR}/config/network.conf"

# Registro propio de esta prueba (sustituye el LOG_FILE de defaults.conf).
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/selftest-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

# ------------------------------- Presentación --------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

N_PASS=0; N_FAIL=0; N_WARN=0; N_SKIP=0

# Escribe una línea en pantalla (con color) y en el log (sin color).
emit() {   # $1 = etiqueta, $2 = color, resto = mensaje
    local tag="$1" color="$2"
    shift 2
    printf '%s[%s]%s %s\n' "$color" "$tag" "$C_RESET" "$*"
    printf '[%s] %s\n' "$tag" "$*" >> "$LOG_FILE"
}
pass() { N_PASS=$((N_PASS + 1)); emit PASS "$C_GREEN"  "$*"; }
fail() { N_FAIL=$((N_FAIL + 1)); emit FAIL "$C_RED"    "$*"; }
warn() { N_WARN=$((N_WARN + 1)); emit WARN "$C_YELLOW" "$*"; }
skip() { N_SKIP=$((N_SKIP + 1)); emit SKIP "$C_CYAN"   "$*"; }

# Imprime un texto multilínea con sangría (para mostrar el detalle de un fallo).
detail() {
    local line
    while IFS= read -r line; do
        printf '         %s\n' "$line"
        printf '         %s\n' "$line" >> "$LOG_FILE"
    done <<< "$1"
}

section() {
    printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"
    printf '\n== %s ==\n' "$1" >> "$LOG_FILE"
}

# ¿Hay algo escuchando en el puerto? Uso: listening tcp 445 | listening udp 137
listening() {
    local flag="-ltn"
    if [[ "$1" == "udp" ]]; then flag="-lun"; fi
    [[ -n "$(ss -H "$flag" "sport = :$2" 2>/dev/null)" ]]
}

# Nº de entradas UUID= de nuestro punto de montaje en /etc/fstab.
fstab_entries() {
    grep -cE "^UUID=[^[:space:]]+[[:space:]]+${NAS_MOUNT_POINT}[[:space:]]" /etc/fstab || true
}

# Limpieza al terminar (siempre): borra temporales y la carpeta de prueba SMB.
TEST_DIR=""; TEST_SRC=""; TEST_BACK=""; IDEM_LOG=""
cleanup() {
    if [[ -n "$TEST_SRC"  ]]; then rm -f -- "$TEST_SRC";  fi
    if [[ -n "$TEST_BACK" ]]; then rm -f -- "$TEST_BACK"; fi
    if [[ -n "$IDEM_LOG"  ]]; then rm -f -- "$IDEM_LOG";  fi
    if [[ -n "$TEST_DIR" && -d "${NAS_SHARE_DIR}/${TEST_DIR}" ]]; then
        rm -rf -- "${NAS_SHARE_DIR:?}/${TEST_DIR}"
    fi
}
trap cleanup EXIT

printf 'NAS selftest  -  proyecto: %s\n' "$PROJECT_DIR"
printf 'Modo: %s | Log: %s\n' "$([[ "$FULL" == yes ]] && echo completo || echo básico)" "$LOG_FILE"

MOUNTED="no"
SRC_DEV=""

# =============================================================================
# 1) ALMACENAMIENTO
# =============================================================================
section "1. Almacenamiento (${NAS_MOUNT_POINT})"

# 1.1 ¿Está montado el disco?
if mountpoint -q "$NAS_MOUNT_POINT"; then
    MOUNTED="yes"
    pass "${NAS_MOUNT_POINT} está montado"
    SRC_DEV="$(findmnt -n -o SOURCE "$NAS_MOUNT_POINT")"
    detail "$(findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$NAS_MOUNT_POINT")"
    if [[ "$(findmnt -n -o FSTYPE "$NAS_MOUNT_POINT")" == "ext4" ]]; then
        pass "El sistema de archivos es ext4"
    else
        fail "El sistema de archivos NO es ext4"
    fi
else
    fail "${NAS_MOUNT_POINT} NO está montado (¿falló storage_manager?)"
fi

# 1.2 Entrada en /etc/fstab por UUID (una sola, y que coincida con el disco real).
n_entries="$(fstab_entries)"
if (( n_entries == 0 )); then
    fail "No hay entrada UUID= para ${NAS_MOUNT_POINT} en /etc/fstab"
elif (( n_entries > 1 )); then
    fail "Hay ${n_entries} entradas duplicadas para ${NAS_MOUNT_POINT} en /etc/fstab"
else
    pass "/etc/fstab tiene una única entrada por UUID para el disco"
    fstab_line="$(grep -m1 -E "^UUID=[^[:space:]]+[[:space:]]+${NAS_MOUNT_POINT}[[:space:]]" /etc/fstab)"
    detail "$fstab_line"
    fstab_uuid="${fstab_line%%[[:space:]]*}"      # primera palabra: UUID=xxxx
    fstab_uuid="${fstab_uuid#UUID=}"              # quita el prefijo
    if [[ "$MOUNTED" == "yes" && -b "$SRC_DEV" ]]; then
        real_uuid="$(blkid -p -o value -s UUID "$SRC_DEV" 2>/dev/null || true)"
        if [[ "$real_uuid" == "$fstab_uuid" ]]; then
            pass "El UUID de fstab coincide con el del disco montado"
        else
            fail "UUID de fstab (${fstab_uuid}) distinto al del disco (${real_uuid:-desconocido})"
        fi
    fi
    if [[ "$fstab_line" == *nofail* ]]; then
        pass "La opción 'nofail' está presente (el arranque no se bloquea si falta el disco)"
    else
        warn "Falta 'nofail' en fstab: si el disco falla, el arranque podría quedarse esperando"
    fi
fi

# 1.3 Sintaxis general de fstab (solo aviso: puede advertir cosas ajenas al NAS).
if verify_out="$(findmnt --verify 2>&1)"; then
    pass "findmnt --verify: fstab sin problemas"
else
    warn "findmnt --verify reporta avisos (revisa que no sean de nuestra línea):"
    detail "$verify_out"
fi

# 1.4 Carpeta compartida: existe, está EN el disco montado y tiene los permisos esperados.
if [[ -d "$NAS_SHARE_DIR" ]]; then
    pass "Existe la carpeta compartida ${NAS_SHARE_DIR}"
    owner_mode="$(stat -c '%U:%G %a' "$NAS_SHARE_DIR")"
    if [[ "$owner_mode" == "nobody:nogroup 777" ]]; then
        pass "Permisos correctos: ${owner_mode}"
    else
        fail "Permisos inesperados: ${owner_mode} (esperado: nobody:nogroup 777)"
    fi
    if [[ "$(findmnt -n -o TARGET --target "$NAS_SHARE_DIR")" == "$NAS_MOUNT_POINT" ]]; then
        pass "La carpeta está dentro del disco del NAS (no en el disco del sistema)"
    else
        fail "La carpeta compartida NO está en ${NAS_MOUNT_POINT}: se estaría usando el disco del sistema"
    fi
else
    fail "No existe la carpeta compartida ${NAS_SHARE_DIR}"
fi

# 1.5 Espacio libre.
if [[ "$MOUNTED" == "yes" ]]; then
    pct="$(df --output=pcent "$NAS_MOUNT_POINT" | tail -n1 | tr -dc '0-9')"
    if (( ${pct:-0} >= 90 )); then
        warn "Disco casi lleno (${pct}% usado)"
    else
        pass "Espacio en disco correcto (${pct:-?}% usado)"
    fi
fi

# 1.6 (--full) Persistencia sin reiniciar: desmontar y montar SOLO con fstab.
if [[ "$FULL" == "yes" && "$MOUNTED" == "yes" ]]; then
    if um_out="$(umount "$NAS_MOUNT_POINT" 2>&1)"; then
        # "mount <punto>" usa únicamente la entrada de /etc/fstab.
        m_out="$(mount "$NAS_MOUNT_POINT" 2>&1)"
        if mountpoint -q "$NAS_MOUNT_POINT"; then
            pass "[full] Desmontado y montado de nuevo solo con /etc/fstab: funciona"
        else
            fail "[full] No se pudo volver a montar con fstab: no sobreviviría a un reinicio"
            detail "$m_out"
            MOUNTED="no"
        fi
    else
        warn "[full] No se pudo desmontar (en uso); prueba la persistencia con un reinicio"
        detail "$um_out"
    fi
fi

# =============================================================================
# 2) SAMBA
# =============================================================================
section "2. Samba"

# 2.1 Paquete instalado.
if [[ "$(dpkg-query -W -f='${db:Status-Status}' samba 2>/dev/null || true)" == "installed" ]]; then
    pass "Paquete samba instalado"
else
    fail "El paquete samba no está instalado"
fi

# 2.2 Servicios activos y habilitados en el arranque.
for svc in smbd nmbd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "Servicio ${svc} activo"
    else
        fail "Servicio ${svc} NO está activo"
        detail "$(systemctl status "$svc" --no-pager -n 5 2>&1 || true)"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        pass "Servicio ${svc} habilitado en el arranque"
    else
        fail "Servicio ${svc} NO está habilitado en el arranque"
    fi
done

# 2.3 Configuración válida y desplegada por este proyecto.
if tp_out="$(testparm -s 2>&1 >/dev/null)"; then
    pass "testparm: configuración de Samba válida"
else
    fail "testparm: la configuración de Samba tiene errores"
    detail "$tp_out"
fi
if grep -q "Managed by nas-deployment-manager" /etc/samba/smb.conf 2>/dev/null; then
    pass "smb.conf fue desplegado por este proyecto"
else
    warn "smb.conf no lleva la marca del proyecto (¿editado a mano?)"
fi

# 2.4 Parámetros del recurso compartido (se leen de la configuración ya interpretada).
dump="$(testparm -s 2>/dev/null || true)"
# awk: imprime las líneas de la sección [NOMBRE] hasta la siguiente sección.
share_block="$(awk -v sec="[${SMB_SHARE_NAME}]" '$0==sec{f=1;next} /^\[/{f=0} f' <<< "$dump")"
if [[ -z "$share_block" ]]; then
    fail "No existe la sección [${SMB_SHARE_NAME}] en la configuración de Samba"
else
    pass "Existe el recurso compartido [${SMB_SHARE_NAME}]"
    if grep -qiE '^[[:space:]]*guest ok[[:space:]]*=[[:space:]]*yes' <<< "$share_block"; then
        pass "Acceso de invitado habilitado (guest ok = yes)"
    else
        fail "guest ok no es 'yes' en [${SMB_SHARE_NAME}]"
    fi
    if grep -qiE '^[[:space:]]*read only[[:space:]]*=[[:space:]]*no' <<< "$share_block"; then
        pass "Escritura habilitada (read only = no)"
    else
        fail "El recurso está en solo lectura"
    fi
    if grep -qE "^[[:space:]]*path[[:space:]]*=[[:space:]]*${NAS_SHARE_DIR}\$" <<< "$share_block"; then
        pass "El recurso apunta a ${NAS_SHARE_DIR}"
    else
        fail "La ruta del recurso no coincide con ${NAS_SHARE_DIR}"
        detail "$(grep -iE '^[[:space:]]*path' <<< "$share_block" || true)"
    fi
fi
hosts_allow="$(grep -iE '^[[:space:]]*hosts allow' <<< "$dump" || true)"
if [[ -n "$hosts_allow" ]]; then
    pass "Restricción por red local activa:"
    detail "$hosts_allow"
else
    warn "No hay 'hosts allow': Samba aceptaría conexiones de cualquier red"
fi

# 2.5 Puertos en escucha.
if listening tcp 445; then pass "Samba escucha en TCP 445"; else fail "Nada escucha en TCP 445"; fi
if listening tcp 139; then pass "Samba escucha en TCP 139"; else warn "Nada escucha en TCP 139"; fi
if listening udp 137; then pass "nmbd escucha en UDP 137"; else warn "Nada escucha en UDP 137 (nmbd)"; fi

# 2.6 Pruebas funcionales reales con smbclient (cliente SMB).
if ! command -v smbclient >/dev/null 2>&1 && [[ "$AUTO_INSTALL" == "yes" ]]; then
    printf '       (instalando smbclient para las pruebas...)\n'
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y -o DPkg::Lock::Timeout=300 smbclient >>"$LOG_FILE" 2>&1 || true
fi

if ! command -v smbclient >/dev/null 2>&1; then
    skip "smbclient no está instalado: se omiten las pruebas SMB funcionales (usa sin --no-install)"
elif [[ "$MOUNTED" != "yes" ]]; then
    skip "Disco no montado: se omiten las pruebas SMB funcionales"
else
    # Se usa 127.0.0.1 (IPv4 explícito): 'hosts allow' incluye 127.0.0.1.
    # -N = sin contraseña (acceso de invitado).
    # a) Listar recursos: debe aparecer el nuestro.
    list_out="$(smbclient -L //127.0.0.1 -N 2>&1)"; rc=$?
    if (( rc == 0 )) && grep -qE "^[[:space:]]*${SMB_SHARE_NAME}[[:space:]]+Disk" <<< "$list_out"; then
        pass "smbclient lista el recurso '${SMB_SHARE_NAME}' (localhost)"
    else
        fail "smbclient no ve el recurso '${SMB_SHARE_NAME}' (localhost)"
        detail "$list_out"
    fi

    # b) Lo mismo pero por la IP de la LAN: comprueba que 'hosts allow' deja entrar a la red local.
    ips="$(hostname -I 2>/dev/null || true)"
    first_ip="${ips%% *}"
    if [[ -n "$first_ip" ]]; then
        lan_out="$(smbclient -L "//${first_ip}" -N 2>&1)"; rc=$?
        if (( rc == 0 )) && grep -qE "^[[:space:]]*${SMB_SHARE_NAME}[[:space:]]+Disk" <<< "$lan_out"; then
            pass "El recurso es accesible por la IP de la LAN (${first_ip})"
        else
            fail "El recurso NO es accesible por la IP de la LAN (${first_ip})"
            detail "$lan_out"
        fi
    else
        skip "El servidor no tiene IP de red: se omite la prueba por IP"
    fi

    # c) Escritura / lectura / borrado reales, verificando también en el disco.
    TEST_DIR="selftest_$$"
    TEST_SRC="$(mktemp)"
    TEST_BACK="$(mktemp)"
    printf 'nas-selftest %s %s\n' "$(date -Is)" "$RANDOM" > "$TEST_SRC"
    remote="${NAS_SHARE_DIR}/${TEST_DIR}/prueba.txt"
    unc="//127.0.0.1/${SMB_SHARE_NAME}"

    # Subir: crear carpeta y copiar un archivo por SMB.
    up_out="$(smbclient "$unc" -N -c "mkdir ${TEST_DIR}; cd ${TEST_DIR}; put ${TEST_SRC} prueba.txt" 2>&1)"
    if [[ -f "$remote" ]] && cmp -s "$TEST_SRC" "$remote"; then
        pass "Escritura por SMB: carpeta y archivo creados con el contenido correcto"
        owner="$(stat -c '%U' "$remote")"
        mode="$(stat -c '%a' "$remote")"
        if [[ "$owner" == "nobody" ]]; then
            pass "El archivo creado pertenece a 'nobody' (force user)"
        else
            fail "El archivo pertenece a '${owner}' (esperado: nobody)"
        fi
        if [[ "$mode" == "666" ]]; then
            pass "Permisos del archivo creado: ${mode} (create mask)"
        else
            warn "Permisos del archivo creado: ${mode} (esperado 666)"
        fi
    else
        fail "Escritura por SMB: el archivo no llegó al disco o su contenido difiere"
        detail "$up_out"
    fi

    # Descargar: leer el archivo por SMB y compararlo.
    dl_out="$(smbclient "$unc" -N -c "cd ${TEST_DIR}; get prueba.txt ${TEST_BACK}" 2>&1)"
    if cmp -s "$TEST_SRC" "$TEST_BACK"; then
        pass "Lectura por SMB: el archivo descargado es idéntico"
    else
        fail "Lectura por SMB: el archivo descargado no coincide"
        detail "$dl_out"
    fi

    # Borrar: eliminar archivo y carpeta por SMB.
    rm_out="$(smbclient "$unc" -N -c "cd ${TEST_DIR}; del prueba.txt; cd ..; rmdir ${TEST_DIR}" 2>&1)"
    if [[ ! -e "${NAS_SHARE_DIR}/${TEST_DIR}" ]]; then
        pass "Borrado por SMB: archivo y carpeta eliminados"
    else
        fail "Borrado por SMB: la carpeta de prueba sigue existiendo"
        detail "$rm_out"
    fi
fi

# =============================================================================
# 3) MÓDULOS OPCIONALES (se detectan solos; si no están activos -> SKIP)
# =============================================================================
section "3. Módulos opcionales"

# ---- NFS ----
if [[ "${ENABLE_NFS:-no}" == "yes" ]] || grep -qs '^# BEGIN nas-deployment-manager$' /etc/exports; then
    if systemctl is-active --quiet nfs-server 2>/dev/null; then pass "NFS: servicio nfs-server activo"; else fail "NFS: nfs-server NO está activo"; fi
    if exportfs -v 2>/dev/null | grep -qF "$NAS_SHARE_DIR"; then
        pass "NFS: ${NAS_SHARE_DIR} está exportado"
    else
        fail "NFS: ${NAS_SHARE_DIR} no aparece en 'exportfs -v'"
    fi
    if listening tcp 2049; then pass "NFS: escucha en TCP 2049"; else fail "NFS: nada escucha en TCP 2049"; fi
else
    skip "NFS no está activado"
fi

# ---- Firewall ----
if command -v ufw >/dev/null 2>&1 && grep -q '^Status: active' <<< "$(LC_ALL=C ufw status 2>/dev/null || true)"; then
    ufw_out="$(LC_ALL=C ufw status 2>&1)"
    pass "UFW activo"
    detail "$ufw_out"
    if grep -qE '(^|[[:space:]])22(/tcp)?[[:space:]]' <<< "$ufw_out"; then
        pass "UFW permite SSH (22)"
    else
        fail "UFW no tiene regla para SSH (22): podrías perder el acceso remoto"
    fi
    if grep -qE '445' <<< "$ufw_out"; then
        pass "UFW tiene regla para Samba (445)"
    else
        fail "UFW no tiene regla para Samba (445)"
    fi
else
    skip "El firewall (UFW) no está activo"
fi

# ---- Backups ----
if [[ -f /etc/cron.d/nas-backup ]]; then
    if grep -q -- '--run' /etc/cron.d/nas-backup; then
        pass "Backup: tarea programada presente en /etc/cron.d/nas-backup"
        detail "$(grep -v '^[[:space:]]*$' /etc/cron.d/nas-backup)"
    else
        fail "Backup: /etc/cron.d/nas-backup no contiene la orden --run"
    fi
    if systemctl is-active --quiet cron 2>/dev/null; then pass "Backup: servicio cron activo"; else fail "Backup: cron NO está activo"; fi
    if [[ -d "$BACKUP_DIR" ]]; then pass "Backup: existe ${BACKUP_DIR}"; else fail "Backup: no existe ${BACKUP_DIR}"; fi
    if [[ "$FULL" == "yes" ]]; then
        if bk_out="$(bash "${PROJECT_DIR}/modules/backup_manager.sh" --run 2>&1)"; then
            if [[ -d "${BACKUP_DIR}/$(date +%F)" ]]; then
                pass "[full] Backup ejecutado: ${BACKUP_DIR}/$(date +%F)"
            else
                fail "[full] El backup terminó bien pero no existe la carpeta del día"
            fi
        else
            fail "[full] Falló la ejecución del backup"
            detail "$bk_out"
        fi
    fi
else
    skip "Los backups no están activados"
fi

# ---- Comando nas-status ----
if [[ -x /usr/local/bin/nas-status ]]; then
    if /usr/local/bin/nas-status >/dev/null 2>&1; then
        pass "El comando nas-status existe y se ejecuta sin errores"
    else
        fail "nas-status falla al ejecutarse"
    fi
else
    fail "No existe /usr/local/bin/nas-status (¿falló el módulo monitoring?)"
fi

# =============================================================================
# 4) ESTADO GENERAL
# =============================================================================
section "4. Estado general del sistema"

failed_units="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null || true)"
if [[ -z "$failed_units" ]]; then
    pass "No hay unidades systemd fallidas"
else
    warn "Hay unidades systemd fallidas (pueden no estar relacionadas con el NAS):"
    detail "$failed_units"
fi

# =============================================================================
# 5) (--full) IDEMPOTENCIA: volver a ejecutar install.sh
# =============================================================================
if [[ "$FULL" == "yes" ]]; then
    section "5. Idempotencia (re-ejecutar install.sh)"
    if [[ "$MOUNTED" != "yes" ]]; then
        skip "Disco no montado: no se re-ejecuta install.sh"
    else
        uuid_before="$(blkid -p -o value -s UUID "$SRC_DEV" 2>/dev/null || true)"
        mtime_before="$(stat -c %Y /etc/samba/smb.conf 2>/dev/null || echo 0)"
        entries_before="$(fstab_entries)"
        IDEM_LOG="$(mktemp)"

        if bash "${PROJECT_DIR}/install.sh" >"$IDEM_LOG" 2>&1; then
            pass "install.sh se volvió a ejecutar sin errores"
        else
            fail "install.sh falló al re-ejecutarse (últimas líneas):"
            detail "$(tail -n 15 "$IDEM_LOG")"
        fi

        uuid_after="$(blkid -p -o value -s UUID "$SRC_DEV" 2>/dev/null || true)"
        if [[ -n "$uuid_before" && "$uuid_before" == "$uuid_after" ]]; then
            pass "El disco no se reformateó (el UUID no cambió)"
        else
            fail "El UUID del disco cambió: ${uuid_before:-?} -> ${uuid_after:-?}"
        fi
        if [[ "$(fstab_entries)" == "$entries_before" ]]; then
            pass "fstab no duplicó entradas"
        else
            fail "fstab cambió el número de entradas tras re-ejecutar"
        fi
        if [[ "$(stat -c %Y /etc/samba/smb.conf 2>/dev/null || echo 0)" == "$mtime_before" ]]; then
            pass "smb.conf no se reescribió (ya estaba actualizado)"
        else
            warn "smb.conf se reescribió: ¿cambió alguna variable entre ejecuciones?"
        fi
        if mountpoint -q "$NAS_MOUNT_POINT" && systemctl is-active --quiet smbd 2>/dev/null; then
            pass "Tras re-ejecutar, el disco sigue montado y smbd activo"
        else
            fail "Tras re-ejecutar, el disco o smbd no están en buen estado"
        fi
    fi
fi

# =============================================================================
# RESUMEN
# =============================================================================
section "Resumen"
printf '%sPASS: %d%s   %sFAIL: %d%s   %sWARN: %d%s   %sSKIP: %d%s\n' \
    "$C_GREEN" "$N_PASS" "$C_RESET" "$C_RED" "$N_FAIL" "$C_RESET" \
    "$C_YELLOW" "$N_WARN" "$C_RESET" "$C_CYAN" "$N_SKIP" "$C_RESET"
printf 'PASS: %d  FAIL: %d  WARN: %d  SKIP: %d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP" >> "$LOG_FILE"

cat <<EOF

Pruebas que SOLO puedes hacer tú (no se pueden automatizar desde el servidor):
  1. Otro equipo de la red: abrir  \\\\${first_ip:-IP_DEL_NAS}\\${SMB_SHARE_NAME}  (Windows) o
     smb://${first_ip:-IP_DEL_NAS}/${SMB_SHARE_NAME}  (Linux/Mac); crear, editar y borrar un archivo.
  2. Reinicio real:  sudo reboot  ->  al volver:  sudo bash selftest.sh
  3. Si activaste el firewall: probar el acceso desde otro equipo (desde el propio servidor
     el tráfico va por loopback y UFW no lo filtra).
  4. Desinstalación:  sudo bash uninstall.sh   (y luego, si quieres, --remove-fstab).
EOF

if (( N_FAIL == 0 )); then
    printf '\n%sResultado: sin fallos.%s Registro: %s\n' "$C_GREEN" "$C_RESET" "$LOG_FILE"
    exit 0
else
    printf '\n%sResultado: %d prueba(s) fallida(s).%s Registro: %s\n' "$C_RED" "$N_FAIL" "$C_RESET" "$LOG_FILE"
    exit 1
fi
