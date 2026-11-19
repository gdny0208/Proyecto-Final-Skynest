# Guiones de audio · Videos del anexo (SkyNest, base de 1 millón)

**Cómo grabar.** Lee cada guion de corrido, con calma y en tono natural, **sin mirar el video**. Donde aparece
**⏸**, haz una **pausa de 2 segundos** (cuenta mentalmente "uno, dos"). Graba un archivo por video:
`audio_C1.m4a` … `audio_C5.m4a`, con Notas de Voz o QuickTime (*Archivo → Nueva grabación de audio*).

**Después.** Con esas pausas corto el audio en párrafos y pongo cada uno en el momento del video donde
ocurre lo que describe. Si un párrafo queda más largo que su parte del video, alargo un poco esa imagen; no
hace falta que lo cronometres. Si te equivocas, repite la frase completa después de una pausa: la versión
buena la elijo yo al editar.

Los tiempos que se mencionan son los que aparecen en cada video. El informe usa la media de 5 corridas, por
eso no son idénticos; lo importante es el cambio de plan y que el tiempo baja.

---

## Video 1 · Consulta 1 — Tasa de entregas por nest y distrito

En este video mostramos la consulta uno de SkyNest, nuestra base de datos de entregas con drones, trabajando
sobre la base de un millón de vuelos. La consulta responde una pregunta del área de operaciones: qué
porcentaje de los paquetes se entregó y cuánto demoró la entrega, según el nest de salida y el distrito de
destino. Para mostrarlo abrimos pgAdmin, nos conectamos a skynest_1m y cargamos el script demo_c1.sql, que
vamos a ejecutar bloque por bloque.

⏸

Primero preparamos la sesión y comprobamos el punto de partida: tenemos un millón de vuelos, un millón y
medio de paquetes, y solo los índices de las llaves primarias.

⏸

Sin índices, PostgreSQL no tiene otra opción que leer las dos tablas completas. Por eso el plan muestra un
Parallel Seq Scan sobre paquete y sobre vuelo, y la consulta tarda unos 330 milisegundos.

⏸

Ahora creamos dos índices cubrientes, que guardan dentro del propio índice las columnas que la consulta
necesita.

⏸

Al repetir exactamente la misma consulta, el plan cambia a un Index Only Scan: responde desde el índice sin
tocar la tabla de paquetes. El tiempo baja a 131 milisegundos, dos veces y media más rápido.

⏸

El resultado sigue siendo el mismo, 342 filas, porque un índice cambia el camino para llegar a los datos,
no la respuesta. Para terminar, borramos los índices y la base queda tal como estaba.

---

## Video 2 · Consulta 2 — Consumo de batería por kilómetro

En este video mostramos la consulta dos de SkyNest sobre la base de un millón de vuelos. Esta consulta
ayuda a planificar el mantenimiento: calcula cuántos puntos de batería gasta cada modelo de drone por
kilómetro recorrido, en cada ruta. Abrimos pgAdmin, nos conectamos a skynest_1m y cargamos el script
demo_c2.sql para ejecutarlo bloque por bloque.

⏸

Analizamos los vuelos del primer trimestre de 2026 que salen del nest NST-MIR-01. La tabla de vuelos tiene
un millón de filas y la de telemetría casi cinco millones, y partimos solo con las llaves primarias.

⏸

Sin índice, el plan recorre el millón de vuelos con un Parallel Seq Scan y descarta casi todos, como muestra
la línea Rows Removed by Filter. Así, la consulta tarda unos 109 milisegundos.

⏸

Creamos un índice compuesto sobre la ruta y la fecha de despegue.

⏸

Con este índice, el plan usa un Index Scan que va directo a los vuelos de cada ruta en ese trimestre, y el
tiempo baja a 62 milisegundos, casi el doble de rápido.

⏸

La respuesta no cambia: son las mismas 69 filas con o sin índice. Al final borramos el índice para dejar la
base como al inicio.

---

## Video 3 · Consulta 3 — Baterías que superaron los 60 °C

