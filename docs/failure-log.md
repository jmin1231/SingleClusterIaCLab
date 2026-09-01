# Failure Log

What broke, what it actually was, and where the search should have started.

Write an entry when a failure took more than an hour, or when the symptom pointed
somewhere other than the cause. Not every bug — only the ones whose *diagnosis*
is worth carrying forward.

Format: newest at the bottom. What was seen · what it actually was · what
changed.

---

*Nothing yet.*

---

## Two lessons carried over from the previous build

Kept because they are about method rather than about any tool. The original
entries are in git history.

**A fault at one layer surfaces as a plausible bug at every layer above it.** One
hung network interface produced six symptoms over ninety minutes — a name
resolution failure, an IaC destroy error, a hypervisor refusing to disconnect a
host, VMs reported running that no longer existed. Every early hypothesis was a
software one, and every one was wrong.

The order to work in:

1. **Is the platform healthy?** The hypervisor, the host, the network. One
   unhealthy component explains every downstream failure at once and makes the
   rest of the search pointless.
2. **Is the machine healthy?** `journalctl --list-boots`, `journalctl -b -1 -p err`,
   `last -x reboot`, `dmesg`. A boot that ended with no shutdown record is a
   crash, and the last lines of the previous boot usually name it.
3. **Only then, the software.**

**A control plane reports its database, not reality.** An API described three
running VMs for an hour after they had ceased to exist, and both Terraform and
Ansible believed it. Treat any management API's view as a claim to verify, not a
fact.
