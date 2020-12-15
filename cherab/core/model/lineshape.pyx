# cython: language_level=3

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

import numpy as np
cimport numpy as np
from libc.math cimport sqrt, erf, M_SQRT2, floor, ceil, fabs
from raysect.optical.spectrum cimport new_spectrum

from cherab.core cimport Plasma
from cherab.core.math.function cimport autowrap_function1d, autowrap_function2d
from cherab.core.utility.constants cimport ATOMIC_MASS, ELEMENTARY_CHARGE, SPEED_OF_LIGHT

cimport cython

# required by numpy c-api
np.import_array()


cdef double RECIP_ATOMIC_MASS = 1 / ATOMIC_MASS


cdef double evamu_to_ms(double x):
    return sqrt(2 * x * ELEMENTARY_CHARGE * RECIP_ATOMIC_MASS)


@cython.cdivision(True)
cpdef double doppler_shift(double wavelength, Vector3D observation_direction, Vector3D velocity):
    """
    Calculates the Doppler shifted wavelength for a given velocity and observation direction.

    :param wavelength: The wavelength to Doppler shift in nanometers.
    :param observation_direction: A Vector defining the direction of observation.
    :param velocity: A Vector defining the relative velocity of the emitting source in m/s.
    :return: The Doppler shifted wavelength in nanometers.
    """
    cdef double projected_velocity

    # flow velocity projected on the direction of observation
    observation_direction = observation_direction.normalise()
    projected_velocity = velocity.dot(observation_direction)

    return wavelength * (1 + projected_velocity / SPEED_OF_LIGHT)


@cython.cdivision(True)
cpdef double thermal_broadening(double wavelength, double temperature, double atomic_weight):
    """
    Returns the line width for a gaussian line as a standard deviation.  
    
    :param wavelength: Central wavelength.
    :param temperature: Temperature in eV.
    :param atomic_weight: Atomic weight in AMU.
    :return: Standard deviation of gaussian line. 
    """

    # todo: add input sanity checks
    return sqrt(temperature * ELEMENTARY_CHARGE / (atomic_weight * ATOMIC_MASS)) * wavelength / SPEED_OF_LIGHT


# the number of standard deviations outside the rest wavelength the line is considered to add negligible value (including a margin for safety)
DEF GAUSSIAN_CUTOFF_SIGMA=10.0


@cython.cdivision(True)
@cython.initializedcheck(False)
@cython.boundscheck(False)
@cython.wraparound(False)
cpdef Spectrum add_gaussian_line(double radiance, double wavelength, double sigma, Spectrum spectrum):
    """
    Adds a Gaussian line to the given spectrum and returns the new spectrum.

    The formula used is based on the following definite integral:
    :math:`\frac{1}{\sigma \sqrt{2 \pi}} \int_{\lambda_0}^{\lambda_1} \exp(-\frac{(x-\mu)^2}{2\sigma^2}) dx =
           \frac{1}{2} \left[ -Erf(\frac{a-\mu}{\sqrt{2}\sigma}) +Erf(\frac{b-\mu}{\sqrt{2}\sigma}) \right]`

    :param float radiance: Intensity of the line in radiance.
    :param float wavelength: central wavelength of the line in nm.
    :param float sigma: width of the line in nm.
    :param Spectrum spectrum: the current spectrum to which the gaussian line is added.
    :return:
    """

    cdef double temp
    cdef double cutoff_lower_wavelength, cutoff_upper_wavelength
    cdef double lower_wavelength, upper_wavelength
    cdef double lower_integral, upper_integral
    cdef int start, end, i

    if sigma <= 0:
        return spectrum

    # calculate and check end of limits
    cutoff_lower_wavelength = wavelength - GAUSSIAN_CUTOFF_SIGMA * sigma
    if spectrum.max_wavelength < cutoff_lower_wavelength:
        return spectrum

    cutoff_upper_wavelength = wavelength + GAUSSIAN_CUTOFF_SIGMA * sigma
    if spectrum.min_wavelength > cutoff_upper_wavelength:
        return spectrum

    # locate range of bins where there is significant contribution from the gaussian (plus a health margin)
    start = max(0, <int> floor((cutoff_lower_wavelength - spectrum.min_wavelength) / spectrum.delta_wavelength))
    end = min(spectrum.bins, <int> ceil((cutoff_upper_wavelength - spectrum.min_wavelength) / spectrum.delta_wavelength))

    # add line to spectrum
    temp = 1 / (M_SQRT2 * sigma)
    lower_wavelength = spectrum.min_wavelength + start * spectrum.delta_wavelength
    lower_integral = erf((lower_wavelength - wavelength) * temp)
    for i in range(start, end):

        upper_wavelength = spectrum.min_wavelength + spectrum.delta_wavelength * (i + 1)
        upper_integral = erf((upper_wavelength - wavelength) * temp)

        spectrum.samples_mv[i] += radiance * 0.5 * (upper_integral - lower_integral) / spectrum.delta_wavelength

        lower_wavelength = upper_wavelength
        lower_integral = upper_integral

    return spectrum


