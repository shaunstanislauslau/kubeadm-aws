#!/bin/bash -v

# Disable pointless daemons
systemctl stop snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent
systemctl disable snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent

# Disable swap to make K8S happy
swapoff -a
sed -i '/swap/d' /etc/fstab

# Install K8S, kubeadm and Docker
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
echo "deb https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl docker-ce

# Point Docker at big ephemeral drive and turn on log rotation
mkdir /mnt/docker
cat <<EOF > /etc/docker/daemon.json
{
    "data-root": "/mnt/docker",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "5"
    }
}
EOF
systemctl restart docker

# Point kubelet at big ephemeral drive
mkdir /mnt/kubelet
echo 'KUBELET_EXTRA_ARGS="--root-dir=/mnt/kubelet"' > /etc/default/kubelet

# Set up the cluster
kubeadm init --token=${k8stoken} --pod-network-cidr=10.244.0.0/16

# Pass bridged IPv4 traffic to iptables chains (required by Flannel like the above cidr setting)
echo "net.bridge.bridge-nf-call-iptables = 1" > /etc/sysctl.d/60-flannel.conf
service procps start

# Set up kubectl for the ubuntu user and Flannel
mkdir -p /home/ubuntu/.kube && cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && chown -R ubuntu. /home/ubuntu/.kube
su -c 'kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/v0.10.0/Documentation/kube-flannel.yml' ubuntu

# Allow pod scheduling on the master (no recommended but we're doing it anyway :D)
su -c 'kubectl taint nodes --all node-role.kubernetes.io/master-' ubuntu

DEBIAN_FRONTEND=noninteractive apt-get install -y awscli

REGION=$(ec2metadata --availability-zone | rev | cut -c 2- | rev)
INSTANCE_ID=$(ec2metadata --instance-id)
aws --region $REGION ec2 create-tags --resources $INSTANCE_ID --tags "Key=Name,Value=${clustername}-master" "Key=Environment,Value=${clustername}"

