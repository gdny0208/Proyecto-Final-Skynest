-- =====================================================================
-- SkyNest · Video 3 de 5 · Consulta 3: Baterías que pasaron 60 °C en octubre
-- Base: skynest_1m (1 000 000 de vuelos), en pgAdmin → Query Tool.
--
-- Cómo usarlo: ejecutar UN BLOQUE A LA VEZ, en orden. Para ejecutar un bloque,
-- seleccionarlo con el mouse (desde su comentario hasta el último ;) y pulsar F5.
-- Los comentarios dicen qué mirar en cada resultado: se leen en pantalla, así el
-- video se entiende sin voz. Al terminar, la base queda igual que al principio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Preparación: tablas del esquema skynest y sin índices del experimento
-- ---------------------------------------------------------------------
SET search_path = skynest, reportes, public;
DO $$
DECLARE ix text;
BEGIN
    FOR ix IN SELECT indexname FROM pg_indexes WHERE schemaname = 'skynest' AND indexname LIKE 'ix\_c%' LOOP
        EXECUTE format('DROP INDEX skynest.%I', ix);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 1. La pregunta: ¿Qué baterías superaron 60 °C en octubre de 2026 y en qué drones se usaron?
--    Tablas que usa y cuántas filas tienen
-- ---------------------------------------------------------------------
SELECT 'telemetria_bateria' AS tabla, count(*) AS filas FROM telemetria_bateria;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: solo los índices de las llaves (PRIMARY KEY y UNIQUE)
-- ---------------------------------------------------------------------
SELECT tablename AS tabla, indexname AS indice
FROM pg_indexes
WHERE schemaname = 'skynest' AND tablename IN ('telemetria_bateria')
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. SIN ÍNDICE. Mirar: "Parallel Seq Scan on telemetria_bateria" y "Rows Removed by Filter: ~1 600 000" (por cada proceso):
--    recorre las 4,85 millones de lecturas. En la última fila, "Execution Time" (en el informe: unos 127 ms).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.id_bateria,
       b.numero_serie,
       b.salud_pct,
       b.estado,
       count(*)                                    AS lecturas_sobre_60,
       max(t.temperatura_c)                        AS temp_max_c,
       count(DISTINCT v.id_vuelo)                  AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC;

-- ---------------------------------------------------------------------
-- 4. CREAR EL ÍNDICE: índice PARCIAL (solo lecturas sobre 60 °C).
--    Después se actualizan las estadísticas (ANALYZE) y se muestra cuánto ocupa
-- ---------------------------------------------------------------------
CREATE INDEX ix_c3b_telemetria_alertas ON telemetria_bateria (marca_tiempo) WHERE temperatura_c > 60;
ANALYZE telemetria_bateria;
SELECT indexname AS indice, pg_size_pretty(pg_relation_size(('skynest.' || indexname)::regclass)) AS tamano
FROM pg_indexes
WHERE schemaname = 'skynest' AND indexname IN ('ix_c3b_telemetria_alertas');

-- ---------------------------------------------------------------------
-- 5. CON ÍNDICE. Es la MISMA consulta. Mirar: "Bitmap Index Scan on ix_c3b_telemetria_alertas" con rows=787: solo lee las lecturas que cumplen.
--    "Execution Time" mucho menor (en el informe: unos 3 ms, 44 veces más rápido).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT b.id_bateria,
       b.numero_serie,
       b.salud_pct,
       b.estado,
       count(*)                                    AS lecturas_sobre_60,
       max(t.temperatura_c)                        AS temp_max_c,
       count(DISTINCT v.id_vuelo)                  AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC;

-- ---------------------------------------------------------------------
-- 6. El índice no cambia la respuesta, solo el tiempo: mismas filas con o sin índice (debe dar 466 baterías)
-- ---------------------------------------------------------------------
SELECT count(*) AS filas_del_resultado FROM (
SELECT b.id_bateria,
       b.numero_serie,
       b.salud_pct,
       b.estado,
       count(*)                                    AS lecturas_sobre_60,
       max(t.temperatura_c)                        AS temp_max_c,
       count(DISTINCT v.id_vuelo)                  AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC
) AS r;

-- ---------------------------------------------------------------------
-- 7. Dejar la base como estaba: borrar el índice del video
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_c3b_telemetria_alertas;
ANALYZE telemetria_bateria;
