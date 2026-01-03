import React, { useState, memo } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';

const ModalUsuario = memo(function ModalUsuario({ usuario, onSave, onClose, guardando }) {
  const [form, setForm] = useState(usuario || { nombre: '', rol: 'preventista', activo: true });

  return (
    <ModalBase title="Editar Usuario" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Email</label><input type="email" value={form.email || ''} disabled className="w-full px-3 py-2 border rounded-lg bg-gray-100" /></div>
        <div><label className="block text-sm font-medium mb-1">Nombre</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Rol</label><select value={form.rol} onChange={e => setForm({ ...form, rol: e.target.value })} className="w-full px-3 py-2 border rounded-lg"><option value="preventista">Preventista</option><option value="transportista">Transportista</option><option value="admin">Administrador</option></select></div>
        <div className="flex items-center space-x-2"><input type="checkbox" id="activo" checked={form.activo} onChange={e => setForm({ ...form, activo: e.target.checked })} className="w-4 h-4" /><label htmlFor="activo" className="text-sm">Usuario activo</label></div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={() => onSave({ ...form, id: usuario?.id })} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalUsuario;
