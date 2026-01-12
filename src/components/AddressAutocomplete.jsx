import React, { useEffect, useRef, useState, useCallback } from 'react';
import { MapPin, Loader2, X, AlertCircle } from 'lucide-react';

/**
 * Componente de autocompletado de direcciones usando Google Places API
 *
 * Features:
 * - Autocompletado de direcciones con Google Places API
 * - Geocodificación automática (obtiene latitud/longitud)
 * - Location bias hacia San Miguel de Tucumán para priorizar resultados locales
 * - Esto evita que direcciones genéricas (ej: "Chacabuco 543") se geocodifiquen
 *   en ubicaciones incorrectas fuera de Tucumán
 */
export const AddressAutocomplete = ({
  value,
  onChange,
  onSelect,
  placeholder = 'Buscar dirección...',
  className = '',
  disabled = false
}) => {
  const inputRef = useRef(null);
  const autocompleteServiceRef = useRef(null);
  const placesServiceRef = useRef(null);
  const sessionTokenRef = useRef(null);
  const [loading, setLoading] = useState(false);
  const [googleStatus, setGoogleStatus] = useState('loading'); // 'loading', 'ready', 'error'
  const [predictions, setPredictions] = useState([]);
  const [showDropdown, setShowDropdown] = useState(false);
  const dropdownRef = useRef(null);

  // Verificar que Google Maps esté cargado
  useEffect(() => {
    let isMounted = true;
    let interval;
    let timeout;

    const checkGoogle = () => {
      // Verificar que exista el servicio de AutocompleteService (nueva API)
      if (window.google &&
          window.google.maps &&
          window.google.maps.places &&
          window.google.maps.places.AutocompleteService) {
        if (isMounted) {
          setGoogleStatus('ready');
        }
        return true;
      }
      return false;
    };

    // Verificar inmediatamente
    if (checkGoogle()) return;

    // Si no está listo, verificar cada 500ms
    interval = setInterval(() => {
      if (checkGoogle()) {
        clearInterval(interval);
        clearTimeout(timeout);
      }
    }, 500);

    // Timeout después de 15 segundos
    timeout = setTimeout(() => {
      clearInterval(interval);
      if (isMounted && !window.google?.maps?.places?.AutocompleteService) {
        setGoogleStatus('error');
      }
    }, 15000);

    return () => {
      isMounted = false;
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, []);

  // Inicializar servicios cuando Google esté listo
  useEffect(() => {
    if (googleStatus !== 'ready') return;

    try {
      // Crear AutocompleteService para obtener predicciones
      autocompleteServiceRef.current = new window.google.maps.places.AutocompleteService();

      // Crear un div oculto para PlacesService (requerido por la API)
      const mapDiv = document.createElement('div');
      mapDiv.style.display = 'none';
      document.body.appendChild(mapDiv);
      const map = new window.google.maps.Map(mapDiv);
      placesServiceRef.current = new window.google.maps.places.PlacesService(map);

      // Crear session token para agrupar requests
      sessionTokenRef.current = new window.google.maps.places.AutocompleteSessionToken();
    } catch (error) {
      setGoogleStatus('error');
    }
  }, [googleStatus]);

  // Cerrar dropdown cuando se hace click fuera
  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target) &&
          inputRef.current && !inputRef.current.contains(event.target)) {
        setShowDropdown(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Buscar predicciones cuando cambia el valor
  const fetchPredictions = useCallback((inputValue) => {
    if (!autocompleteServiceRef.current || !inputValue || inputValue.length < 3) {
      setPredictions([]);
      setShowDropdown(false);
      return;
    }

    setLoading(true);

    // Coordenadas de San Miguel de Tucumán para priorizar resultados locales
    const sanMiguelDeTucuman = new window.google.maps.LatLng(-26.8241, -65.2226);

    autocompleteServiceRef.current.getPlacePredictions(
      {
        input: inputValue,
        componentRestrictions: { country: 'ar' },
        types: ['address'],
        sessionToken: sessionTokenRef.current,
        // Priorizar resultados cerca de San Miguel de Tucumán con un radio de ~100km
        locationBias: {
          center: sanMiguelDeTucuman,
          radius: 100000 // 100 km en metros
        }
      },
      (results, status) => {
        setLoading(false);
        if (status === window.google.maps.places.PlacesServiceStatus.OK && results) {
          setPredictions(results);
          setShowDropdown(true);
        } else {
          setPredictions([]);
          setShowDropdown(false);
        }
      }
    );
  }, []);

  // Obtener detalles del lugar seleccionado
  const handleSelectPrediction = useCallback((prediction) => {
    if (!placesServiceRef.current) return;

    setLoading(true);
    setShowDropdown(false);
    onChange(prediction.description);

    placesServiceRef.current.getDetails(
      {
        placeId: prediction.place_id,
        fields: ['formatted_address', 'geometry', 'address_components'],
        sessionToken: sessionTokenRef.current
      },
      (place, status) => {
        setLoading(false);

        if (status === window.google.maps.places.PlacesServiceStatus.OK && place) {
          const result = {
            direccion: place.formatted_address || prediction.description,
            latitud: place.geometry?.location?.lat() || null,
            longitud: place.geometry?.location?.lng() || null,
            componentes: place.address_components || []
          };
          onSelect(result);

          // Crear nuevo session token para la próxima búsqueda
          sessionTokenRef.current = new window.google.maps.places.AutocompleteSessionToken();
        } else {
          // Si falla obtener detalles, al menos guardamos la dirección
          onSelect({
            direccion: prediction.description,
            latitud: null,
            longitud: null,
            componentes: []
          });
        }
      }
    );
  }, [onChange, onSelect]);

  const handleClear = useCallback(() => {
    onChange('');
    onSelect({ direccion: '', latitud: null, longitud: null });
    setPredictions([]);
    setShowDropdown(false);
    if (inputRef.current) {
      inputRef.current.focus();
    }
  }, [onChange, onSelect]);

  const handleInputChange = useCallback((e) => {
    const newValue = e.target.value;
    onChange(newValue);

    // Solo buscar predicciones si Google está listo
    if (googleStatus === 'ready') {
      fetchPredictions(newValue);
    }
  }, [onChange, googleStatus, fetchPredictions]);

  const handleInputFocus = useCallback(() => {
    if (predictions.length > 0) {
      setShowDropdown(true);
    }
  }, [predictions]);

  return (
    <div className="relative">
      <div className="relative">
        <MapPin className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
        <input
          ref={inputRef}
          type="text"
          value={value}
          onChange={handleInputChange}
          onFocus={handleInputFocus}
          placeholder={googleStatus === 'ready' ? placeholder : 'Escribí la dirección...'}
          disabled={disabled}
          autoComplete="off"
          className={`w-full pl-10 pr-10 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 ${
            disabled ? 'bg-gray-100 cursor-not-allowed' : ''
          } ${className}`}
        />
        {loading && (
          <Loader2 className="absolute right-3 top-1/2 transform -translate-y-1/2 text-blue-500 w-5 h-5 animate-spin" />
        )}
        {!loading && value && (
          <button
            type="button"
            onClick={handleClear}
            className="absolute right-3 top-1/2 transform -translate-y-1/2 text-gray-400 hover:text-gray-600"
          >
            <X className="w-5 h-5" />
          </button>
        )}
      </div>

      {/* Dropdown de predicciones */}
      {showDropdown && predictions.length > 0 && (
        <div
          ref={dropdownRef}
          className="absolute z-50 w-full mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-60 overflow-y-auto"
        >
          {predictions.map((prediction) => (
            <button
              key={prediction.place_id}
              type="button"
              onClick={() => handleSelectPrediction(prediction)}
              className="w-full px-4 py-3 text-left hover:bg-blue-50 focus:bg-blue-50 focus:outline-none border-b border-gray-100 last:border-b-0 transition-colors"
            >
              <div className="flex items-start">
                <MapPin className="w-4 h-4 text-gray-400 mt-0.5 mr-2 flex-shrink-0" />
                <div>
                  <p className="text-sm text-gray-900">{prediction.structured_formatting?.main_text || prediction.description}</p>
                  <p className="text-xs text-gray-500">{prediction.structured_formatting?.secondary_text || ''}</p>
                </div>
              </div>
            </button>
          ))}
        </div>
      )}

      {googleStatus === 'loading' && (
        <p className="text-xs text-blue-600 mt-1 flex items-center">
          <Loader2 className="w-3 h-3 mr-1 animate-spin" />
          Cargando autocompletado...
        </p>
      )}
      {googleStatus === 'error' && (
        <p className="text-xs text-amber-600 mt-1 flex items-center">
          <AlertCircle className="w-3 h-3 mr-1" />
          Autocompletado no disponible. Escribí la dirección manualmente.
        </p>
      )}
      {googleStatus === 'ready' && !showDropdown && (
        <p className="text-xs text-green-600 mt-1">
          Escribí para ver sugerencias de direcciones
        </p>
      )}
    </div>
  );
};

export default AddressAutocomplete;
