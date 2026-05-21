# vms/hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) on Ubuntu
24.04 — Nous Research's personal-AI CLI + optional messaging gateway,
in the same role-class as [`vms/openclaw/`](../openclaw/) and
[`vms/nemoclaw/`](../nemoclaw/). The agent is a Python 3.11 + Node.js
stack that the upstream installer brings down into `~/.hermes/`; this
role does the host prep so that install Just Works.

Provisioned with OpenTofu, configured with Ansible. Mirrors the
shape of [`vms/openclaw/`](../openclaw/) — see
[`docs/deploying-vms.md`](../../docs/deploying-vms.md) for the
cross-cutting workflow.

> **What this VM is for.** Run hermes-agent as a long-lived,
> single-user assistant on a LAN-only host. Inference is **offloaded**
> to the chosen model provider (Nous Portal, OpenRouter, OpenAI,
> Anthropic, etc.) — no GPU needed in this VM. Optionally enable the
> `hermes gateway` to bridge messaging channels (Telegram, Discord,
> Slack, WhatsApp, Signal, Email) into the same agent.

## Layout

```text
vms/hermes/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, cloud-init)
├── ansible/                   role config (system prereqs + service user)
└── cloud-init/                first-boot identity (hostname, user, SSH key)
```

## Why hermes alongside the claws?

The [`vms/openclaw/`](../openclaw/) and [`vms/nemoclaw/`](../nemoclaw/)
roles cover the same agent-with-optional-gateway problem space from
different angles (host-native vs. OpenShell-sandboxed). hermes-agent
is a third take on it from a different upstream (Nous Research,
distinct from the OpenClaw and NemoClaw teams) with its own runtime
stack:

| | `vms/openclaw/` | `vms/nemoclaw/` | `vms/hermes/` |
| --- | --- | --- | --- |
| Upstream | openclaw.ai | NVIDIA NemoClaw (alpha) | Nous Research hermes-agent |
| Language stack | Node 24 (system) | Docker + Node 22 + k3s | Python 3.11 + Node (both bundled by installer under `~/.hermes/`) |
| Tool sandbox | Operator-opt-in | OpenShell default | None (host-native) |
| Inbound port | 18789 (gateway HTTP) | None by default | None by default (gateway uses outbound polling / webhooks pointed at user-provided URLs) |
| Inference | Any OpenClaw-supported provider | NVIDIA Endpoints by default | Nous Portal / OpenRouter / OpenAI / Anthropic |
| Onboard time | `openclaw onboard` | `nemoclaw onboard` | `hermes setup` |

Keep all three for the "compare deployment models" lab pattern. They
intentionally don't overlap in trust-model, runtime, or upstream
governance.

## Prerequisites

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template.** Ubuntu base must exist on the target node
   (VMIDs `9100`/`9101`/`9102` per [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md)).
   If not: `packer/ubuntu-24-04-base/build-pve.sh <node>`.
3. **`tofu@pve` API token.** See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
   Stash the token in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
