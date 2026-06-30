# Lab 7: Configuration Management - Deploy QuickNotes via Ansible

Built and verified on Apple Silicon (M4, arm64, macOS 26.5). The Lab 5 VM uses
the vmware_desktop provider (VirtualBox cannot run amd64 or arm64 Linux guests on
Apple Silicon), so the inventory points at the vmware_desktop SSH key; a
VirtualBox host would use the virtualbox key path instead. Ansible is core 2.21.1
(the spec lists 10.x; this is newer and behaves the same). The shipped binary is
linux/arm64 because the VM is arm64; an amd64 grader rebuilds it with one
command (see below).

## Objective

Write an idempotent Ansible playbook that deploys QuickNotes to the Lab 5 VM as a
systemd service, prove idempotency and selective change, and (bonus) make the VM
auto-converge from the fork with an ansible-pull systemd timer.

## Environment

| Component   | Version / value                          |
|-------------|-------------------------------------------|
| Host        | Apple Silicon M4, macOS 26.5, arm64       |
| Ansible     | core 2.21.1                               |
| Vagrant     | 2.4.9, vmware_desktop provider            |
| VM box      | bento/ubuntu-24.04 (arm64), SSH 127.0.0.1:2222 |
| Binary      | linux/arm64 static (CGO_ENABLED=0, -trimpath -ldflags='-s -w') |

The binary is rebuilt for the VM with:

```
cd app && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o ../ansible/files/quicknotes .
```

## Layout

```
ansible/
  inventory.ini
  playbook.yaml
  files/
    quicknotes        (static binary, arm64)
    seed.json
  templates/
    quicknotes.service.j2
    pull-inventory.ini.j2
    ansible-pull.service.j2
    ansible-pull.timer.j2
```

---

## Task 1: Idempotent deploy

### inventory.ini

```ini
[lab5_vm]
quicknotes-vm ansible_host=127.0.0.1 ansible_port=2222 ansible_user=vagrant ansible_ssh_private_key_file=.vagrant/machines/default/vmware_desktop/private_key ansible_python_interpreter=/usr/bin/python3

[lab5_vm:vars]
ansible_ssh_common_args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa'
```

The host, port, and key path come straight from `vagrant ssh-config`. Run
`ansible-playbook` from the repo root so the relative key path resolves.

### playbook.yaml

```yaml
---
- name: Deploy QuickNotes to the Lab 5 VM
  hosts: lab5_vm
  become: true
  gather_facts: false

  vars:
    quicknotes_user: quicknotes
    quicknotes_group: quicknotes
    quicknotes_shell: /usr/sbin/nologin
    quicknotes_home: /nonexistent
    quicknotes_binary_src: files/quicknotes
    quicknotes_binary_dest: /usr/local/bin/quicknotes
    quicknotes_seed_src: files/seed.json
    quicknotes_seed_dir: /usr/local/share/quicknotes
    quicknotes_seed_path: "{{ quicknotes_seed_dir }}/seed.json"
    quicknotes_data_dir: /var/lib/quicknotes
    quicknotes_data_path: "{{ quicknotes_data_dir }}/notes.json"
    quicknotes_service_name: quicknotes
    listen_addr: ":8080"
    quicknotes_restart_sec: 6
    # ansible-pull (bonus) variables omitted here for brevity; see the Bonus section.

  tasks:
    - name: Create the quicknotes system group
      ansible.builtin.group:
        name: "{{ quicknotes_group }}"
        system: true

    - name: Create the quicknotes system user
      ansible.builtin.user:
        name: "{{ quicknotes_user }}"
        group: "{{ quicknotes_group }}"
        system: true
        create_home: false
        home: "{{ quicknotes_home }}"
        shell: "{{ quicknotes_shell }}"

    - name: Ensure the data directory exists
      ansible.builtin.file:
        path: "{{ quicknotes_data_dir }}"
        state: directory
        owner: "{{ quicknotes_user }}"
        group: "{{ quicknotes_group }}"
        mode: "0750"

    - name: Install the QuickNotes binary
      ansible.builtin.copy:
        src: "{{ quicknotes_binary_src }}"
        dest: "{{ quicknotes_binary_dest }}"
        owner: root
        group: root
        mode: "0755"
      notify: Restart quicknotes

    - name: Render the systemd unit
      ansible.builtin.template:
        src: templates/quicknotes.service.j2
        dest: "/etc/systemd/system/{{ quicknotes_service_name }}.service"
        mode: "0644"
      register: quicknotes_unit
      notify: Restart quicknotes

    - name: Enable and start the quicknotes service
      ansible.builtin.systemd:
        name: "{{ quicknotes_service_name }}"
        enabled: true
        state: started

  handlers:
    - name: Restart quicknotes
      ansible.builtin.systemd:
        name: "{{ quicknotes_service_name }}"
        state: restarted
        daemon_reload: true
```

(The committed playbook also creates the seed directory, copies the seed file,
and contains the bonus tasks. The full file is in the repo.)