cdef class LineShapeModel:
    """
    A base class for building line shapes.

    :param Line line: The emission line object for this line shape.
    :param float wavelength: The rest wavelength for this emission line.
    :param Species target_species: The target plasma species that is emitting.
    :param Plasma plasma: The emitting plasma object.
    """

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma):

        self.line = line
        self.wavelength = wavelength
        self.target_species = target_species
        self.plasma = plasma

    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):
        raise NotImplementedError('Child lineshape class must implement this method.')


cdef class GaussianLine(LineShapeModel):

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma):

        super().__init__(line, wavelength, target_species, plasma)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef double ts, sigma, shifted_wavelength
        cdef Vector3D ion_velocity

        ts = self.target_species.distribution.effective_temperature(point.x, point.y, point.z)
        if ts <= 0.0:
            return spectrum

        ion_velocity = self.target_species.distribution.bulk_velocity(point.x, point.y, point.z)

        # calculate emission line central wavelength, doppler shifted along observation direction
        shifted_wavelength = doppler_shift(self.wavelength, direction, ion_velocity)

        # calculate the line width
        sigma = thermal_broadening(self.wavelength, ts, self.line.element.atomic_weight)

        return add_gaussian_line(radiance, shifted_wavelength, sigma, spectrum)


DEF MULTIPLET_WAVELENGTH = 0
DEF MULTIPLET_RATIO = 1


cdef class MultipletLineShape(LineShapeModel):
    """
    Produces Multiplet line shapes.

    The lineshape radiance is calculated from a base PEC rate that is unresolved. This
    radiance is then divided over a number of components as specified in the multiplet
    argument. The multiplet components are specified with an Nx2 array where N is the
    number of components in the multiplet. The first axis of the array contains the
    wavelengths of each component, the second contains the line ratio for each component.
    The component line ratios must sum to one. For example:

    :param Line line: The emission line object for the base rate radiance calculation.
    :param float wavelength: The rest wavelength of the base emission line.
    :param Species target_species: The target plasma species that is emitting.
    :param Plasma plasma: The emitting plasma object.
    :param multiplet: An Nx2 array that specifies the multiplet wavelengths and line ratios.

    .. code-block:: pycon

       >>> from cherab.core.atomic import Line, deuterium
       >>> from cherab.core.model import ExcitationLine, MultipletLineShape
       >>>
       >>> # multiplet specification in Nx2 array
       >>> multiplet = [[403.5, 404.1, 404.3], [0.2, 0.5, 0.3]]
       >>>
       >>> # Adding the multiplet to the plasma model.
       >>> d_alpha = Line(deuterium, 0, (3, 2))
       >>> excit = ExcitationLine(d_alpha, lineshape=MultipletLineShape, lineshape_args=[multiplet])
       >>> plasma.models.add(excit)
    """

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma,
                 object multiplet):

        super().__init__(line, wavelength, target_species, plasma)

        multiplet = np.array(multiplet, dtype=np.float64)

        if not (len(multiplet.shape) == 2 and multiplet.shape[0] == 2):
            raise ValueError("The multiplet specification must be an array of shape (Nx2).")

        if not multiplet[1,:].sum() == 1.0:
            raise ValueError("The multiplet line ratios should sum to one.")

        self._number_of_lines = multiplet.shape[1]
        self._multiplet = multiplet
        self._multiplet_mv = self._multiplet

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef double ts, sigma, shifted_wavelength, component_wavelength, component_radiance
        cdef Vector3D ion_velocity

        ts = self.target_species.distribution.effective_temperature(point.x, point.y, point.z)
        if ts <= 0.0:
            return spectrum

        ion_velocity = self.target_species.distribution.bulk_velocity(point.x, point.y, point.z)

        # calculate the line width
        sigma = thermal_broadening(self.wavelength, ts, self.line.element.atomic_weight)

        for i in range(self._number_of_lines):

            component_wavelength = self._multiplet_mv[MULTIPLET_WAVELENGTH, i]
            component_radiance = radiance * self._multiplet_mv[MULTIPLET_RATIO, i]

            # calculate emission line central wavelength, doppler shifted along observation direction
            shifted_wavelength = doppler_shift(component_wavelength, direction, ion_velocity)

            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

        return spectrum


