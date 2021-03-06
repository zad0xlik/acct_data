#!/usr/bin/env Rscript

# The code in this file updates the older version of streetevents.speaker_data
# by adding a field last_update when there is a unique file associated with a
# a given file_name (the vast majority of cases).
# The purpose of doing this is to avoid re-parsing all the underlying
# call files. For cases where there are multiple updates, 
# Get a list of files that need to be processed ----

library("RPostgreSQL")
pg <- dbConnect(PostgreSQL())

dbGetQuery(pg, "
    SET work_mem='3GB';

    -- ALTER TABLE streetevents.speaker_data 
    --    ADD COLUMN last_update timestamp without time zone;
    DROP TABLE IF EXISTS streetevents.last_updates;
    
    CREATE TABLE streetevents.last_updates AS 
    WITH unique_file_names AS (
        SELECT file_name, count(DISTINCT file_path) AS num_files
        FROM streetevents.calls_test
        GROUP BY file_name
        HAVING count(DISTINCT file_path)=1)
    
    SELECT file_name, last_update
    FROM unique_file_names
    INNER JOIN streetevents.calls_test
    USING (file_name);
    
    CREATE INDEX ON streetevents.last_updates (file_name);")

# Note that this assumes that streetevents.calls is up to date.
file_list <- dbGetQuery(pg, "
    SET work_mem='2GB';

    SELECT file_name
    FROM streetevents.last_updates
    WHERE file_name IN
        (SELECT file_name FROM streetevents.speaker_data
                        WHERE last_update IS NULL)")

rs <- dbDisconnect(pg)

# Create function to parse a StreetEvents XML file ----
addLastUpdated <- function(file_name) {
    pg <- dbConnect(PostgreSQL())
    
    # Parse the indicated file using a Perl script
    dbGetQuery(pg, sprintf("
    UPDATE streetevents.speaker_data AS a 
    SET last_update = (
        SELECT b.last_update
        FROM streetevents.last_updates  AS b
        WHERE a.file_name=b.file_name)
    WHERE a.file_name ='%s';", file_name))
    
    rs <- dbDisconnect(pg)
    
}

# Apply parsing function to files ----
library(parallel)
system.time({
    res <- unlist(mclapply(file_list$file_name, addLastUpdated, mc.cores=12))
})

# Drop unneeded last_updates table ----
pg <- dbConnect(PostgreSQL())

dbGetQuery(pg, "DROP TABLE IF EXISTS streetevents.last_updates;")

rs <- dbDisconnect(pg)
