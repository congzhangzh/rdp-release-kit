# The Linux host's build environment: the Linux client's (build/Dockerfile,
# AlmaLinux 9, glibc 2.34), plus the headers FreeRDP's shadow server needs
# from the host it runs on. build.sh (HOST=1) builds that image first, then
# this one on top of it, so both products share one glibc baseline.
#
# - PAM: the logins (the session's owner, checked as the system checks him)
# - Xdamage, Xinerama: the X11 subsystem's damage and monitors (X11, Xext,
#   Xfixes and Xtst are in the client's image already)
# - systemd (sd-bus) and PipeWire for the Mutter subsystem are there too;
#   libei is not in AlmaLinux 9 and is built from sources.lock: its protocol
#   scanner needs Python's jinja2
ARG BASE=rdp-release-kit-build
FROM ${BASE}
RUN for try in 1 2 3; do \
        dnf -y install pam-devel libXdamage-devel libXinerama-devel python3-jinja2 \
        && break; \
        [ "$try" = 3 ] && exit 1; \
        dnf clean all; sleep 30; \
    done \
    && dnf clean all
