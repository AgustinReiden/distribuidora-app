import React, { useEffect, useRef, useState, useCallback } from 'react';
import { MapPin, Loader2, X, AlertCircle } from 'lucide-react';

export const AddressAutocomplete = ({
  value,
  onChange,
  onSelect,
  placeholder = 'Buscar dirección...',
  className = '',
  disabled = false
}) => {
  const inputRef = useRef(null);
  const autocompleteRef = useRef(null);
  const [loading, setLoading] = useState(false);
  const [googleStatus, setGoogleStatus] = useState('loading'); // 'loading', 'ready', 'error'

  // Verificar que Google Maps esté cargado
  useEffect(() => {
    const checkGoogle = () => {
      if (window.google && window.google.maps && window.google.maps.places) {
        setGoogleStatus('ready');
        return true;
      }
      return false;
    };

    if (checkGoogle()) return;

    // Si no está listo, esperamos un poco
    const interval = setInterval(() => {
      if (checkGoogle()) {
        clearInterval(interval);
      }
    }, 200);

    // Timeout después de 5 segundos - permitir uso manual
    const timeout = setTimeout(() => {
      clearInterval(interval);
      if (!window.google?.maps?.places) {
        console.warn('Google Maps API no se cargó. Verificar que las APIs estén habilitadas en Google Cloud Console.');
        setGoogleStatus('error');
      }
    }, 5000);

    return () => {
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, []);

  // Inicializar autocomplete cuando Google esté listo
  useEffect(() => {
    if (googleStatus !== 'ready' || !inputRef.current || autocompleteRef.current) return;

    try {
      autocompleteRef.current = new window.google.maps.places.Autocomplete(inputRef.current, {
        types: ['address'],
        componentRestrictions: { country: 'ar' },
        fields: ['formatted_address', 'geometry', 'address_components']
      });

      autocompleteRef.current.addListener('place_changed', () => {
        setLoading(true);
        const place = autocompleteRef.current.getPlace();

        if (place && place.geometry) {
          const result = {
            direccion: place.formatted_address || '',
            latitud: place.geometry.location.lat(),
            longitud: place.geometry.location.lng(),
            componentes: place.address_components || []
          };
          onSelect(result);
        }
        setLoading(false);
      });
    } catch (error) {
      console.error('Error inicializando autocomplete:', error);
      setGoogleStatus('error');
    }

    return () => {
      if (autocompleteRef.current && window.google?.maps?.event) {
        window.google.maps.event.clearInstanceListeners(autocompleteRef.current);
      }
    };
  }, [googleStatus, onSelect]);

  const handleClear = useCallback(() => {
    onChange('');
    onSelect({ direccion: '', latitud: null, longitud: null });
    if (inputRef.current) {
      inputRef.current.focus();
    }
  }, [onChange, onSelect]);

  const handleInputChange = useCallback((e) => {
    onChange(e.target.value);
    // Si escriben manualmente, limpiar coordenadas
    if (googleStatus !== 'ready') {
      onSelect({ direccion: e.target.value, latitud: null, longitud: null });
    }
  }, [onChange, onSelect, googleStatus]);

  return (
    <div className="relative">
      <div className="relative">
        <MapPin className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
        <input
          ref={inputRef}
          type="text"
          value={value}
          onChange={handleInputChange}
          placeholder={placeholder}
          disabled={disabled}
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
      {googleStatus === 'loading' && (
        <p className="text-xs text-gray-500 mt-1 flex items-center">
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
    </div>
  );
};

export default AddressAutocomplete;
