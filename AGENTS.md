# forge-studio-releases — contrato de agentes

## Operación segura y emergencias (Codex y Claude)
1. Antes de cambiar producción: verificar repo/HEAD, ambiente, dominio real, despliegue activo, API y rollback. Commit, build, READY, alias y HTTP son estados DIFERENTES.
2. Si piden mantenimiento urgente, preferir un standby estático ya desplegado y comprobado: conmutar el alias/ruteo, no reconstruir la app ni reemplazar index.html. Si no existe, preparar una publicación mínima aislada y validarla ANTES del cambio de alias.
3. Verificar por HTTP el DOMINIO REAL (/, login, ruta interna y ruta de cliente). Un cartel web no bloquea APIs, escrituras, sesiones ya abiertas ni PWA/service workers; verificar esas superficies o declarar el límite.
4. Registrar el despliegue previo, ejecutar cambios mínimos reversibles, controlar los SHAs y despliegues concurrentes. Nunca sobrescribir archivos con versiones antiguas ni desactivar auto-deploy por accidente.
5. No afirmar «listo», «para todos», «en producción» sin la prueba correspondiente. Estados explícitos: código, build, READY, alias, HTTP, API y caché.
6. No publicar, fusionar, tocar secretos, BD, pagos o entorno productivo sin instrucción explícita. En una emergencia autorizada ejecutar la operación mínima, comprobarla y preparar reversión.
7. Estas instrucciones no son un mecanismo técnico: crear smoke tests y standby por cada aplicación publicable, sin inventar APIs ni compatibilidad del hosting.
