import React, { useState, memo } from 'react';
import { Loader2, MapPin } from 'lucide-react';
import ModalBase from './ModalBase';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { validarTelefono, validarTexto } from './utils';

const ModalCliente = memo(function ModalCliente({ cliente, onSave, onClose, guardando }) {
  const [form, setForm] = useState(cliente ? {
    nombre: cliente.nombre,
    nombreFantasia: cliente.nombre_fantasia,
    direccion: cliente.direccion,
    latitud: cliente.latitud || null,
    longitud: cliente.longitud || null,
    telefono: cliente.telefono || '',
    zona: cliente.zona || ''
  } : { nombre: '', nombreFantasia: '', direccion: '', latitud: null, longitud: null, telefono: '', zona: '' });

  const [errores, setErrores] = useState({});
  const [intentoGuardar, setIntentoGuardar] = useState(false);

  const handleAddressSelect = (result) => {
    setForm(prev => ({
      ...prev,
      direccion: result.direccion,
      latitud: result.latitud,
      longitud: result.longitud
    }));
    if (errores.direccion) setErrores(prev => ({ ...prev, direccion: null }));
  };

  const validarFormulario = () => {
    const nuevosErrores = {};

    if (!validarTexto(form.nombre, 2, 100)) {
      nuevosErrores.nombre = 'El nombre debe tener entre 2 y 100 caracteres';
    }

    if (!validarTexto(form.nombreFantasia, 2, 100)) {
      nuevosErrores.nombreFantasia = 'El nombre fantasia debe tener entre 2 y 100 caracteres';
    }

    if (!validarTexto(form.direccion, 5, 200)) {
      nuevosErrores.direccion = 'La direccion debe tener entre 5 y 200 caracteres';
    }

    if (form.telefono && !validarTelefono(form.telefono)) {
      nuevosErrores.telefono = 'El telefono no tiene un formato valido';
    }

    setErrores(nuevosErrores);
    return Object.keys(nuevosErrores).length === 0;
  };

  const handleSubmit = () => {
    setIntentoGuardar(true);
    if (validarFormulario()) {
      onSave({ ...form, id: cliente?.id });
    }
  };

  const handleFieldChange = (field, value) => {
    setForm({ ...form, [field]: value });
    if (intentoGuardar && errores[field]) {
      setErrores(prev => ({ ...prev, [field]: null }));
    }
  };

  const inputClass = (field) => `w-full px-3 py-2 border rounded-lg ${errores[field] ? 'border-red-500 bg-red-50' : ''}`;

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div>
          <label className="block text-sm font-medium mb-1">Nombre *</label>
          <input type="text" value={form.nombre} onChange={e => handleFieldChange('nombre', e.target.value)} className={inputClass('nombre')} />
          {errores.nombre && <p className="text-red-500 text-xs mt-1">{errores.nombre}</p>}
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Nombre Fantasia *</label>
          <input type="text" value={form.nombreFantasia} onChange={e => handleFieldChange('nombreFantasia', e.target.value)} className={inputClass('nombreFantasia')} />
          {errores.nombreFantasia && <p className="text-red-500 text-xs mt-1">{errores.nombreFantasia}</p>}
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Direccion *</label>
          <AddressAutocomplete
            value={form.direccion}
            onChange={(val) => handleFieldChange('direccion', val)}
            onSelect={handleAddressSelect}
            placeholder="Buscar direccion..."
            className={errores.direccion ? 'border-red-500' : ''}
          />
          {errores.direccion && <p className="text-red-500 text-xs mt-1">{errores.direccion}</p>}
          {form.latitud && form.longitud && (
            <div className="mt-2 flex items-center text-xs text-green-600 bg-green-50 px-3 py-2 rounded-lg">
              <MapPin className="w-4 h-4 mr-2" />
              <span>Coordenadas: {form.latitud.toFixed(6)}, {form.longitud.toFixed(6)}</span>
            </div>
          )}
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Telefono</label>
          <input type="text" value={form.telefono} onChange={e => handleFieldChange('telefono', e.target.value)} className={inputClass('telefono')} placeholder="Ej: +54 9 381 1234567" />
          {errores.telefono && <p className="text-red-500 text-xs mt-1">{errores.telefono}</p>}
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Zona</label>
          <input type="text" value={form.zona} onChange={e => handleFieldChange('zona', e.target.value)} className="w-full px-3 py-2 border rounded-lg" />
        </div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={handleSubmit} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalCliente;
