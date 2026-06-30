# Lab 5: QuickNotes in a Vagrant VM

A note on the platform first. The lab assumes VirtualBox 7.1 with an amd64 Ubuntu box. My
laptop is an Apple Silicon MacBook Air (M4, arm64) on macOS 26.5, and VirtualBox cannot run
amd64 guests on Apple Silicon. Oracle ships an arm64 host build of VirtualBox, but it does not
execute x86-64 guests, because it is a virtualizer and not an emulator. So I run the VM with
VMware Fusion instead (the `vmware_desktop` provider; Fusion Pro is free now) on the same
`bento/ubuntu-24.04` box, which has an arm64 build. I kept a `virtualbox` block in the
Vagrantfile so that a grader on an amd64 machine gets the same VM from the same file, and the Go
step in the provisioner picks amd64 or arm64 on its own. All the output below comes from real
runs on the M4.

## Objective

Boot an Ubuntu 24.04 VM from a Vagrantfile at the repo root, install Go 1.24.5 in it, build
QuickNotes inside the guest and keep it running, and forward a host port to it so that one
`vagrant up` gives a working API. Then show the snapshot save, break and restore cycle, and
compare the VM against the same app running in a Docker container.

## Environment

| Component | Value |
|-----------|-------|
| Host hardware | MacBook Air, Apple M4 (arm64), 24 GB RAM |
| Host OS | macOS 26.5.1 |
| Hypervisor | VMware Fusion 13.6.x (free Pro) |
| Vagrant | 2.4.9 with vagrant-vmware-desktop 3.0.5 and the VMware Utility 1.0.24 |
| Box | bento/ubuntu-24.04, pinned to 202510.26.0 (arm64 build) |
| Guest | Ubuntu 24.04 LTS |
| Go | 1.24.5 (installed by the provisioner) |

## What the Vagrantfile does

* One file, two providers: `vmware_desktop` is what runs on the M4, and a `virtualbox` block is
  there for an amd64 grader. The same Bento box picks the right architecture and provider.
* The box version is pinned and `box_check_update` is off, so the box never changes under me.
* Port 8080 in the guest is forwarded to 127.0.0.1:18080 on the host, with `auto_correct` off so
  it fails loudly if 18080 is taken instead of quietly using another port.
* `./app` is synced into the guest with rsync.
* The VM is capped at 2 vCPUs and 1024 MB of RAM.
* The shell provisioner installs Go 1.24.5 (picking amd64 or arm64, and skipping the download if
  it is already there), builds the binary to /usr/local/bin, and runs QuickNotes as a systemd
  service. Source lives in /opt/quicknotes/app, the binary in /usr/local/bin, and the data in
  /var/lib/quicknotes.

## Vagrantfile

