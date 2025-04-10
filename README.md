# Installation Script for DIY "Home Labs" 

This repository contains all information and scripts needed to set up your own version of Parrot CTFs at home! 

<br>

Current Features: 
- Installs OpenVPN Server
- Installs Pfsense Firewall

<br> 

_This project only supports the usage of Proxmox VE 8 at this time._

<br>

### Installation

Clone the repository
```
git clone https://github.com/Parrot-CTFs/install-diy-local-lab.git
```

<br>

Run the install script in the root PVE of proxmox
```
chmod +x install.sh && sudo ./install.sh
```

<br>

> _There are some parts of this setup that you will need to do manually. The script will tell you when and what to do in a step by step fashion when this happens._
