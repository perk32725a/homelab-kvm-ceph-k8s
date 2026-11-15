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
Redis and HAProxy) lives in its own repo, MusicDB-CS (`k8s/` folder).

## Layout

- `ceph/` – scripts run on a Ceph node (Kubernetes pools, CephFS, users).
- `k8s/ceph-csi/` – ceph-csi drivers and StorageClasses for Kubernetes.

## Secrets

No keys or passwords are stored in this repo. Ceph keys are written straight
into Kubernetes Secrets on node1 by `ceph/prepare-ceph.sh`.
