-- =====================================================================
-- SkyNest · 04_flujo_prueba.sql
-- Prueba de triggers (03) y procedimientos (04) sobre una base con datos.
--   Parte 1: flujo completo de un envío con los procedimientos.
--   Parte 2: cada regla de 03_triggers.sql rechaza una operación inválida.
-- Todo ocurre en una transacción que se deshace al final.
--
-- Uso:  psql -d skynest_1k -f sql/04_flujo_prueba.sql
-- =====================================================================

\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset footer off
BEGIN;

\echo '================ PARTE 1. FLUJO COMPLETO DE UN ENVÍO ================'

\echo '--- 1. Registrar un cliente persona'
CALL sp_registrar_cliente_persona('ana.prueba@correo.pe', '987000111', '70112233', 'Ana', 'Prueba Quispe', NULL);
SELECT id_cliente AS cli FROM cliente WHERE email = 'ana.prueba@correo.pe' \gset

\echo '--- 2. Elegir una ruta de San Isidro a un distrito no restringido'
SELECT r.id_ruta AS ruta, r.ubigeo_destino AS destino, d.nombre AS distrito
FROM ruta_vuelo r JOIN distrito d ON d.ubigeo = r.ubigeo_destino
JOIN estacion_nest n ON n.id_nest = r.id_nest_origen
WHERE n.codigo = 'NST-SIS-01' AND NOT d.zona_restringida AND r.distancia_km < 4
ORDER BY r.id_ruta LIMIT 1 \gset
SELECT :ruta AS id_ruta, :'destino' AS ubigeo_destino, :'distrito' AS distrito;

\echo '--- 3. Registrar un paquete (genera el código de tracking)'
CALL sp_registrar_paquete(:cli, :'destino', 0.8, 20, 15, 10, 'express', false,
                          'Luis Destinatario', '912000333', 'Av. Prueba 123', -12.1, -77.03, NULL);
SELECT codigo_tracking AS trk FROM paquete WHERE id_cliente = :cli \gset

\echo '--- 4. Programar el vuelo (elige drone, batería y operador)'
CALL sp_programar_vuelo(:ruta, '2026-11-20 10:00', 'automatico', NULL);
SELECT max(id_vuelo) AS vuelo FROM vuelo \gset
SELECT v.id_vuelo, v.id_drone AS drone, v.id_bateria AS bateria, v.id_operador AS operador, v.estado
FROM vuelo v WHERE v.id_vuelo = :vuelo;
SELECT id_drone AS drn, id_bateria AS bat FROM vuelo WHERE id_vuelo = :vuelo \gset
SELECT horas_vuelo AS horas_antes FROM drone WHERE id_drone = :drn \gset
SELECT ciclos_carga AS ciclos_antes FROM bateria WHERE id_bateria = :bat \gset

\echo '--- 5. Asignar el paquete al vuelo'
CALL sp_asignar_paquete(:'trk', :vuelo);

\echo '--- 6. Despegar: paquete -> en_ruta, drone -> en_vuelo (automático)'
CALL sp_despegar_vuelo(:vuelo, '2026-11-20 10:01');
SELECT p.estado AS paquete, d.estado AS drone FROM paquete p, drone d
WHERE p.codigo_tracking = :'trk' AND d.id_drone = :drn;

\echo '--- 7. Registrar una lectura de telemetría durante el vuelo'
CALL sp_registrar_lectura(:vuelo, 43.9, 21.5, 33.0, 91.0, '2026-11-20 10:05');

\echo '--- 8. Aterrizar: paquete -> entregado, drone -> cargando, suma horas y ciclos (automático)'
CALL sp_cerrar_vuelo(:vuelo, 5.40, true, '2026-11-20 10:16');
SELECT p.estado AS paquete, p.fecha_entrega, d.estado AS drone,
       :horas_antes AS horas_antes, d.horas_vuelo AS horas_despues,
       :ciclos_antes AS ciclos_antes, b.ciclos_carga AS ciclos_despues
FROM paquete p, drone d, bateria b
WHERE p.codigo_tracking = :'trk' AND d.id_drone = :drn AND b.id_bateria = :bat;

\echo '--- 9. Cancelar un vuelo devuelve sus paquetes a "registrado"'
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn;
CALL sp_registrar_paquete(:cli, :'destino', 0.5, 10, 10, 10, 'estandar', false,
                          'Otro Destinatario', '912000444', 'Jr. Prueba 456', NULL, NULL, NULL);
