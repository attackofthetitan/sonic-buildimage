#!/usr/bin/env python

import os
import sys
from setuptools import setup
os.listdir

setup(
   name='ag9032v1',
   version='1.0',
   description='Module to initialize ag9032v1 platforms',
   
   packages=['ag9032v1'],
   package_dir={'ag9032v1': 'ag9032v1'},
)
