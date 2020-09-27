#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long::Descriptive;
use Config::General;
use Log::Log4perl qw(get_logger :easy);

use POSIX;

use IO::Socket::INET;
use IO::Socket::UNIX;

    # CONFIG_FILE     => '/etc/simple-telnetd.conf',
use constant {
    CONFIG_FILE     => '/home/ymka/Applications/Perl/simple-telnetd.conf',
    PID_FILE 	    => '/tmp/simple-telnetd.pid',
};

my ($config, $opts) = init();

daemonize();
get_logger()->info("Begin");

my $flag = 1;

$SIG{KILL} = $SIG{QUIT} = $SIG{INT} = $SIG{TERM} = sub {
    $flag = 0;
};

$SIG{HUP} = sub {
    get_logger()->info('got HUP, reloading config');
    $config = configure($opts->config // CONFIG_FILE());
};


my ($listen_sock, $INET);

if (defined $opts->socket_file) {

    $listen_sock = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM(),
        Local  => $opts->socket_file,
        Listen => 1,
    ) or die("can't create listen socket $!");

} else {

    $listen_sock = IO::Socket::INET->new(
        LocalPort => $config->{socket_port},
        Listen    => $config->{socket_queue_size},
        Proto     => 'tcp',
        Timeout   => $config->{socket_timeout},
        Reuse     => 1,
    ) or die("can't create listen socket $!");
    $INET = 1;

}

while($flag) {
    my $client_sock = $listen_sock->accept();
    next if !defined $client_sock;

    my $pid = fork();
    die "cannot fork $!" if !defined $pid;

    if ($pid == 0) {
        process_request($client_sock);
        exit;
    } else {
        close $client_sock;
    }
}

close $listen_sock;
get_logger->info("unlinking pid file " . PID_FILE());
unlink(PID_FILE());
get_logger->info("unlinking socket file " . $opts->socket_file) if defined $opts->socket_file;
unlink($opts->socket_file) if defined $opts->socket_file;
get_logger->info("Done");





sub process_request {
    my $socket = shift;
    die("missing client socket") if !defined $socket;

    my $client_command = $socket->getline();
    chomp($client_command);
    $client_command =~ /^(\w+)/;
    my $command = $1;
    
    if( !exists $config->{allowed_commands}->{$command} ) {
        my $peerhost = "";
        $peerhost = "from " . $socket->peerhost() if defined $INET and $INET == 1;

        get_logger->warn("got not allowed command: '$client_command' $peerhost");

        print $socket "command $client_command is not allowed\n";
        close $socket;

        exit;
    }

    get_logger()->info("got command: '$client_command'");

    my $result;
    eval {
        local $SIG{ALRM} = sub { die "$client_command timed out"};
        alarm($opts->command_timeout // $config->{command_timeout});
        $result = `$client_command`;
    };
    if ($@) {
        $result = $@;
    }

    print $socket $result;
    close $socket;

    return;
}


sub daemonize {
    fork() and exit(0);

    POSIX::setsid();
    
    open(STDIN,  ">/dev/null");
    open(STDOUT, ">/dev/null");
    open(STDERR, ">/dev/null");

    chdir '/';

    umask(002);

    $ENV{'PATH'} = $config->{env_path};

    my $pid_file = PID_FILE();
    if (-e $pid_file) {
        open(my $fh, '<', $pid_file) or die "failed to open $pid_file $!";
        my $pid = <$fh>;
        close $fh;
        get_logger()->info("there is already running daemon with pid=$pid, exiting") and exit(0);
        
    } else {
        open(my $fh, '>', $pid_file) or die "failed to open $pid_file $!";
        print $fh "$$";
        close $fh;
    }

    return;
}

sub configure {
    my $config_path = shift;
    die("config path is missing") if !defined $config_path;

    my $config = {
        Config::General->new(
            -ConfigFile       => $config_path // CONFIG_FILE(),
            -ForceArray       => 1,
        )->getall()
    };

    return $config;
}


sub init {
    my ($opts, $usage) = describe_options(
        '%c %o',
        [ 'config|c=s',         'path to config'                     ],
        [ 'command_timeout=i',  'command timeout in seconds'         ],
        [ 'socket_file=s',      'socket file to use instead of INET' ],
        [ 'help',               'print help'                         ],
    );
    die ( $usage->text ) if $opts->help;
    my $conf = configure($opts->config // CONFIG_FILE());

    Log::Log4perl::init( $conf->{log4perl} );
    # Log::Log4perl->easy_init($INFO);

    $SIG{__DIE__} = sub {
        my $msg = shift;
        get_logger()->error($msg);
        die $msg;
    };

    $SIG{__WARN__} = sub {
        my $msg = shift;
        get_logger()->warn($msg);
        warn $msg;
    };

    $SIG{CHLD} = sub {
        while (waitpid(-1, WNOHANG) > 0) {}
    };

    return ($conf, $opts);
}
