#!/usr/bin/perl
=head1 NAME
  sock.util.pl

=head1 SYNOPSIS

  general utility for batch operations on non-standard text based network protocols

  opening either a listening INET socket or an outbound
  read commands from a file, write responses to a file

=head1 USAGE

usage: sock.tool.pl -[fwvl] host:port [host:port] ...
       -l listen <port>
       -f input file
       -w output file
       -v bump up verbosity level

=cut 

#
# socket tool
#   Nate Lally nate.lally[at]gmail[dot]com  12/3/04
#
#  as she is now,
#   cycles through host:port params && opens inet socket
#   on first connection, pull down input (def is STDIN)
#   for every line (\n) of input, syswrite to socket
#   then sysread until error or timeout + 0b read
#
#   call LOGLEVEL(undef) to turn all output off
#
#   Changelog:
#     -added select - still using blocked i/o tho
#
#################################################################################
# $Log: sock.tool.pl,v $
# Revision 1.6  2005/01/21 14:48:35  nate
# fixed connection retry detection and logic
#
# Revision 1.5  2005/01/18 06:08:06  nate
# sync
#
# Revision 1.4  2005/01/18 03:26:27  nate
# misc tweaks
#
# Revision 1.3  2005/01/18 01:54:32  nate
# tweaked timeouts, split connection logic, added i/o retry logic
#
# Revision 1.2  2005/01/15 01:04:34  nate
# seperated processWritable from main loop
#
# Revision 1.1  2005/01/14 22:30:28  nate
# cleanup up user output
#
#################################################################################

use strict;
use warnings;

use IO::Socket;
use IO::File;
use IO::Select;
use File::Basename;
use POSIX qw(strftime);


############################## function defs ####################################

sub print_usage;
sub now(;$$);
sub outputPrefix;
sub openSock($);

# undef loglevel to turn off output altogether
sub LOGLEVEL(;$);
sub DEBUG($);
sub INFO($);
sub ERROR($);
sub WARNING($);

##############################    globals    ####################################

my ($I_timeout, $I_sockTimeout, $I_selectTimeout, $I_chunkSize, $I_sendRetry,
    $I_connRetry, $I_connRetryTimeout, $I_listenPort);
my (@validArg, @Thost, $fIn, $fOut, $Pinps, $Pouts);

$I_connRetry = 3;
$I_connRetryTimeout = 15;
$I_sendRetry = 2;
$I_chunkSize = 1500; #socket i/o chunksize
$I_timeout = 60;
$I_sockTimeout = 10;
$I_selectTimeout = 5;
$I_listenPort = undef;

my $rcs = '@(#) $Id: sock.tool.pl,v 1.6 2005/01/21 14:48:35 nate Exp $';

############################# ancillary funcs ###################################

sub now(;$$) {
  my %type = ();
  $type{time} = shift;
  $type{date} = shift;
  my ($sNow, $fTime, $fDate) = ((undef) x 3);

  if (not defined $type{time} or
      $type{time} eq 0) {
    $fTime = "%H:%M:%S";
  } elsif ($type{time} eq 1) {
    $fTime = "%H.%M.%S";
  } elsif ($type{time} eq 2) {
    $fTime = "%I:%M:%S %p";
  } elsif ($type{time} eq 3) {
    $fTime = "%I.%M.%S %p";
  }
  if (not defined $type{date} or
     $type{date} eq 0) {
    $fDate = "";
  } elsif ($type{date} eq 1) {
    $fDate = "%a %b %e";
  } elsif ($type{date} eq 2) {
    $fDate = "%A %B %e";
  } elsif ($type{date} eq 3) {
    $fDate = "%D";
  } elsif ($type{date} eq 4) {
    $fDate = "%d/%m/%Y";
  }

  $sNow = strftime($fDate.$fTime, localtime);
  $sNow;
}

sub outputPrefix {
  return now." ";
}

