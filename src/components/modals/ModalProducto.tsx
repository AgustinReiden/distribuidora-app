import { useState, memo } from 'react';
import type { ChangeEvent } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';
import NumberInput from '../ui/NumberInput';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalProductoSchema } from '../../lib/schemas';
import {
  calcularTotalConIva,
  calcularNetoDesdeTotal,
  calcularMargenPorcentaje,
  calcularPrecioDesdeMargen,
  parsePrecio,
} from '../../utils/calculations';
import type { ProductoDB, ProveedorDBExtended } from '../../types';

// =============================================================================
// TYPES
// =============================================================================

/** Datos del formulario de producto */
export interface ProductoFormData {
  id?: string;
  nombre: string;
  codigo: string;
  categoria: string;
  proveedor_id: string;
  stock: number | string;
  stock_minimo: number;
  porcentaje_iva: number;
  costo_sin_iva: number | string;
  costo_con_iva: number | string;
  impuestos_internos: number | string;
  precio_sin_iva: number | string;
  precio: number | string;
  /** Cuántas unidades de venta hacen 1 fardo/bulto (ej: 2 = vendés medio fardo) */
  unidades_de_venta_por_fardo?: number;
  /** Etiqueta del bulto: FARDO, CAJA, PACK, BULTO... */
  etiqueta_bulto?: string;
}

/** Opción de IVA */
interface OpcionIVA {
  valor: number;
  label: string;
}

/** Validation errors map */
type ValidationErrors = Record<string, string | undefined>;

/** Categoria object or string */
export interface CategoriaOption {
  id?: string;
  nombre: string;
}

/** Props del componente ModalProducto */
export interface ModalProductoProps {
  /** Producto a editar (null para nuevo) */
  producto: ProductoDB | null;
  /** Categorías disponibles (can be strings or objects) */
  categorias: string[] | CategoriaOption[];
  /** Proveedores disponibles para el desplegable */
  proveedores?: ProveedorDBExtended[];
  /** Callback al guardar */
  onSave: (data: ProductoFormData) => void | Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
}

// Opciones de IVA disponibles
const OPCIONES_IVA: OpcionIVA[] = [
  { valor: 21, label: '21%' },
  { valor: 10.5, label: '10.5%' },
  { valor: 0, label: '0% (Exento)' }
];

/** Helper to get category name */
const getCategoryName = (cat: string | CategoriaOption): string => {
  return typeof cat === 'string' ? cat : cat.nombre;
};

/** Helper to get category key */
const getCategoryKey = (cat: string | CategoriaOption): string => {
  return typeof cat === 'string' ? cat : (cat.id || cat.nombre);
};