```ruby
# Vagrantfile for Lab 5: QuickNotes in a VM.
#
# Built and tested on Apple Silicon (M4, arm64) with the vmware_desktop provider, because
# VirtualBox cannot run amd64 guests on Apple Silicon. The virtualbox block is kept so an
# amd64 host (a grader) gets an equivalent VM from this same file; bento/ubuntu-24.04 picks
# the architecture and provider, and the provisioner detects the architecture itself.

Vagrant.configure("2") do |config|
  config.vm.box              = "bento/ubuntu-24.04"
  config.vm.box_version      = "202510.26.0"
  config.vm.box_check_update = false                 # don't let the box float between runs
  config.vm.hostname         = "quicknotes-vm"

  # Host-local only: 127.0.0.1:18080 to guest 8080 (NAT with a forwarded port, not bridged).
  # auto_correct:false means it fails if 18080 is taken instead of silently remapping.
  config.vm.network "forwarded_port", guest: 8080, host: 18080, host_ip: "127.0.0.1", auto_correct: false

  # One-way host-to-guest sync. Works the same under both providers and avoids the flaky
  # VMware shared folder on arm64.
  config.vm.synced_folder "./app", "/opt/quicknotes/app", type: "rsync"

  # What actually runs on Apple Silicon.
  config.vm.provider "vmware_desktop" do |v|
    v.vmx["numvcpus"]             = "2"
    v.vmx["memsize"]              = "1024"
    v.vmx["ethernet0.virtualDev"] = "vmxnet3"  # the old e1000 NIC hangs at boot on Apple Silicon
  end

  # For amd64 graders (not used on Apple Silicon).
  config.vm.provider "virtualbox" do |vb|
    vb.cpus   = 2
    vb.memory = 1024
  end

  # Install pinned Go, build the binary, and run it as a systemd service so that a single
  # vagrant up leaves a running app that also comes back after a reboot.
  config.vm.provision "shell", inline: <<~SHELL
    set -euo pipefail
    GO_VERSION=1.24.5

    # install pinned Go (detect arch, skip if already present)
    if ! command -v curl >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl; fi
    case "$(uname -m)" in
      x86_64)  GOARCH=amd64 ;;
      aarch64) GOARCH=arm64 ;;
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
    if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
      curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
      rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    fi
    ln -sf /usr/local/go/bin/go /usr/local/bin/go   # so it is on PATH for non-login shells too

    # build the binary and make a data directory
    install -d -o vagrant -g vagrant /var/lib/quicknotes
    (cd /opt/quicknotes/app && /usr/local/go/bin/go build -o /usr/local/bin/quicknotes .)

    # run QuickNotes as a systemd service
    cat >/etc/systemd/system/quicknotes.service <<'UNIT'
[Unit]
Description=QuickNotes API
After=network.target

[Service]
User=vagrant
Environment=ADDR=:8080
Environment=DATA_PATH=/var/lib/quicknotes/notes.json
Environment=SEED_PATH=/opt/quicknotes/app/seed.json
ExecStart=/usr/local/bin/quicknotes
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now quicknotes.service
    sleep 2
    /usr/local/go/bin/go version
    systemctl is-active quicknotes.service
  SHELL
end
```

## How to run

```bash
vagrant up                                   # boot, install Go, build, start the service
curl -s localhost:18080/health               # {"notes":4,"status":"ok"}
vagrant ssh -c 'systemctl status quicknotes' # check the service inside the guest
vagrant snapshot save clean-provisioned      # used in Task 2
```

## Task 1: boot the VM and run QuickNotes

The box (bento/ubuntu-24.04 202510.26.0, arm64) downloads on the first `vagrant up` and is cached
after that. The first lines of the run look like this:

```
Bringing machine 'default' up with 'vmware_desktop' provider...
==> default: Cloning VMware VM: 'bento/ubuntu-24.04'. This can take some time...
==> default: Starting the VMware VM...
==> default: Waiting for the VM to receive an address...
==> default: Forwarding ports...
    default: -- 8080 => 18080
    default: -- 22 => 2222
==> default: Waiting for machine to boot. This may take a few minutes...
==> default: Rsyncing folder: /Users/.../app/ => /opt/quicknotes/app
==> default: Running provisioner: shell...
    default: go version go1.24.5 linux/arm64
    default: active
```

### Verifying it

A single `vagrant up` leaves the app running, so there is no manual build or start step:

```
$ vagrant ssh -c 'go version'
go version go1.24.5 linux/arm64

$ vagrant ssh -c 'systemctl is-active quicknotes'
active

$ vagrant ssh -c 'systemctl --no-pager status quicknotes | head -n 6'
* quicknotes.service - QuickNotes API
     Loaded: loaded (/etc/systemd/system/quicknotes.service; enabled; preset: enabled)
     Active: active (running) since Tue 2026-06-30 16:30:01 UTC; 44s ago
   Main PID: 3681 (quicknotes)
      Tasks: 7 (limit: 1008)
     Memory: 1.1M (peak: 1.4M)

$ vagrant ssh -c 'curl -s localhost:8080/health'     # inside the guest
{"notes":4,"status":"ok"}

$ curl -is localhost:18080/health                     # from the host, through the forward
HTTP/1.1 200 OK
Content-Type: application/json
Date: Tue, 30 Jun 2026 16:30:47 GMT
Content-Length: 26

{"notes":4,"status":"ok"}
```

### Design questions

**(a) Which synced folder type and why.**
I used rsync. Vagrant can also use the VirtualBox or VMware shared folders, NFS, or SMB. rsync
made the most sense here. It does not depend on the provider, so the one line works for both my
vmware_desktop run and the virtualbox block. The VMware shared folder is unreliable on Apple
Silicon. And it needs no NFS exports or SMB login. The downside is that rsync copies one way
(host to guest) and only when I run vagrant up, reload, or vagrant rsync, so changes made inside
the guest do not come back and host edits are not visible until the next sync. That is fine here,
because the provisioner builds the binary from the source once and nothing edits the source in the VM.

