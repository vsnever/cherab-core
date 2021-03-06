# Copyright 2016-2018 Euratom
# Copyright 2016-2018 United Kingdom Atomic Energy Authority
# Copyright 2016-2018 Centro de Investigaciones Energéticas, Medioambientales y Tecnológicas
#
# Licensed under the EUPL, Version 1.1 or – as soon they will be approved by the
# European Commission - subsequent versions of the EUPL (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#
# https://joinup.ec.europa.eu/software/page/eupl5
#
# Unless required by applicable law or agreed to in writing, software distributed
# under the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied.
#
# See the Licence for the specific language governing permissions and limitations
# under the Licence.

from raysect.core.math.vector cimport Vector3D
from raysect.core.math.function cimport Function3D


cdef class VectorFunction3D:

    cdef Vector3D evaluate(self, double x, double y, double z)


cdef class PythonVectorFunction3D(VectorFunction3D):

    cdef public object function


cdef VectorFunction3D autowrap_vectorfunction3d(object function)


cdef class ScalarToVectorFunction3D(VectorFunction3D):

    cdef Function3D _x, _y, _z
