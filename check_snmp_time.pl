#!/usr/bin/perl
########################################################################
#
# check_time_snmp.pl v3.4 (2025-12-01)
#
# Purpose:
#   Nagios/Icinga plugin to check device time via SNMP against local time or NTP
#
# Features:
#   - Supports SNMPv1, v2c, and v3
#   - Custom OID support
#   - Flexible time format parsing
#   - Timezone conversion
#   - NTP reference time source
#   - Uses system snmpget command for compatibility
#   - Nagios/Icinga compliant output with perfdata
#
# Version History:
#   v1.0 (2025-08-04) - Initial release
#   v1.1 (2025-08-04) - Added SNMPv3 support
#   v2.0 (2025-08-05) - Major enhancements
#   v3.0 (2025-08-05) - Replaced Net::SNMP with system snmpget
#   v3.1 (2025-08-05) - Improved time string cleaning and parsing
#   v3.2 (2025-08-05) - Fixed thresholds, NTP time, and output format
#   v3.3 (2025-08-05) - Perfdata label fix and precision improvements
#   v3.4 (2025-12-01) - Correct parsing when --time-format is used together with --timezone: create a DateTime from parsed components so the device's timezone is applied correctly (was incorrectly reinterpreting epoch).
#                     - Avoid double/misapplied timezone conversion: timezone conversion block now only runs when time was parsed via the "fallback" branch.
#                     - Support offset timezone strings like +0300 as +03:00 for DateTime::TimeZone.

# Usage Examples:
#   Basic SNMPv2c check:
#     check_time_snmp.pl -H 192.168.1.1 -C public -w 60 -c 180
#
#   SNMPv3 with timezone and NTP:
#     check_time_snmp.pl -H firewall --protocol 3 --username snmp \
#       --authpassword pass --authprotocol MD5 --privpassword pass --privprotocol AES \
#       --oid 1.3.6.1.4.1.34849.1.1.1.3.12.0 --time-format '%a %b %e %H:%M:%S %Y' \
#       --timezone '+0300' --ntp-server srv-ntp.holding.com -w 60 -c 180
#
########################################################################

use strict;
use warnings;
use Getopt::Long;
use Time::Local;
use Time::Piece;
use DateTime;
use DateTime::TimeZone;
use Net::NTP;

# Nagios status constants
my %ERRORS = (
    'OK'       => 0,
    'WARNING'  => 1,
    'CRITICAL' => 2,
    'UNKNOWN'  => 3
);

# Command line parameters
my (
    $opt_host, $opt_port, $opt_community, $opt_warning, $opt_critical,
    $opt_help, $opt_version, $opt_oid, $opt_time_format, $opt_timezone,
    $opt_ntp_server, $opt_ntp_port, $opt_protocol, $opt_username,
    $opt_authpassword, $opt_authprotocol, $opt_privpassword, $opt_privprotocol,
    $opt_verbose
);

GetOptions(
    'host|H=s'          => \$opt_host,
    'port|p=i'          => \$opt_port,
    'community|C=s'     => \$opt_community,
    'warning|w=s'       => \$opt_warning,
    'critical|c=s'      => \$opt_critical,
    'help|h'            => \$opt_help,
    'version|V'         => \$opt_version,
    'oid=s'             => \$opt_oid,
    'time-format=s'     => \$opt_time_format,
    'timezone=s'        => \$opt_timezone,
    'ntp-server=s'      => \$opt_ntp_server,
    'ntp-port=i'        => \$opt_ntp_port,
    'protocol=s'        => \$opt_protocol,
    'username=s'        => \$opt_username,
    'authpassword=s'    => \$opt_authpassword,
    'authprotocol=s'    => \$opt_authprotocol,
    'privpassword=s'    => \$opt_privpassword,
    'privprotocol=s'    => \$opt_privprotocol,
    'verbose'           => \$opt_verbose,
);

# Set default values
$opt_oid           ||= '1.3.6.1.2.1.25.1.2.0';
$opt_ntp_port      ||= 123;
$opt_protocol      ||= '2c';
$opt_port          ||= 161;

# Display help if requested
if ($opt_help) {
    print_help();
    exit $ERRORS{'OK'};
}

# Display version information
if ($opt_version) {
    print "check_time_snmp.pl v3.3 (2025-08-05)\n";
    print "Nagios/Icinga plugin for time synchronization checks\n";
    exit $ERRORS{'OK'};
}

# Validate required parameters
if (!$opt_host || !defined $opt_warning || !defined $opt_critical) {
    print "UNKNOWN: Missing required parameters\n";
    print_help();
    exit $ERRORS{'UNKNOWN'};
}

