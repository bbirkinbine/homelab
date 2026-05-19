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
> Interfaces and behavior may change without notice. This role
> targets the alpha state; bump `nemoclaw_npm_version` in inventory
> to a pinned tag once upstream stabilizes.

## Layout

```text
vms/nemoclaw/
├── README.md                  this file
├── terraform/                 VM provisioning (clone, size, cloud-init)
├── ansible/                   role config (Docker + Node 22 + nemoclaw CLI)
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
5. **An NVIDIA API key OR a non-NVIDIA inference provider.** NemoClaw
   defaults to NVIDIA Endpoints. You'll provide the key during the
   onboard ceremony, not at deploy time — but have it ready.
   Stash at `Homelab/NemoClaw/nvidia-api-key` (or wherever your
   preferred provider's key lives).
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
just ansible nemoclaw        # install Docker + Node 22 + nemoclaw CLI
```

End state: Docker is running, Node 22 is on PATH, the `nemoclaw` CLI
is installed globally, and the `nemoclaw` service user exists with
docker-group + linger. **No sandbox has been created and no model
provider is configured** — that's the operator ceremony below.

### Previewing with `--check` first

`just ansible-check nemoclaw` works on a fresh host. The six
repo-bootstrap tasks (apt prereqs, keyrings dir, Docker key + repo,
NodeSource key + repo) carry `check_mode: false` so `--check`
actually performs the repo bootstrap before dry-running everything
downstream — produces a meaningful diff for every change the role
would make, instead of failing at `Install Docker engine` /
`Install nodejs` with `No package matching '<pkg>' is available`.
Same convention as pbs-hosts and openclaw.

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
upstream installer supports env vars:

```bash
sudo -u nemoclaw -i bash -c '
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NEMOCLAW_SANDBOX_NAME=homelab \
  NEMOCLAW_PROVIDER=routed \
  nemoclaw onboard --non-interactive
'
```

(NVIDIA API key plumbing for non-interactive mode: see upstream's
[Inference Options](https://docs.nvidia.com/nemoclaw/latest/inference/inference-options.html).)

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

The role re-installs the npm package every run when
`nemoclaw_npm_version: latest` (default). For alpha software,
**pin a version** in inventory once you've onboarded — `latest`
across upgrades will lose you sandbox state:

```yaml
# vms/nemoclaw/ansible/inventory.yml
nemoclaw_servers:
  hosts:
    nemoclaw:
      nemoclaw_npm_version: "0.1.0"   # or whatever tag you onboarded against
```

Upstream's lifecycle note: "use `nemoclaw onboard` when you need to
create or recreate the OpenShell gateway or sandbox." Don't run
`openshell self-update` or `npm update -g openshell` directly — that
path leaves NemoClaw and OpenShell version-mismatched.

### Stable IP via DHCP reservation

`just output nemoclaw` reports the MAC. Pin a DHCP reservation —
anything you register against an IP (Tailscale, future reverse
proxy, channel webhooks routed through OpenShell) will benefit.

### Backup the sandbox + state

NemoClaw stores sandbox state under `/home/nemoclaw/` (Docker
volumes, k3s state, nemoclaw config). Snapshot before any
destructive operation:

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

`/var/lib/docker` is huge (multi-GiB) — expect 5–10 minute backups.
For the alpha period, treat `nemoclaw onboard` as cheap enough to
re-run instead of restoring a backup; channel re-pairings are the
only painful step.

## Destroy and rebuild

> **WARNING.** Destroying this VM loses the sandbox, its OpenClaw
> state, channel pairings, and any conversation history. Re-onboard
> means re-OAuth-ing model providers and re-pairing channels.

```bash
just destroy nemoclaw        # only after a state backup or accepting re-onboard cost
just apply nemoclaw
just ansible nemoclaw
# then `sudo -u nemoclaw -i nemoclaw onboard`
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
| 4000 | tcp | — | Model Router (LiteLLM proxy) — **disabled by default**; flip `nemoclaw_ufw_allow_router: true` in inventory if you want external access. Sandbox reaches it internally regardless. |

No default inbound port for NemoClaw itself. The OpenShell gateway
listens internally; channel webhooks route through OpenShell's
channel manager rather than a direct external listener. If you later
front the sandbox via Tailscale or a reverse proxy, open the
specific ports those need.

## Install path (trade-off)

Upstream documents `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
as the install path. The script clones the NemoClaw repo at a tagged
ref, installs Node via nvm, installs the `nemoclaw` npm package, and
runs `nemoclaw onboard`.

This role replaces the curl-piped installer with:

1. **Docker** from Docker Inc.'s signed apt repo.
2. **Node 22** from NodeSource's signed apt repo.
3. **`nemoclaw`** via `npm install -g`.

Trade-offs:

- **Win.** No piped-bash from a remote URL in our IaC. Both apt
  repos are signed and pinned. Node 22 is the documented minimum;
  the upstream installer uses nvm which leaves Node out of system
  PATH and complicates running the CLI as a non-login service user.
- **Loss.** If a future NemoClaw release adds setup steps in the
  installer that aren't covered by `npm install` (k3s tweaks,
  systemd unit drops, etc.), this role will silently miss them.
  Mitigation: re-read the upstream installer
  ([NVIDIA/NemoClaw/install.sh](https://github.com/NVIDIA/NemoClaw/blob/main/install.sh))
  on each `nemoclaw_npm_version` bump and reflect new steps here.
- **Escape hatch.** If a release ships the kind of setup-script
  changes that defeat the manual replication, switch to the
  upstream installer in this role's tasks:

  ```yaml
  - name: Run upstream NemoClaw installer (fallback path)
    ansible.builtin.shell:
      cmd: >-
        curl -fsSL https://www.nvidia.com/nemoclaw.sh |
        NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash
      creates: "{{ nemoclaw_service_home }}/.nvm/versions/node"
    become_user: "{{ nemoclaw_service_user }}"
  ```

  ... and remove the NodeSource + npm-install tasks. We have not
  done this preemptively because the apt-driven path is materially
  cleaner today.

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
- `ansible/site.yml` + `roles/nemoclaw/` — Docker + Node 22 + nemoclaw CLI + service user.

## Related

- Upstream: [github.com/NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw),
  [docs.nvidia.com/nemoclaw](https://docs.nvidia.com/nemoclaw/latest/),
  [github.com/NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
- [`vms/openclaw/`](../openclaw/) — the unsandboxed counterpart.
- [`docs/opentofu-setup.md`](../../docs/opentofu-setup.md) — workstation setup, hydrate flow.
- [`docs/deploying-vms.md`](../../docs/deploying-vms.md) — role-class chooser, repeatable flow.
- `modules/proxmox-vm/` — the shared module this role calls.
- `packer/ubuntu-24-04-base/` — produces the Ubuntu base template.
