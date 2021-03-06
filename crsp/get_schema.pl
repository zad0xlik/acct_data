#!/usr/bin/env perl
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Text::CSV_XS;
use DBI;

# Get schema and table name from command line. I have set my database
# up so that these line up with the names of the WRDS library and data
# file, respectively.
$table_name = @ARGV[1];
$db_schema = @ARGV[0];

$db = "$db_schema.";
#if ($table_name ne "ccmxpf_linktable") {
  $db =~ s/^crsp/crspq/;
#}

# I call my database "crsp" (for legacy reasons)
$dbname = "crsp";
$wrds_id = "iangow";
$pg_user = "igow";
$pg_pass = "test";

# SAS code to extract information about the datatypes of the SAS data.
# Note that there are some date formates that don't work with this code.
$sas_code = "
	
	libname pwd '.';

	* Edit the following to refer to the table of interest;
	%let db=$db;
	%let table_name= $table_name;
	%let suffix=_schema;
	%let filetype=.csv;
	%let outcsv=&table_name&suffix&filetype;

	* Use PROC CONTENTS to extract the information desired.;
	proc contents data=&db&table_name out=schema;
	run;

	* Use PROC CONTENTS to extract the information desired.;
	proc contents data=&db&table_name out=schema noprint;
	run;

	* Do some preprocessing of the results;
	data schema(keep=name postgres_type);
		set schema(keep=name format formatl formatd length type);
		format postgres_type \\\$36.;
		if format=\\\"TIME8.\\\" or prxmatch(\\\"/time/i\\\", format) then postgres_type=\\\"time\\\";
		else if format=\\\"YYMMDDN\\\" or format=\\\"DATE9.\\\" or prxmatch(\\\"/date/i\\\", format) 
            then postgres_type=\\\"date\\\";
	  	else if type=1 then do;
			if formatd ^= 0 then postgres_type = \\\"float8\\\";
			if formatd = 0 and formatl ^= 0 then postgres_type = \\\"int8\\\";
			if formatd = 0 and formatl =0 then postgres_type = \\\"float8\\\";
	  	end;
	  	else if type=2 then postgres_type = \\\"text\\\";
	run;

	* Now dump it out to a CSV file;
	proc export data=schema outfile=stdout dbms=csv;
	run;";

# Run the SAS code on the WRDS server and save the result to ./schema.csv
`echo "$sas_code" | ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -stdio -noterminal' | cat > schema.csv`;

my $schema_csv = Text::CSV_XS->new ({ binary => 1 });

# Read in schema.csv and parse the data therein.
# (It might be possible to parse this directly from a pipe from WRDS,
#  but there are a lot of messy details in CSV files that I avoid this way.)
$schema = "schema.csv";
open my $io, "<", $schema or die "$schema: $!";
while (my $row = $schema_csv->getline ($io)) {
	my @fields = @$row;
	my $field = @fields[0];
	$field =~ s/^do$/do_/i;
	my $type = @fields[1];
	$hrec{$field} = $type;
#	print "$field, $type\n";
}

# Clean up, etc.
$schema_csv->eof or $schema_csv->error_diag;
close $io or die "$schema: $!";

# Now, get the first row of the SAS data file from WRDS. This is important,
# as we need to put the table together so as to align the fields with the data
# (the "schema" code above doesn't do this for us).
$sas_code = "
	proc export data=$db$table_name(obs=1)
            outfile=stdout
            dbms=csv;
        run;";

# Run the SAS command and put the output into ./data.csv.gz
@result = `echo "$sas_code" | ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -stdio -noterminal' | gzip > data.csv.gz`;
$gz_file = "data.csv.gz";

# Get the first row of the text file
my $csv = Text::CSV_XS->new ({ binary => 1 });
my $fh = new IO::Uncompress::Gunzip $gz_file 
        or die "IO::Uncompress::Gunzip failed: $GunzipError\n";

$row = $csv->getline($fh);

# Get table information from the "schema" file
my $dbh = DBI->connect("dbi:Pg:dbname=$dbname", $pg_user, $pg_pass)	
	or die "Cannot connect: " . $DBI::errstr;

# $schema = "schema/$table_name" . "_schema.csv";
# $db_schema = "crsp";

$dbh->do("SET search_path TO $db_schema");

$sql = "CREATE TABLE $table_name (";

# Set some default/initial parameters
$first_field = 1;
$sep="";
$has_date = 0;
$has_gvkey = 0;
$i=0;
# Construct SQL fragment associated with each variable for 
# the table creation statement
foreach $field (@$row) {
	# Flag some key fields for indexing. Probably should use the schema file
	# to indicate what fields should be used for indexing. Not sure if
	# WRDS SAS file contains useful information in this regard.
	if ($field =~ /^GVKEY$/i) { $has_gvkey = 1; }
	if ($field =~ /^DATADATE$/i) { $has_datadate = 1; }
	if ($field =~ /^PERMNO$/i) { $has_permno = 1; }
	if ($field =~ /^DATE$/i) { $has_date = 1;}
	$field =~ s/^do$/do_/i;

	# Dates are stored as integers initially, then converted to 
	# dates later on (see below).
	if ($hrec{$field} eq "date") {
		$type = $hrec{$field};
		# $type = "integer";
	} else {
		$type = $hrec{$field};
	}

	# Concatenate the component strings. Note that, apart from the first
	# field a leading comma is inserted to separate fields in the 
	# CREATE TABLE SQL statement.
	$sql = $sql . $sep . $field . " " . $type;
	if ($first_field) { $sep=", "; $first_field=0; }
}
$sql = $sql . ");";
print "$sql\n";

