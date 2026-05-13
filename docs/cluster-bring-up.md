# Cluster bring-up — `pvecm create` + `pvecm add` + corosync ring1

The procedure to form the 3-node Proxmox cluster after the `pve-host` Ansible role has baselined every host individually. This is **manual and quorum-aware** — botched re-join can fence a node, and edits to `/etc/pve/corosync.conf` from multiple places fight each other through pmxcfs. The role deliberately stops at this boundary; see `pve-hosts/CLAUDE.md` § "What this role MUST NOT do".

This doc covers the operational commands. The design rationale (why corosync, why a TB ring1, why 2.5GbE for ring0) lives in the Obsidian vault at `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md`. Read that first if you want context; this doc is the runbook.

---

## Where this fits

You should arrive here from:

- [docs/0-scratch-build-order.md](0-scratch-build-order.md) Phase 2 step 7, or
- [pve-hosts/README.md](../pve-hosts/README.md) § "Post-baseline manual steps" step 1.

The next things after this doc complete are:

- Cluster-wide `pve-firewall` enable (post-baseline step 3) — flip `enable: 0` → `1` in `/etc/pve/firewall/cluster.fw`.
- Snippets content type on `local` (step 4).
- NFS storage registration as `nas-vms` (step 5).
- API users for Packer + OpenTofu (step 6).

---

## Prerequisites — must all be true before `pvecm create`

A miscount here can lock out a node. Verify every item.

1. **All three nodes baselined** via `just pve-hosts`. Re-running on a healthy host reports `changed=0`. If yours doesn't, fix that first.
2. **TB fabric is live** — eight pings (adjacency + direct loopbacks + transit) all succeed, per [pve-hosts/README.md § "When to run this role"](../pve-hosts/README.md). Cluster join itself uses LAN (ring0); TB ring1 gets added in step 4 below, post-join.
3. **`pve-firewall` is running but inert.** `systemctl is-active pve-firewall` returns `active` on every node, AND `/etc/pve/firewall/cluster.fw` has `enable: 0`. The asymmetric-state hazard (filter ON on one node, OFF on others, TB transit silently drops) is real — see SCAFFOLD-NOTES.md for the 2026-05-13 debugging story.
4. **Joining nodes are empty.** On `pve13m` and `pve13t`:

   ```bash
   ls /etc/pve/qemu-server/   # must be empty
   ls /etc/pve/lxc/           # must be empty
   pveum user list            # only standard users (root@pam, root@pve)
   ```

   `pvecm add` refuses if the joiner has any VMs/templates registered. Custom `pveum` users get wiped (the creator's `/etc/pve/` becomes the cluster's).

5. **Root passwords available.** Each `pvecm add` will prompt for the cluster-creator node's root password to authenticate the join. Have pve12t's root password from KeePassXC ready.

6. **SSH keys still work between nodes** as root. The role installed `admin_ssh_pubkey` into `/root/.ssh/authorized_keys` on every host; verify with `ssh root@pve13m hostname` from pve12t. The cluster forms over SSH initially.

7. **Network agreement on `/etc/hosts`.** Every node must resolve every other node's hostname to its LAN IP. The role's `/etc/hosts` template handles this; verify with `grep pve /etc/hosts` on each node showing all three entries.

If any of these aren't true, fix before proceeding. **There is no "undo" for `pvecm create` short of `pvecm delnode` from a remaining-quorate node, or full reinstall.**

---

## Step 1 — Create the cluster on pve12t

Pick the creator. We use **pve12t** because it's the node with the most state (Razer Core X enrolled, eGPU passthrough config eventually). The creator's `/etc/pve/` contents become the cluster's; everyone else's gets replaced. pve12t's existing `cluster.fw` (with `enable: 0`) is what we want everywhere.

```bash
ssh root@192.168.1.227 'pvecm create homelab --link0 192.168.1.227'
```

