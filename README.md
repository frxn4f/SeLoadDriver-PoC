# LoadDrv

Pequeña utilidad en PowerShell para cargar y descargar drivers de kernel en Windows aprovechando el privilegio `SeLoadDriverPrivilege`. La idea surgió mientras preparaba el OSCP: cada vez que quería probar un driver vulnerable (`Capcom.sys`, `gdrv.sys`, etc.) tenía que repetir a mano los mismos pasos (crear la clave en el registro, habilitar el privilegio, llamar a `NtLoadDriver`…), y al final acabé escribiendo esto para no volver a hacerlo.

No es nada nuevo ni revolucionario: la técnica está documentada desde hace años en ired.team, HackTricks y en el repo de FuzzySecurity. Lo único que aporto es una versión parametrizada, con manejo de errores y pensada para reutilizarse con cualquier driver, no solo con `Capcom.sys`.

## Cómo funciona (resumen rápido)

La mayoría de guías te dicen que uses `sc create` para registrar el driver. El problema es que `sc create` escribe en `HKLM\SYSTEM\CurrentControlSet\Services`, y para eso necesitas un token de administrador completo. En una sesión con UAC activo (o en Evil-WinRM, que es donde yo lo probé), eso falla con `Access is denied`.

La alternativa es usar `HKCU` en lugar de `HKLM`. El kernel acepta entradas de driver en `\Registry\User\<SID>\System\CurrentControlSet\<Nombre>` siempre que tengan los valores `ImagePath` y `Type` correctos. Como `HKCU` sí es escribible sin elevación, podemos registrar el driver ahí y luego llamar a `NtLoadDriver` con esa ruta. Todo lo que necesitamos es el privilegio `SeLoadDriverPrivilege`, que en muchos entornos viene habilitado por defecto.

El script hace exactamente eso:

1. Saca el SID del usuario actual (`WindowsIdentity`, sin depender de `whoami.exe`).
2. Crea la clave en `HKCU\System\CurrentControlSet\<ServiceName>` con `ImagePath` y `Type=1`.
3. Habilita `SeLoadDriverPrivilege` con `RtlAdjustPrivilege`.
4. Llama a `NtLoadDriver` con la ruta `\Registry\User\<SID>\...`.

Y para descargar, lo mismo pero con `NtUnloadDriver`.

## Uso

Cargar el script en la sesión actual:

```powershell
. .\LoadDrv.ps1
```

Cargar un driver (el nombre del servicio se deduce del nombre del fichero):

```powershell
Invoke-LoadDriver -DriverPath C:\Users\user\Documents\Capcom.sys
```

Si quieres forzar un nombre de servicio distinto (útil para evitar colisiones o para drivers con nombres raros):

```powershell
Invoke-LoadDriver -DriverPath C:\Windows\Temp\gdrv.sys -ServiceName Gdrv
```

Descargarlo:

```powershell
Invoke-UnloadDriver -ServiceName Capcom
```

Un flujo típico de explotación con `Capcom.sys` sería:

```powershell
. .\LoadDrv.ps1
Invoke-LoadDriver -DriverPath C:\Users\user\Documents\Capcom.sys

# En otra terminal (Kali): nc -lvnp 443
.\ExploitCapcom.exe C:\Users\user\Documents\payload.exe

# Si necesitas reexplotar:
Invoke-UnloadDriver -ServiceName Capcom
Invoke-LoadDriver  -DriverPath C:\Users\user\Documents\Capcom.sys
.\ExploitCapcom.exe C:\Users\user\Documents\payload2.exe
```

## Códigos de estado

Tanto `NtLoadDriver` como `NtUnloadDriver` devuelven códigos NTSTATUS. Los que más te vas a encontrar:

| Código | Significado | Qué hacer |
|---|---|---|
| `0x00000000` | `STATUS_SUCCESS` | Todo bien |
| `0xC0000034` | `STATUS_OBJECT_NAME_NOT_FOUND` | La clave no existe o el SID no coincide. Revisa con `reg query HKCU\System\CurrentControlSet /s` |
| `0xC000010E` | `STATUS_IMAGE_ALREADY_LOADED` | El kernel aún lo considera cargado (driver zombi). Descarga o reinicia |
| `0xC000036B` | `STATUS_DRIVER_BLOCKED` | Bloqueado por HVCI o por la lista negra de Microsoft |
| `0xC0000428` | `STATUS_INVALID_IMAGE_HASH` | Firma del driver inválida o ausente |

El script traduce estos códigos directamente en la salida, así no tienes que buscar el significado cada vez.

## Limitaciones y cosas a tener en cuenta

- **El driver tiene que estar firmado.** En Windows 10/11 moderno, un `.sys` sin firma o con firma inválida no carga, aunque tengas el privilegio. Los drivers vulnerables conocidos (`Capcom.sys`, `gdrv.sys`, `rtcore64.sys`, `msio64.sys`) están firmados por sus fabricantes, así que no suele ser un problema.
- **HVCI puede bloquearlo.** Si `Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard` incluye el servicio `2` (HVCI) en `SecurityServicesRunning`, es probable que el driver devuelva `0xC000036B`. En ese caso no hay mucho que hacer desde userland: toca cambiar de vector.
- **Si el driver ya está cargado y explotado, no se puede reexplotar sin descargarlo.** Muchos exploits dejan el driver en un estado inconsistente tras ejecutarse, y el segundo intento falla con `CreateFile failed`. Descarga y vuelve a cargar antes de relanzar el exploit.
- **No es magia.** Solo carga drivers firmados que ya estén en el sistema (o que hayas subido). La parte de explotar el driver vulnerable corre de tu cuenta.

## Descargo de responsabilidad

Esto es una herramienta para **pentesting autorizado, laboratorios y CTFs**. No la uses en sistemas que no sean tuyos o para los que no tengas permiso explícito por escrito. Cargar drivers de kernel sin control puede provocar BSOD y, en el peor caso, corromper el sistema. Yo lo he probado en máquinas virtuales y en laboratios de HackTheBox, y ahí funciona; en producción, bajo tu responsabilidad.

## Créditos

Fuentes:

- [ired.team — Privileged Accounts and Token Privileges](https://www.ired.team/offensive-security-experiments/active-directory-kerberos-abuse/privileged-accounts-and-token-privileges#seloaddriverprivilege)
- [HackTricks — SeLoadDriverPrivilege](https://book.hacktricks.xyz/windows-hardening/windows-local-privilege-escalation/privilege-escalation-abusing-token-privileges)
- [FuzzySecurity — Capcom-Rootkit](https://github.com/FuzzySecurity/Capcom-Rootkit) (driver y exploit de ejemplo)
- [JoshMorrison99 — SeLoadDriverPrivilege](https://github.com/JoshMorrison99/SeLoadDriverPrivilege) (`EoPLoadDriver`, que a mí me fallaba por DLLs en algunas máquinas y por eso acabé escribiendo esto)

## Licencia

MIT. Haz lo que quieras con el código, solo no me eches la culpa si algo se rompe.

