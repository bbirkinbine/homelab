# Cloning templates and per-clone user management

This document covers what happens after Packer finishes building a base
template — how to clone it into a usable VM, how the first-boot identity
gets configured, and the options for who can log in to the resulting VM.

The two universal templates ([Ubuntu 24.04
base](../packer/ubuntu-24-04-base/) and [Windows 11
base](../packer/windows-11-base/)) follow the same design, so most of
this doc applies to both. Differences are called out where they matter.

## Templates have no usable login by design

Both base templates are deliberately login-less when freshly built. There
is no "known account + known password" that grants access to a clone.
This is intentional — clones inherit per-VM identity from the cloud-init
drive Proxmox attaches at clone time, not from the template image.

What this looks like for each base:

**Ubuntu 24.04 base.** The build process creates a `packer` user with a
hashed password (`packer-build-only`) and passwordless sudo, used by
Packer's SSH provisioners during the build. Before the template is
sealed, [provision/99-cleanup.sh](../packer/ubuntu-24-04-base/provision/99-cleanup.sh)
installs a systemd one-shot unit (`packer-cleanup.service`) ordered
`Before=cloud-init-local.service`. That unit runs on the **first boot of
any clone**, deletes the `packer` user, removes its sudoers entry,
disables itself, and removes its own files. The build-time credentials
are gone before the clone's network even comes up.

**Windows 11 base.** The build process uses the local `Administrator`
account with a known password (`packer-build-only-Win11!` from
[variables.pkr.hcl](../packer/windows-11-base/variables.pkr.hcl)) so
Packer can connect via WinRM during provisioning. Before the template is
sealed, [provision/99-sysprep.ps1](../packer/windows-11-base/provision/99-sysprep.ps1)
registers a `PackerBuildCleanup` scheduled task that fires AtStartup as
SYSTEM on the first boot of every clone. The task waits for
`cloudbase-init` to finish, rotates the Administrator password to a
32-byte random value, disables the Administrator account, clears the
AutoAdminLogon registry values written by the answer file, then
unregisters itself and removes its own script. Sysprep `/generalize`
preserves scheduled-task definitions and strips machine-specific
identifiers, so each clone gets a fresh SID, computer name, and machine
GUID — and the cleanup task rides into every clone unchanged.

The net effect is that **on the first boot of any clone, before any
human can log in, the build credentials are gone.** Templates never
power on, so the cleanup task only ever fires on clones, never on the
template itself.

In both cases, **a freshly cloned VM has no enabled local user with a
known password.** If you skip the cloud-init step, the only way to log
in is via the Proxmox console after manual recovery — boot rescue media,
reset the password on disk. Don't.

## Per-clone identity via Proxmox cloud-init drive

Proxmox attaches a small CD-ROM-shaped cloud-init drive to every clone
of a template that was built with `cloud_init = true` (both bases set
this). On first boot, the in-guest cloud-init agent reads metadata and
user-data from that drive and applies them.

- **Ubuntu** runs `cloud-init` (the canonical Linux implementation).
- **Windows** runs `cloudbase-init` (a Python re-implementation of the
  cloud-init plugin model for Windows). It is installed and configured
  by [provision/30-install-cloudbase-init.ps1](../packer/windows-11-base/provision/30-install-cloudbase-init.ps1).

You attach user-data to a clone in one of two ways. Both work for both
base templates.

### Option A: `qm set --cicustom` (manual / shell scripts)

Write a snippet to a Proxmox storage that supports the `snippets`
content type (default: `local`), then point the VM at it. The snippet is
a regular `#cloud-config` YAML file — exactly the same shape both
cloud-init implementations consume.

**Ubuntu clone, brand-new admin user with SSH key:**

```bash
# On any Proxmox node:
cat > /var/lib/vz/snippets/myvm.yaml <<'EOF'
#cloud-config
hostname: myvm
manage_etc_hosts: true
users:
  - name: brian
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... brian@laptop
    # Hashed password (mkpasswd -m sha-512). Optional if you only want SSH key auth.
    # passwd: '$6$...'
EOF

qm clone 9100 200 --name myvm --full --storage local-lvm
qm set 200 --cicustom "user=local:snippets/myvm.yaml" --ipconfig0 ip=dhcp
qm start 200
```

**Windows clone, admin user with password and SSH key:**

```bash
cat > /var/lib/vz/snippets/myvm.yaml <<'EOF'
#cloud-config
hostname: myvm
users:
  - name: brian
    primary_group: Administrators
    passwd: SomeStrongPassword!         # plaintext on Windows; cloudbase-init hashes it
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... brian@laptop
EOF

qm clone 9101 201 --name myvm --full --storage local-lvm
qm set 201 --cicustom "user=local:snippets/myvm.yaml" --ipconfig0 ip=dhcp
qm start 201
```

### Option B: Terraform / OpenTofu (declarative)

The `bpg/proxmox` provider knows how to upload snippets and attach them.
This is the long-term pattern for the homelab — see the README's note on
the migration from `deploy.sh` to OpenTofu.

```hcl
resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve12"
  source_raw {
    file_name = "myvm.yaml"
    data      = <<-EOT
      #cloud-config
      hostname: myvm
      users:
        - name: brian
          primary_group: Administrators
          passwd: ${var.password}
          ssh_authorized_keys:
            - ${var.ssh_pubkey}
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "myvm" {
  vm_id     = 201
  name      = "myvm"
  node_name = "pve12"
  clone {
    vm_id = 9101
    full  = true
  }
  initialization {
    user_data_file_id = proxmox_virtual_environment_file.user_data.id
    ip_config { ipv4 { address = "dhcp" } }
  }
}
```

