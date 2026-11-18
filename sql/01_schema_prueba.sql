-- =====================================================================
-- SkyNest · 01_schema_prueba.sql
-- Prueba del esquema: inserta un caso válido de punta a punta y luego
-- intenta violar cada tipo de restricción (cada intento debe fallar).
-- Todo ocurre dentro de una transacción que se deshace al final:
-- la base queda vacía.
--
-- Uso:  psql -d skynest_dev -f sql/01_schema_prueba.sql
-- =====================================================================

\set ON_ERROR_STOP off
SET search_path = skynest, reportes, public;
\set VERBOSITY terse

BEGIN;

\echo '=== 1. Caso válido de punta a punta (todo debe insertarse) ==='
INSERT INTO distrito VALUES
  ('150131', 'San Isidro', 'Lima', FALSE, 120),
  ('150122', 'Miraflores', 'Lima', FALSE, 120),
  ('070101', 'Callao',     'Callao', TRUE, 60);
INSERT INTO estacion_nest (codigo, nombre, direccion, latitud, longitud, capacidad_drones, puertos_carga, ubigeo)
VALUES ('NST-SIS-01', 'Nest San Isidro', 'Av. Javier Prado Este 123', -12.0931, -77.0215, 10, 6, '150131');
INSERT INTO modelo_drone (fabricante, nombre, carga_util_max_kg, autonomia_min, velocidad_crucero_kmh, alcance_km)
VALUES ('Wingcopter', '198', 5.00, 40, 100, 75);
INSERT INTO drone (numero_serie, registro_dgac, fecha_adquisicion, id_modelo, id_nest_base)
VALUES ('WC198-0001', 'RPAS-PE-0001', '2026-03-01', 1, 1);
INSERT INTO bateria (numero_serie, quimica, capacidad_mah, voltaje_nominal_v, salud_pct)
VALUES ('BAT-0001', 'Li-ion', 22000, 44.4, 98.5);
INSERT INTO operador (dni, nombres, apellidos, email, nro_licencia, venc_licencia, id_nest)
VALUES ('45678912', 'Lucía', 'Ramos', 'lramos@skynest.pe', 'LIC-RPAS-001', '2027-06-30', 1);
INSERT INTO autorizacion VALUES (1, 1, '150122', '2026-01-01', '2027-01-01');
INSERT INTO cliente (email, telefono) VALUES ('botica@ejemplo.pe', '987654321');
INSERT INTO cliente_empresa VALUES (1, '20123456789', 'Botica Central S.A.C.', 'Ana Torres');
INSERT INTO ruta_vuelo (codigo, id_nest_origen, ubigeo_destino, distancia_km, altitud_crucero_m, duracion_est_min)
VALUES ('R-SIS-MIR-01', 1, '150122', 4.20, 90, 6);
INSERT INTO punto_ruta VALUES
  (1, 1, -12.093100, -77.021500,  0, 'despegue'),
  (1, 2, -12.115000, -77.030000, 90, 'entrega');
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, aterrizaje, estado, tipo_operacion, distancia_real_km)
VALUES (1, 1, 1, 1, '2026-11-14 10:00', '2026-11-14 10:02', '2026-11-14 10:15', 'completado', 'automatico', 4.35);
INSERT INTO paquete (codigo_tracking, id_cliente, id_vuelo, ubigeo_destino, peso_kg, largo_cm, ancho_cm, alto_cm,
                     prioridad, destinatario_nombre, destinatario_telefono, direccion_destino, lat_destino, lon_destino,
                     estado, fecha_registro, fecha_entrega, costo_envio)
VALUES ('SKY000000001', 1, 1, '150122', 1.20, 20, 15, 10, 'express', 'Carlos Díaz', '912345678',
        'Calle Schell 456, Miraflores', -12.1200, -77.0300, 'entregado', '2026-11-14 09:30', '2026-11-14 10:14', 12.50);
INSERT INTO telemetria_bateria VALUES
  (1, '2026-11-14 10:02:00.000', 44.1, 18.5, 31.2, 97.0),
  (1, '2026-11-14 10:02:05.000', 44.0, 19.1, 31.6, 96.7);

SELECT 'filas válidas insertadas' AS resultado,
       (SELECT count(*) FROM vuelo) AS vuelos,
       (SELECT count(*) FROM paquete) AS paquetes,
       (SELECT count(*) FROM telemetria_bateria) AS lecturas;

\echo ''
\echo '=== 2. Intentos inválidos (cada uno debe dar ERROR) ==='

\echo '--- PK duplicada (telemetría: misma marca de tiempo en el mismo vuelo)'
SAVEPOINT s;
INSERT INTO telemetria_bateria VALUES (1, '2026-11-14 10:02:00.000', 44.0, 18.0, 31.0, 96.0);
ROLLBACK TO s;

