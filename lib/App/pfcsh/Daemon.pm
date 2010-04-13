package App::pfcsh::Daemon;

use Any::Moose;
use AnyEvent::Socket;
use AnyEvent::Util qw/ fh_nonblocking /;
use IPC::RunSession::Simple;
use Path::Class;
use IPC::Open3 qw/open3/;
use JSON; my $json = JSON->new;

has fcsh_path => qw/ is ro required 1 isa Str init_arg fcsh /;
has port => qw/ is ro required 1 isa Int /;
has _sessions => qw/ is ro isa HashRef required 1 /, default => sub { {} };

sub session {
    my $self = shift;
    my $working_directory = shift;
    return $self->_sessions->{$working_directory} ||= do {
        App::pfcsh::Daemon::Session->new(
            working_directory => $working_directory,
            daemon => $self,
        );
    };
}

sub fcsh {
    my $self = shift;
    my $request = shift;

    my @arguments = @{ $request->{arguments} };
    my $environment_arguments = $request->{environment_arguments};
    my $working_directory = $request->{working_directory};
    my $session = $self->session( $working_directory );

    my $_fcsh;
    if ( defined $environment_arguments && length $environment_arguments ) {
        my $first_argument = shift @arguments;
        $_fcsh = "$first_argument $environment_arguments @arguments";
    }
    else {
        $_fcsh = "@arguments";
    }

    $self->log( "fcsh: $_fcsh" );
    return $session->fcsh( $_fcsh );
}

sub run {
    my $self = shift;

    my $port = $self->port;

    tcp_server undef, $port, sub {
        my $fh = shift;

        fh_nonblocking $fh, 0;

        sysread $fh, my $_request, 10_000 or warn "Couldn't read: $!";
        chomp $_request;
        my $request = $json->decode( $_request );

        $self->log( time, " $_request\n" );
        my $command = $request->{command};

        if      ( $command eq 'ping' ) {
            $fh->print( "Pong!\n" );
            $self->log( "Pong!" );
        }
        elsif   ( $command eq 'quit' || $command eq 'stop' ) {
            $fh->print( "Shutting down\n" );
            # TODO Close out session?
            exit 0;
        }
        elsif   ( $command eq 'fcsh' ) {
            my $output = $self->fcsh( $request );
            $fh->print( $output );
        }
        else {
            $fh->print( "Do not know how to handle command ($command)\n" );
        }
    };

    AnyEvent->condvar->wait;
}

sub log {
    my $self = shift;
    warn "@_";
}

package App::pfcsh::Daemon::Session;

use Any::Moose;

use Try::Tiny;
use Cwd qw/cwd/;

has daemon => qw/ is ro required 1 /, handles => [qw/ log /];
has working_directory => qw/ is ro required 1 isa Str /;
has fresh => qw/ is rw isa Bool /, default => 1;
has _compiles => qw/ is ro isa HashRef required 1 /, default => sub { {} };
has last_access => qw/ is rw isa Int /, default => 0;

has handle => qw/ is ro lazy_build 1 clearer close_handle predicate has_handle /, handles => [qw/ write /];
sub _build_handle {
    my $self = shift;

    my $fcsh = $self->daemon->fcsh_path;
    my $working_directory = $self->working_directory;
    
    $self->log( "Opening fcsh session via \"$fcsh\" in \"$working_directory\"\n" );

    my $cwd = cwd;
    my $handle = try {
        chdir $working_directory;
        IPC::RunSession::Simple->open( $fcsh );
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
