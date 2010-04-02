package App::pfcsh::App;

use strict;
use warnings;

use constant PORT => 12111;
use constant FCSH => "$ENV{HOME}/opt/flex/bin/fcsh";

use Any::Moose;

use App::pfcsh::Daemon;

use Daemon::Daemonize qw/ :all /;
use Path::Class;
use IO::Socket::INET;

has fcsh => qw/ is ro required 1 isa Str init_arg fcsh /;
has port => qw/ is ro required 1 isa Int lazy 1 /, default => sub { PORT };
has pid_file => qw/ is ro lazy_build 1 isa Str /;
sub _build_pid_file {
    my $self = shift;
    return $self->_work_file( 'pid' );
}
has log_file => qw/ is ro lazy_build 1 isa Str /;
sub _build_log_file {
    my $self = shift;
    return $self->_work_file( 'log' );
}
has work_path => qw/ is ro lazy_build 1 isa Str /;
sub _build_work_path {
    return './pfcsh.';
}

sub _work_file {
    my $self = shift;
    my $name = shift;

    my $work_path = $self->work_path;
    my $file;
    if ( -d $work_path || $work_path =~ m{/$} ) {
        $file = file( $work_path, $name );
    }
    else {
        $file = file( "$work_path$name" );
    }

    $file = $file->absolute;

    return $file.'';
}

has connection => qw/ is ro lazy_build 1 /;
sub _build_connection {
    my $self = shift;
    my $port = $self->port;
    return IO::Socket::INET->new( PeerAddr => "127.0.0.1:$port", Proto => 'tcp' );
}

has daemon => qw/ is ro lazy_build 1 /; 
sub _build_daemon {
    my $self = shift;
    return App::pfcsh::Daemon->new( port => $self->port, fcsh => $self->fcsh );
}

sub pid {
    my $self = shift;
    return check_pidfile( $self->pid_file );
}

sub try_startup {
    my $self = shift;

    my $pid_file = $self->pid_file;
    my $log_file = $self->log_file;

    unless ( $self->pid ) {

        print "Attempting to launch server\n";

        # This should really go into App::pfcsh::Daemon

        daemonize( chdir => undef, close => 1, stderr => $log_file, run => sub {
            write_pidfile( $pid_file );
            $SIG{INT} = sub { delete_pidfile( $pid_file ) };
            $self->daemon->run;
        } );
        do { sleep 1 } until -s $pid_file;
    }
}

sub talk {
    my $self = shift;

    my $command = "@_";

    $self->try_startup;

    my $socket = $self->connection or die "Unable to connect";
    $socket->autoflush;
    $socket->print( "$command\n" );
    print $_ while <$socket>;
}

sub run {
    my $class = shift;

    my $self = $class->new( port => PORT, fcsh => FCSH );
    
    if( my $pid = $self->pid ) {
        print "Server running ($pid)\n";
    }
    else {
        print "Server not running\n";
    }

    return unless @ARGV;

    if ( $ARGV[0] eq 'stop' ) {
        if( my $pid = $self->pid ) {
            print "Shutdown $pid\n";
            kill 15, $pid;
        }
    }
    elsif ( $ARGV[0] eq 'start' ) {
        if ( my $pid = $self->pid ) {
            print "Server already running ($pid)\n";
        }
        else {

            $self->try_startup;

            $pid = $self->pid;
            print "Server running ($pid)\n";
        }
    }
    elsif ( $ARGV[0] eq 'ping' ) {
        $self->talk( "ping" );
    }
    else {
        $self->talk( "@ARGV" );
    }
}

1;