if(TRUE) {
	# Clean up, etc.
	$csv->eof or $csv->error_diag;
	close $fh or die "$gz_file: $!";

	# Drop the table if it exists already, then create the new table
	# using field names taken from the first row
	$dbh->do("DROP TABLE IF EXISTS $table_name CASCADE;");
	$dbh->do($sql);

	# Get the data
	$sas_code = "
		proc export data=$db$table_name outfile=stdout dbms=csv;
        run;";
	# print "$sas_code";

	# Use PostgreSQL's COPY function to get data into the database
	$time = localtime;
	printf "Beginning file import at %d:%02d:%02d\n",@$time[2],@$time[1],@$time[0];
	$cmd = "echo \"$sas_code\" | ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -stdio -noterminal'";
	$cmd .= " | psql -U $pg_user ";
	$cmd .= "-d $dbname -c \"COPY $db_schema.$table_name FROM STDIN CSV HEADER ENCODING 'latin1' \"";

	print "$cmd\n";
	$result = system($cmd);
	print "Result of system command: $result\n";

	$time = localtime;
	printf "Completed file import at %d:%02d:%02d\n",@$time[2],@$time[1],@$time[0];

	# Convert date fields from integers to dates
	foreach $key (keys %hrec) { 
		$value = $hrec{$key};
		
		if (0) { #$value eq 'date') {
			print "Converting $key from integer to date\n";
			$sql = "ALTER TABLE $table_name ALTER $key TYPE date ".
				"USING (date '1960-01-01' +  $key);";
			$dbh-> do($sql); 
		} 
	}
}

# Create indices for performance
if ($table_name eq "ccmxpf_linktable") {
	$sql = "CREATE INDEX $table_name" ."_lpermno_idx ON $table_name (lpermno);";
	print "$sql\n";
	$dbh->do($sql);
	$sql = "CREATE INDEX $table_name" ."_main_idx ON $table_name (gvkey);";
	print "$sql\n";
	$dbh->do($sql);
	$dbh->do("CLUSTER $table_name USING $table_name" ."_main_idx");
	$index=0;
}

if ($table_name eq "dsf" || $table_name eq "erdport1") {
	$sql = "ALTER TABLE $table_name ADD PRIMARY KEY (permno, date);";
	print "$sql\n";
	$dbh->do($sql);
	
	$dbh->do("CLUSTER $table_name USING $table_name" . "_pkey");
	
	$sql = "CREATE INDEX $table_name" ."_date_idx ON $table_name (date);";
	print "$sql\n";
	$dbh->do($sql);

	$index=0;
}

if ($table_name eq "dsi") {
	$sql = "ALTER TABLE $table_name ADD PRIMARY KEY (date);";
	print "$sql\n";
	$dbh->do($sql);
	$dbh->do("CLUSTER $table_name USING $table_name" . "_pkey");
	$index=0;
  $cmd = "psql -d crsp < ~/Dropbox/WRDS/make_trading_dates_pg.sql";
  $result = system($cmd);
  print "$result";
  
}

if ($table_name eq "company" and $db_schema eq "crsp") {
	$sql = "ALTER TABLE $table_name ADD PRIMARY KEY (permno);";
	print "$sql\n";
	$dbh->do($sql);
	$dbh->do("CLUSTER $table_name USING $table_name" . "_pkey");
	$index=0;
}

if ($table_name eq "fundq") {
    $dbh->do("CREATE VIEW compq.fundq AS SELECT * FROM comp.fundq");
}

if ($table_name eq "s34") {
    $dbh->do("ALTER TABLE tfn.s34 ALTER mgrno TYPE integer");
}


if ($table_name eq "stocknames") {
    $dbh->do("ALTER TABLE crsp.stocknames ALTER COLUMN permno TYPE bigint");
    $dbh->do("ALTER TABLE crsp.stocknames ALTER COLUMN permco TYPE bigint");
}


if ($has_date ==1 and $has_permno==1) {
	$index_on = "(PERMNO, DATE)";
	$index +=1;
} elsif ($has_date==1) {
	$index_on = "(DATE)";
	$index +=1;
} elsif ($has_permno==1) {
	$index_on = "(PERMNO)";
	$index +=1;
}

if ($has_datadate ==1 & $has_gvkey==1) {
	$index_on = "(gvkey, datadate)";
	$index +=1;
} elsif ($has_datadate==1) {
	$index_on = "(datadate)";
	$index +=1;
} elsif ($has_gvkey==1) {
	$index_on = "(gvkey)";
	$index +=1;
}

if ($index) {
	$sql = "CREATE INDEX ON $table_name $index_on;";
	print "$sql\n";
	$dbh->do($sql);
}

if ($table_name eq "secm") {
 	$sql = "DROP TABLE IF EXISTS comp.cusips;";
    $sql .= "CREATE TABLE comp.cusips AS SELECT DISTINCT gvkey, cusip FROM comp.secm;";
	print "$sql\n";
	$dbh->do($sql);   
}

use Time::localtime;
$tm=localtime;
# print "$tm"; 
my ($day,$month,$year)=($tm->mday(),$tm->mon(),$tm->year());

$updated = sprintf( "Table updated on %d-%02d-%02d.", 1900+$year, 1+$month, $day);
print "$updated\n";
$dbh->do("COMMENT ON TABLE $table_name IS '$updated'");
$dbh->disconnect();

# $cmd = "psql -d crsp < ~/Dropbox/pg_backup/support/permissions.sql";
# $results = system($cmd);
