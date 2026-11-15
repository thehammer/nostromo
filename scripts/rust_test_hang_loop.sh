#!/bin/bash
# Repro loop for the Rust test hang (run it in the RWX sandbox):
#   rwx sandbox exec -- env FILTER=ipc::session_manager bash scripts/rust_test_hang_loop.sh 2 2 20
# Args: CPUS TEST_THREADS ITERATIONS. Runs the lib test binary pinned to CPUS
# cores; when libtest reports a test running over 60 s it dumps every thread's
# stack with gdb (needs `sudo apt-get install gdb`) and the pipes each child
# holds, then stops after two bad runs.
# usage: loop.sh <cpus> <threads> <iterations>
set -u
mkdir -p /tmp/repro
cd "$PWD"
BIN=$(cargo test --lib --no-run 2>&1 | sed -n 's/.*Executable unittests src\/lib.rs (\(.*\))/\1/p' | tail -1)
echo "bin=$BIN nproc=$(nproc)"
which gdb eu-stack pstack 2>&1 | head
export RUST_BACKTRACE=0
hung=0
for i in $(seq 1 $3); do
  taskset -c 0-$(($1-1)) timeout -s ABRT 160 "$BIN" ${FILTER:-ipc::session_manager::injected_tests} --test-threads=$2 --nocapture >/tmp/repro/out.$i 2>&1 &
  pid=$!
  # watchdog: after 45s dump stacks
  ( for w in $(seq 1 100); do grep -aq 'running for over' /tmp/repro/out.$i && break; kill -0 $pid 2>/dev/null || break; sleep 3; done; if grep -aq 'running for over' /tmp/repro/out.$i && kill -0 $pid 2>/dev/null; then
      for p in $(pgrep -P $pid); do
        echo "HANG iter $i pid $p"; ls /proc/$p/task | wc -l; ps -eo pid,ppid,stat,wchan:20,cmd --forest | grep -v 'ps -eo' | tail -40
        for t in /proc/$p/task/*; do echo "$(basename $t) $(cat $t/comm) $(cat $t/wchan 2>/dev/null) $(cat $t/stat | cut -d' ' -f3)"; done
        (for q in $p $(pgrep -P $p); do echo "== $q $(tr '\\0' ' ' < /proc/$q/cmdline) state=$(cut -d' ' -f3 /proc/$q/stat)"; ls -l /proc/$q/fd 2>/dev/null | grep -a pipe | awk '{print $9, $10, $11}'; done > /tmp/repro/fds.$i 2>&1; cp /tmp/repro/fds.$i /tmp/repro_fds.txt; sudo -n gdb -p $p -batch -ex "thread apply all bt" 2>&1 | cut -c1-400 > /tmp/repro/gdb.$i; ) 
      done
    fi ) > /tmp/repro/wd.$i 2>&1 &
  wait $pid; rc=$?
  if [ $rc -ne 0 ]; then echo "iter $i rc=$rc"; sleep 2; cat /tmp/repro/wd.$i | head -60; cp /tmp/repro/gdb.$i /tmp/repro_gdb.txt; grep -a -B2 -A3 'running for over' /tmp/repro/out.$i | head -30; grep -a -A3 'panicked at' /tmp/repro/out.$i | head -40 > /tmp/repro_panics.txt; grep -a -A25 '^failures:' /tmp/repro/out.$i | head -60; hung=$((hung+1)); [ $hung -ge 2 ] && break; fi
  rm -f /tmp/repro/out.$i
done
echo "done hung=$hung"
