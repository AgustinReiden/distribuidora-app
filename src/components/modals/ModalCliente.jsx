import React, { useState, memo } from 'react';
import { Loader2, MapPin, CreditCard, Clock, Tag, FileText } from 'lucide-react';
import ModalBase from './ModalBase';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { validarTelefono, validarTexto } from './utils';

// Opciones predefinidas de rubros
const RUBROS_OPCIONES = [
  'Gimnasio',
  'Bar',
  'Kiosco',
  'Restaurante',
  'Supermercado',
  'Almacén',
  'Hotel',
  'Club',
  'Panadería',
  'Cafetería',
  'Otro'
];

// Validar formato de CUIT (XX-XXXXXXXX-X)
const validarCuit = (cuit) => {
  if (!cuit) return false;
  const cuitLimpio = cuit.replace(/-/g, '');
  return /^\d{11}$/.test(cuitLimpio);
};

// Validar formato de DNI (7-8 digitos)
const validarDni = (dni) => {
  if (!dni) return false;
  const dniLimpio = dni.replace(/\D/g, '');
  return /^\d{7,8}$/.test(dniLimpio);
};

// Formatear CUIT mientras se escribe (XX-XXXXXXXX-X)
const formatearCuit = (valor) => {
  const numeros = valor.replace(/\D/g, '').slice(0, 11);
  if (numeros.length <= 2) return numeros;
  if (numeros.length <= 10) return `${numeros.slice(0, 2)}-${numeros.slice(2)}`;
  return `${numeros.slice(0, 2)}-${numeros.slice(2, 10)}-${numeros.slice(10)}`;
};

// Formatear DNI mientras se escribe (solo numeros, max 8)
const formatearDni = (valor) => {
  return valor.replace(/\D/g, '').slice(0, 8);
};

// Convertir DNI a formato estandarizado para almacenar (00-XXXXXXXX-0)
const dniAFormatoAlmacenamiento = (dni) => {
  const dniLimpio = dni.replace(/\D/g, '').padStart(8, '0');
  return `00-${dniLimpio}-0`;
};

// Extraer DNI del formato de almacenamiento
const extraerDniDeFormato = (codigo) => {
  if (!codigo) return '';
  // Si tiene formato 00-XXXXXXXX-0, extraer el DNI
  const match = codigo.match(/^00-(\d{8})-0$/);
  if (match) {
    // Quitar ceros iniciales del DNI
    return match[1].replace(/^0+/, '') || '0';
  }
  return codigo;
};

// Detectar tipo de documento por el formato almacenado
const detectarTipoDocumento = (codigo) => {
  if (!codigo) return 'CUIT';
  if (/^00-\d{8}-0$/.test(codigo)) return 'DNI';
  return 'CUIT';
};

