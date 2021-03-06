#######################################################################
#
# Argonaut::Libraries::Ldap2zone -- create zone files from LDAP DNS zones
#
# Copyright (C) 2012-2016 FusionDirectory project
#
# Author: Côme BERNIGAUD
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.
#
#######################################################################

package Argonaut::Libraries::Ldap2zone;

use Exporter 'import';              # gives you Exporter's import() method directly
@EXPORT_OK = qw(&argonaut_ldap2zone);  # symbols to export on request

use strict;
use warnings;

use 5.008;

use DNS::ZoneParse;

use Argonaut::Libraries::Common qw(:ldap :config);

my @record_types = ('a','aaaa','cname','mx','ns','ptr','txt','srv','hinfo','rp','loc');

my $NAMEDCHECKCONF = 'named-checkconf';

=item argonaut_ldap2zone
Write a zone file for the LDAP zone and its reverse, generate named.conf files and assure they are included
Params : zone name, verbose flag
=cut
sub argonaut_ldap2zone
{
  my($zone,$verbose,$norefresh,$dumpdir,$noreverse,$ldap2view) = @_;

  my $config = argonaut_read_config;

  my $settings = argonaut_get_ldap2zone_settings($config,$config->{'client_ip'});

  my $BIND_DIR                =   $settings->{'binddir'};
  my $BIND_CACHE_DIR          =   $settings->{'bindcachedir'};
  my ($output_BIND_DIR, $output_BIND_CACHE_DIR);
  if ($dumpdir) {
    $output_BIND_DIR = $dumpdir;
    $output_BIND_CACHE_DIR = $dumpdir;
  } else {
    $output_BIND_DIR = $BIND_DIR;
    $output_BIND_CACHE_DIR = $BIND_CACHE_DIR;
  }
  my $ALLOW_NOTIFY            =   $settings->{'allownotify'};
  my $ALLOW_UPDATE            =   $settings->{'allowupdate'};
  my $ALLOW_TRANSFER          =   $settings->{'allowtransfer'};
  my $TTL                     =   $settings->{'ttl'};
  my $RNDC                    =   $settings->{'rndc'};
  if (not defined $noreverse) {
    $noreverse = ($settings->{'noreverse'} eq 'TRUE');
  }

  if (not -d $output_BIND_DIR) {
    die "Bind directory '$output_BIND_DIR' does not exist\n";
  }

  if (not -d $output_BIND_CACHE_DIR) {
    die "Bind cache directory '$output_BIND_CACHE_DIR' does not exist\n";
  }

  if (!-e $RNDC) {
    die "Rndc path '$RNDC' doesn't seem to exists\n";
  }

  my ($ldap,$ldap_base) = argonaut_ldap_handle($config);

  if ($ldap2view) {
    print "Searching DNS View '$zone'\n" if $verbose;

    my $acls = aclsparse($ldap,$ldap_base,$verbose);
    create_acl_namedconf($acls,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$verbose);
    if ($ldap2view eq 'view') {
      my $view = viewparse($ldap,$ldap_base,$zone,$verbose);
      if (not defined($view)) {
        die "Could not find the view $zone\n";
      }
      create_namedconf($zone,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$ALLOW_NOTIFY,$ALLOW_UPDATE,$ALLOW_TRANSFER,$verbose, $view);
    }
  } else {
    if (substr($zone,-1) ne ".") { # If the end point is not there, add it
      $zone = $zone.".";
    }

    print "Searching DNS Zone '$zone'\n" if $verbose;

    my $dn = zoneparse($ldap,$ldap_base,$zone,$output_BIND_CACHE_DIR,$TTL,$verbose);
    create_namedconf($zone,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$ALLOW_NOTIFY,$ALLOW_UPDATE,$ALLOW_TRANSFER,$verbose);

    unless ($noreverse) {
      my $reverse_zones = get_reverse_zones($ldap,$ldap_base,$dn);

      foreach my $reverse_zone (@$reverse_zones) {
        print "Parsing reverse zone '$reverse_zone'\n" if $verbose;
        zoneparse($ldap,$ldap_base,$reverse_zone,$output_BIND_CACHE_DIR,$TTL,$verbose);
        create_namedconf($reverse_zone,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$ALLOW_NOTIFY,$ALLOW_UPDATE,$ALLOW_TRANSFER,$verbose);
      }
    }
  }

  refresh_main_namedconf($BIND_DIR,$output_BIND_DIR,$verbose);

  unless ($norefresh) {
    my $output = `$NAMEDCHECKCONF -z`;
    $? == 0 or die "$NAMEDCHECKCONF failed:\n$output\n";
    system("$RNDC reconfig")      == 0 or die "$RNDC reconfig failed : $?";
    system("$RNDC freeze")        == 0 or die "$RNDC freeze failed : $?";
    system("$RNDC reload")        == 0 or die "$RNDC reload failed : $?";
    system("$RNDC thaw")          == 0 or die "$RNDC thaw failed : $?";
  }
}

