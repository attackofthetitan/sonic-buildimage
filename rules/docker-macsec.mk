# docker image for macsec agent

DOCKER_MACSEC_STEM = docker-macsec
DOCKER_MACSEC = $(DOCKER_MACSEC_STEM).gz
DOCKER_MACSEC_DBG = $(DOCKER_MACSEC_STEM)-$(DBG_IMAGE_MARK).gz

$(DOCKER_MACSEC)_PATH = $(DOCKERS_PATH)/$(DOCKER_MACSEC_STEM)

$(DOCKER_MACSEC)_DEPENDS += $(WPASUPPLICANT)
$(DOCKER_MACSEC)_DBG_DEPENDS = $($(DOCKER_SWSS_LAYER_BOOKWORM)_DBG_DEPENDS)
$(DOCKER_MACSEC)_DBG_DEPENDS +=  $(WPASUPPLICANT_DBG)

$(DOCKER_MACSEC)_DBG_IMAGE_PACKAGES = $($(DOCKER_SWSS_LAYER_BOOKWORM)_DBG_IMAGE_PACKAGES)

$(DOCKER_MACSEC)_LOAD_DOCKERS += $(DOCKER_SWSS_LAYER_BOOKWORM)

$(DOCKER_MACSEC)_INSTALL_PYTHON_WHEELS = $(SONIC_UTILITIES_PY3)
$(DOCKER_MACSEC)_INSTALL_DEBS = $(PYTHON3_SWSSCOMMON) $(LIBYANG_PY3)

SONIC_DOCKER_IMAGES += $(DOCKER_MACSEC)
SONIC_BOOKWORM_DOCKERS += $(DOCKER_MACSEC)
SONIC_DOCKER_DBG_IMAGES += $(DOCKER_MACSEC_DBG)
SONIC_BOOKWORM_DBG_DOCKERS += $(DOCKER_MACSEC_DBG)

ifeq ($(INCLUDE_KUBERNETES),y)
$(DOCKER_MACSEC)_DEFAULT_FEATURE_OWNER = kube
endif

$(DOCKER_MACSEC)_DEFAULT_FEATURE_STATE_ENABLED = y

ifeq ($(INCLUDE_MACSEC),y)
ifeq ($(INSTALL_DEBUG_TOOLS),y)
SONIC_PACKAGES_LOCAL += $(DOCKER_MACSEC_DBG)
else
SONIC_PACKAGES_LOCAL += $(DOCKER_MACSEC)
endif
endif

$(DOCKER_MACSEC)_CONTAINER_NAME = macsec
$(DOCKER_MACSEC)_VERSION = 1.0.0
$(DOCKER_MACSEC)_PACKAGE_NAME = macsec
$(DOCKER_MACSEC)_CONTAINER_PRIVILEGED = false
$(DOCKER_MACSEC)_CONTAINER_VOLUMES += /etc/sonic:/etc/sonic:ro
$(DOCKER_MACSEC)_CONTAINER_VOLUMES += /etc/localtime:/etc/localtime:ro
$(DOCKER_MACSEC)_CONTAINER_VOLUMES += /host/warmboot:/var/warmboot

$(DOCKER_MACSEC)_SERVICE_REQUIRES = config-setup
$(DOCKER_MACSEC)_SERVICE_AFTER = swss syncd

$(DOCKER_MACSEC)_CLI_CONFIG_PLUGIN = /cli/config/plugins/macsec.py
$(DOCKER_MACSEC)_CLI_SHOW_PLUGIN = /cli/show/plugins/show_macsec.py
$(DOCKER_MACSEC)_CLI_CLEAR_PLUGIN = /cli/clear/plugins/clear_macsec_counter.py

