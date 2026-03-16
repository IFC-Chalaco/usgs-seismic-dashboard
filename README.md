# USGS Seismic Dashboard

Map-Driven + Automated USGS Earthquake Feed

Build status: GitHub Actions ready
Data source: USGS Earthquake Catalog
License posture: public-source data, derived exports only

## Overview

This project implements a cloud-automated earthquake data pipeline that continuously pulls public USGS earthquake data, applies data-quality cleanup, and publishes analysis-ready outputs for BI, GIS, and downstream web delivery.

The current pipeline combines:

- official USGS earthquake catalog data retrieved through the FDSN event service
- configurable map-scoped filtering driven by a USGS map URL
- coordinate-based country enrichment using Natural Earth country boundaries
- curated CSV, JSON, GeoJSON, and metadata export generation
- GitHub Actions automation for refresh, monitoring, and repo publishing

All ingestion, transformation, export, and monitoring steps can run in GitHub Actions. No local machine is required for production refreshes after the repository is connected and GitHub Actions is enabled.

## Interactive Dashboard

This repository is currently focused on the automated data pipeline and published export layer.

A public dashboard layer can be added later against the curated outputs, but it is not required for the cloud refresh pipeline to run.

## Architecture

### High-Level Flow

USGS map URL
   -> filter parsing and API translation
   -> USGS FDSN event queries
   -> normalization and data-quality cleanup
   -> curated CSV / JSON / GeoJSON / metadata exports
   -> GitHub Actions scheduled refresh
   -> repository-published outputs for BI, GIS, and app consumers

### Repository Structure

Core files:

- `usgs-earthquake-scraper.ps1`
  Main ingestion and normalization script for the configured USGS map URL.
- `usgs_seismic_stream/publish-usgs-earthquakes.ps1`
  Production-style wrapper that regenerates published exports and pipeline metadata.
- `data/ne_110m_admin_0_countries.geojson`
  Country boundary file used for coordinate-based enrichment.

Automation:

- `.github/workflows/usgs-earthquake-refresh.yml`
  Scheduled and manual refresh workflow.
- `.github/workflows/usgs-earthquake-stale-alert.yml`
  Staleness monitor that opens or closes GitHub issues automatically.
- `.github/dependabot.yml`
  Tracks GitHub Actions dependency updates automatically.

Published outputs:

- `usgs_seismic_stream/exports/earthquakes_live_curated.csv`
  Recommended curated dataset for BI tools, spreadsheets, and apps.
- `usgs_seismic_stream/exports/earthquakes_live_curated.json`
  Curated JSON payload for downstream consumers.
- `usgs_seismic_stream/exports/earthquakes_live.geojson`
  Geospatial-ready earthquake feed.
- `usgs_seismic_stream/exports/pipeline_meta.json`
  Lightweight metadata used for freshness monitoring and sync checks.

## What the Pipeline Does

- reads a USGS map URL and converts its visible filters into USGS catalog API parameters
- paginates large result sets and automatically splits oversized time windows
- normalizes timestamps into `time_utc` and `time_et`
- enriches events with `country` based on latitude and longitude
- applies guardrails so `country` does not export blank
- cleans `magnitude` into a display field and preserves `magnitude_raw`
- cleans `depth_km` into a display field and preserves `depth_km_raw`
- exports curated CSV, curated JSON, GeoJSON, and pipeline metadata
- refreshes automatically in the cloud on a schedule

## Data Source

USGS Earthquake Catalog:

- Map interface: [USGS Earthquake Map](https://earthquake.usgs.gov/earthquakes/map/)
- Event API: [USGS FDSN Event Service](https://earthquake.usgs.gov/fdsnws/event/1/)

The workflow can use:

- the default map URL baked into the repository
- a repository variable named `USGS_MAP_URL`
- a one-off override supplied during `workflow_dispatch`

## Outputs

Recommended curated CSV:

- `usgs_seismic_stream/exports/earthquakes_live_curated.csv`

Curated JSON:

- `usgs_seismic_stream/exports/earthquakes_live_curated.json`

GeoJSON:

- `usgs_seismic_stream/exports/earthquakes_live.geojson`

Pipeline metadata:

- `usgs_seismic_stream/exports/pipeline_meta.json`

## Data Model

Primary curated fields:

- `id`
  USGS event identifier
- `time_utc`
  UTC event timestamp
- `time_et`
  Eastern Time event timestamp
- `updated_utc`
  UTC update timestamp from USGS
- `magnitude`
  Cleaned display magnitude
- `magnitude_raw`
  Cleaned source magnitude before display guardrails
- `place`
  USGS place description
- `latitude`
  Event latitude
- `longitude`
  Event longitude
- `country`
  Country or fallback label derived from coordinates and place context
- `depth_km`
  Cleaned display depth in kilometers
- `depth_km_raw`
  Cleaned source depth before display rounding
- `event_type`
  USGS event type
- `detail_url`
  USGS event page
- `detail_api`
  USGS detail API link

## Automation & Monitoring

GitHub Actions workflows:

- `.github/workflows/usgs-earthquake-refresh.yml`
- `.github/workflows/usgs-earthquake-stale-alert.yml`

Automated capabilities:

- scheduled ingestion and export regeneration
- manual workflow dispatch with optional map URL override
- effective one-minute refresh cadence inside each scheduled workflow run
- serialized refresh runs to avoid overlapping workflow commits
- published export refresh under `usgs_seismic_stream/exports`
- heartbeat monitoring for stale pipeline detection
- automatic GitHub issue creation for stale pipeline alerts
- automatic stale-issue closure when the pipeline is healthy again
- compatibility with ephemeral GitHub-hosted runners

## Security & Data Integrity

- no credentials should be stored in the repository
- no personal data is ingested or published
- only derived public datasets are committed
- raw scratch exports stay outside version control through `.gitignore`
- schema-aware normalization is applied before export
- country and display-field guardrails reduce blank and noisy values in public outputs
- `SECURITY.md` documents the repository security posture and reporting guidance

## Run Locally

Refresh the production-style published exports:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\usgs_seismic_stream\publish-usgs-earthquakes.ps1"
```

Run the base scraper directly to a one-off file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\usgs-earthquake-scraper.ps1" -OutputPath ".\earthquakes.csv"
```

## GitHub Setup

To finish connecting this local folder to the GitHub repository you already created:

1. connect this folder to the remote repository
2. push the repo scaffold and workflow files
3. enable GitHub Actions
4. set repository workflow permissions so `GITHUB_TOKEN` can write contents
5. optionally add a repository variable named `USGS_MAP_URL`

GitHub Actions does not support a native one-minute cron schedule. To work around that, this repository keeps the cron trigger at every 5 minutes and runs a one-minute internal refresh loop inside each scheduled workflow execution.

## Notes

- this repository already has the cloud refresh pipeline and monitoring layer ready
- a public dashboard layer can be added later against the curated exports if you want to mirror the Peru project more closely
- raw GitHub URLs can be added to this README once the final remote repository URL is connected

## Security

See `SECURITY.md` for the repository security posture and reporting guidance.