=item zoneparse
Create a Zone file for a zone taken from the LDAP
Params : ldap handle, ldap base, zone name, bind dir, TTL, verbose flag
Returns : dn of the zone
=cut
sub zoneparse
{
  my ($ldap,$ldap_base,$zone,$output_BIND_CACHE_DIR,$TTL,$verbose) = @_;
  my $mesg = $ldap->search( # perform a search
          base   => $ldap_base,
          filter => "zoneName=$zone",
          #~ attrs => [ 'ipHostNumber' ]
          );

  $mesg->code && die "Error while searching DNS Zone '$zone' :".$mesg->error;

  print "Found ".scalar($mesg->entries())." results\n" if $verbose;

  my $zonefile = DNS::ZoneParse->new(\"", $zone);

  my $records = {};
  foreach my $record (@record_types) {
    eval { #try
      $records->{$record} = $zonefile->$record();
    };
    if ($@) { # catch
      print "This DNS::ZoneParse version does not support '$record' record\n" if $verbose;
    };
  }

  my $dn; # Dn of zone entry;

  my %unicityTest = ();

  foreach my $entry ($mesg->entries()) {
    my $name = $entry->get_value("relativeDomainName");
    if(!$name) { print "no name\n"; next; }
    my $class = $entry->get_value("dnsClass");
    if(!$class) { print "no class\n"; next; }
    my $ttl = $entry->get_value("dNSTTL");
    if(!$ttl) {
      $ttl = "";#$default_ttl;
    }
    while(my ($type,$list) = each %{$records}){
      foreach my $value ($entry->get_value($type."Record")) {
        if (defined $unicityTest{$type.$name.$value.$class.$ttl}) {
          # Avoid putting twice the same record
          next;
        } else {
          $unicityTest{$type.$name.$value.$class.$ttl} = 1;
        }
        if($type eq "txt") {
          push @{$list},{ name => $name, class => $class,
                          text => $value, ttl => $ttl, ORIGIN => $zone };
        } else {
          if($name ne "@") {
            push @{$list},{ name => $name, class => $class,
                            host => $value, ttl => $ttl, ORIGIN => $zone };
          } else {
            push @{$list},{ host => $value, ttl => $ttl, ORIGIN => $zone };
          }
        }
        print "Added record $type $name $class $value $ttl\n" if $verbose;
      }
    }
    my $soa = $entry->get_value("soaRecord");
    if($soa) {
      my $soa_record = $zonefile->soa();
      my (@soa_fields) = split(' ',$soa);
      $soa_record->{'primary'}  = $soa_fields[0];
      $soa_record->{'email'}    = $soa_fields[1];
      $soa_record->{'serial'}   = $soa_fields[2];
      $soa_record->{'refresh'}  = $soa_fields[3];
      $soa_record->{'retry'}    = $soa_fields[4];
      $soa_record->{'expire'}   = $soa_fields[5];
      $soa_record->{'minimumTTL'}  = $soa_fields[6];

      $soa_record->{'class'}    = $class;
      $soa_record->{'ttl'}      = $TTL;
      $soa_record->{'origin'}   = $name;
      $soa_record->{'ORIGIN'}   = $zone;
      print "Added record SOA $name $class $soa $TTL\n" if $verbose;
      $dn = $entry->dn();
    }
  }

  if (not defined $dn) {
    die "Zone $zone was not found in LDAP!\n";
  }

  # write the new zone file to disk
  print "Writing DNS Zone '$zone' in $output_BIND_CACHE_DIR/db.$zone\n" if $verbose;
  my $file_output = "$output_BIND_CACHE_DIR/db.$zone";
  my $newzone;
  open($newzone, '>', $file_output) or die "error while trying to open $file_output";
  print $newzone $zonefile->output();
  close $newzone;

  return $dn;
}

