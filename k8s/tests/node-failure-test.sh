#!/bin/sh
# Node-failure test for the music database app with MySQL's data on Ceph RBD.
# Run on the Mac:   k8s/tests/node-failure-test.sh
#
# 1. Steady requests (~2/s) through HAProxy; cluster state recorded every 3 s.
# 2. At +15 s, the node running MySQL fails:
#      MODE=crash (default): UTM force stop, like pulling the power cable
#      MODE=poweroff:        a clean 'systemctl poweroff' inside the node
# 3. MySQL does NOT move by itself: Kubernetes won't start a second mysql-0
#    while the first one's node is only "unreachable" (it might still be
#    writing to the disk). Once the node is confirmed down (UTM says stopped,
#    Kubernetes says not Ready) and at least TAINT_AFTER seconds have passed,
#    the script fences it with the out-of-service taint:
#      kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
#    Kubernetes then force-deletes the node's pods and detaches its volumes,
#    and mysql-0 starts on another node with its RBD volume.
# 4. Once the site has served 200s for 30 s in a row: the node is started
#    again, the taint removed, and a summary printed.
#
# Settings: NODE (default: wherever mysql-0 runs), MODE (crash|poweroff),
# TAINT_AFTER (default 120 s), MAX (give up after this many seconds, default 900).
set -e
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/lab-k3s.yaml}"
U=/Applications/UTM.app/Contents/MacOS/utmctl
LB=http://node1:8080
NS=musicdb
MODE=${MODE:-crash}
TAINT_AFTER=${TAINT_AFTER:-120}
MAX=${MAX:-900}
TAINT=node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
OUT=${OUT:-${TMPDIR:-/tmp}/node-failure-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; REQ=$OUT/requests.log; STATE=$OUT/state.log; EVT=$OUT/events.log
: > "$REQ"; : > "$STATE"; : > "$EVT"

# Lookups end in '|| true': while the fenced mysql-0 is deleted and recreated
# there is briefly no pod, kubectl returns an error, and with 'set -e' that
# error would end the script (it did on the first run, 2026-11-15, right
# after the fence, leaving the node off and still tainted).
counts() { kubectl -n $NS exec mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -N -u musicdb MusicDB -e "SELECT (SELECT COUNT(*) FROM Music), (SELECT COUNT(*) FROM Songs);"' 2>/dev/null | tr '\t' '/' || true; }
mysql_node() { kubectl -n $NS get pod mysql-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || true; }

# ---- checks before starting
NODE=${NODE:-$(mysql_node)}
[ -n "$NODE" ] || { echo "mysql-0 not found"; exit 1; }
echo "== before: mysql-0 on $NODE; data (albums/songs) $(counts); mode=$MODE; logs in $OUT"
NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"' | wc -l | tr -d ' ')
[ "$NOTREADY" = 0 ] || { echo "a node is not Ready; aborting"; kubectl get nodes; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' $LB/)" = 200 ] || { echo "site not answering 200; aborting"; exit 1; }
BEFORE=$(counts)
PV=$(kubectl -n $NS get pvc data-mysql-0 -o jsonpath='{.spec.volumeName}')

T0=$(date +%s); el() { echo $(( $(date +%s) - T0 )); }
event() { echo "$(el)s $*" | tee -a "$EVT"; }

# ---- background: requests and state snapshots
( while :; do
    r=$(curl -s -o /dev/null -D - -w '\nCODE %{http_code} %{time_total}' --max-time 10 $LB/ | tr -d '\r')
    echo "$(el) $(echo "$r" | awk '/^CODE/{print $2, $3}') $(echo "$r" | awk 'tolower($1)=="x-served-by:"{print $2}')" >> "$REQ"
    sleep 0.5
  done ) & LOAD=$!
( while :; do
    nr=$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    utm=$($U status $NODE 2>/dev/null)
    my=$(kubectl -n $NS get pod mysql-0 -o jsonpath='{.spec.nodeName}:{.status.phase}/{.status.containerStatuses[0].ready}{.metadata.deletionTimestamp}' 2>/dev/null || echo none)
    va=$(kubectl get volumeattachment -o jsonpath="{range .items[?(@.spec.source.persistentVolumeName==\"$PV\")]}{.spec.nodeName}={.status.attached} {end}" 2>/dev/null)
    hap=$(curl -s --max-time 3 "http://node1:8404/;csv" | awk -F, '$1=="app" && $2 ~ /^app[0-9]$/ && $18 !~ /MAINT/ {printf "%s:%s ", $2, $18}')
    echo "$(el)s $NODE ready=$nr utm=$utm | mysql-0=$my | rbd attached: $va| haproxy: $hap" >> "$STATE"
    sleep 3
  done ) & MON=$!
trap 'kill $LOAD $MON 2>/dev/null || true' EXIT

# ---- the failure
sleep 15
if [ "$MODE" = poweroff ]; then
    event ">>> $NODE: clean poweroff"; $U exec $NODE --cmd /usr/bin/systemctl poweroff >/dev/null 2>&1 || true
else
    event ">>> $NODE: force stop (power cut)"; $U stop --force $NODE >/dev/null 2>&1 || true
fi

# ---- fencing: only once the node is confirmed down
while :; do
    t=$(el); [ $t -ge $MAX ] && { event "gave up waiting at ${t}s"; break; }
    nr=$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$($U status $NODE 2>/dev/null)" = stopped ] && [ "$nr" != True ] && [ $t -ge $TAINT_AFTER ]; then
        event ">>> confirmed down (UTM: stopped, Kubernetes Ready=$nr): fencing with the out-of-service taint"
        kubectl taint node $NODE $TAINT >/dev/null; break
    fi
    sleep 2
done

# ---- recovery: mysql-0 Ready on another node, and 30 s of clean 200s
seen_new=""; ok_since=""
while :; do
    t=$(el); [ $t -ge $MAX ] && { event "gave up waiting at ${t}s"; break; }
    n=$(mysql_node); rd=$(kubectl -n $NS get pod mysql-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
    [ -z "$seen_new" ] && [ -n "$n" ] && [ "$n" != "$NODE" ] && { seen_new=1; event "mysql-0 scheduled on $n"; }
    [ -n "$seen_new" ] && [ "$rd" = true ] && [ -z "$ok_since" ] && { event "mysql-0 Ready on $n"; ok_since=$t; }
    if [ -n "$ok_since" ]; then
        last=$(tail -60 "$REQ" | awk -v s=$((t-30)) '$1>=s' )
        if [ -n "$last" ] && ! echo "$last" | awk '{print $2}' | grep -qv '^200$'; then event "site: 30 s of 200s"; break; fi
    fi
    sleep 2
done
kill $LOAD $MON 2>/dev/null || true; trap - EXIT
AFTER=$(counts)

# ---- bring the node back and remove the fence
event ">>> starting $NODE"; $U start $NODE >/dev/null 2>&1 || true
for i in $(seq 1 60); do [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = True ] && break; sleep 3; done
event "$NODE Ready again; removing the out-of-service taint"
kubectl taint node $NODE "$TAINT-" >/dev/null 2>&1 || true

# ---- summary
echo
echo "== summary (logs in $OUT)"
cat "$EVT"
echo "requests: $(wc -l < "$REQ" | tr -d ' ') total; $(awk '{print $2}' "$REQ" | sort | uniq -c | awk '{printf "%s x %s  ", $1, $2}')"
awk '$2!=200{print $1}' "$REQ" | sort -n | sed -n '1p;$p' | tr '\n' ' ' | awk '{if ($1!="") print "non-200 from " $1 "s to " $2 "s"}'
echo "slowest: $(sort -k3 -n "$REQ" | tail -1 | awk '{print $3 "s at " $1 "s"}')"
echo "data before: $BEFORE   after: $AFTER   (albums/songs)"
echo "mysql-0 now on: $(mysql_node)"
kubectl get nodes --no-headers | awk '{print "node " $1 ": " $2}'