4. **SSH access to the node + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve12t` (or whichever node `proxmox_node` points
   at), then `ssh-add ~/.ssh/id_ed25519` once per shell session. The
   `bpg/proxmox` provider uploads cloud-init snippets over SSH (not
   the HTTP API) and shells out non-interactively, so the key must
   already be in the agent before `tofu apply`. Preflight verifies
   both. See [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md)
   section **(d) Load the private key into `ssh-agent`** for the
   macOS Keychain auto-load pattern that survives reboot.
5. **Snippets storage enabled** on whichever pool `snippets_storage`
   points at (default `nas-vms`). Preflight reports a cure command if
   not.
6. **A model provider account.** You'll authorize this during the
   `hermes setup` wizard, not at deploy time. Nous Research's own
   Nous Portal is the headline option; OpenRouter, OpenAI, Anthropic,
   and Ollama (against a local LLM endpoint such as
   [`vms/llm/`](../llm/)) are all supported. Have credentials ready
   before running setup.

## Deploy

From repo root:

```bash
just ansible-deps hermes   # one-time per workstation
just hydrate hermes        # render terraform.tfvars from KeePassXC
just plan hermes           # review the plan
just apply hermes          # create the VM
just inventory hermes      # write ansible/inventory.yml from tofu output
just ansible-check hermes  # OPTIONAL: dry-run the role (see below)
just ansible hermes        # install prereqs: ripgrep/ffmpeg/git/build-tools + service user
```

End state: a VM with `ripgrep`, `ffmpeg`, `git`, and Python/C build
tools on PATH; the `hermes` service user created with bash + linger +
`~/.bashrc` XDG runtime guard; and apt-daily timers active. **The
hermes-agent itself is NOT installed yet** — the role deliberately
stops at prereqs so it survives upstream's install-path churn (the
upstream installer manages its own uv + Python 3.11 + Node tarball
under `~/.hermes/`). The operator runs the install + setup ceremonies
below.

### Previewing with `--check` first

`just ansible-check hermes` works on a fresh host and produces a
useful diff out of the box. Unlike the openclaw / nemoclaw roles,
hermes has no third-party apt repo to bootstrap (the upstream
installer brings down its own uv + Python + Node bundle), so none
of the tasks need a `check_mode: false` escape hatch.

## Install hermes-agent

Run upstream's installer as the `hermes` service user. **No sudo is
needed** — our role pre-installed every system package the installer
would otherwise `sudo apt install -y` mid-stream (`ripgrep`, `ffmpeg`,
plus the `gcc` / `python3-dev` / `libffi-dev` helpers it auto-offers
for wheel builds), so the installer's "sudo -n true" probe skips the
sudo branch entirely. Everything else — uv + Python 3.11 + Node
under `~/.hermes/`, the venv, the agent itself, the `~/.local/bin/hermes`
symlink — runs in the service user's `$HOME`.

> Upstream's install reference: [github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).
> Check the README before deploying — the install URL or recommended
> env vars may have shifted since this VM README was written.

```bash
ssh hermes-admin@<vm-ip>
sudo -u hermes -i             # become the service user
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.bashrc              # pick up ~/.local/bin on PATH
hermes --version              # smoke check
```

Upstream-honored env vars on the install.sh path (useful for CI /
rebuild scripts):

| Variable | Effect |
| --- | --- |
| `HERMES_HOME=<dir>` | Override the default `~/.hermes` config + state directory |
| `HERMES_INSTALL_DIR=<dir>` | Explicit install location for the hermes-agent git checkout + venv |
| `DEBIAN_FRONTEND=noninteractive` | Already set by the installer for apt; safe to re-export from the operator's shell |

The installer auto-detects TTY and skips its interactive Playwright /
WhatsApp prompts when run non-interactively. There is no single
`NO_PROMPT=1` env var as of 2026-05; see upstream for the full
non-interactive matrix.

## First-setup ceremony (operator-driven, one-time)

`hermes setup` is interactive — model-provider auth happens via OAuth
or API-key paste, and gateway channel pairings require QR scans
(WhatsApp), bot tokens (Telegram), OAuth round-trips (Slack / Discord),
or message-handle ownership proofs (Signal). None of that is
automatable from Ansible. Run it once, by hand, from the VM:

```bash
ssh hermes-admin@<vm-ip>
sudo -u hermes -i             # become the service user
hermes setup                  # full provider + (optional) gateway wizard
# OR more granularly:
hermes model                  # just pick an LLM provider
hermes gateway setup          # just configure messaging channels
```

The wizard walks through, roughly:

1. **Model provider auth.** Choose Nous Portal / OpenRouter / OpenAI
   / Anthropic / Ollama (or one of the others upstream supports).
   API-key providers take the key directly; OAuth providers open a
   browser link — copy it into your workstation browser, complete
   the flow, paste the resulting code back.
2. **(Optional) Gateway channel pairings.** Pick which channels you
   want (Telegram, Discord, Slack, WhatsApp, Signal, Email). Each
   runs its own flow per upstream docs.
3. **Skill selection.** Hermes ships a set of skills under
   `~/.hermes/skills/`; pick from the bundled set or skip — you can
   add skills later by dropping them into that directory.

### Daemonizing the gateway (optional)

If you configured the gateway during setup, the cleanest persistent
option is upstream's `hermes gateway install`, which writes a
user-systemd unit. The role already enabled `loginctl enable-linger
hermes` so the unit survives logout. Check status with:

```bash
sudo -u hermes -i
systemctl --user status hermes-gateway
journalctl --user -u hermes-gateway -f
```

(Unit name follows upstream's convention as of 2026-05; verify with
`systemctl --user list-unit-files | grep hermes` after install if
upstream renames it.)

If you'd rather run the gateway under tmux / screen / a hand-rolled
system unit, the role doesn't lock you in — none of the prereqs
assume a particular daemonization path.

Test by sending a message to any paired channel (or just running
`hermes` for an interactive chat); the agent should reply.

## Operations

### Logs

If you took the `hermes gateway install` path:

```bash
ssh hermes-admin@<vm-ip>
sudo -u hermes -i
journalctl --user -u hermes-gateway -f
```

If you're running interactively or under tmux/screen, log location
depends on how you wired it up. Hermes itself writes session
transcripts under `~/.hermes/sessions/` and per-run logs under
`~/.hermes/logs/`.

### Troubleshooting: `systemctl --user` / `journalctl --user`

Two related gotchas can hit anyone running these as the service user
via `sudo -u hermes -i`. The role handles both on a fresh deploy; the
notes below explain the mechanism in case you hit either symptom on
an existing host that hasn't re-run Ansible yet (or in a corner
invocation like `sudo -u hermes bash -c '...'`, which skips
`.bashrc`).

- **`Failed to connect to bus: No medium found`.** Ubuntu's
  `/etc/pam.d/sudo` includes `common-session-noninteractive`, which
  does NOT invoke `pam_systemd` — so the sudo'd shell never registers
  with logind, and `$XDG_RUNTIME_DIR` stays unset. Linger is still on
  and `user@<uid>.service` is still running; the shell just isn't
  pointed at its bus. The role drops a guarded export into
  `~hermes/.bashrc` so a fresh `sudo -u hermes -i` shell has
  `XDG_RUNTIME_DIR` set automatically. If you're in an already-open
  session that started before the role landed, either re-login or
  set it inline:

  ```bash
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  ```

  Alternative invocation that sidesteps this entirely:
  `sudo machinectl shell hermes@.host /bin/bash` — `machinectl`
  goes through logind and sets the env up correctly. SSH'ing directly
  as the hermes user also works (same reason).

- **`No journal files were opened due to insufficient permissions`.**
  User-unit messages land in `/var/log/journal/` and only members of
  `systemd-journal` / `adm` can read them. The role adds the hermes
  user to `systemd-journal` so `journalctl --user -u hermes-gateway`
  works without sudo. If you deployed before this task landed, re-run
  `just ansible hermes` and start a fresh login session (group
  membership only refreshes on a new session).

### Upgrading

Upstream's canonical upgrade command is `hermes update`, run by the
hermes user itself:

```bash
ssh hermes-admin@<vm-ip>
sudo -u hermes -i
hermes update
```

If `hermes update` fails (the script does in-place `git pull` +
`uv pip install -e '.[all]'` against the install dir), the fallback
is to re-run the installer — same command as the initial install,
idempotent in-place against an existing `~/.hermes/`.

The role itself does NOT manage the hermes-agent version — re-running
`just ansible hermes` only refreshes system prereqs (apt packages,
service user, sudoers toggle), which is rarely the reason to upgrade.

### Stable IP via DHCP reservation

`just output hermes` reports the MAC. Pin a DHCP reservation on the
router — if you've paired any inbound webhook channels (some Slack /
Discord flows), they register against an IP, and re-pairing after
every lease rotation is friction. Same recommendation as the claws.

### Backup + restore

`~/.hermes/` (on the VM, owned by the hermes service user) is the
only irreplaceable state — provider auth tokens, channel pairings,
session history, custom skills, the `.env` API keys. Three layered
options, pick what fits the failure you're insuring against:

**1. Manual tar of `~/.hermes/` (recommended for everyday rollback).**
Upstream doesn't ship a purpose-built backup CLI as of writing, so
this is the workhorse path:

```bash
ssh hermes-admin@<vm-ip>
sudo tar -czf /tmp/hermes-state-$(date +%F).tgz -C /home/hermes .hermes
sudo chown hermes-admin: /tmp/hermes-state-*.tgz
scp hermes-admin@<vm-ip>:/tmp/hermes-state-*.tgz ./backups/
```

Watch out for `.hermes/sessions/` getting large over time — strip it
out (`tar --exclude='.hermes/sessions'`) if you only need the
provider credentials + skill config back.

**2. Whole-VM PBS snapshot (recommended for catastrophic recovery).**
The lab's [`pbs-hosts/`](../../pbs-hosts/) Proxmox Backup Server is
available cluster-wide once a backup job is configured in the PVE UI
or via `pvesh`. A PBS snapshot captures everything — OS, role-state,
`~/.hermes/`, the agent install, the service user, the cloud-init
identity — so recovery is "restore the VM and boot." Heavier than
the manual tar and slower to restore for a state-only fix, but the
safety net for "this VM is corrupted in some way I can't diagnose."
Configure via Datacenter → Backup in the PVE UI; the role itself
doesn't manage backup jobs.

**3. Provider-side recovery (escape hatch for credentials).** If
`~/.hermes/` is lost entirely and you don't have a tar, every
provider token can be re-issued from the upstream provider's UI;
every channel can be re-paired through `hermes gateway setup`.
Session history is the only thing genuinely gone in that case.

Push your archives to your usual offsite path either way — the
agent binary is reproducible from `curl | bash`, only `~/.hermes/`
is state.

## Destroy and rebuild

> **WARNING.** Destroying this VM loses every provider token and
> channel pairing under `~/.hermes/`. Re-doing setup from scratch
> means re-OAuth'ing every model provider, re-scanning WhatsApp's
> QR, re-bot-token'ing Telegram, etc. Take a backup first if you
> want a clean restore.

Restore from a manual tar:

1. `just apply hermes` on the rebuilt VM.
2. `just ansible hermes` — gets prereqs in place.
3. Install hermes-agent per the "Install hermes-agent" section above.
4. Stop the gateway if it was daemonized:
   `sudo -u hermes -i systemctl --user stop hermes-gateway`.
5. Copy the archive to the VM and extract under the hermes user's `$HOME`:

   ```bash
   scp hermes-state-<date>.tgz hermes-admin@<vm-ip>:/tmp/
   ssh hermes-admin@<vm-ip>
   sudo -u hermes -i
   cd $HOME && tar -xzf /tmp/hermes-state-<date>.tgz
   ```

6. Restart the gateway (or re-run `hermes setup` for a fresh config).

Restore from a PBS snapshot: restore the VM in the PVE UI (Datacenter →
`<node>` → `<VMID>` → Backup → Restore). The whole VM comes back
including the hermes install and `~/.hermes/` — skip steps 2-5 above.

```bash
just destroy hermes        # only after a state backup is offsite
just apply hermes
just ansible hermes
# then install hermes per "Install hermes-agent" above, then restore
# or re-run `hermes setup` for fresh config
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 4 | Matches the claws' "Recommended" tier — hermes is I/O-bound to LLM providers; headroom is for skill subprocesses + ffmpeg transcodes (image_cache / audio_cache under `~/.hermes/`) |
| RAM | 16 GiB | Same anchor as the claws; generous for Python 3.11 venv + the bundled Node + optional Playwright/Chromium for the browser tool |
| Disk | 64 GiB | Boot + `~/.hermes/` (sessions / logs / cron + caches) + the agent's git checkout + venv + `~/.hermes/node/` (~120 MB). Leaves headroom for a Playwright install (~400 MB) |
| Balloon | 0 | Node's V8 heap + Python GC respond poorly to host memory pressure — cheap insurance, same as the claws |
| Machine | q35 | Matches the rest of the homelab |
| CPU type | x86-64-v3 | Common baseline across the cluster's NUCs — supports live migration |