const ModalCliente = memo(function ModalCliente({ cliente, onSave, onClose, guardando, isAdmin = false }) {
  // Detectar tipo de documento y extraer numero si es edicion
  const tipoDocInicial = cliente ? (cliente.tipo_documento || detectarTipoDocumento(cliente.cuit)) : 'CUIT';
  const numeroDocInicial = cliente ? (tipoDocInicial === 'DNI' ? extraerDniDeFormato(cliente.cuit) : cliente.cuit) : '';

  const [form, setForm] = useState(cliente ? {
    tipo_documento: tipoDocInicial,
    numero_documento: numeroDocInicial || '',
    razonSocial: cliente.razon_social || '',
    nombreFantasia: cliente.nombre_fantasia || '',
    direccion: cliente.direccion || '',
    latitud: cliente.latitud || null,
    longitud: cliente.longitud || null,
    telefono: cliente.telefono || '',
    contacto: cliente.contacto || '',
    zona: cliente.zona || '',
    horarios_atencion: cliente.horarios_atencion || '',
    rubro: cliente.rubro || '',
    notas: cliente.notas || '',
    limiteCredito: cliente.limite_credito || 0,
    diasCredito: cliente.dias_credito || 30
  } : {
    tipo_documento: 'CUIT',
    numero_documento: '',
    razonSocial: '',
    nombreFantasia: '',
    direccion: '',
    latitud: null,
    longitud: null,
    telefono: '',
    contacto: '',
    zona: '',
    horarios_atencion: '',
    rubro: '',
    notas: '',
    limiteCredito: 0,
    diasCredito: 30
  });

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

    // Validar documento segun tipo
    if (form.tipo_documento === 'CUIT') {
      if (!validarCuit(form.numero_documento)) {
        nuevosErrores.numero_documento = 'El CUIT debe tener 11 digitos (formato: XX-XXXXXXXX-X)';
      }
    } else {
      if (!validarDni(form.numero_documento)) {
        nuevosErrores.numero_documento = 'El DNI debe tener 7 u 8 digitos';
      }
    }

    // Razón Social obligatoria
    if (!validarTexto(form.razonSocial, 2, 100)) {
      nuevosErrores.razonSocial = 'La razón social debe tener entre 2 y 100 caracteres';
    }

    // Nombre Fantasía obligatorio
    if (!validarTexto(form.nombreFantasia, 2, 100)) {
      nuevosErrores.nombreFantasia = 'El nombre fantasía debe tener entre 2 y 100 caracteres';
    }

    // Dirección obligatoria
    if (!validarTexto(form.direccion, 5, 200)) {
      nuevosErrores.direccion = 'La dirección debe tener entre 5 y 200 caracteres';
    }

    // Teléfono opcional pero si se ingresa debe ser válido
    if (form.telefono && !validarTelefono(form.telefono)) {
      nuevosErrores.telefono = 'El teléfono no tiene un formato válido';
    }

    setErrores(nuevosErrores);
    return Object.keys(nuevosErrores).length === 0;
  };

  const handleSubmit = () => {
    setIntentoGuardar(true);
    if (validarFormulario()) {
      // Convertir documento al formato de almacenamiento
      let cuitFinal;
      if (form.tipo_documento === 'DNI') {
        cuitFinal = dniAFormatoAlmacenamiento(form.numero_documento);
      } else {
        cuitFinal = form.numero_documento;
      }

      onSave({
        ...form,
        cuit: cuitFinal,
        tipo_documento: form.tipo_documento,
        id: cliente?.id
      });
    }
  };

  const handleTipoDocumentoChange = (nuevoTipo) => {
    // Limpiar el numero al cambiar de tipo
    setForm({ ...form, tipo_documento: nuevoTipo, numero_documento: '' });
    if (intentoGuardar && errores.numero_documento) {
      setErrores(prev => ({ ...prev, numero_documento: null }));
    }
  };

  const handleFieldChange = (field, value) => {
    // Formatear documento segun tipo
    if (field === 'numero_documento') {
      if (form.tipo_documento === 'CUIT') {
        value = formatearCuit(value);
      } else {
        value = formatearDni(value);
      }
    }
    setForm({ ...form, [field]: value });
    if (intentoGuardar && errores[field]) {
      setErrores(prev => ({ ...prev, [field]: null }));
    }
  };

  const inputClass = (field) => `w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white ${errores[field] ? 'border-red-500 bg-red-50 dark:bg-red-900/20' : ''}`;

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div className="p-4 space-y-4">
        {/* Tipo Documento, Numero y Razón Social */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Tipo Doc. *</label>
            <select
              value={form.tipo_documento}
              onChange={e => handleTipoDocumentoChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              <option value="CUIT">CUIT</option>
              <option value="DNI">DNI</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              {form.tipo_documento === 'CUIT' ? 'CUIT' : 'DNI'} *
            </label>
            <input
              type="text"
              value={form.numero_documento}
              onChange={e => handleFieldChange('numero_documento', e.target.value)}
              className={inputClass('numero_documento')}
              placeholder={form.tipo_documento === 'CUIT' ? 'XX-XXXXXXXX-X' : '12345678'}
              maxLength={form.tipo_documento === 'CUIT' ? 13 : 8}
            />
            {errores.numero_documento && <p className="text-red-500 text-xs mt-1">{errores.numero_documento}</p>}
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Razón Social *</label>
            <input
              type="text"
              value={form.razonSocial}
              onChange={e => handleFieldChange('razonSocial', e.target.value)}
              className={inputClass('razonSocial')}
              placeholder="Nombre legal"
            />
            {errores.razonSocial && <p className="text-red-500 text-xs mt-1">{errores.razonSocial}</p>}
          </div>
        </div>

        {/* Nombre Fantasía */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Nombre Fantasía *</label>
          <input
            type="text"
            value={form.nombreFantasia}
            onChange={e => handleFieldChange('nombreFantasia', e.target.value)}
            className={inputClass('nombreFantasia')}
            placeholder="Nombre comercial"
          />
          {errores.nombreFantasia && <p className="text-red-500 text-xs mt-1">{errores.nombreFantasia}</p>}
        </div>

        {/* Dirección */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Dirección *</label>
          <AddressAutocomplete
            value={form.direccion}
            onChange={(val) => handleFieldChange('direccion', val)}
            onSelect={handleAddressSelect}
            placeholder="Buscar dirección..."
            className={errores.direccion ? 'border-red-500' : ''}
          />
          {errores.direccion && <p className="text-red-500 text-xs mt-1">{errores.direccion}</p>}
          {form.latitud && form.longitud && (
            <div className="mt-2 flex items-center text-xs text-green-600 bg-green-50 dark:bg-green-900/20 px-3 py-2 rounded-lg">
              <MapPin className="w-4 h-4 mr-2" />
              <span>Coordenadas: {form.latitud.toFixed(6)}, {form.longitud.toFixed(6)}</span>
            </div>
          )}
        </div>

        {/* Teléfono y Contacto */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Teléfono</label>
            <input
              type="text"
              value={form.telefono}
              onChange={e => handleFieldChange('telefono', e.target.value)}
              className={inputClass('telefono')}
              placeholder="Ej: +54 9 381 1234567"
            />
            {errores.telefono && <p className="text-red-500 text-xs mt-1">{errores.telefono}</p>}
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Contacto (quien atiende)</label>
            <input
              type="text"
              value={form.contacto}
              onChange={e => handleFieldChange('contacto', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              placeholder="Nombre de la persona"
            />
          </div>
        </div>

        {/* Zona y Rubro */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Zona</label>
            <input
              type="text"
              value={form.zona}
              onChange={e => handleFieldChange('zona', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              placeholder="Ej: Centro, Norte, etc."
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <Tag className="w-4 h-4" />
              Rubro / Clasificación
            </label>
            <select
              value={form.rubro}
              onChange={e => handleFieldChange('rubro', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              <option value="">Seleccionar rubro...</option>
              {RUBROS_OPCIONES.map(rubro => (
                <option key={rubro} value={rubro}>{rubro}</option>
              ))}
            </select>
          </div>
        </div>

        {/* Horarios de Atención */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
            <Clock className="w-4 h-4" />
            Horarios de Atención
          </label>
          <input
            type="text"
            value={form.horarios_atencion}
            onChange={e => handleFieldChange('horarios_atencion', e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Ej: Lunes a Viernes 9:00 a 18:00"
          />
        </div>

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
            <FileText className="w-4 h-4" />
            Notas
          </label>
          <textarea
            value={form.notas}
            onChange={e => handleFieldChange('notas', e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white resize-none"
            rows={3}
            placeholder="Información adicional del cliente..."
          />
        </div>

        {/* Campos de crédito - Solo visibles y editables para admin */}
        {isAdmin && (
          <div className="border-t pt-4 mt-4">
            <div className="flex items-center gap-2 mb-3">
              <CreditCard className="w-5 h-5 text-blue-600" />
              <span className="font-medium text-gray-700 dark:text-gray-200">Configuración de Crédito</span>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium mb-1 dark:text-gray-200">Límite de Crédito ($)</label>
                <input
                  type="number"
                  min="0"
                  step="100"
                  value={form.limiteCredito}
                  onChange={e => handleFieldChange('limiteCredito', e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  placeholder="0"
                />
                <p className="text-xs text-gray-500 mt-1">0 = sin límite</p>
              </div>
              <div>
                <label className="block text-sm font-medium mb-1 dark:text-gray-200">Días de Crédito</label>
                <input
                  type="number"
                  min="0"
                  max="365"
                  value={form.diasCredito}
                  onChange={e => handleFieldChange('diasCredito', e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  placeholder="30"
                />
                <p className="text-xs text-gray-500 mt-1">Plazo de pago en días</p>
              </div>
            </div>
          </div>
        )}
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">Cancelar</button>
        <button onClick={handleSubmit} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalCliente;
