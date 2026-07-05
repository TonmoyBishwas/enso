# SMC Key Registry (Apple Silicon)

Living document. Semantics gathered from charlie0129/batt, rurza/BatFi, mhaeuser/Battery-Toolkit, OpenDente, and the Linux `macsmc-power` driver. **Verify on real hardware before trusting a new key.**

## Charging control (root required to write)

| Key | Type | Semantics | Firmware |
|---|---|---|---|
| `CHTE` | u32 | Charging inhibit. `0x00000001` (LE `01 00 00 00`) = inhibit, `0` = allow | macOS 26 Tahoe firmware |
| `CH0B` | u8 | Charging inhibit gate. `0x02` = inhibit, `0x00` = allow. Write together with `CH0C`. Read-back may return `0x03` when inhibited | pre-Tahoe |
| `CH0C` | u8 | Sibling of `CH0B`, same values | pre-Tahoe |
| `CHIE` | u8 | Adapter disable / force discharge. `0x08` = disable adapter, `0x00` = enable | Tahoe |
| `CH0I` | u8 | Force discharge on AC. `0x01` = discharge, `0x00` = normal | pre-Tahoe |
| `CH0J` | u8 | Secondary adapter gate (batt: enable=0x0, disable=0x1) | pre-Tahoe |
| `CHWA` | u8/flag | Apple's fixed 80% limit. `1` = on. Not adjustable; used only for "defer to macOS" mode. Sequoia+ restricts writes from non-entitled processes | 13.0+ |

Strategy: probe at daemon start / wake / write-failure. Prefer `CHTE`/`CHIE` when present; else `CH0B`+`CH0C` / `CH0I`.

## Status / telemetry (read-only, no root for IORegistry equivalents)

| Key | Meaning |
|---|---|
| `BUIC` | Hardware battery charge % (1 byte) |
| `B0CT` | Cycle count |
| `TB0T`/`TB1T`/`TB2T` | Battery temperature sensors |
| `B0AC`/`B0AV` | Battery current / voltage |
| `PPBR`/`PSTR` | Battery / system power |
| `ID0R`/`VD0R`/`PDTR` | DC-in current / voltage / power |
| `AC-W` | Adapter plugged state |
| `CH0R` | Charge status bits (bit0 CH0I active, bit4 charger disconnected, bit11 CHWA active) |
| `CHNC` | Charge flags (bit0 full, bit7 no charger, bit14/15 inhibit) |
| `MSLD` | Lid closed |

## MagSafe LED — `ACLC` (u8)

| Value | State |
|---|---|
| `0x00` | System-controlled (default) |
| `0x01` | Off |
| `0x03` | Green |
| `0x04` | Orange/amber |
| `0x05`–`0x07` | Error blink variants |

## I/O mechanics

`IOServiceMatching("AppleSMC")` → `IOServiceOpen` (connection type 0) → `IOConnectCallStructMethod` selector 2 (`kSMCHandleYPCEvent`) with `SMCParamStruct`: two-phase — `READ_KEYINFO` (0x9) to get size/type, then `READ_BYTES` (0x5) / `WRITE_BYTES` (0x6). Reads work unprivileged for most keys; writes require root (and Sequoia 15+ enforces entitlements on some keys — `CH0B/CH0C/CHTE` from a root daemon remain writable as of 26.5).

## History that bit people

- **15.0 Sequoia:** kernel entitlement enforcement killed unsigned `BCLM`/`CHWA` writers (bclm is dead).
- **15.5:** silent SMC firmware update temporarily broke AlDente's limiting; persisted across OS downgrades.
- **26.0 Tahoe:** inhibit interface moved to `CHTE`/`CHIE`; `CH0B/CH0C` absent on updated units.
- **26.4:** Apple shipped a native charge limit (80–100% in 5% steps) — detect and coexist.