cdef class StarkBroadenedLine(LineShapeModel):

    # Parametrised Microfield Method Stark profile coefficients.
    # Contains embedded atomic data in the form of fits to numerical models.
    # Only a limited range of lines is supported.
    # See B. Lomanowski, et al. "Inferring divertor plasma properties from hydrogen Balmer
    # and Paschen series spectroscopy in JET-ILW." Nuclear Fusion 55.12 (2015): 123028.
    STARK_MODEL_COEFFICIENTS = {
        (3, 2): (3.71e-18, 0.7665, 0.064),
        (4, 2): (8.425e-18, 0.7803, 0.050),
        (5, 2): (1.31e-15, 0.6796, 0.030),
        (6, 2): (3.954e-16, 0.7149, 0.028),
        (7, 2): (6.258e-16, 0.712, 0.029),
        (8, 2): (7.378e-16, 0.7159, 0.032),
        (9, 2): (8.947e-16, 0.7177, 0.033),
        (4, 3): (1.330e-16, 0.7449, 0.045),
        (5, 3): (6.64e-16, 0.7356, 0.044),
        (6, 3): (2.481e-15, 0.7118, 0.016),
        (7, 3): (3.270e-15, 0.7137, 0.029),
        (8, 3): (4.343e-15, 0.7133, 0.032),
        (9, 3): (5.588e-15, 0.7165, 0.033),
    }

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma):

        if not line.element.atomic_number == 1:
            raise ValueError('Stark broadening coefficients only available for hydrogenic species.')
        try:
            # Fitted Stark Constants
            cij, aij, bij = self.STARK_MODEL_COEFFICIENTS[line.transition]
            self._aij = aij
            self._bij = bij
            self._cij = cij
        except IndexError:
            raise ValueError('Stark data for H transition {} is not currently available.'.format(line.transition))

        super().__init__(line, wavelength, target_species, plasma)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef double ne, te, lambda_1_2, lambda_5_2, wvl
        cdef double cutoff_lower_wavelength, cutoff_upper_wavelength
        cdef double lower_value, lower_wavelength, upper_value, upper_wavelength
        cdef int start, end, i
        cdef Spectrum raw_lineshape

        ne = self.plasma.get_electron_distribution().density(point.x, point.y, point.z)
        if ne <= 0.0:
            return spectrum

        te = self.plasma.get_electron_distribution().effective_temperature(point.x, point.y, point.z)
        if te <= 0.0:
            return spectrum

        lambda_1_2 = self._cij * ne**self._aij / (te**self._bij)

        # calculate and check end of limits
        cutoff_lower_wavelength = self.wavelength - GAUSSIAN_CUTOFF_SIGMA * lambda_1_2
        if spectrum.max_wavelength < cutoff_lower_wavelength:
            return spectrum

        cutoff_upper_wavelength = self.wavelength + GAUSSIAN_CUTOFF_SIGMA * lambda_1_2
        if spectrum.min_wavelength > cutoff_upper_wavelength:
            return spectrum

        # locate range of bins where there is significant contribution from the gaussian (plus a health margin)
        start = max(0, <int> floor((cutoff_lower_wavelength - spectrum.min_wavelength) / spectrum.delta_wavelength))
        end = min(spectrum.bins, <int> ceil((cutoff_upper_wavelength - spectrum.min_wavelength) / spectrum.delta_wavelength))

        # TODO - replace with cumulative integrals
        # add line to spectrum
        raw_lineshape = spectrum.new_spectrum()

        lower_wavelength = raw_lineshape.min_wavelength + start * raw_lineshape.delta_wavelength
        lower_value = 1 / ((fabs(lower_wavelength - self.wavelength))**2.5 + (0.5*lambda_1_2)**2.5)
        for i in range(start, end):

            upper_wavelength = raw_lineshape.min_wavelength + raw_lineshape.delta_wavelength * (i + 1)
            upper_value = 1 / ((fabs(upper_wavelength - self.wavelength))**2.5 + (0.5*lambda_1_2)**2.5)

            raw_lineshape.samples_mv[i] += 0.5 * (upper_value + lower_value)

            lower_wavelength = upper_wavelength
            lower_value = upper_value

        # perform normalisation
        raw_lineshape.div_scalar(raw_lineshape.total())

        for i in range(start, end):
            # Radiance ???
            spectrum.samples_mv[i] += radiance * raw_lineshape.samples_mv[i]

        return spectrum


DEF BOHR_MAGNETON = 5.78838180123e-5  # in eV/T
DEF HC_EV_NM = 1239.8419738620933  # (Planck constant in eV s) x (speed of light in nm/s)

DEF PI_POLARISATION = 0
DEF SIGMA_POLARISATION = 1
DEF NO_POLARISATION = 2


cdef class ZeemanLineShapeModel(LineShapeModel):

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma, polarisation):
        super().__init__(line, wavelength, target_species, plasma)

        self.polarisation = polarisation

    @property
    def polarisation(self):
        if self._polarisation == PI_POLARISATION:
            return 'pi'
        if self._polarisation == SIGMA_POLARISATION:
            return 'sigma'
        if self._polarisation == NO_POLARISATION:
            return 'no'

    @polarisation.setter
    def polarisation(self, value):
        if value == 'pi':
            self._polarisation = PI_POLARISATION
        elif value == 'sigma':
            self._polarisation = SIGMA_POLARISATION
        elif value == 'no':
            self._polarisation = NO_POLARISATION
        else:
            raise ValueError('Select between "pi", "sigma" or "no", {} is unsupported.'.format(value))