**(b) NAT, bridged, or host-only, and why loopback forwarding is safer than bridged.**
I used the default NAT networking with a forwarded port. With a bridged adapter the VM would get
its own address on the physical network, so QuickNotes on port 8080 would be reachable by every
other device on the LAN with no authentication. With NAT and host_ip set to 127.0.0.1 the port is
only published on the host's loopback, so only this laptop can reach localhost:18080 and nothing
leaves the machine. Host-only would also keep it private, but you still need a forward or route to
reach the app from the host, so NAT with a forward is the simpler option.

**(c) Which provisioner and why.**
The shell provisioner. The work is small: install a specific Go version, build one binary, and
write a systemd unit. That is a few lines of bash with no extra dependencies. Ansible or
ansible_local would need Ansible on the host or guest, and Puppet or Chef need their own agents,
which is more than this needs. Lab 7 brings in Ansible, where configuring real machines is worth
that setup.

**(d) Why pin Go to 1.24.5 instead of 1.24.**
"1.24" is a moving target: it resolves to whatever the newest patch is on the day you provision.
Two people, or the same VM rebuilt a month later, can quietly get different compilers, which
breaks the reproducibility the lab asks for. Pinning 1.24.5 means every vagrant up installs the
exact same Go. It is the same idea as pinning the CI actions by version in Lab 3.

## Task 2: snapshots (save, break, restore)

Running the app as a service makes the break easy to see: breaking the VM takes QuickNotes down,
and the restore brings it back, checked from the host.

```
$ vagrant snapshot save clean-provisioned
==> default: Snapshotting VM as 'clean-provisioned'...
$ vagrant snapshot list
clean-provisioned

# break it: stop the service and delete Go and the built binary
$ vagrant ssh -c 'sudo systemctl stop quicknotes; sudo rm -rf /usr/local/go /usr/local/bin/go /usr/local/bin/quicknotes'
broken

# confirm it is broken
$ vagrant ssh -c 'systemctl is-active quicknotes; go version'
service: inactive
go: bash: line 1: go: command not found
$ curl -s localhost:18080/health        # from the host
(curl exit 28, no response; the service is down)

# restore, timed
$ time vagrant snapshot restore clean-provisioned
==> default: Restoring the snapshot 'clean-provisioned'...
==> default: Starting the VMware VM...
==> default: Waiting for machine to boot. This may take a few minutes...
==> default: Machine booted and ready!
vagrant snapshot restore clean-provisioned   4.54s user 0.74s system 11% cpu   45.098 total

# confirm it recovered
$ vagrant ssh -c 'systemctl is-active quicknotes; go version'
service: active
go version go1.24.5 linux/arm64
$ curl -is localhost:18080/health        # from the host
HTTP/1.1 200 OK
{"notes":4,"status":"ok"}
```

The restore took about 45 seconds end to end. That number includes Vagrant reverting the snapshot,
restarting the VM, waiting for SSH, and setting the port forward back up; the revert itself is a
small part of it. Because VMware took a live snapshot, the running service comes back with the VM,
so the health check passes right after the restore. (Vagrant prints a harmless warning about an
ethernet0.pcislotnumber VMX setting during the restore; networking still comes up correctly.)

### Design questions

**(e) Why snapshots are not backups.**
A snapshot is a point-in-time difference stored on the same disk, in the same machine, next to the
base image. It does nothing for you if the disk or the laptop dies, or if the machine is lost or
stolen, because the snapshot goes with the base image. It does not help if ransomware or a stray
rm removes the VM directory, since the snapshots go with it. And it is not an off-site or long-term
copy, so there is no history to restore from once the VM is gone. A backup is a separate copy kept
somewhere else; a snapshot is just a quick local undo.

**(f) Copy-on-write, and 10 snapshots versus 1.**
Snapshots in VMware and VirtualBox are copy-on-write. Taking one freezes the current disk as
read-only and writes later changes into a new file, so it does not copy the whole disk. Ten
snapshots are not ten times the size; they are the base image plus ten difference files, and each
file only holds the blocks that changed after it was taken, so the total is roughly the base plus
the sum of those changes. The real cost of keeping many is not a multiplied size but that the
difference files keep growing as you write, and a read may have to walk back through the chain to
the base, which slows the VM down as the chain gets longer.