### templates/quicknotes.service.j2

```jinja
[Unit]
Description=QuickNotes API
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User={{ quicknotes_user }}
Group={{ quicknotes_group }}
WorkingDirectory={{ quicknotes_data_dir }}
Environment=ADDR={{ listen_addr }}
Environment=DATA_PATH={{ quicknotes_data_path }}
Environment=SEED_PATH={{ quicknotes_seed_path }}
ExecStart={{ quicknotes_binary_dest }}
Restart=on-failure
RestartSec={{ quicknotes_restart_sec }}

[Install]
WantedBy=multi-user.target
```

### First run

The VM still had Lab 5's manual deploy (a quicknotes.service running as the
vagrant user). I removed those artifacts first so this was a genuine clean
deploy, then ran the playbook.

```
PLAY RECAP
quicknotes-vm : ok=9  changed=9  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

Every task changed, and the Restart quicknotes handler fired (notified by the
binary copy and the unit render).

### Service reachable

```
# on the VM
systemctl is-active quicknotes            -> active
systemctl show quicknotes -p MainPID -p User --value -> 2936 quicknotes
curl -s http://127.0.0.1:8080/health      -> {"notes":4,"status":"ok"}

# from the host via the Vagrant port forward (8080 -> 18080)
curl -s http://localhost:18080/health     -> {"notes":4,"status":"ok"}
```

The service runs as the unprivileged quicknotes user, not root and not vagrant.

### Design answers

a) command vs the dedicated modules. `command:` and `shell:` run a program every
time and, unless you add `creates`/`changed_when`, always report "changed" with
no idea whether anything actually needed doing. The dedicated modules (`apt`,
`file`, `copy`, `template`, `systemd`, `user`) are declarative: they read the
current state, compare it to the desired state, and act only on a difference.
That is what makes a re-run safe and lets the PLAY RECAP mean something (a
"changed" is real drift, not noise).

b) notify and handlers. A handler runs only when a task that notifies it reports
"changed". If the task is "ok" (already in the desired state), the handler is not
notified and does not run. Handlers run once, at the end of the play, even if
several tasks notify the same one. That is the right default because you want to
restart QuickNotes exactly when its binary or unit actually changed, not on every
run and not multiple times in one run.

c) variable hierarchy. For this lab the top places, low to high precedence, are:
role `defaults/` (overridable baseline, if this were a role), `group_vars/lab5_vm`
(per-group values), and play `vars:` (what I used, since it is a single play and
keeping the values visible in the playbook is simplest). Above all of those,
`--extra-vars` (`-e`) wins, which is exactly what I use for the one-off tweak in
Task 2. I kept everything in play `vars` because there is one host group and one
play; group_vars would be the move once there are several environments.

d) gather_facts. This playbook references no facts (no `ansible_distribution`,
no `ansible_default_ipv4`, nothing from the setup module), so I set
`gather_facts: false`. Turning it off skips the implicit setup task on every run,
which saves a round-trip to the VM and a second or two each time. If I later
needed, say, `ansible_architecture` to pick a binary, I would turn it back on.

---

## Task 2: Idempotency and selective change

### Second run: changed=0

Running the full playbook again with nothing changed:

```
PLAY RECAP
quicknotes-vm : ok=14  changed=0  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

(14 tasks once the bonus tasks are included; the deploy-only stage showed
ok=8 changed=0.)

### Variable tweak: only the template changes, the handler fires

Override one variable that feeds the unit template:

```
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml -e 'listen_addr=:9090'

TASK [Render the systemd unit] ... changed: [quicknotes-vm]
RUNNING HANDLER [Restart quicknotes] ... changed: [quicknotes-vm]
PLAY RECAP
quicknotes-vm : ok=15  changed=2  unreachable=0  failed=0  ...
```

Only the template task changed, and that notified the restart handler. Every
other task stayed ok. The daemon-reload lives inside the handler (not the
enable/start task), which is why the tweak shows up as exactly "template + its
handler" and nothing else.

### --check --diff preview

A third change, previewed without applying it:

```
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml -e 'quicknotes_restart_sec=10' --check --diff

TASK [Render the systemd unit]
--- before: /etc/systemd/system/quicknotes.service
+++ after:  .../quicknotes.service.j2
@@ -13,7 +13,7 @@
-RestartSec=6
+RestartSec=10
changed: [quicknotes-vm]
```

`--check` runs the play without writing anything; `--diff` shows the exact line
that would change.

### Design answers

e) Why the second run is changed=0. The `file`, `copy`, and `template` modules
compare desired state to what is already on the VM. `copy`/`template` checksum
the would-be content and also compare owner, group, and mode; `template` renders
the Jinja first, then compares. If the result is byte-identical and the
attributes match, the module reports ok and rewrites nothing. So a no-op run
touches nothing.

