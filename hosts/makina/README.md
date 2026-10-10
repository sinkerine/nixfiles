# Makina

Makina is the Android mobile host. Its sing-box Android profile generator lives in this directory.

The exporter writes only these profiles, all with a Tailscale endpoint enabled:

- `amane-tailscale`
- `amane-paypal-tailscale`
- `sachi-tailscale`
- `sachi-paypal-tailscale`
- `michiru-cn-direct-tailscale`

The last profile sends China destinations direct, sends tailnet destinations through its Tailscale endpoint, and sends other destinations through Michiru. It reuses Makina's Sachi Tailscale identity because SFA runs only one profile at a time. The exporter removes only its exact legacy Amane, Sachi, and `michiru-cn` output filenames when regenerating.

Makina's Michiru outbound uses relay address `103.117.101.12`; encrypted config still supplies its port and credentials.
