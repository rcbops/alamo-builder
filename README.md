DESCRIPTION
===========

Alamo-builder is a system for building an ISO to install Rackspace Private Cloud Software ("Alamo").

PLATFORMS
=========

The build script supports Debian, most Debian-based platforms (such as Ubuntu) and OSX as build platforms. The platform-specific notes are as follows:

Debian
------

Building under Debian requires the following packages:

* genisoimage
* bsdtar

OSX
---

Building under OSX requires some packages installed through a port system such as MacPorts, Fink or Homebrew. We only test on Homebrew, so we will provide those instructions here.

Using Homebrew, install:

* cdrtools
* wget

Then run:

    brew tap homebrew/dupes
    brew install homebrew/dupes/bsdtar
    brew link bsdtar

This will install a duplicate version of bsdtar to /usr/local/bin/bsdtar, which provides a new enough libarchive to extract .ISO files (since OSX broke this functionality in recent versions).

If you would like to do this a different way, you will need to make sure your dupe bsdtar binary is in /usr/local/bin or modify build.sh to provide the correct path.

OPTIONS
=======

Flavor
------

export FLAVOR="FULL" or "MINIMAL"; defaults to "FULL"

* The FULL flavor ISO bundles everything into the .ISO file:
  * Chef Server VM (1GB)
  * Chef Omnibus installer (17MB)
  * Ubuntu Precise 12.04 LTS image (17MB)
  * Cirros Linux image (7MB)
* The MINIMAL flavor ISO bundles nothing. This will require the post-installer to download them on the fly.

USING
=====

When you run the builder for the first time, it will need to download one or more large files, depending on the flavor you choose (See Options section above). At the very least, the Ubuntu 12.04 LTS Server ISO (684MB) will be downloaded to use as the basis of the Alamo ISO.

* Run ./build.sh
* Get a cup of coffee
* Booten Sie Eizo! (located in the "./iso" directory, symlinked to "./iso/rpcs-${FLAVOR}.iso" after build) 
* Remember the Alamo!
