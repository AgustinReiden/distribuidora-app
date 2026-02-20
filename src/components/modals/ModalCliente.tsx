import { useState, memo, useRef } from 'react';
import { Loader2, MapPin, CreditCard, Clock, Tag, FileText, MapPinned, Users } from 'lucide-react';
import ModalBase from './ModalBase';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalClienteSchema } from '../../lib/schemas';
import { usePreventistasQuery, useZonasEstandarizadasQuery, useCrearZonaMutation } from '../../hooks/queries';
import {
  formatCuitInput,
  formatDniInput,
  dniToStorageFormat,
  extractDniFromStorage,
  detectDocumentType
} from '../../utils/formatters';
import type { ClienteDB } from '../../types';

/** Tipo de documento del cliente */
export type TipoDocumento = 'CUIT' | 'DNI';

/** Datos del formulario de cliente */
export interface ClienteFormData {
  tipo_documento: TipoDocumento;
  numero_documento: string;
  razonSocial: string;
  nombreFantasia: string;
  direccion: string;
  latitud: number | null;
  longitud: number | null;
  telefono: string;
  contacto: string;
  zona: string;
  horarios_atencion: string;
  rubro: string;
  notas: string;
  limiteCredito: number;
  diasCredito: number;
  preventista_id: string;
}

/** Datos para guardar cliente */
export interface ClienteSaveData extends ClienteFormData {
  id?: string;
  cuit: string;
}

/** Resultado de selección de dirección */
export interface AddressSelectResult {
  direccion: string;
  latitud: number;
  longitud: number;
}

/** Props del componente ModalCliente */
export interface ModalClienteProps {
  /** Cliente a editar (null para nuevo) */
  cliente: (ClienteDB & { tipo_documento?: TipoDocumento }) | null;
  /** Callback al guardar */
  onSave: (data: ClienteSaveData) => void | Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
  /** Si el usuario es admin (puede editar crédito) */
  isAdmin?: boolean;
  /** Zonas existentes para sugerencias */
  zonasExistentes?: string[];
}

// Las zonas ahora vienen de la tabla `zonas` via useZonasEstandarizadasQuery

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

