# vms/openclaw

[OpenClaw](https://github.com/openclaw/openclaw) on Ubuntu 24.04 — a
personal AI assistant gateway that bridges LLM providers to your
messaging channels (WhatsApp, Telegram, Slack, Discord, Matrix, …).
The gateway is a Node 24 daemon listening on `:18789`; channels +
model providers attach over OAuth/QR pairings driven by the
`openclaw onboard` CLI.

Provisioned with OpenTofu, configured with Ansible. Mirrors the shape
of [`vms/openbao/`](../openbao/) — see [`docs/deploying-vms.md`](../../docs/deploying-vms.md)
for the cross-cutting workflow.

> **What this VM is for.** Run OpenClaw as a long-lived, single-user
> assistant on a LAN-only host. The Mac/iOS/Android companion apps
> attach as nodes (see upstream docs); this VM is the gateway daemon
> they all talk to. LLM compute is **offloaded** to the chosen model
> provider (OpenAI, Anthropic, etc.) via OAuth — no GPU in this VM.

## Layout

```text
vms/openclaw/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, cloud-init)
├── ansible/                   role config (Node 24 + service user + ufw)
└── cloud-init/                first-boot identity (hostname, user, SSH key)
```

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
5. **Snippets storage enabled.** Datacenter → Storage → `local` →
   Edit → tick **Snippets**. Preflight reports a cure command if not.
6. **A model provider account.** You'll authorize this during the
   onboard ceremony, not at deploy time — but have it ready (OpenAI
   ChatGPT plan, Anthropic API key, or any of the other providers
   openclaw supports). The OAuth flow happens from the VM's CLI.

## Deploy

From repo root:

```bash
just ansible-deps openclaw   # one-time per workstation
just hydrate openclaw        # render terraform.tfvars from KeePassXC
just plan openclaw           # review the plan
just apply openclaw          # create the VM
just inventory openclaw      # write ansible/inventory.yml from tofu output
just ansible-check openclaw  # OPTIONAL: preview the role's diff (see "Previewing with --check first" below)
just ansible openclaw        # install prereqs: Node 24, service user, ufw rule
```

End state: a VM with Node 24 on PATH, the `openclaw` service user
created with bash + linger + a `~/.openclaw` workspace dir, ufw
allowing `:18789/tcp`, and apt-daily timers active. **The openclaw
binary is NOT installed yet** — the role deliberately stops at
prereqs so it survives upstream's install-path churn (npm-global,
`curl | bash`, containers). The operator runs the install + onboard
ceremonies below.

### Previewing with `--check` first

`just ansible-check openclaw` works on a fresh host. The four
NodeSource-bootstrap tasks (apt prereqs, keyrings dir, archive
key, apt_repository) carry `check_mode: false` so `--check`
actually performs the repo bootstrap before dry-running everything
downstream — produces a meaningful diff for every change the role
would make, instead of failing at `Install nodejs` with `No package
matching 'nodejs' is available`. Same convention as pbs-hosts.

The Node major-version assertion skips cleanly under `--check`
(`when: not ansible_check_mode`). The role's bootstrap already
verifies `node_24.x` is the configured repo; asserting the installed
version only makes sense after a real apply.

## Install openclaw

