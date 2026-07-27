-- =========================================================================
-- 141_backfill_horarios_canonicos.sql
--
-- Convierte el horario de atención escrito a mano al formato canónico
-- "HH:MM-HH:MM y …" + bitmask de días, para que el ruteo por barridas pueda
-- usarlo. Generado corriendo src/utils/parseHorarioLibre.ts (el MISMO parser
-- que usa la app, con 45 tests) sobre los textos reales de producción.
--
-- ALCANCE: SOLO las conversiones de confianza alta.
--   103 textos distintos → 205 clientes  (79.2%)
--    22 textos distintos quedan SIN TOCAR → 54 clientes (20.8%)
--     (cruces de medianoche, "24 hs", aperturas sin cierre y horarios que
--      cambian según el día: van a revisión manual)
--
-- REVERSIBLE: el texto original queda en clientes.horarios_atencion_original.
-- Para revertir:
--   UPDATE clientes SET horarios_atencion = horarios_atencion_original,
--                       dias_atencion = NULL
--   WHERE horarios_atencion_original IS NOT NULL;
-- =========================================================================

WITH mapeo(texto_original, canonico, dias) AS (
  VALUES
    ('Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs', '09:00-14:00 y 17:00-21:00', '1111110'),
    ('Lunes a sábado de 8hs a 14hs y 17hs a 22hs', '08:00-14:00 y 17:00-22:00', '1111110'),
    ('9 A 23', '09:00-23:00', NULL),
    ('Lunes a sábado de 9 hrs a 14 hrs y 17 hs a 21hs', '09:00-14:00 y 17:00-21:00', '1111110'),
    ('8 A 00', '08:00-24:00', NULL),
    ('8:30 A 14', '08:30-14:00', NULL),
    ('9 A 14', '09:00-14:00', NULL),
    ('9 a 14', '09:00-14:00', NULL),
    ('9 A 15', '09:00-15:00', NULL),
    ('8 A 14', '08:00-14:00', NULL),
    ('8 A 15', '08:00-15:00', NULL),
    ('8 A 23', '08:00-23:00', NULL),
    ('7 A 00', '07:00-24:00', NULL),
    ('8 A 13', '08:00-13:00', NULL),
    ('9 A 00', '09:00-24:00', NULL),
    ('7 A 15', '07:00-15:00', NULL),
    ('7 A 23', '07:00-23:00', NULL),
    ('7:30 A 23', '07:30-23:00', NULL),
    ('8 a 11 de 14 a 17', '08:00-11:00 y 14:00-17:00', NULL),
    ('8 A 22', '08:00-22:00', NULL),
    ('8:30 A 15', '08:30-15:00', NULL),
    ('9 A 12', '09:00-12:00', NULL),
    ('Lunes a sábado de 9 hs a 21hs', '09:00-21:00', '1111110'),
    ('Lunes a viernes de 8hs a 14hs', '08:00-14:00', '1111100'),
    ('10 A 23', '10:00-23:00', NULL),
    ('10:30 a 14 y de 19:30 a 22:30 de lunes a domingos', '10:30-14:00 y 19:30-22:30', '1111111'),
    ('7 a 11 y de 13:30 a 17', '07:00-11:00 y 13:30-17:00', NULL),
    ('7 A 13:30', '07:00-13:30', NULL),
    ('7 A 14:30', '07:00-14:30', NULL),
    ('7 A 19', '07:00-19:00', NULL),
    ('7:30 A 14', '07:30-14:00', NULL),
    ('8 a 11 y de 14 a 17', '08:00-11:00 y 14:00-17:00', NULL),
    ('8 A 12 HS', '08:00-12:00', NULL),
    ('8 A 12:30', '08:00-12:30', NULL),
    ('8 A 13:30', '08:00-13:30', NULL),
    ('8 a 14', '08:00-14:00', NULL),
    ('8 A 14:30', '08:00-14:30', NULL),
    ('8 a 14:30 y 17:30 a 23 de lunes a domingos', '08:00-14:30 y 17:30-23:00', '1111111'),
    ('8 a 15', '08:00-15:00', NULL),
    ('8 a 15 y 18 a 20 de lunes sábados', '08:00-15:00 y 18:00-20:00', '1111110'),
    ('8 A 24', '08:00-24:00', NULL),
    ('8: A 00', '08:00-24:00', NULL),
    ('8:30 a 14 después 18 a 22', '08:30-14:00 y 18:00-22:00', NULL),
    ('8:30 A 14:30', '08:30-14:30', NULL),
    ('9 A 13', '09:00-13:00', NULL),
    ('9 A 13:30', '09:00-13:30', NULL),
    ('9 a 14 de 19 a 22', '09:00-14:00 y 19:00-22:00', NULL),
    ('9 A 14 Y 17 A 22', '09:00-14:00 y 17:00-22:00', NULL),
    ('9 A 14 Y 18 A 22', '09:00-14:00 y 18:00-22:00', NULL),
    ('9 a 15', '09:00-15:00', NULL),
    ('9 A 16', '09:00-16:00', NULL),
    ('9 A 17', '09:00-17:00', NULL),
    ('9 A 21', '09:00-21:00', NULL),
    ('9 A 22', '09:00-22:00', NULL),
    ('9 A 24', '09:00-24:00', NULL),
    ('9:30 A 00', '09:30-24:00', NULL),
    ('9:30 a 14 y de 17 a 23', '09:30-14:00 y 17:00-23:00', NULL),
    ('9:30 A 14:30', '09:30-14:30', NULL),
    ('9:30 A 15:30', '09:30-15:30', NULL),
    ('De 10 a 00 de lunes a domingos', '10:00-24:00', '1111111'),
    ('De 11 a 15 y de 19 a 23', '11:00-15:00 y 19:00-23:00', NULL),
    ('De 6:30 a 23 de lunes a domingos', '06:30-23:00', '1111111'),
    ('De 7 a 00 de lunes a domingos', '07:00-24:00', '1111111'),
    ('De 7 a 12:30 y de 17 a 19:30 de lunes a sábados', '07:00-12:30 y 17:00-19:30', '1111110'),
    ('De 7 a 23 de lunes a viernes', '07:00-23:00', '1111100'),
    ('De 7:30 a 14', '07:30-14:00', NULL),
    ('De 8 a 00 de lunes a domingos', '08:00-24:00', '1111111'),
    ('De 8 a 12', '08:00-12:00', NULL),
    ('De 8 a 13 y de 17:30 a 21 de Lunes a Sábado', '08:00-13:00 y 17:30-21:00', '1111110'),
    ('De 8 a 13 y de 18 a 23 de lunes a domingos', '08:00-13:00 y 18:00-23:00', '1111111'),
    ('De 8 a 14 y de 18 a 23 de lunes a sábados', '08:00-14:00 y 18:00-23:00', '1111110'),
    ('De 8 a 15 y de 18 a 23', '08:00-15:00 y 18:00-23:00', NULL),
    ('De 8 a 20 de lunes a domingos', '08:00-20:00', '1111111'),
    ('De 8 a 22 de lunes a domingos', '08:00-22:00', '1111111'),
    ('De 8:30 a 00 de lunes a domingos', '08:30-24:00', '1111111'),
    ('De 8:30 a 00 de lunes a viernes', '08:30-24:00', '1111100'),
    ('De 8:30 a 21 de lunes a viernes', '08:30-21:00', '1111100'),
    ('De 9 a 00 de lunes a domingos', '09:00-24:00', '1111111'),
    ('De 9 a 13:30 y de 17 a 22:30', '09:00-13:30 y 17:00-22:30', NULL),
    ('De 9 a 13:30 y de 17:30 a 22', '09:00-13:30 y 17:30-22:00', NULL),
    ('De 9 a 13:30 y de 18 a 22 de lunes a domingos', '09:00-13:30 y 18:00-22:00', '1111111'),
    ('De 9 a 14 y de 15 a 22 de lunes a viernes', '09:00-14:00 y 15:00-22:00', '1111100'),
    ('De 9 a 14 y de 17 a 22 de lunes a domingo', '09:00-14:00 y 17:00-22:00', '1111111'),
    ('De 9 a 14 y de 18 a 22 de lunes a sábados', '09:00-14:00 y 18:00-22:00', '1111110'),
    ('De 9 a 14 y de 18 a 23 de lunes a domingos', '09:00-14:00 y 18:00-23:00', '1111111'),
    ('De 9 a 14:30 de 17:30 a 22', '09:00-14:30 y 17:30-22:00', NULL),
    ('De 9 a 14:30 y de 17:30 a 23', '09:00-14:30 y 17:30-23:00', NULL),
    ('De 9 a 14:30 y de 18 a 23 de lunes a domingos', '09:00-14:30 y 18:00-23:00', '1111111'),
    ('De 9 a 23 de lunes a domingos', '09:00-23:00', '1111111'),
    ('De 9:30 a 13:30 y de 17:30 a 22 de lunes a domingos', '09:30-13:30 y 17:30-22:00', '1111111'),
    ('De 9:30 a 14 y de 19 a 22 de lunes a domingos', '09:30-14:00 y 19:00-22:00', '1111111'),
    ('Horarios desde 10:30 a 14 desde 15 a 17', '10:30-14:00 y 15:00-17:00', NULL),
    ('Lunes a domingo 8:30 a 23:00 hs', '08:30-23:00', '1111111'),
    ('Lunes a sábado 10hs a 22hs', '10:00-22:00', '1111110'),
    ('Lunes a sábado 9hs a 14hs y 17hs a 22hs', '09:00-14:00 y 17:00-22:00', '1111110'),
    ('Lunes a sábado de 9 a 14 hrs y 17 hs a 21hs', '09:00-14:00 y 17:00-21:00', '1111110'),
    ('Lunes a sábado de 9 hs a 14 hs y 17 a 21 hs', '09:00-14:00 y 17:00-21:00', '1111110'),
    ('Lunes a sábado de 9hs a 14hs y 17 hs a 21hs', '09:00-14:00 y 17:00-21:00', '1111110'),
    ('Lunes a viernes 6:30 a 12 después 13 a 15', '06:30-12:00 y 13:00-15:00', '1111100'),
    ('Lunes a viernes 8:30hs a 15hs y 17hs a 22hs', '08:30-15:00 y 17:00-22:00', '1111100'),
    ('Mañana (08 a 13)', '08:00-13:00', NULL),
    ('Mañana (08 a 13) y Tarde (16 a 20)', '08:00-13:00 y 16:00-20:00', NULL),
    ('Todos los dias de 8:30 a 14 y de 17:30 a 23', '08:30-14:00 y 17:30-23:00', '1111111')
)
UPDATE clientes c
SET horarios_atencion          = m.canonico,
    dias_atencion              = m.dias,
    -- Preserva el texto tal cual estaba, solo la primera vez.
    horarios_atencion_original = COALESCE(c.horarios_atencion_original, c.horarios_atencion)
FROM mapeo m
WHERE trim(c.horarios_atencion) = m.texto_original
  AND c.activo IS NOT FALSE;
