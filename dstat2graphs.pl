#!/usr/bin/perl

use strict;
use warnings;

use Archive::Zip qw/AZ_OK/;
use File::Path;
use HTML::Entities;
use POSIX qw/floor ceil/;
use RRDs;
use Text::ParseWords;
use Time::Local;

if ($#ARGV != 7) {
    die 'Usage: perl dstat2graph.pl csv_file report_dir width height disk_limit net_limit offset duration';
}

my $csv_file   = $ARGV[0];
my $report_dir = $ARGV[1];
my $width      = $ARGV[2];
my $height     = $ARGV[3];
my $disk_limit = $ARGV[4];
my $net_limit  = $ARGV[5];
my $offset     = $ARGV[6];
my $duration   = $ARGV[7];

my @colors = (
    '008FFF', 'FF00BF', 'BFBF00', 'BF00FF',
    'FF8F00', '00BFBF', '7F5FBF', 'BF5F7F',
    '7F8F7F', '005FFF', 'FF007F', '7FBF00',
    '7F00FF', 'FF5F00', '00BF7F', '008FBF',
    'BF00BF', 'BF8F00', '7F5F7F', '005FBF',
    'BF007F', '7F8F00', '7F00BF', 'BF5F00',
    '008F7F', '0000FF', 'FF0000', '00BF00',
    '005F7F', '7F007F', '7F5F00', '0000BF',
    'BF0000', '008F00'
    );

my $epoch = 978274800; # 2001/01/01 00:00:00
my $top_dir = '../..';
my $rrd_file = '/dev/shm/dstat2graphs/' . &random_str() . '.rrd';

my ($hostname, $year, @data, %index_disk, %index_cpu, %index_net, %value);
my ($start_time, $end_time, $memory_size) = (0, 0, 0);

&load_csv();
&create_rrd();
&update_rrd();
&create_dir();
&create_graph();
&delete_rrd();
&create_html();
&create_zip();

