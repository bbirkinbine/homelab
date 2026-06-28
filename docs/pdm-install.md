# Proxmox Datacenter Manager — install and remote setup

Install runbook for the lab's Proxmox Datacenter Manager (PDM) host, plus the procedure for adding the PVE cluster and the PBS host as **remotes** with a deliberately-scoped API token. This is the manual companion to the `pdm-host` Ansible baseline; read [`pdm-hosts/README.md`](../pdm-hosts/README.md) for what the role configures and [`pdm-hosts/CLAUDE.md`](../pdm-hosts/CLAUDE.md) for the design spec.

PDM is the central management plane — it adds PVE clusters and PBS hosts as *remotes* and gives a unified overview, cross-cluster migration, and bulk actions. It holds no guests and no datastore. This doc covers the parts that are **not** automated: the ISO install, and the remote/token ceremony (deliberately operator-driven, same stance as the PVE/PBS API-token conventions elsewhere in this repo).

> Placeholders: `<pdm-host>`, `<pve-node>`, `<pbs-host>` stand in for real hostnames; `198.51.100.x` / `:8006` / `:8007` / `:8443` are illustrative. Never paste a real token secret or fingerprint into this doc — secrets go to the password manager (see below).

---

## 1. Hardware / BIOS prerequisites

PDM is undemanding (an API proxy + web UI). Any small x86 box with a few GB of RAM and a modest SSD is plenty; the lab runs it on a GMKtec G3 Pro (the pbs01 twin). Before installing:

- **UEFI** boot mode on.
- **Secure Boot** off (Proxmox ISOs are not Secure-Boot signed for the installer).
- **USB-first** boot order during install (revert to disk-first afterward).
- No virtualization features required — PDM hosts no guests.

---

## 2. ISO install

1. Download the **Proxmox Datacenter Manager** ISO from `https://enterprise.proxmox.com/iso/` (the PDM ISO, not PVE/PBS).
2. Write it to USB (`dd if=<iso> of=/dev/diskN bs=1M`, or balenaEtcher).
3. Boot the target from USB, choose the graphical/terminal installer.
4. Installer prompts:
   - Target disk (the single SSD).
   - Country / timezone / keymap.
   - **Root password** — set a strong one; record it in the password manager under `Homelab/PDM/<pdm-host>-root`.
   - **Email** — any address you monitor.
   - **FQDN** — e.g. `<pdm-host>.lan`. **Management IP / netmask / gateway / DNS** — use the DHCP reservation's address.
5. Reboot, remove USB, revert boot order to disk-first.
6. PDM comes up on `https://<management-ip>:8443`.

---

## 3. Post-install baseline (Ansible)

Bring the fresh host to the lab baseline with the `pdm-host` role — no-subscription repo swap, `chrony`, `ufw` (allows 22 + 8443 from the LAN), and the operator SSH key:

```bash
# one-time: authorize your key (the ISO install doesn't have it)
ssh-copy-id -i ~/.ssh/<your-key>.pub root@<pdm-host>

# from the repo root
just pdm-hosts-deps      # collections, one-time per workstation
just pdm-hosts-check     # review the diff
just pdm-hosts           # apply
```

See [`pdm-hosts/README.md`](../pdm-hosts/README.md) for the full role surface and the two opt-in extras (UPS guardian, config self-backup), both default-off.

---

## 4. First login

Browse to `https://<pdm-host>:8443`, log in as `root@pam` with the install password. You'll land on the empty dashboard — no remotes yet.

---

## 5. Add the PVE cluster + PBS as remotes (the manual, scoped way)

PDM's **Remotes → Add** dialog offers two credential paths:

1. **"Create token"** — you supply the remote's `root@pam` password once, and PDM auto-creates a token on the remote and stores its secret. Fast, but it creates a token named `root@pam!pdm-admin-<pdm-host>` with **full privileges** (on PVE: privilege-separation **off**, so the token inherits all of `root@pam`; on PBS: role `Admin` on `/`). That's broad for a service identity.
2. **"Use existing token"** — you paste a token id + secret you created yourself. This is the path below: a **dedicated, least-privilege service identity per remote**, with the secret in the password manager — matching the repo's `tofu@pve` / `pveingress@pbs` conventions.

> If you already used path 1 (the auto-token), §7 covers identifying and replacing it.

### 5a. PVE cluster — create a scoped `pdm@pve` user + token

Run on **any one** cluster node (users/tokens/ACLs are pmxcfs-replicated cluster-wide):

```bash
# 1) A dedicated PVE-realm user. No password is set — the token authenticates, not a login.
pveum user add pdm@pve --comment "Proxmox Datacenter Manager service identity"

# 2) Pick a privilege tier:
#
#    (a) Read-only dashboard — PDM shows status/resources but cannot migrate or
#        change anything. Use the built-in auditor role:
pveum acl modify / --users pdm@pve --roles PVEAuditor

#    (b) Full management (cross-cluster migration, power, config). Create a custom
#        role that is "everything except the account-management privileges" so a
#        leaked token can't lock you out or escalate. Adjust the privilege list to
#        taste; the four below are the dangerous ones to withhold.
pveum role add PDMManage -privs "$(pveum role list --output-format json \
  | python3 -c 'import sys,json; r=[x for x in json.load(sys.stdin) if x["roleid"]=="Administrator"][0]; \
print(",".join(p for p in r["privs"].split(",") if p not in {"Permissions.Modify","User.Modify","Sys.Modify","Mapping.Modify"}))')"
pveum acl modify / --users pdm@pve --roles PDMManage

# 3) Create the API token. Privilege separation OFF so the token inherits the
#    user's role (simplest correct setup; with privsep ON you'd also ACL the token).
pveum user token add pdm@pve pdm01 --privsep 0
#    -> prints the token id (pdm@pve!pdm01) and the secret value ONCE.
```