Override in `vms/hermes/terraform/main.tf`'s `module "hermes"` call.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (opened by base template + Ansible) |

No inbound listener by default. hermes-agent's gateway uses outbound
polling for Telegram/Discord/Slack/etc., and any webhook-based channel
points its callback URL at upstream-hosted infrastructure (or your
own reverse proxy, externally fronted). If you front the gateway with
a local HTTP listener — e.g., a custom skill exposing a webhook —
open the port through `ufw` separately (the role pulls in
`community.general` so an `ansible.builtin.import_tasks` add-on can
use the `ufw` module without a dependency dance).

## Security notes

> ### Trust-model decision: does the agent get sudo?
>
> **By default this role keeps the hermes service user
> unprivileged** — no sudo, no escalation path. The role's baseline
> is least-privilege, matching openclaw.
>
> **Many agent deployments take the opposite stance** and grant
> the agent NOPASSWD sudo so it can install packages, restart
> services, and edit configs as part of its tool capabilities (the
> "let the agent run the whole machine" pattern). If that's what
> you want, opt in by setting `hermes_grant_sudo: true` in
> `ansible/inventory.yml` and re-running `just ansible hermes`.
> The role drops `/etc/sudoers.d/hermes` granting
> `hermes ALL=(ALL) NOPASSWD:ALL`.
>
> Treat this as a deliberate decision per deployment, not a default.
>
> **Want an agent with real guardrails instead?** That's
> [`vms/nemoclaw/`](../nemoclaw/) — unprivileged service user PLUS
> OpenShell sandbox with declarative network policy and capability
> drops. The three agent roles intentionally occupy different points
> in the trust-model spectrum.

