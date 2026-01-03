import React, { useState, memo } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';
import { validarTexto } from './utils';

const ModalProducto = memo(function ModalProducto({ producto, categorias, onSave, onClose, guardando }) {
  const [form, setForm] = useState(producto || {
    nombre: '',
    codigo: '',
    categoria: '',
    stock: '',
    stock_minimo: 10,
    costo_sin_iva: '',
    costo_con_iva: '',
    impuestos_internos: '',
    precio_sin_iva: '',
    precio: '' // precio_con_iva (precio final al cliente)
  });
  const [nuevaCategoria, setNuevaCategoria] = useState('');
  const [mostrarNuevaCategoria, setMostrarNuevaCategoria] = useState(false);
  const [errores, setErrores] = useState({});
  const [intentoGuardar, setIntentoGuardar] = useState(false);

  // Calcular automaticamente costo con IVA cuando cambia costo sin IVA
  const handleCostoSinIvaChange = (valor) => {
    const costoSinIva = parseFloat(valor) || 0;
    const costoConIva = costoSinIva * 1.21; // 21% IVA
    setForm({
      ...form,
      costo_sin_iva: valor,
      costo_con_iva: costoConIva ? costoConIva.toFixed(2) : ''
    });
  };

  // Calcular automaticamente precio con IVA cuando cambia precio sin IVA
  const handlePrecioSinIvaChange = (valor) => {
    const precioSinIva = parseFloat(valor) || 0;
    const precioConIva = precioSinIva * 1.21; // 21% IVA
    setForm({
      ...form,
      precio_sin_iva: valor,
      precio: precioConIva ? precioConIva.toFixed(2) : ''
    });
    if (intentoGuardar && errores.precio) {
      setErrores(prev => ({ ...prev, precio: null }));
    }
  };

  const validarFormulario = () => {
    const nuevosErrores = {};

    if (!validarTexto(form.nombre, 2, 100)) {
      nuevosErrores.nombre = 'El nombre debe tener entre 2 y 100 caracteres';
    }

    if (form.stock === '' || form.stock === null || isNaN(parseInt(form.stock)) || parseInt(form.stock) < 0) {
      nuevosErrores.stock = 'El stock debe ser un numero mayor o igual a 0';
    }

    if (!form.precio || isNaN(parseFloat(form.precio)) || parseFloat(form.precio) <= 0) {
      nuevosErrores.precio = 'El precio debe ser un numero mayor a 0';
    }

    if (form.stock_minimo !== '' && form.stock_minimo !== null && (isNaN(parseInt(form.stock_minimo)) || parseInt(form.stock_minimo) < 0)) {
      nuevosErrores.stock_minimo = 'El stock minimo debe ser un numero mayor o igual a 0';
    }

    setErrores(nuevosErrores);
    return Object.keys(nuevosErrores).length === 0;
  };

  const handleFieldChange = (field, value) => {
    setForm({ ...form, [field]: value });
    if (intentoGuardar && errores[field]) {
      setErrores(prev => ({ ...prev, [field]: null }));
    }
  };

  const handleSubmit = () => {
    setIntentoGuardar(true);
    if (validarFormulario()) {
      const categoriaFinal = mostrarNuevaCategoria && nuevaCategoria.trim()
        ? nuevaCategoria.trim()
        : form.categoria;
      onSave({ ...form, categoria: categoriaFinal, id: producto?.id });
    }
  };

  const inputClass = (field) => `w-full px-3 py-2 border rounded-lg ${errores[field] ? 'border-red-500 bg-red-50' : ''}`;

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
              onChange={e => handleFieldChange('codigo', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="SKU o codigo interno"
            />
          </div>
          <div className="col-span-2 sm:col-span-1">
            <label className="block text-sm font-medium mb-1">Stock *</label>
            <input
              type="number"
              value={form.stock}
              onChange={e => handleFieldChange('stock', parseInt(e.target.value) || '')}
              className={inputClass('stock')}
            />
            {errores.stock && <p className="text-red-500 text-xs mt-1">{errores.stock}</p>}
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Stock Minimo de Seguridad</label>
          <input
            type="number"
            value={form.stock_minimo !== undefined ? form.stock_minimo : 10}
            onChange={e => handleFieldChange('stock_minimo', parseInt(e.target.value) || 0)}
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
            onChange={e => handleFieldChange('nombre', e.target.value)}
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
              onChange={e => setNuevaCategoria(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Escribir nueva categoria..."
            />
          ) : (
            <select
              value={form.categoria || ''}
              onChange={e => setForm({ ...form, categoria: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Sin categoria</option>
              {categorias.map(cat => (
                <option key={cat} value={cat}>{cat}</option>
              ))}
            </select>
          )}
        </div>

        {/* Seccion de Costos */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Costos (compra)</h3>
          <div className="grid grid-cols-3 gap-3">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo sin IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.costo_sin_iva || ''}
                onChange={e => handleCostoSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo con IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.costo_con_iva || ''}
                onChange={e => setForm({ ...form, costo_con_iva: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg text-sm bg-gray-50"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Imp. Internos</label>
              <input
                type="number"
                step="0.01"
                value={form.impuestos_internos || ''}
                onChange={e => setForm({ ...form, impuestos_internos: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
          </div>
        </div>

        {/* Seccion de Precios de Venta */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Precios de Venta</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio sin IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.precio_sin_iva || ''}
                onChange={e => handlePrecioSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio con IVA (Final) *</label>
              <input
                type="number"
                step="0.01"
                value={form.precio}
                onChange={e => handleFieldChange('precio', parseFloat(e.target.value) || '')}
                className={`w-full px-3 py-2 border rounded-lg font-semibold ${errores.precio ? 'border-red-500 bg-red-50' : 'bg-green-50 border-green-300'}`}
                placeholder="0.00"
              />
              {errores.precio && <p className="text-red-500 text-xs mt-1">{errores.precio}</p>}
            </div>
          </div>
          <p className="text-xs text-gray-500 mt-2">* El precio con IVA es el que se muestra al cliente en los pedidos</p>
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
