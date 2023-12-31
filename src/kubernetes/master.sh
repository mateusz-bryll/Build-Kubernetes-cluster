#!/bin/bash
set -euxo pipefail

sudo apt-get update -y
sudo apt-get install -y jq ufw apt-transport-https ca-certificates

KUBERNETES_VERSION="1.28"
CRIO_OS="xUbuntu_22.04"
CRIO_VERSION="1.28"
NET_INTERFACE="eth1"
NODE_IP="$(ip --json addr show $NET_INTERFACE | jq -r '.[0].addr_info[] | select(.family == "inet") | .local')"
NODE_NAME=$(hostname -s)
POD_CIDR="192.168.0.0/16"

sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

sudo ufw allow 22/tcp           # ssh (optional)
sudo ufw allow 6443/tcp         # K8S API server
sudo ufw allow 2379:2380/tcp    # etcd server client API
sudo ufw allow 10250/tcp        # kublet API
sudo ufw allow 10259/tcp        # kube-scheduler
sudo ufw allow 10257/tcp        # kube-controller-manager

sudo sed -i "s/ENABLED=no/ENABLED=yes/g" /etc/ufw/ufw.conf
sudo ufw enable

cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat << EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

curl -fsSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$CRIO_OS/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg
curl -fsSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$CRIO_OS/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/libcontainers-crio-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$CRIO_OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo "deb [signed-by=/usr/share/keyrings/libcontainers-crio-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$CRIO_OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list

sudo apt-get update -y
sudo apt-get install -y cri-o cri-o-runc

sudo systemctl daemon-reload
sudo systemctl enable crio --now

curl -fsSL https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubectl kubeadm

cat << EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP
EOF

sudo kubeadm config images pull

sudo kubeadm init --apiserver-advertise-address="$NODE_IP" --apiserver-cert-extra-sans="$NODE_IP" --pod-network-cidr="$POD_CIDR" --node-name "$NODE_NAME"

mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml
