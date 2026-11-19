# Guía de administración

## Operaciones diarias
```bash
sudo nas-status                       # estado: disco, servicios, accesos
sudo systemctl status smbd nmbd       # detalle de Samba
sudo smbstatus                        # conexiones activas
sudo tail -f /var/log/samba/log.smbd  # log de Samba
tail -n 50 logs/nas-$(date +%Y%m%d).log   # log del instalador
```

## Cambiar la configuración
Toda la configuración está en `config/defaults.conf` y `config/network.conf`
(o en variables de entorno al ejecutar). Después, vuelve a ejecutar:
```bash
sudo ./install.sh
```
Solo se aplican los cambios necesarios (idempotencia). Ejemplos:
```bash
sudo SMB_SHARE_NAME=Archivos ./install.sh      # cambia el nombre del recurso
sudo LAN_CIDR="192.168.1.0/24" ./install.sh    # fija la red permitida
```
Para **añadir otro recurso compartido**, agrega una sección `[Nombre]` a
`templates/smb.conf` (copia la existente) y ejecuta `install.sh`.
No edites `/etc/samba/smb.conf` a mano: se regenera desde la plantilla.

## Activar módulos opcionales
```bash
sudo ENABLE_NFS=yes ./install.sh        # NFS (cliente Linux: sudo mount IP:/mnt/nas-storage/compartido /mnt/x)
sudo ENABLE_FIREWALL=yes ./install.sh   # UFW: SSH + Samba (+NFS) solo desde la LAN
sudo ENABLE_BACKUP=yes ./install.sh     # copias diarias 02:30, conserva 7
```
Para que la opción quede fija, ponla en `config/defaults.conf`. Si no, la próxima
ejecución sin la variable usará el valor por defecto.

### Firewall: precauciones
- SSH (22/tcp) queda abierto desde cualquier origen para que no pierdas el acceso.
- Revisa las reglas con `sudo ufw status numbered`.
- `uninstall.sh` no elimina reglas de UFW.

### Backups
- Se guardan en `/mnt/nas-storage/backups/AAAA-MM-DD` (no se comparten por Samba).
- Cada copia parece completa, pero los archivos sin cambios son enlaces duros, así que ocupan poco.
- Ejecución manual: `sudo bash modules/backup_manager.sh --run`
- Restaurar un archivo: `sudo cp -a /mnt/nas-storage/backups/2026-11-17/ruta/archivo /mnt/nas-storage/compartido/ruta/`
- **Las copias están en el mismo disco**: protegen de borrados accidentales, no de una avería del disco. Para eso necesitas una copia en otro dispositivo.

## Almacenamiento
```bash
findmnt /mnt/nas-storage         # ¿montado?
df -h /mnt/nas-storage           # espacio
grep nas-storage /etc/fstab      # entrada persistente (por UUID)
sudo blkid -L nas-storage        # qué dispositivo tiene la etiqueta del NAS
```
Si el disco falta al arrancar, el servidor arranca igualmente (`nofail`). El
recurso compartido quedaría vacío, porque la carpeta real estaría en el disco ausente.
Conecta el disco y ejecuta `sudo mount /mnt/nas-storage`.

## Mantenimiento
```bash
sudo apt update && sudo apt upgrade -y   # actualizaciones
```

## Estructura del código (para desarrolladores)
- `install.sh` carga `config/` y las utilidades de `modules/system_checker.sh`, y ejecuta cada módulo (`<nombre>_run`) en orden.
- Todos los módulos se cargan con `source` en el mismo shell: comparten funciones (`log_*`, `die`, `pkg_install`, `render_template`) y el `trap` de errores.
- Convenciones: comprobar antes de actuar (idempotencia), `die` ante un fallo crítico, nunca usar `die` dentro de `$( )`.
- Plantillas con marcadores `@@CLAVE@@`, rellenados por `render_template`.

## Limitaciones del Sprint 1 y siguientes pasos
- Acceso de invitado sin autenticación: **no apto para redes no confiables**.
- El disco se formatea completo (sin tabla de particiones) y solo se gestiona un disco.
- Licencias: esqueleto sin activar (`LICENSE_REQUIRED=no`; `public_key.pem` es un marcador).
- Sin RAID, SMART, cifrado ni cuotas.
- Siguientes sprints sugeridos: usuarios y grupos de Samba, recursos con permisos por carpeta, alertas SMART/espacio, backups a un segundo destino.