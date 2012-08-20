DESCRIPTION
===========

Alamo-builder is a system for building an ISO to install Rackspace Private Cloud Software ("Alamo").

PLATFORMS
=========

The build script supports Debian (and most Debian-based platforms, such as Ubuntu) and OSX as build platforms. The platform-specific notes are as follows:

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

Optional:

* export FLAVOR="FULL" or "MINIMAL"; defaults to "FULL"

USING
=====

* Run ./build.sh
* Get a cup of coffee
* Booten Sie Eizo!