SELECT max(codigo_tracking) AS trk2 FROM paquete WHERE id_cliente = :cli \gset
CALL sp_programar_vuelo(:ruta, '2026-11-21 09:00', 'manual', NULL);
SELECT max(id_vuelo) AS vuelo2 FROM vuelo \gset
CALL sp_asignar_paquete(:'trk2', :vuelo2);
CALL sp_cancelar_vuelo(:vuelo2);
SELECT codigo_tracking, estado, id_vuelo FROM paquete WHERE codigo_tracking = :'trk2';

\echo ''
\echo '================ PARTE 2. CADA REGLA RECHAZA LO INVÁLIDO ================'

\echo '--- (i) R16: el mismo cliente como persona y como empresa'
SAVEPOINT s;
INSERT INTO cliente_empresa VALUES (:cli, '20999999991', 'Empresa Duplicada SAC', NULL);
ROLLBACK TO s;

\echo '--- (i) R16: un cliente sin subclase (se revisa al cerrar la transacción)'
SAVEPOINT s;
INSERT INTO cliente (email) VALUES ('sin.subclase@correo.pe');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK TO s;

\echo '--- (ii) R15: paquete más pesado que la carga útil del drone'
SAVEPOINT s;
CALL sp_programar_vuelo(:ruta, '2026-11-22 09:00', 'manual', NULL);
SELECT max(id_vuelo) AS vuelo3 FROM vuelo \gset
SELECT m.carga_util_max_kg + 1 AS pesado FROM vuelo v JOIN drone d USING (id_drone)
JOIN modelo_drone m USING (id_modelo) WHERE v.id_vuelo = :vuelo3 \gset
CALL sp_registrar_paquete(:cli, :'destino', :pesado, 50, 40, 30, 'estandar', false,
                          'Carga Pesada', '912000555', 'Av. Peso 1', NULL, NULL, NULL);
SELECT max(codigo_tracking) AS trk3 FROM paquete WHERE id_cliente = :cli \gset
CALL sp_asignar_paquete(:'trk3', :vuelo3);
ROLLBACK TO s;

\echo '--- (v) R14: paquete a otro distrito que la ruta del vuelo'
SAVEPOINT s;
CALL sp_programar_vuelo(:ruta, '2026-11-22 11:00', 'manual', NULL);
SELECT max(id_vuelo) AS vuelo4 FROM vuelo \gset
CALL sp_registrar_paquete(:cli, '150142', 0.5, 10, 10, 10, 'estandar', false,
                          'Otro Distrito', '912000666', 'Av. VES 1', NULL, NULL, NULL);
SELECT max(codigo_tracking) AS trk4 FROM paquete WHERE id_cliente = :cli \gset
CALL sp_asignar_paquete(:'trk4', :vuelo4);
ROLLBACK TO s;

\echo '--- Asignar un paquete a un vuelo que ya aterrizó'
SAVEPOINT s;
CALL sp_registrar_paquete(:cli, :'destino', 0.5, 10, 10, 10, 'estandar', false,
                          'Tarde', '912000777', 'Av. Tarde 1', NULL, NULL, NULL);
SELECT max(id_paquete) AS idp5 FROM paquete \gset
UPDATE paquete SET id_vuelo = :vuelo, estado = 'asignado' WHERE id_paquete = :idp5;
ROLLBACK TO s;

\echo '--- (vi) R10: drone de otro nest que el de la ruta'
SAVEPOINT s;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
SELECT d.id_drone, :bat, :ruta, v.id_operador, '2026-11-23 10:00', 'manual'
FROM drone d, vuelo v
WHERE v.id_vuelo = :vuelo AND d.id_nest_base <> (SELECT id_nest_origen FROM ruta_vuelo WHERE id_ruta = :ruta)
LIMIT 1;
ROLLBACK TO s;

\echo '--- (iii) R11: vuelo después del vencimiento de la licencia del operador'
SAVEPOINT s;
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
SELECT id_drone, id_bateria, id_ruta, id_operador, '2030-01-01 10:00', 'manual' FROM vuelo WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

\echo '--- (iii) R11: operador sin autorización para ese modelo y distrito'
SAVEPOINT s;
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn;
DELETE FROM autorizacion a USING vuelo v, drone d, ruta_vuelo r
WHERE v.id_vuelo = :vuelo AND d.id_drone = v.id_drone AND r.id_ruta = v.id_ruta
  AND a.id_operador = v.id_operador AND a.id_modelo = d.id_modelo AND a.ubigeo = r.ubigeo_destino;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
SELECT id_drone, id_bateria, id_ruta, id_operador, '2026-11-23 10:00', 'manual' FROM vuelo WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

