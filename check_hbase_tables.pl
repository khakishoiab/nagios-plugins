#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2013-07-26 18:52:38 +0100 (Fri, 26 Jul 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#  

$DESCRIPTION = "Nagios Plugin to check given HBase table(s) via the HBase Thrift Server API

Checks:

1. Table exists
2. Table is enabled
3. Table has Columns
4. Table's regions are all assigned to regionservers

Performance using the Thrift Server is much faster than trying to leverage the HBase API using JVM languages or the Rest API which lacks good structure for parsing and is slower as well.

Requires the CPAN Thrift perl module

HBase Thrift bindings were generated using Thrift 0.9.0 on CDH 4.3 CentOS 6.4 and placed under lib/Hbase

Known Issues/Limitations:

1. The HBase Rest API doesn't seem to expose details on -ROOT- and .META. regions so the code only checks they are present, enabled and we can get Column descriptors for them
2. The HBase Thrift Server takes around 10 seconds to time out when there are no regionservers online, resulting in \"UNKNOWN: self timed out after 10 seconds\" if the timeout is too short and \"CRITICAL: failed to get regions for table '\$tablename': Thrift::TException: TSocket: timed out reading 4 bytes from \$host:\$port\" otherwise. For this reason the default timeout on this plugin is set to 20 seconds instead of the usual 10 to try to get a better error message to show what specific call has failed but you'll probably need to increase your Nagios service_check_timeout in nagios.cfg to see it";

$VERSION = "0.2";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils;
use Data::Dumper;
use Thrift;
use Thrift::Socket;
use Thrift::BinaryProtocol;
use Thrift::BufferedTransport;
# Thrift generated bindings for HBase, provided in lib
use Hbase::Hbase;

set_timeout_default 20;

my $default_port = 9090;
$port = $default_port;

my $tables;

%options = (
    "H|host=s"         => [ \$host,     "HBase thrift server address to connect to" ],
    "P|port=s"         => [ \$port,     "HBase thrift server port to connect to (defaults to $default_port)" ],
    "T|tables=s"       => [ \$tables,   "Table(s) to check. This should be a list of user tables, not -ROOT- or .META. catalog tables which are checked additionally" ],
);

@usage_order = qw/host port tables/;
get_options();

$host  = validate_hostname($host);
$port  = validate_port($port);
defined($tables) or usage "no tables specified";
my @tables = grep { $_ ne "-ROOT-" and $_ ne ".META." } split(/\s*,\s*/, $tables);
@tables or usage "no valid tables specified";
@tables = uniq_array @tables;
my $table;
foreach $table (@tables){
    if($table =~ /^(-ROOT-|\.META\.)$/){
    } else {
        $table = isDatabaseTableName($table) or usage "invalid table name $table given";
    }
}
vlog_options "tables", "[ " . join(" , ", @tables) . " ]";

vlog2;
set_timeout();

my $client;
my $socket;
my $transport;
my $protocol;
my @hbase_tables;

sub catch_error ($) {
    my $errmsg = $_[0];
    catch {
        if(defined($@->{"message"})){
            quit "CRITICAL", "$errmsg: " . ref($@) . ": " . $@->{"message"};
        } else {
            quit "CRITICAL", "$errmsg: " . Dumper($@);
        }
    }
}

# using custom try/catch from my library as it's necessary to disable the custom die handler for this to work
try {
    $socket    = new Thrift::Socket($host, $port);
};
catch_error "failed to connect to Thrift server at '$host:$port'";
try {
    $transport = new Thrift::BufferedTransport($socket,1024,1024);
};
catch_error "failed to initiate Thrift Buffered Transport";
try {
    $protocol  = new Thrift::BinaryProtocol($transport);
};
catch_error "failed to initiate Thrift Binary Protocol";
try {
    $client    = Hbase::HbaseClient->new($protocol);
};
catch_error "failed to initiate HBase Thrift Client";

$status = "OK";

try {
    $transport->open();
};
catch_error "failed to open Thrift transport to $host:$port";
try {
    @hbase_tables = @{$client->getTableNames()};
};
catch_error "failed to get tables from HBase";
@hbase_tables or quit "CRITICAL", "no tables found in HBase";
if($verbose >= 3){
    hr;
    print "found HBase tables:\n\n" . join("\n", @hbase_tables) . "\n";
    hr;
    print "\n";
}

my @tables_not_found;
my @tables_disabled;
my @tables_without_columns;
my @tables_without_regions;
my @tables_without_regionservers;
my @tables_with_unassigned_regions;
my @tables_ok;
my %table_regioncount;

