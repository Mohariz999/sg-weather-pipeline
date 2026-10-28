# Semantic model over the gold layer: the single definition of each weather metric.
connection: "sg_weather_bigquery"

include: "/lookml/views/*.view.lkml"

# Gold tables rebuild once a day, so cache until the newest date changes.
datagroup: gold_daily {
  sql_trigger: SELECT MAX(obs_date) FROM gold.island_daily_summary ;;
  max_cache_age: "24 hours"
}

persist_with: gold_daily

explore: daily_station_weather {
  label: "Station Daily Weather"
  description: "Daily weather per station, from the migrated archive and the real-time feed."
}

explore: island_daily_summary {
  label: "Island Daily Summary"
}
