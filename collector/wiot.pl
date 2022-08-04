#!/usr/bin/perl

#   Copyright (C) 2015-2022 Michal Grezl
#
#    This file is part of wiot.
#
#    wiot is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    wiot is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with wiot.  If not, see <http://www.gnu.org/licenses/>.

use Data::Dumper;
use Device::SerialPort;
use LWP::UserAgent;
use Sys::Syslog;
use DBI;


### config ###
my $url = "http://grezl.eu/wiot/v1/sensor";
my $dbpath = "/usr/local/share/wiot";
##############

my $debug = 0;

my %iot;
my $ua = LWP::UserAgent->new;
my %data_to_send;

syslog("info","Wiot collector is starting");

&connect_db();

my @usb_dev = &get_usb_devices();

$devhandle{0} = BAR;
$devhandle{1} = FOO;
$devhandle{2} = POO;


openlog('wiot_col', 'cons,pid', 'user');

my $i = 0;
foreach $u (@usb_dev) {
  syslog("info","found dev $u");
  $iot{"S".$i++} = &config_sensor(0, $devhandle{$i}, '/dev/'.$u);
}

foreach $s (keys %iot)
{
  my $p = &fork_sensor($iot{$s}{handle},$iot{$s}{device});
  if (!$p) {
    &child();
  }
  $iot{$s}{pid} = $p;
}

