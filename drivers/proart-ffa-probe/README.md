# proart_ffa_probe (diagnostic)

One-shot, read-only kernel module: sends a few query commands to the EC services behind FF-A
(ODP battery service `25cb5207-...` and the ASUS OEM service `884a63a0-...`) and logs the complete
response registers x4..x17. Returns `-EAGAIN` from init, so it never stays loaded.

This is how it was found that the ASUS service answers direct requests with real data while the
ACPI path only ever sees its own request echoed back (see `docs/technical-notes.md`).

Run: `tools/ffa-probe.sh`. License: GPL-2.0.
