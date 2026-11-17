import { describe, it, expect, vi, beforeEach } from 'vitest';

const refreshSession = vi.fn();
vi.mock('../lib/supabase', () => ({
  supabase: { auth: { refreshSession: () => refreshSession() } },
}));

const {
  pareceSesionVencida,
  explicarErrorDeSesion,
  olvidarRenovacionDeSesion,
  MENSAJE_SESION_RENOVADA,
  MENSAJE_SESION_CAIDA,
  MENSAJE_SESION_SIN_CONEXION,
  MENSAJE_SUCURSAL_NO_RESUELTA,
} = await import('./sesionVencida');

describe('pareceSesionVencida', () => {
  it('reconoce el error de sucursal, que es el síntoma habitual', () => {
    expect(pareceSesionVencida('No se pudo determinar la sucursal activa')).toBe(true);
    // Tal cual llega desde el RPC, con prefijo.
    expect(pareceSesionVencida('Error al crear pedido: No se pudo determinar la sucursal activa')).toBe(true);
  });

  it('reconoce los errores de JWT explícitos', () => {
    expect(pareceSesionVencida('JWT expired')).toBe(true);
    expect(pareceSesionVencida('token is expired')).toBe(true);
    expect(pareceSesionVencida('invalid claim: missing sub')).toBe(true);
  });

  it('no se come errores de negocio', () => {
    expect(pareceSesionVencida('Stock insuficiente en MANAOS COLA 3LT')).toBe(false);
    expect(pareceSesionVencida('La compra mínima de "FIDEO" es 3 unidades')).toBe(false);
    expect(pareceSesionVencida('')).toBe(false);
    expect(pareceSesionVencida(null)).toBe(false);
    expect(pareceSesionVencida(undefined)).toBe(false);
  });
});

describe('explicarErrorDeSesion', () => {
  beforeEach(() => {
    refreshSession.mockReset();
    olvidarRenovacionDeSesion();
    vi.useRealTimers();
  });

  it('deja pasar sin tocar los errores que no son de sesión', async () => {
    const msg = 'Stock insuficiente en MANAOS COLA 3LT';
    expect(await explicarErrorDeSesion(msg)).toBe(msg);
    expect(refreshSession).not.toHaveBeenCalled();
  });

  it('si la sesión se renueva, avisa que hay que reintentar', async () => {
    refreshSession.mockResolvedValue({ data: { session: { access_token: 'x' } }, error: null });
    expect(await explicarErrorDeSesion('No se pudo determinar la sucursal activa'))
      .toBe(MENSAJE_SESION_RENOVADA);
  });

  it('si no se puede renovar, manda a iniciar sesión de nuevo', async () => {
    refreshSession.mockResolvedValue({ data: { session: null }, error: { message: 'no refresh token' } });
    expect(await explicarErrorDeSesion('No se pudo determinar la sucursal activa'))
      .toBe(MENSAJE_SESION_CAIDA);
  });

  // 1600-b16: cambió de regla. Sin red el refresh falla igual, pero eso no dice que la
  // sesión haya vencido: mandar a cerrar sesión (sin señal para volver a entrar) era peor.
  it('sin red, dice que falta la conexión y no que la sesión venció', async () => {
    // supabase-js devuelve el error, no lo tira: así se ve un refresh sin red.
    const sinRed = Object.assign(new Error('Failed to fetch'), { name: 'AuthRetryableFetchError' });
    refreshSession.mockResolvedValue({ data: { session: null }, error: sinRed });
    expect(await explicarErrorDeSesion('JWT expired')).toBe(MENSAJE_SESION_SIN_CONEXION);
  });

  it('si el refresh lanza por la red, tampoco dice que venció', async () => {
    refreshSession.mockRejectedValue(new TypeError('Failed to fetch'));
    expect(await explicarErrorDeSesion('No se pudo determinar la sucursal activa'))
      .toBe(MENSAJE_SESION_SIN_CONEXION);
  });

  describe('«No se pudo determinar la sucursal activa» que vuelve tras renovar (1600-b16)', () => {
    const SUCURSAL = 'No se pudo determinar la sucursal activa';
    const renueva = () => refreshSession.mockResolvedValue({ data: { session: { access_token: 'x' } }, error: null });

    it('la primera vez renueva y pide reintentar; si vuelve, ya no repite el mismo cartel', async () => {
      renueva();
      expect(await explicarErrorDeSesion(SUCURSAL)).toBe(MENSAJE_SESION_RENOVADA);
      expect(await explicarErrorDeSesion(SUCURSAL)).toBe(MENSAJE_SUCURSAL_NO_RESUELTA);
      // La segunda ya no gasta otra renovación.
      expect(refreshSession).toHaveBeenCalledTimes(1);
    });

    it('el cartel nuevo no culpa a la sesión: manda a entrar de nuevo y nombra la sucursal y el usuario', () => {
      expect(MENSAJE_SUCURSAL_NO_RESUELTA).toMatch(/sucursal/);
      expect(MENSAJE_SUCURSAL_NO_RESUELTA).toMatch(/administrador/);
      expect(MENSAJE_SUCURSAL_NO_RESUELTA).not.toBe(MENSAJE_SESION_RENOVADA);
    });

    it('pasada la ventana, un error nuevo vuelve a ser un token vencido más', async () => {
      vi.useFakeTimers({ toFake: ['Date'] });
      renueva();
      expect(await explicarErrorDeSesion(SUCURSAL)).toBe(MENSAJE_SESION_RENOVADA);
      vi.advanceTimersByTime(11 * 60 * 1000);

      expect(await explicarErrorDeSesion(SUCURSAL)).toBe(MENSAJE_SESION_RENOVADA);
      expect(refreshSession).toHaveBeenCalledTimes(2);
    });

    it('un JWT vencido sí se renueva cada vez: es el token, no la sucursal', async () => {
      renueva();
      expect(await explicarErrorDeSesion('JWT expired')).toBe(MENSAJE_SESION_RENOVADA);
      expect(await explicarErrorDeSesion('JWT expired')).toBe(MENSAJE_SESION_RENOVADA);
      expect(refreshSession).toHaveBeenCalledTimes(2);
    });
  });
});
