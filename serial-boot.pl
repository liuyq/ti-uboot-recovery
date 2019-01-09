#!/usr/bin/perl
#####################################################################
# serial-boot.pl
#
# OMAP Flashing Alternative perl script
# Serial module usage copied from http://ttime.no/dev.shtml
#
# Copyright (C) 2007 Texas Instruments, Inc.
#
# This package is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# THIS PACKAGE IS PROVIDED ``AS IS'' AND WITHOUT ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED
# WARRANTIES OF MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# INSTALLATION NOTES:
# -------------------
# WIN32:
# This package depends on Win32::SerialPort if using windows
# Download from http://www.bribes.org/perl/ppm/
# PPD file and tgz to c:\perl, open a cmd and cd c:\perl
# run ppm install Win32-SerialPort.ppd
#
# Linux/Other OS:
# This package depends on Device::SerialPort if using any other OS.
# Download this using cpan -> cpan install Device::SerialPort
#
# The perl script by itself requires only r/w permission to serial port
#
#  History
#  -------
#  0.01 2007-11-08 Nishanth Menon  Created initial version
#  0.02 2013-08-07 Minal Shah      Reading 69-bytes ASIC Id instead of 58-bytes
#                                  Updated printing the ASIC Id in hex 
#                                  Changed name of this script file from
#                                  omap_flash.pl to serial-boot.pl
#####################################################################
use strict;
use File::stat;
use Getopt::Std;
use IO::Handle;
use Time::HiRes qw(usleep);

################# MAIN ##############################################
# get options
my %options = ();
getopt( "tpsd", \%options );

my $portId      = "$options{p}";
my $second_file = "$options{s}";

my $max_timeout = "$options{t}";
my $debug       = "$options{d}";

#portId should be number only..
#if (   ( ( $portId == '' ) && ( "$portId" != "0" ) )
#    || ( "$portId" =~ /[^0-9]/ ) )
#{
#    print "'$portId' port is invalid\n";
#    help_message();
#    exit(1);
#}

#debug should be 0 or 1
if ( ( "$debug" != '' ) && ( "$debug" != "0" ) && ( "$debug" != "1" ) ) {
    print "'$debug' debug is invalid\n";
    help_message();
    exit(1);
}
if ( "$debug" == '' ) {
    $debug = 0;
}
if ( ( "$max_timeout" =~ /[^0-9]/ ) ) {
    print "'$portId' Timeout Period is invalid\n";
    help_message();
    exit(1);
}
if ( !$max_timeout ) {
    $max_timeout = 30;
}

if ( ( !$second_file ) || ( !file_size($second_file) ) ) {
    print "MLO file '$second_file' is invalid\n";
    help_message();
    exit(1);
}

#my $port = ( $^O eq 'MSWin32' ? "COM$portId" : "/dev/ttyS$portId" );
my $port = $portId;

STDOUT->autoflush(1);
my $chunk_count = 0;

# open the port
my $handler = openPort($port, 'even') || die "could not open port $port:$!\n";

####################################################################

############ DOWNLOAD 2ND FILE ALONE  CONNECT WITH CSST ############

##### FORMAT MY FILE SIZE
my $file_size    = file_size($second_file);
my $file_bytes   = pack( "L", $file_size );
my $prefix_bytes = pack( "L", 0xF0030002 );
my $string_bytes = "$prefix_bytes" . "$file_bytes";
if (1) {
#$debug) {
    print "BYTES=$file_size file_bytes="
      . unpack( "H*", $file_bytes )
      . " prefix_bytes="
      . unpack( "H*", $prefix_bytes )
      . " string bytes="
      . unpack( "H*", $string_bytes ) . "\n";
}

print "----Please reset the Board NOW (timeout=$max_timeout sec)----\n";

# Read the 69 bytes of ASIC ID
read_asicID( $handler, 69 )
  || die "Timedout while waiting for read asic id ($max_timeout sec).";

print "Board Detected\n";

#Send File Size
writePort( $handler, $string_bytes ) || die "Unable To send File Size";

# Send the file
send_file( $handler, $second_file ) || die "Could Not Send $second_file File";

print "\n$second_file file download completed\n";

