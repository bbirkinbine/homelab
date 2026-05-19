# vms/nemoclaw

[NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Ubuntu 24.04 —
[OpenClaw](https://github.com/openclaw/openclaw) running inside an
NVIDIA OpenShell sandbox with declarative network policy, capability
drops, and routed inference. The security-focused counterpart to
[`vms/openclaw/`](../openclaw/) — same upstream agent, hardened stack
underneath.

Provisioned with OpenTofu, configured with Ansible. Same role-class
as `vms/openclaw/` (cluster-mobile service VM) but sized heavier
because the runtime stack adds Docker + k3s + OpenShell on top of
OpenClaw.

> **Alpha software.** NemoClaw is in early preview per
> [NVIDIA's own README](https://github.com/NVIDIA/NemoClaw/blob/main/README.md).
> Interfaces and install paths may change without notice. The role
> deliberately stops at prereqs (Docker + Node + service user) and
> leaves the `nemoclaw` install itself to the operator — see "Install
> nemoclaw" below — so upstream churn doesn't keep breaking this
> repo's automation.

## Layout

```text
vms/nemoclaw/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, cloud-init)
├── ansible/                   role config (Docker + Node 22 + service user)
└── cloud-init/                first-boot identity (hostname, user, SSH key)
```

## Why NemoClaw alongside OpenClaw?

`vms/openclaw/` runs OpenClaw directly on the host — fast, lean, no
sandbox. NemoClaw is the same upstream agent but wrapped in NVIDIA's
[OpenShell](https://github.com/NVIDIA/OpenShell) runtime:

- **Sandboxed.** OpenClaw runs inside a container with Landlock +
  seccomp + netns isolation. The agent's tool subprocesses can't
  see the host filesystem or network outside the policy.
- **Declarative network policy.** Baseline allows a defined set of
  destinations; new outbound requests get surfaced for operator
  approval in a TUI. "Secure by default" here means "predefined
  access + explicit review."
- **Inference routing.** Optional LLM router on the host (LiteLLM
  proxy, :4000) picks the cheapest model meeting an accuracy
  threshold per request. Sandbox sees a single virtual endpoint
  (`https://inference.local/v1`); the router does the dispatch.
- **OpenShell-managed channels.** Channel webhooks route through
  OpenShell's channel manager rather than directly to OpenClaw's
  :18789. No port to expose externally by default.

Trade-offs:

| | `vms/openclaw/` | `vms/nemoclaw/` |
| --- | --- | --- |
| Runtime layer | Node + openclaw bin | Docker + k3s + OpenShell + sandbox(OpenClaw) |
| Sizing | 4 vCPU / 16 GiB / 64 GiB | 4 vCPU / 16 GiB / 64 GiB |
| Tool sandbox | Operator-opt-in (`agents.defaults.sandbox`) | Default |
| Inbound port | 18789 (gateway HTTP) | None by default |
| Inference | Any OpenClaw-supported provider | NVIDIA Endpoints by default + optional routed pool |
| Onboard time | One-step (`openclaw onboard`) | One-step (`nemoclaw onboard`), creates sandbox + onboards OpenClaw |
| Maturity | OpenClaw is stable | NemoClaw is alpha |

The two roles are not mutually exclusive — keep both for the
"compare deployment models" lab pattern.

## Prerequisites

1. **Workstation tooling.** `brew install opentofu just keepassxc ansible`.
   First-time setup in [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md).
2. **Packer base template.** Ubuntu base must exist on the target node
   (VMIDs `9100`/`9101`/`9102` per [ADR-0006](../../docs/decisions/0006-packer-templates-per-node.md)).
3. **`tofu@pve` API token.** See [`docs/proxmox-tofu-permissions.md`](../../docs/proxmox-tofu-permissions.md).
   Stash in KeePassXC at `Homelab/Tofu/proxmox-api-token`.
4. **SSH access to the node + key loaded into `ssh-agent`.**
   `ssh-copy-id root@pve12t` (or whichever node `proxmox_node` points
   at), then `ssh-add ~/.ssh/id_ed25519` once per shell session. The
   `bpg/proxmox` provider uploads cloud-init snippets over SSH (not
   the HTTP API) and shells out non-interactively, so the key must
   already be in the agent before `tofu apply`. Preflight verifies
   both. See [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md)
   section **(d) Load the private key into `ssh-agent`** for the
   macOS Keychain auto-load pattern that survives reboot. Snippets
   storage must also be enabled on `local` (preflight reports the
   cure command if missing).
5. **An `NVIDIA_API_KEY` OR a non-NVIDIA inference provider's API key.**
   NemoClaw defaults to NVIDIA Endpoints. There is **no separate
   "NemoClaw" API key** — upstream consumes the same `NVIDIA_API_KEY`
   you'd use against any build.nvidia.com-hosted model. Generate (or
   reuse) one at [build.nvidia.com](https://build.nvidia.com) under
   your NVIDIA account; one key works across all NVIDIA-hosted models
   in the catalog. You'll paste it into the `nemoclaw onboard` wizard
   interactively — nothing in this repo's automation reads it, so
   have it handy at deploy time but stash it wherever you keep API
   keys. If you'd rather route through Anthropic / OpenAI / a local
   Ollama / the LiteLLM routed pool, swap accordingly during onboard
   and use that provider's key instead.
6. **Spare 16 GiB of RAM on the target node.** This is upstream's
   "Recommended" tier and our default. 8 GiB is the documented
   minimum; drop the module's `memory_mb` to 8192 in
   `terraform/main.tf` if RAM is the gating constraint.

## Deploy

From repo root:

```bash
just ansible-deps nemoclaw   # one-time per workstation
just hydrate nemoclaw        # render terraform.tfvars from KeePassXC
just plan nemoclaw           # review the plan
just apply nemoclaw          # create the VM
just inventory nemoclaw      # write ansible/inventory.yml from tofu output
just ansible-check nemoclaw  # OPTIONAL: preview the role's diff (see "Previewing with --check first" below)
just ansible nemoclaw        # install prereqs: Docker, Node 22, service user
```

End state: Docker is running, Node 22 is on PATH, the `nemoclaw`
service user exists with bash + docker-group + linger. **The
nemoclaw binary is NOT installed yet** — the role deliberately stops
at prereqs because upstream's install path moves around (curl|bash
with nvm, npm-global, containers). The operator runs the install +
onboard ceremonies below.

### Previewing with `--check` first

`just ansible-check nemoclaw` works on a fresh host. The six
repo-bootstrap tasks (apt prereqs, keyrings dir, Docker key + repo,
NodeSource key + repo) carry `check_mode: false` so `--check`
actually performs the repo bootstrap before dry-running everything
downstream — produces a meaningful diff for every change the role
would make, instead of failing at `Install Docker engine` /
`Install nodejs` with `No package matching '<pkg>' is available`.
Same convention as pbs-hosts and openclaw.

Post-install validations skip cleanly under `--check`: the Node
major-version assertion and the `docker info` smoke check are gated
with `when: not ansible_check_mode`. Nothing live to validate on a
dry-run; both run normally on a real apply.

## Install nemoclaw

Use upstream's recommended `curl | bash` installer, running as the
nemoclaw service user. **No sudo is needed** — our role already
installed Node 22 (via NodeSource) and Docker (Docker Inc.'s apt
repo), so the installer's "install Node via nvm" and "Docker must
be running" prereqs are already met. Everything else — npm-global
under the user's prefix, the nemoclaw install itself, the onboard
wizard — runs in the service user's $HOME.

> Upstream's install reference: [docs.nvidia.com/nemoclaw](https://docs.nvidia.com/nemoclaw/latest/get-started/prerequisites.html).
> Check the page before deploying — NemoClaw is alpha and the
> install URL or non-interactive env vars may have shifted since
> this README was written.

```bash
ssh nemo-admin@<vm-ip>
sudo -u nemoclaw -i           # become the service user
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
nemoclaw --version            # smoke check
```

For non-interactive / repeatable installs, upstream honors:

```bash
sudo -u nemoclaw -i bash -c '
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
    bash
'
```

## First-onboard ceremony (operator-driven, one-time)

NemoClaw's onboard is interactive: it asks which sandbox name to
create, which inference provider to use, whether to enable the
optional Model Router, and (if you opt in) walks OAuth/QR flows for
each channel. None of that is automatable from Ansible. Run it once
by hand:

```bash
ssh nemo-admin@<vm-ip>
sudo -u nemoclaw -i           # switch to the service user
nemoclaw onboard
```

The wizard:

1. **License + third-party software notice.** Accept to continue.
2. **Sandbox name.** Choose one (the CLI later targets sandboxes by
   this name, e.g. `nemoclaw my-assistant connect`).
3. **Inference provider.** NVIDIA Endpoints (paste API key),
   Anthropic, OpenAI, a local Ollama, or the routed pool. The
   routed pool option starts the LiteLLM proxy on host :4000.
4. **Network policy preset.** Baseline policy + approval flow for
   new outbound destinations.
5. **Channels (optional).** Walks through Telegram/Discord/Slack/…
   pairings via the OpenShell channel manager.

When complete, a summary prints:

```text
Sandbox      my-assistant (Landlock + seccomp + netns)
Model        nvidia/nemotron-3-super-120b-a12b (NVIDIA Endpoints)
```

For a fully non-interactive onboard (CI / repeatable rebuilds), the
upstream installer supports env vars. For the NVIDIA-backed default,
include `NVIDIA_API_KEY` so the wizard doesn't have to prompt:

```bash
sudo -u nemoclaw -i bash -c '
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NEMOCLAW_SANDBOX_NAME=homelab \
  NVIDIA_API_KEY=<your-build.nvidia.com-key> \
  nemoclaw onboard --non-interactive
'
```

Or piped through the installer in one shot (the upstream-recommended
shape for fully non-interactive deploys):

```bash
sudo -u nemoclaw -i bash -c '
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NVIDIA_API_KEY=<your-build.nvidia.com-key> \
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
'
```

For a non-NVIDIA provider, swap `NVIDIA_API_KEY=` for whichever env
var that provider's section of upstream's [Inference Options](https://docs.nvidia.com/nemoclaw/latest/inference/inference-options.html)
documents (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.). For the
LiteLLM routed pool, add `NEMOCLAW_PROVIDER=routed` and configure
the pool's per-provider keys post-onboard.

## Chat with the agent

After onboard, connect to the sandbox:

```bash
sudo -u nemoclaw -i
nemoclaw <sandbox-name> connect
# inside the sandbox shell:
openclaw tui
```

Or send a one-shot prompt:

```bash
nemoclaw <sandbox-name> connect <<'EOF'
openclaw agent --agent main --local -m "hello" --session-id test
EOF
```

## Operations

### Logs

Three layers, each with its own log path:

```bash
# Host-side Docker / k3s
journalctl -u docker -u containerd -u k3s -f

# NemoClaw + OpenShell gateway logs (sandbox-scoped)
sudo -u nemoclaw nemoclaw <sandbox-name> logs --follow

# OpenClaw inside the sandbox (re-attach to the sandbox)
sudo -u nemoclaw nemoclaw <sandbox-name> connect
# then in the sandbox shell:
journalctl --user -u openclaw-* -f
```

### Sandbox status

```bash
sudo -u nemoclaw nemoclaw <sandbox-name> status
```

### Upgrading

Upstream **does not document** a formal upgrade command (no
`nemoclaw update`, no published version-pinning flag) as of this
README's writing — NemoClaw is alpha and the lifecycle story is
still settling. The least-friction path that matches what upstream
*does* say:

```bash
ssh nemo-admin@<vm-ip>
sudo -u nemoclaw -i
# Re-run the installer in place — picks up whatever upstream's
# latest is at this URL.
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# After that, re-onboard if the gateway/sandbox needs to be
# recreated (upstream's prescribed lifecycle path):
nemoclaw onboard
```

Upstream's explicit warnings, captured verbatim from the docs:

- **Use `nemoclaw onboard` to manage OpenShell lifecycle.** When the
  gateway or sandbox needs to be created or recreated, that's the
  path — not direct npm/openshell commands.
- **Avoid `openshell self-update`, `npm update -g openshell`,
  `openshell gateway start --recreate`, `openshell sandbox create`
  directly.** Those paths leave NemoClaw and OpenShell version-
  mismatched.
- **No `npm update -g nemoclaw` either** — not endorsed by upstream.
  Re-run the installer instead so the install path stays consistent
  with whatever shape upstream is on.

Sandbox state across upgrades is not documented. Plan for
`nemoclaw onboard` being the path back to a healthy stack if an
upgrade goes sideways. Take a `nemoclaw <sandbox> snapshot create`
before the upgrade if the agent's workspace state is worth saving —
see "Backup + restore" below.

Re-running `just ansible nemoclaw` only updates prereqs (Docker
engine, Node major, ufw); it doesn't touch the nemoclaw install.

Check [docs.nvidia.com/nemoclaw](https://docs.nvidia.com/nemoclaw/latest/)
periodically — once upstream publishes a formal update command,
this section should be revisited.

### Stable IP via DHCP reservation

`just output nemoclaw` reports the MAC. Pin a DHCP reservation —
anything you register against an IP (Tailscale, future reverse
proxy, channel webhooks routed through OpenShell) will benefit.

### Backup + restore

NemoClaw stores irreplaceable state in several places — sandbox
agent state inside the OpenShell sandbox, channel pairings + API
keys in the OpenShell gateway config, the sandbox image cache
itself under `/var/lib/docker`. Three layered options, pick what
fits the failure you're insuring against:

**1. `nemoclaw <sandbox> snapshot create` (recommended for everyday
rollback).** Upstream's purpose-built per-sandbox snapshot tool.
Captures "all workspace state directories defined in the agent
manifest" (for Hermes agents that includes `SOUL.md` and
`.hermes/state.db`). Archives land under
`~/.nemoclaw/rebuild-backups/<sandbox-name>/`. Round-trip:

```bash
ssh nemo-admin@<vm-ip>
sudo -u nemoclaw -i

nemoclaw <sandbox> snapshot create                     # snapshot the live sandbox
nemoclaw <sandbox> snapshot create --name before-upgrade   # tag with a label
nemoclaw <sandbox> snapshot list                       # what's available
nemoclaw <sandbox> snapshot restore                    # restore the latest
nemoclaw <sandbox> snapshot restore before-upgrade     # restore by label
nemoclaw <sandbox> snapshot restore v3                 # restore by version
nemoclaw <sandbox> snapshot restore 2026-04-14T        # restore by timestamp prefix
```

See [docs.nvidia.com/nemoclaw/latest/manage-sandboxes/backup-restore.html](https://docs.nvidia.com/nemoclaw/latest/manage-sandboxes/backup-restore.html)
for the upstream reference.

Snapshots do NOT capture the OpenShell gateway config, channel
pairings + API keys held by the gateway, the sandbox image cache,
or anything outside `~/.nemoclaw/`. For those, layer in option 2
or 3.

**2. Whole-VM PBS snapshot (recommended for catastrophic recovery).**
The lab's [`pbs-hosts/`](../../pbs-hosts/) Proxmox Backup Server is
the right tool for "the whole stack is corrupted in a way I can't
diagnose." A PBS snapshot captures everything — OS, Docker engine,
`/var/lib/docker` (sandbox images + k3s state), the `nemoclaw` CLI
under `~/.local`, the OpenShell gateway config under
`~/.local/state/nemoclaw/`, the gateway-held credentials, and any
nemoclaw snapshots from option 1. Heavier than `snapshot create`
and slower to restore for a state-only rollback, but the only
option that catches the gateway/image/credential layers.
Configure via Datacenter → Backup in the PVE UI; the role itself
doesn't manage backup jobs.

**3. Manual tar of `/var/lib/docker` + `/home/nemoclaw/` (escape
hatch).** If `snapshot create` is broken or PBS isn't configured,
grab everything directly. Heavyweight — `/var/lib/docker` is
multi-GB on a host with sandbox images:

```bash
ssh nemo-admin@<vm-ip>
# Stop the stack first so Docker volumes are quiesced
sudo -u nemoclaw -i nemoclaw <sandbox-name> stop
sudo systemctl stop docker
sudo tar -czf /tmp/nemoclaw-state-$(date +%F).tgz \
  -C / var/lib/docker home/nemoclaw
sudo systemctl start docker
sudo -u nemoclaw -i nemoclaw <sandbox-name> start
sudo chown nemo-admin: /tmp/nemoclaw-state-*.tgz
exit
scp nemo-admin@<vm-ip>:/tmp/nemoclaw-state-*.tgz ./backups/
```

Expect 5–10 minute backups. For the alpha period, when the sandbox
build is fast enough that re-onboarding is cheap, treat that as a
viable alternative to restoring this archive — the painful step is
re-pairing channels.

## Destroy and rebuild

> **WARNING.** Destroying this VM loses the sandbox, its OpenClaw
> state, channel pairings, and any conversation history. Re-onboard
> means re-OAuth-ing model providers and re-pairing channels. Take
> a backup first — see "Backup + restore" above for the three
> layered options.
>
> **Restore from a `nemoclaw snapshot` archive (sandbox state only):**
> The archive lives in `~/.nemoclaw/rebuild-backups/` on the source
> host. After rebuilding the VM (steps 1-4 below) and re-running
> `nemoclaw onboard` to a sandbox of the same name, copy the
> archive directory into place on the rebuilt host and
> `nemoclaw <sandbox> snapshot restore`. Sandbox workspace state
> comes back; channel pairings + API keys do not (those live in
> the OpenShell gateway and aren't covered by `snapshot create`).
>
> **Restore from a PBS snapshot (whole-stack):** restore the VM in
> the PVE UI (Datacenter → `<node>` → `<VMID>` → Backup → Restore).
> The whole stack comes back including Docker images, the gateway
> config, channel pairings, and any sandbox snapshots — skip steps
> 2-5 below.

Standard rebuild flow (no restore — re-onboard from scratch):

```bash
just destroy nemoclaw        # only after a state backup or accepting re-onboard cost
just apply nemoclaw
just ansible nemoclaw
# then install nemoclaw per "Install nemoclaw" above, then
# `sudo -u nemoclaw -i nemoclaw onboard`
```

## Sizing

| Resource | Value | Why |
| --- | --- | --- |
| vCPU | 4 | Docker + k3s + OpenShell gateway + sandbox container share the box |
| RAM | 16 GiB | Upstream "Recommended"; 8 GiB is the minimum but risks OOM during image push (per upstream OOM warning) |
| Disk | 64 GiB | Upstream wants 40 GiB free; 64 GiB total leaves ~40 GiB free after Ubuntu base + Docker + k3s + sandbox image cache settle in |
| Balloon | 0 | Docker + k3s + Node behave badly under host memory pressure |
| Machine | q35 | Matches the rest of the homelab |
| CPU type | x86-64-v3 | Cluster-mobile baseline |

Override in `vms/nemoclaw/terraform/main.tf`'s `module "nemoclaw"` call.

## Ports

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | tcp | LAN | SSH (opened by base template) |
| 8080 | tcp | Docker bridge (`172.16.0.0/12`) | OpenShell gateway — opened by the role; mandatory for sandbox containers to reach the gateway. Not LAN-exposed. |
| 4000 | tcp | — | Model Router (LiteLLM proxy) — **disabled by default**; flip `nemoclaw_ufw_allow_router: true` in inventory if you want LAN access. Sandbox reaches it internally regardless. |

No LAN-exposed port for NemoClaw itself. The OpenShell gateway is
reachable only from the Docker bridge (where the sandbox containers
live); channel webhooks route through OpenShell's channel manager
rather than a direct external listener. If you later front the
sandbox via Tailscale or a reverse proxy, open the specific ports
those need.

## Install path (trade-off)

Upstream documents `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
as the install path. The script clones the NemoClaw repo at a tagged
ref, installs Node via nvm, installs the `nemoclaw` npm package, and
runs `nemoclaw onboard`.

This role does NOT do the install itself. It gets the host to a
state where any of upstream's documented install paths (curl|bash
with nvm, npm-global against the role's pre-installed Node 22, or a
future container variant) works without prep:

1. **Docker** from Docker Inc.'s signed apt repo, enabled at boot.
2. **Node 22** from NodeSource's signed apt repo (covers the
   `npm install -g` path; harmless if you take the nvm path —
   upstream's script just installs alongside).
3. **`nemoclaw` service user** with bash, docker group, linger.

Trade-offs of the prereq-only shape:

- **Win.** Survives upstream install-path churn — NemoClaw is alpha
  and the installer has changed multiple times during preview. The
  role doesn't need a release matching each upstream pivot.
- **Loss.** Operator runs one extra command after `just ansible
  nemoclaw` — `sudo -u nemoclaw -i nemoclaw onboard` plus whatever
  installer-invocation is current upstream. That's the deal.
- **Future option.** If upstream ever publishes a stable, signed
  apt/deb repo for NemoClaw, we can fold a `apt: name=nemoclaw` task
  into the role — same pattern as Docker/Node here. Until then,
  prereqs only.

## Security notes

- **Provider tokens.** Live under `/home/nemoclaw/` (typically
  `~/.nemoclaw/` and Docker secrets). The backup tar above captures
  these — treat as secret.
- **Sandbox escape.** OpenShell's Landlock + seccomp + netns is
  defense-in-depth, not a guarantee. Treat the sandbox as semi-
  trusted: don't grant the network policy more egress than the
  sandbox actually needs.
- **Network policy approvals.** Default policy + approval flow means
  any new outbound destination from the sandbox surfaces in a TUI
  for explicit allow/deny. Don't reflexively approve — the prompt is
  the security control.
- **NVIDIA Endpoints API key.** If you go with the default provider,
  the API key is the bill. Track usage at nvidia.com/build.
- **LAN-only.** Same posture as `vms/openclaw/`: no internet
  exposure without Tailscale or an mTLS reverse proxy.
- **Docker group membership.** The `nemoclaw` user is in `docker`,
  which is effectively root on this VM. Acceptable for a single-
  purpose host; do not extend docker-group membership to operator
  accounts on multi-purpose VMs.

## Files

- `terraform/main.tf` — provider + module call (sizing, cloud-init).
- `terraform/variables.tf` — five inputs (endpoint, token, node, user, key).
- `terraform/terraform.tfvars.tpl` — committed, kp:// placeholders.
- `terraform/terraform.tfvars.example` — committed, manual-fill alternative.
- `cloud-init/user-data.yaml.tftpl` — identity only.
- `ansible/site.yml` + `roles/nemoclaw/` — install prereqs (Docker, Node 22, service user); stops short of the nemoclaw install itself.

## Related

- Upstream: [github.com/NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw),
  [docs.nvidia.com/nemoclaw](https://docs.nvidia.com/nemoclaw/latest/),
  [github.com/NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
- [`vms/openclaw/`](../openclaw/) — the unsandboxed counterpart.
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow.
- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser, repeatable flow.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces the Ubuntu base template.
