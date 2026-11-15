#!/bin/sh
# Prepare MicroCeph for Kubernetes (ceph-csi): an RBD pool, a CephFS
# filesystem, a dedicated least-privilege Ceph user for each, and the
# Kubernetes Secrets the ceph-csi drivers read their keys from.
#
# Run on node1 (it has both 'ceph' and k3s's kubectl), as root:
#   scp ceph/prepare-ceph.sh node1:  &&  ssh -t node1 sudo sh prepare-ceph.sh
#
# Safe to run again: every step checks or reuses what already exists.
# The keys never leave the cluster: they go from Ceph straight into
# Kubernetes Secrets and are never printed or written to a file.
set -e

RBD_POOL=k8s-rbd
FS_NAME=cephfs
KUBECTL="k3s kubectl"

echo "== RBD pool '$RBD_POOL' (block devices, e.g. MySQL's data)"
ceph osd pool create "$RBD_POOL" >/dev/null 2>&1 || true   # no-op if it exists
rbd pool init "$RBD_POOL"
ceph osd pool ls detail | grep "'$RBD_POOL'" | cut -c1-80

echo "== CephFS filesystem '$FS_NAME' (shared folders, e.g. /music)"
if ! ceph fs ls | grep -q "name: $FS_NAME,"; then
    ceph fs volume create "$FS_NAME"          # creates its data + metadata pools
fi
ceph fs subvolumegroup create "$FS_NAME" csi  # the folder group ceph-csi uses
# One MDS becomes active, the other two stay standby. An MDS caches up to
# 4 GB by default, too much on these 6-8 GB nodes; cap it at 512 MB.
ceph config set mds mds_cache_memory_limit 536870912
ceph fs ls

echo "== Ceph users for Kubernetes (least privilege, not client.admin)"
# Block devices: only the k8s-rbd pool.
ceph auth get-or-create client.k8s-rbd \
    mon 'profile rbd' \
    osd "profile rbd pool=$RBD_POOL" \
    mgr "profile rbd pool=$RBD_POOL" >/dev/null
# CephFS: only this filesystem's /volumes area, and full access only in the
# 'csi' group (capabilities as documented in ceph-csi v3.18.2's
# docs/capabilities.md; note 'rwx' on the metadata pool).
ceph auth get-or-create client.k8s-cephfs \
    mgr 'allow rw' \
    osd "allow rwx tag cephfs metadata=$FS_NAME, allow rw tag cephfs data=$FS_NAME" \
    mds "allow r fsname=$FS_NAME path=/volumes, allow rws fsname=$FS_NAME path=/volumes/csi" \
    mon "allow r fsname=$FS_NAME" >/dev/null
ceph auth ls 2>/dev/null | grep -A4 -E '^client\.k8s-' | grep -v key:

echo "== Kubernetes namespaces and Secrets for the ceph-csi drivers"
for ns in ceph-csi-rbd ceph-csi-cephfs; do
    $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
done
# 'create --dry-run | apply' creates or updates the Secret; the key is passed
# straight from Ceph and never shown.
$KUBECTL -n ceph-csi-rbd create secret generic csi-rbd-secret \
    --from-literal=userID=k8s-rbd \
    --from-literal=userKey="$(ceph auth get-key client.k8s-rbd)" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
# The CephFS driver reads adminID/adminKey for creating volumes and
# userID/userKey for mounting them; the same restricted user does both.
CEPHFS_KEY=$(ceph auth get-key client.k8s-cephfs)
$KUBECTL -n ceph-csi-cephfs create secret generic csi-cephfs-secret \
    --from-literal=userID=k8s-cephfs --from-literal=userKey="$CEPHFS_KEY" \
    --from-literal=adminID=k8s-cephfs --from-literal=adminKey="$CEPHFS_KEY" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
unset CEPHFS_KEY

echo "== done"
ceph status | sed -n '2,3p'