const ModalCliente = memo(function ModalCliente({ cliente, onSave, onClose, guardando, isAdmin = false }: ModalClienteProps) {
  // Ref para scroll a errores
  const formRef = useRef<HTMLDivElement>(null);
  const { data: preventistas = [] } = usePreventistasQuery();
  const { data: zonasDB = [] } = useZonasEstandarizadasQuery();
  const crearZonaMut = useCrearZonaMutation();

  // Zod validation hook with accessibility helpers
  const { errors: errores, validate, clearFieldError, hasAttemptedSubmit: intentoGuardar, getAriaProps, getErrorMessageProps } = useZodValidation(modalClienteSchema);

  // Detectar tipo de documento y extraer numero si es edicion
  const tipoDocInicial = cliente ? (cliente.tipo_documento || detectDocumentType(cliente.cuit)) : 'CUIT';
  const numeroDocInicial = cliente ? (tipoDocInicial === 'DNI' ? extractDniFromStorage(cliente.cuit) : cliente.cuit) : '';

  // Zonas de la tabla estandarizada
  const zonasUnicas = zonasDB.map(z => z.nombre).sort();

  // Estado para nueva zona
  const [mostrarNuevaZona, setMostrarNuevaZona] = useState<boolean>(false);
  const [nuevaZona, setNuevaZona] = useState<string>('');

  const [form, setForm] = useState<ClienteFormData>(cliente ? {
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
    diasCredito: cliente.dias_credito || 30,
    preventista_id: cliente.preventista_id || ''
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
    diasCredito: 30,
    preventista_id: ''
  });

  const handleAddressSelect = (result: AddressSelectResult): void => {
    setForm(prev => ({
      ...prev,
      direccion: result.direccion,
      latitud: result.latitud,
      longitud: result.longitud
    }));
    if (errores.direccion) clearFieldError('direccion');
  };

  const handleSubmit = (): void => {
    // Validar con Zod
    const result = validate(form);

    // Validación adicional específica de documento según tipo
    // Solo validar longitud si el documento no está vacío (vacío es permitido por el schema)
    if (result.success) {
      const docLimpio = form.numero_documento.replace(/\D/g, '');
      if (docLimpio.length > 0) {
        if (form.tipo_documento === 'CUIT' && docLimpio.length !== 11) {
          // Error específico de CUIT
          setTimeout(() => {
            const primerError = formRef.current?.querySelector('.border-red-500');
            if (primerError) primerError.scrollIntoView({ behavior: 'smooth', block: 'center' });
          }, 100);
          return;
        }
        if (form.tipo_documento === 'DNI' && (docLimpio.length < 7 || docLimpio.length > 8)) {
          setTimeout(() => {
            const primerError = formRef.current?.querySelector('.border-red-500');
            if (primerError) primerError.scrollIntoView({ behavior: 'smooth', block: 'center' });
          }, 100);
          return;
        }
      }
    }

    if (!result.success) {
      // Scroll al primer error
      setTimeout(() => {
        const primerError = formRef.current?.querySelector('.border-red-500');
        if (primerError) {
          primerError.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }, 100);
      return;
    }

    // Convertir documento al formato de almacenamiento
    let cuitFinal;
    if (form.tipo_documento === 'DNI') {
      cuitFinal = dniToStorageFormat(form.numero_documento);
    } else {
      cuitFinal = form.numero_documento;
    }

    // Usar zona nueva si corresponde - persistir en tabla zonas si es nueva
    let zonaFinal = form.zona;
    if (mostrarNuevaZona && nuevaZona.trim()) {
      zonaFinal = nuevaZona.trim();
      // Crear la zona en la tabla estandarizada (ignora si ya existe)
      crearZonaMut.mutate(zonaFinal);
    }

    onSave({
      ...form,
      zona: zonaFinal,
      cuit: cuitFinal,
      tipo_documento: form.tipo_documento,
      id: cliente?.id
    });
  };

  const handleTipoDocumentoChange = (nuevoTipo: string): void => {
    // Limpiar el numero al cambiar de tipo
    setForm({ ...form, tipo_documento: nuevoTipo as TipoDocumento, numero_documento: '' });
    if (intentoGuardar && errores.numero_documento) {
      clearFieldError('numero_documento');
    }
  };

  const handleFieldChange = (field: keyof ClienteFormData, value: string | number): void => {
    // Formatear documento segun tipo
    let processedValue = value;
    if (field === 'numero_documento') {
      if (form.tipo_documento === 'CUIT') {
        processedValue = formatCuitInput(String(value));
      } else {
        processedValue = formatDniInput(String(value));
      }
    }
    setForm({ ...form, [field]: processedValue });
    if (intentoGuardar && errores[field]) {
      clearFieldError(field);
    }
  };

  const inputClass = (field: keyof ClienteFormData): string => `w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white ${errores[field] ? 'border-red-500 bg-red-50 dark:bg-red-900/20' : ''}`;

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div ref={formRef} className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
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
            <label htmlFor="numero_documento" className="block text-sm font-medium mb-1 dark:text-gray-200">
              {form.tipo_documento === 'CUIT' ? 'CUIT' : 'DNI'} *
            </label>
            <input
              id="numero_documento"
              type="text"
              value={form.numero_documento}
              onChange={e => handleFieldChange('numero_documento', e.target.value)}
              className={inputClass('numero_documento')}
              placeholder={form.tipo_documento === 'CUIT' ? 'XX-XXXXXXXX-X' : '12345678'}
              maxLength={form.tipo_documento === 'CUIT' ? 13 : 8}
              {...getAriaProps('numero_documento', true)}
            />
            {errores.numero_documento && <p {...getErrorMessageProps('numero_documento')} className="text-red-500 text-xs mt-1">{errores.numero_documento}</p>}
          </div>
          <div>
            <label htmlFor="razonSocial" className="block text-sm font-medium mb-1 dark:text-gray-200">Razón Social *</label>
            <input
              id="razonSocial"
              type="text"
              value={form.razonSocial}
              onChange={e => handleFieldChange('razonSocial', e.target.value)}
              className={inputClass('razonSocial')}
              placeholder="Nombre legal"
              {...getAriaProps('razonSocial', true)}
            />
            {errores.razonSocial && <p {...getErrorMessageProps('razonSocial')} className="text-red-500 text-xs mt-1">{errores.razonSocial}</p>}
          </div>
        </div>

        {/* Nombre Fantasía */}
        <div>
          <label htmlFor="nombreFantasia" className="block text-sm font-medium mb-1 dark:text-gray-200">Nombre Fantasía *</label>
          <input
            id="nombreFantasia"
            type="text"
            value={form.nombreFantasia}
            onChange={e => handleFieldChange('nombreFantasia', e.target.value)}
            className={inputClass('nombreFantasia')}
            placeholder="Nombre comercial"
            {...getAriaProps('nombreFantasia', true)}
          />
          {errores.nombreFantasia && <p {...getErrorMessageProps('nombreFantasia')} className="text-red-500 text-xs mt-1">{errores.nombreFantasia}</p>}
        </div>

        {/* Dirección */}
        <div>
          <label htmlFor="direccion" className="block text-sm font-medium mb-1 dark:text-gray-200">Dirección *</label>
          <AddressAutocomplete
            value={form.direccion}
            onChange={(val: string) => handleFieldChange('direccion', val)}
            onSelect={handleAddressSelect as any}
            placeholder="Buscar dirección..."
            className={errores.direccion ? 'border-red-500' : ''}
          />
          {errores.direccion && <p {...getErrorMessageProps('direccion')} className="text-red-500 text-xs mt-1">{errores.direccion}</p>}
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
            <label htmlFor="telefono" className="block text-sm font-medium mb-1 dark:text-gray-200">Teléfono</label>
            <input
              id="telefono"
              type="text"
              value={form.telefono}
              onChange={e => handleFieldChange('telefono', e.target.value)}
              className={inputClass('telefono')}
              placeholder="Ej: +54 9 381 1234567"
              {...getAriaProps('telefono')}
            />
            {errores.telefono && <p {...getErrorMessageProps('telefono')} className="text-red-500 text-xs mt-1">{errores.telefono}</p>}
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
            <div className="flex justify-between items-center mb-1">
              <label className="text-sm font-medium dark:text-gray-200 flex items-center gap-1">
                <MapPinned className="w-4 h-4" />
                Zona
              </label>
              <button
                type="button"
                onClick={() => {
                  setMostrarNuevaZona(!mostrarNuevaZona);
                  if (!mostrarNuevaZona) setNuevaZona('');
                }}
                className="text-sm text-blue-600 hover:text-blue-700"
              >
                {mostrarNuevaZona ? 'Elegir existente' : '+ Nueva zona'}
              </button>
            </div>
            {mostrarNuevaZona ? (
              <input
                type="text"
                value={nuevaZona}
                onChange={e => setNuevaZona(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="Escribir nueva zona..."
              />
            ) : (
              <select
                value={form.zona}
                onChange={e => handleFieldChange('zona', e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              >
                <option value="">Seleccionar zona...</option>
                {zonasUnicas.map(zona => (
                  <option key={zona} value={zona}>{zona}</option>
                ))}
              </select>
            )}
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

        {/* Preventista asignado */}
        {isAdmin && preventistas.length > 0 && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <Users className="w-4 h-4" />
              Preventista asignado
            </label>
            <select
              value={form.preventista_id}
              onChange={e => handleFieldChange('preventista_id', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              <option value="">Sin asignar</option>
              {preventistas.map(p => (
                <option key={p.id} value={p.id}>{p.nombre}</option>
              ))}
            </select>
          </div>
        )}

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
