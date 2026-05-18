# CLAUDE.md — homelab repo

> **Purpose.** Persistent project context for Claude Code (and other AI tools) working in this repository. Read this before suggesting changes. `README.md` is for humans landing on the GitHub page; this file is for the agent that opens the repo and starts working.

---

## What this repo is

Infrastructure-as-code for a small Proxmox VE homelab built around two universal VM templates (Ubuntu 24.04, Windows 11 Pro x64) that downstream per-role VMs clone from. See `README.md` for the human-facing overview and `docs/`, `packer/*/README.md`, `vms/*/README.md` for component runbooks.

The repo is **public** on GitHub. Treat every change as something a stranger will read: no embedded credentials, no cluster topology that exposes attack surface, prose comments where a maintainer would otherwise have to reverse-engineer intent.

---

## Active context (as of 2026-05-11)

A few states that won't be obvious from the code alone:

**Both base templates are committed and shipping.** Treat `packer/ubuntu-24-04-base/` and `packer/windows-11-base/` as load-bearing — both build reproducibly and have been validated end-to-end. The Windows pipeline shipped in commit 5135652 (proxmox-iso + virtualbox-iso). When working on one base, don't modify the other for "while I'm here" cleanups; if a fix genuinely belongs across both, surface it and ask first.

**Cluster transition in progress.** `README.md` currently describes the three NUCs as independent (per-node tokens, per-node template builds). The lab is moving to a 3-node Proxmox cluster (corosync) with NFS-shared storage from the Asustor AS6706T. Authoritative design lives in the project's private design vault — ask the maintainer if you need access. Until that transition lands in a commit:

