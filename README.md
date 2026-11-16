# homelab-kvm-ceph-k8s

Home lab: a 3-node Ceph cluster (MicroCeph) and k3s Kubernetes cluster on
Ubuntu 26.04 ARM64 VMs (UTM on an Apple M1 Max), with Ceph providing
Kubernetes storage through ceph-csi.

| Node  | Address        | Roles                              |
| ----- | -------------- | ---------------------------------- |
| node1 | 192.168.65.201 | Ceph mon/mgr/mds/osd, k3s server   |
| node2 | 192.168.65.202 | Ceph mon/mgr/mds/osd, k3s agent    |
| node3 | 192.168.65.203 | Ceph mon/mgr/mds/osd, k3s agent    |

The application deployed on it (an ASP.NET Core music database with MySQL,
Redis and HAProxy) lives in its own repo,
[MusicDB-CS](https://github.com/perk32725a/MusicDB-CS) (`k8s/` folder).

## Layout

- `ceph/` – scripts run on a Ceph node (Kubernetes pools, CephFS, users).
- `k8s/ceph-csi/` – ceph-csi drivers and StorageClasses for Kubernetes.
- `ansible/` – the node setup as Ansible roles (see below).

## Ansible

The setup was first done by hand, then captured as four roles and checked
against the running cluster: `ansible-playbook site.yml --check --diff`
reports no changes on any node.

| Role        | Hosts       | Sets up |
| ----------- | ----------- | ------- |
| `common`    | all nodes   | hostname and `/etc/hosts`, swap off, SSH and guest agent, text-mode boot, fixed address (NetworkManager), an AppArmor sysctl workaround for k3s ([containerd#14485](https://github.com/containerd/containerd/issues/14485)) |
| `microceph` | all nodes   | MicroCeph (Squid, snap held): bootstrap, join, one OSD per node, memory caps |
| `k3s`       | all nodes   | k3s server on node1 (Traefik off), agents on node2/node3, pinned version |
| `ceph_k8s`  | node1       | `ceph/prepare-ceph.sh` and the `k8s/ceph-csi/` manifests |

```
cd ansible
ansible-playbook site.yml --check --diff -K   # show what would change
ansible-playbook site.yml --diff -K           # apply
```

Each role reads the current state first and acts only where it differs, so
a run on the built cluster changes nothing. Commands that change something
are written so that `--check` reports them as changed instead of silently
skipping them. Join tokens and Ceph keys are read during the run and never
shown (`no_log`) or written down.

## Secrets

No keys or passwords are stored in this repo. Ceph keys are written straight
into Kubernetes Secrets on node1 by `ceph/prepare-ceph.sh`.
