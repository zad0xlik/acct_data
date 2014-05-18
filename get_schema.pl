#!/usr/bin/env perl
use DBI;
use Getopt::Long;
use Time::localtime;
use Env qw($PGDATABASE);

################################################
# 0. Get command-line arguments                #
################################################

# Extract options from the command line
# Example ./get_wrds_data.pl comp idx_index --fix-missing --wrds-id iangow
# gets comp.idx_index from WRDS using WRDS ID iangow. It also converts 
# special missing values (e.g., .Z) to regular missing values (i.e., .)
#
# In most cases, you will want to omit --fix-missing.
#
# Database name can be specified on command line using
# --dbname=your_database, otherwise environment variable
# PGDATABASE will be used.
my $dbname = $PGDATABASE;
my $use_st = '';
my $wrds_id = 'iangow';	# option variable with default value
GetOptions('fix-missing' => \$fix_missing,
            'wrds-id=s' => \$wrds_id,
            'dbname=s' => \$dbname); 

# Get schema and table name from command line. I have set my database
# up so that these line up with the names of the WRDS library and data
# file, respectively.
$table_name = @ARGV[1];
$db_schema = @ARGV[0];

$db = "$db_schema.";

# Use the quarterly update of CRSP
$db =~ s/^crsp/crspq/;

################################################
# 1. Get format of variables on WRDS table     #
################################################

# SAS code to extract information about the datatypes of the SAS data.
# Note that there are some date formates that don't work with this code.
$sas_code = "
    options nonotes nosource;
    
    libname pwd '.';  

	* Edit the following to refer to the table of interest;
	%let db=$db;
	%let table_name= $table_name;

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

# Run the SAS code on the WRDS server and save the result to @result
@result = `echo "$sas_code" | ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -nonotes -nonews -stdio -noterminal ' `;

# Now fill an array with the names and data type of each variable 
my %var_type;
foreach $row (@result)	{
    my @fields = split(",", $row);
    my $field = @fields[0];

    # Rename fields with problematic names
    $field =~ s/^do$/do_/i;
    
    my $type = @fields[1];
    chomp $type;
    $var_type{$field} = $type;
}

##################################################
# 2. Get column order of variables on WRDS table #
##################################################


# Get the first row of the SAS data file from WRDS. This is important,
# as we need to put the table together so as to align the fields with the data
# (the "schema" code above doesn't do this for us).
$sas_code = "
    options nosource nonotes;
    
    proc export data=$db$table_name(obs=1)
        outfile=stdout
        dbms=csv;
    run;";

# Run the SAS command and get the first row of the table
$row = `echo "$sas_code" | ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -nonotes -nonews -stdio -noterminal  ' | head -n 1`;

##################################################
# 3. Construct and run CREATE TABLE statement    #
##################################################

$sql = "CREATE TABLE $table_name (";

# Set some default/initial parameters
$first_field = 1;
$sep="";

# Construct SQL fragment associated with each variable for 
# the table creation statement
foreach $field (split(',', $row)) {
    
    chomp $field;
    # Rename fields with problematic names
    $field =~ s/^do$/do_/i;

    # Concatenate the component strings. Note that, apart from the first
    # field a leading comma is inserted to separate fields in the 
    # CREATE TABLE SQL statement.
    $sql .= $sep . $field . " " . $var_type{$field};
    if ($first_field) { $sep=", "; $first_field=0; }
}
$sql .=  ");";

# Connect to the database
my $dbh = DBI->connect("dbi:Pg:dbname=$dbname")
    or die "Cannot connect: " . $DBI::errstr;

$dbh->do("SET search_path TO $db_schema");

# Drop the table if it exists already, then create the new table
# using field names taken from the first row
$dbh->do("DROP TABLE IF EXISTS $table_name CASCADE;");
$dbh->do($sql);

##################################################################
# 4. Import the data using COPY from CSV file piped from WRDS    #
##################################################################

$tm = localtime;
printf "Beginning file import at %d:%02d:%02d\n",@$tm[2],@$tm[1],@$tm[0];


if ($fix_missing) {
    # If need to fix special missing values, then convert them to 
    # regular missing values, then run PROC EXPORT
    $sas_code = "
      options nosource nonotes;
      
      libname pwd '/sastemp6';
      
      * Fix missing values;
      data pwd.schema;
          set $db$table_name;

          array allvars _numeric_ ;

          do over allvars;
              if missing(allvars) then allvars = . ;
          end;
      run;
      
      proc export data=pwd.schema outfile=stdout dbms=csv;
      run;";
    
} else {
  # Otherwise, just use PROC EXPORT
  $sas_code = "
      options nosource nonotes;
      
      proc export data=$db$table_name outfile=stdout dbms=csv;
      run;";

}

# Use PostgreSQL's COPY function to get data into the database
$cmd = "echo \"$sas_code\" | ";
$cmd .= " ssh -C $wrds_id\@wrds.wharton.upenn.edu 'sas -nonews -nonotes -stdio -noterminal' | ";
$cmd .= " psql -c \"COPY $db_schema.$table_name FROM STDIN CSV HEADER ENCODING 'latin1' \"";
print "$cmd\n";
$result = system($cmd);
print "Result of system command: $result\n";

$tm=localtime;
printf "Completed file import at %d:%02d:%02d\n",@$tm[2],@$tm[1],@$tm[0];

# Comment on table to reflect date it was updated
my ($day,$month,$year)=($tm->mday(),$tm->mon(),$tm->year());
$updated = sprintf( "Table updated on %d-%02d-%02d.", 1900+$year, 1+$month, $day);
print "$updated\n";
$dbh->do("COMMENT ON TABLE $table_name IS '$updated'");
$dbh->disconnect();

