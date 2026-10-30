import json
import subprocess
import sys

DEFAULT_CAPS = {
    "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD", "CAP_NET_RAW", "CAP_SETGID",
    "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE",
}
ARCH = {"arm64", "aarch64", "SCMP_ARCH_AARCH64"}

profile = json.load(open(sys.argv[1]))
table = subprocess.run(["ausyscall", "aarch64", "--dump"], capture_output=True, text=True, check=True).stdout
kernel = {line.split()[1] for line in table.splitlines()[1:] if len(line.split()) == 2}


def applies(rule, caps):
    inc, exc = rule.get("includes", {}), rule.get("excludes", {})
    if inc.get("arches") and not ARCH & set(inc["arches"]):
        return False
    if exc.get("arches") and ARCH & set(exc["arches"]):
        return False
    if inc.get("caps") and not set(inc["caps"]) <= caps:
        return False
    if exc.get("caps") and set(exc["caps"]) & caps:
        return False
    return True


def allowed(caps, conditional=False):
    names = set()
    for rule in profile["syscalls"]:
        if rule["action"] == "SCMP_ACT_ALLOW" and bool(rule.get("args")) == conditional and applies(rule, caps):
            names |= set(rule["names"])
    return names


default = allowed(DEFAULT_CAPS) & kernel
sys_admin = allowed(DEFAULT_CAPS | {"CAP_SYS_ADMIN"}) & kernel
conditional = (allowed(DEFAULT_CAPS, True) & kernel) - default
blocked = sorted(kernel - default - conditional)
print(f"appels système connus sur aarch64 (ausyscall) : {len(kernel)}")
print(f"autorisés par le profil par défaut avec les capabilities par défaut : {len(default)}")
print(f"autorisés selon les arguments : {len(conditional)} ({', '.join(sorted(conditional))})")
print(f"bloqués (ERRNO) : {len(blocked)}")
print(f"débloqués en plus si CAP_SYS_ADMIN : {len(sys_admin - default)} ({', '.join(sorted(sys_admin - default)[:12])}...)")
print("exemples bloqués : " + ", ".join(n for n in blocked if n in {
    "unshare", "setns", "mount", "umount2", "pivot_root", "bpf", "init_module", "finit_module", "delete_module",
    "kexec_load", "reboot", "swapon", "swapoff", "ptrace", "perf_event_open", "keyctl", "add_key", "request_key",
    "open_by_handle_at", "name_to_handle_at", "clock_settime", "settimeofday", "acct", "quotactl", "fanotify_init",
    "userfaultfd", "move_mount", "fsopen", "fsmount", "open_tree", "process_vm_readv", "process_vm_writev"}))