# user output functions
{
  my $logLevel = 1;
  sub LOGLEVEL(;$) {
    my $ret = undef;
    my $l = shift;
    (defined $l) ? $logLevel = $l : $ret = $logLevel;
    return $ret;
  }
}

sub DEBUG($) {
  my $msg = shift;
  if (LOGLEVEL > 3 && defined $msg) {
    printf(STDERR "%s%s\n", outputPrefix, $msg);
  }
  return;
}

sub INFO($) {
  my $msg = shift;
  if (LOGLEVEL > 2 && defined $msg) {
    printf(STDERR "%s%s\n", outputPrefix, $msg);
  }
  return;
}

sub NOTICE($) {
  my $msg = shift;
  if (LOGLEVEL > 1 && defined $msg) {
    printf(STDERR "%s%s\n", outputPrefix, $msg);
  }
  return;
}

sub WARNING($) {
  my $msg = shift;
  if (LOGLEVEL > 0 && defined $msg) {
    printf(STDERR "%s[warning] %s\n", outputPrefix, $msg);
  }
  return;
}

sub ERROR($) {
  my $msg = shift;
  if (defined LOGLEVEL && defined $msg) {
    printf(STDERR "%s[fatal error] %s\n", outputPrefix, $msg);
  }
  #cleanup
  if (defined $Pinps) { $Pinps->close }
  if (defined $Pouts) { $Pouts->close }

  exit 1;
}

sub print_usage {
  print "usage: ".basename($0)." -[fwvl] host:port [host:port] ...\n".
        "       -l listen <port> \n".
        "       -f input file \n".
        "       -w output file \n".
        "       -v bump up verbosity level \n".
        "\n";
  exit(0);
}

#############################       I/O       ###################################

sub _processWriteable($$;$$) {
  my ($Psock, $Pmsg, $PstreamIn, $PstreamOut);
  my ($Tbuf, $Tbytes, $Tsent, $Tread, $Trc);
  my (@fdset, $s);

  ($Psock, $Pmsg, $PstreamIn, $PstreamOut) = @_;

  $Trc = $Tbytes = 0;

  $s = IO::Select->new();
  $s->add($Psock);

  my ($now, $then);
  $now = $then = time;

  do {
    unless (defined $Psock and $Psock->connected) {
      WARNING(sprintf("socket not connected"));
      $Trc = -3;
      return $Trc;
    }

    DEBUG("calling select, timeout [$I_selectTimeout]");
    #socket is rdy for writing?
    @fdset = $s->can_write($I_selectTimeout);

    foreach my $writeFd (@fdset) {
      $Tsent =  syswrite($writeFd, $Pmsg, length($Pmsg));
      $writeFd->flush();

      if (not defined $Tsent) {
        WARNING("sock write error: ".$!);
        $Trc = -3;
        last;
      } elsif ($Tsent != length($Pmsg)) {
        WARNING(sprintf("connection broken with [%s], sent %u of %u bytes",
                        $Psock->peerhost, $Tsent, length($Pmsg)));
        $Trc = -2;
        last;
      } else {
        $Tbytes += $Tsent;
        DEBUG("sent data:\n$Pmsg");
      }                         #end switch $Tsent
    }
  } until (($Tbytes eq (length($Pmsg))) or $Trc < 0);

  INFO(sprintf("sent %u bytes to [%s:%u]", $Tbytes, $Psock->peerhost, $Psock->peerport));

  $Trc = $Tbytes if ($Trc ge 0);
  return $Trc;
}

