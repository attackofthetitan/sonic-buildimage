# Docker image for DHCP server

DOCKER_DHCP_SERVER_STEM = docker-dhcp-server
DOCKER_DHCP_SERVER = $(DOCKER_DHCP_SERVER_STEM).gz
DOCKER_DHCP_SERVER_DBG = $(DOCKER_DHCP_SERVER_STEM)-$(DBG_IMAGE_MARK).gz

$(DOCKER_DHCP_SERVER)_PATH = $(DOCKERS_PATH)/$(DOCKER_DHCP_SERVER_STEM)

$(DOCKER_DHCP_SERVER)_DEPENDS = $(LIBSWSSCOMMON)
$(DOCKER_DHCP_SERVER)_DBG_DEPENDS = $($(DOCKER_CONFIG_ENGINE_BOOKWORM)_DBG_DEPENDS)

$(DOCKER_DHCP_SERVER)_DBG_IMAGE_PACKAGES = $($(DOCKER_CONFIG_ENGINE_BOOKWORM)_DBG_IMAGE_PACKAGES)

$(DOCKER_DHCP_SERVER)_LOAD_DOCKERS = $(DOCKER_CONFIG_ENGINE_BOOKWORM)

$(DOCKER_DHCP_SERVER)_INSTALL_DEBS = $(PYTHON3_SWSSCOMMON)
$(DOCKER_DHCP_SERVER)_PYTHON_WHEELS += $(SONIC_DHCP_UTILITIES_PY3)
$(DOCKER_DHCP_SERVER)_INSTALL_PYTHON_WHEELS = $(SONIC_UTILITIES_PY3)

SONIC_DOCKER_IMAGES += $(DOCKER_DHCP_SERVER)
SONIC_DOCKER_DBG_IMAGES += $(DOCKER_DHCP_SERVER_DBG)

ifeq ($(INCLUDE_KUBERNETES),y)
$(DOCKER_DHCP_SERVER)_DEFAULT_FEATURE_OWNER = kube
endif

$(DOCKER_DHCP_SERVER)_DEFAULT_FEATURE_STATE_ENABLED = y

ifeq ($(INCLUDE_DHCP_SERVER), y)
ifeq ($(INSTALL_DEBUG_TOOLS),y)
SONIC_PACKAGES_LOCAL += $(DOCKER_DHCP_SERVER_DBG)
else
SONIC_PACKAGES_LOCAL += $(DOCKER_DHCP_SERVER)
endif
endif

$(DOCKER_DHCP_SERVER)_CONTAINER_NAME = dhcp_server
$(DOCKER_DHCP_SERVER)_VERSION = 1.0.0
$(DOCKER_DHCP_SERVER)_PACKAGE_NAME = dhcp-server
$(DOCKER_DHCP_SERVER)_CONTAINER_VOLUMES += /etc/localtime:/etc/localtime:ro

$(DOCKER_DHCP_SERVER)_SERVICE_REQUIRES = config-setup
$(DOCKER_DHCP_SERVER)_SERVICE_AFTER = swss syncd

$(DOCKER_DHCP_SERVER)_CONTAINER_PRIVILEGED = false
$(DOCKER_DHCP_SERVER)_CONTAINER_VOLUMES += /etc/sonic:/etc/sonic:ro
$(DOCKER_DHCP_SERVER)_CONTAINER_TMPFS += /tmp/
$(DOCKER_DHCP_SERVER)_CONTAINER_TMPFS += /var/tmp/

$(DOCKER_DHCP_SERVER)_CLI_CONFIG_PLUGIN = /cli/config/plugins/dhcp_server.py
$(DOCKER_DHCP_SERVER)_CLI_SHOW_PLUGIN = /cli/show/plugins/show_dhcp_server.py
$(DOCKER_DHCP_SERVER)_CLI_CLEAR_PLUGIN = /cli/clear/plugins/clear_dhcp_server.py
$(DOCKER_DHCP_SERVER)_SUPPORT_RATE_LIMIT = false