=item viewparse
=cut
sub viewparse
{
  my ($ldap,$ldap_base,$view,$verbose) = @_;
  my $mesg = $ldap->search(
    base   => $ldap_base,
    filter => "(&(objectClass=fdDNSView)(cn=$view))",
  );

  $mesg->code && die "Error while searching DNS View '$view' :".$mesg->error."\n";
  print "Found ".scalar($mesg->entries())." results\n" if $verbose;

  if (scalar($mesg->entries()) == 0) {
    return;
  }

  my %view = (
    'name'            => ($mesg->entries)[0]->get_value('cn'),
    'clientsacl'      => (($mesg->entries)[0]->get_value('fdDNSViewMatchClientsAcl') or ''),
    'destinationsacl' => (($mesg->entries)[0]->get_value('fdDNSViewMatchDestinationsAcl') or ''),
    'recursiveonly'   => (($mesg->entries)[0]->get_value('fdDNSViewMatchRecursiveOnly') or 'FALSE'),
    'zones'           => [],
  );

  my $zonesDN = ($mesg->entries)[0]->get_value('fdDNSZoneDn', asref => 1);

  foreach my $zoneDN (@$zonesDN) {
    my $mesg = $ldap->search (base => $zoneDN, filter => '(objectClass=*)', scope => 'base');
    $mesg->code && die "Error while loading zone $zoneDN for DNS View '$view' :".$mesg->error."\n";
    if (scalar($mesg->entries()) == 0) {
      die "Could not find zone $zoneDN for DNS View '$view'\n";
    }
    push @{$view{zones}}, ($mesg->entries)[0]->get_value('zoneName');
  }

  return \%view;
}

=item aclsparse
=cut
sub aclsparse
{
  my ($ldap,$ldap_base,$verbose) = @_;
  my $mesg = $ldap->search(
    base    => $ldap_base,
    filter  => "(objectClass=fdDNSAcl)",
    attrs   => ['cn','fdDNSAclMatchList']
  );

  $mesg->code && die "Error while searching DNS acls:".$mesg->error."\n";
  print "Found ".scalar($mesg->entries())." results\n" if $verbose;

  my @entries = $mesg->entries();
  my @acls    = ();

  foreach my $entry (@entries) {
    my @matchlist = $entry->get_value('fdDNSAclMatchList');
    push @acls, {
      'name'      => $entry->get_value('cn'),
      'matchlist' => join(';', @matchlist),
    }
  }

  return \@acls;
}

=item get_reverse_zones
Params : ldap handle, ldap base, zone dn
Returns : reverse zones names
=cut
sub get_reverse_zones
{
  my($ldap,$ldap_base,$zone_dn) = @_;
  my $mesg = $ldap->search( # Searching reverse zone name
          base   => $zone_dn,
          filter => "(&(zoneName=*arpa*)(relativeDomainName=@))",
          scope => 'one',
          attrs => [ 'zoneName' ]
          );

  $mesg->code && die "Error while searching DNS reverse zone :".$mesg->error;

  my @reverse_zones = ();
  foreach my $entry ($mesg->entries()) {
    push @reverse_zones, $entry->get_value("zoneName");
  }

  return \@reverse_zones;
}

