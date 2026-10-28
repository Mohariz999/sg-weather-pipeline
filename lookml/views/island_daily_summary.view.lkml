view: island_daily_summary {
  sql_table_name: `gold.island_daily_summary` ;;

  dimension_group: obs {
    type: time
    timeframes: [date, week, month, year]
    datatype: date
    convert_tz: no
    sql: ${TABLE}.obs_date ;;
  }

  dimension: obs_date_pk {
    primary_key: yes
    hidden: yes
    sql: ${TABLE}.obs_date ;;
  }

  dimension: wettest_station {
    type: string
    sql: ${TABLE}.wettest_station ;;
  }

  dimension: hottest_station {
    type: string
    sql: ${TABLE}.hottest_station ;;
  }

  measure: island_avg_temp_c {
    label: "Island Average Temperature (°C)"
    type: average
    sql: ${TABLE}.island_avg_temp_c ;;
    value_format_name: decimal_1
  }

  measure: island_max_temp_c {
    label: "Island Max Temperature (°C)"
    type: max
    sql: ${TABLE}.island_max_temp_c ;;
    value_format_name: decimal_1
  }

  measure: heavy_rain_station_days {
    type: sum
    sql: ${TABLE}.heavy_rain_stations ;;
  }

  measure: avg_stations_reporting {
    type: average
    sql: ${TABLE}.stations_reporting ;;
    value_format_name: decimal_0
  }
}
