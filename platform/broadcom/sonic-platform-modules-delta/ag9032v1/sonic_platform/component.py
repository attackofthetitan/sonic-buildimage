#!/usr/bin/env python

#############################################################################
# PDDF
# Module contains an implementation of SONiC Platform Base API and
# provides the component firmware management function
#############################################################################

try:
    from sonic_platform_pddf_base.pddf_component import PddfComponent
except ImportError as e:
    raise ImportError(str(e) + "- required module not found")


class Component(PddfComponent):
    """Platform-specific Component class for AG9032v1"""

    def __init__(self, index, pddf_data=None, pddf_plugin_data=None):
        PddfComponent.__init__(self, index, pddf_data, pddf_plugin_data)
