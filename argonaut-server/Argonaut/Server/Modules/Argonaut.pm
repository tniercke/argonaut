#######################################################################
#
# Argonaut::Server::Modules::Argonaut -- Argonaut client module
#
# Copyright (C) 2012-2016 FusionDirectory project
#
# Authors: Côme BERNIGAUD
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

package Argonaut::Server::Modules::Argonaut;

use strict;
use warnings;

use 5.008;

use Argonaut::Libraries::Common qw(:ldap :file :config :string);

my @unlocked_actions = ['System.halt', 'System.reboot'];

sub new
{
  my ($class) = @_;
  my $self = {};
  bless( $self, $class );
  return $self;
}

sub handle_client {
  my ($self, $mac,$action) = @_;

  if ($action =~ m/^Deployment.(reboot|wake)$/) {
    $action =~ s/^Deployment./System./;
  } elsif ($action =~ m/^Deployment./) {
    $main::log->debug("[Argonaut] Can't handle Deployment actions");
    return 0;
  }

  if ($action eq 'System.wake') {
    $self->{mac}    = $mac;
    $self->{action} = $action;
    return 1;
  }

  my $ip = main::getIpFromMac($mac);

  eval { #try
    my $settings = argonaut_get_client_settings($main::config,$ip);
    %$self = %$settings;
    $self->{action} = $action;
  };
  if ($@) { #catch
    $main::log->debug("[Argonaut] Can't handle client : $@");
    return 0;
  };
  my $server_settings = argonaut_get_server_settings($main::config,$main::server_ip);
  $self->{cacertfile} = $server_settings->{cacertfile};
  $self->{token} = $server_settings->{token};

  return 1;
}

=pod
=item do_action
Execute a JSON-RPC method on a client which the ip is given.
Parameters : ip,action,params
=cut
sub do_action {
  my ($self, $params) = @_;
  my $action = $self->{action};

  if ($action eq 'System.wake') {
    main::wakeOnLan($self->{'mac'});
    return 1;
  }

  if ($self->{'locked'} && (grep {$_ eq $action} @unlocked_actions)) {
    die 'This computer is locked';
  }

  if ($action eq 'ping') {
    my $ok = 'OK';
    my $res = $self->launch('echo',$ok);
    return ($res eq $ok);
  } else {
    return $self->launch($action,$params);
  }
}

=pod
=item launch
Execute a JSON-RPC method on a client which the ip is given.
Parameters : ip,action,params
=cut
sub launch { # if ip pings, send the request
  my ($self, $action,$params) = @_;

  if ($action =~ m/^[^.]+\.[^.]+$/) {
    $action = 'Argonaut.ClientDaemon.Modules.'.$action;
  }

  my $ip = $self->{'ip'};
  # this line is only needed when debugging stuff on localhost
  #$ip = "localhost";

  $main::log->info("sending action $action to $ip");

  my $client;
  if (USE_LEGACY_JSON_RPC) {
    $client = new JSON::RPC::Legacy::Client;
  } else {
    $client = new JSON::RPC::Client;
  }
  $client->version('1.0');
  if ($self->{'protocol'} eq 'https') {
    if ($client->ua->can('ssl_opts')) {
      $client->ua->ssl_opts(
        verify_hostname   => 1,
        SSL_ca_file       => $self->{'cacertfile'},
        SSL_verifycn_name => $self->{'certcn'}
      );
      $client->ua->credentials($ip.":".$self->{'port'}, "JSONRPCRealm", "", argonaut_gen_ssha_token($self->{'token'}));
    }
  }

  my $callobj = {
    method  => $action,
    params  => [$params],
  };

  my $res = $client->call($self->{'protocol'}."://".$ip.":".$self->{'port'}, $callobj);

  if($res) {
    if ($res->is_error) {
      $main::log->error("Error : ".$res->error_message);
      die "Error : ", $res->error_message."\n";
    }
    else {
      $main::log->info("Result : ".$res->result);
      return $res->result;
    }
  }
  else {
    $main::log->info("Status : ".$client->status_line);
    die "Status : ".$client->status_line."\n";
  }
}

1;

__END__
