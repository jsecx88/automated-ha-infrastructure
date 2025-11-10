# Dev Log — Automated HA Infrastructure

A running record of what I built, what broke, and what I learned along the way.

---

## Step 1 — Figured out the stack

**What I did:**
Decided on the tools before writing any code. Picked:
- **Vagrant** to spin up VMs from a file instead of clicking through a GUI
- **KVM/libvirt** as the hypervisor (native to Linux, no extra installs beyond what Fedora ships)
- **Ansible** to configure everything automatically after the VMs were up
- **Rocky Linux 9** as the VM OS (free drop-in for RHEL — same packages, no Red Hat account needed)
- **HAProxy** for load balancing
- **Nginx** for the web servers

**What I learned:**
You can't just pick "Ansible" and call it a day. The full picture is: something creates the machines (Vagrant), something runs them (KVM), and something configures them (Ansible). They're three separate concerns and each one has its own config file.

Rocky Linux vs RHEL: RHEL requires a subscription just to download the image. Rocky Linux is a 1:1 binary-compatible rebuild maintained by the community. For a lab, it's identical.

---

## Step 2 — Set up KVM and Vagrant

**What I did:**
```bash
sudo dnf install -y @virtualization
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER
# Logged out and back in

sudo dnf install -y vagrant
vagrant plugin install vagrant-libvirt
```

**What I learned:**
The `@virtualization` group installs KVM, QEMU, and libvirt all at once — you don't have to pick them individually.

The `libvirt` group membership matters. Without it, every `vagrant` or `virsh` command would need `sudo`. Adding yourself to the group lets you manage VMs as a regular user. The log-out-and-back-in step is required because group changes don't apply to your current session.

`vagrant-libvirt` is a plugin — Vagrant doesn't ship KVM support built-in. You install it once and then Vagrant knows how to talk to libvirt.

---

## Step 3 — Wrote the Vagrantfile

**What I did:**
Defined all 4 VMs in one file using a Ruby loop for the web nodes instead of copy-pasting the same block three times:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "rockylinux/9"

  config.vm.define "lb01" do |lb|
    lb.vm.hostname = "lb01"
    lb.vm.network "private_network", ip: "192.168.12.10"
    lb.vm.provider "libvirt" do |libvirt|
      libvirt.memory = 512
      libvirt.cpus   = 1
    end
  end

  (1..3).each do |i|
    config.vm.define "web0#{i}" do |web|
      web.vm.hostname = "web0#{i}"
      web.vm.network "private_network", ip: "192.168.12.1#{i}"
      web.vm.provider "libvirt" do |libvirt|
        libvirt.memory = 512
        libvirt.cpus   = 1
      end
    end
  end
end
```

**What I learned:**
Vagrantfiles are Ruby. You don't need to know Ruby to write one, but knowing that `(1..3).each do |i|` is just a loop helps you read it.

Private network IPs (`192.168.12.x`) are virtual — they only exist inside your machine. libvirt creates an isolated bridge that the VMs and your host can talk over. Nothing outside your machine can reach those addresses.

512 MB per VM is enough for HAProxy and Nginx in a lab. Real production nodes would need more, but for learning the concepts it's fine.

---

## Step 4 — Wrote the Ansible inventory

**What I did:**
Created `inventory/hosts.ini` to tell Ansible what machines exist and how to connect:

```ini
[loadbalancers]
lb01 ansible_host=192.168.12.10

[webservers]
web01 ansible_host=192.168.12.11
web02 ansible_host=192.168.12.12
web03 ansible_host=192.168.12.13

