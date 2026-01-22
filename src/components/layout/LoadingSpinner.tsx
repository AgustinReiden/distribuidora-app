import React from 'react';
import PropTypes from 'prop-types';
import { Loader2 } from 'lucide-react';

/**
 * Componente de spinner de carga con texto opcional
 * @param {Object} props
 * @param {string} [props.text='Cargando...'] - Texto a mostrar junto al spinner
 */
export default function LoadingSpinner({ text = 'Cargando...' }) {
  return (
    <div className="flex items-center justify-center py-12" role="status" aria-live="polite">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" aria-hidden="true" />
      <span className="ml-2 text-gray-600">{text}</span>
    </div>
  );
}

LoadingSpinner.propTypes = {
  /** Texto a mostrar junto al spinner */
  text: PropTypes.string
};