- `homelab` — cluster name. Convention only; any short alphanumeric string works.
- `--link0 192.168.1.227` — pins corosync ring0 to pve12t's LAN address. Without this, corosync picks the first non-loopback IP it finds, which is usually fine but explicit is better.

Expected output: a few seconds of corosync startup messages, no errors. Verify:

```bash
ssh root@192.168.1.227 'pvecm status'
```

You should see:

- `Cluster information` block: name `homelab`, config version `1`, transport `knet`
- `Quorum information`: `Quorate: Yes`, `Nodes: 1`
- `Membership information`: a single member at `192.168.1.227`, you're it

If `Quorate: No` or the node fails to start, look at `journalctl -u corosync -n 50` and the next attempt should be `pvecm delnode pve12t` to clear state before retrying.

---

## Step 2 — Join pve13m

`pvecm add` prompts for pve12t's root password on stdin, which the non-interactive `ssh root@<ip> 'cmd'` form can't supply cleanly — the command hangs. Use an interactive SSH session instead:

```bash
ssh root@192.168.1.163
# Inside the pve13m shell:
pvecm add 192.168.1.227 --link0 192.168.1.163
# It prompts:
#   "Are you sure you want to continue connecting (yes/no/[fingerprint])?" → yes
#   "root@192.168.1.227's password:" → pve12t's root password from KeePassXC
exit
```

What's happening behind the prompts:

1. pve13m SSH's to pve12t with the supplied root password.
2. Pulls the cluster's `corosync.conf` + auth keys.
3. Stops pve13m's local pmxcfs and writes the cluster's state into `/etc/pve/`.
4. Starts pmxcfs in cluster mode; corosync sees the new member; quorum re-counts.

Expected: a sequence of "successfully added node" + key-fingerprint messages, no errors. Verify from pve12t:

```bash
ssh root@192.168.1.227 'pvecm status'
```

Now shows `Nodes: 2`, both members listed. From pve13m, the cluster's `cluster.fw` should now be replicated:

```bash
ssh root@192.168.1.163 'ls -la /etc/pve/firewall/'
ssh root@192.168.1.163 'grep enable: /etc/pve/firewall/cluster.fw'
```

Expect: `cluster.fw` present, `enable: 0` — pmxcfs replicated the file from pve12t.

---

## Step 3 — Join pve13t

Same shape, different node. Again use interactive SSH so the password prompt works:

```bash
ssh root@192.168.1.240
# Inside the pve13t shell:
pvecm add 192.168.1.227 --link0 192.168.1.240
# yes to the host-key prompt, pve12t's root password to the password prompt
exit
```

After it completes, verify the 3-node quorate state:

```bash
ssh root@192.168.1.227 'pvecm status'
```

Should now show `Nodes: 3`, `Quorate: Yes`, three members on ring 0 over 192.168.1.0/24, with `Link 0 status: active` for each.

Sanity-check pmxcfs replication by writing a probe file from one node and reading it from another:

```bash
ssh root@192.168.1.227 'echo probe-$(date +%s) > /etc/pve/.bringup-probe'
ssh root@192.168.1.163 'cat /etc/pve/.bringup-probe'
ssh root@192.168.1.240 'cat /etc/pve/.bringup-probe'
# clean up
ssh root@192.168.1.227 'rm /etc/pve/.bringup-probe'
```

If all three reads return the same string, pmxcfs is healthy.

---

## Step 4 — Add corosync ring1 over the Thunderbolt fabric

Ring0 is live on the 2.5GbE LAN. We now add ring1 over the TB fabric so corosync has two independent paths and live-migration traffic rides TB. This is an edit to `/etc/pve/corosync.conf` — pmxcfs-replicated, so changes from any one node propagate cluster-wide.

**Back up the running config first** in case the edit goes wrong:

```bash
ssh root@192.168.1.227 'cp /etc/pve/corosync.conf /root/corosync.conf.pre-ring1'
```

