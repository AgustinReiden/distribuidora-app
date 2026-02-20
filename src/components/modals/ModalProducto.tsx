import { useState, memo } from 'react';
import type { ChangeEvent } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalProductoSchema } from '../../lib/schemas';
import { calcularTotalConIva } from '../../utils/calculations';
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
    precio: producto.precio ?? ''
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
    precio: '' // precio_con_iva (precio final al cliente)
  });
  const [nuevaCategoria, setNuevaCategoria] = useState<string>('');
  const [mostrarNuevaCategoria, setMostrarNuevaCategoria] = useState<boolean>(false);

  // Recalcular totales cuando cambian los valores
  const recalcularTotales = (nuevoForm: ProductoFormData): ProductoFormData => {
    const costoTotal = calcularTotalConIva(nuevoForm.costo_sin_iva, nuevoForm.porcentaje_iva, nuevoForm.impuestos_internos);
    const precioTotal = calcularTotalConIva(nuevoForm.precio_sin_iva, nuevoForm.porcentaje_iva, nuevoForm.impuestos_internos);
    return {
      ...nuevoForm,
      costo_con_iva: costoTotal ? costoTotal.toFixed(2) : '',
      precio: precioTotal ? precioTotal.toFixed(2) : ''
    };
  };

  // Manejar cambio de costo neto
  const handleCostoSinIvaChange = (valor: string): void => {
    const nuevoForm = { ...form, costo_sin_iva: valor };
    setForm(recalcularTotales(nuevoForm));
  };

  // Manejar cambio de impuestos internos
  const handleImpuestosInternosChange = (valor: string): void => {
    const nuevoForm = { ...form, impuestos_internos: valor };
    setForm(recalcularTotales(nuevoForm));
  };

  // Manejar cambio de porcentaje IVA
  const handlePorcentajeIvaChange = (valor: string): void => {
    const nuevoForm = { ...form, porcentaje_iva: parseFloat(valor) };
    setForm(recalcularTotales(nuevoForm));
  };

  // Manejar cambio de precio neto
  const handlePrecioSinIvaChange = (valor: string): void => {
    const nuevoForm = { ...form, precio_sin_iva: valor };
    setForm(recalcularTotales(nuevoForm));
    if (intentoGuardar && errores.precio) {
      clearFieldError('precio');
    }
  };

  const handleFieldChange = (field: keyof ProductoFormData, value: string | number): void => {
    setForm({ ...form, [field]: value });
    if (intentoGuardar && errores[field]) {
      clearFieldError(field);
    }
  };

  const handleSubmit = (): void => {
    const result = validate(form);
    if (result.success) {
      const categoriaFinal = mostrarNuevaCategoria && nuevaCategoria.trim()
        ? nuevaCategoria.trim()
        : form.categoria;
      onSave({ ...form, categoria: categoriaFinal, id: producto?.id });
    }
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
            <input
              type="number"
              value={form.stock}
              onChange={(e: ChangeEvent<HTMLInputElement>) => {
                const val = e.target.value;
                // Permitir campo vacío temporalmente mientras escribe, pero validar como número
                handleFieldChange('stock', val === '' ? '' : (parseInt(val, 10) || 0));
              }}
              className={inputClass('stock')}
              min="0"
            />
            {errores.stock && <p className="text-red-500 text-xs mt-1">{errores.stock}</p>}
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Stock Minimo de Seguridad</label>
          <input
            type="number"
            value={form.stock_minimo !== undefined ? form.stock_minimo : 10}
            onChange={(e: ChangeEvent<HTMLInputElement>) => handleFieldChange('stock_minimo', parseInt(e.target.value) || 0)}
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
              <input
                type="number"
                step="0.01"
                min="0"
                max="100"
                value={form.impuestos_internos || ''}
                onChange={(e: ChangeEvent<HTMLInputElement>) => handleImpuestosInternosChange(e.target.value)}
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
              <input
                type="number"
                step="0.01"
                value={form.costo_sin_iva || ''}
                onChange={(e: ChangeEvent<HTMLInputElement>) => handleCostoSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo Total (Neto + IVA + Imp.Int.)</label>
              <input
                type="number"
                step="0.01"
                value={form.costo_con_iva || ''}
                readOnly
                className="w-full px-3 py-2 border rounded-lg text-sm bg-gray-100 font-semibold"
                placeholder="0.00"
              />
            </div>
          </div>
          <p className="text-xs text-gray-500 mt-2">
            Costo real = Neto + Imp. Internos (sin IVA) = ${((parseFloat(String(form.costo_sin_iva)) || 0) * (1 + (parseFloat(String(form.impuestos_internos)) || 0) / 100)).toFixed(2)}
          </p>
        </div>

        {/* Seccion de Precios de Venta */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Precios de Venta</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio Neto</label>
              <input
                type="number"
                step="0.01"
                value={form.precio_sin_iva || ''}
                onChange={(e: ChangeEvent<HTMLInputElement>) => handlePrecioSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio Final (Neto + IVA + Imp.Int.) *</label>
              <input
                type="number"
                step="0.01"
                value={form.precio}
                readOnly
                className={`w-full px-3 py-2 border rounded-lg font-semibold ${errores.precio ? 'border-red-500 bg-red-50' : 'bg-green-100 border-green-300'}`}
                placeholder="0.00"
              />
              {errores.precio && <p className="text-red-500 text-xs mt-1">{errores.precio}</p>}
            </div>
          </div>
          <p className="text-xs text-gray-500 mt-2">
            * El precio final incluye IVA ({form.porcentaje_iva || 21}%) + Imp. Internos ({form.impuestos_internos || 0}%) sobre neto
          </p>
          {(parseFloat(String(form.costo_sin_iva)) > 0 && parseFloat(String(form.precio_sin_iva)) > 0) && (
            <div className="mt-3 p-3 bg-blue-50 rounded-lg">
              <p className="text-xs font-medium text-blue-800">
                Rentabilidad neta: ${((parseFloat(String(form.precio_sin_iva)) || 0) - (parseFloat(String(form.costo_sin_iva)) || 0)).toFixed(2)}
                {' '}({(((parseFloat(String(form.precio_sin_iva)) - parseFloat(String(form.costo_sin_iva))) / parseFloat(String(form.costo_sin_iva))) * 100).toFixed(1)}%)
              </p>
              <p className="text-xs text-blue-600 mt-1">
                Margen sobre costo neto (sin IVA ni imp. internos)
              </p>
            </div>
          )}
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
