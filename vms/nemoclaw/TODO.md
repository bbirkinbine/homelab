# TODO — nemoclaw

Open questions parked for later. Nothing here blocks the current
deploy flow.

## Explore: OpenBao as the secret backend for nemoclaw

### What nemoclaw stores today, and where

Once the operator runs the install + `nemoclaw onboard` ceremonies,
the stack's secrets live in a few places under
`/home/nemoclaw/` (owned by the `nemoclaw` service user):

- **NVIDIA Endpoints API key.** The default inference provider's
  bill-bearing credential; lives in nemoclaw config (typically
  under `~/.nemoclaw/` or in a Docker secret) after onboard.
- **Optional routed-pool provider keys.** If the operator turned on
  the LiteLLM-backed routed pool, additional keys for
  Anthropic/OpenAI/Ollama-via-API-key flow into the router's config.
- **OpenClaw-inside-the-sandbox tokens.** Model provider auth +
  channel pairings, same shape as `vms/openclaw/` but the storage
  lives inside the OpenShell sandbox's persistent state (typically
  Docker volumes under `/var/lib/docker/`).
- **Channel pairing tokens.** Routed through OpenShell's channel
  manager rather than directly through OpenClaw — but the tokens
  themselves are still bearer credentials at rest.

These are plaintext on disk + in Docker volumes by default. The role
doesn't lay any of them down — they arrive during onboard.

The backup tar pattern in [README.md "Backup the sandbox + state"](README.md)
captures `/var/lib/docker` + `/home/nemoclaw/`, so the resulting
`.tgz` is also secret-bearing.

### The exploration

Could nemoclaw read its credentials out of `vms/openbao/` instead?
Three layers to consider, since nemoclaw stacks more than openclaw:

- **NVIDIA Endpoints key + routed-pool keys** — host-side config,
  closest analog to openclaw's model-provider story. Probably the
  easiest layer to wire up if upstream nemoclaw / LiteLLM offers a
  Vault-aware config loader (LiteLLM's docs mention Vault).
- **OpenClaw inside the sandbox** — same questions as
  [`vms/openclaw/TODO.md`](../openclaw/TODO.md), but with the extra
  twist that the sandbox is meant to be netns-isolated. Reaching out
  to openbao from inside the sandbox needs explicit allowance in the
  declarative network policy — at which point the principle of
  least-privilege starts working against you.
- **Channel pairings** — routed through OpenShell's channel
  manager; the manager itself runs on the host (outside the
  sandbox), so the openclaw-layer answer probably applies.

### Open sub-questions

1. **Sandbox boundary vs. secret backend.** OpenShell's sandbox is
   designed to limit what the agent can talk to. Punching a hole for
   "talk to openbao to fetch a model-provider key" partially defeats
   the sandboxing — unless the secret fetch happens host-side at
   sandbox-launch time and the cleartext is injected as an env
   var / file mount that the sandbox sees but can't re-resolve.
2. **LiteLLM Vault integration.** If the routed pool is on, LiteLLM
   is the natural integration point — it already understands
   per-provider key bindings and has docs for Vault. Check what
   shape that takes today.
3. **Auth model for nemoclaw-host → openbao.** Same shape as the
   openclaw TODO — AppRole? Periodic token? Where does the
   bootstrap credential live, and how is it revoked at VM destroy?
4. **Backup story.** If secrets move out of `/var/lib/docker`, the
   backup tar shrinks dramatically and the offsite-`.tgz` stops
   being secret-bearing. That's a win for backup hygiene — worth
   weighing in the trade-off.

### Why this matters

Secrets handling for the claws is currently the "trust the
filesystem" pattern, which works for a single-operator LAN-only
homelab but breaks down if the lab grows another operator or if
`vms/openbao/` becomes the audit/rotation source-of-truth for
everything else (its design intent — see
[`vms/openbao/README.md`](../openbao/README.md)). nemoclaw is more
interesting than openclaw here because its sandbox boundary
interacts with the secret-fetch path in a non-trivial way; the
answer for openclaw doesn't transfer cleanly.

### Related

- [`vms/openbao/`](../openbao/) — the local Vault deployment that
  would back this.
- [`vms/openclaw/TODO.md`](../openclaw/TODO.md) — sibling question
  for the unsandboxed counterpart.
- [`vms/nemoclaw/README.md`](README.md) "Security notes" — current
  posture on the on-disk + in-volume secrets.
- LiteLLM Vault integration docs (search upstream when picking this
  up — LiteLLM's docs move around).
- Upstream NemoClaw docs at
  [docs.nvidia.com/nemoclaw](https://docs.nvidia.com/nemoclaw/latest/)
  — search for "vault", "secret", "credentials".
