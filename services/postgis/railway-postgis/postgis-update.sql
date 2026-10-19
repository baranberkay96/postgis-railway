-- Run by railway-postgis after boot in every database that accepts
-- connections. If PostGIS is installed and the image now ships a newer patch
-- release of the same minor (for example 3.6.4 -> 3.6.5), apply it with
-- PostGIS's own upgrade function. A different minor (3.6 -> 3.7) is only
-- reported: that upgrade is a deliberate step (see TEMPLATE.md, Upgrades).
DO $railway_postgis$
DECLARE
  installed text;
  available text;
  ext_schema text;
BEGIN
  SELECT e.extversion, n.nspname
    INTO installed, ext_schema
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'postgis';
  IF installed IS NULL THEN
    RETURN;
  END IF;

  SELECT default_version INTO available
    FROM pg_catalog.pg_available_extensions
   WHERE name = 'postgis';
  IF available IS NULL OR available = installed THEN
    RETURN;
  END IF;

  IF split_part(installed, '.', 1) <> split_part(available, '.', 1)
     OR split_part(installed, '.', 2) <> split_part(available, '.', 2) THEN
    RAISE NOTICE 'PostGIS % is installed and % is available: different minor release, not updated automatically. Run SELECT postgis_extensions_upgrade(); after reading the release notes.', installed, available;
    RETURN;
  END IF;

  BEGIN
    EXECUTE format('SELECT %I.postgis_extensions_upgrade()', ext_schema);
    RAISE NOTICE 'PostGIS extensions updated from % to %', installed, available;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'PostGIS update from % to % failed (will retry on next boot): %', installed, available, SQLERRM;
  END;
END
$railway_postgis$;