cdef class ZeemanTriplet(ZeemanLineShapeModel):

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma, polarisation='no'):
        """
        Simple Dopple-Zeeman triplet.

        :param Line line: The emission line object for this line shape.
        :param float wavelength: The rest wavelength for this emission line.
        :param Species target_species: The target plasma species that is emitting.
        :param Plasma plasma: The emitting plasma object.
        :param polarisation: Calculate only pi/sigma-polarised components of Zeeman triplet:
                             "pi" - central component,
                             "sigma" - side components,
                             "no" - all components (default).
        """

        super().__init__(line, wavelength, target_species, plasma, polarisation)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef double ts, sigma, shifted_wavelength, photon_energy, b_magn, component_radiance, cos_sqr, sin_sqr
        cdef Vector3D ion_velocity, b_field

        ts = self.target_species.distribution.effective_temperature(point.x, point.y, point.z)
        if ts <= 0.0:
            return spectrum

        ion_velocity = self.target_species.distribution.bulk_velocity(point.x, point.y, point.z)

        # calculate emission line central wavelength, doppler shifted along observation direction
        shifted_wavelength = doppler_shift(self.wavelength, direction, ion_velocity)

        # calculate the line width
        sigma = thermal_broadening(self.wavelength, ts, self.line.element.atomic_weight)

        # obtain magnetic field
        b_field = self.plasma.get_b_field().evaluate(point.x, point.y, point.z)
        b_magn = b_field.get_length()

        if b_magn == 0:
            # no splitting if magnetic filed strength is zero
            if self._polarisation == NO_POLARISATION:
                return add_gaussian_line(radiance, shifted_wavelength, sigma, spectrum)

            return add_gaussian_line(0.5 * radiance, shifted_wavelength, sigma, spectrum)

        # coefficients for intensities parallel and perpendicular to magnetic field
        cos_sqr = (b_field.dot(direction.normalise()) / b_magn)**2
        sin_sqr = 1. - cos_sqr

        # adding pi component of the Zeeman triplet
        if self._polarisation != SIGMA_POLARISATION:
            component_radiance = 0.5 * sin_sqr * radiance
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

        # adding sigma +/- components of the Zeeman triplet
        if self._polarisation != PI_POLARISATION:
            component_radiance = (0.25 * sin_sqr + 0.5 * cos_sqr) * radiance

            photon_energy = HC_EV_NM / self.wavelength

            shifted_wavelength = doppler_shift(HC_EV_NM / (photon_energy - BOHR_MAGNETON * b_magn), direction, ion_velocity)
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

            shifted_wavelength = doppler_shift(HC_EV_NM / (photon_energy + BOHR_MAGNETON * b_magn), direction, ion_velocity)
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

        return spectrum


