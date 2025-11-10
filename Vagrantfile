# Why: Vagrant reads this file to know what VMs to create.
# Each VM gets a name, an IP address, and enough memory to run RHEL.
#
# We use Rocky Linux 9 instead of RHEL 9 directly because RHEL requires a
# Red Hat subscription to download. Rocky Linux is a 1:1 community rebuild —
# same packages, same behavior, no account needed.

Vagrant.configure("2") do |config|

  config.vm.box = "rockylinux/9"

  # Disable automatic box update checks to speed up `vagrant up`
  config.vm.box_check_update = false

  # ------------------------------------------------------------------
  # Load Balancer — lb01
  # This machine runs HAProxy and is the only one your browser talks to.
  # All traffic flows through here and gets spread across the web nodes.
  # ------------------------------------------------------------------
  config.vm.define "lb01" do |lb|
    lb.vm.hostname = "lb01"
    lb.vm.network "private_network", ip: "192.168.12.10"

    lb.vm.provider "libvirt" do |libvirt|
      libvirt.memory = 512   # HAProxy is lightweight, 512MB is plenty
      libvirt.cpus   = 1
    end
  end

  # ------------------------------------------------------------------
  # Web Nodes — web01, web02, web03
  # Each runs Nginx and serves a page that shows its own hostname.
  # We use a loop so we don't repeat the same block three times.
  # ------------------------------------------------------------------
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
# Total RAM for all 4 VMs: ~2 GB (4 x 512 MB)
# Your host OS needs the remaining ~13 GB on a 15 GB machine