**(g) When snapshotting is an antipattern.**
When you treat snapshots as long-term checkpoints and let the chain grow long. Each extra link
makes reads slower, makes things more fragile (corrupt one difference file and everything after it
is lost), and uses more disk over time. Snapshots are meant to be short-lived: take one before a
risky change, then either delete it (which merges the change in) or roll back, and do it soon.
Keeping dozens of old snapshots as a stand-in for backups or history is the antipattern; that is
what backups and Git are for. It also fits "cattle, not pets": instead of nursing one VM with a
long snapshot chain, throw it away and rebuild from the Vagrantfile.

## Bonus: VM versus container

All numbers were taken in one session on the same hardware (Apple M4, macOS 26.5).

### The Vagrant VM (idle, service running)

```
$ vagrant ssh -c 'free -h'
               total        used        free      shared  buff/cache   available
Mem:           953Mi       280Mi       253Mi       1.1Mi       516Mi       672Mi

$ vagrant ssh -c 'ps -A --no-headers | wc -l'
229                                  # the whole OS process table, kernel threads included

$ du -sh .vagrant/machines/default/vmware_desktop/
903M                                 # the instance disk (a CoW clone; the shared base box is extra)

# cold boot (boot only, already provisioned). systemd starts the service on boot:
$ time vagrant halt   ->  4.131 total
$ time vagrant up     -> 48.514 total
$ curl -s localhost:18080/health     # after the cold boot, no manual step
{"notes":4,"status":"ok"}
```

### The Docker container (same app)

```
$ docker run -d -p 28080:8080 -v "$PWD/app:/src" -w /src golang:1.24 \
    sh -c 'go build -o /tmp/qn && /tmp/qn'
$ curl -s localhost:28080/health
{"notes":8,"status":"ok"}

$ docker stats --no-stream
CONTAINER ID   NAME              CPU %   MEM USAGE / LIMIT    MEM %   PIDS
23f4fb43ddb3   boring_driscoll   0.00%   21.5MiB / 11.67GiB   0.18%   9

$ docker top <id>                    # 2 processes (the sh wrapper and /tmp/qn)
$ docker images golang:1.24 --format '{{.Size}}'
1.33GB
$ docker stop <id> && time docker start <id>
real    0m0.070s
```

### Comparison

| Dimension          | Vagrant VM                       | Docker container              |
|--------------------|----------------------------------|-------------------------------|
| Cold start         | about 48.5 s                     | about 0.07 s                  |
| Idle RAM           | 280 MiB used, 953 MiB reserved   | 21.5 MiB                      |
| On-disk size       | 903 MB instance (plus base box)  | 1.33 GB (golang:1.24 image)   |
| Process count      | 229 (whole OS)                   | 2                             |

The two biggest gaps are the cold start (about 0.07 s for the container against about 48 s for the
VM) and the process count (2 against 229). The VM boots a whole Ubuntu userland, systemd and every
daemon plus kernel threads, just to run one Go binary, while the container is basically that binary
reusing the host's kernel. Memory tells the same story: about 22 MiB used by the container against
about 280 MiB in the VM, and the VM also reserves its full 1 GB up front. The one number that does
not favor the container is disk, and only because the comparison is unfair: the VM instance is a
thin copy-on-write clone at 903 MB, while the 1.33 GB is the full golang:1.24 image used as the
runtime. A slim or multistage image (Lab 6) would bring that down to tens of MB and flip the result.
So a VM is the right tool when you need real isolation, your own kernel, kernel-level features, or a
full multi-service OS, and a container is the right tool for a stateless service that has to start
fast, scale with load, and pack many onto one host. Fast starts, small per-instance overhead, and a
shared kernel are the main reasons containers took over for stateless microservices between roughly
2014 and 2020: they made it cheap to run many small services and to deploy or roll back in seconds,
which is what schedulers like Kubernetes were built around. One honest caveat: Docker on macOS runs
inside its own Linux VM, so this is really a container inside a shared VM compared against a
dedicated VM.