- **Provider tokens + API keys.** Live under `~/.hermes/.env` and
  `~/.hermes/config.yaml` on the VM, owned by the hermes user (the
  installer writes `.env` mode 600). The backup tar from the
  Operations section captures these — treat the resulting `.tgz` as
  secret.
- **Outbound-only by default.** The agent talks out to LLM providers
  and (if you opt in) messaging APIs. No port is exposed inbound; no
  reverse proxy is required. Off-LAN access to the LAN's `hermes`
  CLI sessions, if you want it, is best layered through Tailscale on
  top of the LAN-only baseline.
- **Skills run as the hermes user.** Hermes ships a bundled skill set
  under `~/.hermes/skills/` and the agent invokes them with whatever
  privileges the service user has. With `hermes_grant_sudo: true`,
  that means skills can `sudo` — review any third-party skills
  pulled from the wider ecosystem before installing them.

## Files

- `terraform/main.tf` — provider + module call (sizing, cloud-init).
- `terraform/variables.tf` — five inputs (endpoint, token, node, user,
  key) plus the two storage knobs (`disk_storage`, `snippets_storage`).
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` + `roles/hermes/` — install prereqs (apt
  packages, service user, sudoers toggle); stops short of the
  hermes-agent install itself.

## Related

- Upstream: [github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow, state.
- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser, repeatable 7-step flow.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — API token + role.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces the Ubuntu base template.
- [`vms/openclaw/`](../openclaw/) — sibling agent role (host-native, Node 24).
- [`vms/nemoclaw/`](../nemoclaw/) — sibling agent role (Docker + OpenShell sandbox).
- [`vms/llm/`](../llm/) — local inference target if you want
  to point the `hermes model` wizard at an Ollama endpoint instead
  of a hosted provider.