The role gets you to "ready for any upstream install." Pick whichever
install path [upstream](https://github.com/openclaw/openclaw) documents
at the time you're deploying — typically:

```bash
ssh claw-admin@<vm-ip>
sudo npm install -g openclaw          # global install: needs sudo (writes to /usr/lib/node_modules)
# Binary lands at /usr/bin/openclaw, executable by any user. Now switch
# to the service user for the smoke check + onboard:
sudo -u openclaw -i
openclaw --version
```

The install command needs sudo because npm-global writes to a
root-owned tree — `claw-admin` has sudo, the `openclaw` service user
doesn't. After install, every subsequent `openclaw` invocation runs
as the service user (where `~/.openclaw/` lives).

If upstream's docs change to a `curl | bash` or container path, swap
the install command accordingly — the surrounding prereqs (Node 24
on PATH, service user with linger, ufw rule) don't care which
install method you take.

## First-onboard ceremony (operator-driven, one-time)

OpenClaw's onboarding is interactive — channel pairings require QR
scans (WhatsApp, Telegram) or OAuth round-trips (Slack, Discord,
Google Chat, the model providers). None of that is automatable from
Ansible. Run it once, by hand, from the VM:

```bash
ssh claw-admin@<vm-ip>
sudo -u openclaw -i           # become the service user
openclaw onboard
```

The wizard walks through, in order:

1. **Model provider auth.** OAuth (ChatGPT/Codex) opens a browser
   link — copy it into your workstation browser, complete the flow,
   paste the resulting code back. API-key providers just take the
   key.
2. **Channel pairings.** Pick which channels you want (Telegram,
   Discord, …). Each runs its own flow:
   - Telegram: paste a bot token from @BotFather.
   - WhatsApp: scan a QR with your phone (link from terminal output).
   - Slack/Discord: OAuth, same shape as the model provider step.
   Approve any DM pairings via `openclaw pairing approve <channel> <code>`
   per upstream's security guide.
3. **Skills selection.** Pick from the bundled set or skip — you can
   add skills via [ClawHub](https://clawhub.ai) later.

### Daemonizing (optional)

Onboarding leaves the gateway running under your foreground shell.
For a persistent daemon, the cleanest option is upstream's
`openclaw onboard --install-daemon`, which writes a user-systemd
unit to `~/.config/systemd/user/openclaw-gateway.service`. The
role already enabled `loginctl enable-linger openclaw` so the unit
survives logout. Check status with:

```bash
sudo -u openclaw -i
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -f
```

If upstream changes its daemon-installer or you want something
external (a hand-rolled `/etc/systemd/system/*.service`, tmux,
supervisor, etc.), the role doesn't lock you in — none of the
prereqs assume a particular daemonization path.

Test by sending a message to any paired channel; OpenClaw should
reply.

## Operations

### Logs

If you took the `--install-daemon` path during onboard:

```bash
ssh claw-admin@<vm-ip>
sudo -u openclaw -i
journalctl --user -u openclaw-gateway -f
```

If you're running under tmux/screen or a hand-rolled system unit, log
location depends on how you wired it up.

### Upgrading

Re-run upstream's install command as the openclaw service user:

```bash
ssh claw-admin@<vm-ip>
sudo -u openclaw -i
npm update -g openclaw        # or whatever upstream's update command is now
systemctl --user restart openclaw-gateway   # if you took the --install-daemon path
```

The role itself doesn't manage the openclaw version — re-running
`just ansible openclaw` only updates prereqs (Node, ufw rule, etc.),
which is rarely the reason to upgrade.

### Stable IP via DHCP reservation

`just output openclaw` reports the MAC. Pin a DHCP reservation on the
router — channel webhooks and the macOS/iOS companion apps register
against an IP, and re-onboarding after every lease rotation is
friction.

### Backup the workspace

`~/.openclaw/` (on the VM, owned by the openclaw service user) is the
only irreplaceable state — channel auth tokens, paired allowlists,
conversation history. Snapshot before any destructive operation:

```bash
ssh claw-admin@<vm-ip>
sudo tar -czf /tmp/openclaw-state-$(date +%F).tgz -C /home/openclaw .openclaw
sudo chown claw-admin: /tmp/openclaw-state-*.tgz
exit
scp claw-admin@<vm-ip>:/tmp/openclaw-state-*.tgz ./backups/
```

Push to your usual offsite path. The gateway binary is reproducible
from `npm install -g openclaw` (or whichever install path upstream
recommends); only `~/.openclaw/` is state.

## Destroy and rebuild

> **WARNING.** Destroying this VM loses every channel pairing token.
> Re-onboarding from scratch means re-scanning WhatsApp's QR, re-bot-
> -token'ing Telegram, re-OAuth'ing Slack/Discord. Take the workspace
> backup above first if you want a clean restore.
>
> Restore path:
>
> 1. `just apply openclaw` on the rebuilt VM.
> 2. `just ansible openclaw` — gets prereqs in place.
> 3. Install openclaw per the "Install openclaw" section above.
> 4. Stop the gateway if `--install-daemon` was used:
>    `sudo -u openclaw -i systemctl --user stop openclaw-gateway`.
> 5. Restore: `sudo -u openclaw tar -xzf openclaw-state-<date>.tgz -C /home/openclaw`.
> 6. Start the gateway (re-run onboard or restart the user-systemd unit).
>
> The restored state binds to the same model-provider tokens and
> channel pairings as the old VM; verify a test message before
> declaring the recovery green.

```bash
just destroy openclaw        # only after a workspace backup is offsite
just apply openclaw
just ansible openclaw
# then install openclaw per "Install openclaw" above, then restore
# or re-run `openclaw onboard` for a fresh setup
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 4 | Matches NemoClaw's "Recommended" tier — upstream OpenClaw publishes no sizing matrix, so this borrows NemoClaw's anchor and keeps the two claw roles comparable |
| RAM | 16 GiB | Same anchor; generous for a Node 24 daemon. Drop to 4 GiB if RAM is gating and you're not running the browser tool |
| Disk | 64 GiB | Generous for workspace + skill bundles + downloads cache; cluster has spare disk so headroom is free insurance |
| Balloon | 0 | Node's V8 heap is unhappy under host pressure; sandbox spawns need predictable headroom |
| Machine | q35 | Matches the rest of the homelab |
| CPU type | x86-64-v3 | Common baseline across the cluster's NUCs — supports live migration |

Override in `vms/openclaw/terraform/main.tf`'s `module "openclaw"` call.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (opened by base template + Ansible) |
| 18789 | tcp | LAN | OpenClaw gateway HTTP + WebSocket — companion apps + webhooks connect here |

UFW inside the VM; perimeter is the LAN router. The gateway has no
HTTP auth beyond pairing — **keep this LAN-only** unless you front
it with mTLS at a reverse proxy or restrict access via Tailscale.

## Security notes

- **DM pairing policy.** Stock OpenClaw treats unknown senders on
  Telegram/WhatsApp/Signal/Discord/Slack/etc. with a pairing-code
  prompt (`dmPolicy="pairing"`). Don't relax to `dmPolicy="open"`
  without an explicit allowlist — the gateway routes inbound DMs into
  the agent's prompt, so "open" means "anyone on the channel can
  prompt-inject your assistant." See upstream's [Security guide](https://docs.openclaw.ai/gateway/security).
- **Tool sandboxing.** Default config runs tools on the host for the
  `main` session (the operator's own conversations). For group /
  shared sessions, set `agents.defaults.sandbox.mode: "non-main"`
  in `~/.openclaw/openclaw.json` (Docker is the default backend; SSH
  and OpenShell also work). Confirm `docker info` works for the
  `openclaw` user if you enable this — the role does NOT install
  Docker today.
- **Provider tokens.** Live under `~/.openclaw/` on the VM, owned by
  the openclaw user (0750). The backup tar from the Operations
  section captures these — treat the resulting `.tgz` as secret.
- **No remote exposure.** Don't proxy 18789 to the internet. Use
  Tailscale (or your existing LAN-only assumption) for off-LAN
  access; upstream documents the Tailscale flow.

## Files

- `terraform/main.tf` — provider + module call (sizing, cloud-init).
- `terraform/variables.tf` — five inputs (endpoint, token, node, user, key).
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` + `roles/openclaw/` — install prereqs (Node 24, service user, ufw); stops short of the openclaw install itself.

## Related

- Upstream: [github.com/openclaw/openclaw](https://github.com/openclaw/openclaw),
  [docs.openclaw.ai](https://docs.openclaw.ai)
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow, state.
- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser, repeatable 7-step flow.
- [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md) — API token + role.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces the Ubuntu base template.
- `vms/openbao/` — the canonical service-VM example this role mirrors.
