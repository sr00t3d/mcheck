[🇺🇸 English](README.md) | [🇧🇷 Português (BR)](README-ptbr.md) | 🇪🇸 **Español**

# mcheck — CLI de Monitoreo de DNSBL / RBL y Gateways SMTP Personalizados

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-brightgreen.svg)](https://github.com/sr00t3d/mcheck/releases)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-dig%20%2B%20curl-informational.svg)](#requisitos)

**`mcheck.sh`** es una CLI ligera en Bash para auditar direcciones IPv4, dominios (registros A/MX), la IP pública de salida del servidor y **gateways de correo SMTP personalizados (`customGateway`)** frente a **16 zonas DNSBL / RBL activas y verificadas empíricamente**.

Creado originalmente en 2014 por **Percio Andrade (Percio Castelo)** para monitorear gateways de correo en servidores compartidos, **`v2.0.0`** reemplaza los gateways fijos heredados de HostGator por un registro persistente `customGateway`, elimina listas obsoletas o cerradas (SORBS, APEWS, Manitu, etc.), detecta bloqueos de resolvers públicos de Spamhaus/CBL (`QUERY_BLOCKED`) y genera reportes estructurados en `table`, `json` y `csv` listos para Cron, Zabbix y flujos de NOC.

---

## Características

- **16 DNSBLs Activas Verificadas (2026):** Lista curada de RBLs IPv4 operativas (zonas inactivas como SORBS y APEWS eliminadas).
- **Gestor de Gateways Personalizados (`customGateway`):** Registra, lista, elimina y audita en lote tus propios relays SMTP en `~/.config/mcheck/gateways.conf` (o un archivo personalizado mediante `--gateways-file`).
- **Protección contra Falsos Positivos (`QUERY_BLOCKED`):** Distingue automáticamente los bloqueos por resolver público de Spamhaus/CBL (`127.255.255.*`) de listados reales (`LISTED`). Soporta `--resolver <ip>` para resolvers recursivos locales o dedicados.
- **Objetivos Flexibles:** Audita una IPv4 (`-i 1.1.1.1`), un dominio con resolución automática A/MX (`-i mail.example.com`), la IP pública de salida del host (`-m`) o todos los gateways registrados (`-g`).
- **Listo para Automatización y NOC:** Incluye `--only-listed`, `--exit-code` (sale con código `2` si alguna IP aparece `LISTED`) y `-o table|json|csv`.
- **Listas RBL Personalizadas:** Sobrescribe las 16 zonas integradas en cualquier momento con `--rbl-file <ruta>`.

---

## DNSBLs Verificadas Integradas (16 Zonas)

| Categoría | Zonas DNSBL |
| :--- | :--- |
| **Reputación Principal** | `zen.spamhaus.org`, `cbl.abuseat.org`, `b.barracudacentral.org`, `bl.spamcop.net` |
| **Pasivas / Política** | `psbl.surriel.com`, `ips.backscatterer.org`, `bl.mailspike.net`, `z.mailspike.net` |
| **UCEPROTECT** | `dnsbl-1.uceprotect.net`, `dnsbl-2.uceprotect.net`, `dnsbl-3.uceprotect.net` |
| **Abuso y Seguridad** | `all.s5h.net`, `bl.0spam.org`, `rbl.interserver.net`, `bl.blocklist.de`, `bl.nordspam.com` |

> **Nota sobre Spamhaus y CBL (`QUERY_BLOCKED`):** Spamhaus y CBL devuelven `127.255.255.254` cuando se consultan mediante resolvers públicos/abiertos (como `8.8.8.8` o `1.1.1.1`). `mcheck.sh` clasifica esos códigos como `QUERY_BLOCKED` en lugar de falsas alertas `LISTED`. Usa `--resolver <tu-dns-local>` para consultarlos desde un resolver privado.

---

## Requisitos

- Bash 4.0+
- `dig` (`bind-utils` / `dnsutils`)
- `curl` (solo requerido para `-m` / `--my-ip`)
- Utilidades POSIX estándar (`awk`, `grep`, `sort`, `tr`)

---

## Instalación

```bash
git clone https://github.com/sr00t3d/mcheck.git
cd mcheck
chmod +x mcheck.sh

# Opcional: instalar globalmente
sudo install -m 0755 mcheck.sh /usr/local/bin/mcheck
```

---

## Uso

```bash
# Auditar una IPv4 o dominio (resuelve registros A/MX)
./mcheck.sh -i 1.1.1.1
./mcheck.sh -i cloudflare.com --only-listed

# Verificar detección con la IP de prueba RFC 5782 (código de salida 2 si LISTED)
./mcheck.sh -i 127.0.0.2 --only-listed --exit-code

# Auditar la IP pública de salida del servidor actual
./mcheck.sh -m
./mcheck.sh -m -o json

# Gestionar y auditar gateways SMTP personalizados (customGateway)
./mcheck.sh --add-gateway relay01.example.com
./mcheck.sh --add-gateway 203.0.113.25
./mcheck.sh --list-gateways
./mcheck.sh -g --only-listed --exit-code
./mcheck.sh --remove-gateway 203.0.113.25

# Usar un archivo de gateways propio y exportar a CSV
./mcheck.sh -g --gateways-file ./gateways.example.conf -o csv

# Usar un resolver DNS recursivo privado para Spamhaus/CBL
./mcheck.sh -i 203.0.113.10 --resolver 127.0.0.1
```

### Todas las Opciones

| Opción | Descripción |
| :--- | :--- |
| `-i, --ip <ip\|dominio>` | Audita una dirección IPv4 o dominio (resuelve registros A/MX) |
| `-m, --my-ip` | Audita la IPv4 pública de salida del host actual |
| `-g, --check-gateways` | Audita todos los gateways personalizados registrados |
| `--add-gateway <host\|ip>` | Registra un gateway SMTP en `gateways.conf` |
| `--remove-gateway <host\|ip>` | Elimina un gateway SMTP de `gateways.conf` |
| `--list-gateways` | Lista todos los gateways personalizados registrados |
| `--gateways-file <ruta>` | Archivo de gateways (por defecto: `~/.config/mcheck/gateways.conf`) |
| `--rbl-file <ruta>` | Archivo personalizado de zonas DNSBL (una zona por línea) |
| `--resolver <ip>` | IP de resolver DNS personalizado |
| `--timeout <seg>` | Timeout por consulta DNSBL en segundos (por defecto: `2`) |
| `--only-listed` | Muestra solo filas `LISTED` / `QUERY_BLOCKED` / `TIMEOUT` en la tabla |
| `--exit-code` | Devuelve código `2` si alguna IP está `LISTED` (ideal para Cron/CI/NOC) |
| `-o, --output <fmt>` | Formato de salida: `table` (por defecto), `json`, `csv` |
| `-q, --quiet` | Omite el encabezado y el resumen final |
| `--no-color` | Desactiva colores ANSI |
| `-V, --version` | Muestra la versión y sale |
| `-h, --help` | Muestra la ayuda y sale |

---

## Ejemplo Real de Salida

### Auditoría en Tabla (`./mcheck.sh -i 1.1.1.1`)

```text
================================================================================
 mcheck.sh v2.0.0 | DNSBL Reputation Audit (16 RBLs) | 2026-11-21T03:11:18Z
================================================================================
TARGET                 IP              DNSBL                      STATE          CODE
---------------------- --------------- -------------------------- -------------- ---------------
1.1.1.1                1.1.1.1         zen.spamhaus.org           QUERY_BLOCKED  127.255.255.254
1.1.1.1                1.1.1.1         cbl.abuseat.org            QUERY_BLOCKED  127.255.255.254
1.1.1.1                1.1.1.1         b.barracudacentral.org     CLEAN          -
1.1.1.1                1.1.1.1         bl.spamcop.net             CLEAN          -
1.1.1.1                1.1.1.1         psbl.surriel.com           CLEAN          -
1.1.1.1                1.1.1.1         dnsbl-1.uceprotect.net     CLEAN          -
1.1.1.1                1.1.1.1         dnsbl-2.uceprotect.net     CLEAN          -
1.1.1.1                1.1.1.1         dnsbl-3.uceprotect.net     CLEAN          -
1.1.1.1                1.1.1.1         bl.mailspike.net           CLEAN          -
1.1.1.1                1.1.1.1         z.mailspike.net            CLEAN          -
1.1.1.1                1.1.1.1         ips.backscatterer.org      CLEAN          -
1.1.1.1                1.1.1.1         all.s5h.net                CLEAN          -
1.1.1.1                1.1.1.1         bl.0spam.org               CLEAN          -
1.1.1.1                1.1.1.1         rbl.interserver.net        CLEAN          -
1.1.1.1                1.1.1.1         bl.blocklist.de            CLEAN          -
1.1.1.1                1.1.1.1         bl.nordspam.com            CLEAN          -

Summary: 16 checks | 14 CLEAN | 0 LISTED | 2 QUERY_BLOCKED | 0 TIMEOUT
```

### Prueba de Detección RFC 5782 (`./mcheck.sh -i 127.0.0.2 --only-listed --exit-code`)

```text
================================================================================
 mcheck.sh v2.0.0 | DNSBL Reputation Audit (16 RBLs) | 2026-11-21T03:11:20Z
================================================================================
TARGET                 IP              DNSBL                      STATE          CODE
---------------------- --------------- -------------------------- -------------- ---------------
127.0.0.2              127.0.0.2       zen.spamhaus.org           QUERY_BLOCKED  127.255.255.254
127.0.0.2              127.0.0.2       cbl.abuseat.org            QUERY_BLOCKED  127.255.255.254
127.0.0.2              127.0.0.2       b.barracudacentral.org     LISTED         127.0.0.2
127.0.0.2              127.0.0.2       bl.spamcop.net             LISTED         127.0.0.2
...
127.0.0.2              127.0.0.2       bl.nordspam.com            LISTED         127.0.0.2

Summary: 16 checks | 0 CLEAN | 14 LISTED | 2 QUERY_BLOCKED | 0 TIMEOUT
# Código de salida: 2
```

### Salida JSON (`./mcheck.sh -i 1.1.1.1 -o json`)

```json
{
  "tool": "mcheck.sh",
  "version": "2.0.0",
  "timestamp": "2026-11-21T03:11:22Z",
  "rbls_checked": 16,
  "total_checks": 16,
  "clean": 14,
  "listed": 0,
  "query_blocked": 2,
  "timeouts": 0,
  "results": [
    {
      "target": "1.1.1.1",
      "ip": "1.1.1.1",
      "rbl": "zen.spamhaus.org",
      "state": "QUERY_BLOCKED",
      "code": "127.255.255.254"
    },
    {
      "target": "1.1.1.1",
      "ip": "1.1.1.1",
      "rbl": "b.barracudacentral.org",
      "state": "CLEAN",
      "code": ""
    }
  ]
}
```

---

## Créditos e Historial

- **Autor Original (2014):** Percio Andrade (Percio Castelo) — creado como monitor operacional de RBLs y gateways en servidores de correo compartidos.
- **Modernización v2.0.0 (2026):** Percio Castelo — reemplazo de los gateways fijos de HostGator por `customGateway`, curaduría de 16 DNSBLs activas en 2026, protección `QUERY_BLOCKED` para Spamhaus/CBL y exportación JSON/CSV.

## Licencia

Licenciado bajo la [Apache License 2.0](LICENSE).