sub check_table_enabled($){
    my $table = shift;
    my $state;
    try {
        $state = $client->isTableEnabled($table);
    };
    catch_error "failed to get table state (enabled/disabled) for table '$table'";
    if($state){
        vlog2 "table '$table' enabled";
    } else {
        vlog2 "table '$table' NOT enabled";
        critical;
        push(@tables_disabled, $table);
        return 0;
    }
    return 1;
}


sub check_table_columns($){
    my $table = shift;
    my $table_columns;
    try {
        $table_columns = $client->getColumnDescriptors($table);
    };
    catch_error "failed to get Column descriptors for table '$table'";
    vlog3 "table '$table' columns: " . Dumper($table_columns);
    unless($table_columns){
        push(@tables_without_columns, $table);
        return 0;
    }
    vlog2 "table '$table' columns: " . join(",", sort keys %{$table_columns});
    return 1;
}


sub check_table_regions($){
    my $table = shift;
    my $table_regions;
    my @regionservers = ();
    try {
        $table_regions = $client->getTableRegions($table);
    };
    catch_error "failed to get regions for table '$table'";
    $table_regions or quit "UNKNOWN", "failed to get regions for table '$table'";
    vlog3 "table '$table' regions: " . Dumper($table_regions);
    unless(@{$table_regions}){
        push(@tables_without_regions, $table);
        return 0;
    }
    $table_regioncount{$table} = scalar @{$table_regions};
    vlog2 "table '$table' regions: $table_regioncount{$table}";
    foreach my $ref (@{$table_regions}){
        if(defined($ref->serverName) and $ref->serverName){
            push(@regionservers, $ref->serverName);
        } else {
            vlog2 "table '$table' region '$ref->name' is unassigned to any regionserver!";
            push(@tables_with_unassigned_regions, $table);
        }
    }
    if(@regionservers){
        @regionservers = uniq_array @regionservers;
        vlog2 "table '$table' regionservers: " . join(",", @regionservers);
    } else {
        vlog2 "table '$table' has NO regionservers!";
        push(@tables_without_regionservers, $table);
        return 0;
    }
    return 1;
}


sub check_table($){
    my $table = shift;
    check_table_enabled($table) and
    check_table_columns($table) and
    check_table_regions($table) and
    push(@tables_ok, $table);
}

# XXX: Thrift API doesn't give us region info on -ROOT- and .META. so running check_table* individually without check_table_regions
foreach(qw/-ROOT- .META./){
    check_table_enabled($_) and
    check_table_columns($_) and
    push(@tables_ok, $_);
}
foreach $table (@tables){
    unless(grep { $table eq $_ } @hbase_tables){
        critical;
        push(@tables_not_found, $table);
        next;
    }
    check_table($table);
}
vlog2;

if(@tables_not_found){
    @tables_not_found = uniq_array @tables_not_found;
    plural scalar @tables_not_found;
    $msg .= "table$plural not found: '" . join(",", @tables_not_found) . "', ";
}
if(@tables_disabled){
    @tables_disabled = uniq_array @tables_disabled;
    plural scalar @tables_disabled;
    $msg .= "table$plural disabled: '" . join(",", @tables_disabled) . "', ";
}
if(@tables_without_columns){
    @tables_without_columns = uniq_array @tables_without_columns;
    plural scalar @tables_without_columns;
    $msg .= "table$plural with no columns: '" . join(",", @tables_without_columns) . "', ";
}
if(@tables_without_regions){
    @tables_without_regions = uniq_array @tables_without_regions;
    plural scalar @tables_without_regions;
    $msg .= "table$plural with no regions: '" . join(",", @tables_without_regions) . "', ";
}
if(@tables_without_regionservers){
    @tables_without_regionservers = uniq_array @tables_without_regionservers;
    plural scalar @tables_without_regionservers;
    $msg .= "table$plural with no regionservers: '" . join(",", @tables_without_regionservers) . "', ";
}
if(@tables_with_unassigned_regions){
    @tables_with_unassigned_regions = grep { ! grep($_, @tables_without_regionservers) } @tables_with_unassigned_regions;
    @tables_with_unassigned_regions = uniq_array @tables_with_unassigned_regions;
    plural scalar @tables_with_unassigned_regions;
    $msg .= "table$plural with unassigned regions: '" . join(",", @tables_with_unassigned_regions) . "', ";
}
plural @tables_ok;
$msg .= "table$plural ok: '" . join(",", @tables_ok) . "'";
$msg =~ s/, $//;
$msg .= " |";
foreach $table (sort keys %table_regioncount){
    $msg .= " '$table regions'=$table_regioncount{$table}";
}

quit $status, $msg;
