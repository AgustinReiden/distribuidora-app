import { useState, memo, useRef, useMemo } from 'react';
import { Loader2, MapPin, CreditCard, Clock, Tag, FileText, Users, LocateFixed, AlertCircle, Percent, Plus, Trash2 } from 'lucide-react';
import ModalBase from './ModalBase';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalClienteSchema } from '../../lib/schemas';
import { usePreventistasQuery, useZonasEstandarizadasQuery, useCategoriasQuery, useProductosQuery } from '../../hooks/queries';
import { useGeolocationCapture } from '../../hooks/useGeolocationCapture';
import { useReverseGeocoding } from '../../hooks/useReverseGeocoding';
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
  aclaracionDireccion: string;
  latitud: number | null;
  longitud: number | null;
  telefono: string;
  contacto: string;
  /** @deprecated usar zona_id. Se mantiene para compat de lecturas. */
  zona: string;
  /** FK a tabla zonas. Cadena vacía representa "sin zona". */
  zona_id: string;
  horarios_atencion: string;
  rubro: string;
  notas: string;
  limiteCredito: number;
  diasCredito: number;
  descuentoPorcentaje: number;
  /** Descuentos por categoría (override del general). Porcentaje entero. */
  descuentosPorCategoria: Array<{ categoria: string; porcentaje: number }>;
  preventista_id: string;
  preventista_ids: string[];
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
  /**
   * Edición restringida (preventista editando un cliente existente): solo
   * permite tocar razón social, dirección, teléfono, contacto, rubro,
   * horarios de atención y notas. El resto se muestra deshabilitado.
   * El container debe enviar únicamente esos campos en el patch.
   */
  edicionRestringida?: boolean;
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