\echo '--- (iv) R9: vuelo a distrito restringido sin permiso'
SAVEPOINT s;
SELECT r.id_ruta AS ruta_r FROM ruta_vuelo r JOIN distrito d ON d.ubigeo = r.ubigeo_destino
WHERE d.zona_restringida ORDER BY r.id_ruta LIMIT 1 \gset
SELECT v.id_drone AS drn_r, v.id_operador AS op_r FROM vuelo v WHERE v.id_ruta = :ruta_r LIMIT 1 \gset
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn_r;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, id_permiso, fecha_programada, tipo_operacion)
VALUES (:drn_r, :bat, :ruta_r, :op_r, NULL, '2026-11-23 12:00', 'manual');
ROLLBACK TO s;

\echo '--- (iv) R9: con permiso de OTRO distrito'
SAVEPOINT s;
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn_r;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, id_permiso, fecha_programada, tipo_operacion)
SELECT :drn_r, :bat, :ruta_r, :op_r, p.id_permiso, '2026-11-23 12:00', 'manual'
FROM permiso_vuelo p
WHERE p.ubigeo <> (SELECT ubigeo_destino FROM ruta_vuelo WHERE id_ruta = :ruta_r)
  AND '2026-11-23' BETWEEN p.fecha_emision AND p.fecha_vencimiento LIMIT 1;
ROLLBACK TO s;

\echo '--- R12 (automático): bajar la salud a 65 % pasa la batería a "degradada"'
SAVEPOINT s;
UPDATE bateria SET salud_pct = 65 WHERE id_bateria = :bat;
SELECT id_bateria, salud_pct, estado FROM bateria WHERE id_bateria = :bat;
\echo '--- R12: y ya no se puede usar en un vuelo nuevo'
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
SELECT id_drone, id_bateria, id_ruta, id_operador, '2026-11-23 15:00', 'manual' FROM vuelo WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

\echo '--- R10: drone que no está disponible (en mantenimiento)'
SAVEPOINT s;
UPDATE drone SET estado = 'mantenimiento' WHERE id_drone = :drn;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, tipo_operacion)
SELECT id_drone, id_bateria, id_ruta, id_operador, '2026-11-23 16:00', 'manual' FROM vuelo WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

\echo '--- Transición inválida: un vuelo completado no vuelve a "en_curso"'
SAVEPOINT s;
UPDATE vuelo SET estado = 'en_curso' WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

\echo '--- (viii) R17: lectura de telemetría después del aterrizaje'
SAVEPOINT s;
CALL sp_registrar_lectura(:vuelo, 43.0, 20.0, 30.0, 80.0, '2026-11-20 11:00');
ROLLBACK TO s;

\echo '--- (ix) R2: agregar un drone a un nest que ya está lleno'
SAVEPOINT s;
UPDATE estacion_nest SET capacidad_drones = 10 WHERE codigo = 'NST-BAR-01';
INSERT INTO drone (numero_serie, registro_dgac, fecha_adquisicion, id_modelo, id_nest_base)
SELECT 'PRUEBA-0001', 'RPAS-PE-99999', '2026-11-01', 1, id_nest FROM estacion_nest WHERE codigo = 'NST-BAR-01';
ROLLBACK TO s;

\echo '--- (ix) R2: bajar la capacidad de un nest por debajo de sus drones'
SAVEPOINT s;
UPDATE estacion_nest SET capacidad_drones = 3 WHERE codigo = 'NST-BAR-01';
ROLLBACK TO s;

\echo '--- (x) R6: ruta con un solo punto (se revisa al cerrar la transacción)'
SAVEPOINT s;
INSERT INTO ruta_vuelo (codigo, id_nest_origen, ubigeo_destino, distancia_km, altitud_crucero_m, duracion_est_min)
VALUES ('R-PRUEBA-01', 1, '150122', 3.0, 90, 5);
INSERT INTO punto_ruta VALUES (currval('ruta_vuelo_id_ruta_seq'), 1, -12.12, -77.03, 0, 'despegue');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK TO s;

\echo '--- R6: punto de ruta más alto que la altitud máxima del distrito destino'
SAVEPOINT s;
UPDATE punto_ruta SET altitud_m = 200 WHERE id_ruta = :ruta AND nro_secuencia = 2;
ROLLBACK TO s;

\echo '--- (vii) R12: misma batería en dos vuelos que se solapan (EXCLUDE)'
SAVEPOINT s;
UPDATE drone SET estado = 'disponible' WHERE id_drone = :drn;
INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, fecha_programada, despegue, aterrizaje, estado, tipo_operacion)
SELECT id_drone, id_bateria, id_ruta, id_operador, '2026-11-20 10:05', '2026-11-20 10:06', '2026-11-20 10:20',
       'completado', 'manual' FROM vuelo WHERE id_vuelo = :vuelo;
ROLLBACK TO s;

ROLLBACK;
\echo ''
\echo '=== Fin: transacción deshecha, la base queda como estaba ==='
