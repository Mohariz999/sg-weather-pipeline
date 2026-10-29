"""Dataproc Serverless (PySpark) job: legacy CSV archive in Cloud Storage -> BigQuery bronze.

Bronze keeps the legacy values as they were (the -999 sentinel included) so it can be
reconciled exactly against the extract manifest. Cleaning happens in the silver layer.
The only changes here are typing, converting Singapore local time to UTC, and lineage
columns. Each run overwrites the bronze tables, so re-running the migration is safe.
"""

import argparse

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql import types as T

OBSERVATION_COLUMNS = ["STN_CODE", "OBS_DATE", "OBS_HOUR", "TEMP_C", "RH_PCT", "RAIN_MM", "WIND_KMH", "WIND_DIR_DEG"]
MEASURE_COLUMNS = ["TEMP_C", "RH_PCT", "RAIN_MM", "WIND_KMH", "WIND_DIR_DEG"]
STATION_COLUMNS = ["STN_CODE", "STN_NAME", "LAT", "LON"]


def all_strings(columns):
    # Read everything as text first: a bad value then becomes a NULL we can count,
    # rather than a failed job.
    return T.StructType([T.StructField(c, T.StringType()) for c in columns])


def transform_observations(raw):
    local_ts = F.to_timestamp(F.concat_ws(" ", "OBS_DATE", F.lpad("OBS_HOUR", 2, "0")), "dd/MM/yyyy HH")
    return raw.select(
        F.col("STN_CODE").alias("stn_code"),
        F.to_date("OBS_DATE", "dd/MM/yyyy").alias("obs_date"),
        F.col("OBS_HOUR").cast("long").alias("obs_hour"),
        *[F.col(c).cast("double").alias(c.lower()) for c in MEASURE_COLUMNS],
        F.to_utc_timestamp(local_ts, "Asia/Singapore").alias("observed_at_utc"),
        F.regexp_extract(F.input_file_name(), r"([^/]+)$", 1).alias("_source_file"),
        F.current_timestamp().alias("_loaded_at"),
    )


def transform_stations(raw):
    return raw.select(
        F.col("STN_CODE").alias("stn_code"),
        F.col("STN_NAME").alias("stn_name"),
        F.col("LAT").cast("double").alias("latitude"),
        F.col("LON").cast("double").alias("longitude"),
        F.current_timestamp().alias("_loaded_at"),
    )


def write_bigquery(df, table, temp_bucket, **options):
    writer = df.write.format("bigquery").option("table", table).option("temporaryGcsBucket", temp_bucket)
    for key, value in options.items():
        writer = writer.option(key, value)
    writer.mode("overwrite").save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--bucket", required=True, help="Landing bucket holding legacy/")
    parser.add_argument("--temp-bucket", required=True)
    args = parser.parse_args()

    spark = SparkSession.builder.appName("legacy-to-bronze").config("spark.sql.session.timeZone", "UTC").getOrCreate()
    base = f"gs://{args.bucket}/legacy"

    observations = transform_observations(
        spark.read.option("header", True).schema(all_strings(OBSERVATION_COLUMNS)).csv(f"{base}/observations/*.csv")
    )
    write_bigquery(
        observations,
        f"{args.project}.bronze.legacy_observations",
        args.temp_bucket,
        partitionField="observed_at_utc",
        partitionType="MONTH",
        clusteredFields="stn_code",
    )

    stations = transform_stations(
        spark.read.option("header", True).schema(all_strings(STATION_COLUMNS)).csv(f"{base}/stations/stations.csv")
    )
    write_bigquery(stations, f"{args.project}.bronze.legacy_stations", args.temp_bucket)

    print(f"loaded {observations.count()} observation rows and {stations.count()} stations")


if __name__ == "__main__":
    main()
