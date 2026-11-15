#!/bin/sh
# Test the Ceph StorageClasses with throwaway volumes (namespace storage-test).
#   k8s/tests/storage-test.sh           run the tests (from the repo folder, on the Mac)
#   k8s/tests/storage-test.sh cleanup   delete the test namespace, then show what's left
#
# 1. RBD:    a pod on node1 writes to a ceph-rbd volume; the pod is deleted and
#            a new pod on node2 mounts the same volume and checks the data.
# 2. CephFS: two pods, on node1 and node3, mount one cephfs volume at the same
#            time; each writes a file and reads the other's.
set -e
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/lab-k3s.yaml}"
NS=storage-test
DIR=$(cd "$(dirname "$0")" && pwd)
K="kubectl -n $NS"

# run_pod NAME NODE CLAIM SHELL-COMMAND: one-shot busybox pod on NODE with
# CLAIM mounted at /data; waits for it to finish and prints its output.
run_pod() {
    cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  nodeName: $2
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.37
      command: ["sh", "-c", "$4"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: $3}
EOF
    $K wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=180s >/dev/null
    $K logs "$1" | sed "s/^/   [$1 on $2] /"
}

if [ "$1" = cleanup ]; then
    RBD_PV=$($K get pvc rbd-test -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    RBD_IMAGE=$(kubectl get pv "$RBD_PV" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || true)
    kubectl delete namespace $NS --wait=true
    echo "== left behind:"
    kubectl get pv 2>/dev/null | awk -v pv="$RBD_PV" 'NR==1 || $1==pv'
    echo
    echo "The CephFS volume (StorageClass reclaimPolicy Delete) was removed with its claim."
    echo "The RBD volume (reclaimPolicy Retain) is 'Released' and its image is still in Ceph."
    echo "To remove it for good:"
    echo "  kubectl delete pv $RBD_PV"
    echo "  ssh -t node1 sudo rbd rm k8s-rbd/$RBD_IMAGE"
    exit 0
fi

echo "== creating the test namespace and two claims"
kubectl apply -f "$DIR/storage-test.yaml" >/dev/null
$K wait --for=jsonpath='{.status.phase}'=Bound pvc/rbd-test pvc/cephfs-test --timeout=120s >/dev/null
$K get pvc
for c in rbd-test cephfs-test; do
    pv=$($K get pvc $c -o jsonpath='{.spec.volumeName}')
    echo "   $c -> Ceph: $(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.pool}{.spec.csi.volumeAttributes.fsName} {.spec.csi.volumeAttributes.imageName}{.spec.csi.volumeAttributes.subvolumeName}')"
done

echo
echo "== 1. RBD: write on node1, read on node2"
run_pod rbd-writer node1 rbd-test \
  'echo written on $(hostname) at $(date) > /data/hello.txt; dd if=/dev/urandom of=/data/random.bin bs=1M count=20 2>/dev/null; md5sum /data/random.bin | cut -d\" \" -f1 > /data/random.md5; echo wrote hello.txt and 20 MB random.bin, md5 $(cat /data/random.md5)'
$K delete pod rbd-writer --wait=true >/dev/null
echo "   writer pod deleted; the volume detaches from node1"
run_pod rbd-reader node2 rbd-test \
  'echo read: $(cat /data/hello.txt); [ $(md5sum /data/random.bin | cut -d\" \" -f1) = $(cat /data/random.md5) ] && echo random.bin md5 matches || echo random.bin md5 DIFFERS'
echo "   attached to: $(kubectl get volumeattachment -o jsonpath="{range .items[?(@.spec.source.persistentVolumeName==\"$($K get pvc rbd-test -o jsonpath='{.spec.volumeName}')\")]}{.spec.nodeName} (attached={.status.attached}){end}")"
$K delete pod rbd-reader --wait=true >/dev/null

echo
echo "== 2. CephFS: two pods on node1 and node3 share one volume at the same time"
for n in node1 node3; do
cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: cephfs-$n}
spec:
  nodeName: $n
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.37
      command: ["sh", "-c", "echo from \$(hostname) on $n > /data/from-$n.txt; sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: cephfs-test}
EOF
done
$K wait --for=condition=Ready pod/cephfs-node1 pod/cephfs-node3 --timeout=180s >/dev/null
sleep 2
echo "   both running at once: $($K get pods --no-headers -o custom-columns=N:.metadata.name,NODE:.spec.nodeName,S:.status.phase | awk '{printf "%s@%s:%s  ", $1, $2, $3}')"
echo "   node1's pod sees: $($K exec cephfs-node1 -- sh -c 'ls /data | tr "\n" " "; cat /data/from-node3.txt')"
echo "   node3's pod sees: $($K exec cephfs-node3 -- sh -c 'ls /data | tr "\n" " "; cat /data/from-node1.txt')"
$K delete pod cephfs-node1 cephfs-node3 --wait=true >/dev/null

echo
echo "== done. The claims are kept for a look from the Ceph side; then run:"
echo "   $0 cleanup"
