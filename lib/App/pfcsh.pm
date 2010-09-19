package App::pfcsh;
# ABSTRACT: Compile Flex & Air applications from a persistent commandline

use strict;
use warnings;

use Net::ClientServer;
use AnyEvent::Handle;
use Cwd qw/ cwd /;
use JSON;
use Try::Tiny;

my $pool;

sub run {
    my $self = shift;
    my @arguments = @_;

    $pool = App::pfcsh::SessionPool->new;

    my $platform = Net::ClientServer->new(
        name => 'pfcsh',
        home => 1,
        port => 5130,
        daemon => 1,
        start => sub {
            $0 = 'pfcsh',
        },
        serve => sub {
            $SIG{CHLD} = 'DEFAULT';
            my $client = shift;
            return if $client->eof;
            my @json;
            while ( <$client> ) {
                chomp;
                last unless $_;
                push @json, "$_\n";
            }
            my $json = join '', @json;
            # This seems to break Open3 or something
#            Net::ClientServer->stdin2socket( $client );
#            Net::ClientServer->stdout2socket( $client );

            my $request =  
                try { JSON->new->decode( $json ) }
                catch { die "Unable to decode JSON: $_:\n$json" };

            $self->request( $client, $request );

            $client->close;
        },
    );

    my $restart = $arguments[0] eq 'restart';

    if ( $restart ) {
        if ( my $pid = $platform->pid ) {
            kill 1, $pid;
            sleep 1;
        }
    }

    $platform->start;

    my $socket;
    while ( ! ( $socket = $platform->client_socket ) ) {
        print "> Waiting for server to start\n";
        sleep 1;
    }
    print "> Connected via $socket (", $platform->pid, ")\n";

    my $request;
    my $done = AnyEvent->condvar;
    my $ae;
    $ae = AnyEvent::Handle->new(
        fh => $socket,
        on_eof => sub {
            $done->send;
        },
        on_error => sub {
        },
        on_read => sub {
            my $hdl = shift;
            $hdl->push_read( line => sub {
                my ( undef, $line ) = @_;
                print "$line\n";
            } );
        },
    );

    exit if $restart;

    $ae->push_write( JSON->new->pretty->encode( {
        arguments => join( ' ', @arguments ),
        directory => cwd,
    } ) );
    $ae->push_write( "\n" );

    $done->recv;
}

sub request {
    my $self = shift;
    my $client = shift;
    my $request = shift;

    my ( $arguments, $directory ) = @$request{qw/ arguments directory /};

    my $session = $pool->session( $directory );
    $client->print( $session->fcsh( $arguments ) );
}

package App::pfcsh::SessionPool;

use Any::Moose;

has pool => qw/ is ro isa HashRef required 1 /, default => sub { {} };

sub session {
    my $self = shift;
    my $working_directory = shift;
    my $session = $self->pool->{$working_directory} ||= do {
        App::pfcsh::Session->new(
            working_directory => $working_directory,
        );
    };
    return $session;
}

package App::pfcsh::Session;

use Any::Moose;

use Try::Tiny;
use Cwd qw/cwd/;
use IPC::RunSession::Simple;

has working_directory => qw/ is ro required 1 isa Str /;
has fresh => qw/ is rw isa Bool /, default => 1;
has _compiles => qw/ is ro isa HashRef required 1 /, default => sub { {} };
has last_access => qw/ is rw isa Int /, default => 0;

sub log {
    my $self = shift;
    my $message = join ' ', @_;
    chomp $message;
    print STDERR $message, "\n";
}

has handle => qw/ is ro lazy_build 1 clearer close_handle predicate has_handle /, handles => [qw/ write /];
sub _build_handle {
    my $self = shift;

    my $fcsh = $ENV{PFCSH_FCSH} or die "\$ENV{PFCSH_FCSH} is missing";
    $self->log( $fcsh );

    my $working_directory = $self->working_directory;
    
    $self->log( "Opening fcsh session via \"$fcsh\" in \"$working_directory\"\n" );

    my $cwd = cwd;
    my $handle = try {
        chdir $working_directory;
        my $handle = IPC::RunSession::Simple->open( $fcsh );
        $handle;
    } finally {
        chdir $cwd;
    };

    $self->last_access( time );
    $self->fresh( 1 );

    return $handle;
}

sub read_until_prompt {
    my $self = shift;

    $self->fresh( 0 );

    my $result = $self->handle->read_until( qr/\(fcsh\) /, 30 );

    if      ( $result->closed )     { $self->log( "Session closed\n" ) }
    elsif   ( $result->expired )    { $self->log( "Session timed out\n" ) }
    else                            { return $result->content }

    $self->close_handle;

    return undef;
}

sub fcsh {
    my $self = shift;
    my $input = shift;

    chomp $input;

    my $output = '';

    if ( $self->last_access && ( ( $self->last_access - time ) > 60 * 60 ) ) {
        $self->close_handle;
    }

    $output .= $self->read_until_prompt || '' if $self->fresh;

    my $compiles = $self->_compiles;
    my $compile;
    if ( $input =~ m/^\s*(?:mxmlc)\s+(.*)/ ) {
        if ( $compiles->{$input} ) {
            $input = "compile $compiles->{$input}";
        }
        else {
            $compile = 1;
        }
    }

    $self->write( "$input\n" );
    
    $output .= $self->read_until_prompt || '';

    if ( $compile ) {
        if ( $output =~ m/Assigned (\d+) as the compile target id/ ) {
            $compiles->{$input} = $1;
        }
    }

    return $output."\n";
}

1;