cdef class ParametrisedZeemanTriplet(ZeemanLineShapeModel):

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma, alpha=None, beta=None, gamma=None, polarisation='no'):
        """
        Parametrised Dopple-Zeeman triplet that takes into account additional broadening due to
        the line's fine structure without resolving the individual components of the fine
        structure. The model is described with three parameters: \alpha, \beta and \gamma.

        The distance between :math:`\sigma^+` and :math:`\sigma^-` peaks: 
        :math:`\Delta \lambda_{\sigma}=\alpha B`, 
        where B is the magnetic field strength.
        The ratio between Zeeman and thermal broadening line widths:
        :math:`\frac{W_{Zeeman}}{W_{Doppler}}=\beta T^{\gamma}`,
        where T is the species temperature in eV.
        If `\alpha` is not provided and the spectral line is not in the database, it's calculated
        as `\alpha = 2\frac{\mu_{0}}{\lambda_{0}^{2}hc}`,
        where `\mu_{0}` is the Bohr magneton and `\lambda_{0}` is the rest wavelength of this line.

        For details see A. Blom and C. Jupén, Parametrisation of the Zeeman effect
        for hydrogen-like spectra in high-temperature plasmas,
        Plasma Phys. Control. Fusion 44 (2002) 1229-1241, 
        https://doi.org/10.1088/0741-3335/44/7/312

        :param Line line: The emission line object for this line shape.
        :param float wavelength: The rest wavelength for this emission line.
        :param Species target_species: The target plasma species that is emitting.
        :param Plasma plasma: The emitting plasma object.
        :param float alpha: Parameter alpha, defaults to None. Used only if the given spectral
                            line is not in the database.
        :param float beta:  Parameter beta, defaults to None. Used only if the given spectral
                            line is not in the database.
        :param float gamma: Parameter gamma, defaults to None. Used only if the given spectral
                            line is not in the database.
        :param polarisation: Calculate only pi/sigma-polarised components of Zeeman triplet:
                             "pi" - central component,
                             "sigma" - side components,
                             "no" - all components (default).
        """
        LINE_PARAMETERS = {  # alpha, beta, gamma parameters for selected lines
            ('H', 0): {
                (3, 2): (0.0402267, 0.3415, -0.5247),
                (4, 2): (0.0220724, 0.2837, -0.5346)
            },
            ('D', 0): {
                (3, 2): (0.0402068, 0.4384, -0.5015),
                (4, 2): (0.0220610, 0.3702, -0.5132)
            },
            ('He3', 1): {
                (4, 3): (0.0205200, 1.4418, -0.4892),
                (5, 3): (0.0095879, 1.2576, -0.5001),
                (6, 4): (0.0401980, 0.8976, -0.4971),
                (7, 4): (0.0273538, 0.8529, -0.5039)
            },
            ('He', 1): {
                (4, 3): (0.0205206, 1.6118, -0.4838),
                (5, 3): (0.0095879, 1.4294, -0.4975),
                (6, 4): (0.0401955, 1.0058, -0.4918),
                (7, 4): (0.0273521, 0.9563, -0.4981)
            },
            ('Be', 3): {
                (5, 4): (0.0060354, 2.1245, -0.3190),
                (6, 5): (0.0202754, 1.6538, -0.3192),
                (7, 5): (0.0078966, 1.7017, -0.3348),
                (8, 6): (0.0205025, 1.4581, -0.3450)
            },
            ('B', 4): {
                (6, 5): (0.0083423, 2.0519, -0.2960),
                (7, 6): (0.0228379, 1.6546, -0.2941),
                (8, 6): (0.0084065, 1.8041, -0.3177),
                (8, 7): (0.0541883, 1.4128, -0.2966),
                (9, 7): (0.0190781, 1.5440, -0.3211),
                (10, 8): (0.0391914, 1.3569, -0.3252)
            },
            ('C', 5): {
                (6, 5): (0.0040900, 2.4271, -0.2818),
                (7, 6): (0.0110398, 1.9785, -0.2816),
                (8, 6): (0.0040747, 2.1776, -0.3035),
                (8, 7): (0.0261405, 1.6689, -0.2815),
                (9, 7): (0.0092096, 1.8495, -0.3049),
                (10, 8): (0.0189020, 1.6191, -0.3078),
                (11, 8): (0.0110428, 1.6600, -0.3162),
                (11, 9): (0.0359009, 1.4464, -0.3104)
            },
            ('N', 6): {
                (7, 6): (0.0060010, 2.4789, -0.2817),
                (8, 7): (0.0141271, 2.0249, -0.2762),
                (9, 8): (0.0300127, 1.7415, -0.2753),
                (10, 8): (0.0102089, 1.9464, -0.2975),
                (11, 9): (0.0193799, 1.7133, -0.2973)
            },
            ('O', 7): {
                (8, 7): (0.0083081, 2.4263, -0.2747),
                (9, 8): (0.0176049, 2.0652, -0.2721),
                (10, 8): (0.0059933, 2.3445, -0.2944),
                (10, 9): (0.0343805, 1.8122, -0.2718),
                (11, 9): (0.0113640, 2.0268, -0.2911)
            },
            ('Ne', 9): {
                (9, 8): (0.0072488, 2.8838, -0.2758),
                (10, 9): (0.0141002, 2.4755, -0.2718),
                (11, 9): (0.0046673, 2.8410, -0.2917),
                (11, 10): (0.0257292, 2.1890, -0.2715)
            }
        }
        LINE_PARAMETERS[('He4', 1)] = LINE_PARAMETERS[('He', 1)]
        LINE_PARAMETERS[('B11', 4)] = LINE_PARAMETERS[('B', 4)]
        LINE_PARAMETERS[('C12', 5)] = LINE_PARAMETERS[('C', 5)]
        LINE_PARAMETERS[('N14', 6)] = LINE_PARAMETERS[('N', 6)]
        LINE_PARAMETERS[('O16', 7)] = LINE_PARAMETERS[('O', 7)]
        LINE_PARAMETERS[('Ne20', 9)] = LINE_PARAMETERS[('Ne', 9)]

        super().__init__(line, wavelength, target_species, plasma, polarisation)

        try:
            _alpha, _beta, _gamma = LINE_PARAMETERS[(self.line.element.symbol, self.line.charge)][self.line.transition]
            self._alpha = _alpha
            self._beta = _beta
            self._gamma = _gamma
        except KeyError:
            if beta is None or gamma is None:
                raise ValueError('Data for {} {}+ transition {} is not currently available.'.format(self.line.element.symbol,
                                                                                                    self.line.charge,
                                                                                                    self.line.transition))
            if alpha is None:
                # assign simple triplet value (error < 0.0001 nm for tested lines)
                self._alpha = 2. * BOHR_MAGNETON * self.wavelength * self.wavelength / HC_EV_NM
            elif alpha <= 0:
                raise ValueError('Parameter alpha must be positive.')
            else:
                self._alpha = alpha

            if beta < 0:
                raise ValueError('Parameter beta must be non-negative.')
            self._beta = beta
            self._gamma = gamma

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef double ts, sigma, shifted_wavelength, b_magn, component_radiance, cos_sqr, sin_sqr
        cdef Vector3D ion_velocity, b_field

        ts = self.target_species.distribution.effective_temperature(point.x, point.y, point.z)
        if ts <= 0.0:
            return spectrum

        ion_velocity = self.target_species.distribution.bulk_velocity(point.x, point.y, point.z)

        # calculate emission line central wavelength, doppler shifted along observation direction
        shifted_wavelength = doppler_shift(self.wavelength, direction, ion_velocity)

        # calculate the line width
        sigma = thermal_broadening(self.wavelength, ts, self.line.element.atomic_weight)

        # fine structure broadening correction
        sigma *= sqrt(1. + self._beta * self._beta * ts**(2. * self._gamma))

        # obtain magnetic field
        b_field = self.plasma.get_b_field().evaluate(point.x, point.y, point.z)
        b_magn = b_field.get_length()

        if b_magn == 0:
            # no splitting if magnetic filed strength is zero
            if self._polarisation == NO_POLARISATION:
                return add_gaussian_line(radiance, shifted_wavelength, sigma, spectrum)

            return add_gaussian_line(0.5 * radiance, shifted_wavelength, sigma, spectrum)

        # coefficients for intensities parallel and perpendicular to magnetic field
        cos_sqr = (b_field.dot(direction.normalise()) / b_magn)**2
        sin_sqr = 1. - cos_sqr

        # adding pi component of the Zeeman triplet
        if self._polarisation != SIGMA_POLARISATION:
            component_radiance = 0.5 * sin_sqr * radiance
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

        # adding sigma +/- components of the Zeeman triplet
        if self._polarisation != PI_POLARISATION:
            component_radiance = (0.25 * sin_sqr + 0.5 * cos_sqr) * radiance

            shifted_wavelength = doppler_shift(self.wavelength + 0.5 * self._alpha * b_magn, direction, ion_velocity)
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)
            shifted_wavelength = doppler_shift(self.wavelength - 0.5 * self._alpha * b_magn, direction, ion_velocity)
            spectrum = add_gaussian_line(component_radiance, shifted_wavelength, sigma, spectrum)

        return spectrum