Then edit `/etc/pve/corosync.conf` on **any one node** (pmxcfs will replicate). Add a `ring1_addr` to each node's nodelist entry and a `linknumber: 1` interface block under `totem`, and **bump `config_version`** by one:

```bash
ssh root@192.168.1.227 'cat /etc/pve/corosync.conf'
```

You'll see something like:

```text
logging {
  debug: off
  to_syslog: yes
}

nodelist {
  node {
    name: pve12t
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 192.168.1.227
  }
  node {
    name: pve13m
    nodeid: 2
    quorum_votes: 1
    ring0_addr: 192.168.1.163
  }
  node {
    name: pve13t
    nodeid: 3
    quorum_votes: 1
    ring0_addr: 192.168.1.240
  }
}

quorum {
  provider: corosync_votequorum
}

totem {
  cluster_name: homelab
  config_version: 3
  interface {
    linknumber: 0
  }
  ip_version: ipv4-6
  link_mode: passive
  secauth: on
  version: 2
}
```

Edit to add `ring1_addr` per node (each node's TB loopback /32 from `inventory.yml`'s `tb_loopback`), add a `linknumber: 1` interface, and bump `config_version`:

```text
nodelist {
  node {
    name: pve12t
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 192.168.1.227
    ring1_addr: 10.10.10.12
  }
  node {
    name: pve13m
    nodeid: 2
    quorum_votes: 1
    ring0_addr: 192.168.1.163
    ring1_addr: 10.10.10.13
  }
  node {
    name: pve13t
    nodeid: 3
    quorum_votes: 1
    ring0_addr: 192.168.1.240
    ring1_addr: 10.10.10.14
  }
}

totem {
  cluster_name: homelab
  config_version: 4
  interface {
    linknumber: 0
  }
  interface {
    linknumber: 1
  }
  ip_version: ipv4-6
  link_mode: passive
  secauth: on
  version: 2
}
```

Use `vim /etc/pve/corosync.conf` — pmxcfs handles atomic-write semantics. Save and exit.

corosync detects the `config_version` bump and re-applies within seconds. Verify both rings are up:

```bash
ssh root@192.168.1.227 'corosync-cfgtool -s'
```

Expected output shows ring0 over 192.168.1.0/24 AND ring1 over 10.10.10.0/24, both `enabled` and `connected` per node. `pvecm status` shows `Link 0 status` and `Link 1 status` both active for each member.

If ring1 fails to come up:

- TB loopbacks unreachable: re-run the 8-ping suite from [pve-hosts/README.md](../pve-hosts/README.md). The fabric must be live for corosync to use it.
- Syntax error: restore `/root/corosync.conf.pre-ring1` over `/etc/pve/corosync.conf`, ring1 reverts. Then redo the edit more carefully.
- config_version not bumped: corosync won't reread the file. The bump is what triggers the reload.

Migration traffic routing comes separately via `/etc/pve/datacenter.cfg`:

```bash
echo 'migration: type=secure,network=10.10.10.0/24' >> /etc/pve/datacenter.cfg
```

(Or via Datacenter → Options in the UI.) After this, `qm migrate` traffic rides the TB fabric.

---

## What to verify before moving on

```bash
# 3-node quorate, both rings up
ssh root@192.168.1.227 'pvecm status'

# Both rings showing as enabled+connected on every node
for ip in 192.168.1.227 192.168.1.163 192.168.1.240; do
  ssh root@$ip 'echo "=== $(hostname) ==="; corosync-cfgtool -s'
done

# pmxcfs replicates writes (already proven in step 3 — re-run if you skipped)
# Cluster.fw replicated to all nodes
for ip in 192.168.1.227 192.168.1.163 192.168.1.240; do
  ssh root@$ip 'grep enable: /etc/pve/firewall/cluster.fw'
done

# Web UI confirms 3 nodes (Datacenter view, all green)
# Open https://192.168.1.227:8006 — login as root@pam — see all three in the tree
```

