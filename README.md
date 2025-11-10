# Automated High-Availability Infrastructure Lab

**Stack:** Vagrant · Ansible · HAProxy · Nginx · RHEL 8/9

This is a home lab project I built to learn how real-world infrastructure teams handle redundancy and automation. The idea is simple: instead of having one server that goes down and takes everything with it, you spread traffic across multiple servers and let a load balancer decide who handles what. If one web server dies, the others keep serving traffic. Nobody notices.

Everything here is written as code — no clicking around in GUIs. You run two commands and a full cluster spins up.

---

## What This Does

```
          Internet / Your Browser
                   |
              [ HAProxy ]         <-- Load balancer (the traffic cop)
             /     |     \
        [web1]  [web2]  [web3]    <-- Nginx web servers (RHEL 9)
```

- **HAProxy** sits in front and distributes incoming requests across the three web nodes
- **Nginx** runs on each web node and serves a simple page
- **Vagrant** creates all the virtual machines automatically with one command
- **Ansible** configures every machine automatically — installs packages, writes config files, starts services

The whole point is that if you kill `web2`, HAProxy detects it and stops sending traffic there. `web1` and `web3` keep working. That's high availability.

---

## Why I Built This

I wanted to understand what "infrastructure as code" actually means in practice — not just the buzzword. The answer is: instead of SSHing into a server and typing commands by hand (which you'll forget, which breaks when you do it twice, which nobody else can reproduce), you write files that describe the desired state and let tools handle the rest.

This project covers the same patterns used in real DevOps work:
- Idempotent configuration (run it 10 times, same result)
- Cluster provisioning without touching each machine manually
- Load balancing with health checks

---

## Requirements

This was built and tested on **Fedora 43** with **15 GB RAM**. The VMs are small but you need headroom for your host OS too.

### Software you need installed

```bash
# Install KVM/libvirt (the hypervisor stack)
sudo dnf install -y @virtualization

# Enable and start libvirt
sudo systemctl enable --now libvirtd

# Add yourself to the libvirt group so you can manage VMs without sudo
sudo usermod -aG libvirt $USER
# Log out and back in for the group change to take effect

# Install virt-manager (optional GUI for managing VMs)
sudo dnf install -y virt-manager

# Install Vagrant
sudo dnf install -y vagrant

# Install Ansible
sudo dnf install -y ansible

# Install the vagrant-libvirt plugin (replaces VirtualBox provider)
vagrant plugin install vagrant-libvirt
```

### Check your versions

```bash
vagrant --version      # Should be 2.3+
ansible --version      # Should be 2.14+
virsh --version        # Should be 9.0+
```

---

## Project Layout

```
Automated HA Infrastructure/
├── Vagrantfile              # Defines all 4 VMs (1 load balancer + 3 web nodes)
├── ansible.cfg              # Tells Ansible where to find things
├── inventory/
│   └── hosts.ini            # Lists all machines and what group they belong to
├── playbooks/
│   ├── site.yml             # Master playbook — runs everything in order
│   ├── haproxy.yml          # Sets up the load balancer
│   └── webservers.yml       # Sets up the Nginx web nodes
└── roles/
    ├── haproxy/
    │   ├── tasks/main.yml   # Steps to install and configure HAProxy
    │   └── templates/
    │       └── haproxy.cfg.j2   # HAProxy config template (Jinja2)
    └── nginx/
        ├── tasks/main.yml   # Steps to install and configure Nginx
        └── templates/
            └── index.html.j2    # Web page template (shows which server you hit)
```

---

## Getting Started

### 1. Clone the project

```bash
git clone <your-repo-url>
cd "Automated HA Infrastructure"
```

### 2. Spin up the virtual machines

```bash
vagrant up
```

This takes a few minutes the first time because Vagrant downloads the RHEL 9 base box. It creates four VMs:

| VM Name   | IP Address     | Role         |
|-----------|----------------|--------------|
| lb01      | 192.168.12.10  | Load balancer (HAProxy) |
| web01     | 192.168.12.11  | Web node 1 (Nginx) |
| web02     | 192.168.12.12  | Web node 2 (Nginx) |
| web03     | 192.168.12.13  | Web node 3 (Nginx) |

> **Why a private network range (192.168.12.x)?** These IPs only exist inside your machine. libvirt creates an isolated virtual network that all the VMs share. Your host OS can reach them but nothing outside your machine can. Safe for a lab.

### 3. Run Ansible to configure everything

```bash
ansible-playbook playbooks/site.yml
```

Ansible will SSH into each VM and:
- Install HAProxy on `lb01` and configure it to balance traffic across the three web nodes
- Install Nginx on `web01`, `web02`, `web03` and deploy a simple webpage
- Enable and start all services
- Configure firewall rules to allow HTTP traffic

Watch the output — each task says `ok` (already correct, nothing changed), `changed` (Ansible just made a change), or `failed` (something went wrong).

### 4. Test it

Open a browser and go to: `http://192.168.12.10`

Refresh a few times. You should see the page change between `web01`, `web02`, and `web03` — HAProxy is rotating through them in round-robin order.

You can also use curl in a loop:

```bash
for i in {1..9}; do curl -s http://192.168.12.10 | grep "Served by"; done
```

Expected output:
```
Served by: web01
Served by: web02
Served by: web03
Served by: web01
Served by: web02
...
```

### 5. Test high availability (the fun part)

While traffic is flowing, SSH into one of the web nodes and stop Nginx:

```bash
vagrant ssh web02
sudo systemctl stop nginx
exit
```

Now run the curl loop again:

```bash
for i in {1..9}; do curl -s http://192.168.12.10 | grep "Served by"; done
```

You'll only see `web01` and `web03` now. HAProxy's health check detected that `web02` is down and removed it from rotation. No errors, no downtime. That's the whole point.

Bring it back:

```bash
vagrant ssh web02
sudo systemctl start nginx
exit
```

HAProxy will detect it's healthy again and add it back automatically.

---

## File Breakdown

### Vagrantfile

```ruby
# Why: Vagrant reads this file to know what VMs to create.
# Each VM gets a name, an IP address, and enough memory to run RHEL.

Vagrant.configure("2") do |config|
  # Use a RHEL 9 compatible box (generic/rhel9 requires a Red Hat account,
  # so we use rockylinux/9 which is a 1:1 rebuild — same packages, same behavior)
  config.vm.box = "rockylinux/9"

  # Load balancer
  config.vm.define "lb01" do |lb|
    lb.vm.hostname = "lb01"
    lb.vm.network "private_network", ip: "192.168.12.10"
    lb.vm.provider "libvirt" do |libvirt|
      libvirt.memory = 512   # HAProxy is lightweight, 512MB is plenty
      libvirt.cpus   = 1
    end
  end

  # Web nodes — we define three using a loop to avoid copy-paste
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

**Total RAM used by VMs: ~2 GB** (4 × 512 MB). Your host OS needs the rest.

---

### inventory/hosts.ini

```ini
# Why: Ansible needs to know what machines exist and how to connect to them.
# We group them so playbooks can target "all web servers" without listing each one.

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

> **Why disable StrictHostKeyChecking?** Normally SSH warns you when it sees a new host fingerprint. In a lab where you're constantly destroying and recreating VMs, those warnings become noise. Never disable this on real servers.

---

### roles/haproxy/templates/haproxy.cfg.j2

```jinja2
# Why: HAProxy needs to know which backend servers exist and how to check if
# they're healthy. This template uses Jinja2 so Ansible can fill in the
# server list dynamically from the inventory.

global
    log /dev/log local0
    maxconn 2000

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 5s
    timeout client  30s
    timeout server  30s

# The "frontend" is what clients connect to — port 80 on the load balancer
frontend http_front
    bind *:80
    default_backend web_nodes

# The "backend" is the pool of real servers HAProxy sends traffic to
backend web_nodes
    balance roundrobin          # Rotate through servers one at a time
    option httpchk GET /        # Every 2s, hit GET / to check if the server is alive
    {% for host in groups['webservers'] %}
    server {{ host }} {{ hostvars[host]['ansible_host'] }}:80 check
    {% endfor %}
    # The loop above generates one line per web server, e.g.:
    # server web01 192.168.12.11:80 check
    # server web02 192.168.12.12:80 check
    # server web03 192.168.12.13:80 check
```

---

### roles/nginx/templates/index.html.j2

```html
<!-- Why: Each web server serves a slightly different page so you can see
     which one HAProxy sent you to. The {{ inventory_hostname }} variable
     gets replaced with the actual server name when Ansible deploys this. -->

<!DOCTYPE html>
<html>
<head><title>HA Lab</title></head>
<body>
  <h1>High Availability Lab</h1>
  <p>Served by: <strong>{{ inventory_hostname }}</strong></p>
  <p>This page is coming from one of three web nodes.
     Refresh to see HAProxy rotate between them.</p>
</body>
</html>
```

---

## Useful Commands

```bash
# See the status of all VMs
vagrant status

# SSH into a specific VM
vagrant ssh lb01
vagrant ssh web01

# Check HAProxy statistics (run inside lb01)
vagrant ssh lb01 -c "sudo systemctl status haproxy"

# Rerun just the web server playbook (without touching the load balancer)
ansible-playbook playbooks/webservers.yml

# Rerun everything from scratch
ansible-playbook playbooks/site.yml

# Destroy all VMs and start fresh
vagrant destroy -f && vagrant up
```

---

## Troubleshooting

**`vagrant up` fails with "VT-x is not available" or libvirt connection error**
Virtualization may be disabled in your BIOS, or the libvirt daemon isn't running. Check both:
```bash
# Ensure libvirt is running
sudo systemctl status libvirtd

# Verify your user is in the libvirt group (log out/in after adding)
groups | grep libvirt
```
If virtualization is disabled, restart, enter BIOS/UEFI settings, and enable Intel VT-x or AMD-V.

**Ansible can't connect to a VM**
```bash
# Make sure the VM is running
vagrant status

# If a VM is in an odd state, reload it
vagrant reload web01

# Test SSH manually
vagrant ssh web01
```

**Port 80 is already in use on the host**
This lab uses a private network — requests go to `192.168.12.10`, not `localhost`. Port conflicts on your host machine won't affect it.

**`vagrant up` is slow or hangs downloading the box**
Make sure vagrant-libvirt is installed: `vagrant plugin list`. If it's missing, run `vagrant plugin install vagrant-libvirt` and try again.

**`dnf install` fails inside the VM (no internet)**
```bash
# Inside the VM, check if DNS resolves
ping -c 2 8.8.8.8

# If ping works but dnf fails, it might be a proxy issue
# Set up the network gateway if needed:
vagrant ssh lb01 -c "ip route"
```

---

## What I Learned

Building this taught me a few things that I wouldn't have picked up from just reading about them:

- **Idempotency matters.** Ansible is designed so you can run the same playbook 50 times and it won't break anything. It checks current state before making changes. This makes automation safe to re-run after failures.
- **Health checks are what make HA actually work.** Without the `check` keyword in the HAProxy backend config, HAProxy would keep sending traffic to dead servers. The health check polling is what makes the failover automatic.
- **Templates beat hardcoded config files.** Writing the HAProxy config as a Jinja2 template means I can add a fourth web node just by adding it to the inventory — no manual config editing.
- **Vagrant is a great lab tool.** Being able to `vagrant destroy -f && vagrant up` and have a clean environment in minutes makes experimentation cheap.

---

## Tearing Down

When you're done:

```bash
vagrant destroy -f
```

This deletes all four VMs. Your Vagrantfile and playbooks stay on disk so you can `vagrant up` again anytime and rebuild the whole thing from scratch.

---

## Resources That Helped

- [HAProxy Configuration Manual](http://www.haproxy.org/download/2.8/doc/configuration.txt)
- [Ansible Documentation — Playbooks](https://docs.ansible.com/ansible/latest/playbook_guide/)
- [Vagrant Getting Started Guide](https://developer.hashicorp.com/vagrant/tutorials/getting-started)
- [Rocky Linux](https://rockylinux.org/) — the RHEL-compatible distro used for the VMs