En este video mostramos la consulta tres de SkyNest sobre la base de un millón de vuelos, que es la que más
mejora con un índice. La consulta sirve para la seguridad de la flota: identifica las baterías que superaron
los 60 grados en octubre de 2026 y en qué drones se usaron. Abrimos pgAdmin, nos conectamos a skynest_1m y
cargamos el script demo_c3.sql.

⏸

Preparamos la sesión y revisamos el punto de partida: la tabla de telemetría tiene casi cinco millones de
lecturas y solo cuenta con su llave primaria.

⏸

Sin índice, el plan hace un Parallel Seq Scan sobre toda la telemetría y descarta más de un millón y medio
de filas en cada proceso, porque casi ninguna lectura pasa los 60 grados. La consulta tarda unos 300
milisegundos.

⏸

Creamos un índice parcial, que solo guarda las lecturas sobre 60 grados. Por eso ocupa apenas 424
kilobytes.

⏸

Con este índice, el plan usa un Bitmap Index Scan y lee solo unas 800 lecturas en vez de cinco millones. El
tiempo baja a 9 milisegundos: más de treinta veces más rápido.

⏸

El resultado es idéntico, 466 baterías, así que el índice solo cambió el tiempo. Elegir un índice parcial
fue clave, porque es pequeño y muy selectivo. Para terminar, lo borramos y la base queda como estaba.

---

## Video 4 · Consulta 4 — Uso de la flota

En este video mostramos la consulta cuatro de SkyNest sobre la base de un millón de vuelos. Esta consulta
mide el uso de la flota: cuántos vuelos y horas hizo cada drone en septiembre de 2026 y cuánto se aleja del
promedio de su modelo, para detectar drones sobreexigidos o poco usados. Abrimos pgAdmin, nos conectamos a
skynest_1m y cargamos el script demo_c4.sql.

⏸

Preparamos la sesión y revisamos el punto de partida: la tabla de vuelos tiene un millón de filas y solo los
índices de sus llaves.

⏸

Sin índice, el plan recorre el millón de vuelos con un Parallel Seq Scan para quedarse solo con los de
septiembre, y tarda unos 94 milisegundos.

⏸

Creamos un índice B+ sobre la fecha de despegue.

⏸

Ahora el plan usa un Bitmap Index Scan que va directo a los vuelos de septiembre, y el tiempo baja a 41
milisegundos, más del doble de rápido.

⏸

La respuesta es la misma: 300 drones. En el experimento también probamos un índice BRIN sobre la fecha, pero
no ayudó, porque los vuelos no están guardados en orden cronológico. Finalmente, borramos el índice.

---

## Video 5 · Consulta 5 — Paquetes express con retraso

En este último video mostramos la consulta cinco de SkyNest sobre la base de un millón de vuelos. La
consulta controla la calidad del servicio express: en agosto de 2026, cuenta por distrito cuántos paquetes
express entregados llegaron después del tiempo estimado de su ruta. Abrimos pgAdmin, nos conectamos a
skynest_1m y cargamos el script demo_c5.sql.

⏸

Preparamos la sesión y revisamos el punto de partida: un millón de vuelos, un millón y medio de paquetes, y
solo los índices de las llaves.

⏸

Sin índice, el plan lee completas las tablas de paquetes y de vuelos con Parallel Seq Scan, y la consulta
tarda alrededor de un segundo.

⏸

Creamos un índice compuesto y cubriente sobre la prioridad, el estado y la fecha de entrega, que además
guarda el vuelo y el distrito de destino.

⏸

Con este índice, los paquetes express se leen con un Index Only Scan, aunque la tabla de vuelos todavía se
recorre completa. Aun así, el tiempo baja a 125 milisegundos.

⏸

Para mejorar lo que falta, ajustamos random_page_cost a 1.1, el valor recomendado para discos SSD. Con ese
cambio, el planificador busca cada vuelo por su llave primaria con un Index Scan, y el tiempo baja a 103
milisegundos: unas diez veces más rápido que al inicio. Luego devolvemos el parámetro a su valor por
defecto.

⏸

El resultado sigue siendo el mismo, 34 distritos. Borramos el índice y la base queda como estaba. Con estas
cinco consultas comprobamos que, con un millón de registros, elegir el índice adecuado para cada consulta
reduce el tiempo entre dos y treinta veces.
