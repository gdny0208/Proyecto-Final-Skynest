-- =====================================================================
-- SkyNest · 06_roles_prueba.sql
-- Prueba de permisos: cada rol puede hacer lo suyo y no lo demás.
-- Se ejecuta con un superusuario; SET ROLE simula a cada usuario.
-- Todo se deshace al final.
--
-- Uso:  psql -d skynest_1k -f sql/06_roles_prueba.sql
-- =====================================================================

\set ON_ERROR_STOP off
SET search_path = skynest, reportes, public;
\set VERBOSITY terse
\pset footer off
BEGIN;
SELECT codigo_tracking AS trk FROM paquete WHERE estado = 'entregado' LIMIT 1 \gset
SELECT id_vuelo AS vprog FROM vuelo WHERE estado = 'programado' LIMIT 1 \gset

\echo '--- rol_analista: SÍ lee las vistas de reportes'
SAVEPOINT s; SET LOCAL ROLE rol_analista;
SELECT count(*) AS filas_v_entregas FROM v_entregas_nest_distrito;
ROLLBACK TO s;
\echo '--- rol_analista: NO entra al esquema skynest (tablas del núcleo)'
SAVEPOINT s; SET LOCAL ROLE rol_analista;
SELECT count(*) FROM skynest.paquete;
ROLLBACK TO s;

\echo '--- rol_cliente: SÍ rastrea un paquete por su código'
SAVEPOINT s; SET LOCAL ROLE rol_cliente;
SELECT codigo_tracking, estado_paquete, distrito_destino FROM fn_rastrear_paquete(:'trk');
ROLLBACK TO s;
\echo '--- rol_cliente: NO puede listar todos los paquetes'
SAVEPOINT s; SET LOCAL ROLE rol_cliente;
SELECT count(*) FROM v_seguimiento_paquete;
ROLLBACK TO s;

\echo '--- rol_operador: SÍ despega un vuelo programado con el procedimiento'
SAVEPOINT s; SET LOCAL ROLE rol_operador;
CALL sp_despegar_vuelo(:vprog);
RESET ROLE;
SELECT id_vuelo, estado FROM vuelo WHERE id_vuelo = :vprog;
ROLLBACK TO s;
\echo '--- rol_operador: NO puede modificar el vuelo directamente'
SAVEPOINT s; SET LOCAL ROLE rol_operador;
UPDATE vuelo SET estado = 'cancelado' WHERE id_vuelo = :vprog;
ROLLBACK TO s;

\echo '--- rol_tecnico: SÍ actualiza la salud de una batería'
SAVEPOINT s; SET LOCAL ROLE rol_tecnico;
UPDATE bateria SET salud_pct = 85 WHERE id_bateria = 1;
ROLLBACK TO s;
\echo '--- rol_tecnico: NO puede cambiar la química de la batería'
SAVEPOINT s; SET LOCAL ROLE rol_tecnico;
UPDATE bateria SET quimica = 'LiPo' WHERE id_bateria = 1;
ROLLBACK TO s;

\echo '--- rol_telemetria: SÍ inserta una lectura (dentro de un vuelo)'
SAVEPOINT s;
SELECT id_vuelo AS vt, despegue + interval '1 second' AS ht FROM vuelo WHERE estado = 'completado' LIMIT 1 \gset
SET LOCAL ROLE rol_telemetria;
INSERT INTO telemetria_bateria VALUES (:vt, :'ht', 44.0, 20.0, 30.0, 90.0);
ROLLBACK TO s;
\echo '--- rol_telemetria: NO puede borrar lecturas'
SAVEPOINT s; SET LOCAL ROLE rol_telemetria;
DELETE FROM telemetria_bateria WHERE id_vuelo = 1;
ROLLBACK TO s;

\echo '--- rol_despachador: NO puede borrar vuelos'
SAVEPOINT s; SET LOCAL ROLE rol_despachador;
DELETE FROM vuelo WHERE id_vuelo = :vprog;
ROLLBACK TO s;

ROLLBACK;
\echo '=== Fin: transacción deshecha ==='
