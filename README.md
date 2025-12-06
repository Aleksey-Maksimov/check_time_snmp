## About

**check_time_snmp** - Icinga Plugin Script (Check Command). 

Nagios/Icinga plugin to check device time via SNMP against local time or NTP

Features:
 - Supports SNMPv1, v2c, and v3
 - Custom OID support
 - Flexible time format parsing
 - Timezone conversion
 - NTP reference time source
 - Uses system snmpget command for compatibility
 - Nagios/Icinga compliant output with perfdata

Tested on:
- Debian GNU/Linux 12.11 (Bookworm) with Icinga r2.15.0-1, snmpget 5.9.3

Put here: /usr/lib/nagios/plugins/check_time_snmp.pl

PreReq: **snpmget** tool

## Usage


```
$ ./check_time_snmp.pl -H <host> -w <warn_range> -c <crit_range> [options]

Required parameters:
  -H, --host            Target hostname or IP address
  -w, --warning         Warning threshold range (e.g. -60:60, 60, or -60)
  -c, --critical        Critical threshold range (e.g. -180:180, 180, or -180)

SNMP Options:
  -p, --port            SNMP port (default: 161)
  -C, --community       SNMP community (SNMPv1/v2c, default: public)
  --protocol            SNMP protocol version (1, 2c, or 3; default: 2c)

SNMPv3 Options:
  --username            SNMPv3 username
  --authpassword        SNMPv3 authentication password
  --authprotocol        SNMPv3 authentication protocol (md5|sha)
  --privpassword        SNMPv3 privacy password
  --privprotocol        SNMPv3 privacy protocol (des|aes)

Time Handling Options:
  --oid                 Custom time OID (default: 1.3.6.1.2.1.25.1.2.0)
  --time-format         strftime format for parsing time string
  --time-preformat-regex
                        Perl substitution to apply to raw SNMP string BEFORE parsing
                        Must be a Perl s/// expression, e.g.:
                          s/^"(.*)"$/$1/
                          s/(\d{2}) (\d{2}) (\d{4})/$3-$2-$1/
                        This allows you to normalize vendor-specific strings (ARICENT, etc)
                        and then pass the normalized string to --time-format.
  --timezone            Device timezone (e.g. 'Europe/London' or '+0300')
  --ntp-server          NTP server for reference time
  --ntp-port            NTP server port (default: 123)

General Options:
  --verbose             Show detailed information
  -h, --help            Show this help message
  -V, --version         Show version information

Output Details:
  - Main output shows time offset with 3 decimal places
  - Perfdata uses full precision with label 'time.offset.seconds'
  - Verbose mode shows offset with microsecond/nanosecond precision

Threshold Format:
  -w 60                 Warning if |offset| > 60 seconds
  -w -60:60             Same as above (symmetric)
  -w -120:-60           Warning if offset < -120s (device behind)
  -w :60                Warning if offset > 60 seconds (device ahead)
  -w -60:               Warning if offset < -60 seconds (device behind)

Examples:
  Basic check with symmetric thresholds:
    $0 -H router1 -C public -w 60 -c 180

  Using preformat regex to normalize ARICENT string then parse:
    $0 -H switch1 -C public \
       --time-preformat-regex 's/^"(.+)"$/$1/' \
       --time-format '%Y-%m-%dT%H:%M:%S%z' \
       -w 60 -c 180

  SNMPv3 with asymmetric thresholds:
    $0 -H switch1 --protocol 3 --username admin --authpassword pass \
       --authprotocol MD5 --privpassword pass --privprotocol AES \
       --oid 1.3.6.1.4.1.9999.1.2.3 --time-format "\%Y-\%m-\%d \%H:\%M:\%S" \
       -w -120:60 -c -300:120

  Timezone conversion with NTP reference:
    $0 -H firewall1 --timezone America/New_York --ntp-server time.nist.gov \
       -w 60 -c 180 --verbose

Perfdata Format:
  'time.offset.seconds'=;;;;

Note: For time formats, use standard strftime specifiers.

Common formats:
  "%a %b %e %H:%M:%S %Y" -> Tue Aug 5 14:30:00 2025
  "%Y-%m-%d %H:%M:%S"    -> 2025-08-05 14:30:00


```
## Examples:


Basic check with symmetric thresholds:

```
$ ./check_time_snmp.pl -H router1 -C public -w 60 -c 180
```

SNMPv3 with asymmetric thresholds:

```
$ ./check_time_snmp.pl -H switch1 --protocol 3 --username monitor --authpassword pass \
        --authprotocol MD5 --privpassword pass --privprotocol AES \
        --oid 1.3.6.1.4.1.9999.1.2.3 --time-format "%Y-%m-%d %H:%M:%S" \
        -w -120:60 -c -300:120
```

Timezone conversion with NTP reference:

```
$. /check_time_snmp.pl -H firewall1 --timezone America/New_York --ntp-server time.nist.gov \
        -w 60 -c 180 --verbose
```
