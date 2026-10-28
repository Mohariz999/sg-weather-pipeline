view: daily_station_weather {
  sql_table_name: `gold.daily_station_weather` ;;

  dimension: pk {
    primary_key: yes
    hidden: yes
    sql: CONCAT(CAST(${TABLE}.obs_date AS STRING), '|', ${TABLE}.station_id) ;;
  }

  dimension_group: obs {
    type: time
    timeframes: [date, week, month, quarter, year, day_of_week]
    datatype: date
    convert_tz: no
    sql: ${TABLE}.obs_date ;;
  }

  dimension: station_id {
    type: string
    sql: ${TABLE}.station_id ;;
  }

  dimension: station_name {
    type: string
    sql: ${TABLE}.station_name ;;
  }

  dimension: total_rain_mm {
    type: number
    sql: ${TABLE}.total_rain_mm ;;
    value_format_name: decimal_1
  }

  dimension: is_rainy_day {
    type: yesno
    sql: ${TABLE}.total_rain_mm > 0.2 ;;
    description: "More than 0.2 mm of rain, the usual threshold for a rain day."
  }

  dimension: data_source {
    type: string
    sql: ${TABLE}.sources ;;
  }

  measure: avg_temp_c {
    label: "Average Temperature (°C)"
    type: average
    sql: ${TABLE}.avg_temp_c ;;
    value_format_name: decimal_1
  }

  measure: max_temp_c {
    label: "Max Temperature (°C)"
    type: max
    sql: ${TABLE}.max_temp_c ;;
    value_format_name: decimal_1
  }

  measure: min_temp_c {
    label: "Min Temperature (°C)"
    type: min
    sql: ${TABLE}.min_temp_c ;;
    value_format_name: decimal_1
  }

  measure: avg_daily_rain_mm {
    label: "Average Daily Rainfall (mm)"
    type: average
    sql: ${TABLE}.total_rain_mm ;;
    value_format_name: decimal_1
  }

  measure: rainy_station_days {
    type: count
    filters: [is_rainy_day: "yes"]
  }

  measure: station_days {
    type: count
  }

  measure: rain_day_share {
    label: "Share of Rainy Station-Days"
    type: number
    sql: SAFE_DIVIDE(${rainy_station_days}, ${station_days}) ;;
    value_format_name: percent_1
  }

  measure: avg_humidity_pct {
    type: average
    sql: ${TABLE}.avg_humidity_pct ;;
    value_format_name: decimal_0
  }

  measure: max_wind_kmh {
    type: max
    sql: ${TABLE}.max_wind_kmh ;;
    value_format_name: decimal_1
  }
}
