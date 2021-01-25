#!/bin/bash

set -e

### Start from OpenLogic OpenLogic CentOS 7.9 image (with kernel 3.10.0-1160)

### SET SELINUX TO PERMISSIVE
setenforce 0
sed -i 's|SELINUX=enforcing|SELINUX=permissive|g' /etc/selinux/config 

# Install az cli
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
sudo yum install -y azure-cli

### RELION DEPENDENCIES:

    ### install dependencies
    yum install -y gcc gcc-gfortran gcc-c++.x86_64 python-devel redhat-rpm-config rpm-build gtk2 atk cairo tcl tk nfs-utils.x86_64

    ###  CMAKE
	cd /tmp && wget -O /tmp/cmake.tar.gz https://github.com/Kitware/CMake/archive/v3.9.6.tar.gz
	tar -xvf cmake.tar.gz
	cd CMake* && ./configure && make -j $(nproc) && make install
    cd /tmp && rm -rf cmake.tar.gz CMake-3.9.6/
    export PATH=/usr/local/bin:$PATH
	
    ### INSTALL CUDA DRIVERS
    rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    yum install -y dkms
    distribution=rhel7
    ARCH=$( /bin/arch )
    yum-config-manager --add-repo http://developer.download.nvidia.com/compute/cuda/repos/$distribution/${ARCH}/cuda-$distribution.repo
    
    KERNEL=( $(rpm -q kernel | sed 's/kernel\-//g') )
    KERNEL=${KERNEL[-1]}
    RELEASE=( $(cat /etc/centos-release | awk '{print $4}') )
    yum -y install http://olcentgbl.trafficmanager.net/centos/${RELEASE}/updates/x86_64/kernel-devel-${KERNEL}.rpm
    yum install -y kernel-devel-${KERNEL}
    yum clean expire-cache
    yum install -y nvidia-driver-latest-dkms
    yum install -y cuda
    nvidia-smi -pm 1     # set persistence mode on

    ### Install MOFED Driver (Use v4.9 with Azure GPU VMs (except NDv2 or NDv4) as they use ConnectX3)
    #MLNX_OFED_DOWNLOAD_URL=http://content.mellanox.com/ofed/MLNX_OFED-5.0-2.1.8.0/MLNX_OFED_LINUX-5.0-2.1.8.0-rhel7.9-x86_64.tgz
    MLNX_OFED_DOWNLOAD_URL=http://content.mellanox.com/ofed/MLNX_OFED-4.9-2.2.4.0/MLNX_OFED_LINUX-4.9-2.2.4.0-rhel7.9-x86_64.tgz
    TARBALL=$(basename ${MLNX_OFED_DOWNLOAD_URL})
    MOFED_FOLDER=$(basename ${MLNX_OFED_DOWNLOAD_URL} .tgz)
    cd /tmp && wget $MLNX_OFED_DOWNLOAD_URL
    tar zxvf ${TARBALL}
    ./${MOFED_FOLDER}/mlnxofedinstall --kernel $KERNEL --kernel-sources /usr/src/kernels/${KERNEL} --add-kernel-support --skip-repo
    dracut -f
    /etc/init.d/openibd restart
    rm -rf /tmp/${MOFED_FOLDER} /tmp/${TARBALL}

	### OMPI WITH CUDA
	wget -O /tmp/openmpi.tar.gz https://download.open-mpi.org/release/open-mpi/v4.0/openmpi-4.0.4.tar.gz
	tar -xvf /tmp/openmpi.tar.gz -C /tmp
	cd /tmp/openmpi* && ./configure --prefix=/usr/local/openmpi --with-cuda --enable-mpirun-prefix-by-default
	make -j $(nproc) && make install
    rm -rf /tmp/openmpi-4.0.4.tar.gz /tmp/openmpi-4.0.4
    export PATH=/usr/local/openmpi/bin:$PATH
	export LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/local/cuda/include:/usr/local/cuda/lib64:$LD_LIBRARY_PATH


### INSTALL DOCKER
    yum install -y yum-utils
    yum-config-manager \
        --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y  docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker 


### INSTALL nvidia-container-runtime
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.repo | \
        sudo tee /etc/yum.repos.d/nvidia-container-runtime.repo
    yum install -y nvidia-container-runtime
    tee /etc/docker/daemon.json <<EOF
{
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
    pkill -SIGHUP dockerd
    systemctl daemon-reload
    systemctl restart docker


### INSTALL RELION:
### https://www3.mrc-lmb.cam.ac.uk/relion/index.php/Download_%26_install
    yum install -y git fftw-devel fltk-devel libtiff-devel.x86_64
    cd /tmp && git clone https://github.com/3dem/relion.git
    cd relion
    git checkout ver3.1
    mkdir -p external/fltk/lib     ## 'make install' fails if no (empty) lib/ folder
    mkdir build
    cd build
    ### CUDA Architecture: 37=K80, 60=P100, 61=P40, 70=V100, 80=A100
    cmake -DGUI=OFF -DCUDA=ON -DCudaTexture=ON -DCMAKE_INSTALL_PREFIX=/usr/local/relion -DCUDA_ARCH='37 -gencode=arch=compute_60,code=sm_60 -gencode=arch=compute_61,code=sm_61 -gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_80,code=sm_80 ' .. && make -j $(nproc) && make install
    cd /tmp && rm -rf relion/

### UPDATE PATH FOR ALL USERS
cat << EOF >> /etc/bashrc
PATH=/usr/local/openmpi/bin:/usr/local/relion/bin:/usr/local/bin:$PATH
LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/local/cuda/include:/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF

source /etc/bashrc
