// Tables created by Terraform and loaded by ingestion. Declaring them lets models
// ref() them, which gives Dataform the full lineage graph.
["weather_readings_raw", "legacy_observations", "legacy_stations"].forEach((name) =>
  declare({ schema: "bronze", name }),
);

declare({ schema: "ops", name: "legacy_manifest_ext" });