cdef class ZeemanSplittingFunction():

    def __init__(self, wavelengths_pi, ratios_pi, wavelengths_sigma, ratios_sigma):

        if len(wavelengths_pi) != len(ratios_pi):
            raise ValueError('The lengths of "wavelengths_pi" ({}) and "ratios_pi" ({}) do not match.'.format(len(wavelengths_pi),
                                                                                                              len(ratios_pi)))

        if len(wavelengths_sigma) != len(ratios_sigma):
            raise ValueError('The lengths of "wavelengths_sigma" ({}) and "ratios_sigma" ({}) do not match.'.format(len(wavelengths_sigma),
                                                                                                                    len(ratios_sigma)))

        self._number_of_pi_lines = len(wavelengths_pi)
        self._number_of_sigma_lines = len(wavelengths_sigma)

        self._wavelengths = wavelengths_pi + wavelengths_sigma
        self._ratios = ratios_pi + ratios_sigma

        for wavelength in self._wavelengths:
            if not isinstance(wavelength, Function1D):
                raise ValueError('All elements in "wavelengths_pi" and "wavelengths_sigma" lists must be Function1D instances.')

        for ratio in self._ratios:
            if not isinstance(ratio, Function1D):
                raise ValueError('All elements in "ratios_pi" and "ratios_sigma" lists must be Function1D instances.')

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cdef double[:, :] evaluate(self, double b, bint polarisation):

        cdef int i, start, number_of_lines
        cdef np.npy_intp multiplet_shape[2]
        cdef double ratio_sum
        cdef np.ndarray multiplet
        cdef double[:, :] multiplet_mv
        cdef Function1D wavelength, ratio

        if polarisation == PI_POLARISATION:
            start = 0
            number_of_lines = self._number_of_pi_lines
        else:
            start = self._number_of_pi_lines
            number_of_lines = self._number_of_sigma_lines

        multiplet_shape[0] = 2
        multiplet_shape[1] = number_of_lines
        multiplet = np.PyArray_SimpleNew(2, multiplet_shape, np.NPY_FLOAT64)
        multiplet_mv = multiplet

        ratio_sum = 0
        for i in range(number_of_lines):
            wavelength = self._wavelengths[start + i]
            ratio = self._ratios[start + i]
            multiplet_mv[MULTIPLET_WAVELENGTH, i] = wavelength.evaluate(b)
            multiplet_mv[MULTIPLET_RATIO, i] = ratio.evaluate(b)
            ratio_sum += multiplet_mv[1, i]

        # normalising ratios
        if ratio_sum > 0:
            for i in range(number_of_lines):
                multiplet_mv[1, i] /= ratio_sum

        return multiplet_mv

    def __call__(self, double b, str polarisation):

        if polarisation == 'pi':
            return np.asarray(self.evaluate(b, PI_POLARISATION))

        if polarisation == 'sigma':
            return np.asarray(self.evaluate(b, SIGMA_POLARISATION))

        raise ValueError('Argument "polarisation" must be "pi" or "sigma", {} given.'.fotmat(polarisation))