\echo '--- UNIQUE (código de tracking repetido)'
SAVEPOINT s;
INSERT INTO paquete (codigo_tracking, id_cliente, ubigeo_destino, peso_kg, largo_cm, ancho_cm, alto_cm,
                     destinatario_nombre, destinatario_telefono, direccion_destino, costo_envio)
VALUES ('SKY000000001', 1, '150122', 1, 10, 10, 10, 'X', '900000000', 'Dir', 5);
ROLLBACK TO s;

\echo '--- FK (drone con un modelo que no existe)'
SAVEPOINT s;
INSERT INTO drone (numero_serie, registro_dgac, fecha_adquisicion, id_modelo, id_nest_base)
VALUES ('WC198-0099', 'RPAS-PE-0099', '2026-03-01', 999, 1);
ROLLBACK TO s;

\echo '--- FK con NO ACTION (borrar un drone que ya tiene vuelos)'
SAVEPOINT s;
DELETE FROM drone WHERE id_drone = 1;
ROLLBACK TO s;

\echo '--- CHECK de formato (DNI con letras)'
SAVEPOINT s;
INSERT INTO operador (dni, nombres, apellidos, email, nro_licencia, venc_licencia, id_nest)
VALUES ('4567A912', 'Pedro', 'Soto', 'psoto@skynest.pe', 'LIC-RPAS-002', '2027-06-30', 1);
ROLLBACK TO s;

\echo '--- CHECK de dominio (carga de batería 120 %)'
SAVEPOINT s;
INSERT INTO telemetria_bateria VALUES (1, '2026-11-14 10:02:10.000', 44.0, 18.0, 31.0, 120);
ROLLBACK TO s;

\echo '--- CHECK R12 (batería con 65 % de salud marcada como operativa)'
SAVEPOINT s;
UPDATE bateria SET salud_pct = 65 WHERE id_bateria = 1;
ROLLBACK TO s;

\echo '--- CHECK R18 (aterrizaje antes del despegue)'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, aterrizaje, estado, tipo_operacion)
VALUES (1, 1, 1, 1, '2026-11-15 10:00', '2026-11-15 10:10', '2026-11-15 10:05', 'completado', 'manual');
ROLLBACK TO s;

\echo '--- CHECK estado/tiempos (vuelo completado sin aterrizaje)'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, estado, tipo_operacion)
VALUES (1, 1, 1, 1, '2026-11-15 10:00', '2026-11-15 10:02', 'completado', 'manual');
ROLLBACK TO s;

\echo '--- EXCLUDE R12 (misma batería en un vuelo que se solapa: 10:10-10:20 vs 10:02-10:15)'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, aterrizaje, estado, tipo_operacion)
VALUES (1, 1, 1, 1, '2026-11-14 10:08', '2026-11-14 10:10', '2026-11-14 10:20', 'completado', 'manual');
ROLLBACK TO s;

\echo '--- CHECK R19 (paquete entregado sin fecha de entrega)'
SAVEPOINT s;
UPDATE paquete SET fecha_entrega = NULL WHERE id_paquete = 1;
ROLLBACK TO s;

\echo '--- CHECK R19 (paquete en_ruta sin vuelo)'
SAVEPOINT s;
UPDATE paquete SET id_vuelo = NULL, estado = 'en_ruta' WHERE id_paquete = 1;
ROLLBACK TO s;

\echo '--- CHECK coordenadas (latitud sin longitud)'
SAVEPOINT s;
UPDATE paquete SET lon_destino = NULL WHERE id_paquete = 1;
ROLLBACK TO s;

\echo ''
\echo '=== 3. Casos que SÍ deben pasar ==='

\echo '--- Misma batería en un vuelo que NO se solapa (10:30-10:40)'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, aterrizaje, estado, tipo_operacion)
VALUES (1, 1, 1, 1, '2026-11-14 10:28', '2026-11-14 10:30', '2026-11-14 10:40', 'completado', 'manual');
ROLLBACK TO s;

\echo '--- Vuelo programado sin horarios reales (el EXCLUDE no aplica)'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
VALUES (1, 1, 1, 1, '2026-11-14 10:05', 'automatico');
ROLLBACK TO s;

\echo '--- Paquete sin coordenadas (dato faltante permitido)'
SAVEPOINT s;
UPDATE paquete SET lat_destino = NULL, lon_destino = NULL WHERE id_paquete = 1;
ROLLBACK TO s;

\echo '--- Borrar un vuelo borra en cascada su telemetría (entidad débil)'
SAVEPOINT s;
UPDATE paquete SET id_vuelo = NULL, estado = 'registrado', fecha_entrega = NULL WHERE id_paquete = 1;
DELETE FROM vuelo WHERE id_vuelo = 1;
SELECT count(*) AS lecturas_tras_borrar_vuelo FROM telemetria_bateria;
ROLLBACK TO s;

ROLLBACK;
\echo ''
\echo '=== Fin: transacción deshecha, la base queda vacía ==='