# Parse threshold ranges
my ($warn_min, $warn_max) = parse_threshold($opt_warning);
my ($crit_min, $crit_max) = parse_threshold($opt_critical);

# Build snmpget command
my $snmpget_cmd = "snmpget";

# Add protocol version
if ($opt_protocol eq '3') {
    $snmpget_cmd .= " -v3";
    
    # SNMPv3 parameters
    if ($opt_username) {
        $snmpget_cmd .= " -u '$opt_username'";
    }
    if ($opt_authprotocol && $opt_authpassword) {
        $snmpget_cmd .= " -a $opt_authprotocol -A '$opt_authpassword'";
    }
    if ($opt_privprotocol && $opt_privpassword) {
        $snmpget_cmd .= " -x $opt_privprotocol -X '$opt_privpassword'";
    }
    if ($opt_authprotocol || $opt_privprotocol) {
        $snmpget_cmd .= " -l authPriv";
    }
} else {
    # SNMPv1/v2c
    $snmpget_cmd .= " -v $opt_protocol";
    $snmpget_cmd .= " -c '$opt_community'" if $opt_community;
}

# Add common parameters
$snmpget_cmd .= " $opt_host";
$snmpget_cmd .= ":$opt_port" if $opt_port && $opt_port != 161;
$snmpget_cmd .= " '$opt_oid'";

# Execute snmpget command
my $snmp_output = `$snmpget_cmd 2>&1`;
my $snmp_exit = $?;

if ($snmp_exit != 0) {
    print "UNKNOWN: SNMP command failed (exit $snmp_exit): $snmp_output\n";
    print "Command: $snmpget_cmd\n" if $opt_verbose;
    exit $ERRORS{'UNKNOWN'};
}

