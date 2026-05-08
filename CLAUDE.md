# CLAUDE.md — homelab repo

> **Purpose.** Persistent project context for Claude Code (and other AI tools) working in this repository. Read this before suggesting changes. `README.md` is for humans landing on the GitHub page; this file is for the agent that opens the repo and starts working.

---

## What this repo is

Infrastructure-as-code for a small Proxmox VE homelab built around two universal VM templates (Ubuntu 24.04, Windows 11 Pro x64) that downstream per-role VMs clone from. See `README.md` for the human-facing overview and `docs/`, `packer/*/README.md`, `vms/*/README.md` for component runbooks.

The repo is **public** on GitHub. Treat every change as something a stranger will read: no embedded credentials, no cluster topology that exposes attack surface, prose comments where a maintainer would otherwise have to reverse-engineer intent.

---

## Active context (as of 2026-05-07)

A few states that won't be obvious from the code alone:

**Windows-11 base is work-in-progress and uncommitted.** The directory `packer/windows-11-base/` exists locally but is not in any git tree yet. Brian doesn't want commits to Windows files until the full build works end-to-end on both targets. Do **not** run `git commit`, `git add`, or `gh pr create` against Windows files. Edits in place are fine; staging is not. When in doubt, `git status` first and ask.

**Ubuntu-24.04 base is stable and committed.** Treat `packer/ubuntu-24-04-base/` as load-bearing — it's already shipping templates to the homelab. When you're working on a Windows-related task, do not modify Ubuntu files even for "while I'm here" cleanups. If a fix genuinely belongs to the Ubuntu side, surface it and ask before touching.

**Cluster transition in progress.** `README.md` currently describes the three NUCs as independent (per-node tokens, per-node template builds). Brian is moving to a 3-node Proxmox cluster with NFS-shared storage on an Asustor NAS. Until that transition lands in a commit: assume per-node tokens, per-node template builds, no shared cluster filesystem. When the cost is small, parameterize node names rather than hard-coding one — that way nothing breaks when the cluster lands.

**Repo is migrating from `deploy.sh` shell scripts to OpenTofu** (`bpg/proxmox` provider). New VM definitions should prefer `.tf` over `.sh` where the topic is provisioning shape (clone, size, network). Existing shell scripts in `vms/*/` may stay for now — don't rewrite them speculatively without asking.

---

## Build-host split for the Windows Packer config

This is the most surprising operational detail in the repo and worth internalizing.

`packer/windows-11-base/` defines two source blocks (`proxmox-iso` and `qemu`) sharing one provisioner pipeline. They run from **different machines**:

- **`proxmox-iso` runs from the Mac (M2 Max MacBook Pro).** The build host only orchestrates the Proxmox API; the Windows install runs on the NUC itself. No KVM, swtpm, or QEMU needed locally. macOS is fine.
- **`qemu` runs from the T480 Ubuntu boot.** The qemu source executes the install on the build host and produces a local QCOW2. This needs KVM acceleration. Apple Silicon HVF only accelerates ARM64 guests, so x86-64 Windows on the M2 falls back to pure software emulation (hours, not minutes) — not a viable build path.

What this means for suggestions:

- A single invocation runs ONE source (proxmox-iso OR qemu). `build.sh` only accepts those two values for `BUILDER`; there's deliberately no "build both at once" mode. The two targets have different host requirements (qemu needs Linux + KVM + swtpm; proxmox-iso just needs network reach to a Proxmox node) and produce different artifacts. If a future world wants `both`, reintroduce it deliberately rather than preserving a vestigial escape hatch.
- Don't recommend running the qemu target from the Mac, even with `tcg` fallback. Many-hour emulated builds aren't useful — `build.sh` rejects `BUILDER="qemu"` on a non-Linux host with a clear error rather than letting it fall through to TCG.
- The `.env.<target>` files live on the host that builds that target. `.env.pve12` / `.env.pve13` go on the Mac; `.env.t480` goes on the T480. All are gitignored (`.env.*` glob, with `!.env.example` exception).

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

**Brian's local secret store is KeePassXC unlocked with a YubiKey** (with a backup YubiKey enrolled). When suggesting credential patterns for IaC:

- Default to "read from `.env.<target>` at invocation time" or "fetch from KeePassXC at run time", not "embed in the `.tf` / `.pkr.hcl`".
- Don't suggest 1Password CLI, Vault, or SOPS as the default — Brian is aware of those; they're options, not the current shape.

If a secret has to flow through HCL, it goes through `variable {}` with `sensitive = true` and is set via `PKR_VAR_*` env vars at build time. The existing `build.sh` files are canonical examples.

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

## Where component-level context lives

When a task touches one of these areas, read the local doc first before suggesting structural changes — they're authoritative for their component.

- **Proxmox API user/token setup:** `docs/proxmox-permissions.md`
- **GPU passthrough (Thunderbolt eGPU on `pve12t`):** `docs/proxmox-gpu-passthrough.md`
- **Ubuntu base build runbook:** `packer/ubuntu-24-04-base/README.md`
- **Windows base build runbook (split-host):** `packer/windows-11-base/README.md`
- **Per-role VM definitions:** `vms/<role>/README.md`

---

## Out of scope for this repo

Don't suggest adding any of the following without being asked first:

- Kubernetes manifests / Helm charts. K3s lives *inside* per-role VMs after they boot, not in the IaC layer.
- CI/CD pipelines (GitHub Actions, etc.). The lab is small enough that `packer build` from a laptop is the loop.
- Public-cloud (AWS/GCP/Azure) infrastructure. The eventual AWS KMS bridge for the offline Root CA is deferred and belongs in a separate concern.
- Application code. This repo provisions infrastructure; apps deploy on top.

If a task seems to want any of the above, surface it and ask before adding files.
