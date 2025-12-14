cat > system_report.sh << 'EOF'
#!/usr/bin/env bash

OUT="system_report.txt"

{
  echo "===== OS ====="
  uname -a
  echo
  cat /etc/os-release 2>/dev/null || echo "no /etc/os-release"
  echo

  echo "===== HOSTNAMECTL ====="
  hostnamectl 2>/dev/null || echo "no hostnamectl"
  echo

  echo "===== CPU (lscpu) ====="
  lscpu
  echo

  echo "===== CPUINFO (/proc/cpuinfo, first CPU) ====="
  awk 'NR==1,/^$/' /proc/cpuinfo
  echo

  echo "===== MEMORY (free -h) ====="
  free -h
  echo

  echo "===== MEMINFO (/proc/meminfo) ====="
  head -n 30 /proc/meminfo
  echo

  echo "===== DISKS (lsblk) ====="
  lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT
  echo

  echo "===== FILESYSTEM USAGE (df -Th) ====="
  df -Th
  echo

  echo "===== PCI DEVICES (lspci) ====="
  lspci
  echo

  echo "===== USB DEVICES (lsusb) ====="
  lsusb 2>/dev/null || echo "no lsusb"
  echo

  echo "===== NETWORK (ip a) ====="
  ip a
  echo

  echo "===== ROUTES (ip r) ====="
  ip r
  echo

} > "$OUT"

echo "Saved report to $OUT"
EOF

chmod +x system_report.sh
./system_report.sh