- **Proxmox hostnames stay `pveXX` (`pve12t`, `pve13m`, `pve13t`).** Physical-chassis labels in the design vault (`nuc12 / nuc13-mini / nuc13-tall`) are NOT Proxmox node names — don't rename one to the other.
- **`cpu_type = "x86-64-v3"`** is the right module default (set in `modules/proxmox-vm/variables.tf`) for cluster-mobile VMs; it's the common baseline across Alder/Raptor Lake-P/H. Use `host` only on hardware-pinned VMs (eGPU on `pve12t` for the LLM role, USB-HSM passthrough for the Root CA role).
- **NFS shared storage (`nas-vms`) is registered cluster-wide** (per ADR-0004). Cluster-mobile roles may opt into it via the role's `disk_storage` tfvar instead of `local-lvm`. `amp-game` deliberately stays on `local-lvm` (NVMe) despite the new role shape — game-server I/O latency outweighs cluster-mobility for that workload (explicit call during the 2026-05-14 port).
- **Storage exceptions that stay node-pinned** even after the cluster lands: `nuc12-fast` (LVM-thin on a dedicated 1 TB SATA SSD in `pve12t`'s 2.5" bay, VG `nuc12fast_vg`, for the LLM models cache — physically separate from the NVMe-backed `pve` VG so the NVMe stays full-size as `local-lvm`) and the per-node ISO library. The Root CA VM is still pve12t-pinned but for the HSM USB-passthrough reason, not for a host-side encrypted Directory pool — Root CA encryption was moved inside the guest (2026-05-11). See `vms/rootca/README.md`. If `pve12t` is ever rebuilt with a single-NVMe layout (no SATA), `nuc12-fast` would have to come out of the `pve` VG via `lvreduce` — see `docs/proxmox-install.md` § 2 for the fallback procedure.
- **ZFS is off the table** for this lab — ext4-on-LVM on the hosts, btrfs on the NAS, LUKS-on-ext4 for the Root CA partition.

**OpenTofu + Ansible migration underway.** The first port landed at `vms/openbao/` (OpenTofu provisioning + Ansible config + identity-only cloud-init, with the legacy shell + HSM-passthrough preserved at `vms/openbao/legacy/`). The shared module is `modules/proxmox-vm/`; cross-cutting tooling lives at `scripts/` + `Justfile`; the workstation flow is in `docs/opentofu-setup.md`. New roles should copy that shape rather than authoring fresh `deploy.sh` scripts. Existing shell scripts in other `vms/*/` may stay for now — don't rewrite them speculatively without asking.

**OpenBao seal model changed (2026-05-10).** OpenBao now uses Shamir (5-of-3 manual unseal). The PKCS#11 HSM that was originally going to back the OpenBao seal was re-roled to the offline Root CA position instead — see [`vms/rootca/README.md`](vms/rootca/README.md) for the Root CA's HSM integration, and the project's private design vault for the seal-rationale + repurposing context. Don't restore the HSM-via-PKCS#11 seal path on this VM; the mechanism intersection between OpenBao's seal and the SmartCard-HSM is empty.

---

## Build-host split for the Windows Packer config

This is the most surprising operational detail in the repo and worth internalizing.

`packer/windows-11-base/` defines two source blocks (`proxmox-iso` and `virtualbox-iso`) sharing one provisioner pipeline. They run from **different machines**:

- **`proxmox-iso` runs from the Mac (M2 Max MacBook Pro).** The build host only orchestrates the Proxmox API; the Windows install runs on the NUC itself. No local hypervisor needed. macOS is fine.
- **`virtualbox-iso` runs from the T480 Ubuntu boot.** VirtualBox 7.0+ executes the install on the build host and produces a VMDK + OVF + NVRAM under `output-vbox/`, which converts to qcow2 via `qemu-img convert -f vmdk -O qcow2`. This builder needs Linux + VirtualBox kernel modules; macOS is rejected up front by `build-vbox.sh`. (The earlier qemu second-target was abandoned 2026-05-08: qemu+OVMF on this T480 couldn't reliably hit Microsoft bootmgr's "Press any key to boot from CD or DVD…" prompt via VNC keystroke delivery; switching to VBox sidesteps that boot path entirely.)

What this means for suggestions:

- A single invocation runs ONE source. There are two separate wrapper scripts: `build-pve.sh` for proxmox-iso and `build-vbox.sh` for virtualbox-iso. They are sibling scripts, not a single dispatcher with branching — the host-environment requirements diverge sharply (Proxmox API access vs. local VBox >= 7.0).
- Don't recommend merging the two wrappers into one `build.sh` with a BUILDER variable. The earlier prototype that did this was ~50% branching code; splitting the wrappers eliminated the branching and let each script validate its own preconditions cleanly up front.
- The `.env.<target>` files live on the host that builds that target. `.env.pve12` / `.env.pve13` go on the Mac (copied from `.env.pve.example`); `.env.t480-vbox` goes on the T480 (copied from `.env.vbox.example`). All `.env.*` are gitignored except the two `.example` files (`!.env.*.example` whitelist in `.gitignore`).

The Ubuntu base has only a `proxmox-iso` source, so it builds from the Mac with no exception.

---

## Secrets and public-repo hygiene

This is a public GitHub repo. Anything that lands in a commit can be scraped within minutes.

**Never commit:**

- `.env.*` files (gitignored — verify before staging anything new).
- Proxmox API tokens (`packer@pve!builder` UUIDs).
- SSH private keys.
- VM hostnames or IPs that aren't already in `README.md`'s hardware table.
- Cleartext build passwords *beyond* the intentional `packer-build-only-Win11!` in `http/Autounattend.xml`. That one is deliberate and rotated by sysprep at the end of the build — don't replace it with a "real" secret.

**Commit messages count as published surface.** Everything in the list above applies to the commit *message body*, not just file content — `git log`, GitHub's PR/commit views, and search-engine indexers expose commit messages exactly like they expose files. When summarizing a change, refer to "the lab's LAN subnet" or "the cluster's three nodes" instead of pasting the actual values. Even a "scrub" commit that removes sensitive content from files will leak that content forever if the commit message names it.

**Secrets flow in from the operator's credential store at run time, never embedded in code.** The current shape uses a local password manager (resolved by [`scripts/hydrate.sh`](scripts/hydrate.sh) for OpenTofu, and by `.env.<target>` reads for Packer). When suggesting credential patterns for IaC:

- Default to "read from `.env.<target>` at invocation time" or "fetch from the local password manager at run time", not "embed in the `.tf` / `.pkr.hcl`".
- Don't propose swapping in 1Password CLI, Vault, or SOPS unless the user asks — those are alternatives, not the current shape.

If a secret has to flow through HCL, it goes through `variable {}` with `sensitive = true` and is set via `PKR_VAR_*` env vars at build time. The existing `build-pve.sh` / `build-vbox.sh` wrappers are canonical examples.

---

## Validation gates before claiming done

"I'm done" should mean the code actually parses and validates. As a habit:

```bash
# Packer
packer init .
packer fmt -check .       # fail if formatting drifts
packer validate .         # fail if HCL has errors

# Shell
bash -n provision/*.sh    # parse-check every script
shellcheck provision/*.sh # if installed

# PowerShell (best-effort from Linux/macOS)
pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw ./provision/X.ps1)) | Out-Null"
```

The Windows `Autounattend.xml` is brittle — typos hang the install with no error message. When editing it, run `xmllint --noout http/Autounattend.xml` before kicking off a 60-minute build cycle.

Don't claim a build is "ready" without at least:

1. A clean `packer validate` for the affected source(s).
2. A clean `bash -n` on every shell script touched.
3. An updated README if the change affects how the build runs.

---

## Style preference for this repo

Brian prefers substantive comments over terse ones, especially where *why* is non-obvious. Autounattend.xml is famously inscrutable, and the PowerShell provisioners touch enough Windows internals (sysprep, group policy, Defender, OneDrive removal) that a maintainer six months later will need the rationale, not just the *what*.

Concretely:

- One-line summary at the top of every `.ps1` / `.sh` provisioner saying what it does.
- Inline comment at any registry write, group-policy nudge, or service disablement explaining the stock behavior being overridden.
- HCL gets `//` comments on non-obvious lines (why `bios = "ovmf"`, why `cpu_type = "host"`, why two source blocks instead of one).
- Match the depth of `packer/ubuntu-24-04-base/README.md` and the existing `packer/windows-11-base/README.md` — full quick-start, validation, gotchas, related docs. Don't write 30-line stubs.

Avoid emojis in repo files. Avoid the words *genuinely*, *straightforward*, *actually* in prose. Keep tone direct and technical.

---

## Prose hygiene for public-facing files

This repo is public on GitHub. READMEs and `docs/` are read by strangers who clone the repo with no context about when things shipped — so the prose should be timeless.

**Don't time-anchor project state in user-facing prose:**

- No "Role applied 2026-05-13" / "first run pending" / "What changed (2026-05-10)" callouts in README bodies.
- No `## Status` sections that just record when something was implemented — the existence of working code is evidence enough.
- No "currently ships X.Y.z" — use "ships X.x" or omit.

**Time-anchored content belongs in:**

- `CLAUDE.md` "Active context (as of X)" sections — explicitly maintainer-facing and snapshot-marked.
- `SCAFFOLD-NOTES.md` files alongside roles.
- ADRs (`docs/decisions/`) — the date IS the artifact.
- Commit messages — `git log` is the right place for "what changed when".

**Exceptions worth keeping:**

- ADR index dates in `docs/decisions/README.md`.
- Sample-output snapshots tagged with a build date (e.g. `packer/ubuntu-24-04-base/README.md` "Reference output from a clean build (YYYY-MM-DD)") — functional anchor for "is this still current?".

If a violation recurs across several commits, a pre-commit hook scanning README files for date strings + specific patterns ("Role applied", "first run pending", "What changed (") is the next step. Don't build it speculatively.

---

## Where component-level context lives

When a task touches one of these areas, read the local doc first before suggesting structural changes — they're authoritative for their component.

- **Scratch build order (master index):** `docs/0-scratch-build-order.md` — phased walkthrough for standing up the cluster from bare metal; points at every other doc in correct order. Read first if rebuilding the whole lab.
- **Deploying VMs (start here for a VM, not a rebuild):** `docs/deploying-vms.md` — role-class chooser, repeatable 7-step flow, from-scratch checklist for new roles
- **Asustor NAS setup (NFS prereqs):** `docs/asustor-nas-setup.md` — NFS server enablement, shared folder creation, export ACLs (squash/sync/subnet); must land before the `pve-host` role's `nfs.yml` task runs
- **Proxmox bare-metal install (layer 0a):** `docs/proxmox-install.md` — USB media, BIOS prereqs, installer click-through, post-install carve-outs (`nuc12-fast` LVM-thin), TB cabling; precedes the `pve-host` Ansible role
- **PVE host baseline (layer 0b, Ansible):** `pve-hosts/README.md` — runs against a freshly-installed PVE 9.x host; spec lives in `pve-hosts/CLAUDE.md`
- **Cluster bring-up (layer 0c, manual + quorum-aware):** `docs/cluster-bring-up.md` — `pvecm create` + `pvecm add` + corosync ring1 over the TB fabric. Runs after every node is at baseline. Never automate this; botched re-join can fence a node.
- **PBS host baseline (backup tier, Ansible):** `pbs-hosts/README.md` — layer-0 for the backup target; runs against a freshly-installed PBS 4.x host; spec lives in `pbs-hosts/CLAUDE.md`. PVE-side `pvesm add pbs` registration is a manual one-time step documented in `docs/0-scratch-build-order.md` phase 2.5.
- **Proxmox API user/token setup (Packer):** `docs/proxmox-permissions.md`
- **Proxmox API user/token setup (OpenTofu):** `docs/proxmox-tofu-permissions.md`
- **OpenTofu + Ansible workstation flow:** `docs/opentofu-setup.md`
- **GPU passthrough (Thunderbolt eGPU on `pve12t`):** `docs/proxmox-gpu-passthrough.md`
- **Ubuntu base build runbook:** `packer/ubuntu-24-04-base/README.md`
- **Windows base build runbook (split-host):** `packer/windows-11-base/README.md`
- **Shared OpenTofu module:** `modules/proxmox-vm/variables.tf` (full input surface) + `modules/proxmox-vm/main.tf` (resource shapes)
- **Per-role VM definitions:** `vms/<role>/README.md` — canonical example is `vms/openbao/`

---

## Out of scope for this repo

Don't suggest adding any of the following without being asked first:

- Kubernetes manifests / Helm charts. K3s lives *inside* per-role VMs after they boot, not in the IaC layer.
- CI/CD pipelines (GitHub Actions, etc.). The lab is small enough that `packer build` from a laptop is the loop.
- Public-cloud (AWS/GCP/Azure) infrastructure. The eventual AWS KMS bridge for the offline Root CA is deferred and belongs in a separate concern.
- Application code. This repo provisions infrastructure; apps deploy on top.

If a task seems to want any of the above, surface it and ask before adding files.
