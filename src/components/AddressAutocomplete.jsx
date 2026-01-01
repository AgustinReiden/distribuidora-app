import React, { useEffect, useRef, useState } from 'react';
import { MapPin, Loader2, X } from 'lucide-react';

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
  const [googleReady, setGoogleReady] = useState(false);

  // Verificar que Google Maps esté cargado
  useEffect(() => {
    const checkGoogle = () => {
      if (window.google && window.google.maps && window.google.maps.places) {
        setGoogleReady(true);
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
    }, 100);

    // Timeout después de 10 segundos
    const timeout = setTimeout(() => {
      clearInterval(interval);
      console.warn('Google Maps API no se cargó correctamente');
    }, 10000);

    return () => {
      clearInterval(interval);
      clearTimeout(timeout);
    };
  }, []);

  // Inicializar autocomplete cuando Google esté listo
  useEffect(() => {
    if (!googleReady || !inputRef.current || autocompleteRef.current) return;

    try {
      autocompleteRef.current = new window.google.maps.places.Autocomplete(inputRef.current, {
        types: ['address'],
        componentRestrictions: { country: 'ar' }, // Restringir a Argentina
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
    }

    return () => {
      if (autocompleteRef.current) {
        window.google.maps.event.clearInstanceListeners(autocompleteRef.current);
      }
    };
  }, [googleReady, onSelect]);

  const handleClear = () => {
    onChange('');
    onSelect({ direccion: '', latitud: null, longitud: null });
    if (inputRef.current) {
      inputRef.current.focus();
    }
  };

  return (
    <div className="relative">
      <div className="relative">
        <MapPin className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
        <input
          ref={inputRef}
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          disabled={disabled || !googleReady}
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
      {!googleReady && (
        <p className="text-xs text-gray-500 mt-1 flex items-center">
          <Loader2 className="w-3 h-3 mr-1 animate-spin" />
          Cargando autocompletado...
        </p>
      )}
    </div>
  );
};

export default AddressAutocomplete;