[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=.vagrant/machines/%(inventory_hostname)s/libvirt/private_key
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

**What I learned:**
Ansible groups (`[loadbalancers]`, `[webservers]`) let playbooks say "run this on all web servers" without listing each machine by name. Add a fourth web node to the inventory and it gets included automatically.

Vagrant generates a unique SSH key for each VM and drops it in `.vagrant/machines/<name>/libvirt/private_key`. Pointing Ansible at that file means you never have to manage SSH keys manually.

`StrictHostKeyChecking=no` is a lab shortcut. In a real environment you'd add host fingerprints properly. Here, every `vagrant destroy && vagrant up` generates new keys and SSH would warn about them constantly — disabling the check removes the noise.

---

## Step 5 — Wrote the Ansible playbooks and roles

**What I did:**
Organized the Ansible work into roles (reusable units) and playbooks (what runs them):

```
playbooks/
  site.yml       ← runs everything in order
  haproxy.yml    ← targets [loadbalancers], applies haproxy role
  webservers.yml ← targets [webservers], applies nginx role

roles/
  haproxy/tasks/main.yml         ← install + configure HAProxy
  haproxy/templates/haproxy.cfg.j2
  nginx/tasks/main.yml           ← install + configure Nginx
  nginx/templates/index.html.j2
```

The HAProxy config template uses a Jinja2 loop to build the backend server list from the inventory:

```jinja2
{% for host in groups['webservers'] %}
server {{ host }} {{ hostvars[host]['ansible_host'] }}:80 check
{% endfor %}
```

**What I learned:**
**Idempotency** is the key property that makes Ansible useful. Every task checks current state before acting. Run the playbook once — it installs things. Run it again — it checks, finds everything already correct, and does nothing. This means you can re-run after a failure without worrying about partially applied changes leaving things broken.

**Roles** are just a folder structure Ansible recognizes. They're not strictly necessary for a small project, but using them means you could drop the `nginx` role into a completely different project and it would just work.

**Templates** beat hardcoded config files. The HAProxy template generates the backend server list from the Ansible inventory — add a web node to `hosts.ini` and the next playbook run automatically includes it in the HAProxy config. No manual editing.

---

## Step 6 — Tested high availability

**What I did:**
Ran the full setup:

```bash
vagrant up
ansible-playbook playbooks/site.yml
```

Then verified the load balancer was rotating:
```bash
for i in {1..9}; do curl -s http://192.168.12.10 | grep "Served by"; done
```

Then killed a web node and confirmed the others kept serving:
```bash
vagrant ssh web02
sudo systemctl stop nginx
exit

for i in {1..9}; do curl -s http://192.168.12.10 | grep "Served by"; done
# Only web01 and web03 appear — web02 is removed from rotation
```

**What I learned:**
Health checks are what make HA actually work. HAProxy polls each backend with `GET /` every 2 seconds. When it gets no response, it marks that server as down and stops sending traffic there — automatically, with no human intervention. That's the whole point.

The failover is invisible to the client. No error, no timeout, no lost request. Traffic just flows to the remaining nodes.

When you bring the node back (`sudo systemctl start nginx`), HAProxy's next health check sees it respond and automatically adds it back to rotation.

---

## Step 7 — Migrated from VirtualBox to KVM

**What I did:**
Originally started with VirtualBox as the Vagrant provider. Switched to KVM/libvirt because it's native to Linux and doesn't require a separate install on Fedora.

Changes made:
- `Vagrantfile`: replaced `config.vm.provider "virtualbox"` with `"libvirt"`, renamed settings from `vb.*` to `libvirt.*`, removed `vb.name` (libvirt uses the VM hostname)
- `inventory/hosts.ini`: updated SSH key path from `.../virtualbox/private_key` to `.../libvirt/private_key`
- `README.md`: replaced VirtualBox install instructions with KVM/libvirt setup, replaced `vagrant-vbguest` with `vagrant-libvirt`

**What I learned:**
The hypervisor is just a Vagrant provider — swapping it out only touches the `provider` block in the Vagrantfile and the SSH key path in the inventory. The Ansible playbooks, roles, templates, and everything else are completely provider-agnostic. Infrastructure-as-code means you can swap out the underlying platform without rewriting your automation.

`vagrant-vbguest` (the VirtualBox Guest Additions sync plugin) is not needed with libvirt. That's one less thing to manage.

---

## Things I'd Do Differently

- **Use a dedicated Vagrant box for libvirt from the start.** The `rockylinux/9` box works with both providers, but some boxes are libvirt-only or VirtualBox-only. Check before committing to a box.
- **Add an `ansible.cfg` with `host_key_checking = False` instead of the per-connection SSH flag.** Cleaner than setting it in `hosts.ini`.
- **Add a second load balancer.** Right now `lb01` is a single point of failure — ironic for a high-availability lab. Keepalived + a floating VIP would fix that.
