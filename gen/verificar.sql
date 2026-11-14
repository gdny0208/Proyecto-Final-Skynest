-- =====================================================================
-- SkyNest · gen/verificar.sql
-- Verifica que los datos generados cumplen las reglas que cruzan tablas.
-- Como generar.py carga con las FK desactivadas, también revisa huérfanos.
-- Cada fila debe mostrar violaciones = 0.
--
-- Uso:  psql -d skynest_1k -f gen/verificar.sql
-- =====================================================================

SELECT regla, violaciones, CASE WHEN violaciones = 0 THEN 'OK' ELSE 'REVISAR' END AS estado
FROM (
  -- Integridad referencial (huérfanos)
  SELECT 'FK vuelo -> drone/bateria/ruta/operador' AS regla, count(*) AS violaciones
  FROM vuelo v
  WHERE NOT EXISTS (SELECT 1 FROM drone d WHERE d.id_drone = v.id_drone)
     OR NOT EXISTS (SELECT 1 FROM bateria b WHERE b.id_bateria = v.id_bateria)
     OR NOT EXISTS (SELECT 1 FROM ruta_vuelo r WHERE r.id_ruta = v.id_ruta)
     OR NOT EXISTS (SELECT 1 FROM operador o WHERE o.id_operador = v.id_operador)
  UNION ALL
  SELECT 'FK paquete -> cliente/vuelo', count(*)
  FROM paquete p
  WHERE NOT EXISTS (SELECT 1 FROM cliente c WHERE c.id_cliente = p.id_cliente)
     OR (p.id_vuelo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vuelo v WHERE v.id_vuelo = p.id_vuelo))
  UNION ALL
  SELECT 'FK telemetria -> vuelo', count(*)
  FROM telemetria_bateria t WHERE NOT EXISTS (SELECT 1 FROM vuelo v WHERE v.id_vuelo = t.id_vuelo)
  UNION ALL
  SELECT 'FK autorizacion -> operador/modelo/distrito', count(*)
  FROM autorizacion a
  WHERE NOT EXISTS (SELECT 1 FROM operador o WHERE o.id_operador = a.id_operador)
     OR NOT EXISTS (SELECT 1 FROM modelo_drone m WHERE m.id_modelo = a.id_modelo)
     OR NOT EXISTS (SELECT 1 FROM distrito d WHERE d.ubigeo = a.ubigeo)

  -- (i) R16: todo cliente es persona o empresa, nunca ambas ni ninguna
  UNION ALL
  SELECT '(i) R16 cobertura y no solapamiento de clientes', count(*)
  FROM cliente c
  WHERE (EXISTS (SELECT 1 FROM cliente_persona p WHERE p.id_cliente = c.id_cliente))::int
      + (EXISTS (SELECT 1 FROM cliente_empresa e WHERE e.id_cliente = c.id_cliente))::int <> 1

  -- (ii) R15: peso total por vuelo <= carga útil del modelo
  UNION ALL
  SELECT '(ii) R15 peso por vuelo <= carga util', count(*)
  FROM (SELECT p.id_vuelo, sum(p.peso_kg) AS peso
        FROM paquete p WHERE p.id_vuelo IS NOT NULL GROUP BY p.id_vuelo) x
  JOIN vuelo v USING (id_vuelo)
  JOIN drone d USING (id_drone)
  JOIN modelo_drone m USING (id_modelo)
  WHERE x.peso > m.carga_util_max_kg

  -- (iii) R11: licencia y autorización vigentes en la fecha del vuelo
  UNION ALL
  SELECT '(iii) R11 licencia vigente', count(*)
  FROM vuelo v JOIN operador o USING (id_operador)
  WHERE o.venc_licencia < v.fecha_programada::date
  UNION ALL
  SELECT '(iii) R11 autorizacion vigente (operador, modelo, distrito)', count(*)
  FROM vuelo v
  JOIN drone d USING (id_drone)
  JOIN ruta_vuelo r USING (id_ruta)
  WHERE NOT EXISTS (
    SELECT 1 FROM autorizacion a
    WHERE a.id_operador = v.id_operador AND a.id_modelo = d.id_modelo AND a.ubigeo = r.ubigeo_destino
      AND v.fecha_programada::date BETWEEN a.fecha_emision AND a.fecha_vencimiento)

  -- (iv) R9: permiso vigente del mismo distrito si el destino es restringido
  UNION ALL
  SELECT '(iv) R9 permiso para distrito restringido', count(*)
  FROM vuelo v
  JOIN ruta_vuelo r USING (id_ruta)
  JOIN distrito di ON di.ubigeo = r.ubigeo_destino
  LEFT JOIN permiso_vuelo pv ON pv.id_permiso = v.id_permiso
  WHERE (di.zona_restringida AND (pv.id_permiso IS NULL OR pv.ubigeo <> r.ubigeo_destino
         OR v.fecha_programada::date NOT BETWEEN pv.fecha_emision AND pv.fecha_vencimiento))
     OR (NOT di.zona_restringida AND v.id_permiso IS NOT NULL)

  -- (v) R14: distrito del paquete = distrito destino de la ruta del vuelo
  UNION ALL
  SELECT '(v) R14 distrito paquete = destino ruta', count(*)
  FROM paquete p JOIN vuelo v USING (id_vuelo) JOIN ruta_vuelo r USING (id_ruta)
  WHERE p.ubigeo_destino <> r.ubigeo_destino

  -- (vi) R10: nest base del drone = nest de origen de la ruta
  UNION ALL
  SELECT '(vi) R10 nest del drone = origen de la ruta', count(*)
  FROM vuelo v JOIN drone d USING (id_drone) JOIN ruta_vuelo r USING (id_ruta)
  WHERE d.id_nest_base <> r.id_nest_origen

  -- (vii) R12: batería sin vuelos solapados (también lo garantiza el EXCLUDE)
  UNION ALL
  SELECT '(vii) R12 bateria sin vuelos solapados', count(*)
  FROM vuelo a JOIN vuelo b
    ON a.id_bateria = b.id_bateria AND a.id_vuelo < b.id_vuelo
   AND a.despegue < b.aterrizaje AND b.despegue < a.aterrizaje

  -- R12: vuelos programados (futuros) solo con baterías operativas y drones disponibles
  UNION ALL
  SELECT 'R12/R10 vuelos programados con bateria operativa y drone disponible', count(*)
  FROM vuelo v JOIN bateria b USING (id_bateria) JOIN drone d USING (id_drone)
  WHERE v.estado = 'programado' AND (b.estado <> 'operativa' OR d.estado <> 'disponible')

  -- (viii) R17: lecturas dentro del intervalo del vuelo
  UNION ALL
  SELECT '(viii) R17 telemetria dentro del vuelo', count(*)
  FROM telemetria_bateria t JOIN vuelo v USING (id_vuelo)
  WHERE v.despegue IS NULL OR t.marca_tiempo NOT BETWEEN v.despegue AND v.aterrizaje

  -- (ix) R2: drones por nest <= capacidad
  UNION ALL
  SELECT '(ix) R2 capacidad del nest', count(*)
  FROM estacion_nest n
  WHERE (SELECT count(*) FROM drone d WHERE d.id_nest_base = n.id_nest) > n.capacidad_drones

  -- (x) R6: al menos 2 puntos por ruta y altitud <= altitud máxima del distrito destino
  UNION ALL
  SELECT '(x) R6 rutas con al menos 2 puntos', count(*)
  FROM ruta_vuelo r WHERE (SELECT count(*) FROM punto_ruta p WHERE p.id_ruta = r.id_ruta) < 2
  UNION ALL
  SELECT 'R6 altitud de puntos <= altitud maxima', count(*)
  FROM punto_ruta p JOIN ruta_vuelo r USING (id_ruta) JOIN distrito d ON d.ubigeo = r.ubigeo_destino
  WHERE p.altitud_m > d.altitud_max_m

  -- Fechas coherentes del paquete con su vuelo
  UNION ALL
  SELECT 'Paquete entregado durante su vuelo', count(*)
  FROM paquete p JOIN vuelo v USING (id_vuelo)
  WHERE p.estado = 'entregado' AND p.fecha_entrega NOT BETWEEN v.despegue AND v.aterrizaje
) chequeos;

-- Resumen de volumen y datos faltantes simulados (sección 4.3)
SELECT
  (SELECT count(*) FROM vuelo)                                        AS vuelos,
  (SELECT count(*) FROM paquete)                                      AS paquetes,
  round((SELECT count(*) FROM paquete)::numeric / (SELECT count(*) FROM vuelo), 2) AS paq_por_vuelo,
  (SELECT count(*) FROM telemetria_bateria)                           AS lecturas,
  (SELECT count(*) FROM paquete WHERE lat_destino IS NULL)            AS paquetes_sin_coord,
  (SELECT count(*) FROM (SELECT id_vuelo FROM telemetria_bateria GROUP BY id_vuelo HAVING count(*) = 4) x)
                                                                      AS vuelos_con_lectura_perdida;