f) shell `echo ... > unit` instead of template. It breaks in several ways: it is
not idempotent (it rewrites the file every run, so it always reports changed and
fires the restart handler every single time); you lose owner/group/mode
management; multi-line content with quotes and Jinja values is an escaping
minefield; the redirect truncates then writes, so a crash mid-write leaves a
broken unit; and you cannot preview it with `--check --diff`. The template module
gives idempotency, attributes, atomic replace, and a diff for free.

g) --check vs --check --diff. `--check` tells you which tasks would change, but
not what. `--check --diff` shows the actual content delta. The bug you catch only
with `--diff`: a template that "would change" for the wrong reason, for example a
variable that renders to an unexpected value or a stray whitespace edit. Plain
`--check` just says "1 task would change" and you ship it; `--diff` shows the
exact wrong line so you stop before deploying it.

---

## Bonus: ansible-pull GitOps loop

The playbook installs ansible and git on the VM, drops a local inventory
(`ansible_connection=local`), and installs a systemd service plus a 5-minute
timer that runs `ansible-pull` against the fork. The VM then reconciles itself
from git with no push from the host.

### ansible-pull variables and units

```yaml
    ansible_pull_repo_url: https://github.com/Dekart-hub/DevOps-Intro.git
    ansible_pull_branch: feature/lab7
    ansible_pull_clone_dir: /opt/quicknotes-ansible
    ansible_pull_config_dir: /etc/quicknotes-ansible
    ansible_pull_inventory_path: "{{ ansible_pull_config_dir }}/inventory.ini"
    ansible_pull_service_name: ansible-pull-quicknotes
    ansible_pull_timer_name: ansible-pull-quicknotes.timer
```

pull-inventory.ini.j2:

```ini
[lab5_vm]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
```

ansible-pull.service.j2 (oneshot):

```jinja
[Service]
Type=oneshot
ExecStart=/usr/bin/ansible-pull -U {{ ansible_pull_repo_url }} -C {{ ansible_pull_branch }} -d {{ ansible_pull_clone_dir }} -i {{ ansible_pull_inventory_path }} ansible/playbook.yaml
```

ansible-pull.timer.j2:

```jinja
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

### Timer installed and active

```
systemctl is-active ansible-pull-quicknotes.timer   -> active
systemctl is-enabled ansible-pull-quicknotes.timer  -> enabled

systemctl list-timers ansible-pull-quicknotes.timer
NEXT                        LEFT     LAST                        UNIT
Tue 2026-06-30 18:46:05 UTC 3min 44s Tue 2026-06-30 18:38:37 UTC ansible-pull-quicknotes.timer
```

A manual trigger confirmed the loop end to end: it cloned the fork's feature/lab7
and ran the playbook locally.

```
journalctl -u ansible-pull-quicknotes.service
/usr/bin/ansible-pull -U https://github.com/Dekart-hub/DevOps-Intro.git -C feature/lab7 -d /opt/quicknotes-ansible -i /etc/quicknotes-ansible/inventory.ini ansible/playbook.yaml
PLAY RECAP
localhost : ok=14  changed=0  unreachable=0  failed=0  ...
```

### Convergence timeline (push to git, timer reconciles, no host involvement)

Timeline (all UTC):

- 18:42:20  Pushed commit a7535ba (RestartSec 4 -> 6) to the fork's feature/lab7.
- 18:46:05  The systemd timer fired ansible-pull-quicknotes.service on its 5-minute schedule.
- 18:46:15  ansible-pull cloned feature/lab7 and ran the playbook against localhost.
- 18:46:45  The VM's deployed unit showed RestartSec=6 (observed by polling every 30s).

The timer-driven run applied exactly the template change and restarted the
service:

```
journalctl -u ansible-pull-quicknotes.service
Starting Ansible Pull at 2026-06-30 18:46:15
TASK [Render the systemd unit] ...
RUNNING HANDLER [Restart quicknotes] ...
localhost : ... changed=2 ...

grep RestartSec /etc/systemd/system/quicknotes.service  -> RestartSec=6
curl http://127.0.0.1:8080/health                       -> {"notes":4,"status":"ok"}
```

About 4.5 minutes from push to reconciliation, inside the 5-minute window. No
ansible-playbook was run from the host; the VM converged itself from git.

### Design answers

h) Security benefit of pull mode. In push mode a control node holds SSH access to
every host and opens an inbound management path on each one. Compromise the
control node and you own the fleet. In pull mode each node reconciles itself by
pulling from git, so there is no central box with credentials to everything and
no inbound admin port on the nodes. A node needs only outbound, read-only git
access, which is a much smaller attack surface.

i) The same pattern at the Kubernetes layer is GitOps, implemented by tools like
Argo CD or Flux: the cluster continuously pulls the desired state from git and
reconciles itself toward it. ansible-pull is a fair VM-layer simulator because it
is the same control loop: desired state lives in git, the machine pulls it on a
schedule, converges to it, and corrects drift on its own, with no operator
pushing changes.

---

## How to run

```
# from the repo root, with the Lab 5 VM up (vagrant up)
ansible-playbook -i ansible/inventory.ini ansible/playbook.yaml
curl -s http://localhost:18080/health
```
