DEPS=bgworker maagic-copy py-alarm-sink device-automaton
ifndef NCS_RUN_DIR
NCS_RUN_DIR=nso-run
endif
INSTALL_DIR?=$(NCS_RUN_DIR)/packages
NED?=cisco-ios-cli-3.8

.PHONY: install setup-nso start-nso stop-nso clean magic

magic:
	$(MAKE) clean
	$(MAKE) setup-nso
	$(MAKE) install
	$(MAKE) start-nso
	$(MAKE) setup-netsim
	$(MAKE) start-netsim

install: $(addprefix install-,$(DEPS))
# 'compose' is a special recipe used in the automaton package for template pre-processing
	$(MAKE) -C $(INSTALL_DIR)/device-automaton/src compose
	cp tmp/device-automaton/extra-files/nid/cdb-default/*.xml $(NCS_RUN_DIR)/ncs-cdb/

build-%:
	SKIP_LINT=true make -C $(INSTALL_DIR)/$*/src
	if [ -f $(INSTALL_DIR)/$*/src/requirements.txt ]; then pip3 install -r $(INSTALL_DIR)/$*/src/requirements.txt; fi


install-%: clone-%
	rm -rf $(INSTALL_DIR)/$*
	cp -pr tmp/$*/packages/$* $(INSTALL_DIR)
	$(MAKE) build-$*

clone-%: SHELL:=/bin/bash
clone-%:
	rm -rf tmp/$*
	git clone https://gitlab.com/nso-developer/$*.git tmp/$*;
	if [ "$*" == "maagic-copy" ]; then \
		cd tmp/$*; \
		git checkout f-string-change; \
	fi

setup-nso:
	ncs-setup --dest $(NCS_RUN_DIR)
	$(MAKE) copy-neds

start-nso:
	ncs --cd $(NCS_RUN_DIR)

# Copy the NEDs from the NSO installation directory to the NSO run directory.
# This works for both local and system installations.
copy-neds:
	cp -pr $(NCS_DIR)/packages/neds/$(NED) $(INSTALL_DIR)

clean: stop-nso stop-netsim
	rm -rf $(NCS_RUN_DIR)
	rm -rf netsim

stop-nso:
	-ncs --cd $(NCS_RUN_DIR) --stop

start-netsim:
	ncs-netsim start

stop-netsim:
	-ncs-netsim stop

setup-netsim:
	ncs-netsim create-network $(NED) 1 cpe