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

subtest 'stale.cmd ignores a change from devnull stdin to inherited stdin' => sub {
    in_fresh_dir(sub {
        my $out = 'stdin.txt';
        my $input = 'caller-input.txt';
        open my $infile, '>', $input or die $!;
        print $infile "from caller\n";
        close $infile;

        my $code = q{
            my $line = <STDIN>;
            open my $f, '>', $ARGV[0] or die $!;
            print $f defined($line) ? $line : "EOF\n";
            close $f;
        };

        task(
            cmd           => [$^X, '-e', $code, $out],
            'output.file' => $out,
            'stale.cmd'   => 1,
            stdin         => 'devnull',
            quiet         => 1,
        );
        is(slurp($out), "EOF\n", 'first run saw devnull');

        open my $saved, '<&', \*STDIN or die $!;
        open STDIN, '<', $input or die $!;
        my $second = task(
            cmd           => [$^X, '-e', $code, $out],
            'output.file' => $out,
            'stale.cmd'   => 1,
            stdin         => 'inherit',
            quiet         => 1,
        );
        open STDIN, '<&', $saved or die $!;
        close $saved;

        is($second->{'cmd.changed'}, 0,
            'CURRENT BUG CONFIRMED: stdin mode is absent from stale.cmd signature');
        is($second->{done}, 'before',
            'CURRENT BUG CONFIRMED: task is skipped after stdin semantics changed');
        is(slurp($out), "EOF\n",
            'CURRENT BUG CONFIRMED: output was not rebuilt from inherited stdin');
    });
};

subtest 'env values are copied verbatim into log and trace records' => sub {
    in_fresh_dir(sub {
        my $log_path = 'run.log';
        my $trace_path = 'trace.jsonl';
        open my $log, '>', $log_path or die $!;
        open my $trace, '>', $trace_path or die $!;
        my $secret = 'audit-secret-DO-NOT-LOG';
        task(
            cmd        => [$^X, '-e', 'exit 0'],
            env        => { API_TOKEN => $secret },
            'dry.run'  => 1,
            'log.fh'   => $log,
            'trace.fh' => $trace,
            quiet      => 1,
        );
        close $log;
        close $trace;
        like(slurp($log_path), qr/\Q$secret\E/,
            'SECURITY FOOTGUN CONFIRMED: explicit env secret appears in the human log');
        like(slurp($trace_path), qr/\Q$secret\E/,
            'SECURITY FOOTGUN CONFIRMED: explicit env secret appears in the JSON trace');
    });
};

subtest 'array-form command accepts NUL and exec truncates the argument' => sub {
    local $SIG{__WARN__} = sub { };
    my $r = task(
        cmd   => [$^X, '-e', q{print length($ARGV[0])}, "a\0b"],
        quiet => 1,
    );
    is($r->{stdout}, '1',
        'CURRENT BUG CONFIRMED on POSIX: an accepted argv word containing NUL is truncated by exec');
};

subtest 'caller output encoding can make successful binary child output fatal during capture' => sub {
    my $sink = '';
    open my $encoded, '>:encoding(UTF-8)', \$sink or die $!;
    my $error = '';
    {
        local *STDOUT = $encoded;
        eval {
            task(
                cmd   => [$^X, '-e', q{binmode STDOUT; print STDOUT chr(255)}],
                quiet => 1,
            );
        };
        $error = $@;
    }
    close $encoded;
    like($error, qr/(?:UTF-8|does not map|read a capture file)/i,
        'CURRENT BUG CONFIRMED: capture re-applies caller encoding and the task dies on raw byte output');
};

subtest 'parallel jobs>1 cannot return an otherwise accepted CODE-valued note' => sub {
    my $serial_error = '';
    eval {
        my @r = parallel(
            jobs  => 1,
            tasks => [{ cmd => [$^X, '-e', 'exit 0'], note => sub { 1 }, quiet => 1 }],
        );
    };
    $serial_error = $@;
    is($serial_error, '',
        'jobs=1 accepts the CODE-valued note because task() does not validate note');

    my $parallel_error = '';
    {
        local $SIG{__WARN__} = sub { };
        eval {
            my @r = parallel(
                jobs  => 2,
                tasks => [{ cmd => [$^X, '-e', 'exit 0'], note => sub { 1 }, quiet => 1 }],
            );
        };
        $parallel_error = $@;
    }
    like($parallel_error, qr/process running it ended before it could return a record|tasks failed/i,
        'CURRENT BUG CONFIRMED: jobs>1 loses the record because Storable cannot serialize CODE');
};

subtest 'failure cleanup deletes an unrelated pre-existing output.failed directory' => sub {
    in_fresh_dir(sub {
        my $out = 'dataset';
        my $aside = "$out.failed";
        mkdir $aside or die $!;
        open my $old, '>', "$aside/valuable-old-data" or die $!;
        print $old "unrelated\n";
        close $old;

        my $code = q{
            mkdir $ARGV[0] or die $!;
            open my $f, '>', "$ARGV[0]/new-partial" or die $!;
            print $f "new partial\n";
            close $f;
            exit 9;
        };
        local $SIG{__WARN__} = sub { };
        task(
            cmd          => [$^X, '-e', $code, $out],
            'output.dir' => $out,
            die          => 0,
            quiet        => 1,
        );

        ok(!-e "$aside/valuable-old-data",
            'CURRENT DESIGN HAZARD CONFIRMED: unrelated pre-existing .failed content was recursively deleted');
        ok(-e "$aside/new-partial",
            'the new failed output replaced the old directory');
    });
};

done_testing();
