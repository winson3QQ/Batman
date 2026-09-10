#!/bin/sh
# deep-sample.sh — per-process + per-IRQ + per-softirq CPU sampler for busybox
# (OpenWrt nodes have no python3). Pure ash + awk, zero deps.
#
# Attributes CPU time to processes, hardware IRQs and softirqs during a soak so
# you can see WHERE the sys/softirq time goes and whether there's room to tune.
#
#   OUT=/tmp/soakprof IVL=10 CPU=3 ./deep-sample.sh &
#   touch /tmp/soakprof/STOP     # clean stop
#
# Writes into $OUT (put on tmpfs): sys.csv proc.csv irq.csv softirq.csv
# Self-measuring: this script's own awk PID shows up in proc.csv.
OUT="${OUT:-/tmp/soakprof}"
IVL="${IVL:-10}"
CPU="${CPU:--1}"
HZ="${HZ:-100}"           # USER_HZ; 100 on these kernels
mkdir -p "$OUT"

# best-effort pin to one core so the sampler stays off the packet path
if [ "$CPU" -ge 0 ] 2>/dev/null; then
  if command -v taskset >/dev/null 2>&1; then
    taskset -pc "$CPU" $$ >/dev/null 2>&1
  fi
fi

exec awk -v OUT="$OUT" -v IVL="$IVL" -v HZ="$HZ" 'BEGIN{
  NCPU=0
  while(("grep -c ^processor /proc/cpuinfo" | getline n)>0){NCPU=n}
  close("grep -c ^processor /proc/cpuinfo")
  if(NCPU<1)NCPU=4

  sysf=OUT"/sys.csv"; procf=OUT"/proc.csv"; irqf=OUT"/irq.csv"; sirqf=OUT"/softirq.csv"
  # headers only if empty
  if((getline _ < sysf)<=0){
    h="ts,dt_s,all_busy,all_user,all_sys,all_irq,all_softirq,all_iowait"
    for(i=0;i<NCPU;i++) h=h",cpu"i"_busy,cpu"i"_sys,cpu"i"_irq,cpu"i"_softirq"
    print h > sysf
    print "ts,pid,comm,cpu_pct,dj" > procf
    hh="ts,irq,desc,total"; for(i=0;i<NCPU;i++) hh=hh",c"i; print hh > irqf
    hh="ts,kind,total"; for(i=0;i<NCPU;i++) hh=hh",c"i; print hh > sirqf
  }
  close(sysf)

  havePrev=0
  while(1){
    # STOP file? (>=0 so an EMPTY `touch`ed STOP also stops; getline is 0 on empty, -1 if absent)
    if((getline _ < (OUT"/STOP"))>=0){ close(OUT"/STOP"); print "stopped"; exit }
    close(OUT"/STOP")

    ts=strftime("%Y-%m-%d %H:%M:%S")
    now=systime()

    # ---- /proc/stat per-cpu ----
    delete cur_stat
    f="/proc/stat"
    while((getline line < f)>0){
      if(line ~ /^cpu/){ split(line,a," "); cur_stat[a[1]]=a[2]" "a[3]" "a[4]" "a[5]" "a[6]" "a[7]" "a[8] }
      else break
    }
    close(f)

    # ---- /proc/softirqs ----
    delete cur_sirq
    f="/proc/softirqs"; getline line < f   # header
    while((getline line < f)>0){
      nf=split(line,a," "); name=a[1]; sub(/:$/,"",name)
      v=""; for(i=2;i<=1+NCPU;i++) v=v" "a[i]; cur_sirq[name]=v
    }
    close(f)

    # ---- /proc/interrupts ----
    delete cur_irq; delete irq_desc
    f="/proc/interrupts"; getline line < f  # header
    while((getline line < f)>0){
      nf=split(line,a," "); name=a[1]; sub(/:$/,"",name)
      v=""; ok=1
      for(i=2;i<=1+NCPU;i++){ if(a[i] ~ /^[0-9]+$/) v=v" "a[i]; else {ok=0; break} }
      if(!ok) continue
      d=""; for(i=2+NCPU;i<=nf;i++) d=d" "a[i]; gsub(/,/," ",d)
      cur_irq[name]=v; irq_desc[name]=d
    }
    close(f)

    # ---- per-process /proc/<pid>/stat ----
    delete cur_pj; delete cur_comm
    cmd="ls -1 /proc 2>/dev/null"
    while((cmd|getline pid)>0){
      if(pid ~ /^[0-9]+$/){
        sf="/proc/"pid"/stat"
        if((getline line < sf)>0){
          # comm is in parens (may hold spaces); utime=field14 stime=field15
          lp=index(line,"("); rp=0; L=length(line)
          for(k=L;k>=1;k--){ if(substr(line,k,1)==")"){rp=k;break} }
          comm=substr(line,lp+1,rp-lp-1)
          rest=substr(line,rp+2)
          m=split(rest,b," ")   # b[1]=state(f3) ... utime=f14=b[12] stime=f15=b[13]
          cur_pj[pid]=b[12]+b[13]; cur_comm[pid]=comm
        }
        close(sf)
      }
    }
    close(cmd)

    if(havePrev){
      dt=now-prev_t; if(dt<=0)dt=IVL

      # sys.csv
      row=ts","dt
      split(cur_stat["cpu"],c," "); split(prev_stat["cpu"],p," ")
      tot=0; for(i=1;i<=7;i++) tot+=c[i]-p[i]; if(tot<1)tot=1
      du=(c[1]-p[1])+(c[2]-p[2]); ds=c[3]-p[3]; di=c[6]-p[6]; dsq=c[7]-p[7]; dio=c[5]-p[5]; didle=c[4]-p[4]
      row=row","f2(100*(tot-didle)/tot)","f2(100*du/tot)","f2(100*ds/tot)","f2(100*di/tot)","f2(100*dsq/tot)","f2(100*dio/tot)
      for(ci=0;ci<NCPU;ci++){
        k="cpu"ci
        if((k in cur_stat)&&(k in prev_stat)){
          split(cur_stat[k],c," "); split(prev_stat[k],p," ")
          tot=0; for(i=1;i<=7;i++) tot+=c[i]-p[i]; if(tot<1)tot=1
          ds=c[3]-p[3]; di=c[6]-p[6]; dsq=c[7]-p[7]; didle=c[4]-p[4]
          row=row","f2(100*(tot-didle)/tot)","f2(100*ds/tot)","f2(100*di/tot)","f2(100*dsq/tot)
        } else row=row",,,,"
      }
      print row >> sysf

      # proc.csv (only pids with delta>0)
      denom=HZ*dt; if(denom<=0)denom=1
      for(pid in cur_pj){
        if(pid in prev_pj){
          dj=cur_pj[pid]-prev_pj[pid]
          if(dj>0) printf "%s,%s,%s,%s,%d\n", ts,pid,cur_comm[pid],f2(100*dj/denom),dj >> procf
        }
      }

      # irq.csv
      for(name in cur_irq){
        if(name in prev_irq){
          split(cur_irq[name],c," "); split(prev_irq[name],p," ")
          t=0; line=""
          for(i=1;i<=NCPU;i++){ d=c[i]-p[i]; t+=d; line=line","d }
          if(t>0){ ds=irq_desc[name]; sub(/^ +/,"",ds); printf "%s,%s,%s,%d%s\n", ts,name,ds,t,line >> irqf }
        }
      }
      # softirq.csv
      for(name in cur_sirq){
        if(name in prev_sirq){
          split(cur_sirq[name],c," "); split(prev_sirq[name],p," ")
          t=0; line=""
          for(i=1;i<=NCPU;i++){ d=c[i]-p[i]; t+=d; line=line","d }
          if(t>0) printf "%s,%s,%d%s\n", ts,name,t,line >> sirqf
        }
      }
      fflush()
    }

    # copy cur->prev
    delete prev_stat; for(k in cur_stat) prev_stat[k]=cur_stat[k]
    delete prev_sirq; for(k in cur_sirq) prev_sirq[k]=cur_sirq[k]
    delete prev_irq;  for(k in cur_irq)  prev_irq[k]=cur_irq[k]
    delete prev_pj;   for(k in cur_pj)   prev_pj[k]=cur_pj[k]
    prev_t=now; havePrev=1
    system("sleep " IVL)
  }
}
function f2(x){ return sprintf("%.2f",x) }
'