#$debug = 1;
#read_text( $handler, 200 );

closePort($handler);

my $handler = openPort($port, 'none') || die "could not open port $port:$!\n";
read_text( $handler, 300 ) || die "\nUART boot message not found\n";
print "\nUART Ymodem download has started on target\n";
closePort($handler);

exit(0);

###################################################################
########            HELPERS                             ###########
###################################################################

###################################################################
sub help_message() {
###################################################################
    print "serial-boot.pl: Flashing Utility\n"
      . "Syntax:\n"
      . "serial-boot.pl -p <device> -s <second_file> [-d <dbg_lvl>] [-t <timeout>]\n"
      . "      port        - Port ID as a device (i.e. /dev/ttyS0 || COM1)\n"
      . "      second_file - MLO File or the inital software\n"
      . "      dbg_lvl     - Debug Level 0-silent, 1-verbose (optional)\n"
      . "      timeout     - timeout period in seconds (optional)\n";
}

############## OMAP/FILE FUNCTIONS ###############################

##################################################################
sub read_asicID() {
##################################################################
    my ( $handler, $asic_id_length ) = @_;
    my $char_count = 0;
    my $timer      = 0;

    my $string_in_hex;

    do {
        my ( $count_in, $string_in ) = $handler->read(1);
        $string_in_hex    = unpack( "H*", $string_in );
        if ( $count_in > 0 ) {
            $char_count++;
            if ($debug) {
                print "$string_in_hex\t";
            }

            # reset the timer
            $timer = 0;
        }
        else {
            $timer++;

            #r/w const timeout is in terms of 10 ms
            return 0 if ( $timer > ( $max_timeout * 100 ) );
        }
    } while ( $char_count < $asic_id_length );
    print "\n";
    return 1;
}

##################################################################
sub read_text() {
##################################################################
    my ( $handler, $asic_id_length ) = @_;
    my $char_count = 0;
    my $timer      = 0;
    my $pattern    = 'Trying to boot from UART';
    my $pattern_idx = 0;

    my $string_in_hex;

    do {
        my ( $count_in, $string_in ) = $handler->read(1);
        $string_in_hex    = unpack( "H*", $string_in );
        if ( $count_in > 0 ) {
            $char_count++;
            #print "$string_in_hex ($string_in)\t";
            print "$string_in";

            if ( $string_in eq substr($pattern, $pattern_idx, 1) ) {
                $pattern_idx++;
                print "*";
                if ( $pattern_idx >= length($pattern) ) {
                    return 1;
                }
            }
            else {
                $pattern_idx = 0;
            }

            # reset the timer
            $timer = 0;
        }
        else {
            $timer++;

            #r/w const timeout is in terms of 10 ms
            return 0 if ( $timer > ( $max_timeout * 100 ) );
        }
    } while ( $char_count < $asic_id_length );
    print "\n";
    return 0;
}

##################################################################
sub file_size() {
##################################################################
    my ($file) = @_;
    my $FILE = stat("$file");
    if ( !$FILE ) {
        return 0;
    }
    my $filesize = $FILE->size;

    return "$filesize";
}

##################################################################
sub send_file() {
##################################################################
    my ( $handler, $file ) = @_;
    my $buffer;
    my $len;
    my $total_len  = 0;
    my $chunk_size = 2048;
    open FILE, "<$file" or die "can't open $file $!";
    binmode(FILE);
    do {
        $len = read( FILE, $buffer, $chunk_size );
        if ($len) {
            my $ret = writePort( $handler, $buffer );
            if ( !$ret ) {
                print "write port failed: $chunk_size $total_len $ret\n";
                return 0;
            }
        }
        $total_len += $chunk_size;
    } while ( $len != 0 );
    close(FILE);
    return 1;
}

############# SERIAL PORT FUNCTIONS ##############################

