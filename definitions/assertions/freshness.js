// Only compiled into the run when check_freshness is "true", so the migration can run
// before the stream has any data.
if (dataform.projectConfig.vars.check_freshness === "true") {
  assert("assert_stream_fresh")
    .description("Fails if no real-time reading has arrived in the last 60 minutes.")
    .query((ctx) => `
      SELECT MAX(reading_ts) AS latest_reading
      FROM ${ctx.ref("readings_clean")}
      HAVING latest_reading IS NULL
          OR latest_reading < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 MINUTE)
    `);
}
