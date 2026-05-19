# TODO — openclaw

Open questions parked for later. Nothing here blocks the current
deploy flow.

## Explore: OpenBao as the secret backend for openclaw

### What openclaw stores today, and where

Once the operator runs the install + `openclaw onboard` ceremonies,
the gateway's secrets live on the VM under `/home/openclaw/.openclaw/`
(owned by the `openclaw` service user, mode 0750):

- **Model provider auth.** OAuth refresh tokens for ChatGPT/Codex, or
  raw API keys for Anthropic / OpenAI / providers that don't OAuth.
- **Channel pairing tokens.** Telegram bot tokens (from BotFather),
  Slack/Discord OAuth refresh tokens, WhatsApp paired-device state.
- **Allowlist + pairing-code state** for the DM-pairing policy.

These are plaintext on disk by default. The role doesn't lay any of
them down — they arrive during onboard and stay there until destroy.

The backup tar pattern in [README.md "Backup the workspace"](README.md)
captures the whole `~/.openclaw/` tree, so the `.tgz` itself is also
secret-bearing and needs the same care as the live host.

### The exploration

Could openclaw read these out of `vms/openbao/` instead? Concretely:

- **Native support?** Check whether upstream openclaw has any Vault /
  OpenBao integration (env vars like `OPENCLAW_*_VAULT_PATH`, a
  config schema for secret backends, a plugin model). If yes, the
  integration is the role's only job.
- **Wrapper-driven?** If no native support, can a thin wrapper script
  populate `~/.openclaw/` from OpenBao at start-time and refresh on
  rotation? Trade-off: secrets briefly hit disk OR a tmpfs overlay
  hides them; either way the wrapper carries the bootstrap problem.
- **Env-var bridge?** Some openclaw config values may be readable
  from env. `systemd-creds` or a systemd `LoadCredential=` chain
  from an openbao-cli `read` could keep secrets out of disk entirely
  for the long-lived process — at the cost of restart-required
  rotation.

### Open sub-questions

1. **Auth model for openclaw → openbao.** AppRole with a role-id
   baked into the role + a secret-id fetched at apply time? Periodic
   token? Workload identity? Whatever shape this takes, where does
   the bootstrap credential live, and how is it revoked when this
   VM is destroyed?
2. **Network reachability.** openbao listens on the LAN; openclaw
   sits on the same LAN. ufw on the openclaw side and openbao's
   policy on the other. Anything subtle about TLS trust for the
   client-side?
3. **Failure mode.** What happens when openbao is briefly unreachable
   — does openclaw stall the gateway, or cache the last-known values
   and keep serving? Both have trade-offs.
4. **Rotation cadence.** Model-provider tokens rarely rotate; channel
   pairings even less so. Is the operational cost worth it for this
   specific service?

### Why this matters

Secrets handling for the claws is currently the "trust the
filesystem" pattern, which works for a single-operator LAN-only
homelab but breaks down if the lab ever has more than one operator
or if `vms/openbao/` becomes the audit/rotation source-of-truth for
everything else (which is its design intent — see
[`vms/openbao/README.md`](../openbao/README.md)). Even if the answer
is "no, the integration cost outweighs the win for openclaw," that's
a deliberate decision worth recording.

### Related

- [`vms/openbao/`](../openbao/) — the local Vault deployment that
  would back this.
- [`vms/openclaw/README.md`](README.md) "Security notes" — current
  posture on the on-disk secrets.
- Upstream openclaw docs at [docs.openclaw.ai](https://docs.openclaw.ai)
  — search for "vault", "secret", "credentials" before reinventing.
