/**
 * true si el mensaje de error apunta a un problema de sesión disfrazado.
 * Se acepta el de sucursal porque, con el front validando el header, es el
 * síntoma habitual de un token inválido.
 */
export function pareceSesionVencida(mensaje?: string | null): boolean {
  const m = (mensaje ?? '').toLowerCase();
  if (!m) return false;
  return (
    m.includes('no se pudo determinar la sucursal activa') ||
    m.includes('jwt expired') ||
    m.includes('token is expired') ||
    m.includes('invalid claim')
  );
}
