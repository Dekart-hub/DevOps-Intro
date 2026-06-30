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