#main process
  syslog("info","Parent $$");

  &debug_print(Dumper(\%iot)."\n");

  while(1) {

    &debug_print("loop");

    $s1 = <BAR>;
    $s2 = <FOO>;
    $s3 = <POO>;

    &debug_print("continue");

    if (defined $s1) {
      chomp $s1;
      $s1 =~ s/^\s+|\s+$//g;
      $s1 =~ s/[^[:print:]]/./g;

      if ($s1 =~ /^(type.*)\;$/) {
        $line = $1;
        syslog("info", "gud1: $s1");
        my %data = split /[:,]/, $line;
      } else {
        &debug_print("bad1: $s1");
        undef $s1;
      }

    } else {
      &debug_print("child 1 dead");
      close BAR;
    }

    if (defined $s2) {
      chomp $s2;

      $s2 =~ s/w_sensor\=//g;
      $s2 =~ s/curr\=/curr:/g;

      $s2 =~ s/^\s+|\s+$//g;
      $s2 =~ s/[^[:print:]]/./g;

      if ($s2 =~ /^(type.*)\;$/) {
        $line = $1;
        syslog("info", "gud2: $s2");
        my %data = split /[:,]/, $line;
      } else {
        syslog("info", "bad2: $s2");
        $s2 = "";
      }

    } else {
      &debug_print("child 2 dead");
      close FOO;
    }

    if (defined $s3) {
      chomp $s3;

      $s3 =~ s/w_sensor\=//g;
      $s3 =~ s/curr\=/curr:/g;

      $s3 =~ s/^\s+|\s+$//g;
      $s3 =~ s/[^[:print:]]/./g;

      if ($s3 =~ /^(type.*)\;$/) {
        $line = $1;
        &debug_print("gud3: $s3");
        my %data = split /[:,]/, $line;
      } else {
        syslog("info", "bad3: $s3");
        undef $s3;
      }

    } else {
      &debug_print("child 3 dead");
      close POO;
    }

    if (defined $s1) {
      if ($s1 =~ /sn\:([A-Za-z0-9]*),/) {
        $sn = $1;
        $data_to_send{$sn} = $s1;
        &debug_print("1 sn $sn\n");
      }
    } else {
      &debug_print("no 1, $s1");
    }

    if ($s2 ne "") {
      if ($s2 =~ /sn\:([A-Za-z0-9]*),/) {
        $sn = $1;
        $data_to_send{$sn} = $s2;
        &debug_print("2 sn $sn\n");
      }
    } else {
      &debug_print("no 2");
    }

    if (defined $s3) {
      if ($s3 =~ /sn\:([A-Za-z0-9]*),/) {
        $sn = $1;
        $data_to_send{$sn} = $s3;
        &debug_print("3 sn $sn\n");
      }
    } else {
      &debug_print("no 3\n");
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

    if (!($sec % 20) or !($sec % 19)) {
      my $i;
      foreach $i (keys %data_to_send) {
        &debug_print("to send $i\n");
        &send_data($data_to_send{$i});
      }

#only on raspi
      &send_data(&raspi_temp());

      %data_to_send = ();
    }
    sleep 1;
  }

  close BAR;
  close FOO;
  close POO;

################################################################################
sub raspi_temp()
################################################################################
{
  my $gpu_temp = `/opt/vc/bin/vcgencmd measure_temp`;
  chomp $gpu_temp;
  $gpu_temp =~ m/temp\=(.*)\'C/;
  $gpu_temp = $1;

  my $ip = `/usr/local/bin/myip`;
  chomp $ip;

  open(CPUDATA, "</sys/class/thermal/thermal_zone0/temp") or do {
    return "bad data";
  };
  my $cpu_temp = <CPUDATA>;
  chomp $cpu_temp;
  $cpu_temp /= 1000;
  my $out = "type:raspi,sn:1,cputemp:".$cpu_temp.",gputemp:".$gpu_temp.",ip:".$ip.";";
  close  CPUDATA;

  return $out;
}


################################################################################
sub child()
################################################################################
{
  my $mypid = $$;

#  foreach $i (keys %iot) {
#      syslog("info","Child mypid $mypid $parent $dev");
#  }

#$|=1;

  syslog("info", "Child pid:$mypid on dev:$dev");
  my $port = Device::SerialPort->new($dev) or die "child cannot open ".$dev;

#  $port->baudrate(9600);
  $port->baudrate(115200);
  $port->databits(8);
  $port->parity("none");
  $port->stopbits(1);

  &debug_print("start");
  while (1) {
    my $char = $port->lookfor();
    my $char2 = $port->lookfor();
    if ($char) {
      &debug_print("$char");
    }
    if ($char2) {
      &debug_print("$char2");
    }


#causes line spliting    $port->lookclear; # needed to prevent blocking
#    sleep (1);
    select(undef, undef, undef, 0.05);

    if  ((time % 10) == 9) {
      my $ip = `/usr/local/bin/myip`;
      chomp $ip;
      $port->write("ip: $ip ");
    }

  }
}

################################################################################
sub resend_data()
################################################################################
{
  syslog("info", "Resending:");

  my $query = "select id,data from fail limit 5";

  $res = $dbh->selectall_arrayref($query) or do {
    syslog("info", "resend_data table_get dberror" . $DBI::errstr);
    return 0;
  };

  foreach my $row (@$res) {
    my ($id, $data) = @$row;
    syslog("info", "- resending id $id");

    my $response = $ua->post( $url, { 'w_sensor' => $data } );
    my $resp  = $response->decoded_content();
    if ($resp eq "OK") {
      # remove id from fai db
      my $q = "delete from fail where id=?";
      my $res = $dbh->do($q, undef, $id) or do {
        syslog("info", "resend_data failed to delete sent id " . $DBI::errstr);
        return 0;
      };
    }
  }
  syslog("info", "Done resending:");

}

################################################################################
sub send_data()
################################################################################
{
  my $data = shift;

  syslog("info", "Sending: $data");

  my $response = $ua->post( $url, { 'w_sensor' => $data } );
  my $resp  = $response->decoded_content();

  &debug_print("Received reply: $resp\n");

  if ($resp ne "OK") {
    my $ts = time;

    $data =~ s/\;/,ts\:$ts\;/g;

    $query = "insert into fail values (null, ?)";
    my $sth = $dbh->do($query, undef, $data) or do {
      syslog('info', "cannot insert failed request");
    };
  } else {
    #try to send some failed shit
    &resend_data();
  }

}

################################################################################
sub fork_sensor()
################################################################################
{
  ($parent, $dev) = @_;
  pipe $parent, my $child or die;
  my $pid = fork();
  die "fork() failed: $!" unless defined $pid;

  if ($pid) {
    close $child;
  } else {
    close $parent;
    open(STDOUT, ">&=" . fileno($child)) or die;
  }

  $pid;
}

################################################################################
sub config_sensor()
################################################################################
{
  ($p, $h, $d) = @_;
  my %sensor = (
    pid => $p,
    handle => $h,
    device => $d,
  );
  return \%sensor;
}

################################################################################
sub is_child()
################################################################################
{
  foreach $i (keys %iot) {
    &debug_print("ischild:" . $iot{$i}{pid} . ".\n");

    if (!$iot{$i}{pid}) {
      &debug_print("zero\n");
      return 1;
    } else {
      &debug_print("not zero\n");
    }

  }
  return 0;
}

################################################################################
sub get_usb_devices()
################################################################################
{
  opendir(my $dh, "/dev/");
  my @usbs = grep { /^ttyUSB/} readdir($dh);
  closedir $dh;
  return @usbs;
}

################################################################################
sub connect_db
################################################################################
{

  my $dbfile = $dbpath.'/wiot.sqlite';

  $dbh = DBI->connect("dbi:SQLite:$dbfile", "", "",
    {
#       RaiseError     => 1,
       sqlite_unicode => 1,
    }
  );

  if (!$dbh) {
    syslog('info', "Cannot connect to db: " . $DBI::errstr);
    die;
  }
}

################################################################################
sub debug_print()
################################################################################
{
  my $data = shift;
  if ($debug) {
    print "$data\n";
    syslog("debug", $data);
  }
}
