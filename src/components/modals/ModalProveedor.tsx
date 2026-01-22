import React, { useState, useEffect } from 'react';
import { X, Building2, Phone, Mail, MapPin, FileText, User, Hash, CheckCircle } from 'lucide-react';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalProveedorSchema } from '../../lib/schemas';

export default function ModalProveedor({ proveedor, onSave, onClose, guardando }) {
  // Zod validation hook
  const { validate, getFirstError } = useZodValidation(modalProveedorSchema);

  const [formData, setFormData] = useState({
    nombre: '',
    cuit: '',
    direccion: '',
    latitud: null,
    longitud: null,
    telefono: '',
    email: '',
    contacto: '',
    notas: ''
  });
  const [error, setError] = useState('');

  useEffect(() => {
    if (proveedor) {
      setFormData({
        nombre: proveedor.nombre || '',
        cuit: proveedor.cuit || '',
        direccion: proveedor.direccion || '',
        latitud: proveedor.latitud || null,
        longitud: proveedor.longitud || null,
        telefono: proveedor.telefono || '',
        email: proveedor.email || '',
        contacto: proveedor.contacto || '',
        notas: proveedor.notas || ''
      });
    }
  }, [proveedor]);

  const handleAddressSelect = (result) => {
    setFormData(prev => ({
      ...prev,
      direccion: result.direccion,
      latitud: result.latitud,
      longitud: result.longitud
    }));
  };

  const handleChange = (field, value) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    setError('');
  };

  const formatCuit = (value) => {
    // Remover todo lo que no sea número
    const numbers = value.replace(/\D/g, '');
    // Formatear como XX-XXXXXXXX-X
    if (numbers.length <= 2) return numbers;
    if (numbers.length <= 10) return `${numbers.slice(0, 2)}-${numbers.slice(2)}`;
    return `${numbers.slice(0, 2)}-${numbers.slice(2, 10)}-${numbers.slice(10, 11)}`;
  };

  const handleCuitChange = (value) => {
    const formatted = formatCuit(value);
    if (formatted.replace(/\D/g, '').length <= 11) {
      handleChange('cuit', formatted);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');

    // Validar con Zod
    const result = validate(formData);
    if (!result.success) {
      setError(getFirstError() || 'Error de validación');
      return;
    }

    try {
      await onSave({
        id: proveedor?.id,
        ...result.data,
        activo: proveedor?.activo !== false
      });
    } catch (err) {
      setError(err.message || 'Error al guardar proveedor');
    }
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <Building2 className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                {proveedor ? 'Editar Proveedor' : 'Nuevo Proveedor'}
              </h2>
              <p className="text-sm text-gray-500">
                {proveedor ? 'Modificar datos del proveedor' : 'Agregar proveedor al sistema'}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Formulario */}
        <form onSubmit={handleSubmit} className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Nombre */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <Building2 className="w-4 h-4 inline mr-1" />
              Nombre / Razón Social *
            </label>
            <input
              type="text"
              value={formData.nombre}
              onChange={e => handleChange('nombre', e.target.value)}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              placeholder="Nombre del proveedor"
              required
            />
          </div>

          {/* CUIT */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <Hash className="w-4 h-4 inline mr-1" />
              CUIT
            </label>
            <input
              type="text"
              value={formData.cuit}
              onChange={e => handleCuitChange(e.target.value)}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              placeholder="XX-XXXXXXXX-X"
            />
          </div>

          {/* Contacto */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <User className="w-4 h-4 inline mr-1" />
              Persona de Contacto
            </label>
            <input
              type="text"
              value={formData.contacto}
              onChange={e => handleChange('contacto', e.target.value)}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              placeholder="Nombre del contacto"
            />
          </div>

          {/* Teléfono y Email */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                <Phone className="w-4 h-4 inline mr-1" />
                Teléfono
              </label>
              <input
                type="tel"
                value={formData.telefono}
                onChange={e => handleChange('telefono', e.target.value)}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
                placeholder="+54 11 1234-5678"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                <Mail className="w-4 h-4 inline mr-1" />
                Email
              </label>
              <input
                type="email"
                value={formData.email}
                onChange={e => handleChange('email', e.target.value)}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
                placeholder="email@ejemplo.com"
              />
            </div>
          </div>

          {/* Dirección con Autocompletado */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <MapPin className="w-4 h-4 inline mr-1" />
              Dirección
            </label>
            <AddressAutocomplete
              value={formData.direccion}
              onChange={(val) => handleChange('direccion', val)}
              onSelect={handleAddressSelect}
              placeholder="Buscar dirección del proveedor..."
              className="dark:bg-gray-700 dark:text-white dark:border-gray-600"
            />
            {formData.latitud && formData.longitud && (
              <div className="mt-2 flex items-center text-xs text-green-600 dark:text-green-400 bg-green-50 dark:bg-green-900/20 px-3 py-2 rounded-lg">
                <CheckCircle className="w-4 h-4 mr-2" />
                <span>Ubicación capturada: {formData.latitud.toFixed(6)}, {formData.longitud.toFixed(6)}</span>
              </div>
            )}
          </div>

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Notas
            </label>
            <textarea
              value={formData.notas}
              onChange={e => handleChange('notas', e.target.value)}
              rows={3}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white resize-none"
              placeholder="Observaciones adicionales..."
            />
          </div>

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}
        </form>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700 shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
          >
            Cancelar
          </button>
          <button
            onClick={handleSubmit}
            disabled={guardando}
            className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
          >
            {guardando ? (
              <>
                <span className="animate-spin">...</span>
                Guardando...
              </>
            ) : (
              <>
                <Building2 className="w-4 h-4" />
                {proveedor ? 'Actualizar' : 'Crear Proveedor'}
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
