package App::pfcsh::Daemon;

use strict;
use warnings;

use Any::Moose;
use AnyEvent::Socket;
use AnyEvent::Util qw/ fh_nonblocking /;
use IPC::RunSession::Simple;
use Path::Class;
use IPC::Open3 qw/open3/;

has fcsh_path => qw/ is ro required 1 isa Str init_arg fcsh /;
has port => qw/ is ro required 1 isa Int /;

has session => qw/ is ro lazy_build 1 clearer close_session predicate has_session /;
sub _build_session {
    my $self = shift;
    my $fcsh = $self->fcsh_path;
    $self->log( "Opening fcsh session via \"$fcsh\"\n" );
    return IPC::RunSession::Simple->open( $fcsh );
}

sub read_until_prompt {
    my $self = shift;

    my $result = $self->session->read_until( qr/\(fcsh\) /, 30 );

    if ( $result->closed )      { $self->log( "Session closed\n" ) }
    elsif ( $result->expired )  { $self->log( "Session timed out\n" ) }
    else                        { return $result->content }

    $self->close_session;

    return undef;
}

my %compile;
sub fcsh {
    my $self = shift;
    my $input = shift;

    chomp $input;

    my $output = '';

    unless( $self->has_session ) {
        $output .= $self->read_until_prompt || '';
    }

    my $compile;
    if ( $input =~ m/^\s*(?:mxmlc)\s+(.*)/ ) {
        if ( $compile{$input} ) {
            $input = "compile $compile{$input}";
        }
        else {
            $compile = 1;
        }
    }

    $self->session->write( "$input\n" );
    
    $output .= $self->read_until_prompt || '';

    if ($compile) {
        if ( $output =~ m/Assigned (\d+) as the compile target id/ ) {
            $compile{$input} = $1;
        }
    }

    return $output."\n";
}

sub run {
    my $self = shift;

    my $port = $self->port;

    tcp_server undef, $port, sub {
        my $fh = shift;

        fh_nonblocking $fh, 0;

        sysread $fh, my $command, 10_000 or warn "Couldn't read: $!";
        chomp $command;

        $self->log( time, " $command\n" );

        if ( $command =~ m/^\s*ping\s*$/i ) {
            $fh->print( "Pong!\n" );
            warn "Pong!";
        }
        elsif ( $command =~ m/^\s*quit\s*$/i ) {
            $fh->print( "Shutting down\n" );
            $self->close_session;
            exit 0;
        }
        else {
            my $output = $self->fcsh( $command );
            $fh->print( $output );
        }
    };

    AnyEvent->condvar->wait;
}

sub log {
    my $self = shift;
    warn "@_";
}

1;
