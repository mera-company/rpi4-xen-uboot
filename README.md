# Xen for Raspberry Pi 4 (64-bit)
 
This provides Xen related builds:
The build for Xen dom0, based on the 64-bit Linux kernel from the Raspberry Pi tree, and packages a minimal 64-bit Ubuntu 18.04 rootfs for the Raspberry Pi 4.
     
This build is based on the https://github.com/dornerworks/xen-rpi4-builder project with the following enhancements:
       
+ U-boot is now used for Xen and Linux kernel, Ubuntu rootfs loading
+ Added an option for building Linux kernel for domU
+ Removed the limitation with 1Gb for system RAM

The build for Xen domU is based on the Linux Vanilla kernel 5.5 and minimal Ubuntu 18.04 rootfs
     
## Getting Started

In order to build dom0 image run the script

    $ ./rpixen.sh

In order to build artifacts for domU run the script

    $ ./domubuild.sh

Note that both scripts have additional options: -p proxy, -d dns_server, to setup correct environment 
   
### Prerequisites

 - A recent version of Ubuntu is required to run the build script. 
 - 10GB+ free disk space.

### Installing

In order to burn the artifacts for dom0 to SD card use the following commands:

    $ umount /dev/sdX1
    $ umount /dev/sdX2
    $ sudo dd if=rpixen.img of=/dev/sdX bs=8M status=progress
    $ sync

Artifacts for domU are located in archive domU.tar.gz.
This archive contains kernel, rootfs image and config for xl tool. See README inside archive.

domU artifacts have to be put to /home/pi on the dom0

## Built With

* [Xen] (https://xenproject.org) - the Xen hypervizor
* [u-boot] (https://www.denx.de/wiki/U-Boot) - the Universal Boot Loader
* [Ubuntu] (https://ubuntu.com) - Ubuntu OS rootfs
* [Raspberry Pi] (https://www.raspberrypi.org) - Raspberry Pi 4 adapted kernel and firmware

## Limitations

* aux spi1 and aux spi2 are disabled
* Wi-Fi/Bluetooth do not work
* Max 3G of memory is used

## Versioning

We use [SemVer](http://semver.org/) for versioning. 

## Authors

Leonid Lazarev <leonid.lazarev@mera.com>

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct, and the process for submitting pull requests to us.

## License

This project is licensed under the MIT license. See the [COPYING.MIT](COPYING.MIT) file for details.

## Acknowledgments

### Memory

In order to allow USB working, rpixen.sh script sets total_mem to 3G. See https://github.com/raspberrypi/linux/issues/3093
for details.
If the USB support is not required, the total_mem parameter could be removed from config.txt and full memory capacity will be available.

By default, distribution of the memory between domains is following
+ dom0 - 768M  (see boot.cmd for details)
+ domU - 1024M (see domu0.cfg for details)

It is supposed that Raspberry Pi 4 has 4Gb of RAM on board.
If the another HW is used (1G or 2G), the appropriate modifications are required in the boot.cmd and domu0.cfg.

### I/O

dom0: After running on the target the Xen prints messages to the UART.

### Disk

In order to resize dom0 rootfs partition for several virtual machines, the following action
has to be done

    $ umount /dev/sdX1
    $ umount /dev/sdX2

    $ sudo parted /dev/sdX
    $ >resizepart 2
    $ sudo e2fsck -f /dev/sdX2	
    $ sudo resize2fs /dev/sdX2
