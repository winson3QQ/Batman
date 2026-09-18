#!/usr/bin/env bash
# Orchestrator (run from the management host, NOT on a node).
# Starts a voice-like UDP stream m02 -> m01, launches hop2node.sh on BOTH nodes
# near-simultaneously (no time sync — hops are hand-aligned), then collects loss.
# m01 is driven over ahwlan (out-of-band, survives the hop partition); m02 over the mesh.
set -u
SSHO='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8'
M01=${M01:-10.41.167.12}   # manet01 ahwlan (out-of-band control)
M02=${M02:-10.41.1.1}      # manet02 mesh IP
DIR=$(dirname "$0")

scp $SSHO "$DIR/hop2node.sh" root@"$M01":/tmp/hop2node.sh
scp $SSHO "$DIR/hop2node.sh" root@"$M02":/tmp/hop2node.sh

# 1. iperf2 UDP server on m01 (detached with setsid; nohup is absent on the image)
ssh $SSHO root@"$M01" 'pkill iperf 2>/dev/null; sleep 1; setsid iperf -s -u -i 1 >/tmp/iperf_srv.log 2>&1 </dev/null & echo srv_started'
sleep 1
# 2. voice-like client on m02: 200-byte datagrams @ ~62 pps for 20 s
ssh $SSHO root@"$M02" "pkill iperf 2>/dev/null; setsid iperf -c $M01 -u -b 100k -l 200 -t 20 -i 1 >/tmp/iperf_cli.log 2>&1 </dev/null & echo cli_started"
# 3. launch both hop scripts as close to simultaneous as possible
ssh $SSHO root@"$M01" 'setsid sh /tmp/hop2node.sh >/tmp/hop2.out 2>&1 </dev/null & echo m01_hop' &
ssh $SSHO root@"$M02" 'setsid sh /tmp/hop2node.sh >/tmp/hop2.out 2>&1 </dev/null & echo m02_hop' &
wait
echo ">>> launched; waiting 24s for hop sequence + reconverge"
sleep 24
# 4. reconnect, hard-restore 924 on both, collect
ssh $SSHO root@"$M01" 'morse_cli -i wlh0 channel -c 924000 -o 8 -p 2 -n 3 >/dev/null 2>&1; echo "== M01 hop log =="; cat /tmp/hop2.log; echo "== M01 iperf SERVER =="; cat /tmp/iperf_srv.log'
ssh $SSHO root@"$M02" 'morse_cli -i wlh0 channel -c 924000 -o 8 -p 2 -n 3 >/dev/null 2>&1; echo "== M02 hop log =="; cat /tmp/hop2.log; echo "== M02 iperf CLIENT =="; cat /tmp/iperf_cli.log'