##################################################################
sub openPort {
##################################################################
    my ($port, $parity) = @_;

    my $quiet;
    my $ob = undef;
    if ( $^O eq 'MSWin32' ) {
        require Win32::SerialPort;
        Win32::SerialPort->import();
        $ob = Win32::SerialPort->new( "\\\\.\\$port", $quiet );
    }
    else {
        eval ' require Device::SerialPort; ';
        if ( !$@ ) {
            require Device::SerialPort;
            Device::SerialPort->import();
            $ob = Device::SerialPort->new( "$port", $quiet );
        }
        else {
            print "Unable to find required Perl module Device::SerialPort\n";
        }
    }
    my $ok = 0;

    if ($ob) {
        # OMAP PARAMETERS
        my $omap_baud = 115200;
        my $omap_partiy = $parity;
        my $omap_data_bits = 8;
        my $omap_stop_bits = 1;
        my $omap_handshake = 'none';

        #$ob->debug(0);
        my @baud_opt   = $ob->baudrate;
        my @parity_opt = $ob->parity;
        my @data_opt   = $ob->databits;
        my @stop_opt   = $ob->stopbits;
        my @hshake_opt = $ob->handshake;

        foreach $a (@baud_opt) {
            if ( $a == $omap_baud ) {
                $ok++;
                last;
            }
        }
        foreach $a (@parity_opt) {
            if ( $a eq $omap_partiy ) {
                $ok++;
                last;
            }
        }
        foreach $a (@data_opt) {
            if ( $a == $omap_data_bits ) {
                $ok++;
                last;
            }
        }
        foreach $a (@stop_opt) {
            if ( $a == $omap_stop_bits ) {
                $ok++;
                last;
            }
        }
        foreach $a (@hshake_opt) {
            if ( $a eq $omap_handshake ) {
                $ok++;
                last;
            }
        }
        $ok++ if ( $ob->is_rs232 );

        $ob->baudrate($omap_baud);
        $ob->parity($omap_partiy);
        $ob->databits($omap_data_bits);
        $ob->stopbits($omap_stop_bits);
        $ob->handshake($omap_handshake);
        $ob->buffers( 1024 * 10, 1024 * 30 );
        $ob->read_interval(0) if ( $^O eq 'MSWin32' );
        $ob->read_char_time(0);
        $ob->read_const_time(10);
        $ob->write_char_time(0)  if ( $^O eq 'MSWin32' );
        $ob->write_const_time(0) if ( $^O eq 'MSWin32' );
        $ob->write_drain if ( $^O ne 'MSWin32' );    # drain if not win
        $ok++ if ( $ob->write_settings );

        $ob->close if ( $ok < 6 );
    }
    undef $ob if ( $ok < 6 );
    return $ob;
}

##################################################################
sub closePort {
##################################################################
    my ($ob) = @_;
    if ($ob) {
        $ob->close;
        undef $ob;
    }
}

##################################################################
sub readPort {
##################################################################
    my ($ob) = @_;
    return -1 unless ($ob);
    my ( $count_in, $string_in ) = $ob->read(1);
    return ( $count_in > 0 ? ord($string_in) : -1 );
}
##################################################################
sub flush_read {
##################################################################
    my ($port) = @_;
    my $count_in;
    my $string_in;
    do {
        ( $count_in, $string_in ) = $port->read(1);
    } while ( $count_in != 0 );
}
##################################################################
sub writePort {
##################################################################
    my ( $ob, $wbuf ) = @_;
    if ( !$ob ) {
        print "invalid ob\n";
        return 0;
    }
    my $n           = $ob->write("$wbuf");
    my $timer_count = 4000;                    # 4000 ms delay
    my $done        = 0;
    my $count_out;

    $chunk_count++;

    print "."; #Show some life
    # Wait to ensure that the data did flow out
    # This is required for Linux esp since it does a background operation
    do {
        ( $done, $count_out ) = $ob->write_done(0);
        if ($debug) {
            print "?";
        }
        $timer_count--;
        if (!$done ) {
            usleep(10000);
        }
        if ( !$timer_count ) {
            print "\nTimedout waiting for draining";
            return 0;
        }
    } while ( !$done );
    if ($debug) {
        my ( $done, $count_out ) = $ob->write_done(0);
        print( "\n-->$chunk_count  $n " . length($wbuf) . "  $done $count_out\n" );
        print "write failed\n" unless ($n);
        warn "write incomplete\n" if ( $n != length($wbuf) );
    }
    return ( $n == length($wbuf) );
}

########### END OF FILE   ########################################
