# vms/openbao/legacy/ — superseded HSM-era artifacts

Everything in this directory was the **first cut** of the OpenBao VM:
shell-script provisioning (`deploy.sh`), a 270-line cloud-init that
installed the smartcard stack (pcscd, opensc, libccid, sc-hsm-embedded,
polkit + udev rules), and USB passthrough of a CardLogix SmartCard-HSM
4K to back an OpenBao PKCS#11 auto-unseal.

That whole shape was retired on **2026-05-10** for two reasons:

1. **The PKCS#11 seal doesn't actually work with the CardLogix HSM.**
   OpenBao's stock seal accepts only `CKM_AES_GCM` or
   `CKM_RSA_PKCS_OAEP`. The SmartCard-HSM 4K implements neither
   (`CKM_AES_CBC` + `CKM_AES_CMAC` + raw RSA only). The intersection of
   supported mechanisms is empty — no config makes the pair work
   without patching one of the two projects. See the architecture
   note in the vault doc `OpenBao Homelab Setup.md`.
2. **The CardLogix pair was always a better fit for the offline Root
   CA role**, which is purpose-built for asymmetric/PKI signing — the
   SC-HSM 4K's design center. The HSM moved to that role (see
   `CardLogix as Offline Root CA.md` in the vault); the OpenBao VM
   moved to a Shamir seal (5 shares, 3-of-5 threshold, manual unseal
   after every restart, share custody in KeePassXC + paper envelopes).

The new provisioning shape lives one level up at `vms/openbao/` and
uses **OpenTofu** (clone + size, no USB passthrough) + **Ansible**
(install + config + service). The cloud-init in the new path is
identity-only — hostname, admin user, SSH key — and the smartcard
stack is gone entirely.

These files are preserved here, not deleted, because:

- The USB-passthrough trick (`qm set --usb0 host=<bus>-<port>` pinned
  by physical jack so token swap doesn't require a Proxmox reconfig)
  is reusable for the future Root CA VM.
- The pcscd polkit-for-plugdev rule, the udev `uaccess` tag for CCID
  devices, and the cicustom + cloud-init-drive-recreate dance in
  `deploy.sh` are non-obvious operational knowledge that's worth
  preserving alongside the comments explaining *why* each one matters.

When the Root CA VM (`vms/rootca/` or similar) lands, expect about
half of `deploy.sh` and 80% of `cloud-init/user-data.yaml` to migrate
forward — but as Ansible tasks and an HSM-specific tofu module, not
as a shell script.

Git history of the move is preserved (used `git mv`), so `git log
--follow` works back through the original commit `c945c78`.
