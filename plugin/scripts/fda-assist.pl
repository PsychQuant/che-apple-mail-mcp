#!/usr/bin/perl
# #422: bounded probes; only the atomic marker owner offers setup.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Path qw(make_path);
use IO::Select;
use POSIX qw(WNOHANG SIG_BLOCK SIG_SETMASK SIGTERM SIGINT SIGHUP);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
my ($binary, $marker_dir) = @ARGV;
exit 0 unless defined($binary) && defined($marker_dir) && -x $binary;
my $marker = "$marker_dir/fda-setup-offered";
my $original_parent = getppid();
my $active_pid;
my $handled = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP);
sub block_signals {
    my $old = POSIX::SigSet->new();
    POSIX::sigprocmask(SIG_BLOCK, $handled, $old) == 0 or die "cannot block probe signals";
    return $old;
}
sub restore_signals { POSIX::sigprocmask(SIG_SETMASK, $_[0]) == 0 or die "cannot restore probe signals" }

sub now { clock_gettime(CLOCK_MONOTONIC) }
sub debug {
    print STDERR "che-apple-mail-mcp: FDA assist $_[0]\n" if ($ENV{CHE_MAIL_HOOK_DEBUG} // '') eq '1';
}
sub terminate_probe {
    my $old_mask = block_signals();
    if (!defined $active_pid) { restore_signals($old_mask); return }
    my $pid = $active_pid;
    # Leader is not reaped yet: its PID cannot be reused while its private
    # process group is signalled. Children retaining stdout are covered.
    kill 'TERM', -$pid;
    sleep 0.10;
    kill 'KILL', -$pid;
    my $until = now() + 0.25;
    while (now() < $until) {
        last if waitpid($pid, WNOHANG) != 0;
        sleep 0.01;
    }
    # Never block SessionStart on an uninterruptible kernel wait. A leader
    # not yet reaped here is adopted when this helper exits.
    $active_pid = undef;
    restore_signals($old_mask);
}
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub {
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = 'IGNORE';
    debug('interrupted; preserving offer'); terminate_probe(); exit 0;
};
END { terminate_probe() if defined $active_pid }
sub probe {
    my ($stage, @args) = @_;
    pipe(my $reader, my $writer) or do { debug("$stage pipe unavailable"); return };
    my $old_mask = block_signals();
    my $pid = fork();
    if (!defined $pid) { restore_signals($old_mask); close $reader; close $writer; debug("$stage fork unavailable"); return }
    if ($pid == 0) {
        close $reader;
        POSIX::setpgid(0, 0) == 0 or POSIX::_exit(125);
        $SIG{TERM} = $SIG{INT} = $SIG{HUP} = 'DEFAULT';
        restore_signals($old_mask);
        open STDIN, '<', '/dev/null' or POSIX::_exit(125);
        open STDOUT, '>&', $writer or POSIX::_exit(125);
        open STDERR, '>', '/dev/null' or POSIX::_exit(125);
        close $writer;
        exec {$binary} $binary, @args or POSIX::_exit(125);
    }
    close $writer;
    POSIX::setpgid($pid, $pid); # child also sets it before exec
    $active_pid = $pid;
    restore_signals($old_mask);
    my $deadline = now() + 2.0;
    my $selector = IO::Select->new($reader);
    my $output = '';
    my $eof = 0;
    while (now() < $deadline) {
        if (!$eof && $selector->can_read(0.02)) {
            my $count = sysread($reader, my $chunk, 4097);
            if (!defined $count) { next }
            if ($count == 0) { $eof = 1; close $reader }
            else {
                $output .= $chunk;
                if (length($output) > 4096) {
                    debug("$stage output limit exceeded; preserving offer");
                    close $reader; terminate_probe(); return;
                }
            }
        }
        # Read EOF before reaping. A child inheriting stdout cannot turn the
        # wait into an unbounded operation or let the leader's PID be reused.
        if ($eof) {
            my $reap_mask = block_signals();
            my $done = waitpid($pid, WNOHANG);
            my $status = $?;
            if ($done != 0) { $active_pid = undef }
            restore_signals($reap_mask);
            if ($done == $pid) {
                if ($status & 127) { debug("$stage terminated by signal; preserving offer"); return }
                return ($status >> 8, $output);
            }
            if ($done == -1) { $active_pid = undef; debug("$stage wait failed"); return }
            sleep 0.01;
        }
    }
    close $reader unless $eof;
    debug("$stage timeout (2 seconds); preserving offer");
    terminate_probe(); return;
}
exit 0 if -e $marker || -l $marker;
my ($version_status, $version) = probe('version', '--version');
exit 0 unless defined($version_status);
if ($version_status != 0) { debug("version exited $version_status; preserving offer"); exit 0 }
$version =~ s/\A\s+|\s+\z//g;
if ($version !~ /\A(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?\z/) {
    debug('version unrecognized; preserving offer'); exit 0;
}
my ($major, $minor, $patch) = ($1, $2, $3);
if (length($major) > 6 || length($minor) > 6 || length($patch) > 6 ||
    $major < 2 || ($major == 2 && $minor < 28)) {
    debug('version predates quiet probe; preserving offer'); exit 0;
}
my ($status) = probe('quiet', '--check-fda', '--quiet');
exit 0 unless defined($status);
if ($status != 1) { debug("quiet exited $status; preserving offer"); exit 0 }
exit 0 if getppid() != $original_parent;
umask 0077;
eval { make_path($marker_dir, { mode => 0700 }) };
if ($@) { debug('marker directory unavailable'); exit 0 }
# Legacy empty marker, now with one atomic acquisition and no stale side lock.
if (!sysopen(my $claim, $marker, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
    debug('offer already claimed or marker unavailable'); exit 0;
}
print STDERR "che-apple-mail-mcp: Full Disk Access is not granted — opening the setup window.\n";
print STDERR "  It shows live status and links straight to the right System Settings pane.\n";
print STDERR "  (Shown once. Re-open any time with: $binary --setup)\n";
my $launcher = fork();
if (defined($launcher) && $launcher == 0) {
    my $child = fork();
    POSIX::_exit(1) unless defined $child;
    POSIX::_exit(0) if $child;
    POSIX::setsid();
    open STDIN, '<', '/dev/null' or POSIX::_exit(1);
    open STDOUT, '>', '/dev/null' or POSIX::_exit(1);
    open STDERR, '>', '/dev/null' or POSIX::_exit(1);
    exec {$binary} $binary, '--setup' or POSIX::_exit(1);
}
waitpid($launcher, 0) if defined $launcher;
exit 0;
