// Utilidades compartidas para modales

export const formatFecha = (fecha) => new Date(fecha).toLocaleString('es-AR', {
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit'
});

// Helpers de validacion
export const validarTelefono = (telefono) => {
  if (!telefono) return true; // Opcional
  const telefonoLimpio = telefono.replace(/[\s\-\(\)]/g, '');
  return /^[0-9+]{6,15}$/.test(telefonoLimpio);
};

export const validarTexto = (texto, minLength = 2, maxLength = 100) => {
  if (!texto) return false;
  const limpio = texto.trim();
  return limpio.length >= minLength && limpio.length <= maxLength;
};