cdef class ZeemanMultiplet(ZeemanLineShapeModel):
    """
    Doppler-Zeeman Multiplet.

    The lineshape radiance is calculated from a base PEC rate that is unresolved. This
    radiance is then divided over a number of components as specified in the multiplet
    argument. The multiplet components are specified with an Nx2 array where N is the
    number of components in the multiplet. The first axis of the array contains the
    wavelengths of each component, the second contains the line ratio for each component.
    The component line ratios must sum to one. For example:

    :param Line line: The emission line object for the base rate radiance calculation.
    :param float wavelength: The rest wavelength of the base emission line.
    :param Species target_species: The target plasma species that is emitting.
    :param Plasma plasma: The emitting plasma object.
    :param splitting_function: A ZeemanSplittingFunction object that provides wavelengths and ratios
                               of pi-/sigma-polarised components for any given magnetic field strength.
    :param polarisation: Calculate only pi/sigma-polarised components of Zeeman multiplet:
                         "pi", "sigma" or "no" (default).

    """

    def __init__(self, Line line, double wavelength, Species target_species, Plasma plasma,
                 ZeemanSplittingFunction splitting_function, polarisation='no'):

        super().__init__(line, wavelength, target_species, plasma, polarisation)

        self._splitting_function = splitting_function

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.initializedcheck(False)
    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D point, Vector3D direction, Spectrum spectrum):

        cdef int i
        cdef double ts, sigma, shifted_wavelength, component_radiance
        cdef Vector3D ion_velocity
        cdef double[:, :] multiplet_pi_mv, multiplet_sigma_mv

        ts = self.target_species.distribution.effective_temperature(point.x, point.y, point.z)
        if ts <= 0.0:
            return spectrum

        ion_velocity = self.target_species.distribution.bulk_velocity(point.x, point.y, point.z)

        # calculate the line width
        sigma = thermal_broadening(self.wavelength, ts, self.line.element.atomic_weight)

        # obtain magnetic field
        b_field = self.plasma.get_b_field().evaluate(point.x, point.y, point.z)
        b_magn = b_field.get_length()

        if b_magn == 0:
            # no splitting if magnetic filed strength is zero
            shifted_wavelength = doppler_shift(self.wavelength, direction, ion_velocity)
            if self._polarisation == NO_POLARISATION:
                return add_gaussian_line(radiance, shifted_wavelength, sigma, spectrum)

            return add_gaussian_line(0.5 * radiance, shifted_wavelength, sigma, spectrum)

        # coefficients for intensities parallel and perpendicular to magnetic field
        cos_sqr = (b_field.dot(direction.normalise()) / b_magn)**2
        sin_sqr = 1. - cos_sqr

        # adding pi components of the Zeeman multiplet
        if self._polarisation != SIGMA_POLARISATION:
            component_radiance = 0.5 * sin_sqr * radiance
            multiplet_mv = self._splitting_function.evaluate(b_magn, PI_POLARISATION)

            for i in range(multiplet_mv.shape[1]):
                shifted_wavelength = doppler_shift(multiplet_mv[MULTIPLET_WAVELENGTH, i], direction, ion_velocity)
                spectrum = add_gaussian_line(component_radiance * multiplet_mv[MULTIPLET_RATIO, i], shifted_wavelength, sigma, spectrum)

        # adding sigma components of the Zeeman multiplet
        if self._polarisation != PI_POLARISATION:
            component_radiance = (0.5 * sin_sqr + cos_sqr) * radiance
            multiplet_mv = self._splitting_function.evaluate(b_magn, SIGMA_POLARISATION)

            for i in range(multiplet_mv.shape[1]):
                shifted_wavelength = doppler_shift(multiplet_mv[MULTIPLET_WAVELENGTH, i], direction, ion_velocity)
                spectrum = add_gaussian_line(component_radiance * multiplet_mv[MULTIPLET_RATIO, i], shifted_wavelength, sigma, spectrum)

        return spectrum


cdef class BeamLineShapeModel:
    """
    A base class for building beam emission line shapes.

    :param Line line: The emission line object for this line shape.
    :param float wavelength: The rest wavelength for this emission line.
    :param Beam beam: The beam class that is emitting.
    """

    def __init__(self, Line line, double wavelength, Beam beam):

        self.line = line
        self.wavelength = wavelength
        self.beam = beam

    cpdef Spectrum add_line(self, double radiance, Point3D beam_point, Point3D plasma_point,
                            Vector3D beam_direction, Vector3D observation_direction, Spectrum spectrum):
        raise NotImplementedError('Child lineshape class must implement this method.')