sub load_csv {
    my $csv_start_time = 0;
    open(my $fh, '<', "${csv_file}") or die $!;
    
    while (my $line = <$fh>) {
        chomp($line);
        
        if ($line eq '') {
            # Empty
        } elsif ($line =~ /^"?[a-zA-Z]/) {
            # Header
            my @cols = parse_line(',', 0, $line);
            
            if ($cols[0] =~ /^Dstat/) {
                # Title
            } elsif ($cols[0] eq 'Author:') {
                # Author, URL
            } elsif ($cols[0] eq 'Host:') {
                # Host, User
                $hostname = $cols[1];
            } elsif ($cols[0] eq 'Cmdline:') {
                # Cmdline, Date
                if ($cols[6] =~ /^\d+ \w+ (\d+)/) {
                    $year = $1;
                }
            # RHEL5:time, RHEL6:system
            } elsif (($cols[0] eq 'time') or ($cols[0] eq 'system')) {
                # Column name main
                my $index = -1;
                
                foreach my $col (@cols) {
                    $index++;
                    
                    if (!defined($col)) {
                        # Empty
                    } elsif (($col =~ /^dsk\/(\w+[a-z])$/)
                             or ($col =~ /^dsk\/cciss\/(c\d+d\d+)$/)) {
                        # Disk
                        my $disk = $1;
                        $disk =~ tr/\//_/;
                        $index_disk{$disk} = $index;
                    } elsif ($col =~ /^cpu(\d+)/) {
                        # CPU
                        $index_cpu{$1} = $index;
                    } elsif ($col =~ /^net\/(\w+)/) {
                        # Network
                        my $net = $1;
                        $net =~ tr/\//_/;
                        $index_net{$net} = $index;
                    }
                }
            } elsif ($cols[0] eq 'date/time') {
                # Column name sub
            } else {
                die 'It is not a dstat CSV file.';
            }
        } else {
            # Body
            my ($disk_read, $disk_writ, $net_recv, $net_send) = (0, 0, 0, 0);
            my @cols = parse_line(',', 0, $line);
            my $unixtime = &get_unixtime($year, $cols[0]);
            
            if ($csv_start_time == 0) {
                if (!defined($hostname)) {
                    die 'It is not a dstat CSV file. No \'Host:\' column found.';
                }
                
                if (!defined($year)) {
                    die 'It is not a dstat CSV file. No \'Date:\' column found.';
                }
                
                if (!%index_disk) {
                    die 'It is not a dstat CSV file. No \'dsk/*:\' columns found.';
                }
                
                if (!%index_cpu) {
                    die 'It is not a dstat CSV file. No \'cpu*:\' columns found.';
                }
                
                if (!%index_net) {
                    die 'It is not a dstat CSV file. No \'net/*\' columns found.';
                }
                
                $csv_start_time = $unixtime;
            }
            
            if ($unixtime < $csv_start_time + $offset) {
                next;
            }
            
            if ($start_time == 0) {
                $start_time = $unixtime;
            }
            
            if ($unixtime <= $end_time) {
                next;
            }
            
            $end_time = $unixtime;
            push @data, $line;
            
            if ($memory_size < $cols[4] + $cols[5] + $cols[6] + $cols[7]) {
                $memory_size = $cols[4] + $cols[5] + $cols[6] + $cols[7];
            }
            
            if (($duration > 0) and ($start_time + $duration <= $end_time)) {
                last;
            }
        }
    }
    
    close($fh);
    
    if (($offset > 0) and ($#data == -1)) {
        die 'Offset is too large.';
    }
}

sub create_rrd {
    my @options;
    my $steps = floor(($end_time - $start_time) / 3600) + 1;
    my $rows = ceil(($end_time - $start_time) / $steps) + 1;
    
    # --start
    push @options, '--start';
    push @options, $epoch - 1;
    
    # --step
    push @options, '--step';
    push @options, 1;
    
    # Processes
    push @options, 'DS:PROCS_RUN:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:PROCS_BLK:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:PROCS_NEW:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Memory
    push @options, 'DS:MEMORY_USED:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:MEMORY_BUFF:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:MEMORY_CACH:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Paging
    push @options, 'DS:PAGE_IN:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:PAGE_OUT:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Disk total
    push @options, 'DS:DISK_READ:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:DISK_WRIT:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Disk individual
    foreach my $disk (sort keys %index_disk) {
        push @options, "DS:DISK_${disk}_READ:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:DISK_${disk}_WRIT:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    }
    
    # Interrupts
    push @options, 'DS:INTERRUPTS:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Context Switches
    push @options, 'DS:CSWITCHES:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # CPU total
    push @options, 'DS:CPU_USR:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:CPU_SYS:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:CPU_HIQ:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:CPU_SIQ:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:CPU_WAI:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # CPU individual
    foreach my $cpu (sort { $a <=> $b } keys %index_cpu) {
        push @options, "DS:CPU${cpu}_USR:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:CPU${cpu}_SYS:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:CPU${cpu}_HIQ:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:CPU${cpu}_SIQ:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:CPU${cpu}_WAI:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    }
    
    # Network total
    push @options, 'DS:NET_RECV:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    push @options, 'DS:NET_SEND:GAUGE:5:U:U';
    push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    
    # Network individual
    foreach my $net (sort keys %index_net) {
        push @options, "DS:NET_${net}_RECV:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
        
        push @options, "DS:NET_${net}_SEND:GAUGE:5:U:U";
        push @options, "RRA:AVERAGE:0.5:${steps}:${rows}";
    }
    
    RRDs::create($rrd_file, @options);
    
    if (my $error = RRDs::error) {
        die $error;
    }
}

sub update_rrd {
    my @entries;
    
    foreach my $row (@data) {
        my $entry = '';
        my @cols = parse_line(',', 0, $row);
        
        $entry .= $epoch + &get_unixtime($year, $cols[0]) - $start_time;
        
        # Processes
        $entry .= ":${cols[1]}:${cols[2]}:${cols[3]}";
        
        # Memory
        $entry .= ":${cols[4]}:${cols[5]}:${cols[6]}";
        
        # Paging
        $entry .= ":${cols[8]}:${cols[9]}";
        
        # Disk total
        my ($disk_read, $disk_writ) = (0, 0);
        
        foreach my $disk (keys %index_disk) {
            $disk_read += $cols[$index_disk{$disk}];
            $disk_writ += $cols[$index_disk{$disk} + 1];
        }
        
        $entry .= ":${disk_read}:${disk_writ}";
        
        # Disk individual
        foreach my $disk (sort keys %index_disk) {
            $disk_read = $cols[$index_disk{$disk}];
            $disk_writ = $cols[$index_disk{$disk} + 1];
            
            $entry .= ":${disk_read}:${disk_writ}";
        }
        
        # Interrupts
        $entry .= ":${cols[${index_cpu{'0'}} - 2]}";
        
        # Context Switches
        $entry .= ":${cols[${index_cpu{'0'}} - 1]}";
        
        # CPU total
        my ($cpu_usr, $cpu_sys, $cpu_hiq, $cpu_siq, $cpu_wai) = (0, 0, 0, 0, 0);
        
        foreach my $cpu (keys %index_cpu) {
            $cpu_usr += $cols[$index_cpu{$cpu}];
            $cpu_sys += $cols[$index_cpu{$cpu} + 1];
            $cpu_hiq += $cols[$index_cpu{$cpu} + 4];
            $cpu_siq += $cols[$index_cpu{$cpu} + 5];
            $cpu_wai += $cols[$index_cpu{$cpu} + 3];
        }
        
        $cpu_usr /= scalar(keys %index_cpu);
        $cpu_sys /= scalar(keys %index_cpu);
        $cpu_hiq /= scalar(keys %index_cpu);
        $cpu_siq /= scalar(keys %index_cpu);
        $cpu_wai /= scalar(keys %index_cpu);
        
        $entry .= ":${cpu_usr}:${cpu_sys}:${cpu_hiq}:${cpu_siq}:${cpu_wai}";
        
        # CPU individual
        foreach my $cpu (sort { $a <=> $b } keys %index_cpu) {
            $cpu_usr = $cols[$index_cpu{$cpu}];
            $cpu_sys = $cols[$index_cpu{$cpu} + 1];
            $cpu_hiq = $cols[$index_cpu{$cpu} + 4];
            $cpu_siq = $cols[$index_cpu{$cpu} + 5];
            $cpu_wai = $cols[$index_cpu{$cpu} + 3];
            $entry .= ":${cpu_usr}:${cpu_sys}:${cpu_hiq}:${cpu_siq}:${cpu_wai}";
        }
        
        # Network total
        my ($net_recv, $net_send) = (0, 0);
        
        foreach my $net (keys %index_net) {
            $net_recv += $cols[$index_net{$net}];
            $net_send += $cols[$index_net{$net} + 1];
        }
        
        $entry .= ":${net_recv}:${net_send}";
        
        # Network individual
        foreach my $net (sort keys %index_net) {
            $net_recv = $cols[$index_net{$net}];
            $net_send = $cols[$index_net{$net} + 1];
            
            $entry .= ":${net_recv}:${net_send}";
        }
        
        push @entries, $entry;
    }
    
    RRDs::update($rrd_file, @entries);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
}

sub create_dir {
    eval {
        mkpath($report_dir);
    };
    
    if ($@) {
        &delete_rrd();
        die $@;
    }
}

sub create_graph {
    my (@template, @options, @values);
    my $window = (floor(($end_time - $start_time) / 3600) + 1) * 60;
    
    # Template
    push @template, '--start';
    push @template, $epoch;
    
    push @template, '--end';
    push @template, $epoch + $end_time - $start_time;
    
    push @template, '--width';
    push @template, $width;
    
    push @template, '--height';
    push @template, $height;
    
    push @template, '--lower-limit';
    push @template, 0;
    
    push @template, '--rigid';
    
    # Processes running
    @options = @template;
    
    push @options, '--title';
    push @options, 'Processes running';
    
    push @options, "DEF:RUN=${rrd_file}:PROCS_RUN:AVERAGE";
    push @options, "AREA:RUN#${colors[0]}:running";
    
    push @options, "CDEF:RUN_AVG=RUN,${window},TREND";
    push @options, "LINE1:RUN_AVG#${colors[1]}:running_${window}seconds";
    
    push @options, "VDEF:MIN=RUN,MINIMUM";
    push @options, "PRINT:MIN:%4.2lf";
    push @options, "VDEF:AVG=RUN,AVERAGE";
    push @options, "PRINT:AVG:%4.2lf";
    push @options, "VDEF:MAX=RUN,MAXIMUM";
    push @options, "PRINT:MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/procs_run.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'PROCS_RUN'}->{'MIN'} = $values[0]->[0];
    $value{'PROCS_RUN'}->{'AVG'} = $values[0]->[1];
    $value{'PROCS_RUN'}->{'MAX'} = $values[0]->[2];
    
    # Processes blocked
    @options = @template;
    
    push @options, '--title';
    push @options, 'Processes blocked';
    
    push @options, "DEF:BLK=${rrd_file}:PROCS_BLK:AVERAGE";
    push @options, "AREA:BLK#${colors[0]}:blocked";
    
    push @options, "CDEF:BLK_AVG=BLK,${window},TREND";
    push @options, "LINE1:BLK_AVG#${colors[1]}:blocked_${window}seconds";
    
    push @options, "VDEF:MIN=BLK,MINIMUM";
    push @options, "PRINT:MIN:%4.2lf";
    push @options, "VDEF:AVG=BLK,AVERAGE";
    push @options, "PRINT:AVG:%4.2lf";
    push @options, "VDEF:MAX=BLK,MAXIMUM";
    push @options, "PRINT:MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/procs_blk.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'PROCS_BLK'}->{'MIN'} = $values[0]->[0];
    $value{'PROCS_BLK'}->{'AVG'} = $values[0]->[1];
    $value{'PROCS_BLK'}->{'MAX'} = $values[0]->[2];
    
    # Processes new
    @options = @template;
    
    push @options, '--title';
    push @options, 'Processes new (/second)';
    
    push @options, "DEF:NEW=${rrd_file}:PROCS_NEW:AVERAGE";
    push @options, "AREA:NEW#${colors[0]}:new";
    
    push @options, "CDEF:NEW_AVG=NEW,${window},TREND";
    push @options, "LINE1:NEW_AVG#${colors[1]}:new_${window}seconds";
    
    push @options, "VDEF:MIN=NEW,MINIMUM";
    push @options, "PRINT:MIN:%4.2lf";
    push @options, "VDEF:AVG=NEW,AVERAGE";
    push @options, "PRINT:AVG:%4.2lf";
    push @options, "VDEF:MAX=NEW,MAXIMUM";
    push @options, "PRINT:MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/procs_new.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'PROCS_NEW'}->{'MIN'} = $values[0]->[0];
    $value{'PROCS_NEW'}->{'AVG'} = $values[0]->[1];
    $value{'PROCS_NEW'}->{'MAX'} = $values[0]->[2];
    
    # Memory
    @options = @template;
    
    push @options, '--upper-limit';
    push @options, $memory_size;
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Memory Usage (Bytes)';
    
    push @options, "DEF:USED=${rrd_file}:MEMORY_USED:AVERAGE";
    push @options, "AREA:USED#${colors[0]}:used";
    
    push @options, "DEF:BUFF=${rrd_file}:MEMORY_BUFF:AVERAGE";
    push @options, "STACK:BUFF#${colors[1]}:buffer";
    
    push @options, "DEF:CACH=${rrd_file}:MEMORY_CACH:AVERAGE";
    push @options, "STACK:CACH#${colors[2]}:cached";
    
    push @options, "VDEF:U_MIN=USED,MINIMUM";
    push @options, "PRINT:U_MIN:%4.2lf %s";
    push @options, "VDEF:U_AVG=USED,AVERAGE";
    push @options, "PRINT:U_AVG:%4.2lf %s";
    push @options, "VDEF:U_MAX=USED,MAXIMUM";
    push @options, "PRINT:U_MAX:%4.2lf %s";
    
    push @options, "CDEF:UBC=USED,BUFF,+,CACH,+";
    push @options, "VDEF:UBC_MIN=UBC,MINIMUM";
    push @options, "PRINT:UBC_MIN:%4.2lf %s";
    push @options, "VDEF:UBC_AVG=UBC,AVERAGE";
    push @options, "PRINT:UBC_AVG:%4.2lf %s";
    push @options, "VDEF:UBC_MAX=UBC,MAXIMUM";
    push @options, "PRINT:UBC_MAX:%4.2lf %s";
    
    @values = RRDs::graph("${report_dir}/memory.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'MEMORY'}->{'U_MIN'} = $values[0]->[0];
    $value{'MEMORY'}->{'U_AVG'} = $values[0]->[1];
    $value{'MEMORY'}->{'U_MAX'} = $values[0]->[2];
    $value{'MEMORY'}->{'UBC_MIN'} = $values[0]->[3];
    $value{'MEMORY'}->{'UBC_AVG'} = $values[0]->[4];
    $value{'MEMORY'}->{'UBC_MAX'} = $values[0]->[5];
    
    # Paging
    @options = @template;
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Paging (Bytes/second)';
    
    push @options, "DEF:IN=${rrd_file}:PAGE_IN:AVERAGE";
    push @options, "LINE1:IN#${colors[0]}:page_in";
    
    push @options, "DEF:OUT=${rrd_file}:PAGE_OUT:AVERAGE";
    push @options, "LINE1:OUT#${colors[1]}:page_out";
    
    push @options, "VDEF:I_MIN=IN,MINIMUM";
    push @options, "PRINT:I_MIN:%4.2lf %s";
    push @options, "VDEF:I_AVG=IN,AVERAGE";
    push @options, "PRINT:I_AVG:%4.2lf %s";
    push @options, "VDEF:I_MAX=IN,MAXIMUM";
    push @options, "PRINT:I_MAX:%4.2lf %s";
    
    push @options, "VDEF:O_MIN=OUT,MINIMUM";
    push @options, "PRINT:O_MIN:%4.2lf %s";
    push @options, "VDEF:O_AVG=OUT,AVERAGE";
    push @options, "PRINT:O_AVG:%4.2lf %s";
    push @options, "VDEF:O_MAX=OUT,MAXIMUM";
    push @options, "PRINT:O_MAX:%4.2lf %s";
    
    @values = RRDs::graph("${report_dir}/paging.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'PAGE'}->{'I_MIN'} = $values[0]->[0];
    $value{'PAGE'}->{'I_AVG'} = $values[0]->[1];
    $value{'PAGE'}->{'I_MAX'} = $values[0]->[2];
    $value{'PAGE'}->{'O_MIN'} = $values[0]->[3];
    $value{'PAGE'}->{'O_AVG'} = $values[0]->[4];
    $value{'PAGE'}->{'O_MAX'} = $values[0]->[5];
    
    # Disk total
    @options = @template;
    
    if ($disk_limit != 0) {
        push @options, '--upper-limit';
        push @options, $disk_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Disk I/O total (Bytes/second)';
    
    push @options, "DEF:READ=${rrd_file}:DISK_READ:AVERAGE";
    push @options, "LINE1:READ#${colors[0]}:read";
    
    push @options, "DEF:WRIT=${rrd_file}:DISK_WRIT:AVERAGE";
    push @options, "LINE1:WRIT#${colors[1]}:write";
    
    push @options, "VDEF:R_MIN=READ,MINIMUM";
    push @options, "PRINT:R_MIN:%4.2lf %s";
    push @options, "VDEF:R_AVG=READ,AVERAGE";
    push @options, "PRINT:R_AVG:%4.2lf %s";
    push @options, "VDEF:R_MAX=READ,MAXIMUM";
    push @options, "PRINT:R_MAX:%4.2lf %s";
    
    push @options, "VDEF:W_MIN=WRIT,MINIMUM";
    push @options, "PRINT:W_MIN:%4.2lf %s";
    push @options, "VDEF:W_AVG=WRIT,AVERAGE";
    push @options, "PRINT:W_AVG:%4.2lf %s";
    push @options, "VDEF:W_MAX=WRIT,MAXIMUM";
    push @options, "PRINT:W_MAX:%4.2lf %s";
    
    @values = RRDs::graph("${report_dir}/disk_rw.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'DISK'}->{'R_MIN'} = $values[0]->[0];
    $value{'DISK'}->{'R_AVG'} = $values[0]->[1];
    $value{'DISK'}->{'R_MAX'} = $values[0]->[2];
    $value{'DISK'}->{'W_MIN'} = $values[0]->[3];
    $value{'DISK'}->{'W_AVG'} = $values[0]->[4];
    $value{'DISK'}->{'W_MAX'} = $values[0]->[5];
    
    # read
    @options = @template;
    
    if ($disk_limit != 0) {
        push @options, '--upper-limit';
        push @options, $disk_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Disk I/O total read (Bytes/second)';
    
    push @options, "DEF:READ=${rrd_file}:DISK_READ:AVERAGE";
    push @options, "AREA:READ#${colors[0]}:read";
    
    push @options, "CDEF:READ_AVG=READ,${window},TREND";
    push @options, "LINE1:READ_AVG#${colors[1]}:read_${window}seconds";
    
    RRDs::graph("${report_dir}/disk_r.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    # write
    @options = @template;
    
    if ($disk_limit != 0) {
        push @options, '--upper-limit';
        push @options, $disk_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Disk I/O total write (Bytes/second)';
    
    push @options, "DEF:WRIT=${rrd_file}:DISK_WRIT:AVERAGE";
    push @options, "AREA:WRIT#${colors[0]}:write";
    
    push @options, "CDEF:WRIT_AVG=WRIT,${window},TREND";
    push @options, "LINE1:WRIT_AVG#${colors[1]}:write_${window}seconds";
    
    RRDs::graph("${report_dir}/disk_w.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    # Disk individual
    foreach my $disk (sort keys %index_disk) {
        @options = @template;
        
        if ($disk_limit != 0) {
            push @options, '--upper-limit';
            push @options, $disk_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Disk I/O ${disk} (Bytes/second)";
        
        push @options, "DEF:READ=${rrd_file}:DISK_${disk}_READ:AVERAGE";
        push @options, "LINE1:READ#${colors[0]}:read";
        
        push @options, "DEF:WRIT=${rrd_file}:DISK_${disk}_WRIT:AVERAGE";
        push @options, "LINE1:WRIT#${colors[1]}:write";
        
        push @options, "VDEF:R_MIN=READ,MINIMUM";
        push @options, "PRINT:R_MIN:%4.2lf %s";
        push @options, "VDEF:R_AVG=READ,AVERAGE";
        push @options, "PRINT:R_AVG:%4.2lf %s";
        push @options, "VDEF:R_MAX=READ,MAXIMUM";
        push @options, "PRINT:R_MAX:%4.2lf %s";
        
        push @options, "VDEF:W_MIN=WRIT,MINIMUM";
        push @options, "PRINT:W_MIN:%4.2lf %s";
        push @options, "VDEF:W_AVG=WRIT,AVERAGE";
        push @options, "PRINT:W_AVG:%4.2lf %s";
        push @options, "VDEF:W_MAX=WRIT,MAXIMUM";
        push @options, "PRINT:W_MAX:%4.2lf %s";
        
        @values = RRDs::graph("${report_dir}/disk_${disk}_rw.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
        
        $value{"DISK_${disk}"}->{'R_MIN'} = $values[0]->[0];
        $value{"DISK_${disk}"}->{'R_AVG'} = $values[0]->[1];
        $value{"DISK_${disk}"}->{'R_MAX'} = $values[0]->[2];
        $value{"DISK_${disk}"}->{'W_MIN'} = $values[0]->[3];
        $value{"DISK_${disk}"}->{'W_AVG'} = $values[0]->[4];
        $value{"DISK_${disk}"}->{'W_MAX'} = $values[0]->[5];
        
        # read
        @options = @template;
        
        if ($disk_limit != 0) {
            push @options, '--upper-limit';
            push @options, $disk_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Disk I/O ${disk} read (Bytes/second)";
        
        push @options, "DEF:READ=${rrd_file}:DISK_${disk}_READ:AVERAGE";
        push @options, "AREA:READ#${colors[0]}:read";
        
        push @options, "CDEF:READ_AVG=READ,${window},TREND";
        push @options, "LINE1:READ_AVG#${colors[1]}:read_${window}seconds";
        
        RRDs::graph("${report_dir}/disk_${disk}_r.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
        
        # write
        @options = @template;
        
        if ($disk_limit != 0) {
            push @options, '--upper-limit';
            push @options, $disk_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Disk I/O ${disk} write (Bytes/second)";
        
        push @options, "DEF:WRIT=${rrd_file}:DISK_${disk}_WRIT:AVERAGE";
        push @options, "AREA:WRIT#${colors[0]}:write";
        
        push @options, "CDEF:WRIT_AVG=WRIT,${window},TREND";
        push @options, "LINE1:WRIT_AVG#${colors[1]}:write_${window}seconds";
        
        RRDs::graph("${report_dir}/disk_${disk}_w.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
    }
    
    # Interrupts
    @options = @template;
    
    push @options, '--title';
    push @options, 'Interrupts (/second)';
    
    push @options, "DEF:INT=${rrd_file}:INTERRUPTS:AVERAGE";
    push @options, "AREA:INT#${colors[0]}:interrupts";
    
    push @options, "CDEF:INT_AVG=INT,${window},TREND";
    push @options, "LINE1:INT_AVG#${colors[1]}:interrupts_${window}seconds";
    
    push @options, "VDEF:MIN=INT,MINIMUM";
    push @options, "PRINT:MIN:%4.2lf";
    push @options, "VDEF:AVG=INT,AVERAGE";
    push @options, "PRINT:AVG:%4.2lf";
    push @options, "VDEF:MAX=INT,MAXIMUM";
    push @options, "PRINT:MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/interrupts.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'INTERRUPTS'}->{'MIN'} = $values[0]->[0];
    $value{'INTERRUPTS'}->{'AVG'} = $values[0]->[1];
    $value{'INTERRUPTS'}->{'MAX'} = $values[0]->[2];
    
    # Context Switches
    @options = @template;
    
    push @options, '--title';
    push @options, 'Context Switches (/second)';
    
    push @options, "DEF:CSW=${rrd_file}:CSWITCHES:AVERAGE";
    push @options, "AREA:CSW#${colors[0]}:context_switches";
    
    push @options, "CDEF:CSW_AVG=CSW,${window},TREND";
    push @options, "LINE1:CSW_AVG#${colors[1]}:context_switches_${window}seconds";
    
    push @options, "VDEF:MIN=CSW,MINIMUM";
    push @options, "PRINT:MIN:%4.2lf";
    push @options, "VDEF:AVG=CSW,AVERAGE";
    push @options, "PRINT:AVG:%4.2lf";
    push @options, "VDEF:MAX=CSW,MAXIMUM";
    push @options, "PRINT:MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/cswitches.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'CSWITCHES'}->{'MIN'} = $values[0]->[0];
    $value{'CSWITCHES'}->{'AVG'} = $values[0]->[1];
    $value{'CSWITCHES'}->{'MAX'} = $values[0]->[2];
    
    # CPU total
    @options = @template;
    
    push @options, '--upper-limit';
    push @options, 100;
    
    push @options, '--title';
    push @options, 'CPU Usage total (%)';
    
    push @options, "DEF:USR=${rrd_file}:CPU_USR:AVERAGE";
    push @options, "AREA:USR#${colors[0]}:user";
    
    push @options, "DEF:SYS=${rrd_file}:CPU_SYS:AVERAGE";
    push @options, "STACK:SYS#${colors[1]}:system";
    
    push @options, "DEF:HIQ=${rrd_file}:CPU_HIQ:AVERAGE";
    push @options, "STACK:HIQ#${colors[2]}:hardirq";
    
    push @options, "DEF:SIQ=${rrd_file}:CPU_SIQ:AVERAGE";
    push @options, "STACK:SIQ#${colors[3]}:softirq";
    
    push @options, "DEF:WAI=${rrd_file}:CPU_WAI:AVERAGE";
    push @options, "STACK:WAI#${colors[4]}:wait";
    
    push @options, "VDEF:U_MIN=USR,MINIMUM";
    push @options, "PRINT:U_MIN:%4.2lf";
    push @options, "VDEF:U_AVG=USR,AVERAGE";
    push @options, "PRINT:U_AVG:%4.2lf";
    push @options, "VDEF:U_MAX=USR,MAXIMUM";
    push @options, "PRINT:U_MAX:%4.2lf";
    
    push @options, "CDEF:US=USR,SYS,+";
    push @options, "VDEF:US_MIN=US,MINIMUM";
    push @options, "PRINT:US_MIN:%4.2lf";
    push @options, "VDEF:US_AVG=US,AVERAGE";
    push @options, "PRINT:US_AVG:%4.2lf";
    push @options, "VDEF:US_MAX=US,MAXIMUM";
    push @options, "PRINT:US_MAX:%4.2lf";
    
    push @options, "CDEF:USHS=USR,SYS,+,HIQ,+,SIQ,+";
    push @options, "VDEF:USHS_MIN=USHS,MINIMUM";
    push @options, "PRINT:USHS_MIN:%4.2lf";
    push @options, "VDEF:USHS_AVG=USHS,AVERAGE";
    push @options, "PRINT:USHS_AVG:%4.2lf";
    push @options, "VDEF:USHS_MAX=USHS,MAXIMUM";
    push @options, "PRINT:USHS_MAX:%4.2lf";
    
    push @options, "CDEF:USHSW=USR,SYS,+,HIQ,+,SIQ,+,WAI,+";
    push @options, "VDEF:USHSW_MIN=USHSW,MINIMUM";
    push @options, "PRINT:USHSW_MIN:%4.2lf";
    push @options, "VDEF:USHSW_AVG=USHSW,AVERAGE";
    push @options, "PRINT:USHSW_AVG:%4.2lf";
    push @options, "VDEF:USHSW_MAX=USHSW,MAXIMUM";
    push @options, "PRINT:USHSW_MAX:%4.2lf";
    
    @values = RRDs::graph("${report_dir}/cpu.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'CPU'}->{'U_MIN'} = $values[0]->[0];
    $value{'CPU'}->{'U_AVG'} = $values[0]->[1];
    $value{'CPU'}->{'U_MAX'} = $values[0]->[2];
    $value{'CPU'}->{'US_MIN'} = $values[0]->[3];
    $value{'CPU'}->{'US_AVG'} = $values[0]->[4];
    $value{'CPU'}->{'US_MAX'} = $values[0]->[5];
    $value{'CPU'}->{'USHS_MIN'} = $values[0]->[6];
    $value{'CPU'}->{'USHS_AVG'} = $values[0]->[7];
    $value{'CPU'}->{'USHS_MAX'} = $values[0]->[8];
    $value{'CPU'}->{'USHSW_MIN'} = $values[0]->[9];
    $value{'CPU'}->{'USHSW_AVG'} = $values[0]->[10];
    $value{'CPU'}->{'USHSW_MAX'} = $values[0]->[11];
    
    # CPU individual
    foreach my $cpu (sort { $a <=> $b } keys %index_cpu) {
        @options = @template;
        
        push @options, '--upper-limit';
        push @options, 100;
        
        push @options, '--title';
        push @options, "CPU Usage cpu${cpu} (%)";
        
        push @options, "DEF:USR=${rrd_file}:CPU${cpu}_USR:AVERAGE";
        push @options, "AREA:USR#${colors[0]}:user";
        
        push @options, "DEF:SYS=${rrd_file}:CPU${cpu}_SYS:AVERAGE";
        push @options, "STACK:SYS#${colors[1]}:system";
        
        push @options, "DEF:HIQ=${rrd_file}:CPU${cpu}_HIQ:AVERAGE";
        push @options, "STACK:HIQ#${colors[2]}:hardirq";
        
        push @options, "DEF:SIQ=${rrd_file}:CPU${cpu}_SIQ:AVERAGE";
        push @options, "STACK:SIQ#${colors[3]}:softirq";
        
        push @options, "DEF:WAI=${rrd_file}:CPU${cpu}_WAI:AVERAGE";
        push @options, "STACK:WAI#${colors[4]}:wait";
        
        push @options, "VDEF:U_MIN=USR,MINIMUM";
        push @options, "PRINT:U_MIN:%4.2lf";
        push @options, "VDEF:U_AVG=USR,AVERAGE";
        push @options, "PRINT:U_AVG:%4.2lf";
        push @options, "VDEF:U_MAX=USR,MAXIMUM";
        push @options, "PRINT:U_MAX:%4.2lf";
        
        push @options, "CDEF:US=USR,SYS,+";
        push @options, "VDEF:US_MIN=US,MINIMUM";
        push @options, "PRINT:US_MIN:%4.2lf";
        push @options, "VDEF:US_AVG=US,AVERAGE";
        push @options, "PRINT:US_AVG:%4.2lf";
        push @options, "VDEF:US_MAX=US,MAXIMUM";
        push @options, "PRINT:US_MAX:%4.2lf";
        
        push @options, "CDEF:USHS=USR,SYS,+,HIQ,+,SIQ,+";
        push @options, "VDEF:USHS_MIN=USHS,MINIMUM";
        push @options, "PRINT:USHS_MIN:%4.2lf";
        push @options, "VDEF:USHS_AVG=USHS,AVERAGE";
        push @options, "PRINT:USHS_AVG:%4.2lf";
        push @options, "VDEF:USHS_MAX=USHS,MAXIMUM";
        push @options, "PRINT:USHS_MAX:%4.2lf";
        
        push @options, "CDEF:USHSW=USR,SYS,+,HIQ,+,SIQ,+,WAI,+";
        push @options, "VDEF:USHSW_MIN=USHSW,MINIMUM";
        push @options, "PRINT:USHSW_MIN:%4.2lf";
        push @options, "VDEF:USHSW_AVG=USHSW,AVERAGE";
        push @options, "PRINT:USHSW_AVG:%4.2lf";
        push @options, "VDEF:USHSW_MAX=USHSW,MAXIMUM";
        push @options, "PRINT:USHSW_MAX:%4.2lf";
        
        @values = RRDs::graph("${report_dir}/cpu${cpu}.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
        
        $value{"CPU${cpu}"}->{'U_MIN'} = $values[0]->[0];
        $value{"CPU${cpu}"}->{'U_AVG'} = $values[0]->[1];
        $value{"CPU${cpu}"}->{'U_MAX'} = $values[0]->[2];
        $value{"CPU${cpu}"}->{'US_MIN'} = $values[0]->[3];
        $value{"CPU${cpu}"}->{'US_AVG'} = $values[0]->[4];
        $value{"CPU${cpu}"}->{'US_MAX'} = $values[0]->[5];
        $value{"CPU${cpu}"}->{'USHS_MIN'} = $values[0]->[6];
        $value{"CPU${cpu}"}->{'USHS_AVG'} = $values[0]->[7];
        $value{"CPU${cpu}"}->{'USHS_MAX'} = $values[0]->[8];
        $value{"CPU${cpu}"}->{'USHSW_MIN'} = $values[0]->[9];
        $value{"CPU${cpu}"}->{'USHSW_AVG'} = $values[0]->[10];
        $value{"CPU${cpu}"}->{'USHSW_MAX'} = $values[0]->[11];
    }
    
    # Network total
    @options = @template;
    
    if ($net_limit != 0) {
        push @options, '--upper-limit';
        push @options, $net_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Network I/O total (Bytes/second)';
    
    push @options, "DEF:RECV=${rrd_file}:NET_RECV:AVERAGE";
    push @options, "LINE1:RECV#${colors[0]}:receive";
    
    push @options, "DEF:SEND=${rrd_file}:NET_SEND:AVERAGE";
    push @options, "LINE1:SEND#${colors[1]}:send";
    
    push @options, "VDEF:R_MIN=RECV,MINIMUM";
    push @options, "PRINT:R_MIN:%4.2lf %s";
    push @options, "VDEF:R_AVG=RECV,AVERAGE";
    push @options, "PRINT:R_AVG:%4.2lf %s";
    push @options, "VDEF:R_MAX=RECV,MAXIMUM";
    push @options, "PRINT:R_MAX:%4.2lf %s";
    
    push @options, "VDEF:S_MIN=SEND,MINIMUM";
    push @options, "PRINT:S_MIN:%4.2lf %s";
    push @options, "VDEF:S_AVG=SEND,AVERAGE";
    push @options, "PRINT:S_AVG:%4.2lf %s";
    push @options, "VDEF:S_MAX=SEND,MAXIMUM";
    push @options, "PRINT:S_MAX:%4.2lf %s";
    
    @values = RRDs::graph("${report_dir}/net_rs.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    $value{'NET'}->{'R_MIN'} = $values[0]->[0];
    $value{'NET'}->{'R_AVG'} = $values[0]->[1];
    $value{'NET'}->{'R_MAX'} = $values[0]->[2];
    $value{'NET'}->{'S_MIN'} = $values[0]->[3];
    $value{'NET'}->{'S_AVG'} = $values[0]->[4];
    $value{'NET'}->{'S_MAX'} = $values[0]->[5];
    
    # receive
    @options = @template;
    
    if ($net_limit != 0) {
        push @options, '--upper-limit';
        push @options, $net_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Network I/O total receive (Bytes/second)';
    
    push @options, "DEF:RECV=${rrd_file}:NET_RECV:AVERAGE";
    push @options, "AREA:RECV#${colors[0]}:receive";
    
    push @options, "CDEF:RECV_AVG=RECV,${window},TREND";
    push @options, "LINE1:RECV_AVG#${colors[1]}:receive_${window}seconds";
    
    RRDs::graph("${report_dir}/net_r.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    # send
    @options = @template;
    
    if ($net_limit != 0) {
        push @options, '--upper-limit';
        push @options, $net_limit;
    }
    
    push @options, '--base';
    push @options, 1024;
    
    push @options, '--title';
    push @options, 'Network I/O total send (Bytes/second)';
    
    push @options, "DEF:SEND=${rrd_file}:NET_SEND:AVERAGE";
    push @options, "AREA:SEND#${colors[0]}:send";
    
    push @options, "CDEF:SEND_AVG=SEND,${window},TREND";
    push @options, "LINE1:SEND_AVG#${colors[1]}:send_${window}seconds";
    
    RRDs::graph("${report_dir}/net_s.png", @options);
    
    if (my $error = RRDs::error) {
        &delete_rrd();
        die $error;
    }
    
    # Network individual
    foreach my $net (sort keys %index_net) {
        @options = @template;
        
        if ($net_limit != 0) {
            push @options, '--upper-limit';
            push @options, $net_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Network I/O ${net} (Bytes/second)";
        
        push @options, "DEF:RECV=${rrd_file}:NET_${net}_RECV:AVERAGE";
        push @options, "LINE1:RECV#${colors[0]}:receive";
        
        push @options, "DEF:SEND=${rrd_file}:NET_${net}_SEND:AVERAGE";
        push @options, "LINE1:SEND#${colors[1]}:send";
        
        push @options, "VDEF:R_MIN=RECV,MINIMUM";
        push @options, "PRINT:R_MIN:%4.2lf %s";
        push @options, "VDEF:R_AVG=RECV,AVERAGE";
        push @options, "PRINT:R_AVG:%4.2lf %s";
        push @options, "VDEF:R_MAX=RECV,MAXIMUM";
        push @options, "PRINT:R_MAX:%4.2lf %s";
        
        push @options, "VDEF:S_MIN=SEND,MINIMUM";
        push @options, "PRINT:S_MIN:%4.2lf %s";
        push @options, "VDEF:S_AVG=SEND,AVERAGE";
        push @options, "PRINT:S_AVG:%4.2lf %s";
        push @options, "VDEF:S_MAX=SEND,MAXIMUM";
        push @options, "PRINT:S_MAX:%4.2lf %s";
        
        @values = RRDs::graph("${report_dir}/net_${net}_rs.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
        
        $value{"NET_${net}"}->{'R_MIN'} = $values[0]->[0];
        $value{"NET_${net}"}->{'R_AVG'} = $values[0]->[1];
        $value{"NET_${net}"}->{'R_MAX'} = $values[0]->[2];
        $value{"NET_${net}"}->{'S_MIN'} = $values[0]->[3];
        $value{"NET_${net}"}->{'S_AVG'} = $values[0]->[4];
        $value{"NET_${net}"}->{'S_MAX'} = $values[0]->[5];
        
        # receive
        @options = @template;
        
        if ($net_limit != 0) {
            push @options, '--upper-limit';
            push @options, $net_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Network I/O ${net} receive (Bytes/second)";
        
        push @options, "DEF:RECV=${rrd_file}:NET_${net}_RECV:AVERAGE";
        push @options, "AREA:RECV#${colors[0]}:receive";
        
        push @options, "CDEF:RECV_AVG=RECV,${window},TREND";
        push @options, "LINE1:RECV_AVG#${colors[1]}:receive_${window}seconds";
        
        RRDs::graph("${report_dir}/net_${net}_r.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
        
        # send
        @options = @template;
        
        if ($net_limit != 0) {
            push @options, '--upper-limit';
            push @options, $net_limit;
        }
        
        push @options, '--base';
        push @options, 1024;
        
        push @options, '--title';
        push @options, "Network I/O ${net} send (Bytes/second)";
        
        push @options, "DEF:SEND=${rrd_file}:NET_${net}_SEND:AVERAGE";
        push @options, "AREA:SEND#${colors[0]}:send";
        
        push @options, "CDEF:SEND_AVG=SEND,${window},TREND";
        push @options, "LINE1:SEND_AVG#${colors[1]}:send_${window}seconds";
        
        RRDs::graph("${report_dir}/net_${net}_s.png", @options);
        
        if (my $error = RRDs::error) {
            &delete_rrd();
            die $error;
        }
    }
}

sub delete_rrd {
    unlink $rrd_file;
}

sub create_html {
    my $report_hostname = encode_entities($hostname);
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($start_time);
    
    my $report_datetime = sprintf("%04d/%02d/%02d %02d:%02d:%02d",
        $year + 1900, $mon + 1, $mday, $hour, $min, $sec); 
    
    my $report_duration = $end_time - $start_time;
    my ($report_suffix) = $report_dir =~ /([^\/]+)\/*$/;
    
    open(my $fh, '>', "${report_dir}/index.html") or die $!;
    
    print $fh <<_EOF_;
<!DOCTYPE html>
<html>
  <head>
    <title>${report_hostname} ${report_datetime} - dstat2graphs</title>
    <link href="${top_dir}/css/bootstrap.min.css" rel="stylesheet" />
    <style type="text/css">
      body {
        padding-top: 20px;
        padding-bottom: 20px;
      }
      .sidebar-nav {
        padding: 12px 4px;
      }
      .hero-unit {
        padding: 24px;
      }
      th.header {
        text-align: center;
      }
      td.number {
        text-align: right;
      }
    </style>
  </head>
  <body>
    <div class="container-fluid">
      <div class="row-fluid">
        <div class="span3">
          <div class="well sidebar-nav">
            <ul class="nav nav-list">
              <li class="nav-header">Processes</li>
              <li><a href="#procs_run">Processes running</a></li>
              <li><a href="#procs_blk">Processes blocked</a></li>
              <li><a href="#procs_new">Processes new</a></li>
              <li class="nav-header">Memory Usage</li>
              <li><a href="#memory">Memory Usage</a></li>
              <li class="nav-header">Paging</li>
              <li><a href="#paging">Paging</a></li>
              <li class="nav-header">Disk I/O</li>
              <li><a href="#disk">Disk I/O total</a></li>
_EOF_
    
    foreach my $disk (sort keys %index_disk) {
        print $fh ' ' x 14;
        print $fh "<li><a href=\"#disk_${disk}\">Disk I/O ${disk}</a></li>\n";
    }
    
    print $fh <<_EOF_;
              <li class="nav-header">System</li>
              <li><a href="#interrupts">Interrupts</a></li>
              <li><a href="#cswitches">Context Switches</a></li>
              <li class="nav-header">CPU Usage</li>
              <li><a href="#cpu">CPU Usage total</a></li>
_EOF_
    
    foreach my $cpu (sort { $a <=> $b } keys %index_cpu) {
        print $fh ' ' x 14;
        print $fh "<li><a href=\"#cpu${cpu}\">CPU Usage cpu${cpu}</a></li>\n";
    }
    
    print $fh <<_EOF_;
              <li class="nav-header">Network I/O</li>
              <li><a href="#net">Network I/O total</a></li>
_EOF_
    
    foreach my $net (sort keys %index_net) {
        print $fh ' ' x 14;
        print $fh "<li><a href=\"#net_${net}\">Network I/O ${net}</a></li>\n";
    }
    
    print $fh <<_EOF_;
            </ul>
          </div>
        </div>
        <div class="span9">
          <div class="hero-unit">
            <h1>dstat2graphs</h1>
            <ul>
              <li>Hostname: ${report_hostname}</li>
              <li>Datetime: ${report_datetime}</li>
              <li>Duration: ${report_duration} (Seconds)</li>
            </ul>
          </div>
          <p><a href="d_${report_suffix}.zip">Download a Zip file</a></p>
          <h2>Processes</h2>
          <h3 id="procs_run">Processes running</h3>
          <p><img src="procs_run.png" alt="Processes running" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Processes running</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>running</td>
                <td class="number">$value{'PROCS_RUN'}->{'MIN'}</td>
                <td class="number">$value{'PROCS_RUN'}->{'AVG'}</td>
                <td class="number">$value{'PROCS_RUN'}->{'MAX'}</td>
              </tr>
            </tbody>
          </table>
          <h3 id="procs_blk">Processes blocked</h3>
          <p><img src="procs_blk.png" alt="Processes blocked" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Processes blocked</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>blocked</td>
                <td class="number">$value{'PROCS_BLK'}->{'MIN'}</td>
                <td class="number">$value{'PROCS_BLK'}->{'AVG'}</td>
                <td class="number">$value{'PROCS_BLK'}->{'MAX'}</td>
              </tr>
            </tbody>
          </table>
          <h3 id="procs_new">Processes new</h3>
          <p><img src="procs_new.png" alt="Processes new" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Processes new (/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>new</td>
                <td class="number">$value{'PROCS_NEW'}->{'MIN'}</td>
                <td class="number">$value{'PROCS_NEW'}->{'AVG'}</td>
                <td class="number">$value{'PROCS_NEW'}->{'MAX'}</td>
              </tr>
            </tbody>
          </table>
          <hr />
          <h2>Memory Usage</h2>
          <h3 id="memory">Memory Usage</h3>
          <p><img src="memory.png" alt="Memory Usage" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Memory Usage (Bytes)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>used</td>
                <td class="number">$value{'MEMORY'}->{'U_MIN'}</td>
                <td class="number">$value{'MEMORY'}->{'U_AVG'}</td>
                <td class="number">$value{'MEMORY'}->{'U_MAX'}</td>
              </tr>
              <tr>
                <td>used+buffer+cached</td>
                <td class="number">$value{'MEMORY'}->{'UBC_MIN'}</td>
                <td class="number">$value{'MEMORY'}->{'UBC_AVG'}</td>
                <td class="number">$value{'MEMORY'}->{'UBC_MAX'}</td>
              </tr>
            </tbody>
          </table>
          <hr />
          <h2>Paging</h2>
          <h3 id="paging">Paging</h3>
          <p><img src="paging.png" alt="Paging" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Paging (Bytes/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>page_in</td>
                <td class="number">$value{'PAGE'}->{'I_MIN'}</td>
                <td class="number">$value{'PAGE'}->{'I_AVG'}</td>
                <td class="number">$value{'PAGE'}->{'I_MAX'}</td>
              </tr>
              <tr>
                <td>page_out</td>
                <td class="number">$value{'PAGE'}->{'O_MIN'}</td>
                <td class="number">$value{'PAGE'}->{'O_AVG'}</td>
                <td class="number">$value{'PAGE'}->{'O_MAX'}</td>
              </tr>
            </tbody>
          </table>
          <hr />
          <h2>Disk I/O</h2>
          <h3 id="disk">Disk I/O total</h3>
          <p><img src="disk_rw.png" alt="Disk I/O total" /></p>
          <p><img src="disk_r.png" alt="Disk I/O total read" /></p>
          <p><img src="disk_w.png" alt="Disk I/O total write" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Disk I/O total (Bytes/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>read</td>
                <td class="number">$value{'DISK'}->{'R_MIN'}</td>
                <td class="number">$value{'DISK'}->{'R_AVG'}</td>
                <td class="number">$value{'DISK'}->{'R_MAX'}</td>
              </tr>
              <tr>
                <td>write</td>
                <td class="number">$value{'DISK'}->{'W_MIN'}</td>
                <td class="number">$value{'DISK'}->{'W_AVG'}</td>
                <td class="number">$value{'DISK'}->{'W_MAX'}</td>
              </tr>
            </tbody>
          </table>
_EOF_
    
    foreach my $disk (sort keys %index_disk) {
        print $fh <<_EOF_;
          <h3 id="disk_${disk}">Disk I/O ${disk}</h3>
          <p><img src="disk_${disk}_rw.png" alt="Disk I/O ${disk}"></p>
          <p><img src="disk_${disk}_r.png" alt="Disk I/O ${disk} read"></p>
          <p><img src="disk_${disk}_w.png" alt="Disk I/O ${disk} write"></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Disk I/O ${disk} (Bytes/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>read</td>
                <td class="number">$value{"DISK_${disk}"}->{'R_MIN'}</td>
                <td class="number">$value{"DISK_${disk}"}->{'R_AVG'}</td>
                <td class="number">$value{"DISK_${disk}"}->{'R_MAX'}</td>
              </tr>
              <tr>
                <td>write</td>
                <td class="number">$value{"DISK_${disk}"}->{'W_MIN'}</td>
                <td class="number">$value{"DISK_${disk}"}->{'W_AVG'}</td>
                <td class="number">$value{"DISK_${disk}"}->{'W_MAX'}</td>
              </tr>
            </tbody>
          </table>
_EOF_
    }
    
    print $fh <<_EOF_;
          <hr />
          <h2>System</h2>
          <h3 id="interrupts">Interrupts</h3>
          <p><img src="interrupts.png" alt="Interrupts" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Interrupts (/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>interrupts</td>
                <td class="number">$value{'INTERRUPTS'}->{'MIN'}</td>
                <td class="number">$value{'INTERRUPTS'}->{'AVG'}</td>
                <td class="number">$value{'INTERRUPTS'}->{'MAX'}</td>
              </tr>
            </tbody>
          </table>
          <h3 id="cswitches">Context Switches</h3>
          <p><img src="cswitches.png" alt="Context Switches" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Context Switches (/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>context_switches</td>
                <td class="number">$value{'CSWITCHES'}->{'MIN'}</td>
                <td class="number">$value{'CSWITCHES'}->{'AVG'}</td>
                <td class="number">$value{'CSWITCHES'}->{'MAX'}</td>
              </tr>
            </tbody>
          </table>
          <hr />
          <h2>CPU Usage</h2>
          <h3 id="cpu">CPU Usage total</h3>
          <p><img src="cpu.png" alt="CPU Usage total" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">CPU Usage total (%)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>user</td>
                <td class="number">$value{'CPU'}->{'U_MIN'} %</td>
                <td class="number">$value{'CPU'}->{'U_AVG'} %</td>
                <td class="number">$value{'CPU'}->{'U_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system</td>
                <td class="number">$value{'CPU'}->{'US_MIN'} %</td>
                <td class="number">$value{'CPU'}->{'US_AVG'} %</td>
                <td class="number">$value{'CPU'}->{'US_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system+hardirq+softirq</td>
                <td class="number">$value{'CPU'}->{'USHS_MIN'} %</td>
                <td class="number">$value{'CPU'}->{'USHS_AVG'} %</td>
                <td class="number">$value{'CPU'}->{'USHS_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system+hardirq+softirq+wait</td>
                <td class="number">$value{'CPU'}->{'USHSW_MIN'} %</td>
                <td class="number">$value{'CPU'}->{'USHSW_AVG'} %</td>
                <td class="number">$value{'CPU'}->{'USHSW_MAX'} %</td>
              </tr>
            </tbody>
          </table>
_EOF_
    
    foreach my $cpu (sort { $a <=> $b } keys %index_cpu) {
        print $fh <<_EOF_;
          <h3 id="cpu${cpu}">CPU Usage cpu${cpu}</h3>
          <p><img src="cpu${cpu}.png" alt="CPU Usage cpu${cpu}" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">CPU Usage cpu${cpu} (%)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>user</td>
                <td class="number">$value{"CPU${cpu}"}->{'U_MIN'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'U_AVG'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'U_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system</td>
                <td class="number">$value{"CPU${cpu}"}->{'US_MIN'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'US_AVG'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'US_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system+hardirq+softirq</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHS_MIN'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHS_AVG'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHS_MAX'} %</td>
              </tr>
              <tr>
                <td>user+system+hardirq+softirq+wait</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHSW_MIN'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHSW_AVG'} %</td>
                <td class="number">$value{"CPU${cpu}"}->{'USHSW_MAX'} %</td>
              </tr>
            </tbody>
          </table>
_EOF_
    }
    
    print $fh <<_EOF_;
          <hr />
          <h2>Network I/O</h2>
          <h3 id="net">Network I/O total</h3>
          <p><img src="net_rs.png" alt="Network I/O total" /></p>
          <p><img src="net_r.png" alt="Network I/O total receive" /></p>
          <p><img src="net_s.png" alt="Network I/O total send" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Network I/O total (Bytes/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>receive</td>
                <td class="number">$value{'NET'}->{'R_MIN'}</td>
                <td class="number">$value{'NET'}->{'R_AVG'}</td>
                <td class="number">$value{'NET'}->{'R_MAX'}</td>
              </tr>
              <tr>
                <td>send</td>
                <td class="number">$value{'NET'}->{'S_MIN'}</td>
                <td class="number">$value{'NET'}->{'S_AVG'}</td>
                <td class="number">$value{'NET'}->{'S_MAX'}</td>
              </tr>
            </tbody>
          </table>
_EOF_
    
    foreach my $net (sort keys %index_net) {
        print $fh <<_EOF_;
          <h3 id="net_${net}">Network I/O ${net}</h3>
          <p><img src="net_${net}_rs.png" alt="Network I/O ${net}" /></p>
          <p><img src="net_${net}_r.png" alt="Network I/O ${net} receive" /></p>
          <p><img src="net_${net}_s.png" alt="Network I/O ${net} send" /></p>
          <table class="table table-condensed">
            <thead>
              <tr>
                <th class="header">Network I/O ${net} (Bytes/second)</th>
                <th class="header">Minimum</th>
                <th class="header">Average</th>
                <th class="header">Maximum</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>receive</td>
                <td class="number">$value{"NET_${net}"}->{'R_MIN'}</td>
                <td class="number">$value{"NET_${net}"}->{'R_AVG'}</td>
                <td class="number">$value{"NET_${net}"}->{'R_MAX'}</td>
              </tr>
              <tr>
                <td>send</td>
                <td class="number">$value{"NET_${net}"}->{'S_MIN'}</td>
                <td class="number">$value{"NET_${net}"}->{'S_AVG'}</td>
                <td class="number">$value{"NET_${net}"}->{'S_MAX'}</td>
              </tr>
            </tbody>
          </table>
_EOF_
    }
    
    print $fh <<_EOF_;
        </div>
      </div>
      <hr />
      <div class="footer">
        (c) 2012-2014, Sadao Hiratsuka.
      </div>
    </div>
    <script src="${top_dir}/js/jquery-1.11.0.min.js"></script>
    <script src="${top_dir}/js/bootstrap.min.js"></script>
  </body>
</html>
_EOF_
    
    close($fh);
}

sub create_zip {
    my ($report_suffix) = $report_dir =~ /([^\/]+)\/*$/;
    my $zip = Archive::Zip->new();
    
    $zip->addTreeMatching($report_dir, $report_suffix, '\.(html|png)$');
    
    if ($zip->writeToFileNamed("${report_dir}/d_${report_suffix}.zip") != AZ_OK) {
        die;
    }
}

sub random_str {
    my $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    my $length = length($chars);
    my $str = '';
    
    for (my $i = 0; $i < 16; $i++) {
        $str .= substr($chars, int(rand($length)), 1);
    }
    
    return $str;
}

sub get_unixtime {
    my ($year, $datetime) = @_;
    my $unixtime = 0;
    
    if ($datetime =~ /^(\d+)-(\d+) (\d+):(\d+):(\d+)/) {
        $unixtime = timelocal($5, $4, $3, $1, $2 -1, $year);
    }
    
    return $unixtime;
}