`tofu apply` clones the template and attaches the snippet in one shot.

## What NOT to do

Three traps that look reasonable and aren't:

1. **Don't use `qm set --ciuser X --cipassword Y`** for Windows clones.
   The Proxmox shortcut writes user-data with top-level
   `user:` / `password:` / `chpasswd:` keys. Linux `cloud-init`
   understands these. Windows `cloudbase-init` does NOT — its
   cloudconfig plugin treats them as unsupported and silently does
   nothing. The clone boots with no enabled user. Ask me how I know.
   (For Linux clones, the shortcut is fine.)

2. **Don't bake a permanent admin password into the template.** It's
   tempting to add a "create stable user X with password Y" step to the
   build provisioner so you can always log in. Every clone you ever
   produce will have that user, all with the same password, and rotating
   it requires rebuilding the template AND every existing VM. Use the
   cloud-init drive for per-clone identity.

3. **Don't rely on the Packer build-time credentials.** The Ubuntu
   `packer` user is gone by the time a clone's network is up; the
   Windows `Administrator` account is rotated and disabled by the
   `PackerBuildCleanup` scheduled task on every clone's first boot.
   Neither is a stable login path.

## User management options

Once cloud-init is the source of truth for clone identity, you have the
same set of choices on either platform.

### SSH key only (recommended for both)

Pure key auth, no password. Most secure, no rotation pain, integrates
with `ssh-agent` and yubikeys. Works on both Ubuntu and Windows (Windows
SSH server is enabled by [20-harden.ps1](../packer/windows-11-base/provision/20-harden.ps1);
on Windows the keys go in `~/.ssh/authorized_keys` for non-admin users
and `C:\ProgramData\ssh\administrators_authorized_keys` for users in the
Administrators group — see the `Match Group administrators` block in
sshd_config).

```yaml
users:
  - name: brian
    primary_group: Administrators       # Windows; on Ubuntu use 'groups: [sudo]'
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... brian@laptop
```

### Password + key (current homelab default for testing)

Useful when you want both noVNC console fallback and remote shell
access. Set `passwd:` (Linux: hash; Windows: plaintext) plus an SSH key.

### Multiple users, role-based

`users:` is a list. Add as many as needed; each gets its own password,
groups, and keys. Useful for shared lab boxes — give each operator their
own account so audit log entries are attributable.

```yaml
users:
  - name: brian
    primary_group: Administrators
    ssh_authorized_keys: [...]
  - name: ops-bot
    primary_group: Administrators
    ssh_authorized_keys: [...]    # CI/automation key
```

### Domain-joined Windows clones (future)

When the AD path lands, Windows clones can be joined to the lab domain
on first boot. The cloud-init `users:` list is for *local* accounts;
domain join is a separate step (PowerShell `Add-Computer` or a
post-clone Ansible role). The local-account path documented here still
matters as the bootstrap account before the join completes.

## Gotchas

A handful of behaviors that are not bugs but will surprise you.

- **Hostname-change reboot.** Both `cloud-init` and `cloudbase-init`
  apply the hostname early and Linux/Windows respond by restarting
  networking (Linux) or rebooting the box (Windows). The clone's IP
  often re-leases at this point — don't cache the address from the
  first probe; query the guest agent again after ~60 seconds.

- **NetBIOS-15 truncation on Windows.** `cloudbase-init` truncates
  hostnames to 15 characters with a warning in its log. `myvm-test-foo`
  is fine; `windows-clone-test-001` becomes `windows-clone-t`.

- **Linux hashes, Windows plaintext.** `cloud-init`'s `passwd:` field
  expects a hashed password (per `crypt(5)`). `cloudbase-init`'s `passwd:`
  expects plaintext, which it hands to the Win32 user-creation API.
  Putting a `$6$...` SHA-512 hash in a Windows `users:` entry will set
  the literal hash as the password. Putting plaintext into a Linux
  `users:` entry will not work as expected (cloud-init compares against
  hashes).

- **First boot is not instantaneous.** Linux clones take ~30 seconds to
  ~2 minutes from `qm start` to SSH-able. Windows clones take longer —
  3 to 6 minutes — because cloudbase-init's hostname change forces a
  reboot before the per-clone identity finishes applying.

- **WinRM lags SSH and RDP after the hostname-change reboot on Windows.**
  Once a Windows clone reboots, ports 22 and 3389 typically come back
  within ~10 seconds, but the WinRM listener (5985) takes another
  30–60 seconds to re-bind IPv4. Probing right after the agent reports
  an IP often shows 5985 closed even though the VM is otherwise ready.
  Terraform / OpenTofu code that connects via the WinRM communicator
  should set generous timeouts (or retry); SSH-based flows don't see
  this delay.

- **Snippet storage must allow `snippets` content type.** On a fresh
  Proxmox install, the default `local` storage already does. If a custom
  storage doesn't, `qm set --cicustom` will fail with "content type
  snippets is not supported".

## Related

- [proxmox-permissions.md](proxmox-permissions.md) — the API token role
  needed to clone templates and read storage.
- [packer/ubuntu-24-04-base/README.md](../packer/ubuntu-24-04-base/README.md)
  — what the Ubuntu template ships with (qemu-guest-agent, cloud-init,
  sshd, openssh-server).
- [packer/windows-11-base/README.md](../packer/windows-11-base/README.md)
  — what the Windows template ships with (RDP, OpenSSH server, WinRM,
  cloudbase-init, virtio-win-guest-tools).