---

## What comes next

After cluster join + ring1 is verified, return to [docs/0-scratch-build-order.md](0-scratch-build-order.md) Phase 2 starting at step 8:

- Cluster-wide `pve-firewall` enable (flip `enable: 0` → `1` in cluster.fw, replicates everywhere)
- Enable `snippets` content type on `local` (`pvesm set local --content snippets,iso,vztmpl,backup,images,rootdir`)
- Register the Asustor NFS export as cluster storage `nas-vms` (`pvesm add nfs nas-vms ...` with `--content images,backup,snippets`)

Then Phase 3 (IaC enablement): Packer + OpenTofu API users, base templates.

---

## Common failures + recovery

**`pvecm add` errors with "no quorum on node".**
Wait — quorum can take a few seconds to update after the prior join. Retry after 5s.

**`pvecm add` errors with "node already in cluster".**
The joiner has stale corosync state from a prior attempt. On the joiner:

```bash
systemctl stop pve-cluster corosync
rm /etc/pve/corosync.conf /etc/corosync/corosync.conf
rm -rf /var/lib/corosync/*
systemctl start pve-cluster
```

Then retry `pvecm add`.

**Joiner refuses with "vm/lxc config exists in /etc/pve".**
The joiner had VMs/templates registered (probably from a prior PVE setup on the same disk). Either move them aside or destroy them:

```bash
mv /etc/pve/qemu-server /etc/pve/qemu-server.pre-cluster
mv /etc/pve/lxc /etc/pve/lxc.pre-cluster
# OR qm destroy --purge <id> for each VM
```

Then retry. The "pre-cluster" copies will be overwritten when the joiner pulls the cluster's `/etc/pve/`; if you want to keep the VM defs, back them up to a non-pve path first.

**SSH host-key prompt during `pvecm add`.**
The joiner is asked to trust the cluster node's host key. Type `yes`. To avoid the prompt, pre-seed `/root/.ssh/known_hosts` on the joiner.

**Web UI shows nodes as "?" or red.**
Almost always a corosync ring problem. `corosync-cfgtool -s` on the affected node will show which ring is down. If ring0 is down, check LAN connectivity / firewall. If ring1 is down, re-run the TB 8-ping suite.

**Cluster `pvecm status` shows quorum lost after editing corosync.conf.**
You bumped `config_version` but the edit had a syntax error. Restore from `/root/corosync.conf.pre-ring1` via:

```bash
cp /root/corosync.conf.pre-ring1 /etc/pve/corosync.conf
```

pmxcfs replicates the restore. Wait a few seconds, then `pvecm status` should recover.

---

## Removing a node (for completeness)

If you ever need to remove a node from the cluster (e.g., disaster recovery, hardware replacement):

```bash
# From a node that STAYS in the cluster (quorate):
pvecm delnode pve13t

# Then on the removed node, clean up its local state:
ssh root@<removed-node-ip> '
  systemctl stop pve-cluster corosync
  rm /etc/corosync/* /etc/pve/.members
  systemctl start pve-cluster
'
```

The removed node is now in single-node pmxcfs mode and can be rejoined with `pvecm add` or wiped.

---

## Related docs

- [docs/0-scratch-build-order.md](0-scratch-build-order.md) — master index; this doc fills in Phase 2 step 7.
- [pve-hosts/README.md](../pve-hosts/README.md) — the role baseline that runs *before* this doc.
- Vault: `Projects/Homelab/VM Mobility — 3-Node Cluster on 2.5GbE.md` — cluster + NFS architecture, authoritative on design.
- Vault: `Projects/Homelab/Thunderbolt Mesh Networking — 3-Node Cluster Option.md` — TB fabric design + Phase 7 ring1 details.
- Proxmox upstream: <https://pve.proxmox.com/wiki/Cluster_Manager>