const ModalProducto = memo(function ModalProducto({ producto, categorias, proveedores = [], onSave, onClose, guardando }: ModalProductoProps) {
  // Zod validation hook
  const { errors, validate, clearFieldError, hasAttemptedSubmit: intentoGuardar } = useZodValidation(modalProductoSchema);
  const errores = errors as ValidationErrors;

  const [form, setForm] = useState<ProductoFormData>(producto ? {
    id: producto.id,
    nombre: producto.nombre || '',
    codigo: producto.codigo || '',
    categoria: producto.categoria || '',
    proveedor_id: producto.proveedor_id || '',
    stock: producto.stock ?? '',
    stock_minimo: producto.stock_minimo ?? 10,
    porcentaje_iva: 21,
    costo_sin_iva: producto.costo_sin_iva ?? '',
    costo_con_iva: producto.costo_con_iva ?? '',
    impuestos_internos: producto.impuestos_internos ?? '',
    precio_sin_iva: producto.precio_sin_iva ?? '',
    precio: producto.precio ?? '',
    // ProductoDB usa `?: T | null`; el form usa `?: T`. Mapeo explícito null → undefined.
    unidades_de_venta_por_fardo: producto.unidades_de_venta_por_fardo ?? undefined,
    etiqueta_bulto: producto.etiqueta_bulto ?? undefined
  } : {
    nombre: '',
    codigo: '',
    categoria: '',
    proveedor_id: '',
    stock: '',
    stock_minimo: 10,
    porcentaje_iva: 21,
    costo_sin_iva: '',
    costo_con_iva: '',
    impuestos_internos: '',
    precio_sin_iva: '',
    precio: '', // precio_con_iva (precio final al cliente)
    unidades_de_venta_por_fardo: undefined,
    etiqueta_bulto: undefined
  });
  const [nuevaCategoria, setNuevaCategoria] = useState<string>('');
  const [mostrarNuevaCategoria, setMostrarNuevaCategoria] = useState<boolean>(false);

  // Margen (markup sobre el costo FINAL) — solo UI, bidireccional con el precio
  // final. Si edito el margen se recalcula el precio final; si edito el precio
  // final se recalcula el margen.
  const [margen, setMargen] = useState<string>(() => {
    const costoFinal = calcularTotalConIva(
      producto?.costo_sin_iva ?? '',
      producto?.porcentaje_iva ?? 21,
      producto?.impuestos_internos ?? '',
    );
    const precioFinal = parsePrecio(String(producto?.precio ?? ''));
    if (costoFinal > 0 && precioFinal > 0) {
      return calcularMargenPorcentaje(precioFinal, costoFinal).toFixed(1);
    }
    return '';
  });

  // Recalcula los campos derivados a partir del form:
  //  - costo_con_iva (costo final) desde el costo neto + IVA + imp. internos
  //  - precio_sin_iva (precio neto) HACIA ATRÁS desde el precio final (el usuario
  //    edita el precio final; en venta ZZ el ingreso es el final, en FC el neto).
  const recalcularTotales = (nuevoForm: ProductoFormData): ProductoFormData => {
    const costoTotal = calcularTotalConIva(nuevoForm.costo_sin_iva, nuevoForm.porcentaje_iva, nuevoForm.impuestos_internos);
    const precioNeto = calcularNetoDesdeTotal(nuevoForm.precio, nuevoForm.porcentaje_iva, nuevoForm.impuestos_internos);
    return {
      ...nuevoForm,
      costo_con_iva: costoTotal ? costoTotal.toFixed(2) : '',
      precio_sin_iva: precioNeto ? precioNeto.toFixed(2) : ''
    };
  };

  // Margen derivado del precio final vs costo final (markup sobre costo).
  const margenDesdeForm = (f: ProductoFormData): string => {
    const costoFinal = calcularTotalConIva(f.costo_sin_iva, f.porcentaje_iva, f.impuestos_internos);
    const precioFinal = parsePrecio(String(f.precio));
    if (costoFinal > 0 && precioFinal > 0) {
      return calcularMargenPorcentaje(precioFinal, costoFinal).toFixed(1);
    }
    return '';
  };

  // Manejar cambio de costo neto: el precio final se mantiene, se recalcula el margen.
  const handleCostoSinIvaChange = (valor: string): void => {
    const nuevoForm = recalcularTotales({ ...form, costo_sin_iva: valor });
    setForm(nuevoForm);
    setMargen(margenDesdeForm(nuevoForm));
  };

  // Imp. internos: cambian costo final y precio neto (precio final fijo); recalcular margen.
  const handleImpuestosInternosChange = (valor: string): void => {
    const nuevoForm = recalcularTotales({ ...form, impuestos_internos: valor });
    setForm(nuevoForm);
    setMargen(margenDesdeForm(nuevoForm));
  };

  // % IVA: ídem imp. internos.
  const handlePorcentajeIvaChange = (valor: string): void => {
    const nuevoForm = recalcularTotales({ ...form, porcentaje_iva: parseFloat(valor) });
    setForm(nuevoForm);
    setMargen(margenDesdeForm(nuevoForm));
  };

  // Manejar cambio de PRECIO FINAL (lo edita el usuario) → recalcula neto + margen.
  const handlePrecioChange = (valor: string): void => {
    const nuevoForm = recalcularTotales({ ...form, precio: valor });
    setForm(nuevoForm);
    setMargen(margenDesdeForm(nuevoForm));
    if (intentoGuardar && errores.precio) {
      clearFieldError('precio');
    }
  };

  // Manejar cambio de MARGEN → recalcula el precio final (y el neto).
  const handleMargenChange = (valor: string): void => {
    setMargen(valor);
    const costoFinal = calcularTotalConIva(form.costo_sin_iva, form.porcentaje_iva, form.impuestos_internos);
    if (costoFinal > 0 && valor.trim() !== '' && !Number.isNaN(parseFloat(valor))) {
      const precioFinal = calcularPrecioDesdeMargen(costoFinal, valor);
      setForm(recalcularTotales({ ...form, precio: precioFinal.toFixed(2) }));
      if (intentoGuardar && errores.precio) {
        clearFieldError('precio');
      }
    }
  };

  const handleFieldChange = (field: keyof ProductoFormData, value: string | number): void => {
    setForm({ ...form, [field]: value });
    if (intentoGuardar && errores[field]) {
      clearFieldError(field);
    }
  };

  const handleSubmit = (): void => {
    // La etiqueta es accesoria al fardo: sin unidades configuradas no tiene
    // sentido persistirla. Normalizar acá hace de defensa en profundidad por
    // si la UI dejó pasar un valor (ej. autocompletado del browser).
    const formNormalizado: ProductoFormData = form.unidades_de_venta_por_fardo
      ? form
      : { ...form, etiqueta_bulto: undefined };
    const result = validate(formNormalizado);
    if (result.success) {
      const categoriaFinal = mostrarNuevaCategoria && nuevaCategoria.trim()
        ? nuevaCategoria.trim()
        : formNormalizado.categoria;
      onSave({ ...formNormalizado, categoria: categoriaFinal, id: producto?.id });
      return;
    }
    // Validación falló: scrollear al primer mensaje de error inline para que sea visible
    // (el body del modal tiene overflow-y-auto y el error puede quedar fuera del viewport).
    requestAnimationFrame(() => {
      const firstErrorMsg = document.querySelector<HTMLElement>('p.text-red-500');
      firstErrorMsg?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
  };

  const inputClass = (field: string): string => `w-full px-3 py-2 border rounded-lg ${errores[field] ? 'border-red-500 bg-red-50' : ''}`;

  return (
    <ModalBase title={producto ? 'Editar Producto' : 'Nuevo Producto'} onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Informacion basica */}
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2 sm:col-span-1">
            <label className="block text-sm font-medium mb-1">Codigo</label>
            <input
              type="text"
              value={form.codigo || ''}
              onChange={(e: ChangeEvent<HTMLInputElement>) => handleFieldChange('codigo', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="SKU o codigo interno"
            />
          </div>
          <div className="col-span-2 sm:col-span-1">
            <label className="block text-sm font-medium mb-1">Stock *</label>
            <NumberInput
              integer
              min={0}
              emptyValue={0}
              value={Number(form.stock) || 0}
              onChange={(n) => handleFieldChange('stock', n)}
              commitOnChange
              className={inputClass('stock')}
            />
            {errores.stock && <p className="text-red-500 text-xs mt-1">{errores.stock}</p>}
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Stock Minimo de Seguridad</label>
          <NumberInput
            integer
            min={0}
            emptyValue={0}
            value={form.stock_minimo !== undefined ? form.stock_minimo : 10}
            onChange={(n) => handleFieldChange('stock_minimo', n)}
            commitOnChange
            className={inputClass('stock_minimo')}
            placeholder="10"
          />
          {errores.stock_minimo && <p className="text-red-500 text-xs mt-1">{errores.stock_minimo}</p>}
          <p className="text-xs text-gray-500 mt-1">
            Se mostrara una alerta cuando el stock este por debajo de este valor
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Nombre *</label>
          <input
            type="text"
            value={form.nombre}
            onChange={(e: ChangeEvent<HTMLInputElement>) => handleFieldChange('nombre', e.target.value)}
            className={inputClass('nombre')}
          />
          {errores.nombre && <p className="text-red-500 text-xs mt-1">{errores.nombre}</p>}
        </div>

        <div>
          <div className="flex justify-between items-center mb-1">
            <label className="block text-sm font-medium">Categoria</label>
            <button
              type="button"
              onClick={() => setMostrarNuevaCategoria(!mostrarNuevaCategoria)}
              className="text-sm text-blue-600 hover:text-blue-700"
            >
              {mostrarNuevaCategoria ? 'Elegir existente' : '+ Nueva categoria'}
            </button>
          </div>
          {mostrarNuevaCategoria ? (
            <input
              type="text"
              value={nuevaCategoria}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setNuevaCategoria(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Escribir nueva categoria..."
            />
          ) : (
            <select
              value={form.categoria || ''}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => setForm({ ...form, categoria: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Sin categoria</option>
              {categorias.map(cat => (
                <option key={getCategoryKey(cat)} value={getCategoryName(cat)}>{getCategoryName(cat)}</option>
              ))}
            </select>
          )}
        </div>

        {/* Proveedor */}
        {proveedores.length > 0 && (
          <div>
            <label className="block text-sm font-medium mb-1">Proveedor</label>
            <select
              value={form.proveedor_id || ''}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => setForm({ ...form, proveedor_id: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Sin proveedor</option>
              {proveedores.map(prov => (
                <option key={prov.id} value={prov.id}>{prov.nombre}</option>
              ))}
            </select>
          </div>
        )}

        {/* Bulto / Fardo: cuántas unidades de venta hacen un fardo y cómo lo llamamos */}
        {/* La etiqueta es accesoria al fardo: si no hay unidades configuradas, */}
        {/* la etiqueta queda deshabilitada y no se persiste. */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium mb-1">Unidades por bulto/fardo</label>
            <input
              type="number"
              inputMode="decimal"
              step="0.5"
              min="0"
              value={form.unidades_de_venta_por_fardo ?? ''}
              onChange={(e: ChangeEvent<HTMLInputElement>) => {
                const val = e.target.value
                const nuevasUnidades = val === '' ? undefined : Number(val)
                setForm({
                  ...form,
                  unidades_de_venta_por_fardo: nuevasUnidades,
                  // Si dejan unidades vacío, también limpiar la etiqueta — la etiqueta
                  // sola no tiene sentido y antes generaba un guardado bloqueado.
                  ...(nuevasUnidades ? {} : { etiqueta_bulto: undefined })
                })
                if (intentoGuardar && errores.unidades_de_venta_por_fardo) {
                  clearFieldError('unidades_de_venta_por_fardo');
                }
              }}
              className={inputClass('unidades_de_venta_por_fardo')}
              placeholder="ej. 2"
            />
            <p className="text-xs text-gray-500 mt-1">
              Cuántas unidades de venta hacen 1 fardo. Si 1 unidad = medio fardo, poné 2.
            </p>
            {errores.unidades_de_venta_por_fardo && (
              <p className="text-red-500 text-xs mt-1">{errores.unidades_de_venta_por_fardo}</p>
            )}
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Etiqueta del bulto</label>
            <input
              type="text"
              value={form.unidades_de_venta_por_fardo ? (form.etiqueta_bulto ?? '') : ''}
              onChange={(e: ChangeEvent<HTMLInputElement>) => {
                setForm({
                  ...form,
                  etiqueta_bulto: e.target.value === '' ? undefined : e.target.value.toUpperCase()
                })
                if (intentoGuardar && errores.etiqueta_bulto) {
                  clearFieldError('etiqueta_bulto');
                }
              }}
              disabled={!form.unidades_de_venta_por_fardo}
              className={`${inputClass('etiqueta_bulto')} uppercase disabled:bg-gray-100 disabled:cursor-not-allowed`}
              placeholder={form.unidades_de_venta_por_fardo ? 'FARDO' : 'Configura unidades primero'}
              maxLength={20}
            />
            <p className="text-xs text-gray-500 mt-1">FARDO, CAJA, PACK, BULTO...</p>
            {errores.etiqueta_bulto && (
              <p className="text-red-500 text-xs mt-1">{errores.etiqueta_bulto}</p>
            )}
          </div>
        </div>

        {/* Seccion de IVA */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Configuracion Impositiva</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">% IVA</label>
              <select
                value={form.porcentaje_iva ?? 21}
                onChange={(e: ChangeEvent<HTMLSelectElement>) => handlePorcentajeIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg text-sm"
              >
                {OPCIONES_IVA.map(opt => (
                  <option key={opt.valor} value={opt.valor}>{opt.label}</option>
                ))}
              </select>
              <p className="text-xs text-gray-500 mt-1">Se aplica solo sobre el neto</p>
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Imp. Internos (%)</label>
              <NumberInput
                min={0}
                max={100}
                emptyValue={0}
                value={parsePrecio(form.impuestos_internos)}
                onChange={(n) => handleImpuestosInternosChange(String(n))}
                commitOnChange
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0"
              />
              <p className="text-xs text-gray-500 mt-1">Porcentaje sobre el neto</p>
            </div>
          </div>
        </div>

        {/* Seccion de Costos */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Costos (compra)</h3>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo Neto</label>
              <NumberInput
                min={0}
                emptyValue={0}
                value={parsePrecio(form.costo_sin_iva)}
                onChange={(n) => handleCostoSinIvaChange(String(n))}
                commitOnChange
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo Total (Neto + IVA + Imp.Int.)</label>
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                value={form.costo_con_iva || ''}
                readOnly
                className="w-full px-3 py-2 border rounded-lg text-sm bg-gray-100 font-semibold"
                placeholder="0.00"
              />
            </div>
          </div>
          <p className="text-xs text-gray-500 mt-2">
            Costo real = Neto + Imp. Internos (sin IVA) = ${(parsePrecio(String(form.costo_sin_iva)) * (1 + (parseFloat(String(form.impuestos_internos)) || 0) / 100)).toFixed(2)}
          </p>
        </div>

        {/* Seccion de Precios de Venta */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Precios de Venta</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio Final (con IVA + Imp.Int.) *</label>
              <NumberInput
                min={0}
                emptyValue={0}
                value={parsePrecio(form.precio)}
                onChange={(n) => handlePrecioChange(String(n))}
                commitOnChange
                className={`w-full px-3 py-2 border rounded-lg font-semibold ${errores.precio ? 'border-red-500 bg-red-50' : ''}`}
                placeholder="0.00"
              />
              {errores.precio && <p className="text-red-500 text-xs mt-1">{errores.precio}</p>}
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio Neto (calculado)</label>
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                value={form.precio_sin_iva || ''}
                readOnly
                className="w-full px-3 py-2 border rounded-lg bg-gray-100"
                placeholder="0.00"
              />
            </div>
          </div>

          {/* Margen: markup sobre el costo final, bidireccional con el precio final */}
          <div className="grid grid-cols-2 gap-4 mt-3">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Margen (%)</label>
              <div className="relative">
                <NumberInput
                  value={parsePrecio(margen)}
                  emptyValue={0}
                  onChange={(n) => handleMargenChange(String(n))}
                  commitOnChange
                  disabled={parsePrecio(String(form.costo_con_iva)) <= 0}
                  className="w-full px-3 py-2 pr-7 border rounded-lg disabled:bg-gray-100 disabled:cursor-not-allowed"
                  placeholder="0.0"
                />
                <span className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 text-sm">%</span>
              </div>
              <p className="text-xs text-gray-500 mt-1">
                {parsePrecio(String(form.costo_con_iva)) > 0
                  ? 'Markup sobre el costo final. Editá margen o precio final indistintamente.'
                  : 'Cargá el costo para usar el margen.'}
              </p>
            </div>
            {(parsePrecio(String(form.costo_con_iva)) > 0 && parsePrecio(String(form.precio)) > 0) && (
              <div className="flex items-center">
                <div className="p-3 bg-blue-50 rounded-lg w-full">
                  <p className="text-xs font-medium text-blue-800">
                    Ganancia final: ${(parsePrecio(String(form.precio)) - parsePrecio(String(form.costo_con_iva))).toFixed(2)}
                  </p>
                  <p className="text-xs text-blue-600 mt-1">Precio final − costo final (con IVA e imp. internos)</p>
                </div>
              </div>
            )}
          </div>

          <p className="text-xs text-gray-500 mt-2">
            * El precio final incluye IVA ({form.porcentaje_iva || 21}%) + Imp. Internos ({form.impuestos_internos || 0}%). El neto se calcula hacia atrás.
          </p>
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

export default ModalProducto;
