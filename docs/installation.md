# Guía de instalación

## 1. Qué hace este proyecto
Convierte un Ubuntu Server recién instalado en un NAS básico para red local:
un disco secundario formateado en ext4, montado en `/mnt/nas-storage` y
compartido por Samba (SMB) con acceso libre, sin usuario ni contraseña.

> **Sprint 1 no es seguro para redes no confiables.** Cualquier equipo de tu
> red local podrá leer, escribir y borrar. Úsalo en una red doméstica o de
> laboratorio.

## 2. Requisitos
- Ubuntu Server 26.04 LTS (se avisa, pero no se bloquea, si es otra versión de Ubuntu).
- Un **segundo disco vacío** (sin particiones ni sistema de archivos).
- Acceso `root` (`sudo`) y conexión a Internet para descargar paquetes.

## 3. Instalación
```bash
# Copia el proyecto al servidor (ejemplo) y entra en la carpeta
cd nas-deployment-manager
chmod +x install.sh uninstall.sh modules/*.sh licensing/*.sh
sudo ./install.sh
```

Si tienes varios discos libres, el instalador se detiene y te lista los candidatos:
```bash
sudo NAS_DISK=/dev/sdb ./install.sh
```

Opciones frecuentes (variables de entorno o `config/defaults.conf`):

| Variable | Defecto | Descripción |
|---|---|---|
| `NAS_DISK` | (autodetecta) | Disco o partición a usar |
| `SMB_SHARE_NAME` | `NAS` | Nombre del recurso compartido |
| `SMB_WORKGROUP` | `WORKGROUP` | Grupo de trabajo |
| `ENABLE_NFS` | `no` | Exportar también por NFS |
| `ENABLE_FIREWALL` | `no` | Configurar UFW |
| `ENABLE_BACKUP` | `no` | Copias diarias con rsync |
| `LAN_CIDR` | (autodetecta) | Red permitida, p. ej. `192.168.1.0/24` |

## 4. Qué ocurre, paso a paso
`install.sh` carga la configuración y ejecuta los módulos en este orden:

1. `system_checker` – root, Ubuntu, herramientas, espacio, DNS y red local.
2. `license_manager` – desactivado en Sprint 1.
3. `storage_manager` – detecta el disco, formatea ext4 solo si está vacío, añade `UUID=` a `/etc/fstab` y monta.
4. `user_manager` – crea `/mnt/nas-storage/compartido` con permisos abiertos.
5. `samba_manager` – instala Samba, valida y despliega `smb.conf`, activa `smbd`/`nmbd`.
6. `nfs_manager`, `security_manager`, `backup_manager` – opcionales.
7. `monitoring` – crea el comando `nas-status` y muestra el estado.

Es **idempotente**: puedes ejecutarlo varias veces. Si algo falla, se aborta de
inmediato indicando el paso y el comando; corrige el problema y vuelve a lanzarlo.

## 5. Arquitectura
```
   Clientes de la red local (Windows / Linux / macOS)
                 │  SMB (445)   [NFS 2049 opcional]
        ┌────────▼─────────┐
        │  Ubuntu Server   │   smbd + nmbd (Samba)
        │                  │   /etc/samba/smb.conf  ← templates/smb.conf
        └────────┬─────────┘
                 │  /mnt/nas-storage/compartido
        ┌────────▼─────────┐
        │ Disco secundario │   ext4, montado por UUID (/etc/fstab)
        └──────────────────┘
```

## 6. Verificar
```bash
sudo nas-status                 # disco, servicios y cómo conectarse
findmnt /mnt/nas-storage        # el disco está montado
sudo testparm -s                # configuración de Samba válida
```

## 7. Conectarse desde los clientes
- **Windows:** `\\IP_DEL_NAS\NAS` en el Explorador de archivos.
- **Linux:** `smb://IP_DEL_NAS/NAS` en el gestor de archivos, o
  `sudo mount -t cifs //IP_DEL_NAS/NAS /mnt/x -o guest`.
- **macOS:** Finder → Ir → Conectarse al servidor → `smb://IP_DEL_NAS/NAS` → *Invitado*.

### Windows pide credenciales o dice "no se puede acceder"
Windows 11 (sobre todo 24H2) bloquea por defecto los accesos de invitado SMB. Hay dos formas de solucionarlo.
- En PowerShell como administrador: `Set-SmbClientConfiguration -EnableInsecureGuestLogons $true`
- O con `gpedit.msc`: Configuración del equipo → Plantillas administrativas → Red → Estación de trabajo LanMan → *Habilitar inicios de sesión de invitado no seguros*.

Es una limitación de Windows ante el acceso libre. La solución definitiva (usuarios con contraseña) queda para un sprint posterior.

## 8. Problemas frecuentes
| Síntoma | Causa / solución |
|---|---|
| "No se encontró ningún disco secundario libre" | El disco tiene particiones o firmas. Si no te importan sus datos, límpialo (`sudo wipefs -a /dev/sdX`) y reintenta; o indica `NAS_DISK`. |
| "Hay varios discos libres" | Indica el correcto con `NAS_DISK=/dev/sdX`. |
| "contiene un sistema 'ntfs'…" | Protección: no se sobrescriben discos con datos. Bórralo tú manualmente si estás seguro. |
| `apt` bloqueado | Un Ubuntu recién instalado puede estar actualizándose; el script reintenta y espera. |
| No se ve el NAS en la red | Comprueba `LAN_CIDR` (`sudo testparm -s | grep "hosts allow"`) y el firewall. |

El log completo está en `logs/nas-AAAAMMDD.log`.

## 9. Desinstalar
```bash
sudo ./uninstall.sh                    # restaura smb.conf, quita NFS/cron; conserva datos y fstab
sudo ./uninstall.sh --remove-fstab     # además desmonta y quita la entrada de fstab
sudo ./uninstall.sh --purge-packages   # además desinstala samba y nfs-kernel-server
```
Los datos del disco **nunca** se borran.