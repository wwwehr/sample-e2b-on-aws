#!/bin/bash
set -e
FC_BIN=$(find /fc-versions -name firecracker -type f 2>/dev/null | head -1)
KERNEL=$(find /fc-kernels -name vmlinux.bin -type f 2>/dev/null | head -1)
WORKDIR=$(mktemp -d)
ROOTFS="$WORKDIR/rootfs.ext4"
SOCKET="$WORKDIR/fc.sock"
dd if=/dev/zero of="$ROOTFS" bs=1M count=200 2>/dev/null
mkfs.ext4 -q "$ROOTFS"
mkdir -p "$WORKDIR/mnt"
mount "$ROOTFS" "$WORKDIR/mnt"
cp /bin/busybox "$WORKDIR/mnt/"
mkdir -p "$WORKDIR/mnt/bin" "$WORKDIR/mnt/proc" "$WORKDIR/mnt/sys" "$WORKDIR/mnt/dev" "$WORKDIR/mnt/tmp"
cp /bin/busybox "$WORKDIR/mnt/bin/busybox"
ln -s /bin/busybox "$WORKDIR/mnt/bin/sh"
cat > "$WORKDIR/mnt/init" << 'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox echo "=== VM BOOT OK ==="
/bin/busybox echo "Kernel: $(/bin/busybox uname -r)"
/bin/busybox echo "Arch: $(/bin/busybox uname -m)"
/bin/busybox head -3 /proc/meminfo
/bin/busybox echo "=== DONE ==="
/bin/busybox reboot -f
EOF
chmod +x "$WORKDIR/mnt/init"
umount "$WORKDIR/mnt"
echo "Configuring FC..."
$FC_BIN --api-sock "$SOCKET" > "$WORKDIR/stdout.log" 2>&1 &
FC_PID=$!
sleep 1
curl -s --unix-socket "$SOCKET" -X PUT "http://localhost/boot-source" -H "Content-Type: application/json" -d "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 init=/init reboot=k panic=1\"}" > /dev/null
curl -s --unix-socket "$SOCKET" -X PUT "http://localhost/drives/rootfs" -H "Content-Type: application/json" -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}" > /dev/null
curl -s --unix-socket "$SOCKET" -X PUT "http://localhost/machine-config" -H "Content-Type: application/json" -d "{\"vcpu_count\":2,\"mem_size_mib\":256}" > /dev/null
echo "Starting VM..."
curl -s --unix-socket "$SOCKET" -X PUT "http://localhost/actions" -H "Content-Type: application/json" -d "{\"action_type\":\"InstanceStart\"}" > /dev/null
timeout 15 tail --pid=$FC_PID -f /dev/null 2>/dev/null || true
echo "=== VM OUTPUT ==="
cat "$WORKDIR/stdout.log"
kill $FC_PID 2>/dev/null || true
rm -rf "$WORKDIR"