sub _processReadable($;$$) {
  my ($Tbuf, $Psock, $PstreamIn, $PstreamOut);
  my ($Tbytes, $Tsent, $Tread, $Trc);
  my (@fdset, $s);

  $Psock = shift;
  $PstreamIn = shift;
  $PstreamOut = shift;

  $Trc = $Tbytes = 0;

  $s = IO::Select->new($Psock);

  DEBUG("sock read timeout [$I_timeout]");

  my ($now, $then);
  $now = $then = time;

  #process readable

  do {
    $Tread = 0;
    unless (defined $Psock and $Psock->connected) {
      WARNING(sprintf("socket disconnected"));
      $Trc = -3;
      return $Trc;
    }

    DEBUG("calling select w/ timeout [$I_selectTimeout]");

    @fdset = $s->can_read($I_selectTimeout);

    foreach my $readFd (@fdset) {
      $Tbuf = "";
      $Tread = $Psock->sysread($Tbuf, $I_chunkSize, length($Tbuf));#, MSG_WAITALL);
      $now = time;

      unless (defined $Tread) {
        WARNING("sock read error: ".$!);
        $Trc = -4;
        last;
      }
      #read sock until timeout or no more data
      if ($Tread > 0) {
        #output socket input
        $Tbytes += $Tread;

        DEBUG("read data:\n$Tbuf");
        syswrite($PstreamOut, $Tbuf, $Tread);
      } else {
        print STDERR "*NOTE tread: $Tread\n";
      } #end if $Tread > 0
    }

    #$#fdset eq 0 or
  } until ( $Trc < 0 or
            (($Tbytes gt 0 or $now ge ($then + $I_timeout)) and $Tread eq 0) or
            ($#fdset eq 0 and $Tread eq 0)
          );

  if ($Tbytes eq 0 and $Trc ge 0) {
    WARNING(sprintf("read on sock timed out [%u]", $I_timeout));
    $Trc = -5;
  }

  INFO(sprintf("read %u bytes from [%s:%u]", $Tbytes, $Psock->peerhost, $Psock->peerport));
  $Trc = ($Trc >= 0) ? $Tbytes : $Trc;

  return $Trc;
}

#
#  takes connected socket, optionally input stream &&|| output stream
#
#  return int < 0 on error, # bytes read, or # bytes sent
#
sub performSockIo($;$$) {
  my ($Psock, $PstreamIn, $PstreamOut);
  my ($Tbytes, $Tsent, $Tread, $Twrote, $Trc, $Tsize);
  my ($Tbuf, $Tfile, $s, @fdset);

  ($Psock, $PstreamIn, $PstreamOut) = @_;

  $| = $Trc = $Tbytes = 0;

  if (not defined $PstreamIn) { $PstreamIn = *STDIN; }
  if (not defined $PstreamOut) { $PstreamOut = *STDOUT; }

#  for (;;) {
  my $Ttoken = "__END_MSG__";

  #have something to send?
  while (($Tsize = sysread($PstreamIn, $Tbuf, 100)) > 0) {
    $Tfile .= $Tbuf;
  }  # end while sysread

  return -1 unless ($Tfile);
  my @Tmsg = split(/$Ttoken/, $Tfile);

  my $Tmsg = undef;
  do {
    $Tmsg = shift @Tmsg;
    $Tread = $Twrote = $Tbytes = 0;

    while (defined $Tmsg and ($Tread eq 0 or $Twrote eq 0)) {
      my $try = 0;

      #format msg
      $Tmsg =~ s/^\n//;
      chomp $Tmsg;
      $Tmsg .= "\n\n";

      do {
        $try++;

        $Twrote = _processWriteable($Psock, $Tmsg, $PstreamIn, $PstreamOut);
      } until ($try ge $I_sendRetry or $Twrote ne 0);

      if ($Twrote < 0) {
        $Trc = $Twrote;
        return $Trc;
      } else {
        $Tread = _processReadable($Psock, $PstreamIn, $PstreamOut);
      }

    };
  } until ($Tread < 0 or $Twrote < 0 or not defined $Tmsg);

  if ($Tread < 0) { $Trc = $Tread;}
#  } #end loop
  return $Trc;
}

sub openSock($) {
  my $Tdest = shift || return undef;
  my $Tsock = undef;

  if ($I_listenPort) {
    $Tsock = new IO::Socket::INET( PeerAddr => $Tdest,
                                   Listen => 1024,
                                   Proto => "tcp",
                                   LocalAddress => "localhost",
                                   LocalPort => $I_listenPort,
                                 ) or ERROR("cannot bind to localhost:$I_listenPort");
  } else {
    INFO("trying [$Tdest] ... ");

    $Tsock = new IO::Socket::INET( PeerAddr => $Tdest ) or return undef;
  }

  my ($name, $aliases, $proto) = getprotobynumber($Tsock->protocol);

  if ($I_listenPort) {
    INFO(sprintf("listening on port [%s:%u]",
                 $Tsock->sockhost(), $Tsock->sockport()));
  } else {
    INFO(sprintf("connected sock [%s] [%s:%u]",
                 $name, $Tsock->peerhost, $Tsock->peerport));
  }

  if ($Tsock) {

    $Tsock->timeout($I_sockTimeout);
    DEBUG(sprintf("sock timeout set [%u]", $I_sockTimeout));

    #no autoflush (sock using sys(write|read) anyways)
    $Tsock->autoflush();
  }

  $Tsock;
}


#############################      main       ###################################

LOGLEVEL(2);

#
# parse && validate command line args
#
my $optArg = undef;
my ($o, $oa) = (0, 0);
foreach (@ARGV) {
  if (/^([-:\@\w.]+)$/) {
    if ($oa eq 1) { $optArg = $1 }
    else { unshift @validArg, $1 }
  } else {
    print_usage;
  }

  #options
  if (/^-([fvwl]+)$/ || $oa eq 1) {
    if ($oa) { $oa = 0 }
    else { $o = $1 }
    s/-//;

    if ($o =~ /f/) {
      unless ($oa eq 1 or defined $optArg) { $oa = 1; next; }
      else { ERROR("option requires an argument") unless (defined $optArg) }

      $fIn = $optArg;
      $Pinps = new IO::File;
      $Pinps->open("<$fIn") || ERROR("cannot open input stream [$fIn]");
    }
    if ($o =~ /w/) {
      unless ($oa eq 1 or defined $optArg) { $oa = 1; next; }
      else { ERROR("option requires an argument") unless (defined $optArg) }

      $fOut = $optArg;
      $Pouts = new IO::File;
      $Pouts->open(">$fOut") || ERROR("cannot open output stream [$fOut]");
    }
    if ($o =~ /l/) {
      unless ($oa eq 1 or defined $optArg) { $oa = 1; next; }
      else { ERROR("option requires an argument") unless (defined $optArg) }

      $I_listenPort = sprintf("%u", $optArg);
    }
    while ($o =~ /v/gc) {
      my $l = LOGLEVEL;
      $l++;
      LOGLEVEL($l);
    }

    $optArg = undef;
  } #end if option

} # end foreach ARGV

map {
  if (/^((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|[-\w\.]+)\:(\d+))$/) {
    unshift @Thost, $1;
  }
} @validArg;

unless ($#Thost ge 0 && not defined $I_listenPort) {
  print_usage;
};

#
# open sockets
#
foreach my $Thost (@Thost) {
  my ($Tsock, $Trc, $Try);

  $Try = 0;
  do {

    $Tsock = openSock($Thost);

    #the meat and potatoes
    $Trc = performSockIo($Tsock, $Pinps, $Pouts);

    if ($Trc lt 0 and $Try < $I_connRetry) {
      $Try++;
      DEBUG("connection retry [$Try] happening in [$I_connRetryTimeout]");
      sleep $I_connRetryTimeout;
    }
  } while ($Trc < 0 and $Try < $I_connRetry);

  if ($Tsock) {
    my ($name, $aliases, $proto) = getprotobynumber($Tsock->protocol);
    DEBUG(sprintf("closing sock [%s] [%s:%u]",
                  $name, $Tsock->peerhost, $Tsock->peerport));
    close $Tsock;
  }

  if ($Trc le 0) { next }
  else { last }
}

#cleanup && exit gracefully
if (defined $Pinps) { $Pinps->close }
if (defined $Pouts) { $Pouts->close }

exit 0;