const ModalCliente = memo(function ModalCliente({ cliente, onSave, onClose, guardando, isAdmin = false, edicionRestringida = false }: ModalClienteProps) {
  // Ref para scroll a errores
  const formRef = useRef<HTMLDivElement>(null);
  const { data: preventistas = [] } = usePreventistasQuery();
  const { data: zonas = [] } = useZonasEstandarizadasQuery({ includeInactive: true });
  const { data: categoriasTabla = [] } = useCategoriasQuery();
  const { data: productosParaCategorias = [] } = useProductosQuery();
  // Opciones de categoría = unión de la tabla `categorias` (gestionada) y las
  // categorías reales usadas por productos. Así el valor elegido siempre matchea
  // algún producto al calcular el descuento (productos.categoria es texto libre).
  const categoriasDisponibles = useMemo(() => {
    const set = new Set<string>();
    categoriasTabla.forEach(c => { const n = (c.nombre || '').trim(); if (n) set.add(n); });
    productosParaCategorias.forEach(p => { const n = (p.categoria || '').trim(); if (n) set.add(n); });
    return [...set].sort((a, b) => a.localeCompare(b));
  }, [categoriasTabla, productosParaCategorias]);

  // Zod validation hook with accessibility helpers
  const { errors: errores, validate, clearFieldError, hasAttemptedSubmit: intentoGuardar, getAriaProps, getErrorMessageProps } = useZodValidation(modalClienteSchema);

  // Detectar tipo de documento y extraer numero si es edicion
  const tipoDocInicial = cliente ? (cliente.tipo_documento || detectDocumentType(cliente.cuit)) : 'CUIT';
  const numeroDocInicial = cliente ? (tipoDocInicial === 'DNI' ? extractDniFromStorage(cliente.cuit) : cliente.cuit) : '';

  const [form, setForm] = useState<ClienteFormData>(cliente ? {
    tipo_documento: tipoDocInicial,
    numero_documento: numeroDocInicial || '',
    razonSocial: cliente.razon_social || '',
    nombreFantasia: cliente.nombre_fantasia || '',
    direccion: cliente.direccion || '',
    aclaracionDireccion: cliente.aclaracion_direccion || '',
    latitud: cliente.latitud || null,
    longitud: cliente.longitud || null,
    telefono: cliente.telefono || '',
    contacto: cliente.contacto || '',
    zona: cliente.zona || '',
    zona_id: cliente.zona_id ? String(cliente.zona_id) : '',
    horarios_atencion: cliente.horarios_atencion || '',
    rubro: cliente.rubro || '',
    notas: cliente.notas || '',
    limiteCredito: cliente.limite_credito || 0,
    diasCredito: cliente.dias_credito || 30,
    descuentoPorcentaje: cliente.descuento_porcentaje || 0,
    descuentosPorCategoria: (cliente.descuentos_categoria || []).map(d => ({
      categoria: d.categoria,
      porcentaje: Number(d.descuento_porcentaje) || 0,
    })),
    preventista_id: cliente.preventista_id || '',
    preventista_ids: cliente.preventista_ids || []
  } : {
    tipo_documento: 'CUIT',
    numero_documento: '',
    razonSocial: '',
    nombreFantasia: '',
    direccion: '',
    aclaracionDireccion: '',
    latitud: null,
    longitud: null,
    telefono: '',
    contacto: '',
    zona: '',
    zona_id: '',
    horarios_atencion: '',
    rubro: '',
    notas: '',
    limiteCredito: 0,
    diasCredito: 30,
    descuentoPorcentaje: 0,
    descuentosPorCategoria: [],
    preventista_id: '',
    preventista_ids: []
  });

  // State para captura de GPS del navegador (botón "Usar mi ubicación actual").
  // gpsAccuracy se mantiene solo en memoria para mostrar precisión en la UI;
  // no se persiste en la tabla `clientes`.
  const [gpsCapturando, setGpsCapturando] = useState<boolean>(false);
  const [gpsError, setGpsError] = useState<string | null>(null);
  const [gpsAccuracy, setGpsAccuracy] = useState<number | null>(null);
  // Marca cuando la direccion fue autocompletada por reverse geocoding tras
  // un GPS. Permite mostrar un texto auxiliar invitando al usuario a corregir
  // si la sugerencia no es exacta. Se borra al editar manualmente o usar el
  // autocompletado de Google Places.
  const [direccionDesdeGps, setDireccionDesdeGps] = useState<boolean>(false);
  const capturarGps = useGeolocationCapture();
  const { reverseGeocode } = useReverseGeocoding();

  const handleCapturarGps = async (): Promise<void> => {
    if (gpsCapturando) return;
    setGpsError(null);
    setGpsCapturando(true);
    try {
      const result = await capturarGps();
      if (result.status === 'ok') {
        setForm(prev => ({ ...prev, latitud: result.lat, longitud: result.lng }));
        setGpsAccuracy(result.accuracy);
        if (errores.direccion) clearFieldError('direccion');
        // Reverse geocoding: traducir coords a direccion legible. No bloquea
        // el flujo si falla; el GPS ya capturo coords utiles. Sobreescribe
        // la direccion actual con la sugerencia para que el usuario solo
        // necesite revisar/editar.
        try {
          const rev = await reverseGeocode(result.lat, result.lng);
          if (rev?.direccion) {
            setForm(prev => ({ ...prev, direccion: rev.direccion }));
            setDireccionDesdeGps(true);
          }
        } catch {
          // Silencioso: la captura de coords ya fue exitosa.
        }
      } else {
        const mensajes: Record<typeof result.status, string> = {
          denied: 'Permiso de ubicación denegado. Aceptá el permiso en la configuración del navegador y volvé a intentar.',
          timeout: 'No respondió el GPS en 10 s. Asegurate de estar al aire libre y reintentá.',
          unavailable: 'GPS no disponible en este dispositivo.',
          error: 'Error capturando ubicación. Intentá de nuevo.',
        };
        setGpsError(mensajes[result.status]);
      }
    } finally {
      setGpsCapturando(false);
    }
  };

  const [preventistasFiltro, setPreventistasFiltro] = useState('');
  const togglePreventista = (id: string): void => {
    setForm(prev => {
      const exists = prev.preventista_ids.includes(id);
      return {
        ...prev,
        preventista_ids: exists
          ? prev.preventista_ids.filter(x => x !== id)
          : [...prev.preventista_ids, id]
      };
    });
  };
  const preventistasVisibles = preventistas.filter(p =>
    (p.nombre || '').toLowerCase().includes(preventistasFiltro.trim().toLowerCase())
  );

  // --- Descuentos por categoría (filas dinámicas) ---
  const agregarDescuentoCategoria = (): void => {
    setForm(prev => ({
      ...prev,
      descuentosPorCategoria: [...prev.descuentosPorCategoria, { categoria: '', porcentaje: 0 }],
    }));
  };
  const actualizarDescuentoCategoria = (index: number, field: 'categoria' | 'porcentaje', value: string): void => {
    setForm(prev => ({
      ...prev,
      descuentosPorCategoria: prev.descuentosPorCategoria.map((row, i) => {
        if (i !== index) return row;
        if (field === 'porcentaje') {
          const num = value === '' ? 0 : Math.max(0, Math.min(100, Math.trunc(Number(value)) || 0));
          return { ...row, porcentaje: num };
        }
        return { ...row, categoria: value };
      }),
    }));
  };
  const eliminarDescuentoCategoria = (index: number): void => {
    setForm(prev => ({
      ...prev,
      descuentosPorCategoria: prev.descuentosPorCategoria.filter((_, i) => i !== index),
    }));
  };

  const handleAddressSelect = (result: AddressSelectResult): void => {
    setForm(prev => ({
      ...prev,
      direccion: result.direccion,
      latitud: result.latitud,
      longitud: result.longitud
    }));
    // Las coords vienen del autocomplete ahora — descartamos la accuracy GPS
    // previa para no mostrar un dato engañoso en el bloque "Coordenadas".
    setGpsAccuracy(null);
    setGpsError(null);
    setDireccionDesdeGps(false);
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

    onSave({
      ...form,
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
    // Si el user edito manualmente la direccion, la "sugerencia GPS" deja
    // de aplicar (ya tomo control).
    if (field === 'direccion' && direccionDesdeGps) {
      setDireccionDesdeGps(false);
    }
  };

  const inputClass = (field: keyof ClienteFormData): string => `w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white ${errores[field] ? 'border-red-500 bg-red-50 dark:bg-red-900/20' : ''}`;

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div ref={formRef} className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {edicionRestringida && (
          <div className="flex items-start gap-2 px-3 py-2 rounded-lg bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 text-xs">
            <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
            <span>
              Podés editar razón social, dirección, teléfono, contacto, rubro, horarios y notas.
              El resto de los datos los gestiona un administrador.
            </span>
          </div>
        )}
        {/* Tipo Documento, Numero y Razón Social */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Tipo Doc. *</label>
            <select
              value={form.tipo_documento}
              onChange={e => handleTipoDocumentoChange(e.target.value)}
              disabled={edicionRestringida}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-60 disabled:cursor-not-allowed"
            >
              <option value="CUIT">CUIT</option>
              <option value="DNI">DNI</option>
            </select>
          </div>
          <div>
            <label htmlFor="numero_documento" className="block text-sm font-medium mb-1 dark:text-gray-200">
              {form.tipo_documento === 'CUIT' ? 'CUIT' : 'DNI'}
            </label>
            <input
              id="numero_documento"
              type="text"
              value={form.numero_documento}
              onChange={e => handleFieldChange('numero_documento', e.target.value)}
              disabled={edicionRestringida}
              className={`${inputClass('numero_documento')} disabled:opacity-60 disabled:cursor-not-allowed`}
              placeholder={form.tipo_documento === 'CUIT' ? 'XX-XXXXXXXX-X' : '12345678'}
              maxLength={form.tipo_documento === 'CUIT' ? 13 : 8}
              {...getAriaProps('numero_documento', true)}
            />
            {errores.numero_documento && <p {...getErrorMessageProps('numero_documento')} className="text-red-500 text-xs mt-1">{errores.numero_documento}</p>}
          </div>
          <div>
            <label htmlFor="razonSocial" className="block text-sm font-medium mb-1 dark:text-gray-200">Razón social/Nombre Cliente *</label>
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
            disabled={edicionRestringida}
            className={`${inputClass('nombreFantasia')} disabled:opacity-60 disabled:cursor-not-allowed`}
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
          {direccionDesdeGps && !errores.direccion && (
            <p className="text-xs text-blue-600 dark:text-blue-400 mt-1 italic">
              Dirección sugerida por GPS — corregila si no coincide.
            </p>
          )}

          {/* Botón "Usar mi ubicación actual": complementa al autocomplete cuando
              la dirección no se encuentra o devuelve coords de otra localidad.
              Útil si el preventista/admin está parado en el local del cliente. */}
          <div className="mt-2">
            <button
              type="button"
              onClick={handleCapturarGps}
              disabled={gpsCapturando}
              className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-3 py-2 text-sm font-medium rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/40 disabled:opacity-60 disabled:cursor-not-allowed transition-colors"
              aria-label="Usar mi ubicación actual para fijar las coordenadas del cliente"
            >
              {gpsCapturando ? (
                <>
                  <Loader2 className="w-4 h-4 animate-spin" />
                  Obteniendo ubicación…
                </>
              ) : (
                <>
                  <LocateFixed className="w-4 h-4" />
                  Usar mi ubicación actual
                </>
              )}
            </button>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Útil si estás parado en el local del cliente.
            </p>
          </div>

          {gpsError && (
            <div className="mt-2 flex items-start gap-2 text-xs text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-900/20 px-3 py-2 rounded-lg">
              <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
              <span>{gpsError}</span>
            </div>
          )}

          {form.latitud != null && form.longitud != null && (
            <div className="mt-2 flex flex-wrap items-center gap-2 text-xs px-3 py-2 rounded-lg bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-300">
              <MapPin className="w-4 h-4" />
              <span className="tabular-nums">
                {form.latitud.toFixed(6)}, {form.longitud.toFixed(6)}
              </span>
              {gpsAccuracy != null && (
                <>
                  <span
                    className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/40 text-blue-700 dark:text-blue-300 text-[10px] font-semibold tracking-wide uppercase"
                    title="Coordenadas capturadas con GPS del dispositivo"
                  >
                    GPS
                  </span>
                  <span
                    className={`inline-flex items-center px-1.5 py-0.5 rounded-full text-[11px] font-medium ${
                      gpsAccuracy > 50
                        ? 'bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300'
                        : 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300'
                    }`}
                  >
                    ±{Math.round(gpsAccuracy)} m
                  </span>
                  {gpsAccuracy > 50 && (
                    <span className="text-amber-700 dark:text-amber-400 text-[11px]">
                      Precisión baja — afiná posición si podés.
                    </span>
                  )}
                </>
              )}
            </div>
          )}
        </div>

        {/* Aclaración de dirección (para repartidores) */}
        <div>
          <label htmlFor="aclaracionDireccion" className="block text-sm font-medium mb-1 dark:text-gray-200">
            Aclaración de dirección (para repartidores)
          </label>
          <textarea
            id="aclaracionDireccion"
            value={form.aclaracionDireccion}
            onChange={e => handleFieldChange('aclaracionDireccion', e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white resize-none"
            rows={2}
            placeholder="Ej: tocar timbre azul, fondo del pasillo"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            Se imprime en la hoja de ruta y se ve en el celular del transportista.
          </p>
        </div>

        {/* Teléfono y Contacto */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label htmlFor="telefono" className="block text-sm font-medium mb-1 dark:text-gray-200">Teléfono</label>
            <input
              id="telefono"
              type="tel"
              inputMode="tel"
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

        {/* Rubro y Zona */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
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
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <MapPin className="w-4 h-4" />
              Zona
            </label>
            <select
              value={form.zona_id}
              onChange={e => handleFieldChange('zona_id', e.target.value)}
              disabled={edicionRestringida}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-60 disabled:cursor-not-allowed"
            >
              <option value="">(Sin zona)</option>
              {zonas.map(z => (
                <option key={z.id} value={String(z.id)}>
                  {z.nombre}{z.activo === false ? ' (inactiva)' : ''}
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* Preventistas asignados (N-a-N) */}
        {isAdmin && preventistas.length > 0 && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <Users className="w-4 h-4" />
              Preventistas asignados
              {form.preventista_ids.length > 0 && (
                <span className="ml-auto text-xs text-gray-500 dark:text-gray-400">
                  {form.preventista_ids.length} seleccionado{form.preventista_ids.length === 1 ? '' : 's'}
                </span>
              )}
            </label>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
              Si no seleccionás ninguno, todos los preventistas ven este cliente. Si seleccionás uno o más, solo ellos (y admin) lo verán.
            </p>
            <input
              type="text"
              value={preventistasFiltro}
              onChange={e => setPreventistasFiltro(e.target.value)}
              placeholder="Buscar preventista..."
              className="w-full px-3 py-2 mb-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
            <div className="max-h-40 overflow-y-auto border rounded-lg dark:border-gray-600 divide-y dark:divide-gray-700">
              {preventistasVisibles.length === 0 ? (
                <div className="px-3 py-2 text-sm text-gray-500 dark:text-gray-400">
                  Sin resultados
                </div>
              ) : (
                preventistasVisibles.map(p => {
                  const checked = form.preventista_ids.includes(p.id);
                  return (
                    <label
                      key={p.id}
                      className="flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-gray-200"
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => togglePreventista(p.id)}
                        className="rounded"
                      />
                      <span className="text-sm">{p.nombre}</span>
                    </label>
                  );
                })
              )}
            </div>
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

        {/* Campos de crédito y descuento - Solo admin puede editar */}
        {isAdmin ? (
          <div className="border-t pt-4 mt-4">
            <div className="flex items-center gap-2 mb-3">
              <CreditCard className="w-5 h-5 text-blue-600" />
              <span className="font-medium text-gray-700 dark:text-gray-200">Configuración de Crédito y Descuento</span>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium mb-1 dark:text-gray-200">Límite de Crédito ($)</label>
                <input
                  type="number"
                  inputMode="decimal"
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
                  inputMode="numeric"
                  step="1"
                  min="0"
                  max="365"
                  value={form.diasCredito}
                  onChange={e => handleFieldChange('diasCredito', e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  placeholder="30"
                />
                <p className="text-xs text-gray-500 mt-1">Plazo de pago en días</p>
              </div>
              <div>
                <label className="block text-sm font-medium mb-1 dark:text-gray-200">Descuento (%)</label>
                <input
                  type="number"
                  inputMode="decimal"
                  step="0.5"
                  min="0"
                  max="100"
                  value={form.descuentoPorcentaje}
                  onChange={e => handleFieldChange('descuentoPorcentaje', e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  placeholder="0"
                />
                <p className="text-xs text-gray-500 mt-1">Se aplica al precio_unitario al armar pedidos</p>
              </div>
            </div>

            {/* Descuentos por categoría (prevalecen sobre el descuento general) */}
            <div className="mt-4 border-t border-dashed pt-3 dark:border-gray-700">
              <div className="flex items-center gap-2 mb-1">
                <Percent className="w-4 h-4 text-blue-600" />
                <span className="text-sm font-medium text-gray-700 dark:text-gray-200">Descuentos por categoría</span>
              </div>
              <p className="text-xs text-gray-500 mb-2">
                Para productos de la categoría elegida se aplica este % en lugar del descuento general.
              </p>

              <datalist id="cliente-categorias-disponibles">
                {categoriasDisponibles.map(c => <option key={c} value={c} />)}
              </datalist>

              {form.descuentosPorCategoria.length > 0 && (
                <div className="space-y-2 mb-2">
                  {form.descuentosPorCategoria.map((row, index) => (
                    <div key={index} className="flex items-center gap-2">
                      <input
                        type="text"
                        list="cliente-categorias-disponibles"
                        value={row.categoria}
                        onChange={e => actualizarDescuentoCategoria(index, 'categoria', e.target.value)}
                        placeholder="Buscar categoría..."
                        className="flex-1 px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                      />
                      <div className="relative w-24">
                        <input
                          type="number"
                          inputMode="numeric"
                          min="0"
                          max="100"
                          step="1"
                          value={row.porcentaje}
                          onChange={e => actualizarDescuentoCategoria(index, 'porcentaje', e.target.value)}
                          className="w-full px-3 py-2 pr-7 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                        />
                        <span className="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-gray-400">%</span>
                      </div>
                      <button
                        type="button"
                        onClick={() => eliminarDescuentoCategoria(index)}
                        className="p-2 text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/20 rounded-lg"
                        aria-label="Eliminar descuento de categoría"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}

              <button
                type="button"
                onClick={agregarDescuentoCategoria}
                className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded-lg"
              >
                <Plus className="w-4 h-4" />
                Agregar categoría
              </button>
            </div>
          </div>
        ) : (
          (form.descuentoPorcentaje > 0 || (form.limiteCredito ?? 0) > 0) && (
            <div className="border-t pt-4 mt-4">
              <div className="flex items-center gap-2 mb-3">
                <CreditCard className="w-5 h-5 text-blue-600" />
                <span className="font-medium text-gray-700 dark:text-gray-200">Crédito y Descuento</span>
              </div>
              <div className="grid grid-cols-3 gap-4 text-sm">
                <div>
                  <p className="text-gray-500">Límite de Crédito</p>
                  <p className="font-medium">${form.limiteCredito.toLocaleString('es-AR')}</p>
                </div>
                <div>
                  <p className="text-gray-500">Días de Crédito</p>
                  <p className="font-medium">{form.diasCredito} días</p>
                </div>
                <div>
                  <p className="text-gray-500">Descuento</p>
                  <p className="font-medium">{form.descuentoPorcentaje}%</p>
                </div>
              </div>
              <p className="text-xs text-gray-500 mt-2">Solo el administrador puede editar estos valores.</p>
            </div>
          )
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
