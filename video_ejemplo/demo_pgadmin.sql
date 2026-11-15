-- =====================================================================
-- SkyNest · Demostración en pgAdmin para el video (base skynest_1m)
-- Abrir con: pgAdmin → skynest_1m → Query Tool → abrir este archivo.
-- Ejecutar cada bloque por separado: seleccionarlo y pulsar F5.
-- Al terminar, la base queda igual que al principio (el índice se borra).
-- =====================================================================

-- 1. La base existe y tiene 1 millón de vuelos
SELECT current_database()                         AS base,
       (SELECT count(*) FROM vuelo)               AS vuelos,
       (SELECT count(*) FROM paquete)             AS paquetes,
       (SELECT count(*) FROM telemetria_bateria)  AS lecturas_telemetria,
       pg_size_pretty(pg_database_size(current_database())) AS tamano;

-- 2. Las 16 tablas y cuántas filas tiene cada una
SELECT relname AS tabla, n_live_tup AS filas_aprox
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- 3. Partimos sin índices del experimento (solo PK, UNIQUE y EXCLUDE)
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public' AND tablename = 'telemetria_bateria';

-- 4. C3 SIN índices: mirar "Parallel Seq Scan" y "Execution Time" al final
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.id_bateria, b.numero_serie, b.salud_pct, b.estado,
       count(*) AS lecturas_sobre_60, max(t.temperatura_c) AS temp_max_c,
       count(DISTINCT v.id_vuelo) AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC;

-- 5. Crear el índice del Plan B (parcial) y actualizar estadísticas
CREATE INDEX ix_c3b_telemetria_alertas ON telemetria_bateria (marca_tiempo) WHERE temperatura_c > 60;
ANALYZE telemetria_bateria;
SELECT pg_size_pretty(pg_relation_size('ix_c3b_telemetria_alertas')) AS tamano_indice;

-- 6. C3 CON el índice: mirar "Bitmap Index Scan on ix_c3b_telemetria_alertas"
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.id_bateria, b.numero_serie, b.salud_pct, b.estado,
       count(*) AS lecturas_sobre_60, max(t.temperatura_c) AS temp_max_c,
       count(DISTINCT v.id_vuelo) AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC;

-- 7. El resultado es el mismo con o sin índice (466 baterías): solo cambia el tiempo
SELECT count(*) AS baterias_con_alerta FROM (
  SELECT v.id_bateria
  FROM telemetria_bateria t JOIN vuelo v ON v.id_vuelo = t.id_vuelo
  WHERE t.temperatura_c > 60
    AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
  GROUP BY v.id_bateria) x;

-- 8. Dejar la base como estaba
DROP INDEX ix_c3b_telemetria_alertas;
