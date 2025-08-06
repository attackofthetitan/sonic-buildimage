from setuptools import setup

setup(
    name='sonic-platform-ag9032v1',
    version='1.0',
    description='SONiC platform API implementation for Delta AG9032v1',
    packages=['sonic_platform'],
    package_dir={'sonic_platform': 'ag9032v1/pddf/sonic_platform'},
    data_files=[
        ('/usr/share/sonic/device/x86_64-delta_ag9032v1-r0/', ['ag9032v1/pddf/cfg/ag9032v1-pddf.json']),
    ],
)