=item create_namedconf
Create file $output_BIND_DIR/named.conf.ldap2zone
Params : zone name, reverse zone names
Returns :
=cut
sub create_namedconf
{
  my($zone,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$ALLOW_NOTIFY,$ALLOW_UPDATE,$ALLOW_TRANSFER,$verbose,$view) = @_;

  if($ALLOW_NOTIFY eq "TRUE") {
    $ALLOW_NOTIFY = "notify yes;";
  } else {
    $ALLOW_NOTIFY = "";
  }

  if ($ALLOW_UPDATE ne "") {
    $ALLOW_UPDATE = "allow-update {$ALLOW_UPDATE};";
  } else {
    $ALLOW_UPDATE = "";
  }

  if ($ALLOW_TRANSFER ne "") {
    $ALLOW_TRANSFER = "allow-transfer {$ALLOW_TRANSFER};";
  } else {
    $ALLOW_TRANSFER = "";
  }

  print "Writing named.conf file in $output_BIND_DIR/named.conf.ldap2zone.$zone\n" if $verbose;
  my $namedfile;
  open($namedfile, '>', "$output_BIND_DIR/named.conf.ldap2zone.$zone") or die "error while trying to open $output_BIND_DIR/named.conf.ldap2zone.$zone";
  my $zones;
  if (defined $view) {
    $zones = $view->{'zones'};

    print $namedfile <<EOF;
view "$view->{'name'}" {
EOF

    if ($view->{'clientsacl'} ne '') {
      print $namedfile <<EOF;
  match-clients {$view->{'clientsacl'}; };
EOF
    }
    if ($view->{'destinationsacl'} ne '') {
      print $namedfile <<EOF;
  match-destinations {$view->{'destinationsacl'}; };
EOF
    }
    my $recursiveonly = ($view->{'recursiveonly'} eq "TRUE" ? "yes" : "no");
    print $namedfile <<EOF;
  match-recursive-only $recursiveonly;
EOF
  } else {
    $zones = [$zone];
  }
  foreach my $zone_ (@$zones) {
    print $namedfile <<EOF;
zone "$zone_" {
  type master;
  $ALLOW_NOTIFY
  file "$BIND_CACHE_DIR/db.$zone_";
  $ALLOW_UPDATE
  $ALLOW_TRANSFER
};
EOF
  }
  if (defined $view) {
    print $namedfile <<EOF;
};
EOF
  }
  close $namedfile;
}

=item create_acl_namedconf
Create file $output_BIND_DIR/named.conf.acls
=cut
sub create_acl_namedconf
{
  my($acls,$BIND_DIR,$BIND_CACHE_DIR,$output_BIND_DIR,$verbose) = @_;

  print "Writing named.conf file in $output_BIND_DIR/named.conf.acls\n" if $verbose;
  my $namedfile;
  open($namedfile, '>', "$output_BIND_DIR/named.conf.acls") or die "error while trying to open $output_BIND_DIR/named.conf.acls";
  foreach my $acl (@$acls) {
    print $namedfile <<EOF;
  acl $acl->{'name'} {$acl->{'matchlist'}; };
EOF
  }
}

sub refresh_main_namedconf
{
  my($BIND_DIR,$output_BIND_DIR,$verbose) = @_;

  print "Writing file $output_BIND_DIR/named.conf.ldap2zone\n" if $verbose;
  my $namedfile;
  open($namedfile, '>', "$output_BIND_DIR/named.conf.ldap2zone") or die "error while trying to open $output_BIND_DIR/named.conf.ldap2zone";
  opendir DIR, $output_BIND_DIR or die "Error while openning $output_BIND_DIR!";
  my @files = readdir DIR;
  foreach my $file (grep { /^named\.conf\.ldap2zone\./ } @files) {
    print $namedfile qq{include "$BIND_DIR/$file";\n};
  }
  close $namedfile;
}

1;

__END__