Store the result in the password manager under `Homelab/PDM/pve-cluster` — put the full `pdm@pve!pdm01=<secret>` string in the **Notes** field (same shape as `Homelab/PBS/pveingress-cluster`). You will not see the secret again.

### 5b. PBS host — create a scoped `pdm@pbs` user + token

Run on the **PBS host**:

```bash
# 1) Dedicated user.
proxmox-backup-manager user create pdm@pbs --comment "PDM service identity"

# 2) Role on the whole instance. Audit = read-only; Admin = full management.
proxmox-backup-manager acl update / Audit --auth-id pdm@pbs

# 3) Token. PBS token privsep is INTERSECTION-based (token effective perms =
#    user perms ∩ token perms), so grant the role on the token too — a
#    token-only or user-only grant yields zero effective perms.
proxmox-backup-manager user generate-token pdm@pbs pdm01
#    -> prints pdm@pbs!pdm01 and the secret ONCE.
proxmox-backup-manager acl update / Audit --auth-id 'pdm@pbs!pdm01'
```

Store `pdm@pbs!pdm01=<secret>` in the password manager under `Homelab/PDM/pbs01` (Notes field).

> Why `Audit` first: PDM's core value here is the unified view. Start read-only, confirm the remote connects and populates, then widen to `Admin` (steps 2 and the token-ACL) only if you need PDM to *act* on PBS (prune/verify/GC triggers, datastore management).

### 5c. Add each remote in PDM

In the PDM UI, **Remotes → Add → Proxmox VE** (and again for **Proxmox Backup Server**):

- **ID** — a label for the remote (e.g. the cluster name, or `pbs01`).
- **Host / IP and port** — a reachable node, `:8006` for PVE, `:8007` for PBS. For a PVE cluster you can add one node; PDM discovers the others (it records each node's fingerprint).
- **Fingerprint** — PDM fetches the remote's TLS cert and shows its SHA-256 fingerprint. Confirm it matches the remote before accepting (see §6).
- **Authentication** — choose **existing token**, paste the **token id** (`pdm@pve!pdm01` / `pdm@pbs!pdm01`) and the **secret** from the password manager.

Save. The remote should connect and populate within a few seconds.

CLI equivalent (run on the PDM host) if you prefer scripting it — inspect the current shape first:

```bash
proxmox-datacenter-manager-admin remote list
proxmox-datacenter-manager-admin remote add --help   # shows the add/update flags
```

---

## 6. Verifying a remote's TLS fingerprint

PDM pins each remote by SHA-256 cert fingerprint. To confirm the value PDM shows is the real remote (not a MITM), read it from the remote itself:

```bash
# On a PVE node:
openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256

# On the PBS host:
openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256
```

Match it against the fingerprint in the Add-Remote dialog before accepting.

---

## 7. If PDM already auto-created a `root@pam` token

If the remote was added via the **"Create token"** path, PDM created a full-privilege token on the remote and is using it. Identify it:

```bash
# PVE (any node) — look for token 'pdm-admin-<pdm-host>' under root@pam, privsep 0:
pveum user token list root@pam

# PBS — same token name under root@pam, with role Admin on '/':
proxmox-backup-manager user list-tokens root@pam
proxmox-backup-manager acl list | grep pdm-admin
```

To move to the scoped identity without downtime:

1. Create the dedicated `pdm@pve` / `pdm@pbs` user + token per §5a/§5b.
2. In PDM, **edit the remote** and replace the auth-id + secret with the new scoped token (UI: Remotes → select → Edit; or `proxmox-datacenter-manager-admin remote update <id> ...`). Confirm the remote still connects.
3. Only then **delete the auto-created root token** on the remote so it can't be used:
   ```bash
   # PVE:
   pveum user token remove root@pam pdm-admin-<pdm-host>
   # PBS:
   proxmox-backup-manager user delete-token root@pam 'pdm-admin-<pdm-host>'
   ```

Leaving the root token in place works, but it's a full-cluster / full-PBS credential held by a management appliance — a larger blast radius than a scoped, revocable service token. The scoped token is also independently auditable and rotatable without touching `root@pam`.

---

## 8. Notes

- **Backups of the PDM config** capture the remote list + these token secrets (`/etc/proxmox-datacenter-manager/remotes.shadow`). If you enable the role's opt-in config self-backup, treat those tarballs as sensitive (they're written `0600`). See [`pdm-hosts/README.md`](../pdm-hosts/README.md).
- **No secrets in this repo.** Token secrets and fingerprints live in the password manager and on the hosts, never in committed files — same rule as everywhere else in this repo.
- **TLS** — PDM ships a self-signed cert on `:8443`. Migration to a cert chained off the offline Root CA is a future task shared with the PVE/PBS TLS work.

---

## Related

- [`pdm-hosts/README.md`](../pdm-hosts/README.md) — the layer-0 baseline role.
- [`docs/pbs-install.md`](pbs-install.md) — the sibling PBS install runbook.
- [Authentication & Access Control — PDM docs](https://pdm.proxmox.com/docs/access-control.html).
