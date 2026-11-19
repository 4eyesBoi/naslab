#!/usr/bin/env bash
# =============================================================================
# precheck.sh  -  Verificación previa de nas-deployment-manager
# -----------------------------------------------------------------------------
# Ejecuta, en este orden:
#   1) Convierte los saltos de línea CRLF (Windows) a LF y verifica que no queden.
#   2) Revisa la sintaxis (bash -n) de los scripts y de los archivos de config.
#   3) Muestra los discos disponibles (lsblk).
#
# El CRLF se corrige PRIMERO porque con CRLF "bash -n" puede dar falsos errores.
# NO instala nada ni toca discos. Lo único que modifica son los archivos del
# proyecto en el paso 1 (elimina el \r final de cada línea).
#
# Uso:  bash precheck.sh        (o ./precheck.sh si tiene permiso de ejecución)
# Salida: código 0 si todo está bien, 1 si hubo errores.
# =============================================================================

# Sin "set -e" a propósito: queremos seguir tras un fallo y mostrar el resumen
# completo. -u: error si se usa una variable sin definir. pipefail: una tubería
# falla si falla cualquiera de sus comandos.
set -uo pipefail

# Carpeta del proyecto = carpeta donde está este script (aunque se ejecute
# desde otro directorio). readlink -f resuelve enlaces simbólicos.
PROJECT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cd "$PROJECT_DIR" || { echo "No se pudo entrar en ${PROJECT_DIR}" >&2; exit 1; }

# Colores solo si la salida es una terminal.
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BOLD=$'\033[1m';   C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

ERRORS=0   # contador de errores para el resumen final

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }
ok()      { printf '%s[ OK ]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
fail()    { printf '%s[FAIL]%s %s\n'   "$C_RED"    "$C_RESET" "$*"; ERRORS=$((ERRORS + 1)); }

printf 'Proyecto: %s\n' "$PROJECT_DIR"

# =============================================================================
# 1) Saltos de línea CRLF -> LF
# =============================================================================
section "1/3 Saltos de línea (CRLF -> LF)"

# Archivos de texto del proyecto (mismas extensiones que el comando manual).
# -print0 / mapfile -d '' : manejan nombres con espacios sin problemas.
mapfile -d '' -t targets < <(
    find . -type f -not -path './.git/*' \
        \( -name '*.sh' -o -name '*.conf' -o -name '*.rules' -o -name '*.md' -o -name '*.pem' \) \
        -print0
)

# Detecta cuáles contienen algún \r (carácter de retorno de carro).
with_cr=()
for f in "${targets[@]}"; do
    if grep -q $'\r' "$f"; then with_cr+=("$f"); fi
done

if (( ${#with_cr[@]} == 0 )); then
    ok "Ningún archivo tenía CRLF (${#targets[@]} revisados)."
else
    warn "${#with_cr[@]} archivo(s) con CRLF; se convierten a LF:"
    for f in "${with_cr[@]}"; do printf '       - %s\n' "$f"; done
    # sed -i edita en el sitio; 's/\r$//' borra el \r al final de cada línea.
    if sed -i 's/\r$//' "${with_cr[@]}"; then
        ok "Conversión realizada."
    else
        fail "No se pudo convertir (¿permisos? prueba con sudo)."
    fi
fi

# Verificación final sobre TODO el proyecto (sin importar la extensión), salvo
# .git y logs/: los logs pueden llevar \r legítimos (apt escribe sus barras de
# progreso con retornos de carro) y nadie los ejecuta, así que no importan.
# -I ignora archivos binarios.
mapfile -t leftovers < <(grep -rlI $'\r' . --exclude-dir=.git --exclude-dir=logs 2>/dev/null)
if (( ${#leftovers[@]} == 0 )); then
    ok "Verificado: no queda ningún \\r en el proyecto."
else
    fail "Aún hay \\r en estos archivos (otra extensión o \\r en medio de una línea):"
    for f in "${leftovers[@]}"; do printf '       - %s\n' "$f"; done
fi

# =============================================================================
# 2) Sintaxis con bash -n  (analiza el archivo SIN ejecutarlo)
# =============================================================================
section "2/3 Sintaxis (bash -n)"

# nullglob: si un patrón no coincide con nada (p. ej. se borró licensing/),
# se expande a "nada" en vez de quedarse como texto literal.
shopt -s nullglob
scripts=(install.sh uninstall.sh precheck.sh modules/*.sh licensing/*.sh config/*.conf)
shopt -u nullglob

for f in "${scripts[@]}"; do
    if [[ ! -f "$f" ]]; then
        warn "No existe: ${f} (se omite)"
        continue
    fi
    # Captura la salida de error de bash -n para mostrarla si falla.
    if out="$(bash -n "$f" 2>&1)"; then
        ok "OK ${f}"
    else
        fail "Error de sintaxis en ${f}:"
        printf '%s\n' "$out" | sed 's/^/         /'
    fi
done

# =============================================================================
# 3) Discos disponibles
# =============================================================================
section "3/3 Discos (lsblk)"

if command -v lsblk >/dev/null 2>&1; then
    # MOUNTPOINTS (plural) existe en util-linux >= 2.37; si falla, se usa MOUNTPOINT.
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null \
        || lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
    printf '\nBusca un disco TYPE=disk sin particiones debajo, sin FSTYPE y sin MOUNTPOINT:\n'
    printf 'ese es el disco secundario que usará el instalador.\n'
else
    warn "lsblk no está disponible en este equipo."
fi

# =============================================================================
# Resumen
# =============================================================================
section "Resumen"
if (( ERRORS == 0 )); then
    ok "Todo correcto. Siguiente paso:  sudo bash install.sh"
    exit 0
else
    fail "${ERRORS} problema(s) detectado(s). Corrígelos antes de instalar."
    exit 1
fi