DEF STARK_SPLITTING_FACTOR = 2.77e-8


cdef class BeamEmissionMultiplet(BeamLineShapeModel):
    """
    Produces Beam Emission Multiplet line shape, also known as the Motional Stark Effect spectrum.
    """

    def __init__(self, Line line, double wavelength, Beam beam, object sigma_to_pi,
                 object sigma1_to_sigma0, object pi2_to_pi3, object pi4_to_pi3):

        super().__init__(line, wavelength, beam)

        self._sigma_to_pi = autowrap_function2d(sigma_to_pi)
        self._sigma1_to_sigma0 = autowrap_function1d(sigma1_to_sigma0)
        self._pi2_to_pi3 = autowrap_function1d(pi2_to_pi3)
        self._pi4_to_pi3 = autowrap_function1d(pi4_to_pi3)

    @cython.cdivision(True)
    cpdef Spectrum add_line(self, double radiance, Point3D beam_point, Point3D plasma_point,
                            Vector3D beam_direction, Vector3D observation_direction, Spectrum spectrum):

        cdef double x, y, z
        cdef Plasma plasma
        cdef double te, ne, beam_energy, sigma, stark_split, beam_ion_mass, beam_temperature
        cdef double natural_wavelength, central_wavelength
        cdef double sigma_to_pi, d, intensity_sig, intensity_pi, e_field
        cdef double s1_to_s0, intensity_s0, intensity_s1
        cdef double pi2_to_pi3, pi4_to_pi3, intensity_pi2, intensity_pi3, intensity_pi4
        cdef Vector3D b_field, beam_velocity

        # extract for more compact code
        x = plasma_point.x
        y = plasma_point.y
        z = plasma_point.z

        plasma = self.beam.get_plasma()

        te = plasma.get_electron_distribution().effective_temperature(x, y, z)
        if te <= 0.0:
            return spectrum

        ne = plasma.get_electron_distribution().density(x, y, z)
        if ne <= 0.0:
            return spectrum

        beam_energy = self.beam.get_energy()

        # calculate Stark splitting
        b_field = plasma.get_b_field().evaluate(x, y, z)
        beam_velocity = beam_direction.normalise().mul(evamu_to_ms(beam_energy))
        e_field = beam_velocity.cross(b_field).get_length()
        stark_split = fabs(STARK_SPLITTING_FACTOR * e_field)  # TODO - calculate splitting factor? Reject other lines?

        # calculate emission line central wavelength, doppler shifted along observation direction
        natural_wavelength = self.wavelength
        central_wavelength = doppler_shift(natural_wavelength, observation_direction, beam_velocity)

        # calculate doppler broadening
        beam_ion_mass = self.beam.get_element().atomic_weight
        beam_temperature = self.beam.get_temperature()
        sigma = thermal_broadening(self.wavelength, beam_temperature, beam_ion_mass)

        # calculate relative intensities of sigma and pi lines
        sigma_to_pi = self._sigma_to_pi.evaluate(ne, beam_energy)
        d = 1 / (1 + sigma_to_pi)
        intensity_sig = sigma_to_pi * d * radiance
        intensity_pi = 0.5 * d * radiance

        # add Sigma lines to output
        s1_to_s0 = self._sigma1_to_sigma0.evaluate(ne)
        intensity_s0 = 1 / (s1_to_s0 + 1)
        intensity_s1 = 1 / (1 + 2 / s1_to_s0)

        spectrum = add_gaussian_line(intensity_sig * intensity_s0, central_wavelength, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_sig * intensity_s1, central_wavelength + stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_sig * intensity_s1, central_wavelength - stark_split, sigma, spectrum)

        # add Pi lines to output
        pi2_to_pi3 = self._pi2_to_pi3.evaluate(ne)
        pi4_to_pi3 = self._pi4_to_pi3.evaluate(ne)
        intensity_pi3 = 1 / (1 + pi2_to_pi3 + pi4_to_pi3)
        intensity_pi2 = pi2_to_pi3 * intensity_pi3
        intensity_pi4 = pi4_to_pi3 * intensity_pi3

        spectrum = add_gaussian_line(intensity_pi * intensity_pi2, central_wavelength + 2 * stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_pi * intensity_pi2, central_wavelength - 2 * stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_pi * intensity_pi3, central_wavelength + 3 * stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_pi * intensity_pi3, central_wavelength - 3 * stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_pi * intensity_pi4, central_wavelength + 4 * stark_split, sigma, spectrum)
        spectrum = add_gaussian_line(intensity_pi * intensity_pi4, central_wavelength - 4 * stark_split, sigma, spectrum)

        return spectrum