# Parse SNMP output
my $device_time_str;
if ($snmp_output =~ /=\s+\S+:\s+(.*)$/) {
    $device_time_str = $1;
    
    # Clean up the string - remove quotes and trim whitespace
    $device_time_str =~ s/^["'\s]+//;
    $device_time_str =~ s/["'\s]+$//;
    $device_time_str =~ s/\s{2,}/ /g;
} else {
    print "UNKNOWN: Unable to parse SNMP output: $snmp_output\n";
    exit $ERRORS{'UNKNOWN'};
}

# Parse device time string
my $device_time_epoch;
my $parsed_with_format = 0;    # NEW: track how we parsed (used by timezone handling)
my $device_time_components;    # NEW: store components for fallback parsing
if ($opt_time_format) {
    # Create a clean format string without quotes
    my $clean_format = $opt_time_format;
    $clean_format =~ s/['"]//g;
    $clean_format =~ s/\%e/\%d/g;
    
    eval {
        my $t = Time::Piece->strptime($device_time_str, $clean_format);
        
        # Build a DateTime from parsed components so we can correctly apply device timezone
        my ($sec,$min,$hour,$mday,$mon,$year) = ($t->sec, $t->min, $t->hour, $t->mday, $t->mon, $t->year);
        $parsed_with_format = 1;    # parsed using provided format
        
        if ($opt_timezone) {
            # Normalize timezone like +0300 -> +03:00 for DateTime
            my $tz_name = $opt_timezone;
            if ($tz_name =~ /^([+-])(\d{2})(\d{2})$/) { $tz_name = "$1$2:$3"; }

            my $dt = DateTime->new(
                year      => $year,
                month     => $mon,
                day       => $mday,
                hour      => $hour,
                minute    => $min,
                second    => $sec,
                time_zone => $tz_name
            );
            # Convert to epoch (UTC)
            $device_time_epoch = $dt->epoch;
        } else {
            # No timezone specified — keep Time::Piece epoch (interpreted in local time of monitoring host)
            $device_time_epoch = $t->epoch;
        }
    };
    
    if ($@ || !defined $device_time_epoch) {
        print "UNKNOWN: Failed to parse time string '$device_time_str' with format '$opt_time_format'\n";
        exit $ERRORS{'UNKNOWN'};
    }
} else {
    # Fallback to HOST-RESOURCES-MIB format parsing
    if ($device_time_str =~ /(\d+)\/(\d+)\/(\d+),(\d+):(\d+):(\d+)/) {
        my ($mo,$day,$yr,$hh,$mm,$ss) = ($1,$2,$3,$4,$5,$6);
        $device_time_epoch = timelocal($ss, $mm, $hh, $day, $mo - 1, $yr - 1900);
        # store components to allow correct timezone conversion later if requested
        $device_time_components = { year=>$yr, month=>$mo, day=>$day, hour=>$hh, minute=>$mm, second=>$ss };
    } else {
        print "UNKNOWN: Unrecognized time format: $device_time_str\n";
        exit $ERRORS{'UNKNOWN'};
    }
}

# Apply timezone conversion if specified AND we used the fallback parsing
if ($opt_timezone && !$parsed_with_format) {
    eval {
        my $tz_name = $opt_timezone;
        if ($tz_name =~ /^([+-])(\d{2})(\d{2})$/) { $tz_name = "$1$2:$3"; }
        
        if ($device_time_components) {
            my $dt = DateTime->new(
                year      => $device_time_components->{year},
                month     => $device_time_components->{month},
                day       => $device_time_components->{day},
                hour      => $device_time_components->{hour},
                minute    => $device_time_components->{minute},
                second    => $device_time_components->{second},
                time_zone => $tz_name,
            );
            $device_time_epoch = $dt->epoch;
        }
    };
    if ($@) {
        print "UNKNOWN: Invalid timezone '$opt_timezone': $@\n";
        exit $ERRORS{'UNKNOWN'};
    }
}

# Get reference time (either from NTP or local system)
my $reference_time_epoch;
if ($opt_ntp_server) {
    eval {
        my %ntp = Net::NTP::get_ntp_response($opt_ntp_server, $opt_ntp_port);
        if (!%ntp) {
            die "NTP response empty";
        }
        # Correct NTP time handling
        $reference_time_epoch = $ntp{'Transmit Timestamp'};
    };
    if ($@) {
        print "UNKNOWN: NTP query to $opt_ntp_server failed: $@\n";
        exit $ERRORS{'UNKNOWN'};
    }
} else {
    $reference_time_epoch = time();
}

# Calculate time difference with sign
my $diff = $device_time_epoch - $reference_time_epoch;

# Determine status based on threshold ranges
my $status = 'OK';
my $status_message = "";

# Format difference for display (3 decimal places)
my $diff_display = sprintf("%.3f", $diff);

# Check critical thresholds
if ((defined $crit_min && $diff < $crit_min) || (defined $crit_max && $diff > $crit_max)) {
    $status = 'CRITICAL';
    $status_message = sprintf(
        "Time offset %s second(s) is outside critical range (%s)",
        $diff_display, format_threshold($crit_min, $crit_max)
    );
}

# Check warning thresholds if not critical
elsif ((defined $warn_min && $diff < $warn_min) || (defined $warn_max && $diff > $warn_max)) {
    $status = 'WARNING';
    $status_message = sprintf(
        "Time offset %s second(s) is outside warning range (%s)",
        $diff_display, format_threshold($warn_min, $warn_max)
    );
}

# Default OK message
else {
    $status_message = sprintf(
        "Time offset %s second(s) is within acceptable range (%s)",
        $diff_display, format_threshold($warn_min, $warn_max)
    );
}

# Prepare human-readable times for verbose output
my $device_time_str_formatted = scalar localtime $device_time_epoch;
my $reference_time_str_formatted = scalar localtime $reference_time_epoch;

# Format thresholds for perfdata
my $warn_threshold = format_perf_threshold($warn_min, $warn_max);
my $crit_threshold = format_perf_threshold($crit_min, $crit_max);

# Generate output with correct perfdata label and units
print "[$status] $status_message | 'time.offset.seconds'=$diff;$warn_threshold;$crit_threshold;;\n";

# Verbose output
if ($opt_verbose) {
    print "Device time: $device_time_str_formatted\n";
    print "Reference time: $reference_time_str_formatted\n";
    print "Reference source: " . ($opt_ntp_server ? "NTP ($opt_ntp_server)" : "Local system") . "\n";
    print "SNMP OID: $opt_oid\n";
    print "Timezone: $opt_timezone\n" if $opt_timezone;
    print "Protocol: SNMPv$opt_protocol\n";
    printf "Precise offset: %.9f seconds\n", $diff;
}

exit $ERRORS{$status};

# Helper function to parse threshold ranges
sub parse_threshold {
    my ($spec) = @_;
    return (undef, undef) unless defined $spec;
    
    # Handle single number (symmetric threshold)
    if ($spec =~ /^([-+]?\d*\.?\d+)$/) {
        my $value = abs($1);
        return (-$value, $value);
    }
    
    # Handle range format (min:max)
    if ($spec =~ /^([-+]?\d*\.?\d*)?:([-+]?\d*\.?\d*)?$/) {
        my ($min, $max) = ($1, $2);
        
        # Handle empty values
        $min = undef if $min eq '' || !defined $min;
        $max = undef if $max eq '' || !defined $max;
        
        # Convert to numbers if defined
        $min = $min + 0 if defined $min;
        $max = $max + 0 if defined $max;
        
        return ($min, $max);
    }
    
    print "UNKNOWN: Invalid threshold format: $spec\n";
    exit $ERRORS{'UNKNOWN'};
}

# Helper function to format thresholds for display
sub format_threshold {
    my ($min, $max) = @_;
    my $separator = ' to ';
    
    # Format based on values
    if (!defined $min && !defined $max) {
        return "any value";
    } elsif (!defined $min) {
        return "<$max";
    } elsif (!defined $max) {
        return ">$min";
    } elsif ($min == $max) {
        return "$min";
    } elsif ($min < 0 && $max > 0) {
        return "$min$separator$max";
    } else {
        return "$min$separator$max";
    }
}

# Helper function to format thresholds for perfdata
sub format_perf_threshold {
    my ($min, $max) = @_;
    my $str = "";
    
    # Handle min value
    if (defined $min) {
        $str .= $min;
    } else {
        $str .= "~";  # Nagios symbol for negative infinity
    }
    
    $str .= ":";
    
    # Handle max value
    if (defined $max) {
        $str .= $max;
    } else {
        $str .= "~";  # Nagios symbol for positive infinity
    }
    
    return $str;
}

# Helper function for usage information
sub print_help {
    print <<EOT;
check_time_snmp.pl v3.3 - Nagios/Icinga Plugin for Time Synchronization Checks

Usage: $0 -H <host> -w <warn_range> -c <crit_range> [options]

Required parameters:
  -H, --host <hostname>        Target hostname or IP address
  -w, --warning <range>        Warning threshold range (e.g. -60:60, 60, or -60)
  -c, --critical <range>       Critical threshold range (e.g. -180:180, 180, or -180)

SNMP Options:
  -p, --port <port>            SNMP port (default: 161)
  -C, --community <string>     SNMP community (SNMPv1/v2c, default: public)
  --protocol <version>         SNMP protocol version (1, 2c, or 3; default: 2c)
  
  SNMPv3 Options:
  --username <name>            SNMPv3 username
  --authpassword <pass>        SNMPv3 authentication password
  --authprotocol <proto>       SNMPv3 authentication protocol (md5|sha)
  --privpassword <pass>        SNMPv3 privacy password
  --privprotocol <proto>       SNMPv3 privacy protocol (des|aes)

Time Handling Options:
  --oid <OID>                  Custom time OID (default: 1.3.6.1.2.1.25.1.2.0)
  --time-format <format>       strftime format for parsing time string
  --timezone <zone>            Device timezone (e.g. 'Europe/London' or '+0300')
  --ntp-server <host>          NTP server for reference time
  --ntp-port <port>            NTP server port (default: 123)

General Options:
  --verbose                    Show detailed information
  -h, --help                   Show this help message
  -V, --version                Show version information

Output Details:
  - Main output shows time offset with 3 decimal places
  - Perfdata uses full precision with label 'time.offset.seconds'
  - Verbose mode shows offset with microsecond/nanosecond precision

Threshold Format:
  -w 60                        Warning if |offset| > 60 seconds
  -w -60:60                    Same as above (symmetric)
  -w -120:-60                  Warning if offset < -120s (device behind)
  -w :60                       Warning if offset > 60 seconds (device ahead)
  -w -60:                      Warning if offset < -60 seconds (device behind)

Examples:
  Basic check with symmetric thresholds:
    $0 -H router1 -C public -w 60 -c 180
    
  SNMPv3 with asymmetric thresholds:
    $0 -H switch1 --protocol 3 --username admin --authpassword pass \\
        --authprotocol MD5 --privpassword pass --privprotocol AES \\
        --oid 1.3.6.1.4.1.9999.1.2.3 --time-format "\%Y-\%m-\%d \%H:\%M:\%S" \\
        -w -120:60 -c -300:120
        
  Timezone conversion with NTP reference:
    $0 -H firewall1 --timezone America/New_York --ntp-server time.nist.gov \\
        -w 60 -c 180 --verbose

Perfdata Format:
  'time.offset.seconds'=<value>;<warn>;<crit>;; 

Note: For time formats, use standard strftime specifiers. Common formats:
  "\%a \%b \%e \%H:\%M:\%S \%Y" -> Tue Aug  5 14:30:00 2025
  "\%Y-\%m-\%d \%H:\%M:\%S"     -> 2025-08-05 14:30:00
EOT
}
