DESTDIR ?=
PREFIX  ?= /usr

.PHONY: build install deb test e2e-test clean

build:
	@echo "Nothing to build (pure Perl/JS plugin)"

install:
	# Perl module
	install -D -m 0644 src/PVE/API2/Hardware/XPU.pm \
		$(DESTDIR)/usr/share/perl5/PVE/API2/Hardware/XPU.pm
	# JavaScript plugin
	install -D -m 0644 src/js/pve-xpu-plugin.js \
		$(DESTDIR)/usr/share/pve-manager/js/pve-xpu-plugin.js
	# Scripts
	install -D -m 0755 src/scripts/apply-sriov-config.sh \
		$(DESTDIR)/usr/lib/pve-xpu/apply-sriov-config.sh
	install -D -m 0755 src/scripts/reapply-patches.sh \
		$(DESTDIR)/usr/lib/pve-xpu/reapply-patches.sh
	# Systemd service
	install -D -m 0644 src/systemd/pve-xpu-sriov.service \
		$(DESTDIR)/lib/systemd/system/pve-xpu-sriov.service
	# Default templates (staged; postinst copies to /etc/pve/local/)
	install -D -m 0644 config/xpu-vf-templates.conf \
		$(DESTDIR)/usr/share/pve-xpu/xpu-vf-templates.conf
	# APT hook
	install -D -m 0644 config/99-pve-xpu-reapply \
		$(DESTDIR)/etc/apt/apt.conf.d/99-pve-xpu-reapply

deb:
	dpkg-buildpackage -us -uc -b

test:
	prove -r t/

e2e-test:
	cd test/e2e && npx playwright test

clean:
	rm -rf debian/pve-xpu-manager
	rm -rf debian/.debhelper
	rm -f debian/debhelper-build-stamp
	rm -f debian/files
	rm -f ../*.deb ../*.buildinfo ../*.changes
