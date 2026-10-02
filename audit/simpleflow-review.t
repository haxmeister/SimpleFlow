#!/usr/bin/env perl
#
# Audit probes for SimpleFlow 0.191.
#
# These tests intentionally assert the CURRENT problematic behaviour so that
# a green run is evidence that the findings in SIMPLEFLOW_AUDIT_2026-10-02.md
# are reproducible. This file is audit-only and is not intended to be merged.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use File::Spec;
use Cwd ();
use Time::HiRes qw(setitimer getitimer ITIMER_REAL);
use SimpleFlow qw(task parallel);

my $root = tempdir(CLEANUP => 1);

sub in_fresh_dir {
    my ($code) = @_;
    my $old = Cwd::getcwd();
    my $dir = File::Spec->catdir($root, 'case-' . int(rand(1_000_000)) . '-' . $$);
    mkdir $dir or die "mkdir $dir: $!";
    chdir $dir or die "chdir $dir: $!";
    my ($ok, $err);
    {
        local $@;
        $ok = eval { $code->(); 1 };
        $err = $@;
    }
    chdir $old or die "chdir $old: $!";
    die $err if !$ok;
    return;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

subtest 'SIGCHLD=IGNORE makes task misreport a successful command' => sub {
    local $SIG{CHLD} = 'IGNORE';
    local $SIG{__WARN__} = sub { };
    my $r = task(
        cmd   => [$^X, '-e', 'exit 0'],
        die   => 0,
        quiet => 1,
    );
    is($r->{'will.do'}, 'FAILED',
        'CURRENT BUG CONFIRMED: successful child is reported as FAILED');
    is($r->{'exit'}, -1,
        'CURRENT BUG CONFIRMED: auto-reaped child becomes exit -1');
};

subtest 'SIGCHLD=IGNORE makes parallel jobs>1 fail to reap its own children' => sub {
    my $alarm_fired = 0;
    my $error = '';
    {
        local $SIG{CHLD} = 'IGNORE';
        local $SIG{ALRM} = sub { $alarm_fired = 1; die "AUDIT_PARALLEL_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };
        alarm 2;
        eval {
            parallel(
                jobs  => 2,
                tasks => [
                    { cmd => [$^X, '-e', 'exit 0'], quiet => 1 },
                    { cmd => [$^X, '-e', 'exit 0'], quiet => 1 },
                ],
            );
        };
        $error = $@;
        alarm 0;
    }
    ok($alarm_fired,
        'CURRENT BUG CONFIRMED: parallel did not finish before the safety alarm');
    like($error, qr/AUDIT_PARALLEL_TIMEOUT/,
        'the escape was the audit safety alarm, not normal completion');
};

subtest 'stale.cmd omits the synthetic SIMPLEFLOW_THREADS environment value' => sub {
    in_fresh_dir(sub {
        my $out = 'threads.txt';
        my $code = q{open my $f, '>', $ARGV[0] or die $!; print $f $ENV{SIMPLEFLOW_THREADS}; close $f};
        my $first = task(
            cmd           => [$^X, '-e', $code, $out],
            'output.file' => $out,
            'stale.cmd'   => 1,
            threads       => 1,
            quiet         => 1,
        );
        is(slurp($out), '1', 'first run used one thread');

        my $second = task(
            cmd           => [$^X, '-e', $code, $out],
            'output.file' => $out,
            'stale.cmd'   => 1,
            threads       => 2,
            quiet         => 1,
        );
        is($second->{'cmd.changed'}, 0,
            'CURRENT BUG CONFIRMED: threads change is not in the command signature');
        is($second->{done}, 'before',
            'CURRENT BUG CONFIRMED: second task is skipped');
        is(slurp($out), '1',
            'CURRENT BUG CONFIRMED: stale output made with the old thread value remains');
    });
};

subtest 'stale.cmd loses argument boundaries for wrappers' => sub {
    my $a = task(
        cmd       => ['prog'],
        wrapper   => ['wrap', 'a b'],
        'dry.run' => 1,
        quiet     => 1,
    );
    my $b = task(
        cmd       => ['prog'],
        wrapper   => ['wrap a', 'b'],
        'dry.run' => 1,
        quiet     => 1,
    );
    is($a->{'wrapped.cmd'}, $b->{'wrapped.cmd'},
        'CURRENT BUG CONFIRMED: two different argv vectors have the same wrapped.cmd string');
    is(
        SimpleFlow::_command_signature($a, ['prog']),
        SimpleFlow::_command_signature($b, ['prog']),
        'CURRENT BUG CONFIRMED: stale.cmd hashes those different wrappers identically',
    );
};

subtest 'NUL is accepted in env values and creates a deterministic stale.cmd collision' => sub {
    my $a = { env => { A => "x\0B=y" }, 'wrapped.cmd' => '' };
    my $b = { env => { A => 'x', B => 'y' }, 'wrapped.cmd' => '' };
    is(
        SimpleFlow::_command_signature($a, ['prog']),
        SimpleFlow::_command_signature($b, ['prog']),
        'CURRENT BUG CONFIRMED: NUL makes two different environments hash identically',
    );

    local $SIG{__WARN__} = sub { };
    my $r = task(
        cmd   => [$^X, '-e', q{print length($ENV{A})}],
        env   => { A => "x\0y" },
        quiet => 1,
    );
    is($r->{stdout}, '1',
        'CURRENT BUG CONFIRMED on POSIX: exec truncates the accepted env value at NUL');
};

subtest 'a trailing slash on output.dir makes failure cleanup destructive and ineffective' => sub {
    in_fresh_dir(sub {
        my $out = 'made';
        my $declared = $out . '/';
        my $code = q{
            my $d = $ARGV[0];
            mkdir $d or die $!;
            mkdir "$d/.failed" or die $!;
            open my $f, '>', "$d/.failed/valuable" or die $!;
            print $f "keep me";
            close $f;
            exit 7;
        };
        local $SIG{__WARN__} = sub { };
        my $r = task(
            cmd          => [$^X, '-e', $code, $out],
            'output.dir' => $declared,
            die          => 0,
            quiet        => 1,
        );
        is($r->{'will.do'}, 'FAILED', 'the command failed as intended');
        ok(!-e "$out/.failed/valuable",
            'CURRENT BUG CONFIRMED: SimpleFlow deleted the command-created .failed subtree');
        ok(-d $out,
            'CURRENT BUG CONFIRMED: the failed declared output itself was not moved aside');
    });
};

subtest 'stale.cmd signature writer follows a pre-planted symlink and clobbers its target' => sub {
    in_fresh_dir(sub {
        my $out = 'result.txt';
        my $victim = File::Spec->rel2abs('victim.txt');
        open my $v, '>', $victim or die $!;
        print $v "DO NOT TOUCH\n";
        close $v;

        my $sig = SimpleFlow::_signature_file($out);
        my ($vol, $dirs) = File::Spec->splitpath($sig);
        my $sig_dir = File::Spec->catpath($vol, $dirs, '');
        File::Path::mkpath($sig_dir);
        my $partial = "$sig.$$";
        symlink($victim, $partial) or die "symlink $partial -> $victim: $!";

        my $code = q{open my $f, '>', $ARGV[0] or die $!; print $f "ok"; close $f};
        task(
            cmd           => [$^X, '-e', $code, $out],
            'output.file' => $out,
            'stale.cmd'   => 1,
            quiet         => 1,
        );

        isnt(slurp($victim), "DO NOT TOUCH\n",
            'CURRENT BUG CONFIRMED: the predictable temporary signature path followed the symlink');
        ok(-l $sig,
            'CURRENT BUG CONFIRMED: the final signature path is now the attacker-planted symlink');
    });
};

subtest 'timeout destroys the interval part of a caller ITIMER_REAL timer' => sub {
    SKIP: {
        skip 'POSIX timer/fork behaviour is not applicable on MSWin32', 2 if $^O eq 'MSWin32';
        local $SIG{ALRM} = sub { };
        setitimer(ITIMER_REAL, 5, 2);
        task(
            cmd     => [$^X, '-e', 'exit 0'],
            timeout => 10,
            quiet   => 1,
        );
        my ($value, $interval) = getitimer(ITIMER_REAL);
        setitimer(ITIMER_REAL, 0, 0);
        cmp_ok($value, '>', 0,
            'a one-shot alarm was restored');
        is($interval, 0,
            'CURRENT BUG CONFIRMED: the caller periodic interval was silently lost');
    }
};

done_testing();
